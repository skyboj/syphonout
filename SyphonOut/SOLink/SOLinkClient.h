#pragma once
/*
 SOLinkClient.h — SOLink subscriber (SyphonOut side)
 ====================================================
 Mirrors SyphonNative.h but consumes the SOLink protocol instead of Syphon.

 Call order:
   1. SOLinkClientInit()            — register NSDistributedNotificationCenter observers.
   2. SOLinkClientStartDiscovery()  — post SOLinkServerEnumerate so running publishers
                                      reply with Announce. Calls syphonout_on_server_announced
                                      for each discovered publisher.
   3. SOLinkClientSetServer()       — open SHM, start polling frame_counter.
   4. SOLinkClientClearServer()     — stop polling, close SHM.
   5. SOLinkClientStop()            — tear everything down (call from applicationWillTerminate).

 UUID convention:
   SOLink server UUIDs are stored in Rust with a "solink:" prefix so
   OutputWindowController can distinguish them from Syphon servers.
   e.g. "solink:422D73FE-0831-441A-A862-0C7605891DC4"
*/

#include <stdint.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Register notification observers. Call once before StartDiscovery.
void SOLinkClientInit(void);

/// Post SOLinkServerEnumerate so already-running OBS publishers announce themselves.
/// Calls syphonout_on_server_announced for each discovered server.
void SOLinkClientStartDiscovery(void);

/// Open the shared memory for publisher @p uuid and start polling frames for @p displayId.
/// @p uuid is the raw UUID from the announce notification (WITHOUT the "solink:" prefix).
void SOLinkClientSetServer(uint32_t displayId, const char *uuid);

/// Stop polling and close shared memory for @p displayId.
void SOLinkClientClearServer(uint32_t displayId);

/// Unregister all observers and clear all subscribers. Call from applicationWillTerminate.
void SOLinkClientStop(void);

#ifdef __cplusplus
}
#endif
