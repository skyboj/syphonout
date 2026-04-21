/*
 solink-plugin.c — OBS module entry points
 ==========================================
 Registers the SOLink output type with OBS.
 obs_module_load() is called once when OBS loads the plugin.
*/

#include <obs-module.h>
#include "solink-output.h"
#include "solink-discovery.h"

OBS_DECLARE_MODULE()
OBS_MODULE_USE_DEFAULT_LOCALE("obs-solink", "en-US")

MODULE_EXPORT const char *obs_module_description(void)
{
    return "SOLink — zero-copy IOSurface video output for SyphonOut";
}

bool obs_module_load(void)
{
    blog(LOG_INFO, "[SOLink] Loading obs-solink v1.0");

    // Register the output type
    solink_output_register();

    // Start the discovery layer (NSDistributedNotificationCenter listener)
    solink_discovery_init();

    blog(LOG_INFO, "[SOLink] Ready");
    return true;
}

void obs_module_unload(void)
{
    blog(LOG_INFO, "[SOLink] Unloading");
    solink_discovery_deinit();
}
