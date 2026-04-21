/*
 solink-output.h — OBS output type declaration
*/
#pragma once

#ifdef __cplusplus
extern "C" {
#endif

/// Register the "solink_output" output type with OBS.
/// Called once from obs_module_load().
void solink_output_register(void);

#ifdef __cplusplus
}
#endif
