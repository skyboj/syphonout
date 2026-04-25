/*
 obs-frontend-api.h — minimal subset needed by obs-solink
 Sourced from obs-studio/UI/obs-frontend-api/obs-frontend-api.h (tag 32.1.1)
*/
#pragma once
#include <obs-module.h>

#ifdef __cplusplus
extern "C" {
#endif

enum obs_frontend_event {
    OBS_FRONTEND_EVENT_STREAMING_STARTING,
    OBS_FRONTEND_EVENT_STREAMING_STARTED,
    OBS_FRONTEND_EVENT_STREAMING_STOPPING,
    OBS_FRONTEND_EVENT_STREAMING_STOPPED,
    OBS_FRONTEND_EVENT_RECORDING_STARTING,
    OBS_FRONTEND_EVENT_RECORDING_STARTED,
    OBS_FRONTEND_EVENT_RECORDING_STOPPING,
    OBS_FRONTEND_EVENT_RECORDING_STOPPED,
    OBS_FRONTEND_EVENT_SCENE_CHANGED,
    OBS_FRONTEND_EVENT_SCENE_LIST_CHANGED,
    OBS_FRONTEND_EVENT_TRANSITION_CHANGED,
    OBS_FRONTEND_EVENT_TRANSITION_STOPPED,
    OBS_FRONTEND_EVENT_TRANSITION_LIST_CHANGED,
    OBS_FRONTEND_EVENT_SCENE_COLLECTION_CHANGED,
    OBS_FRONTEND_EVENT_SCENE_COLLECTION_LIST_CHANGED,
    OBS_FRONTEND_EVENT_PROFILE_CHANGED,
    OBS_FRONTEND_EVENT_PROFILE_LIST_CHANGED,
    OBS_FRONTEND_EVENT_EXIT,
    OBS_FRONTEND_EVENT_REPLAY_BUFFER_STARTING,
    OBS_FRONTEND_EVENT_REPLAY_BUFFER_STARTED,
    OBS_FRONTEND_EVENT_REPLAY_BUFFER_STOPPING,
    OBS_FRONTEND_EVENT_REPLAY_BUFFER_STOPPED,
    OBS_FRONTEND_EVENT_STUDIO_MODE_ENABLED,
    OBS_FRONTEND_EVENT_STUDIO_MODE_DISABLED,
    OBS_FRONTEND_EVENT_PREVIEW_SCENE_CHANGED,
    OBS_FRONTEND_EVENT_SCENE_COLLECTION_CLEANUP,
    OBS_FRONTEND_EVENT_FINISHED_LOADING,
    OBS_FRONTEND_EVENT_RECORDING_PAUSED,
    OBS_FRONTEND_EVENT_RECORDING_UNPAUSED,
    OBS_FRONTEND_EVENT_VIRTUAL_CAM_STARTED,
    OBS_FRONTEND_EVENT_VIRTUAL_CAM_STOPPED,
    OBS_FRONTEND_EVENT_TBAR_VALUE_CHANGED,
    OBS_FRONTEND_EVENT_SCENE_COLLECTION_CHANGING,
    OBS_FRONTEND_EVENT_PROFILE_CHANGING,
    OBS_FRONTEND_EVENT_SCRIPTING_SHUTDOWN,
    OBS_FRONTEND_EVENT_PROFILE_RENAMED,
    OBS_FRONTEND_EVENT_SCENE_COLLECTION_RENAMED,
    OBS_FRONTEND_EVENT_THEME_CHANGED,
    OBS_FRONTEND_EVENT_SCREENSHOT_TAKEN,
};

typedef void (*obs_frontend_cb)(enum obs_frontend_event event, void *private_data);
typedef void (*obs_frontend_menu_cb)(void *private_data);

struct obs_frontend_source_list {
    DARRAY(obs_source_t *) sources;
};

static inline void obs_frontend_source_list_free(struct obs_frontend_source_list *source_list)
{
    size_t i;
    for (i = 0; i < source_list->sources.num; i++)
        obs_source_release(source_list->sources.array[i]);
    da_free(source_list->sources);
}

EXPORT void obs_frontend_add_event_callback(obs_frontend_cb callback, void *private_data);
EXPORT void obs_frontend_remove_event_callback(obs_frontend_cb callback, void *private_data);

EXPORT void obs_frontend_add_tools_menu_item(const char *name,
                                              obs_frontend_menu_cb callback,
                                              void *private_data);

EXPORT void obs_frontend_get_scenes(struct obs_frontend_source_list *sources);

EXPORT obs_source_t *obs_frontend_get_current_scene(void);
EXPORT obs_source_t *obs_frontend_get_current_preview_scene(void);

#ifdef __cplusplus
}
#endif
