/*
 solink-surface-pool.h — IOSurface triple-buffer pool
*/
#pragma once

#include <stdint.h>
#include "solink-protocol.h"

#ifdef __cplusplus
extern "C" {
#endif

/// Opaque IOSurface pool — 3 surfaces + 3 OBS gs_texture_t render targets.
typedef struct solink_surface_pool solink_surface_pool_t;

/// Create a triple-buffer IOSurface pool.
/// Must be called on the OBS graphics thread (gs_texture_create needs it).
/// Returns NULL on failure.
solink_surface_pool_t *solink_pool_create(uint32_t width, uint32_t height,
                                          uint32_t pixel_format);

/// Destroy pool and release all IOSurfaces and textures.
/// Must be called on the OBS graphics thread.
void solink_pool_destroy(solink_surface_pool_t *pool);

/// Get the index of the next buffer to write into (round-robin).
/// Does NOT advance the counter — call solink_shm_publish_frame() to commit.
uint32_t solink_pool_next_index(const solink_surface_pool_t *pool);

/// Get the OBS render-target gs_texture_t for buffer slot @p index.
/// Returns NULL if index is out of range or pool not ready.
struct gs_texture *solink_pool_texture(const solink_surface_pool_t *pool,
                                       uint32_t index);

/// Get the IOSurface ID for buffer slot @p index (for writing into SOLinkHeader).
uint32_t solink_pool_iosurface_id(const solink_surface_pool_t *pool,
                                   uint32_t index);

/// Copy rendered pixels from the render target texture to the IOSurface.
/// Call after gs_set_render_target(NULL, NULL) and before publishing.
void solink_pool_copy_to_iosurface(solink_surface_pool_t *pool, uint32_t index);

#ifdef __cplusplus
}
#endif
