/*
 solink-shm.h — POSIX shared memory (publisher side)
*/
#pragma once

#include <stdint.h>
#include "solink-protocol.h"
#include "solink-surface-pool.h"

#ifdef __cplusplus
extern "C" {
#endif

/// Opaque shm context (wraps SOLinkHeader + file descriptor).
typedef struct solink_shm solink_shm_t;

/// Create and initialise the shared memory region.
/// @p shm_name  — POSIX name as from solink_shm_name() (e.g. "/solink-uuid")
/// @p pool       — surface pool (provides IOSurface IDs for the header)
/// @p width/height/pixel_format — copied into the static header fields
/// @p server_name / @p app_name — copied into header metadata
/// Returns NULL on failure.
solink_shm_t *solink_shm_create(const char          *shm_name,
                                 solink_surface_pool_t *pool,
                                 uint32_t              width,
                                 uint32_t              height,
                                 uint32_t              pixel_format,
                                 const char           *server_name,
                                 const char           *app_name);

/// Atomically publish a completed frame.
/// @p next_idx — the buffer slot just rendered into.
/// Updates current_index, frame_counter, and timestamp_ns.
void solink_shm_publish_frame(solink_shm_t *shm, uint32_t next_idx);

/// Clean shutdown: zero-out publisher_pid and unlink the shm region.
void solink_shm_destroy(solink_shm_t *shm);

#ifdef __cplusplus
}
#endif
