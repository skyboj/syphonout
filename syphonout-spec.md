# SyphonOut — Functional Specification

## Overview

SyphonOut is a lightweight macOS menu bar application that receives Syphon video streams and outputs them to physical displays as exclusive fullscreen windows immune to Mission Control, Spaces switching, and trackpad gestures.

### Tech Stack

| Component | Technology |
|-----------|------------|
| Frontend | Swift 5.9 + AppKit + Combine |
| GPU Rendering | Metal (MTKView + fragment shaders) |
| Video Input | Syphon Framework (OpenGL-based, v5) |
| Bridge Layer | Objective-C (`SyphonBridge.m`) for CGL/OpenGL interop |
| Rust Core | Rust 2021 + `metal` crate + `objc2` (FFI-ready, experimental) |
| Build | Xcode project + Cargo (Rust) |

### Project Structure

```
syphonout/
├── SyphonOut/                    # Swift frontend (running implementation)
│   ├── App/                      # AppDelegate, Info.plist, entitlements
│   ├── MenuBar/                  # StatusBarController, MenuBuilder
│   ├── Output/                   # OutputController, OutputManager, OutputMode
│   ├── Metal/                    # MetalRenderer.swift, Shaders.metal
│   ├── Syphon/                   # SyphonBridge.m/h, SyphonClientWrapper
│   ├── Bridging/                 # syphonout_core.h (Rust FFI header, unused)
│   └── Preferences/              # PreferencesStore, PreferencesWindowController
├── core/                         # Rust core library (FFI-ready, not integrated)
│   ├── src/
│   │   ├── lib.rs                # FFI exports (C API)
│   │   ├── core.rs               # SyphonOutCore (global state)
│   │   ├── output.rs             # OutputCore (per-display)
│   │   ├── renderer.rs           # MetalRenderer (Rust)
│   │   ├── state.rs              # Enums: SyphonOutMode, SyphonOutIcon, etc.
│   │   └── syphon.rs             # SyphonRegistry (server list)
│   ├── Cargo.toml                # Rust dependencies: metal, objc2, parking_lot
│   ├── cbindgen.toml             # Header generation config
│   ├── build.rs                  # cbindgen pre-build hook
│   └── syphonout_core.h          # Generated C FFI header
├── Frameworks/Syphon.framework   # Syphon SDK v5 (MIT license)
├── SyphonOut.xcodeproj/          # Xcode project (generated or maintained)
└── project.yml                   # XcodeGen spec (optional project generation)
```

---

## Architecture

### Current Implementation (Swift + Obj-C)

```
OBS (obs-syphon plugin, Server mode)
        │
        │  Syphon protocol (GPU texture, zero-copy)
        ▼
┌─────────────────────────────────────────────────────────────┐
│  SyphonOut (menu bar app)                                   │
│                                                             │
│  ┌──────────────┐     ┌──────────────┐     ┌────────────┐  │
│  │ SyphonClient │────▶│ SyphonBridge │────▶│  Metal     │  │
│  │   Wrapper    │     │   (Obj-C)    │     │ Renderer   │  │
│  └──────────────┘     └──────────────┘     └─────┬──────┘  │
│        ▲                                         │         │
│        │                                         ▼         │
│  ┌──────────────┐                         ┌────────────┐   │
│  │   Syphon     │                         │   MTKView  │   │
│  │ Server Disc. │                         │  (display) │   │
│  └──────────────┘                         └────────────┘   │
│                                                             │
│  OutputManager ──▶ OutputController (one per display)       │
└─────────────────────────────────────────────────────────────┘
```

