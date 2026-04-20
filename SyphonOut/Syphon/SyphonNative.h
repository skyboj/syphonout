#pragma once
/*
 SyphonNative.h
 Runtime dlopen-based Syphon bridge — no compile-time dependency on Syphon.framework.

 Call order:
   1. SyphonNativeLoad()          — dlopen the framework, create shared CGLContext.
   2. SyphonNativeStartDiscovery()— subscribe to NSDistributedNotificationCenter,
                                    enumerate existing servers, call Rust FFI.
   3. SyphonNativeSetServer()     — create SyphonClient for a display.
   4. SyphonNativeClearServer()   — tear down a display's SyphonClient.
   5. SyphonNativeStop()          — unregister notifications, stop all clients.
*/

#include <stdint.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Load Syphon.framework via dlopen from known install paths.
/// Returns true on success. Safe to call multiple times.
bool SyphonNativeLoad(void);

/// Subscribe to Syphon's NSDistributedNotificationCenter notifications
/// and enumerate servers already present on the network.
/// Calls syphonout_on_server_announced / syphonout_on_server_retired on events.
/// Must be called after SyphonNativeLoad().
void SyphonNativeStartDiscovery(void);

/// Create (or replace) the SyphonClient for @p displayId using the server
/// identified by @p uuid (null-terminated UTF-8). Frames are pushed to Rust
/// via syphonout_on_new_frame() from a Syphon callback thread.
void SyphonNativeSetServer(uint32_t displayId, const char *uuid);

/// Tear down and release the SyphonClient for @p displayId.
void SyphonNativeClearServer(uint32_t displayId);

/// Stop all clients and unregister all notifications. Call from applicationWillTerminate.
void SyphonNativeStop(void);

#ifdef __cplusplus
}
#endif
