# Virtual Displays — Architecture & Implementation Plan

## Goal

Decouple the "video channel" from the "physical output". Users create N Virtual
Displays (VDs), each owning its own source + mode + state. Physical outputs
(macOS displays) are then *assigned* to a VD. Multiple physical outputs may
point at the same VD (mirroring). VDs also exist without a physical output
attached (for preview-only / staging). Previews of each VD render into menu
thumbnails.

## Design decisions (locked)

| Question | Decision |
| -------- | -------- |
| VD resolution | Inline-configurable. When assigned to a physical, defaults to that display's native size. When unassigned, defaults to 1920×1080, with a picker for standard sizes up to 4K (1280×720, 1920×1080, 2560×1440, 3840×2160). |
| Auto-create | On startup: if at least one physical display exists, auto-create one default VD and assign every physical display to it (backward-compatible with single-VD users). If no physicals, still create one default VD for preview/testing. |
| Mode controls | Mode (signal/freeze/blank-black/blank-white/test-pattern/off) is **per-VD**. Physical outputs have no mode of their own — they simply display their assigned VD. A "disable output" for a physical = assign it to no VD (renders black). |
| Preview | Phase 4 ships approach **A** first (menu-item thumbnails, ~160×90, updated ~6 fps via IOSurface downscale in a background render pass). Dedicated multi-VD preview window (approach C) is a later add-on. |

## Core concepts

```
                        ┌───────────────────────┐
Syphon / SOLink source ─►│    VirtualDisplay     │
   (by vd_uuid)          │  uuid, name, size     │
                         │  mode, source_uuid    │
                         │  current_texture      │
                         │  frozen_texture       │
                         │  preview_texture      │
                         └──────────┬────────────┘
                                    │ (0..N)
                                    ▼
                         ┌───────────────────────┐
                         │   PhysicalOutput      │
                         │  display_id           │
                         │  ca_metal_layer       │
                         │  assigned_vd_uuid     │
                         │  crossfade state      │
                         └───────────────────────┘
```

- **VirtualDisplay** owns all *state* (mode, source assignment, signal flags,
  textures). It is the unit that receives frames from Syphon/SOLink.
- **PhysicalOutput** owns only *presentation* (CAMetalLayer + drawable
  acquisition + blit + per-physical crossfade on VD-swap). It looks up its
  assigned VD each frame and renders that VD's current/frozen texture.
- Crossfade between sources belongs to the VD (source-switch crossfade).
- Crossfade between VDs belongs to the PhysicalOutput (assignment-swap
  crossfade). Both use the same shader, different owners.

## FFI surface (new)

```c
// Virtual Display lifecycle
void   syphonout_vd_create(const char *uuid, const char *name, uint32_t w, uint32_t h);
void   syphonout_vd_destroy(const char *uuid);
void   syphonout_vd_set_size(const char *uuid, uint32_t w, uint32_t h);
void   syphonout_vd_set_name(const char *uuid, const char *name);

// Mode & source — keyed by VD uuid, not display_id
void   syphonout_vd_set_mode(const char *uuid, enum SyphonOutMode mode);
void   syphonout_vd_set_source(const char *uuid, const char *source_uuid); // "solink:..." or syphon uuid
void   syphonout_vd_clear_source(const char *uuid);

// Frame delivery (replaces syphonout_on_new_frame keyed by display_id)
void   syphonout_on_new_frame_vd(const char *vd_uuid,
                                 void *iosurface_ref,
                                 uint32_t width, uint32_t height);

// Physical output assignment
void   syphonout_physical_assign(uint32_t display_id, const char *vd_uuid);
void   syphonout_physical_unassign(uint32_t display_id);

// Preview — copy VD's current frame into a shared BGRA8 CPU buffer.
// Returns rowBytes; caller provides buf_len >= height * rowBytes.
uintptr_t syphonout_vd_snapshot_preview(const char *uuid,
                                        uint8_t *buf, uintptr_t buf_len,
                                        uint32_t out_w, uint32_t out_h);
```

The existing `syphonout_output_*` functions become thin shims around the
VD API (one implicit VD per physical display_id) for a transition period,
then are removed once Swift fully migrates.

## Phased implementation

### Phase 1 — Rust core refactor
- New module `virtual_display.rs`: `VirtualDisplay` struct (mode + source +
  textures + signal flags). Extracted from today's `OutputCore`.
- Rename `output.rs` → represents `PhysicalOutput`. Drops source/mode fields;
  gains `assigned_vd_uuid: Option<String>` + assignment-swap crossfade.
- Core owns `HashMap<String, VirtualDisplay>` and `HashMap<u32, PhysicalOutput>`.
- Existing tests ported; new tests: VD-CRUD, physical-assign, shared-VD mirror
  via two physicals assigned to same VD.

### Phase 2 — ObjC bridges key by vd_uuid
- `SyphonNative.m` + `SOLinkClient.m` client tables become
  `NSMutableDictionary<NSString *uuid, *Subscriber>`.
- `SyphonNativeSetServer(displayId,…)` → `SyphonNativeSetServer(vdUuid,…)`.
- Frame callbacks call `syphonout_on_new_frame_vd(vd_uuid, ...)`.

### Phase 3 — Swift UI
- `VirtualDisplayManager` (ObservableObject) drives VD list.
- `PreferencesStore` gains `[VDSpec]` and `[CGDirectDisplayID: vdUUID]`.
- Menu rebuilt:
  - **Virtual Displays** section (per-VD submenu: source picker, mode, size,
    rename, delete, live preview thumbnail).
  - **Physical Outputs** section (per-display: VD assignment picker, "None").
  - "New Virtual Display…" action.
- On startup: migrate existing per-display state into one auto-created VD.

### Phase 4 — Preview pipeline
- Add `preview_texture` (160×90 BGRA8) to `VirtualDisplay`.
- Background render pass downscales `current_texture` into it at 6 fps
  (throttle via frame counter, not a separate timer).
- `syphonout_vd_snapshot_preview` blits to caller CPU buffer via
  `MTLBlitCommandEncoder::copy` + `getBytes`. Swift wraps that into an
  `NSImage` and sets it on the menu item.
- Dedicated "Preview All VDs" window (grid layout) — later, not MVP.

## Open migration points

1. Backward-compat shim for `syphonout_output_set_server` etc. — implement as
   `assign_or_create_implicit_vd(display_id)` then route. Keeps Swift
   compiling during the transition. Remove after Phase 3.
2. Crossfade duration is currently global. Leave it that way; applies to
   both source-switch (in VD) and assignment-swap (in PhysicalOutput).
3. Preview fps throttle happens inside Rust's render_frame — no new thread.
