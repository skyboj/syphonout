/*
 solink-output.c — OBS output implementation
 =============================================
 Hooks into OBS main render loop via obs_add_main_render_callback().
 Each frame: blit OBS scene → gs_texrender → stage → IOSurface → atomic publish.

 Key design: gs_texrender_t instead of manual gs_set_render_target().
   obs_add_main_render_callback fires while OBS has its own render target set.
   Manually calling gs_set_render_target + restoring to NULL corrupts OBS's
   render pipeline (OBS continues rendering to NULL instead of its output texture),
   causing the OBS preview/output to show a black screen.

   gs_texrender_begin/end saves and restores the PREVIOUS render target properly,
   which is the canonical OBS pattern for off-screen capture (obs-syphon, NDI, etc).
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
#include "../include/obs-frontend-api.h"

// ─── Output context ──────────────────────────────────────────────────────────

// ─── Source type ─────────────────────────────────────────────────────────────

/// What OBS content this output captures.
typedef enum {
    SOLINK_SOURCE_MAIN_OUTPUT = 0,  ///< OBS program output (default)
    SOLINK_SOURCE_PREVIEW     = 1,  ///< OBS preview (Studio Mode)
    SOLINK_SOURCE_SCENE       = 2,  ///< A specific named scene
    SOLINK_SOURCE_SOURCE      = 3,  ///< A specific named source
} solink_source_type_t;

typedef struct solink_output {
    obs_output_t          *output;
    solink_surface_pool_t *pool;
    solink_shm_t          *shm;

    char      uuid[64];
    char      server_name[64];
    char      shm_name[SOLINK_SHM_NAME_MAX];

    uint32_t  width;
    uint32_t  height;

    // Source selection — what to capture
    solink_source_type_t source_type;
    char                 source_name[256];  // scene/source name when applicable

    // Triple-buffer write rotation tracked here.
    // Next write goes into (last_write_idx + 1) % SOLINK_BUFFER_COUNT.
    uint32_t  last_write_idx;

    // One gs_texrender_t per buffer slot — used for safe off-screen rendering.
    // gs_texrender_begin/end saves and restores OBS's active render target,
    // preventing corruption of OBS's own compositing pipeline.
    gs_texrender_t *texrenders[SOLINK_BUFFER_COUNT];

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

    // Next slot in round-robin (never the one subscriber is currently reading).
    uint32_t next_idx = (ctx->last_write_idx + 1) % SOLINK_BUFFER_COUNT;
    gs_texrender_t *tr = ctx->texrenders[next_idx];
    if (!tr) return;

    // ── Off-screen render via gs_texrender ───────────────────────────────────
    // gs_texrender_begin saves the current OBS render target (OBS's own output
    // texture) and sets ours. gs_texrender_end restores it — no state corruption.
    gs_texrender_reset(tr);
    if (!gs_texrender_begin(tr, ctx->width, ctx->height)) return;

    struct vec4 black = {0};
    gs_clear(GS_CLEAR_COLOR, &black, 0.0f, 0);
    gs_ortho(0.0f, (float)ctx->width,
             0.0f, (float)ctx->height,
             -100.0f, 100.0f);
    gs_blend_state_push();
    gs_reset_blend_state();

    switch (ctx->source_type) {
    case SOLINK_SOURCE_MAIN_OUTPUT:
        obs_render_main_texture();
        break;

    case SOLINK_SOURCE_PREVIEW: {
        obs_source_t *preview = obs_frontend_get_current_preview_scene();
        if (preview) {
            obs_source_video_render(preview);
            obs_source_release(preview);
        } else {
            // Fallback: show program output when not in Studio Mode
            obs_render_main_texture();
        }
        break;
    }

    case SOLINK_SOURCE_SCENE:
    case SOLINK_SOURCE_SOURCE: {
        obs_source_t *src = obs_get_source_by_name(ctx->source_name);
        if (src) {
            obs_source_video_render(src);
            obs_source_release(src);
        }
        break;
    }

    default:
        obs_render_main_texture();
        break;
    }

    gs_blend_state_pop();

    gs_texrender_end(tr);  // ← restores OBS's render target automatically

    // ── Copy rendered texture → IOSurface ────────────────────────────────────
    gs_texture_t *tex = gs_texrender_get_texture(tr);
    solink_pool_copy_to_iosurface(ctx->pool, next_idx, tex);

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

    ctx->source_type = (solink_source_type_t)obs_data_get_int(settings, "source_type");
    const char *src_name = obs_data_get_string(settings, "source_name");
    if (src_name) snprintf(ctx->source_name, sizeof(ctx->source_name), "%s", src_name);

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

    obs_enter_graphics();
    for (uint32_t i = 0; i < SOLINK_BUFFER_COUNT; i++) {
        if (ctx->texrenders[i]) {
            gs_texrender_destroy(ctx->texrenders[i]);
            ctx->texrenders[i] = NULL;
        }
    }
    obs_leave_graphics();

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

    // 1. gs_texrender_t per buffer slot (must be created on graphics thread)
    obs_enter_graphics();
    for (uint32_t i = 0; i < SOLINK_BUFFER_COUNT; i++) {
        ctx->texrenders[i] = gs_texrender_create(GS_BGRA, GS_ZS_NONE);
        if (!ctx->texrenders[i]) {
            obs_leave_graphics();
            blog(LOG_ERROR, "[SOLink] gs_texrender_create failed for slot %u", i);
            return false;
        }
    }
    obs_leave_graphics();

    // 2. IOSurface triple buffer + stage surfaces (gs_* calls require graphics context)
    ctx->pool = solink_pool_create(ctx->width, ctx->height,
                                   SOLINK_PIXEL_FORMAT_BGRA8);
    if (!ctx->pool) {
        blog(LOG_ERROR, "[SOLink] Failed to create surface pool");
        obs_enter_graphics();
        for (uint32_t i = 0; i < SOLINK_BUFFER_COUNT; i++) {
            if (ctx->texrenders[i]) {
                gs_texrender_destroy(ctx->texrenders[i]);
                ctx->texrenders[i] = NULL;
            }
        }
        obs_leave_graphics();
        return false;
    }

    // 3. Shared memory region
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

    // 4. Hook into OBS main render loop
    obs_add_main_render_callback(render_callback, ctx);
    ctx->active = true;

    // 5. Announce to subscribers
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
    obs_data_set_default_int(settings, "source_type", SOLINK_SOURCE_MAIN_OUTPUT);
    obs_data_set_default_string(settings, "source_name", "");
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

// ─── Public stream management API ────────────────────────────────────────────

/// Create and start a named SOLink output with the specified source.
/// @p source_type: 0=main output, 1=preview, 2=scene, 3=source
/// @p source_name: scene/source name (ignored for main/preview)
/// Returns the obs_output_t (caller owns one reference). NULL on failure.
obs_output_t *solink_output_create_stream(const char *stream_name,
                                           int         source_type,
                                           const char *source_name)
{
    obs_data_t *settings = obs_data_create();
    obs_data_set_string(settings, "server_name", stream_name ? stream_name : "OBS");
    obs_data_set_int(settings, "source_type", source_type);
    obs_data_set_string(settings, "source_name", source_name ? source_name : "");

    obs_output_t *output = obs_output_create(
        "solink_output", stream_name ? stream_name : "SOLink", settings, NULL);
    obs_data_release(settings);

    if (!output) {
        blog(LOG_ERROR, "[SOLink] obs_output_create failed for stream '%s'", stream_name);
        return NULL;
    }

    if (!obs_output_start(output)) {
        blog(LOG_ERROR, "[SOLink] obs_output_start failed for stream '%s'", stream_name);
        obs_output_release(output);
        return NULL;
    }

    blog(LOG_INFO, "[SOLink] Stream '%s' created (source_type=%d, source='%s')",
         stream_name, source_type, source_name ? source_name : "");
    return output;
}