**Data Flow:**
1. `SyphonServerDiscovery` polls Syphon server directory via `NSDistributedNotificationCenter`
2. User selects a server → `OutputController` creates `SyphonClientWrapper`
3. `SyphonClientWrapper` → `SyphonBridge` (Obj-C) creates `SyphonClient` with CGL context
4. New frame callback → `glGetTexImage` reads pixels from `GL_TEXTURE_RECTANGLE_ARB`
5. CPU buffer uploaded to `MTLTexture` → `MetalRenderer.updateTexture()`
6. `MTKViewDelegate.draw()` renders via Metal pipeline (passthrough/crossfade/solid/test pattern)

### Rust Core Architecture (FFI-Ready, Not Integrated)

```
┌───────────────────────────────────────────────────────────────┐
│  Swift Frontend (future integration)                          │
│  - Creates CAMetalLayer per output                            │
│  - Calls FFI: syphonout_output_create(), syphonout_render_frame()
└───────────────────────┬───────────────────────────────────────┘
                        │ FFI (C API)
                        ▼
┌───────────────────────────────────────────────────────────────┐
│  Rust Core (libsyphonout_core.a)                              │
│                                                               │
│  ┌─────────────┐    ┌─────────────┐    ┌─────────────────┐   │
│  │ SyphonOut   │───▶│ OutputCore  │───▶│  MetalRenderer  │   │
│  │   Core      │    │ (per-display)    │  (metal crate)  │   │
│  └─────────────┘    └─────────────┘    └─────────────────┘   │
│         │                                                    │
│         ▼                                                    │
│  ┌─────────────┐                                             │
│  │ Syphon      │  ◀── callbacks from SyphonNative.m          │
│  │ Registry    │      (on_server_announced, on_new_frame)    │
│  └─────────────┘                                             │
└───────────────────────────────────────────────────────────────┘
```

**Rust Core Benefits (when integrated):**
- Memory safety without ARC overhead
- Crossfade/freeze logic in zero-cost abstractions
- Simpler FFI boundary for alternate frontends
- Potential for zero-copy IOSurface binding (vs current CPU readback)

---

## Core Problem

OBS Fullscreen Projector windows are managed by the macOS window compositor (Quartz). Any Mission Control gesture (4-finger swipe up, etc.) affects all displays including projection outputs, causing visual disruption during live events.

## Solution

SyphonOut renders each output via a borderless `NSWindow` at `NSScreenSaverWindowLevel` (level 2000), which sits above the Mission Control layer (~1500). The window is rendered via Metal directly to the display surface with zero compression, preserving full image fidelity.

---

## Display Outputs

Each physical display connected to the Mac is represented as an independent **Output** in SyphonOut.

### Per-Output State Machine

```swift
enum OutputMode: Equatable {
    case signal              // Live Syphon stream rendered to display
    case freeze              // Last received frame held; stream switches in background
    case blank(BlankOption)  // Solid color or test pattern (no Syphon required)
    case off                 // SyphonOut releases the display; system regains control
}

enum BlankOption: Equatable {
    case black
    case white
    case testPattern  // GPU-generated SMPTE EBU color bars
}
```

| Mode | Description |
|------|-------------|
| `signal` | Live Syphon stream rendered to display |
| `freeze` | Last received frame held; stream can be switched in background |
| `blank(.black/.white)` | Solid color fill (no Syphon required) |
| `blank(.testPattern)` | SMPTE EBU color bars generated on GPU |
| `off` | SyphonOut releases the display; system regains control |

---

## Menu Bar UI

The app lives exclusively in the menu bar (`LSUIElement: true` in Info.plist — no Dock icon).

### Menu Structure

```
● SyphonOut                          [app name + global status icon]
─────────────────────────────────────
  Display 1: HDMI — Projector        [display name]
    Mode:  ● Signal  ○ Freeze  ○ Blank  ○ Off
    Source: [Syphon Server dropdown ▼]
    Status: ✓ Signal present / ✗ No signal
  ─────────────────────────────────────
  Display 2: DisplayPort — Monitor
    Mode:  ○ Signal  ● Freeze  ○ Blank  ○ Off
    Source: [Syphon Server dropdown ▼]
    Status: ✓ Signal present
  ─────────────────────────────────────
  [ Mirror all outputs → Display 1 source ]
  ─────────────────────────────────────
  Preferences…
  Quit SyphonOut
```

