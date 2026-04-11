#![allow(clippy::missing_safety_doc)]
// SyphonOut Core — C-compatible FFI boundary.
// Compiled to libsyphonout_core.a and linked into the Swift app.

mod core;
mod output;
mod renderer;
mod state;
mod syphon;

use std::ffi::{c_void, CStr};
use parking_lot::Mutex;
use std::sync::OnceLock;
use std::collections::HashMap;

pub use state::{SyphonOutIcon, SyphonOutMode, SyphonOutServerInfo, SyphonOutSignal};

use crate::core::SyphonOutCore;

// ── Global state ─────────────────────────────────────────────────────────────

static CORE: OnceLock<Mutex<SyphonOutCore>> = OnceLock::new();

fn core() -> &'static Mutex<SyphonOutCore> {
    CORE.get().expect("syphonout_core_init() not called")
}

// ── C-string name cache (avoids re-allocation on every status query) ─────────

static NAME_CACHE: OnceLock<Mutex<HashMap<u32, std::ffi::CString>>> = OnceLock::new();

fn name_cache() -> &'static Mutex<HashMap<u32, std::ffi::CString>> {
    NAME_CACHE.get_or_init(|| Mutex::new(HashMap::new()))
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
    // OnceLock doesn't have a reset, so outputs are dropped when the process exits.
    // Explicit cleanup can be added here if needed.
    let mut c = core().lock();
    c.outputs.clear();
}

// ═══════════════════════════════════════════════════════════════════════════════
// Output management
// ═══════════════════════════════════════════════════════════════════════════════

/// Create a Metal-backed output for `display_id`.
/// `ca_metal_layer_ptr` is the raw `CAMetalLayer *` created by Swift.
#[no_mangle]
pub unsafe extern "C" fn syphonout_output_create(
    display_id: u32,
    ca_metal_layer_ptr: *mut c_void,
) {
    core().lock().create_output(display_id, ca_metal_layer_ptr);
}

/// Remove an output (call when a display is disconnected).
#[no_mangle]
pub extern "C" fn syphonout_output_destroy(display_id: u32) {
    core().lock().destroy_output(display_id);
}

/// Transition an output to a new mode.
#[no_mangle]
pub extern "C" fn syphonout_output_set_mode(display_id: u32, mode: SyphonOutMode) {
    core().lock().set_mode(display_id, mode);
}

/// Assign a Syphon server to an output. `server_uuid` is a null-terminated UTF-8 string.
#[no_mangle]
pub unsafe extern "C" fn syphonout_output_set_server(
    display_id: u32,
    server_uuid: *const libc::c_char,
) {
    let uuid = CStr::from_ptr(server_uuid).to_str().unwrap_or("").to_owned();
    core().lock().set_server(display_id, &uuid);
}

/// Remove the server assignment from an output.
#[no_mangle]
pub extern "C" fn syphonout_output_clear_server(display_id: u32) {
    core().lock().clear_server(display_id);
}

// ═══════════════════════════════════════════════════════════════════════════════
// Render (called from Swift CVDisplayLink callback on a background thread)
// ═══════════════════════════════════════════════════════════════════════════════

/// Draw the current frame into the output's CAMetalLayer.
/// Called from a CVDisplayLink background thread — Metal is thread-safe.
#[no_mangle]
pub extern "C" fn syphonout_render_frame(display_id: u32) {
    core().lock().render_frame(display_id);
}

// ═══════════════════════════════════════════════════════════════════════════════
// Settings
// ═══════════════════════════════════════════════════════════════════════════════

/// Set the crossfade duration in milliseconds.
#[no_mangle]
pub extern "C" fn syphonout_set_crossfade_duration_ms(ms: f64) {
    core().lock().set_crossfade_duration_ms(ms);
}

/// Set whether mirroring is enabled and which display is the primary source.
#[no_mangle]
pub extern "C" fn syphonout_set_mirror(enabled: bool, primary_display_id: u32) {
    core().lock().set_mirror(enabled, primary_display_id);
}

/// Register a callback invoked (on an arbitrary thread) when the server list changes.
/// Swift should dispatch to main thread and rebuild the menu.
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
/// `callback` is invoked synchronously with an array of SyphonOutServerInfo.
#[no_mangle]
pub unsafe extern "C" fn syphonout_get_servers(
    callback: unsafe extern "C" fn(*const SyphonOutServerInfo, usize, *mut c_void),
    userdata: *mut c_void,
) {
    let c = core().lock();
    let servers = c.registry.server_list();

    // Build temp C strings on the stack for each server
    let entries: Vec<_> = servers
        .iter()
        .map(|s| {
            (
                std::ffi::CString::new(s.uuid.as_str()).unwrap_or_default(),
                std::ffi::CString::new(s.name.as_str()).unwrap_or_default(),
                std::ffi::CString::new(s.app_name.as_str()).unwrap_or_default(),
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

/// Get the signal status for a specific display.
#[no_mangle]
pub extern "C" fn syphonout_get_signal_status(display_id: u32) -> SyphonOutSignal {
    core().lock().signal_status(display_id)
}

/// Returns a pointer to a null-terminated server name string, or NULL.
/// The pointer is valid until the next call to this function for the same display_id.
#[no_mangle]
pub extern "C" fn syphonout_get_selected_server_name(
    display_id: u32,
) -> *const libc::c_char {
    let c = core().lock();
    match c.selected_server_name(display_id) {
        Some(name) => {
            let cstr = std::ffi::CString::new(name).unwrap_or_default();
            let mut cache = name_cache().lock();
            cache.insert(display_id, cstr);
            cache[&display_id].as_ptr()
        }
        None => std::ptr::null(),
    }
}

// ═══════════════════════════════════════════════════════════════════════════════
// Syphon event callbacks — called FROM SyphonNative.m
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

/// New frame available from a Syphon server for a specific output.
/// `iosurface_ref` is an `IOSurfaceRef` — the MTLTexture is created zero-copy in Rust.
#[no_mangle]
pub unsafe extern "C" fn syphonout_on_new_frame(
    display_id: u32,
    iosurface_ref: *mut c_void,
    width: u32,
    height: u32,
) {
    core().lock().on_new_frame(display_id, iosurface_ref, width, height);
}