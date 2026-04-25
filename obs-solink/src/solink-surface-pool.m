/*
 solink-surface-pool.m — IOSurface triple-buffer pool (ObjC + Metal)
 ====================================================================
 Creates SOLINK_BUFFER_COUNT IOSurfaces for cross-process sharing,
 plus OBS gs_stagesurf_t staging surfaces for GPU→CPU readback.

 Render targets are intentionally NOT managed here.
 The caller (solink-output.c) owns gs_texrender_t per slot, which:
   - properly saves/restores OBS render state (including the active render
     target) around each off-screen render pass
   - is the canonical OBS pattern for capture/output plugins

 GPU→IOSurface copy path (solink_pool_copy_to_iosurface):
   gs_texture_t * (from gs_texrender_get_texture)
     → gs_stage_texture            (GPU→staging, async submit)
     → gs_stagesurface_map         (blocks until GPU done)
     → memcpy                      (staging→IOSurface CPU memory)
     → gs_stagesurface_unmap

 All gs_* calls MUST happen on the OBS graphics thread.
 */

#import <Foundation/Foundation.h>
#import <IOSurface/IOSurface.h>

#include <obs-module.h>
#include <graphics/graphics.h>

#include "solink-surface-pool.h"
#include "solink-protocol.h"

// ─── Internal struct ─────────────────────────────────────────────────────────

struct solink_surface_pool {
    uint32_t       width;
    uint32_t       height;
    uint32_t       pixel_format;

    IOSurfaceRef   surfaces[SOLINK_BUFFER_COUNT];
    uint32_t       surface_ids[SOLINK_BUFFER_COUNT];

    // Stage surfaces for GPU→CPU readback (OBS cross-backend API).
    // Render targets are owned by gs_texrender_t in solink_output_t.
    gs_stagesurf_t *stage_surfaces[SOLINK_BUFFER_COUNT];
};

// ─── IOSurface creation ──────────────────────────────────────────────────────

static IOSurfaceRef create_iosurface(uint32_t width, uint32_t height,
                                      uint32_t pixel_format)
{
    uint32_t bpe = 4;
    uint32_t bytes_per_row = width * bpe;

    uint32_t ios_pixel_format;
    switch (pixel_format) {
        case SOLINK_PIXEL_FORMAT_BGRA8:
            ios_pixel_format = 'BGRA';
            break;
        case SOLINK_PIXEL_FORMAT_RGBA8:
            ios_pixel_format = 'RGBA';
            break;
        default:
            ios_pixel_format = 'BGRA';
    }

    NSDictionary *props = @{
        (id)kIOSurfaceWidth:           @(width),
        (id)kIOSurfaceHeight:          @(height),
        (id)kIOSurfaceBytesPerElement: @(bpe),
        (id)kIOSurfaceBytesPerRow:     @(bytes_per_row),
        (id)kIOSurfacePixelFormat:     @(ios_pixel_format),
        (id)kIOSurfaceIsGlobal:        @YES,
    };

    IOSurfaceRef surface = IOSurfaceCreate((__bridge CFDictionaryRef)props);
    if (!surface) {
        blog(LOG_ERROR, "[SOLink] IOSurfaceCreate failed (%ux%u)", width, height);
    }
    return surface;
}

// ─── Pool create / destroy ───────────────────────────────────────────────────

