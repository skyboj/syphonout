/*
 solink-surface-pool.m — IOSurface triple-buffer pool (ObjC + Metal)
 ====================================================================
 Creates SOLINK_BUFFER_COUNT IOSurfaces and wraps each in an OBS gs_texture_t
 via gs_texture_create_from_iosurface() — the OBS macOS Metal backend API.

 All gs_* calls MUST happen on the OBS graphics thread.
*/

#import <Foundation/Foundation.h>
#import <IOSurface/IOSurface.h>
#import <Metal/Metal.h>

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
    gs_texture_t  *textures[SOLINK_BUFFER_COUNT];
    uint32_t       surface_ids[SOLINK_BUFFER_COUNT];

    uint32_t       current_write_index;  // next slot to write (not yet published)
};

// ─── IOSurface creation ──────────────────────────────────────────────────────

static IOSurfaceRef create_iosurface(uint32_t width, uint32_t height,
                                     uint32_t pixel_format)
{
    // Bytes per element based on pixel format
    // BGRA8 = 4 bytes, RGBA8 = 4 bytes
    uint32_t bpe = 4;
    uint32_t bytes_per_row = width * bpe;

    // IOSurface pixel format: 'BGRA' = 0x42475241
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
        (id)kIOSurfaceIsGlobal:        @YES,    // accessible cross-process
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
        pool->surfaces[i] = create_iosurface(width, height, pixel_format);
        if (!pool->surfaces[i]) {
            obs_leave_graphics();
            solink_pool_destroy(pool);
            return NULL;
        }

        // Wrap IOSurface in an OBS Metal texture so OBS can render into it.
        // gs_texture_create_from_iosurface is a macOS-specific OBS API.
        pool->textures[i] =
            gs_texture_create_from_iosurface(pool->surfaces[i]);

        if (!pool->textures[i]) {
            blog(LOG_ERROR,
                 "[SOLink] gs_texture_create_from_iosurface failed for slot %u", i);
            obs_leave_graphics();
            solink_pool_destroy(pool);
            return NULL;
        }

        pool->surface_ids[i] = IOSurfaceGetID(pool->surfaces[i]);
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
        if (pool->textures[i]) {
            gs_texture_destroy(pool->textures[i]);
            pool->textures[i] = NULL;
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

// ─── Index / accessor ────────────────────────────────────────────────────────

uint32_t solink_pool_next_index(const solink_surface_pool_t *pool)
{
    // Next write slot: advance from current without touching what subscriber reads
    return (pool->current_write_index + 1) % SOLINK_BUFFER_COUNT;
}

struct gs_texture *solink_pool_texture(const solink_surface_pool_t *pool,
                                       uint32_t index)
{
    if (!pool || index >= SOLINK_BUFFER_COUNT) return NULL;
    return pool->textures[index];
}

uint32_t solink_pool_iosurface_id(const solink_surface_pool_t *pool,
                                   uint32_t index)
{
    if (!pool || index >= SOLINK_BUFFER_COUNT) return 0;
    return pool->surface_ids[index];
}
