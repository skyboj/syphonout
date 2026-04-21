/*
 solink-discovery.h — NSDistributedNotificationCenter lifecycle layer
*/
#pragma once

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Subscribe to SOLinkServerEnumerate requests.
/// Called once from obs_module_load().
void solink_discovery_init(void);

/// Unsubscribe from all notifications.
/// Called from obs_module_unload().
void solink_discovery_deinit(void);

/// Broadcast a SOLinkServerAnnounce notification.
/// Called when an output starts.
void solink_discovery_announce(const char *uuid,
                                const char *server_name,
                                const char *app_name,
                                const char *shm_name,
                                uint32_t    width,
                                uint32_t    height,
                                uint32_t    pixel_format);

/// Broadcast a SOLinkServerRetire notification.
/// Called when an output stops.
void solink_discovery_retire(const char *uuid);

#ifdef __cplusplus
}
#endif
