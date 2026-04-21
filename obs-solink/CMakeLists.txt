cmake_minimum_required(VERSION 3.22)
project(obs-solink VERSION 1.0.0 LANGUAGES C OBJC)

# ─── macOS-only ───────────────────────────────────────────────────────────────
if(NOT APPLE)
    message(FATAL_ERROR "obs-solink is macOS-only (IOSurface + Metal + NSDistributedNotificationCenter)")
endif()

# ─── OBS paths ────────────────────────────────────────────────────────────────
set(OBS_APP_PATH "/Applications/OBS.app" CACHE PATH "Path to OBS.app")
set(OBS_SOURCE_PATH "${CMAKE_CURRENT_SOURCE_DIR}/../obs-solink-deps/obs-studio"
    CACHE PATH "Path to OBS source (for headers)")

# Support both in-tree and standalone builds
if(IS_DIRECTORY "${OBS_SOURCE_PATH}/libobs")
    set(OBS_INCLUDE_DIR "${OBS_SOURCE_PATH}/libobs")
    message(STATUS "OBS headers: ${OBS_INCLUDE_DIR}")
elseif(IS_DIRECTORY "$ENV{HOME}/Developer/obs-studio-headers/libobs")
    set(OBS_INCLUDE_DIR "$ENV{HOME}/Developer/obs-studio-headers/libobs")
    message(STATUS "OBS headers (fallback): ${OBS_INCLUDE_DIR}")
else()
    message(FATAL_ERROR
        "OBS source headers not found. Clone OBS source:\n"
        "  git clone --depth 1 --branch 32.1.1 --sparse "
        "https://github.com/obsproject/obs-studio.git obs-studio-headers\n"
        "  cd obs-studio-headers && git sparse-checkout set libobs")
endif()

set(OBS_FRAMEWORKS_DIR "${OBS_APP_PATH}/Contents/Frameworks")
set(OBS_FRAMEWORK       "${OBS_FRAMEWORKS_DIR}/libobs.framework")

if(NOT EXISTS "${OBS_FRAMEWORK}")
    message(FATAL_ERROR "libobs.framework not found at ${OBS_FRAMEWORK}\nIs OBS installed?")
endif()

# ─── Target ───────────────────────────────────────────────────────────────────
add_library(obs-solink MODULE
    src/solink-plugin.c
    src/solink-output.c
    src/solink-surface-pool.m
    src/solink-shm.c
    src/solink-discovery.m
)

# ─── Headers ──────────────────────────────────────────────────────────────────
# Generate obsconfig.h stub (cmake-generated file, not in source tree)
set(OBSCONFIG_DIR "${CMAKE_BINARY_DIR}/libobs")
file(MAKE_DIRECTORY "${OBSCONFIG_DIR}")
file(WRITE "${OBSCONFIG_DIR}/obsconfig.h"
    "#pragma once\n"
    "/* Generated for obs-solink standalone plugin build */\n"
    "#define OBS_RELEASE_CANDIDATE 0\n"
    "#define OBS_BETA 0\n"
)

target_include_directories(obs-solink PRIVATE
    include
    src
    "${OBS_INCLUDE_DIR}"
    "${OBS_INCLUDE_DIR}/graphics"
    # obsconfig.h is cmake-generated — point to our stub
    "${OBSCONFIG_DIR}"
    # simde — cross-platform SIMD needed by OBS util/sse-intrin.h on arm64
    "/opt/homebrew/include"
    "/usr/local/include"
)

# ─── Link libobs from OBS.app ─────────────────────────────────────────────────
# Link as framework: -F .../Frameworks -framework libobs
target_compile_options(obs-solink PRIVATE
    "-F${OBS_FRAMEWORKS_DIR}"
)
target_link_options(obs-solink PRIVATE
    "-F${OBS_FRAMEWORKS_DIR}"
    "-framework" "libobs"
    # rpath so the binary finds libobs at runtime when loaded by OBS
    "-Wl,-rpath,@executable_path/../Frameworks"
    "-Wl,-rpath,${OBS_FRAMEWORKS_DIR}"      # for dev/testing outside OBS
)

# ─── System frameworks ────────────────────────────────────────────────────────
target_link_libraries(obs-solink PRIVATE
    "-framework Foundation"
    "-framework IOSurface"
    "-framework Metal"
    "-framework QuartzCore"
)

# ─── Compiler flags ───────────────────────────────────────────────────────────
target_compile_options(obs-solink PRIVATE
    -Wall
    -Wextra
    -Wno-unused-parameter
    -fvisibility=hidden
)

set_target_properties(obs-solink PROPERTIES
    C_STANDARD   11
    C_EXTENSIONS OFF
    OBJC_STANDARD 11
    # Apple bundle (.plugin)
    BUNDLE TRUE
    BUNDLE_EXTENSION plugin
    PREFIX ""
    # arm64 only (OBS 28+ dropped x86_64 on macOS)
    OSX_ARCHITECTURES "arm64"
    MACOSX_DEPLOYMENT_TARGET "12.0"
    # Bundle Info.plist
    MACOSX_BUNDLE_INFO_PLIST "${CMAKE_CURRENT_SOURCE_DIR}/cmake/MacOSXBundleInfo.plist.in"
    MACOSX_BUNDLE_BUNDLE_NAME "obs-solink"
    MACOSX_BUNDLE_BUNDLE_VERSION "${PROJECT_VERSION}"
    MACOSX_BUNDLE_SHORT_VERSION_STRING "${PROJECT_VERSION}"
    MACOSX_BUNDLE_IDENTIFIER "com.syphonout.obs-solink"
    MACOSX_BUNDLE_GUI_IDENTIFIER "com.syphonout.obs-solink"
    MACOSX_BUNDLE_EXECUTABLE_NAME "obs-solink"
)

# kIOSurfaceIsGlobal is deprecated since 10.11 but still works and is required for
# IOSurfaceLookup() cross-process access. Not in App Store → security concern N/A.
# Syphon.framework uses the same approach. Suppress for this file only.
set_source_files_properties(src/solink-surface-pool.m
    PROPERTIES COMPILE_OPTIONS "-Wno-deprecated-declarations")

# ─── Resources (locale) ───────────────────────────────────────────────────────
set_source_files_properties(data/locale/en-US.ini
    PROPERTIES MACOSX_PACKAGE_LOCATION Resources/locale)
target_sources(obs-solink PRIVATE data/locale/en-US.ini)

# ─── Install ──────────────────────────────────────────────────────────────────
set(OBS_USER_PLUGIN_DIR
    "$ENV{HOME}/Library/Application Support/obs-studio/plugins"
    CACHE PATH "OBS user plugin install directory")

install(TARGETS obs-solink
    BUNDLE  DESTINATION "${OBS_USER_PLUGIN_DIR}"
    LIBRARY DESTINATION "${OBS_USER_PLUGIN_DIR}")

message(STATUS "obs-solink ${PROJECT_VERSION}")
message(STATUS "  OBS app:      ${OBS_APP_PATH}")
message(STATUS "  OBS headers:  ${OBS_INCLUDE_DIR}")
message(STATUS "  Install to:   ${OBS_USER_PLUGIN_DIR}")
