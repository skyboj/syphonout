/*
 SyphonNative.m
 dlopen-based Syphon integration — no compile-time Syphon.framework dependency.

 Architecture:
   • Syphon.framework is loaded at runtime via dlopen().
   • SyphonServerDirectory is used for server enumeration.
   • NSDistributedNotificationCenter relays server lifecycle events.
   • One SyphonClient per display (keyed by CGDirectDisplayID).
   • A single shared CGLContext is created for all clients.
   • Per-frame: newFrameImage → extract IOSurface from _surface ivar →
     call syphonout_on_new_frame() so Rust creates a zero-copy MTLTexture.
*/

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <IOSurface/IOSurface.h>
#import <OpenGL/OpenGL.h>
#import <OpenGL/gl.h>
#import <dlfcn.h>

#import "SyphonNative.h"
// Rust FFI — declares syphonout_on_server_announced, syphonout_on_server_retired,
// syphonout_on_new_frame.
#import "syphonout_core.h"

// ─────────────────────────────────────────────────────────────────────────────
// Syphon string constants (values are stable across framework versions)
// ─────────────────────────────────────────────────────────────────────────────

static NSString * const kSyphonUUIDKey    = @"SyphonServerDescriptionUUID";
static NSString * const kSyphonNameKey    = @"SyphonServerDescriptionName";
static NSString * const kSyphonAppKey     = @"SyphonServerDescriptionAppName";

static NSString * const kSyphonAnnounce   = @"SyphonServerAnnounce";
static NSString * const kSyphonUpdate     = @"SyphonServerUpdate";
static NSString * const kSyphonRetire     = @"SyphonServerRetire";

// ─────────────────────────────────────────────────────────────────────────────
// Module-level state
// ─────────────────────────────────────────────────────────────────────────────

static void    *gSyphonHandle  = NULL;   // dlopen handle
static CGLContextObj gCGLCtx   = NULL;   // shared CGL context for SyphonClient
static NSMutableDictionary<NSString *, NSDictionary *> *gServerDescs = nil;
static NSMutableDictionary<NSString *, id>             *gClients     = nil;
static NSMutableArray<id /* NSObjectProtocol */> *gObservers         = nil;

// ─────────────────────────────────────────────────────────────────────────────
// IOSurface extraction
// ─────────────────────────────────────────────────────────────────────────────

/// SyphonIOSurfaceImage stores an IOSurfaceRef in its `_surface` ivar (not an ObjC object).
/// We use raw byte-offset arithmetic — object_getIvar() only works for ObjC object ivars.
static IOSurfaceRef extractIOSurface(id image) {
    if (!image) return NULL;
    Class cls = object_getClass(image);
    Ivar ivar = NULL;
    // Walk the class hierarchy to find _surface
    while (cls && !ivar) {
        ivar = class_getInstanceVariable(cls, "_surface");
        cls  = class_getSuperclass(cls);
    }
    if (!ivar) {
        NSLog(@"[SyphonNative] _surface ivar not found on %@", NSStringFromClass(object_getClass(image)));
        return NULL;
    }
    ptrdiff_t offset = ivar_getOffset(ivar);
    uint8_t  *base   = (__bridge void *)image;
    return *(IOSurfaceRef *)(base + offset);
}

// ─────────────────────────────────────────────────────────────────────────────
// SyphonNativeLoad
// ─────────────────────────────────────────────────────────────────────────────

bool SyphonNativeLoad(void) {
    if (gSyphonHandle) return true;

    static const char *kPaths[] = {
        // Bundled with our app (relative to the executable)
        "Frameworks/Syphon.framework/Syphon",
        // OBS app bundle
        "/Applications/OBS.app/Contents/Frameworks/Syphon.framework/Syphon",
        // OBS plugin data directories
        "/Library/Application Support/obs-studio/plugins/obs-syphon/data/Syphon.framework/Syphon",
        "/Library/Application Support/obs-studio/plugins/obs-syphon/Syphon.framework/Syphon",
        // System-wide
        "/Library/Frameworks/Syphon.framework/Syphon",
        NULL
    };

    for (int i = 0; kPaths[i]; i++) {
        gSyphonHandle = dlopen(kPaths[i], RTLD_NOW | RTLD_LOCAL);
        if (gSyphonHandle) {
            NSLog(@"[SyphonNative] Loaded Syphon.framework from: %s", kPaths[i]);
            break;
        }
    }

    if (!gSyphonHandle) {
        NSLog(@"[SyphonNative] Syphon.framework not found — Syphon source support disabled");
        return false;
    }

    // Create a minimal CGLContext for SyphonClient to operate in.
    // The context is never used for display — only for Syphon's internal texture management.
    CGLPixelFormatAttribute attrs[] = {
        kCGLPFAAccelerated,
        kCGLPFANoRecovery,
        kCGLPFAColorSize, (CGLPixelFormatAttribute)24,
        (CGLPixelFormatAttribute)0
    };
    CGLPixelFormatObj pix = NULL;
    GLint npix = 0;
    CGLError err = CGLChoosePixelFormat(attrs, &pix, &npix);
    if (err == kCGLNoError && pix) {
        CGLCreateContext(pix, NULL, &gCGLCtx);
        CGLDestroyPixelFormat(pix);
    }
    if (!gCGLCtx) {
        NSLog(@"[SyphonNative] Could not create CGLContext — SyphonClient frames unavailable");
    }

    gServerDescs = [NSMutableDictionary dictionary];
    gClients     = [NSMutableDictionary dictionary];
    gObservers   = [NSMutableArray array];
    return true;
}