### Menu Bar Icon States

| Icon | Meaning |
|------|---------|
| Solid circle ● | All active outputs have live signal |
| Half circle ◑ | At least one output has no signal or is frozen |
| Empty circle ○ | All outputs are blank or off |

---

## Signal Mode

- Syphon client connects to the selected server
- Frames are received via OpenGL (`GL_TEXTURE_RECTANGLE_ARB`)
- `SyphonBridge.m` reads pixels via `glGetTexImage` → CPU buffer → `MTLTexture`
- Metal renders each frame to the output window at native display resolution
- VSync enabled per display (`preferredFramesPerSecond = screen.maximumFramesPerSecond`)

### Source Switching (while in Signal mode)

1. User selects a new Syphon server from the dropdown
2. SyphonOut begins receiving from the new server
3. Crossfade transition: new frame alpha ramps from 0→1 over ~6 frames (~100ms at 60fps)
4. No intermediate blank frame, no compression artifacts
5. Transition is GPU-side (Metal blend), no CPU involvement

### Signal Status

Displayed per output in the menu:
- `✓ Signal present` — frames arriving from Syphon server
- `✗ No signal` — server listed but no frames arriving (server paused/crashed)
- `— No source selected` — no server assigned to this output

---

## Freeze Mode

1. User selects Freeze (or triggers via shortcut)
2. The last successfully rendered frame is retained in a Metal texture (`frozenTexture`)
3. That texture is held and re-presented every vsync (no flicker, no blank)
4. Syphon client **remains connected** in the background
5. User can switch Source in the menu — new server begins buffering
6. On exit from Freeze → Signal mode: crossfade from frozen frame to live stream

Use case: switch sources mid-show without audience seeing the transition.

---

## Blank Mode

Output shows a solid fill or test pattern. No Syphon connection required.

### Blank Options

| Option | Description |
|--------|-------------|
| Black | `RGB(0, 0, 0)` |
| White | `RGB(255, 255, 255)` |
| Test Pattern | SMPTE EBU color bars at output resolution (GPU-generated) |

Transition from any mode → Blank: crossfade over ~100ms.

**SMPTE Bars Shader:** `Shaders.metal::smpteBarsFragment`
- Top 2/3: 7 bars at 75% luminance (White, Yellow, Cyan, Green, Magenta, Red, Blue)
- Bottom 1/3: PLUGE (Picture Line-Up Generation Equipment) with -I, 100% White, +Q, and black/PLUGE zones

---

## Off Mode

- SyphonOut's Metal window on that display is hidden (`orderOut`)
- Display returns to normal macOS desktop behavior
- Syphon client for that output is disconnected

---

## Mirror Mode

A single toggle in the menu:

**`[ Mirror all outputs → [Source Name] ]`**

When enabled:
- All outputs are forced to the same Syphon server as the **primary output** (Display 1, or whichever is designated primary)
- Per-output source dropdowns are disabled
- Each output retains its own Mode (one can be frozen while another is live)
- Toggle off → each output returns to its individually assigned source

---

## Syphon Server Discovery

- `SyphonServerDiscovery` polls `SyphonServerDirectory` continuously
- Source dropdown shows all currently available servers by name
- If a previously selected server disappears (app closed), status shows `✗ No signal`
- When that server reappears, user must manually re-select (no auto-reconnect currently)

---

## Window Management

### NSWindow Configuration

```swift
let win = NSWindow(
    contentRect: screen.frame,
    styleMask: .borderless,
    backing: .buffered,
    defer: false,
    screen: screen
)
win.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.screenSaverWindow)))
win.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
win.isOpaque = true
win.backgroundColor = .black
```

### Result

