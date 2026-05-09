#![allow(clippy::missing_safety_doc)]
// SyphonOut Core — C-compatible FFI boundary.
// Compiled to libsyphonout_core.a and linked into the Swift app.

mod core;
mod output;
mod renderer;
mod solink_publisher;
mod state;
mod registry;
mod virtual_display;

use std::ffi::{c_void, CStr, CString};
use parking_lot::Mutex;
use std::sync::OnceLock;

pub use state::{SyphonOutIcon, SyphonOutMode, SyphonOutScaleMode, SyphonOutServerInfo, SyphonOutSignal};

use crate::core::SyphonOutCore;


// ── Global state ─────────────────────────────────────────────────────────────

static CORE: OnceLock<Mutex<SyphonOutCore>> = OnceLock::new();

fn core() -> &'static Mutex<SyphonOutCore> {
    CORE.get().expect("syphonout_core_init() not called")
}

// ═══════════════════════════════════════════════════════════════════════════════
// Lifecycle
// ═══════════════════════════════════════════════════════════════════════════════

/// Initialise the Rust core. Call once from AppDelegate before any other function.
#[no_mangle]
pub extern "C" fn syphonout_core_init() {
    CORE.get_or_init(|| Mutex::new(SyphonOutCore::new()));
}

/// Tear down the core (call from applicationWillTerminate).
#[no_mangle]
pub extern "C" fn syphonout_core_deinit() {
    let mut c = core().lock();
    c.physical_outputs.clear();
    c.virtual_displays.clear();
}

// ═══════════════════════════════════════════════════════════════════════════════
// Virtual Display lifecycle
// ═══════════════════════════════════════════════════════════════════════════════

#[no_mangle]
pub unsafe extern "C" fn syphonout_vd_create(
    uuid: *const libc::c_char,
    name: *const libc::c_char,
    width: u32,
    height: u32,
) {
    let uuid = CStr::from_ptr(uuid).to_str().unwrap_or("").to_owned();
    let name = CStr::from_ptr(name).to_str().unwrap_or("").to_owned();
    core().lock().vd_create(uuid, name, width, height);
}

#[no_mangle]
pub unsafe extern "C" fn syphonout_vd_destroy(uuid: *const libc::c_char) {
    let uuid = CStr::from_ptr(uuid).to_str().unwrap_or("");
    core().lock().vd_destroy(uuid);
}

#[no_mangle]
pub unsafe extern "C" fn syphonout_vd_set_size(uuid: *const libc::c_char, width: u32, height: u32) {
    let uuid = CStr::from_ptr(uuid).to_str().unwrap_or("");
    core().lock().vd_set_size(uuid, width, height);
}

#[no_mangle]
pub unsafe extern "C" fn syphonout_vd_set_name(uuid: *const libc::c_char, name: *const libc::c_char) {
    let uuid = CStr::from_ptr(uuid).to_str().unwrap_or("");
    let name = CStr::from_ptr(name).to_str().unwrap_or("");
    core().lock().vd_set_name(uuid, name);
}

// ═══════════════════════════════════════════════════════════════════════════════
// Virtual Display mode & source
// ═══════════════════════════════════════════════════════════════════════════════

#[no_mangle]
pub unsafe extern "C" fn syphonout_vd_set_mode(uuid: *const libc::c_char, mode: SyphonOutMode) {
    let uuid = CStr::from_ptr(uuid).to_str().unwrap_or("");
    core().lock().vd_set_mode(uuid, mode);
}

#[no_mangle]
pub unsafe extern "C" fn syphonout_vd_set_source(
    uuid: *const libc::c_char,
    source_uuid: *const libc::c_char,
) {
    let uuid = CStr::from_ptr(uuid).to_str().unwrap_or("");
    let source = CStr::from_ptr(source_uuid).to_str().unwrap_or("").to_owned();
    core().lock().vd_set_source(uuid, &source);
}

#[no_mangle]
pub unsafe extern "C" fn syphonout_vd_clear_source(uuid: *const libc::c_char) {
    let uuid = CStr::from_ptr(uuid).to_str().unwrap_or("");
    core().lock().vd_clear_source(uuid);
}

// ═══════════════════════════════════════════════════════════════════════════════
// Physical output management
// ═══════════════════════════════════════════════════════════════════════════════

/// Create a Metal-backed output for `display_id`.
/// `ca_metal_layer_ptr` is the raw `CAMetalLayer *` created by Swift.
#[no_mangle]
pub unsafe extern "C" fn syphonout_output_create(
    display_id: u32,
    ca_metal_layer_ptr: *mut c_void,
) {
    core().lock().physical_create(display_id, ca_metal_layer_ptr);
}

/// Remove an output (call when a display is disconnected).
#[no_mangle]
pub extern "C" fn syphonout_output_destroy(display_id: u32) {
    core().lock().physical_destroy(display_id);
}

/// Assign a physical output to a VirtualDisplay.
#[no_mangle]
pub unsafe extern "C" fn syphonout_physical_assign(
    display_id: u32,
    vd_uuid: *const libc::c_char,
) {
    let uuid = CStr::from_ptr(vd_uuid).to_str().unwrap_or("");
    core().lock().physical_assign(display_id, uuid);
}

/// Set the scale mode (fill / fit) for a physical output.
#[no_mangle]
pub extern "C" fn syphonout_physical_set_scale_mode(
    display_id: u32,
    mode: SyphonOutScaleMode,
) {
    core().lock().physical_set_scale_mode(display_id, mode);
}

