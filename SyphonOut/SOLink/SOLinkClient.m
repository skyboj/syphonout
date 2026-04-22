/*
 SOLinkClient.m — SOLink subscriber implementation
 ==================================================
 Discovery:  NSDistributedNotificationCenter → Announce / Retire / Enumerate
 Frames:     mmap(SOLinkHeader) + dispatch_source timer polls frame_counter at ~120 Hz.
             On change → IOSurfaceLookup(ids[current_index]) → syphonout_on_new_frame().

 No memcpy. No staging. The IOSurface is already filled by the OBS plugin;
 Rust creates a zero-copy MTLTexture from it via newTextureWithDescriptor:iosurface:plane:.
*/

#import <Foundation/Foundation.h>
#import <IOSurface/IOSurface.h>
#import <sys/mman.h>
#import <fcntl.h>
#import <unistd.h>
#import <stdatomic.h>

#import "SOLinkClient.h"
#import "syphonout_core.h"

// ─── SOLink protocol constants (mirrors solink-protocol.h) ───────────────────
// Duplicated here to avoid a cross-project include path dependency.

#define SOLINK_MAGIC         0x4B4E4C53u
#define SOLINK_BUFFER_COUNT  3u
#define SOLINK_SHM_NAME_MAX  33u

#define SOLINK_LIVENESS_TIMEOUT_NS  500000000ULL   /* 500 ms */

#define SOLINK_NOTIF_ANNOUNCE   "SOLinkServerAnnounce"
#define SOLINK_NOTIF_RETIRE     "SOLinkServerRetire"
#define SOLINK_NOTIF_ENUMERATE  "SOLinkServerEnumerate"

#define SOLINK_KEY_UUID         "SOLinkUUID"
#define SOLINK_KEY_NAME         "SOLinkName"
#define SOLINK_KEY_APP_NAME     "SOLinkAppName"
#define SOLINK_KEY_SHM_NAME     "SOLinkShmName"
#define SOLINK_KEY_WIDTH        "SOLinkWidth"
#define SOLINK_KEY_HEIGHT       "SOLinkHeight"

typedef struct {
    uint32_t magic, version, width, height, pixel_format, buffer_count;
    uint32_t iosurface_ids[SOLINK_BUFFER_COUNT];
    uint32_t _pad0;
    _Atomic uint64_t frame_counter;
    _Atomic uint32_t current_index;
    _Atomic uint32_t publisher_pid;
    _Atomic uint64_t timestamp_ns;
    char server_name[32];
    char app_name[16];
    uint8_t _reserved[16];
} SOLinkHeader;

// ─── Per-display subscriber ──────────────────────────────────────────────────

@interface SOLinkSubscriber : NSObject
@property (nonatomic, assign) uint32_t      displayId;
@property (nonatomic, copy)   NSString     *publisherUUID;   // raw UUID, no prefix
@property (nonatomic, assign) SOLinkHeader *header;          // mmap pointer, NULL if closed
@property (nonatomic, assign) int           shmFd;
@property (nonatomic, assign) uint64_t      lastFrameCounter;
@property (nonatomic, strong) dispatch_source_t pollSource;
@end

@implementation SOLinkSubscriber

- (instancetype)init {
    if ((self = [super init])) {
        _shmFd = -1;
        _header = NULL;
    }
    return self;
}

- (void)stopPolling {
    if (_pollSource) {
        dispatch_source_cancel(_pollSource);
        _pollSource = nil;
    }
}

- (void)closeSHM {
    if (_header && _header != (SOLinkHeader *)MAP_FAILED) {
        munmap(_header, sizeof(SOLinkHeader));
        _header = NULL;
    }
    if (_shmFd >= 0) {
        close(_shmFd);
        _shmFd = -1;
    }
}

- (void)stop {
    [self stopPolling];
    [self closeSHM];
    NSLog(@"[SOLinkClient] Subscriber stopped for display %u", _displayId);
}

@end

// ─── Module state ─────────────────────────────────────────────────────────────

// uuid (no prefix) → announce userInfo dict
static NSMutableDictionary<NSString *, NSDictionary *> *gServers;
// displayId → SOLinkSubscriber
static NSMutableDictionary<NSNumber *, SOLinkSubscriber *> *gSubscribers;
// notification observers (for removeObserver on stop)
static NSMutableArray<id> *gObservers;

static dispatch_queue_t gPollQueue;  // serial queue for all frame polling

