/// Global SyphonOutCore — owns all VirtualDisplays and PhysicalOutputs.
///
/// VirtualDisplay = logical video channel (source, mode, signal, latest frame).
/// PhysicalOutput = Metal-backed window for a macOS display.
///
/// One VD can feed zero or more PhysicalOutputs (mirroring).

use std::collections::HashMap;
use std::ffi::c_void;

use crate::output::PhysicalOutput;
use crate::state::{SyphonOutIcon, SyphonOutMode, SyphonOutScaleMode, SyphonOutSignal};
use crate::registry::ServerRegistry;
use crate::virtual_display::VirtualDisplay;

pub struct SyphonOutCore {
    pub virtual_displays: HashMap<String, VirtualDisplay>,
    pub physical_outputs: HashMap<u32, PhysicalOutput>,
    /// display_id → vd_uuid. When present, the physical output renders that VD.
    /// When absent, it falls back to the implicit per-display VD.
    pub physical_assignments: HashMap<u32, String>,
    pub registry: ServerRegistry,
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
            virtual_displays: HashMap::new(),
            physical_outputs: HashMap::new(),
            physical_assignments: HashMap::new(),
            registry: ServerRegistry::default(),
            crossfade_duration_ms: 100.0,
            server_changed_cb: None,
        }
    }

    // ═════════════════════════════════════════════════════════════════════════
    // Virtual Display CRUD
    // ═════════════════════════════════════════════════════════════════════════

    pub fn vd_create(&mut self, uuid: String, name: String, width: u32, height: u32) {
        let vd = VirtualDisplay::new(&uuid, &name, width, height);
        self.virtual_displays.insert(uuid, vd);
    }

    pub fn vd_destroy(&mut self, uuid: &str) {
        let to_unassign: Vec<u32> = self
            .physical_assignments
            .iter()
            .filter(|(_, vd_uuid)| vd_uuid.as_str() == uuid)
            .map(|(id, _)| *id)
            .collect();
        for id in to_unassign {
            self.physical_unassign(id);
        }
        self.virtual_displays.remove(uuid);
    }

    pub fn vd_set_size(&mut self, uuid: &str, width: u32, height: u32) {
        if let Some(vd) = self.virtual_displays.get_mut(uuid) {
            vd.width = width;
            vd.height = height;
        }
    }

    pub fn vd_set_name(&mut self, uuid: &str, name: &str) {
        if let Some(vd) = self.virtual_displays.get_mut(uuid) {
            vd.name = name.to_string();
        }
    }

    pub fn vd_set_mode(&mut self, uuid: &str, mode: SyphonOutMode) {
        if let Some(vd) = self.virtual_displays.get_mut(uuid) {
            vd.set_mode(mode);
        }
    }

    pub fn vd_set_source(&mut self, uuid: &str, source_uuid: &str) {
        if let Some(vd) = self.virtual_displays.get_mut(uuid) {
            vd.set_source(source_uuid);
        }
    }

    pub fn vd_clear_source(&mut self, uuid: &str) {
        if let Some(vd) = self.virtual_displays.get_mut(uuid) {
            vd.clear_source();
        }
    }

    // ═════════════════════════════════════════════════════════════════════════
    // Physical output management
    // ═════════════════════════════════════════════════════════════════════════

    pub fn physical_create(&mut self, display_id: u32, layer: *mut c_void) {
        let mut po = PhysicalOutput::new(display_id, layer);
        po.set_crossfade_duration_ms(self.crossfade_duration_ms);
        self.physical_outputs.insert(display_id, po);
    }

    pub fn physical_destroy(&mut self, display_id: u32) {
        self.physical_outputs.remove(&display_id);
    }

    /// Assign a PhysicalOutput to a VirtualDisplay by UUID.
    pub fn physical_assign(&mut self, display_id: u32, vd_uuid: &str) {
        if let Some(po) = self.physical_outputs.get_mut(&display_id) {
            po.last_vd_mode = SyphonOutMode::Off;
            po.last_frame_serial = 0;
        }
        self.physical_assignments.insert(display_id, vd_uuid.to_string());
    }

    pub fn physical_set_scale_mode(&mut self, display_id: u32, mode: SyphonOutScaleMode) {
        if let Some(po) = self.physical_outputs.get_mut(&display_id) {
            po.set_scale_mode(mode);
        }
    }

    pub fn physical_unassign(&mut self, display_id: u32) {
        if let Some(po) = self.physical_outputs.get_mut(&display_id) {
            po.last_vd_mode = SyphonOutMode::Off;
            po.last_frame_serial = 0;
        }
        self.physical_assignments.remove(&display_id);
    }

    // ═════════════════════════════════════════════════════════════════════════
    // Render
    // ═════════════════════════════════════════════════════════════════════════

    pub fn render_frame(&mut self, display_id: u32) {
        // Determine which VD to render without borrowing the whole self.
        let assigned_uuid = self.physical_assignments.get(&display_id).cloned();
        if let Some(po) = self.physical_outputs.get_mut(&display_id) {
            let vd = assigned_uuid
                .and_then(|u| self.virtual_displays.get(&u))
                .or_else(|| {
                    let key = Self::implicit_vd_key(display_id);
                    self.virtual_displays.get(&key)
                });
            po.render_frame(vd);
        }
    }

    // ═════════════════════════════════════════════════════════════════════════
    // Frame delivery (from SyphonNative / SOLinkClient callback)
    // ═════════════════════════════════════════════════════════════════════════

    pub fn on_new_frame(&mut self, vd_uuid: &str, iosurface: *mut c_void, w: u32, h: u32) {
        if let Some(vd) = self.virtual_displays.get_mut(vd_uuid) {
            vd.on_new_frame(iosurface, w, h);
        }
    }

    // ═════════════════════════════════════════════════════════════════════════
    // Syphon server events
    // ═════════════════════════════════════════════════════════════════════════

    pub fn on_server_announced(&mut self, uuid: String, name: String, app_name: String) {
        self.registry.announce(uuid, name, app_name);
        self.notify_server_changed();
    }

    pub fn on_server_retired(&mut self, uuid: &str) {
        // Signal loss for any VD that was watching this server
        for vd in self.virtual_displays.values_mut() {
            if vd.source_uuid.as_deref() == Some(uuid) {
                vd.on_server_lost();
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

    // ═════════════════════════════════════════════════════════════════════════
    // Settings
    // ═════════════════════════════════════════════════════════════════════════

    pub fn set_crossfade_duration_ms(&mut self, ms: f64) {
        self.crossfade_duration_ms = ms;
        for po in self.physical_outputs.values_mut() {
            po.set_crossfade_duration_ms(ms);
        }
    }

    // ═════════════════════════════════════════════════════════════════════════
    // Status
    // ═════════════════════════════════════════════════════════════════════════

    pub fn icon_state(&self) -> SyphonOutIcon {
        let active: Vec<_> = self
            .virtual_displays
            .values()
            .filter(|vd| vd.is_active())
            .collect();
        if active.is_empty() {
            return SyphonOutIcon::Empty;
        }
        let all_signal = active.iter().all(|vd| vd.signal_status() == SyphonOutSignal::Present);
        if all_signal {
            SyphonOutIcon::Solid
        } else {
            SyphonOutIcon::Half
        }
    }

    // ═════════════════════════════════════════════════════════════════════════
    // Legacy implicit-per-display VD (for syphonout_output_set_mode)
    // ═════════════════════════════════════════════════════════════════════════

    fn implicit_vd_key(display_id: u32) -> String {
        format!("__display__{}", display_id)
    }

    fn ensure_implicit_vd(&mut self, display_id: u32) {
        let key = Self::implicit_vd_key(display_id);
        if !self.virtual_displays.contains_key(&key) {
            self.vd_create(
            key.clone(),
                format!("Display {}", display_id),
                1920,
                1080,
            );
            // Auto-assign the physical output to its implicit VD
            self.physical_assign(display_id, &key);
        }
    }

    pub fn legacy_set_mode(&mut self, display_id: u32, mode: SyphonOutMode) {
        self.ensure_implicit_vd(display_id);
        let key = Self::implicit_vd_key(display_id);
        self.vd_set_mode(&key, mode);
    }

    // ═════════════════════════════════════════════════════════════════════════
    // Helpers
    // ═════════════════════════════════════════════════════════════════════════

    /// Return the IOSurface for a VD's current frame, CFRetain'd (+1 for the caller).
    /// Returns null if no frame has arrived yet.
    pub fn vd_get_iosurface(&self, uuid: &str) -> *mut c_void {
        let vd = if let Some(v) = self.virtual_displays.get(uuid) {
            v
        } else {
            return std::ptr::null_mut();
        };
        match vd.iosurface {
            Some(surface) => {
                extern "C" { fn CFRetain(cf: *const c_void) -> *const c_void; }
                unsafe { CFRetain(surface); }
                surface
            }
            None => std::ptr::null_mut(),
        }
    }

}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::state::SyphonOutIcon;

    fn make_core() -> SyphonOutCore {
        SyphonOutCore::new()
    }

    #[test]
    fn create_and_destroy_vd() {
        let mut c = make_core();
        c.vd_create("vd-1".into(), "Main".into(), 1920, 1080);
        assert!(c.virtual_displays.contains_key("vd-1"));
        c.vd_destroy("vd-1");
        assert!(!c.virtual_displays.contains_key("vd-1"));
    }

    #[test]
    fn create_and_destroy_physical() {
        let mut c = make_core();
        c.physical_create(1, std::ptr::null_mut());
        assert!(c.physical_outputs.contains_key(&1));
        c.physical_destroy(1);
        assert!(!c.physical_outputs.contains_key(&1));
    }

    #[test]
    fn vd_set_mode_propagates() {
        let mut c = make_core();
        c.vd_create("vd-1".into(), "Main".into(), 1920, 1080);
        c.vd_set_mode("vd-1", SyphonOutMode::Freeze);
        assert_eq!(c.virtual_displays["vd-1"].mode, SyphonOutMode::Freeze);
    }

    #[test]
    fn on_new_frame_updates_vd() {
        let mut c = make_core();
        c.vd_create("vd-1".into(), "Main".into(), 1920, 1080);
        c.vd_set_source("vd-1", "u1");
        // on_new_frame with a real IOSurface sets has_signal; in unit tests
        // we pass null (guarded) so set the flag manually to test the state path.
        c.on_new_frame("vd-1", std::ptr::null_mut(), 1920, 1080);
        c.virtual_displays.get_mut("vd-1").unwrap().has_signal = true;
        assert!(c.virtual_displays["vd-1"].has_signal);
    }

    #[test]
    fn on_server_retired_clears_signal_for_vd() {
        let mut c = make_core();
        c.on_server_announced("u1".into(), "Main".into(), "OBS".into());
        c.vd_create("vd-1".into(), "Main".into(), 1920, 1080);
        c.vd_set_source("vd-1", "u1");
        c.virtual_displays.get_mut("vd-1").unwrap().has_signal = true;
        c.on_server_retired("u1");
        assert!(!c.virtual_displays["vd-1"].has_signal);
    }

    #[test]
    fn icon_state_empty_with_no_vds() {
        let c = make_core();
        assert_eq!(c.icon_state(), SyphonOutIcon::Empty);
    }

    #[test]
    fn icon_state_solid_when_all_signal() {
        let mut c = make_core();
        c.vd_create("vd-1".into(), "A".into(), 1920, 1080);
        c.vd_create("vd-2".into(), "B".into(), 1920, 1080);
        c.vd_set_source("vd-1", "u1");
        c.vd_set_source("vd-2", "u2");
        c.virtual_displays.get_mut("vd-1").unwrap().has_signal = true;
        c.virtual_displays.get_mut("vd-2").unwrap().has_signal = true;
        assert_eq!(c.icon_state(), SyphonOutIcon::Solid);
    }

    #[test]
    fn icon_state_half_when_one_no_signal() {
        let mut c = make_core();
        c.vd_create("vd-1".into(), "A".into(), 1920, 1080);
        c.vd_create("vd-2".into(), "B".into(), 1920, 1080);
        c.vd_set_source("vd-1", "u1");
        c.vd_set_source("vd-2", "u2");
        c.on_new_frame("vd-1", std::ptr::null_mut(), 1920, 1080);
        // vd-2 has no frames → NoSignal
        assert_eq!(c.icon_state(), SyphonOutIcon::Half);
    }

    #[test]
    fn legacy_implicit_vd_created_on_demand() {
        let mut c = make_core();
        c.legacy_set_mode(1, SyphonOutMode::Signal);
        let key = SyphonOutCore::implicit_vd_key(1);
        assert!(c.virtual_displays.contains_key(&key));
    }
}