/// Unassign a physical output from its VirtualDisplay.
#[no_mangle]
pub extern "C" fn syphonout_physical_unassign(display_id: u32) {
    core().lock().physical_unassign(display_id);
}

// ═══════════════════════════════════════════════════════════════════════════════
// Render (called from Swift CVDisplayLink callback on a background thread)
// ═══════════════════════════════════════════════════════════════════════════════

/// Draw the current frame into the output's CAMetalLayer.
#[no_mangle]
pub extern "C" fn syphonout_render_frame(display_id: u32) {
    core().lock().render_frame(display_id);
}

// ═══════════════════════════════════════════════════════════════════════════════
// Frame delivery — NEW (keyed by VD UUID)
// ═══════════════════════════════════════════════════════════════════════════════

/// New frame available for a specific VirtualDisplay.
/// `iosurface_ref` is an `IOSurfaceRef` — retained by Rust until replaced.
#[no_mangle]
pub unsafe extern "C" fn syphonout_on_new_frame_vd(
    vd_uuid: *const libc::c_char,
    iosurface_ref: *mut c_void,
    width: u32,
    height: u32,
) {
    let uuid = CStr::from_ptr(vd_uuid).to_str().unwrap_or("");
    core().lock().on_new_frame(uuid, iosurface_ref, width, height);
}

// ═══════════════════════════════════════════════════════════════════════════════
// Settings
// ═══════════════════════════════════════════════════════════════════════════════

/// Set the crossfade duration in milliseconds.
#[no_mangle]
pub extern "C" fn syphonout_set_crossfade_duration_ms(ms: f64) {
    core().lock().set_crossfade_duration_ms(ms);
}

/// Register a callback invoked (on an arbitrary thread) when the server list changes.
#[no_mangle]
pub unsafe extern "C" fn syphonout_set_server_changed_callback(
    callback: unsafe extern "C" fn(*mut c_void),
    userdata: *mut c_void,
) {
    core().lock().server_changed_cb = Some((callback, userdata));
}

// ═══════════════════════════════════════════════════════════════════════════════
// Server list
// ═══════════════════════════════════════════════════════════════════════════════

/// Enumerate all currently available Syphon servers.
#[no_mangle]
pub unsafe extern "C" fn syphonout_get_servers(
    callback: unsafe extern "C" fn(*const SyphonOutServerInfo, usize, *mut c_void),
    userdata: *mut c_void,
) {
    let c = core().lock();
    let servers = c.registry.server_list();

    let entries: Vec<_> = servers
        .iter()
        .map(|s| {
            (
                CString::new(s.uuid.as_str()).unwrap_or_default(),
                CString::new(s.name.as_str()).unwrap_or_default(),
                CString::new(s.app_name.as_str()).unwrap_or_default(),
            )
        })
        .collect();

    let infos: Vec<SyphonOutServerInfo> = entries
        .iter()
        .map(|(u, n, a)| SyphonOutServerInfo {
            uuid: u.as_ptr(),
            name: n.as_ptr(),
            app_name: a.as_ptr(),
        })
        .collect();

    callback(infos.as_ptr(), infos.len(), userdata);
}

// ═══════════════════════════════════════════════════════════════════════════════
// Status queries
// ═══════════════════════════════════════════════════════════════════════════════

/// Get the overall icon state for the menu bar.
#[no_mangle]
pub extern "C" fn syphonout_get_icon_state() -> SyphonOutIcon {
    core().lock().icon_state()
}

// ═══════════════════════════════════════════════════════════════════════════════
// Server event callbacks — called from SOLinkClient.m
// ═══════════════════════════════════════════════════════════════════════════════

/// Server appeared on the network.
#[no_mangle]
pub unsafe extern "C" fn syphonout_on_server_announced(
    uuid: *const libc::c_char,
    name: *const libc::c_char,
    app_name: *const libc::c_char,
) {
    let uuid = CStr::from_ptr(uuid).to_str().unwrap_or("").to_owned();
    let name = CStr::from_ptr(name).to_str().unwrap_or("").to_owned();
    let app_name = CStr::from_ptr(app_name).to_str().unwrap_or("").to_owned();
    core().lock().on_server_announced(uuid, name, app_name);
}

/// Server left the network.
#[no_mangle]
pub unsafe extern "C" fn syphonout_on_server_retired(uuid: *const libc::c_char) {
    let uuid = CStr::from_ptr(uuid).to_str().unwrap_or("");
    core().lock().on_server_retired(uuid);
}

// ═══════════════════════════════════════════════════════════════════════════════
// Backward-compat shims — OLD display_id-based frame delivery
// ═══════════════════════════════════════════════════════════════════════════════

/// Legacy: transition an output to a new mode.
/// Operates on the implicit per-display VD.
#[no_mangle]
pub extern "C" fn syphonout_output_set_mode(display_id: u32, mode: SyphonOutMode) {
    core().lock().legacy_set_mode(display_id, mode);
}

/// Return the current IOSurface for a Virtual Display, with a +1 CFRetain.
/// Returns NULL if no frame has arrived yet.
/// THE CALLER MUST CFRelease the returned pointer when done.
#[no_mangle]
pub unsafe extern "C" fn syphonout_vd_get_iosurface(
    uuid: *const libc::c_char,
) -> *mut c_void {
    let uuid = CStr::from_ptr(uuid).to_str().unwrap_or("");
    core().lock().vd_get_iosurface(uuid)
}