// ─── Monotonic clock ─────────────────────────────────────────────────────────

static uint64_t now_ns(void) {
    struct timespec ts;
    clock_gettime(CLOCK_UPTIME_RAW, &ts);
    return (uint64_t)ts.tv_sec * 1000000000ULL + (uint64_t)ts.tv_nsec;
}

// ─── Server announce / retire helpers ────────────────────────────────────────

static void handleAnnounce(NSDictionary *info) {
    if (!info) return;

    NSString *uuid    = info[@SOLINK_KEY_UUID]     ?: @"";
    NSString *name    = info[@SOLINK_KEY_NAME]     ?: @"";
    NSString *appName = info[@SOLINK_KEY_APP_NAME] ?: @"";

    if (uuid.length == 0) return;

    @synchronized (gServers) {
        gServers[uuid] = info;
    }

    // Prefix UUID with "solink:" so Swift/Rust can tell it apart from Syphon servers.
    NSString *prefixed = [@"solink:" stringByAppendingString:uuid];
    syphonout_on_server_announced(prefixed.UTF8String,
                                  name.UTF8String,
                                  appName.UTF8String);

    NSLog(@"[SOLinkClient] Announced: '%@' (by %@) uuid=%@", name, appName, uuid);
}

static void handleRetire(NSDictionary *info) {
    if (!info) return;

    NSString *uuid = info[@SOLINK_KEY_UUID] ?: @"";
    if (uuid.length == 0) return;

    @synchronized (gServers) {
        [gServers removeObjectForKey:uuid];
    }

    NSString *prefixed = [@"solink:" stringByAppendingString:uuid];
    syphonout_on_server_retired(prefixed.UTF8String);

    NSLog(@"[SOLinkClient] Retired: uuid=%@", uuid);
}

// ─── Frame polling ────────────────────────────────────────────────────────────

static void tickSubscriber(SOLinkSubscriber *sub) {
    SOLinkHeader *hdr = sub.header;
    if (!hdr) return;

    // Liveness: publisher_pid == 0 means clean shutdown
    uint32_t pid = atomic_load_explicit(&hdr->publisher_pid, memory_order_relaxed);
    if (pid == 0) return;

    // Liveness: timestamp stale > 500 ms → publisher hung/crashed
    uint64_t ts = atomic_load_explicit(&hdr->timestamp_ns, memory_order_relaxed);
    if (now_ns() - ts > SOLINK_LIVENESS_TIMEOUT_NS) return;

    // Check for new frame
    uint64_t fc = atomic_load_explicit(&hdr->frame_counter, memory_order_acquire);
    if (fc == sub.lastFrameCounter) return;
    sub.lastFrameCounter = fc;

    // Read which buffer index was last written
    uint32_t idx = atomic_load_explicit(&hdr->current_index, memory_order_acquire);
    if (idx >= SOLINK_BUFFER_COUNT) return;

    uint32_t surfId = hdr->iosurface_ids[idx];
    if (surfId == 0) return;

    // IOSurfaceLookup returns a +1 retained ref
    IOSurfaceRef surface = IOSurfaceLookup(surfId);
    if (!surface) return;

    // Hand IOSurface to Rust — it creates a zero-copy MTLTexture internally
    syphonout_on_new_frame(sub.displayId,
                           (void *)surface,
                           hdr->width,
                           hdr->height);

    // Release our +1 reference (Rust/Metal retains its own)
    CFRelease(surface);
}

// ─── Public API ───────────────────────────────────────────────────────────────

void SOLinkClientInit(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        gServers     = [NSMutableDictionary dictionary];
        gSubscribers = [NSMutableDictionary dictionary];
        gObservers   = [NSMutableArray array];
        gPollQueue   = dispatch_queue_create("com.syphonout.solink.poll",
                                             DISPATCH_QUEUE_SERIAL);
    });

    NSDistributedNotificationCenter *dnc = [NSDistributedNotificationCenter defaultCenter];
    id obs;

    obs = [dnc addObserverForName:@SOLINK_NOTIF_ANNOUNCE object:nil queue:nil
                       usingBlock:^(NSNotification *n) { handleAnnounce(n.userInfo); }];
    [gObservers addObject:obs];

    obs = [dnc addObserverForName:@SOLINK_NOTIF_RETIRE object:nil queue:nil
                       usingBlock:^(NSNotification *n) { handleRetire(n.userInfo); }];
    [gObservers addObject:obs];

    NSLog(@"[SOLinkClient] Initialised — listening for SOLink publishers");
}

