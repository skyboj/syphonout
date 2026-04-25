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
#include "solink-streams-ui.h"

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

        g_solink_output = solink_output_create_stream("OBS Main", 0, "");
        if (g_solink_output) {
            blog(LOG_INFO, "[SOLink] Default stream started");
            solink_streams_ui_add_initial_stream("OBS Main", g_solink_output);
        }
        break;

    case OBS_FRONTEND_EVENT_EXIT:
        // OBS is shutting down — stop all streams cleanly.
        blog(LOG_INFO, "[SOLink] OBS exiting — stopping all streams");
        solink_streams_ui_stop_all();
        if (g_solink_output) {
            // Already stopped by stop_all, just clear the reference
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

    // Add "SOLink Streams…" to OBS Tools menu
    obs_frontend_add_tools_menu_item("SOLink Streams…", solink_streams_ui_show, NULL);

    blog(LOG_INFO, "[SOLink] Registered — waiting for OBS_FRONTEND_EVENT_FINISHED_LOADING");
    return true;
}

void obs_module_unload(void)
{
    blog(LOG_INFO, "[SOLink] Unloading");

    obs_frontend_remove_event_callback(frontend_event_cb, NULL);
    solink_discovery_deinit();
}