solink_surface_pool_t *solink_pool_create(uint32_t width, uint32_t height,
                                          uint32_t pixel_format)
{
    solink_surface_pool_t *pool = bzalloc(sizeof(*pool));
    pool->width        = width;
    pool->height       = height;
    pool->pixel_format = pixel_format;

    obs_enter_graphics();

    for (uint32_t i = 0; i < SOLINK_BUFFER_COUNT; i++) {
        // 1. Create IOSurface for cross-process sharing
        pool->surfaces[i] = create_iosurface(width, height, pixel_format);
        if (!pool->surfaces[i]) {
            obs_leave_graphics();
            solink_pool_destroy(pool);
            return NULL;
        }
        pool->surface_ids[i] = IOSurfaceGetID(pool->surfaces[i]);

        // 2. Create stage surface for GPU→CPU readback.
        //    Render targets are owned by gs_texrender_t in solink_output_t.
        pool->stage_surfaces[i] = gs_stagesurface_create(width, height, GS_BGRA);
        if (!pool->stage_surfaces[i]) {
            blog(LOG_ERROR,
                 "[SOLink] gs_stagesurface_create failed for slot %u", i);
            obs_leave_graphics();
            solink_pool_destroy(pool);
            return NULL;
        }

        blog(LOG_INFO, "[SOLink] Pool slot %u: IOSurfaceID=%u", i,
             pool->surface_ids[i]);
    }

    obs_leave_graphics();

    blog(LOG_INFO, "[SOLink] Surface pool created (%ux%u, %u buffers)",
         width, height, SOLINK_BUFFER_COUNT);
    return pool;
}

void solink_pool_destroy(solink_surface_pool_t *pool)
{
    if (!pool) return;

    obs_enter_graphics();
    for (uint32_t i = 0; i < SOLINK_BUFFER_COUNT; i++) {
        if (pool->stage_surfaces[i]) {
            gs_stagesurface_destroy(pool->stage_surfaces[i]);
            pool->stage_surfaces[i] = NULL;
        }
        if (pool->surfaces[i]) {
            CFRelease(pool->surfaces[i]);
            pool->surfaces[i] = NULL;
        }
    }
    obs_leave_graphics();

    blog(LOG_INFO, "[SOLink] Surface pool destroyed");
    bfree(pool);
}

// ─── IOSurface ID accessor ───────────────────────────────────────────────────

uint32_t solink_pool_iosurface_id(const solink_surface_pool_t *pool,
                                   uint32_t index)
{
    if (!pool || index >= SOLINK_BUFFER_COUNT) return 0;
    return pool->surface_ids[index];
}

// ─── Copy gs_texrender texture → IOSurface ───────────────────────────────────
//
// @p tex is gs_texrender_get_texture(texrender[index]) — the texture that
// obs_render_main_texture() drew into during gs_texrender_begin/end.

void solink_pool_copy_to_iosurface(solink_surface_pool_t *pool,
                                   uint32_t index,
                                   gs_texture_t *tex)
{
    if (!pool || index >= SOLINK_BUFFER_COUNT) return;
    if (!pool->surfaces[index] || !tex) return;

    gs_stagesurf_t *stage = pool->stage_surfaces[index];
    uint32_t w = pool->width;
    uint32_t h = pool->height;

    // 1. GPU → stage surface (cross-backend copy)
    gs_stage_texture(stage, tex);

    // 2. Map stage surface for CPU access
    uint8_t *data = NULL;
    uint32_t linesize = 0;
    if (!gs_stagesurface_map(stage, &data, &linesize)) {
        blog(LOG_WARNING, "[SOLink] gs_stagesurface_map failed");
        return;
    }

    // 3. Copy into IOSurface
    IOSurfaceLock(pool->surfaces[index], 0, NULL);
    uint8_t *base = IOSurfaceGetBaseAddress(pool->surfaces[index]);
    if (base && data) {
        size_t dst_row = IOSurfaceGetBytesPerRow(pool->surfaces[index]);
        size_t src_row = linesize;
        size_t copy_width = (size_t)w * 4;

        if (dst_row == src_row && dst_row == copy_width) {
            memcpy(base, data, copy_width * h);
        } else {
            for (uint32_t y = 0; y < h; y++) {
                memcpy(base + y * dst_row, data + y * src_row, copy_width);
            }
        }
    }
    IOSurfaceUnlock(pool->surfaces[index], 0, NULL);

    // 4. Unmap
    gs_stagesurface_unmap(stage);
}