void SOLinkClientStartDiscovery(void) {
    // Ask any running publisher to re-announce itself.
    // Publishers observe SOLinkServerEnumerate and reply with Announce.
    [[NSDistributedNotificationCenter defaultCenter]
        postNotificationName:@SOLINK_NOTIF_ENUMERATE
                      object:nil
                    userInfo:nil
          deliverImmediately:YES];

    NSLog(@"[SOLinkClient] Sent SOLinkServerEnumerate — waiting for publishers to reply");
}

void SOLinkClientSetServer(uint32_t displayId, const char *uuid) {
    if (!uuid || !gServers) return;

    NSString *uuidStr = [NSString stringWithUTF8String:uuid];
    NSDictionary *info = nil;
    @synchronized (gServers) {
        info = gServers[uuidStr];
    }

    if (!info) {
        NSLog(@"[SOLinkClient] Server %@ not in cache — cannot subscribe", uuidStr);
        return;
    }

    NSString *shmName = info[@SOLINK_KEY_SHM_NAME];
    if (!shmName) {
        NSLog(@"[SOLinkClient] No SHM name in server info for %@", uuidStr);
        return;
    }

    // Tear down existing subscriber for this display
    SOLinkClientClearServer(displayId);

    // Open shared memory
    int fd = shm_open(shmName.UTF8String, O_RDONLY, 0);
    if (fd < 0) {
        NSLog(@"[SOLinkClient] shm_open('%@') failed: %s", shmName, strerror(errno));
        return;
    }

    SOLinkHeader *hdr = mmap(NULL, sizeof(SOLinkHeader),
                              PROT_READ, MAP_SHARED, fd, 0);
    if (hdr == MAP_FAILED) {
        NSLog(@"[SOLinkClient] mmap failed: %s", strerror(errno));
        close(fd);
        return;
    }

    // Sanity check
    if (hdr->magic != SOLINK_MAGIC) {
        NSLog(@"[SOLinkClient] Bad magic in SHM — not a SOLink region");
        munmap(hdr, sizeof(SOLinkHeader));
        close(fd);
        return;
    }

    // Build subscriber
    SOLinkSubscriber *sub = [[SOLinkSubscriber alloc] init];
    sub.displayId         = displayId;
    sub.publisherUUID     = uuidStr;
    sub.header            = hdr;
    sub.shmFd             = fd;
    sub.lastFrameCounter  = atomic_load(&hdr->frame_counter);  // don't replay old frames

    @synchronized (gSubscribers) {
        gSubscribers[@(displayId)] = sub;
    }

    // Poll at ~120 Hz on the serial poll queue — well above any display refresh rate.
    // dispatch_source_timer is low-overhead: no thread per subscriber.
    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, gPollQueue);
    uint64_t interval = 8 * NSEC_PER_MSEC;  // 8 ms → 125 Hz
    dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, 0), interval, NSEC_PER_MSEC);
    dispatch_source_set_event_handler(timer, ^{
        SOLinkSubscriber *s = nil;
        @synchronized (gSubscribers) {
            s = gSubscribers[@(displayId)];
        }
        if (s) tickSubscriber(s);
    });
    dispatch_resume(timer);
    sub.pollSource = timer;

    NSLog(@"[SOLinkClient] Subscribed display %u → '%@' shm=%@",
          displayId, uuidStr, shmName);
}

void SOLinkClientClearServer(uint32_t displayId) {
    SOLinkSubscriber *sub = nil;
    @synchronized (gSubscribers) {
        sub = gSubscribers[@(displayId)];
        [gSubscribers removeObjectForKey:@(displayId)];
    }
    [sub stop];
}

void SOLinkClientStop(void) {
    // Unregister all notification observers
    NSDistributedNotificationCenter *dnc = [NSDistributedNotificationCenter defaultCenter];
    for (id obs in gObservers) {
        [dnc removeObserver:obs];
    }
    [gObservers removeAllObjects];

    // Stop all active subscribers
    NSArray<NSNumber *> *displayIds;
    @synchronized (gSubscribers) {
        displayIds = [gSubscribers allKeys];
    }
    for (NSNumber *key in displayIds) {
        SOLinkClientClearServer(key.unsignedIntValue);
    }

    NSLog(@"[SOLinkClient] Stopped.");
}
