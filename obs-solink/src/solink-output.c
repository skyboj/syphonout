/*
 solink-output.c — OBS output implementation
 =============================================
 Implements the obs_output_info callbacks that hook into OBS's video pipeline.

 Architecture:
   • obs_add_main_render_callback() hooks into OBS's main render loop.
   • Each frame: blit OBS main scene texture → one of our IOSurface-backed textures.
   • Atomic store of frame_counter signals subscribers (no per-frame IPC).

 NOTE: gs_* calls must happen on OBS's graphics thread.
       discovery/shm calls are safe from any thread.
*/

#include <stdio.h>
#include <string.h>
#include <obs-module.h>
#include <obs.h>
#include <graphics/graphics.h>
#include <util/platform.h>

#include "solink-output.h"
#include "solink-surface-pool.h"
#include "solink-shm.h"
#include "solink-discovery.h"
#include "solink-protocol.h"

// ─── Output context ──────────────────────────────────────────────────────────

typedef struct solink_output {
    obs_output_t       *output;
    solink_surface_pool_t *pool;        // IOSurface triple buffer
    solink_shm_t          *shm;         // shared memory header
    char                   uuid[64];    // this publisher's UUID
    char                   server_name[32];
    uint32_t               width;
    uint32_t               height;
    bool                   active;
} solink_output_t;

// ─── Render callback (graphics thread) ──────────────────────────────────────

static void render_callback(void *param, uint32_t cx, uint32_t cy)
{
    solink_output_t *ctx = param;
    if (!ctx->active || !ctx->pool || !ctx->shm) return;

    // Pick the next buffer slot (round-robin, never touches the slot subscriber is reading)
    uint32_t next_idx = solink_pool_next_index(ctx->pool);
    gs_texture_t *target = solink_pool_texture(ctx->pool, next_idx);
    if (!target) return;

    // Save OBS render state
    gs_blend_state_push();
    gs_reset_blend_state();

    // Render OBS main scene into our IOSurface-backed texture
    gs_set_render_target(target, NULL);
    gs_clear(GS_CLEAR_COLOR, NULL, 0.0f, 0);

    struct vec4 black;
    vec4_zero(&black);
    gs_ortho(0.0f, (float)ctx->width, 0.0f, (float)ctx->height, -100.0f, 100.0f);
    obs_render_main_texture();

    gs_set_render_target(NULL, NULL);
    gs_blend_state_pop();

    // Publish frame atomically — no IPC, just atomic stores
    solink_shm_publish_frame(ctx->shm, next_idx);
}

// ─── Output lifecycle ────────────────────────────────────────────────────────

static const char *solink_output_get_name(void *unused)
{
    (void)unused;
    return "SOLink Output";
}

static void *solink_output_create(obs_data_t *settings, obs_output_t *output)
{
    solink_output_t *ctx = bzalloc(sizeof(*ctx));
    ctx->output = output;

    const char *name = obs_data_get_string(settings, "server_name");
    snprintf(ctx->server_name, sizeof(ctx->server_name),
             "%s", (name && *name) ? name : "OBS Main");

    // Generate a UUID (simple: use process ID + pointer address)
    // In Phase 4 we'll use a proper UUID generator
    snprintf(ctx->uuid, sizeof(ctx->uuid),
             "%08x-%04x-%04x-%04x-%012llx",
             (uint32_t)os_gettime_ns(),
             (uint16_t)(uintptr_t)ctx >> 16,
             (uint16_t)(uintptr_t)ctx,
             (uint16_t)(os_gettime_ns() >> 32),
             (unsigned long long)(uintptr_t)ctx ^ (uintptr_t)output);

    blog(LOG_INFO, "[SOLink] Output created: '%s' uuid=%s",
         ctx->server_name, ctx->uuid);
    return ctx;
}

