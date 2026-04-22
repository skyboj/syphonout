/*
 solink-output.c — OBS output implementation
 =============================================
 Hooks into OBS main render loop via obs_add_main_render_callback().
 Each frame: blit OBS scene → IOSurface-backed texture → atomic publish.

 Bug fixes vs Phase 1:
   • Track write index in ctx (not pool) — pool was never advancing
   • UUID via CFUUIDCreate (CoreFoundation, no rand() hack)
   • obs_output_begin_data_capture return value checked
   • #include <stdio.h><string.h> for snprintf/bzalloc
*/

#include <stdio.h>
#include <string.h>

#include <obs-module.h>
#include <obs.h>
#include <graphics/graphics.h>
#include <util/platform.h>

// CoreFoundation for CFUUIDCreate
#include <CoreFoundation/CoreFoundation.h>

#include "solink-output.h"
#include "solink-surface-pool.h"
#include "solink-shm.h"
#include "solink-discovery.h"
#include "solink-protocol.h"

// ─── Output context ──────────────────────────────────────────────────────────

typedef struct solink_output {
    obs_output_t          *output;
    solink_surface_pool_t *pool;
    solink_shm_t          *shm;

    char      uuid[64];
    char      server_name[32];
    char      shm_name[SOLINK_SHM_NAME_MAX];

    uint32_t  width;
    uint32_t  height;

    // Triple-buffer write rotation tracked here (not in pool).
    // last_write_idx = slot subscriber is currently reading.
    // Next write goes into (last_write_idx + 1) % SOLINK_BUFFER_COUNT.
    uint32_t  last_write_idx;

    bool      active;
} solink_output_t;

// ─── UUID via CoreFoundation ─────────────────────────────────────────────────

static void generate_uuid(char *out, size_t len)
{
    CFUUIDRef   uuid_ref = CFUUIDCreate(kCFAllocatorDefault);
    CFStringRef uuid_str = CFUUIDCreateString(kCFAllocatorDefault, uuid_ref);
    CFStringGetCString(uuid_str, out, (CFIndex)len, kCFStringEncodingUTF8);
    CFRelease(uuid_str);
    CFRelease(uuid_ref);
}

// ─── Render callback (OBS graphics thread) ───────────────────────────────────

static void render_callback(void *param, uint32_t cx, uint32_t cy)
{
    (void)cx; (void)cy;
    solink_output_t *ctx = param;
    if (!ctx->active || !ctx->pool || !ctx->shm) return;

    // Next slot in round-robin (never the one subscriber just read)
    uint32_t next_idx = (ctx->last_write_idx + 1) % SOLINK_BUFFER_COUNT;
    gs_texture_t *target = solink_pool_texture(ctx->pool, next_idx);
    if (!target) return;

    // Save and reset OBS blend state so our blit doesn't affect main output
    gs_blend_state_push();
    gs_reset_blend_state();

    // Render OBS composite into our IOSurface-backed texture
    gs_set_render_target(target, NULL);
    // NOTE: device_clear dereferences the vec4 even when only GS_CLEAR_COLOR is
    // set — passing NULL here causes the SIGSEGV we saw in libobs-opengl.
    struct vec4 black = {0};
    gs_clear(GS_CLEAR_COLOR, &black, 0.0f, 0);
    gs_ortho(0.0f, (float)ctx->width,
             0.0f, (float)ctx->height,
             -100.0f, 100.0f);
    obs_render_main_texture();

    gs_set_render_target(NULL, NULL);
    gs_blend_state_pop();

    // Copy rendered pixels from render target → IOSurface
    solink_pool_copy_to_iosurface(ctx->pool, next_idx);

    // Atomically publish the completed frame
    solink_shm_publish_frame(ctx->shm, next_idx);
    ctx->last_write_idx = next_idx;
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
    ctx->last_write_idx = 0;

    const char *name = obs_data_get_string(settings, "server_name");
    snprintf(ctx->server_name, sizeof(ctx->server_name),
             "%s", (name && *name) ? name : "OBS Main");

    generate_uuid(ctx->uuid, sizeof(ctx->uuid));
    solink_shm_name(ctx->uuid, ctx->shm_name);

    blog(LOG_INFO, "[SOLink] Output created — name='%s' uuid=%s",
         ctx->server_name, ctx->uuid);
    return ctx;
}

