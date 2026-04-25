/*
 solink-streams-ui.h — OBS Tools menu UI bridge
*/
#pragma once

#include <obs-module.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Callback for obs_frontend_add_tools_menu_item — shows the streams panel.
void solink_streams_ui_show(void *unused);

/// Register the initial auto-started stream in the UI stream list.
void solink_streams_ui_add_initial_stream(const char *name, obs_output_t *output);

/// Stop all managed streams (called from obs_module_unload).
void solink_streams_ui_stop_all(void);

#ifdef __cplusplus
}
#endif