| Behavior | Effect |
|----------|--------|
| Mission Control gesture | Does not affect output window |
| Spaces switching | Does not affect output window |
| App Exposé | Does not include output window |
| Cmd+Tab | Does not surface output window |
| Window is invisible to user workspace | Only display output is affected |

---

## Keyboard Shortcuts (Global)

| Action | Default |
|--------|---------|
| Freeze all outputs | `⌃⌥F` |
| Unfreeze all outputs | `⌃⌥U` |
| Blank all outputs (black) | `⌃⌥B` |
| Restore all outputs to Signal | `⌃⌥S` |

Shortcuts are configurable in Preferences via `PreferencesStore` (stored in `UserDefaults`).

---

## Preferences

- Launch at login toggle
- Primary display selection (for Mirror mode)
- Crossfade duration (50ms – 500ms, default 100ms)
- Global shortcut key assignments
- Per-output display name aliases (e.g., rename "Thunderbolt Display" → "Stage Left")

---

## Rust Core FFI API

The Rust core in `core/` exports a C-compatible API via `syphonout_core.h`. **Note:** This API is implemented but not currently integrated with the Swift frontend.

### Lifecycle

```c
void syphonout_core_init(void);           // Call once from AppDelegate
void syphonout_core_deinit(void);         // Call from applicationWillTerminate
```

### Output Management

```c
void syphonout_output_create(uint32_t display_id, void *ca_metal_layer_ptr);
void syphonout_output_destroy(uint32_t display_id);
void syphonout_output_set_mode(uint32_t display_id, enum SyphonOutMode mode);
void syphonout_output_set_server(uint32_t display_id, const char *server_uuid);
void syphonout_output_clear_server(uint32_t display_id);
```

### Render

```c
void syphonout_render_frame(uint32_t display_id);  // Call from CVDisplayLink callback
```

### Settings

```c
void syphonout_set_crossfade_duration_ms(double ms);
void syphonout_set_mirror(bool enabled, uint32_t primary_display_id);
```

### Server Discovery

```c
void syphonout_set_server_changed_callback(void (*callback)(void*), void *userdata);
void syphonout_get_servers(
    void (*callback)(const struct SyphonOutServerInfo*, uintptr_t, void*),
    void *userdata
);
```

### Status Queries

```c
enum SyphonOutIcon syphonout_get_icon_state(void);
enum SyphonOutSignal syphonout_get_signal_status(uint32_t display_id);
const char *syphonout_get_selected_server_name(uint32_t display_id);
```

### Syphon Events (called FROM Objective-C bridge)

```c
void syphonout_on_server_announced(const char *uuid, const char *name, const char *app_name);
void syphonout_on_server_retired(const char *uuid);
void syphonout_on_new_frame(uint32_t display_id, void *iosurface_ref, uint32_t width, uint32_t height);
```

### Rust Core Enums

```c
typedef enum SyphonOutMode {
    SYPHON_OUT_MODE_SIGNAL = 0,
    SYPHON_OUT_MODE_FREEZE = 1,
    SYPHON_OUT_MODE_BLANK_BLACK = 2,
    SYPHON_OUT_MODE_BLANK_WHITE = 3,
    SYPHON_OUT_MODE_BLANK_TEST_PATTERN = 4,
    SYPHON_OUT_MODE_OFF = 5,
} SyphonOutMode;

typedef enum SyphonOutIcon {
    SYPHON_OUT_ICON_SOLID = 0,   // ● All active outputs have live signal
    SYPHON_OUT_ICON_HALF = 1,    // ◑ At least one output frozen / no signal
    SYPHON_OUT_ICON_EMPTY = 2,   // ○ All outputs blank or off
} SyphonOutIcon;

typedef enum SyphonOutSignal {
    SYPHON_OUT_SIGNAL_PRESENT = 0,
    SYPHON_OUT_SIGNAL_NO_SIGNAL = 1,
    SYPHON_OUT_SIGNAL_NO_SOURCE_SELECTED = 2,
} SyphonOutSignal;

typedef struct SyphonOutServerInfo {
    const char *uuid;
    const char *name;
    const char *app_name;
} SyphonOutServerInfo;
```