static void solink_output_destroy(void *data)
{
    solink_output_t *ctx = data;
    if (!ctx) return;

    if (ctx->active) {
        obs_remove_main_render_callback(render_callback, ctx);
        solink_discovery_retire(ctx->uuid);
        ctx->active = false;
    }
    if (ctx->shm)  { solink_shm_destroy(ctx->shm);   ctx->shm  = NULL; }
    if (ctx->pool) { solink_pool_destroy(ctx->pool);  ctx->pool = NULL; }

    blog(LOG_INFO, "[SOLink] Output destroyed — '%s'", ctx->server_name);
    bfree(ctx);
}

static bool solink_output_start(void *data)
{
    solink_output_t *ctx = data;

    struct obs_video_info ovi;
    if (!obs_get_video_info(&ovi)) {
        blog(LOG_WARNING, "[SOLink] OBS video not ready yet — will retry");
        return false;
    }
    ctx->width  = ovi.output_width;
    ctx->height = ovi.output_height;

    blog(LOG_INFO, "[SOLink] Starting — %ux%u server='%s'",
         ctx->width, ctx->height, ctx->server_name);

    // 1. IOSurface triple buffer (gs_* calls require graphics context)
    ctx->pool = solink_pool_create(ctx->width, ctx->height,
                                   SOLINK_PIXEL_FORMAT_BGRA8);
    if (!ctx->pool) {
        blog(LOG_ERROR, "[SOLink] Failed to create surface pool");
        return false;
    }

    // 2. Shared memory region
    ctx->shm = solink_shm_create(ctx->shm_name, ctx->pool,
                                  ctx->width, ctx->height,
                                  SOLINK_PIXEL_FORMAT_BGRA8,
                                  ctx->server_name, "OBS");
    if (!ctx->shm) {
        blog(LOG_ERROR, "[SOLink] Failed to open shared memory");
        solink_pool_destroy(ctx->pool);
        ctx->pool = NULL;
        return false;
    }

    // 3. Hook into OBS main render loop
    obs_add_main_render_callback(render_callback, ctx);
    ctx->active = true;

    // 4. Announce to subscribers
    solink_discovery_announce(ctx->uuid, ctx->server_name, "OBS",
                               ctx->shm_name,
                               ctx->width, ctx->height,
                               SOLINK_PIXEL_FORMAT_BGRA8);

    blog(LOG_INFO, "[SOLink] Started — shm=%s", ctx->shm_name);

    if (!obs_output_begin_data_capture(ctx->output, 0)) {
        blog(LOG_WARNING, "[SOLink] obs_output_begin_data_capture returned false "
                          "(no video configured?) — render callback still active");
    }
    return true;
}

static void solink_output_stop(void *data, uint64_t ts)
{
    (void)ts;
    solink_output_t *ctx = data;

    obs_remove_main_render_callback(render_callback, ctx);
    ctx->active = false;

    solink_discovery_retire(ctx->uuid);

    if (ctx->shm)  { solink_shm_destroy(ctx->shm);   ctx->shm  = NULL; }
    if (ctx->pool) { solink_pool_destroy(ctx->pool);  ctx->pool = NULL; }

    obs_output_end_data_capture(ctx->output);
    blog(LOG_INFO, "[SOLink] Stopped — '%s'", ctx->server_name);
}

// ─── Properties ───────────────────────────────────────────────────────────────

static obs_properties_t *solink_output_get_properties(void *data)
{
    (void)data;
    obs_properties_t *props = obs_properties_create();
    obs_properties_add_text(props, "server_name", "Server Name", OBS_TEXT_DEFAULT);
    return props;
}

static void solink_output_get_defaults(obs_data_t *settings)
{
    obs_data_set_default_string(settings, "server_name", "OBS Main");
}

// ─── Registration ─────────────────────────────────────────────────────────────

static struct obs_output_info solink_output_info = {
    .id             = "solink_output",
    .flags          = 0,
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
