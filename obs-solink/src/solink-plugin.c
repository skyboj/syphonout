/*
 solink-plugin.c — OBS module entry points
 ==========================================
 Auto-starts the SOLink output once OBS finishes loading
 (OBS_FRONTEND_EVENT_FINISHED_LOADING), so it's active without
 user interaction. The output stays running until OBS exits.
*/

#include <obs-module.h>
#include "obs-frontend-api.h"

#include "solink-output.h"
#include "solink-discovery.h"

OBS_DECLARE_MODULE()
OBS_MODULE_USE_DEFAULT_LOCALE("obs-solink", "en-US")

MODULE_EXPORT const char *obs_module_description(void)
{
    return "SOLink — zero-copy IOSurface video output for SyphonOut";
}

// ─── Auto-managed output ─────────────────────────────────────────────────────

static obs_output_t *g_solink_output = NULL;

static void frontend_event_cb(enum obs_frontend_event event, void *data)
{
    (void)data;

    switch (event) {
    case OBS_FRONTEND_EVENT_FINISHED_LOADING:
        // OBS is fully initialised — safe to create and start the output.
        blog(LOG_INFO, "[SOLink] OBS finished loading — starting SOLink output");

        if (g_solink_output) {
            blog(LOG_WARNING, "[SOLink] Output already exists, skipping");
            break;
        }

        {
            obs_data_t *settings = obs_data_create();
            obs_data_set_string(settings, "server_name", "OBS Main");

            g_solink_output = obs_output_create(
                "solink_output", "SOLink Main Output", settings, NULL);
            obs_data_release(settings);

            if (!g_solink_output) {
                blog(LOG_ERROR, "[SOLink] obs_output_create failed");
                break;
            }

            if (obs_output_start(g_solink_output)) {
                blog(LOG_INFO, "[SOLink] Output started successfully");
            } else {
                blog(LOG_ERROR, "[SOLink] obs_output_start failed");
            }
        }
        break;

    case OBS_FRONTEND_EVENT_EXIT:
        // OBS is shutting down — stop and destroy the output cleanly.
        blog(LOG_INFO, "[SOLink] OBS exiting — stopping output");
        if (g_solink_output) {
            obs_output_stop(g_solink_output);
            obs_output_release(g_solink_output);
            g_solink_output = NULL;
        }
        break;

    default:
        break;
    }
}

// ─── Module lifecycle ────────────────────────────────────────────────────────

bool obs_module_load(void)
{
    blog(LOG_INFO, "[SOLink] Loading obs-solink v1.0");

    solink_output_register();
    solink_discovery_init();

    // Will be called once OBS UI is ready
    obs_frontend_add_event_callback(frontend_event_cb, NULL);

    blog(LOG_INFO, "[SOLink] Registered — waiting for OBS_FRONTEND_EVENT_FINISHED_LOADING");
    return true;
}

void obs_module_unload(void)
{
    blog(LOG_INFO, "[SOLink] Unloading");

    obs_frontend_remove_event_callback(frontend_event_cb, NULL);

    if (g_solink_output) {
        obs_output_stop(g_solink_output);
        obs_output_release(g_solink_output);
        g_solink_output = NULL;
    }

    solink_discovery_deinit();
}
