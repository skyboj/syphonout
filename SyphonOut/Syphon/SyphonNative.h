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
/// identified by @p uuid. Legacy path — prefer SyphonNativeSetServerForVD.
void SyphonNativeSetServer(uint32_t displayId, const char *uuid);

/// Tear down and release the SyphonClient for @p displayId (legacy path).
void SyphonNativeClearServer(uint32_t displayId);

/// VD-keyed variant: create a SyphonClient for Virtual Display @p vdUUID using
/// the server identified by @p serverUUID. Frames are delivered via
/// syphonout_on_new_frame_vd(vdUUID, ...).
void SyphonNativeSetServerForVD(const char *vdUUID, const char *serverUUID);

/// Stop and release the SyphonClient for Virtual Display @p vdUUID.
void SyphonNativeClearServerForVD(const char *vdUUID);

/// Stop all clients and unregister all notifications. Call from applicationWillTerminate.
void SyphonNativeStop(void);

#ifdef __cplusplus
}
#endif
