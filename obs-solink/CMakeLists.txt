cmake_minimum_required(VERSION 3.22)
project(obs-solink VERSION 1.0.0 LANGUAGES C OBJC)

# ─── OBS dependency ───────────────────────────────────────────────────────────
# Supports two modes:
#   1. In-tree build (obs-solink placed inside obs-studio source tree)
#   2. Standalone build via find_package(libobs)
if(NOT TARGET OBS::libobs)
    find_package(libobs REQUIRED)
endif()

# ─── macOS-only ───────────────────────────────────────────────────────────────
if(NOT APPLE)
    message(FATAL_ERROR "obs-solink is macOS-only (uses IOSurface + Metal + NSDistributedNotificationCenter)")
endif()

# ─── Sources ──────────────────────────────────────────────────────────────────
add_library(obs-solink MODULE
    src/solink-plugin.c
    src/solink-output.c
    src/solink-surface-pool.m
    src/solink-shm.c
    src/solink-discovery.m
)

target_include_directories(obs-solink PRIVATE
    include
    ${CMAKE_CURRENT_SOURCE_DIR}/src
)

# ─── Frameworks ───────────────────────────────────────────────────────────────
target_link_libraries(obs-solink PRIVATE
    OBS::libobs
    "-framework Foundation"
    "-framework IOSurface"
    "-framework Metal"
    "-framework QuartzCore"
)

# ─── Compiler flags ───────────────────────────────────────────────────────────
target_compile_options(obs-solink PRIVATE
    -Wall
    -Wextra
    -Wno-unused-parameter        # OBS callbacks have many unused params
    -fvisibility=hidden          # Only export obs_module_* symbols
)

set_target_properties(obs-solink PROPERTIES
    C_STANDARD   11
    C_EXTENSIONS OFF
    # Plugin bundle: no lib prefix, .so suffix (OBS convention)
    PREFIX ""
    SUFFIX ".so"
    # Universal binary — matches OBS 28+ which ships arm64 + x86_64
    OSX_ARCHITECTURES "arm64;x86_64"
)

# ─── Install ──────────────────────────────────────────────────────────────────
# Installs into ~/Library/Application Support/obs-studio/plugins/obs-solink/
set(OBS_PLUGIN_INSTALL_DIR
    "$ENV{HOME}/Library/Application Support/obs-studio/plugins/obs-solink/bin/64bit"
    CACHE PATH "OBS user plugin directory")

install(TARGETS obs-solink
    LIBRARY DESTINATION "${OBS_PLUGIN_INSTALL_DIR}")

install(DIRECTORY data/
    DESTINATION
        "$ENV{HOME}/Library/Application Support/obs-studio/plugins/obs-solink/data")

# ─── Summary ──────────────────────────────────────────────────────────────────
message(STATUS "obs-solink ${PROJECT_VERSION} — install to ${OBS_PLUGIN_INSTALL_DIR}")