static void solink_output_destroy(void *data)
{
    solink_output_t *ctx = data;
    if (!ctx) return;

    if (ctx->active) {
        obs_remove_main_render_callback(render_callback, ctx);
        ctx->active = false;
    }
    if (ctx->shm) {
        solink_shm_destroy(ctx->shm);
        ctx->shm = NULL;
    }
    if (ctx->pool) {
        solink_pool_destroy(ctx->pool);
        ctx->pool = NULL;
    }
    blog(LOG_INFO, "[SOLink] Output destroyed: '%s'", ctx->server_name);
    bfree(ctx);
}

static bool solink_output_start(void *data)
{
    solink_output_t *ctx = data;

    // Get current OBS canvas size
    struct obs_video_info ovi;
    if (!obs_get_video_info(&ovi)) {
        blog(LOG_ERROR, "[SOLink] Could not get OBS video info");
        return false;
    }
    ctx->width  = ovi.output_width;
    ctx->height = ovi.output_height;

    blog(LOG_INFO, "[SOLink] Starting — %ux%u", ctx->width, ctx->height);

    // 1. Create IOSurface triple buffer
    ctx->pool = solink_pool_create(ctx->width, ctx->height,
                                   SOLINK_PIXEL_FORMAT_BGRA8);
    if (!ctx->pool) {
        blog(LOG_ERROR, "[SOLink] Failed to create surface pool");
        return false;
    }

    // 2. Open shared memory
    char shm_name[SOLINK_SHM_NAME_MAX];
    solink_shm_name(ctx->uuid, shm_name);

    ctx->shm = solink_shm_create(shm_name, ctx->pool, ctx->width, ctx->height,
                                  SOLINK_PIXEL_FORMAT_BGRA8,
                                  ctx->server_name, "OBS");
    if (!ctx->shm) {
        blog(LOG_ERROR, "[SOLink] Failed to create shared memory");
        solink_pool_destroy(ctx->pool);
        ctx->pool = NULL;
        return false;
    }

    // 3. Register render callback
    obs_add_main_render_callback(render_callback, ctx);
    ctx->active = true;

    // 4. Announce on NSDistributedNotificationCenter
    solink_discovery_announce(ctx->uuid, ctx->server_name, "OBS",
                               shm_name, ctx->width, ctx->height,
                               SOLINK_PIXEL_FORMAT_BGRA8);

    blog(LOG_INFO, "[SOLink] Started — shm: %s", shm_name);
    obs_output_begin_data_capture(ctx->output, 0);
    return true;
}

static void solink_output_stop(void *data, uint64_t ts)
{
    (void)ts;
    solink_output_t *ctx = data;

    obs_remove_main_render_callback(render_callback, ctx);
    ctx->active = false;

    solink_discovery_retire(ctx->uuid);

    if (ctx->shm) {
        solink_shm_destroy(ctx->shm);
        ctx->shm = NULL;
    }
    if (ctx->pool) {
        solink_pool_destroy(ctx->pool);
        ctx->pool = NULL;
    }

    obs_output_end_data_capture(ctx->output);
    blog(LOG_INFO, "[SOLink] Stopped: '%s'", ctx->server_name);
}

// ─── Properties (OBS Settings UI) ───────────────────────────────────────────

static obs_properties_t *solink_output_get_properties(void *data)
{
    (void)data;
    obs_properties_t *props = obs_properties_create();
    obs_properties_add_text(props, "server_name",
                            "Server Name", OBS_TEXT_DEFAULT);
    return props;
}

static void solink_output_get_defaults(obs_data_t *settings)
{
    obs_data_set_default_string(settings, "server_name", "OBS Main");
}

// ─── Registration ─────────────────────────────────────────────────────────────

static struct obs_output_info solink_output_info = {
    .id             = "solink_output",
    .flags          = 0,   // raw video/audio not needed — we use render callback
    .get_name       = solink_output_get_name,
    .create         = solink_output_create,
    .destroy        = solink_output_destroy,
    .start          = solink_output_start,
    .stop           = solink_output_stop,
    .get_properties = solink_output_get_properties,
    .get_defaults   = solink_output_get_defaults,
};

void solink_output_register(void)
{
    obs_register_output(&solink_output_info);
}