// ─────────────────────────────────────────────────────────────────────────────
// Server lifecycle helpers
// ─────────────────────────────────────────────────────────────────────────────

static void handleAnnounce(NSDictionary *info) {
    if (!info) return;
    NSString *uuid    = info[kSyphonUUIDKey]    ?: @"";
    NSString *name    = info[kSyphonNameKey]    ?: @"";
    NSString *appName = info[kSyphonAppKey]     ?: @"";
    @synchronized (gServerDescs) {
        gServerDescs[uuid] = info;
    }
    syphonout_on_server_announced(uuid.UTF8String, name.UTF8String, appName.UTF8String);
}

static void handleRetire(NSDictionary *info) {
    if (!info) return;
    NSString *uuid = info[kSyphonUUIDKey] ?: @"";
    @synchronized (gServerDescs) {
        [gServerDescs removeObjectForKey:uuid];
    }
    syphonout_on_server_retired(uuid.UTF8String);
}

// ─────────────────────────────────────────────────────────────────────────────
// SyphonNativeStartDiscovery
// ─────────────────────────────────────────────────────────────────────────────

void SyphonNativeStartDiscovery(void) {
    if (!gSyphonHandle) return;

    NSDistributedNotificationCenter *dnc = [NSDistributedNotificationCenter defaultCenter];

    id obs;
    obs = [dnc addObserverForName:kSyphonAnnounce object:nil queue:nil usingBlock:^(NSNotification *n) {
        handleAnnounce(n.userInfo);
    }];
    [gObservers addObject:obs];

    obs = [dnc addObserverForName:kSyphonUpdate object:nil queue:nil usingBlock:^(NSNotification *n) {
        // Update cached description; don't re-announce to Rust (no API change from Rust's view)
        if (!n.userInfo) return;
        NSString *uuid = n.userInfo[kSyphonUUIDKey];
        if (uuid) {
            @synchronized (gServerDescs) { gServerDescs[uuid] = n.userInfo; }
        }
    }];
    [gObservers addObject:obs];

    obs = [dnc addObserverForName:kSyphonRetire object:nil queue:nil usingBlock:^(NSNotification *n) {
        handleRetire(n.userInfo);
    }];
    [gObservers addObject:obs];

    // Enumerate servers currently on the network via SyphonServerDirectory
    Class Dir = objc_getClass("SyphonServerDirectory");
    if (Dir) {
        id directory = ((id(*)(Class, SEL))objc_msgSend)(Dir, sel_registerName("sharedDirectory"));
        if (directory) {
            NSArray *servers = ((NSArray *(*)(id, SEL, id, id))objc_msgSend)(
                directory, sel_registerName("serversMatchingName:appName:"), nil, nil);
            for (NSDictionary *desc in servers) {
                handleAnnounce(desc);
            }
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Shared client management
// ─────────────────────────────────────────────────────────────────────────────

/// Create (or replace) a SyphonClient keyed by @p vdUUID, feeding server @p serverUUID.
static void startClientForVD(NSString *vdUUID, NSString *serverUUID) {
    if (!gSyphonHandle || !gCGLCtx || !vdUUID || !serverUUID) return;

    NSDictionary *desc = nil;
    @synchronized (gServerDescs) {
        desc = gServerDescs[serverUUID];
    }
    if (!desc) {
        NSLog(@"[SyphonNative] Server %@ not in cache — cannot create client for VD %@",
              serverUUID, vdUUID);
        return;
    }

    // Tear down any existing client for this VD key first
    id old = nil;
    @synchronized (gClients) {
        old = gClients[vdUUID];
        [gClients removeObjectForKey:vdUUID];
    }
    if (old) {
        ((void(*)(id, SEL))objc_msgSend)(old, sel_registerName("stop"));
    }

    Class SyphonClientClass = objc_getClass("SyphonClient");
    if (!SyphonClientClass) {
        NSLog(@"[SyphonNative] SyphonClient class not found");
        return;
    }

    NSString *vdKeyCopy = [vdUUID copy];
    void (^handler)(id client) = ^(id client) {
        CGLLockContext(gCGLCtx);
        id image = ((id(*)(id, SEL))objc_msgSend)(client, sel_registerName("newFrameImage"));
        CGLUnlockContext(gCGLCtx);
        if (!image) return;

        NSSize size = ((NSSize(*)(id, SEL))objc_msgSend)(image, sel_registerName("textureSize"));
        IOSurfaceRef surface = extractIOSurface(image);
        if (surface) {
            syphonout_on_new_frame_vd(vdKeyCopy.UTF8String,
                                      (void *)surface,
                                      (uint32_t)size.width,
                                      (uint32_t)size.height);
        }
        (void)image; // ARC releases at scope exit
    };

    id alloc  = ((id(*)(Class, SEL))objc_msgSend)(SyphonClientClass, sel_registerName("alloc"));
    id client = ((id(*)(id, SEL, NSDictionary *, CGLContextObj, NSDictionary *, id))objc_msgSend)(
        alloc,
        sel_registerName("initWithServerDescription:context:options:newFrameHandler:"),
        desc, gCGLCtx, nil, handler
    );
    if (!client) {
        NSLog(@"[SyphonNative] SyphonClient init failed for VD %@ server %@", vdUUID, serverUUID);
        return;
    }
    BOOL isValid = ((BOOL(*)(id, SEL))objc_msgSend)(client, sel_registerName("isValid"));
    if (!isValid) {
        NSLog(@"[SyphonNative] SyphonClient for VD %@ is not valid", vdUUID);
        return;
    }

    @synchronized (gClients) {
        gClients[vdUUID] = client;
    }
    NSLog(@"[SyphonNative] Created SyphonClient for VD '%@' → server %@", vdUUID, serverUUID);
}

/// Stop and remove the SyphonClient keyed by @p vdUUID.
static void stopClientForVD(NSString *vdUUID) {
    if (!vdUUID) return;
    id client = nil;
    @synchronized (gClients) {
        client = gClients[vdUUID];
        [gClients removeObjectForKey:vdUUID];
    }
    if (client) {
        ((void(*)(id, SEL))objc_msgSend)(client, sel_registerName("stop"));
        NSLog(@"[SyphonNative] Stopped SyphonClient for VD '%@'", vdUUID);
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Public API
// ─────────────────────────────────────────────────────────────────────────────

void SyphonNativeSetServer(uint32_t displayId, const char *uuid) {
    if (!uuid) return;
    NSString *vdUUID = [NSString stringWithFormat:@"__display__%u", displayId];
    startClientForVD(vdUUID, [NSString stringWithUTF8String:uuid]);
}

void SyphonNativeClearServer(uint32_t displayId) {
    NSString *vdUUID = [NSString stringWithFormat:@"__display__%u", displayId];
    stopClientForVD(vdUUID);
}

void SyphonNativeSetServerForVD(const char *vdUUID, const char *serverUUID) {
    if (!vdUUID || !serverUUID) return;
    startClientForVD([NSString stringWithUTF8String:vdUUID],
                     [NSString stringWithUTF8String:serverUUID]);
}

void SyphonNativeClearServerForVD(const char *vdUUID) {
    if (!vdUUID) return;
    stopClientForVD([NSString stringWithUTF8String:vdUUID]);
}

// ─────────────────────────────────────────────────────────────────────────────
// SyphonNativeStop
// ─────────────────────────────────────────────────────────────────────────────

void SyphonNativeStop(void) {
    // Unregister all notification observers
    NSDistributedNotificationCenter *dnc = [NSDistributedNotificationCenter defaultCenter];
    for (id obs in gObservers) {
        [dnc removeObserver:obs];
    }
    [gObservers removeAllObjects];

    // Stop all active clients
    NSArray<id> *allClients;
    @synchronized (gClients) {
        allClients = [gClients allValues];
        [gClients removeAllObjects];
    }
    for (id client in allClients) {
        if (client) {
            ((void(*)(id, SEL))objc_msgSend)(client, sel_registerName("stop"));
        }
    }

    // Destroy CGL context
    if (gCGLCtx) {
        CGLDestroyContext(gCGLCtx);
        gCGLCtx = NULL;
    }

    NSLog(@"[SyphonNative] Stopped.");
}
