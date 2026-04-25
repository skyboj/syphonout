/*
 solink-output.h — OBS output type declaration and stream management API
*/
#pragma once

#include <obs-module.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Register the "solink_output" output type with OBS.
/// Called once from obs_module_load().
void solink_output_register(void);

/// Create and start a named SOLink output with the specified source.
/// @p stream_name: human-readable name (used as the SOLink server name)
/// @p source_type: 0=main output, 1=preview, 2=scene by name, 3=source by name
/// @p source_name: scene/source name (pass NULL or "" for main/preview)
/// Returns the obs_output_t (caller holds one reference). NULL on failure.
obs_output_t *solink_output_create_stream(const char *stream_name,
                                           int         source_type,
                                           const char *source_name);

#ifdef __cplusplus
}
#endif
