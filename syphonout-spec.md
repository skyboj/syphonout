# SyphonOut — Functional Specification

## Overview

SyphonOut is a lightweight macOS menu bar application that receives Syphon video streams and outputs them to physical displays as exclusive fullscreen windows immune to Mission Control, Spaces switching, and trackpad gestures.

Built with: Swift + AppKit + Metal + Syphon Framework

---

## Core Problem

OBS Fullscreen Projector windows are managed by the macOS window compositor (Quartz). Any Mission Control gesture (4-finger swipe up, etc.) affects all displays including projection outputs, causing visual disruption during live events.

## Solution

SyphonOut renders each output via a borderless `NSWindow` at `NSScreenSaverWindowLevel` (level 2000), which sits above the Mission Control layer (~1500). The window is rendered via Metal directly to the display surface with zero compression, preserving full image fidelity.

---

## Architecture

```
OBS (obs-syphon plugin, Server mode)
        │
        │  Syphon protocol (GPU texture, zero-copy)
        ▼
SyphonOut (menu bar app)
  ├── Syphon Client per output
  ├── Metal renderer per output
  └── NSWindow per physical display (level > Mission Control)
```

---

## Display Outputs

Each physical display connected to the Mac is represented as an independent **Output** in SyphonOut.

### Per-Output State Machine

Each output operates in one of four modes:

| Mode | Description |
|------|-------------|
| `signal` | Live Syphon stream rendered to display |
| `freeze` | Last received frame held; stream can be switched in background |
| `blank` | Solid color or test pattern (no Syphon required) |
| `off` | SyphonOut releases the display; system regains control |

---

## Menu Bar UI

The app lives exclusively in the menu bar (no Dock icon).

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
- Frames are received as `IOSurface` GPU textures
- Metal renders each frame to the output window at native display resolution
- No compression, no encoding — raw texture blit
- VSync enabled per display to prevent tearing

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
2. The last successfully rendered frame is retained in a Metal texture
3. That texture is held and re-presented every vsync (no flicker, no blank)
4. Syphon client **remains connected** in the background
5. User can switch Source in the menu — new server begins buffering
6. On exit from Freeze → Signal mode: crossfade from frozen frame to live stream

Use case: switch sources mid-show without audience seeing the transition.

---

## Blank Mode

Output shows a solid fill or test pattern. No Syphon connection required.

### Blank Options (submenu)

| Option | Description |
|--------|-------------|
| Black | `RGB(0, 0, 0)` |
| White | `RGB(255, 255, 255)` |
| Test Pattern | SMPTE color bars at output resolution |

Transition from any mode → Blank: crossfade over ~100ms.

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

- SyphonOut polls the Syphon server directory continuously
- Source dropdown shows all currently available servers by name
- If a previously selected server disappears (app closed), status shows `✗ No signal`
- When that server reappears, SyphonOut auto-reconnects

---

## Window Management

### NSWindow Configuration

```
styleMask:     .borderless
level:         NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.maximumWindow)))
                 — or NSScreenSaverWindowLevel (2000), above Mission Control (~1500)
collectionBehavior: [.canJoinAllSpaces, .stationary, .ignoresCycle]
isOpaque:      true
backgroundColor: .black
```

### Result

- Mission Control gesture does not affect the output window
- Spaces switching does not affect the output window  
- App Exposé does not include the output window
- Cmd+Tab does not surface the output window
- The window is invisible to the user's workspace; only the display output is affected

---

## Keyboard Shortcuts (Global, configurable in Preferences)

| Action | Default |
|--------|---------|
| Freeze all outputs | `⌃⌥F` |
| Unfreeze all outputs | `⌃⌥U` |
| Blank all outputs (black) | `⌃⌥B` |
| Restore all outputs to Signal | `⌃⌥S` |

---

## Preferences

- Launch at login toggle
- Primary display selection (for Mirror mode)
- Crossfade duration (50ms – 500ms, default 100ms)
- Global shortcut key assignments
- Per-output display name aliases (e.g. rename "Thunderbolt Display" → "Stage Left")

---

## Technical Notes

### Why not an OBS plugin?

An OBS plugin would run inside the OBS process and inherit OBS's window level. SyphonOut as a standalone app creates its own windows at an elevated level, independent of OBS's window hierarchy.

### Syphon Framework

- Use [Syphon-Framework](https://github.com/Syphon/Syphon-Framework) — supports Metal natively
- `SyphonMetalClient` receives `IOSurface`-backed textures directly, no CPU copy
- Framework is MIT licensed, embed directly in the app bundle

### Metal Rendering

- One `MTKView` per output display
- `preferredFramesPerSecond` = display refresh rate (via `NSScreen.maximumFramesPerSecond`)
- On new Syphon frame: update shared `MTLTexture`, mark view as needing display
- Crossfade: blend two `MTLTexture`s with alpha parameter via fragment shader

### Deployment

- Target: macOS 12.0+ (Monterey)
- Apple Silicon + Intel (Universal Binary)
- No App Store — direct distribution (no sandboxing required, simplifies window level access)
- Code signing: Developer ID (required for Gatekeeper on other machines)

---

## OBS Syphon Plugin Installation

SyphonOut requires the **obs-syphon** plugin installed in OBS to publish scenes as Syphon servers.

### What it is

obs-syphon is a binary OBS plugin (.so + .dylib) that adds a Syphon Server output to OBS. It is not available via Homebrew — installation is manual file placement.

Plugin source: https://github.com/zakk4223/obs-syphon  
Releases: https://github.com/zakk4223/obs-syphon/releases

### Installation Script

Create and run `install_obs_syphon.sh`:

```bash
#!/bin/bash
set -e

PLUGIN_DIR="$HOME/Library/Application Support/obs-studio/plugins"
TMP_DIR=$(mktemp -d)

echo "Downloading obs-syphon..."

# Get latest release download URL
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

### Manual Installation (fallback)

1. Download the latest `.zip` from https://github.com/zakk4223/obs-syphon/releases
2. Unzip and copy the `obs-syphon` folder into `~/Library/Application Support/obs-studio/plugins/`
3. Restart OBS

### Enabling in OBS

After installation:
1. Open OBS → **Tools → Syphon Output**
2. Select which scene/output to publish as a Syphon server
3. Click **Start** — OBS now appears as a Syphon server visible to SyphonOut

### Note on macOS Gatekeeper

The plugin binary may be blocked on first run. If OBS shows an error loading the plugin:

```bash
xattr -dr com.apple.quarantine "$HOME/Library/Application Support/obs-studio/plugins/obs-syphon"
```

---

## Out of Scope (v1)

- Audio passthrough
- MIDI/OSC control
- NDI input (Syphon only)
- Recording output
- Windows/Spout support
