/// Global SyphonOutCore — owns all OutputCores and the Syphon server registry.
/// Accessed through the FFI functions in lib.rs via a parking_lot Mutex.

use std::collections::HashMap;
use std::ffi::c_void;

use crate::output::OutputCore;
use crate::state::{SyphonOutIcon, SyphonOutMode, SyphonOutSignal};
use crate::syphon::SyphonRegistry;

pub struct SyphonOutCore {
    pub outputs: HashMap<u32, OutputCore>,
    pub registry: SyphonRegistry,
    pub mirror_enabled: bool,
    pub primary_display_id: u32,
    pub crossfade_duration_ms: f64,

    /// Called (on main thread) whenever the server list changes.
    pub server_changed_cb: Option<(unsafe extern "C" fn(*mut c_void), *mut c_void)>,
}

// SAFETY: The callback pointer is set once from Swift and valid for the app lifetime.
unsafe impl Send for SyphonOutCore {}
unsafe impl Sync for SyphonOutCore {}

impl SyphonOutCore {
    pub fn new() -> Self {
        SyphonOutCore {
            outputs: HashMap::new(),
            registry: SyphonRegistry::default(),
            mirror_enabled: false,
            primary_display_id: 0,
            crossfade_duration_ms: 100.0,
            server_changed_cb: None,
        }
    }

    // ── Output management ────────────────────────────────────────────────────

    pub fn create_output(&mut self, display_id: u32, layer: *mut c_void) {
        let output = OutputCore::new(display_id, layer);
        self.outputs.insert(display_id, output);
    }

    pub fn destroy_output(&mut self, display_id: u32) {
        self.outputs.remove(&display_id);
    }

    pub fn set_mode(&mut self, display_id: u32, mode: SyphonOutMode) {
        if let Some(out) = self.outputs.get_mut(&display_id) {
            out.set_mode(mode);
        }
    }

    pub fn set_server(&mut self, display_id: u32, server_uuid: &str) {
        self.registry.select(display_id, server_uuid.to_string());
        if let Some(out) = self.outputs.get_mut(&display_id) {
            out.has_source = true;
            out.has_signal = false;  // will flip true when frames arrive
        }
        // Notify SyphonNative.m to connect (done via the C callback in lib.rs)
    }

    pub fn clear_server(&mut self, display_id: u32) {
        self.registry.clear_selection(display_id);
        if let Some(out) = self.outputs.get_mut(&display_id) {
            out.on_source_cleared();
        }
    }

    // ── Frame delivery (from SyphonNative.m callback) ────────────────────────

    pub fn on_new_frame(&mut self, display_id: u32, iosurface: *mut c_void, w: u32, h: u32) {
        if let Some(out) = self.outputs.get_mut(&display_id) {
            out.on_new_frame(iosurface, w, h);
        }
    }

    // ── Syphon server events ─────────────────────────────────────────────────

    pub fn on_server_announced(&mut self, uuid: String, name: String, app_name: String) {
        self.registry.announce(uuid, name, app_name);
        self.notify_server_changed();
    }

    pub fn on_server_retired(&mut self, uuid: &str) {
        // Signal loss for any output that was watching this server
        for out in self.outputs.values_mut() {
            if self.registry.selected_uuid(out.display_id) == Some(uuid) {
                out.on_server_lost();
            }
        }
        self.registry.retire(uuid);
        self.notify_server_changed();
    }

    fn notify_server_changed(&self) {
        if let Some((cb, ud)) = self.server_changed_cb {
            unsafe { cb(ud) };
        }
    }

    // ── Mirror mode ───────────────────────────────────────────────────────────

    pub fn set_mirror(&mut self, enabled: bool, primary_display_id: u32) {
        self.mirror_enabled = enabled;
        self.primary_display_id = primary_display_id;
        if enabled {
            if let Some(uuid) = self.registry.selected_uuid(primary_display_id).map(|s| s.to_string()) {
                let ids: Vec<u32> = self.outputs.keys().copied().collect();
                for id in ids {
                    if id != primary_display_id {
                        self.set_server(id, &uuid.clone());
                    }
                }
            }
        }
    }

    // ── Settings ─────────────────────────────────────────────────────────────

    pub fn set_crossfade_duration_ms(&mut self, ms: f64) {
        self.crossfade_duration_ms = ms;
        for out in self.outputs.values_mut() {
            out.set_crossfade_duration_ms(ms);
        }
    }

    // ── Render ───────────────────────────────────────────────────────────────

    pub fn render_frame(&mut self, display_id: u32) {
        if let Some(out) = self.outputs.get_mut(&display_id) {
            out.render_frame();
        }
    }

    // ── Status ────────────────────────────────────────────────────────────────

    pub fn icon_state(&self) -> SyphonOutIcon {
        let active: Vec<_> = self.outputs.values().filter(|o| o.is_active()).collect();
        if active.is_empty() { return SyphonOutIcon::Empty; }
        let all_signal = active.iter().all(|o| o.signal_status() == SyphonOutSignal::Present);
        if all_signal { SyphonOutIcon::Solid } else { SyphonOutIcon::Half }
    }

    pub fn signal_status(&self, display_id: u32) -> SyphonOutSignal {
        self.outputs.get(&display_id)
            .map(|o| o.signal_status())
            .unwrap_or(SyphonOutSignal::NoSourceSelected)
    }

    pub fn selected_server_name(&self, display_id: u32) -> Option<&str> {
        self.registry.selected_server_name(display_id)
    }
}
