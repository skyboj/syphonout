/*
 solink-surface-pool.h — IOSurface triple-buffer pool
*/
#pragma once

#include <stdint.h>
#include "solink-protocol.h"

#ifdef __cplusplus
extern "C" {
#endif

/// Opaque IOSurface pool — 3 IOSurfaces + 3 OBS gs_stagesurf_t for GPU→CPU readback.
/// Render targets are managed externally by gs_texrender_t (one per slot in solink_output_t).
typedef struct solink_surface_pool solink_surface_pool_t;

/// Create a triple-buffer IOSurface pool.
/// Must be called on the OBS graphics thread.
/// Returns NULL on failure.
solink_surface_pool_t *solink_pool_create(uint32_t width, uint32_t height,
                                          uint32_t pixel_format);

/// Destroy pool and release all IOSurfaces and stage surfaces.
/// Must be called on the OBS graphics thread.
void solink_pool_destroy(solink_surface_pool_t *pool);

/// Get the IOSurface ID for buffer slot @p index (for writing into SOLinkHeader).
uint32_t solink_pool_iosurface_id(const solink_surface_pool_t *pool,
                                   uint32_t index);

/// Copy rendered pixels from @p tex (a gs_texrender's internal texture) to
/// the IOSurface at @p index via GPU→stage→CPU→IOSurface.
/// Must be called on the OBS graphics thread.
void solink_pool_copy_to_iosurface(solink_surface_pool_t *pool,
                                   uint32_t index,
                                   struct gs_texture *tex);

#ifdef __cplusplus
}
#endif