---

## Metal Shaders (`Shaders.metal`)

### Vertex Shader
Full-screen quad (2 triangles). Flips Y coordinate because Metal UV origin is top-left, Syphon textures are bottom-left.

### Fragment Shaders

| Shader | Purpose |
|--------|---------|
| `passthroughFragment` | Direct texture sample to output |
| `crossfadeFragment` | Blend between previous and current texture with alpha |
| `solidColorFragment` | Fill with uniform color (blank mode) |
| `smpteBarsFragment` | Procedural SMPTE EBU test pattern |

---

## Build Instructions

### Prerequisites

- macOS 12.0+ (Monterey)
- Xcode 15+
- Rust toolchain (for core library)
- Syphon Framework v5 (included in `Frameworks/`)

### Build Swift Frontend (Running Implementation)

```bash
# Open Xcode project
open SyphonOut.xcodeproj

# Or generate from project.yml (if using XcodeGen)
xcodegen generate

# Build and run
Cmd+R in Xcode
```

Xcode project settings:
- `FRAMEWORK_SEARCH_PATHS`: `$(PROJECT_DIR)/Frameworks`
- `SWIFT_OBJC_BRIDGING_HEADER`: `SyphonOut/Syphon/SyphonOut-Bridging-Header.h`
- `GCC_WARN_ABOUT_DEPRECATED_FUNCTIONS`: NO (suppresses OpenGL deprecation warnings)

### Build Rust Core (Experimental)

```bash
cd core/

# Build static library
cargo build --release

# Generate FFI header (via build.rs hook)
cargo build  # Runs cbindgen automatically

# Output:
# - target/release/libsyphonout_core.a
# - syphonout_core.h (updated via cbindgen)
```

**Cargo.toml Dependencies:**
- `metal = "0.29"` — Metal GPU API
- `objc2 = "0.5"` — Objective-C runtime interop
- `parking_lot = "0.12"` — Thread-safe global state
- `libc = "0.2"` — C string utilities

### Integrating Rust Core (Future)

To integrate the Rust core with Swift:

1. Link `libsyphonout_core.a` in Xcode build phases
2. Add `$(SRCROOT)/core` to Header Search Paths
3. Import `syphonout_core.h` in bridging header
4. Replace `MetalRenderer.swift` calls with FFI:
   - `syphonout_core_init()` on app launch
   - `syphonout_output_create(displayID, metalLayer)` per output
   - `syphonout_render_frame(displayID)` in display link callback
5. Route Syphon events to Rust via `syphonout_on_server_announced`, `syphonout_on_new_frame`

---

## Technical Notes

### Why Rust Core?

The Rust core was prototyped for:
- Memory safety without runtime overhead
- Easier cross-platform portability (Metal → Vulkan/DX12)
- Zero-copy IOSurface binding (avoiding `glGetTexImage` CPU readback)
- Simpler FFI for alternative frontends (e.g., CLI, web UI)

Current limitation: Rust `metal` crate requires `objc2` for CAMetalLayer interop, which adds complexity. The Swift implementation is currently more mature.

### Syphon Framework Notes

- Uses OpenGL (legacy, deprecated on macOS but still functional)
- v5 supports Metal indirectly via IOSurface
- Current implementation does CPU readback: `glGetTexImage` → buffer → `MTLTexture`
- Future Rust integration could use IOSurface direct bind: `newTextureWithDescriptor:iosurface:plane:`

### Window Level Details

- `NSScreenSaverWindowLevel` = 2000
- Mission Control = ~1500
- Dock = 500
- Normal window = 0

