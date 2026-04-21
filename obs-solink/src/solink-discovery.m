/*
 solink-discovery.m — NSDistributedNotificationCenter server lifecycle
 ======================================================================
 Handles:
   • Responding to SOLinkServerEnumerate (late-joining subscribers)
   • Broadcasting SOLinkServerAnnounce / SOLinkServerRetire
*/

#import <Foundation/Foundation.h>
#include <obs-module.h>

#include "solink-discovery.h"
#include "solink-protocol.h"

// ─── Active outputs cache (uuid → announce userInfo) ─────────────────────────

static NSMutableDictionary<NSString *, NSDictionary *> *gActiveOutputs = nil;
static id gEnumerateObserver = nil;

// ─── Init / deinit ───────────────────────────────────────────────────────────

void solink_discovery_init(void)
{
    gActiveOutputs = [NSMutableDictionary dictionary];

    NSDistributedNotificationCenter *dnc =
        [NSDistributedNotificationCenter defaultCenter];

    // When a subscriber starts and broadcasts Enumerate,
    // reply with Announce for every currently active output.
    gEnumerateObserver =
        [dnc addObserverForName:@(SOLINK_NOTIF_ENUMERATE)
                         object:nil
                          queue:nil
                     usingBlock:^(NSNotification *note) {
            (void)note;
            blog(LOG_INFO, "[SOLink] Received Enumerate — re-announcing %u outputs",
                 (unsigned)gActiveOutputs.count);
            for (NSDictionary *info in gActiveOutputs.allValues) {
                [dnc postNotificationName:@(SOLINK_NOTIF_ANNOUNCE)
                                   object:nil
                                 userInfo:info
                       deliverImmediately:YES];
            }
        }];

    blog(LOG_INFO, "[SOLink] Discovery init");
}

void solink_discovery_deinit(void)
{
    if (gEnumerateObserver) {
        [[NSDistributedNotificationCenter defaultCenter]
            removeObserver:gEnumerateObserver];
        gEnumerateObserver = nil;
    }
    [gActiveOutputs removeAllObjects];
    gActiveOutputs = nil;
    blog(LOG_INFO, "[SOLink] Discovery deinit");
}

// ─── Announce ─────────────────────────────────────────────────────────────────

void solink_discovery_announce(const char *uuid,
                                const char *server_name,
                                const char *app_name,
                                const char *shm_name,
                                uint32_t    width,
                                uint32_t    height,
                                uint32_t    pixel_format)
{
    NSString *uuidStr = [NSString stringWithUTF8String:uuid ?: ""];

    NSDictionary *info = @{
        @(SOLINK_KEY_UUID):         uuidStr,
        @(SOLINK_KEY_NAME):         [NSString stringWithUTF8String:server_name ?: ""],
        @(SOLINK_KEY_APP_NAME):     [NSString stringWithUTF8String:app_name    ?: ""],
        @(SOLINK_KEY_SHM_NAME):     [NSString stringWithUTF8String:shm_name    ?: ""],
        @(SOLINK_KEY_WIDTH):        @(width),
        @(SOLINK_KEY_HEIGHT):       @(height),
        @(SOLINK_KEY_PIXEL_FORMAT): @(pixel_format),
    };

    gActiveOutputs[uuidStr] = info;

    [[NSDistributedNotificationCenter defaultCenter]
        postNotificationName:@(SOLINK_NOTIF_ANNOUNCE)
                      object:nil
                    userInfo:info
          deliverImmediately:YES];

    blog(LOG_INFO, "[SOLink] Announced: '%s' shm=%s", server_name, shm_name);
}

// ─── Retire ──────────────────────────────────────────────────────────────────

void solink_discovery_retire(const char *uuid)
{
    NSString *uuidStr = [NSString stringWithUTF8String:uuid ?: ""];
    [gActiveOutputs removeObjectForKey:uuidStr];

    [[NSDistributedNotificationCenter defaultCenter]
        postNotificationName:@(SOLINK_NOTIF_RETIRE)
                      object:nil
                    userInfo:@{ @(SOLINK_KEY_UUID): uuidStr }
          deliverImmediately:YES];

    blog(LOG_INFO, "[SOLink] Retired: %s", uuid);
}