`canJoinAllSpaces` + `stationary` + `ignoresCycle` collection behaviors ensure the window survives all workspace transitions.

---

## Deployment

- **Target:** macOS 12.0+ (Monterey)
- **Architecture:** Apple Silicon + Intel (Universal Binary `arm64 x86_64`)
- **Distribution:** Direct download (not App Store — sandboxing blocks elevated window levels)
- **Code Signing:** Developer ID recommended (required for Gatekeeper on other machines)
- **Sandbox:** Disabled (`com.apple.security.app-sandbox: false`)

---

## OBS Syphon Plugin Installation

SyphonOut requires the **obs-syphon** plugin installed in OBS to publish scenes as Syphon servers.

### Installation Script

Create and run `install_obs_syphon.sh`:

```bash
#!/bin/bash
set -e

PLUGIN_DIR="$HOME/Library/Application Support/obs-studio/plugins"
TMP_DIR=$(mktemp -d)

echo "Downloading obs-syphon..."

RELEASE_URL=$(curl -s https://api.github.com/repos/zakk4223/obs-syphon/releases/latest \
  | grep "browser_download_url" \
  | grep ".zip" \
  | cut -d '"' -f 4)

if [ -z "$RELEASE_URL" ]; then
  echo "ERROR: Could not find release. Check https://github.com/zakk4223/obs-syphon/releases"
  exit 1
fi

curl -L "$RELEASE_URL" -o "$TMP_DIR/obs-syphon.zip"
unzip -q "$TMP_DIR/obs-syphon.zip" -d "$TMP_DIR/extracted"

mkdir -p "$PLUGIN_DIR"
cp -R "$TMP_DIR/extracted/"* "$PLUGIN_DIR/"

rm -rf "$TMP_DIR"

echo "✓ obs-syphon installed to: $PLUGIN_DIR"
echo "→ Restart OBS, then go to Tools → Syphon Output to enable"
```

### Gatekeeper Fix

If OBS shows an error loading the plugin:

```bash
xattr -dr com.apple.quarantine "$HOME/Library/Application Support/obs-studio/plugins/obs-syphon"
```

### Enabling in OBS

1. Open OBS → **Tools → Syphon Output**
2. Select which scene/output to publish as a Syphon server
3. Click **Start** — OBS now appears as a Syphon server visible to SyphonOut

---

## Out of Scope (v1)

- Audio passthrough
- MIDI/OSC control
- NDI input (Syphon only)
- Recording output
- Windows/Spout support
- Rust core integration (experimental)

---

## File Reference

| File | Purpose |
|------|---------|
| `SyphonOut/App/AppDelegate.swift` | App lifecycle, NSStatusBar setup |
| `SyphonOut/MenuBar/StatusBarController.swift` | Menu bar icon, global shortcuts |
| `SyphonOut/MenuBar/MenuBuilder.swift` | Dynamic menu construction |
| `SyphonOut/Output/OutputManager.swift` | Multi-display coordination |
| `SyphonOut/Output/OutputController.swift` | Per-display window/renderer |
| `SyphonOut/Output/OutputMode.swift` | Mode enum definitions |
| `SyphonOut/Metal/MetalRenderer.swift` | MTKView delegate, pipeline management |
| `SyphonOut/Metal/Shaders.metal` | Vertex/fragment shaders |
| `SyphonOut/Syphon/SyphonBridge.m` | Obj-C Syphon client + CGL context |
| `SyphonOut/Syphon/SyphonClientWrapper.swift` | Swift wrapper for bridge |
| `SyphonOut/Syphon/SyphonServerDiscovery.swift` | Server polling |
| `SyphonOut/Preferences/PreferencesStore.swift` | UserDefaults wrapper |
| `core/src/lib.rs` | Rust FFI exports |
| `core/src/core.rs` | Rust global state |
| `core/src/renderer.rs` | Rust Metal renderer |
| `core/syphonout_core.h` | Generated C header |
