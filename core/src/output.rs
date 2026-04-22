/// Per-display output: thin presenter that renders whatever `VirtualDisplay`
/// it is assigned to. Owns the `MetalRenderer` (CAMetalLayer + Metal pipeline).
///
/// Assignment-swap crossfade happens automatically: when a new VD is attached
/// and its first frame is delivered, `update_from_iosurface` promotes the old
/// renderer state to `previous_texture` and starts a crossfade.

use std::ffi::c_void;
use crate::state::{SyphonOutMode, SyphonOutSignal};
use crate::virtual_display::VirtualDisplay;

#[cfg(not(test))]
use crate::renderer::MetalRenderer as Renderer;

#[cfg(test)]
mod test_renderer {
    use std::ffi::c_void;
    pub struct MockRenderer;
    impl MockRenderer {
        pub fn new(_layer: *mut c_void) -> Self { Self }
        pub fn set_crossfade_duration_ms(&mut self, _ms: f64, _fps: f64) {}
        pub fn begin_freeze(&mut self) {}
        pub fn end_freeze(&mut self) {}
        pub fn show_blank(&mut self, _mode: super::SyphonOutMode) {}
        pub fn update_from_iosurface(&mut self, _iosurface: *mut c_void, _width: u32, _height: u32) {}
        pub fn render_frame(&mut self) {}
    }
}

#[cfg(test)]
use test_renderer::MockRenderer as Renderer;

pub struct PhysicalOutput {
    pub display_id: u32,
    pub renderer: Renderer,

    /// FPS hint from CVDisplayLink, used for crossfade step calculation.
    pub display_fps: f64,

    /// The last VD mode we rendered. Used to detect transitions.
    pub last_vd_mode: SyphonOutMode,
    /// The last frame_serial consumed from the assigned VD. Used to detect new frames.
    pub last_frame_serial: u64,
}

impl PhysicalOutput {
    pub fn new(display_id: u32, layer: *mut c_void) -> Self {
        Self {
            display_id,
            renderer: Renderer::new(layer),
            display_fps: 60.0,
            last_vd_mode: SyphonOutMode::Off,
            last_frame_serial: 0,
        }
    }

    pub fn set_crossfade_duration_ms(&mut self, ms: f64) {
        self.renderer.set_crossfade_duration_ms(ms, self.display_fps);
    }

    /// Render one frame. `vd` is the currently assigned VirtualDisplay, if any.
    pub fn render_frame(&mut self, vd: Option<&VirtualDisplay>) {
        if let Some(vd) = vd {
            // ── Mode transitions ───────────────────────────────────────
            if vd.mode != self.last_vd_mode {
                match vd.mode {
                    SyphonOutMode::Signal => {
                        if self.last_vd_mode == SyphonOutMode::Freeze {
                            self.renderer.end_freeze();
                        }
                        // Pull the latest frame now so we crossfade into live
                        self.try_update_from_vd(vd);
                    }
                    SyphonOutMode::Freeze => {
                        self.renderer.begin_freeze();
                    }
                    SyphonOutMode::BlankBlack |
                    SyphonOutMode::BlankWhite |
                    SyphonOutMode::BlankTestPattern => {
                        self.renderer.show_blank(vd.mode);
                    }
                    SyphonOutMode::Off => {}
                }
                self.last_vd_mode = vd.mode;
            }

            // ── Frame update (only in Signal mode) ──────────────────
            if vd.mode == SyphonOutMode::Signal {
                self.try_update_from_vd(vd);
            }
        }

        self.renderer.render_frame();
    }

    /// If the VD has a newer frame than we've consumed, forward it to the renderer.
    fn try_update_from_vd(&mut self, vd: &VirtualDisplay) {
        if vd.frame_serial > self.last_frame_serial {
            if let Some(surface) = vd.iosurface {
                self.renderer.update_from_iosurface(surface, vd.frame_width, vd.frame_height);
            }
            self.last_frame_serial = vd.frame_serial;
        }
    }

    // ── Status helpers (used by Core for icon / signal aggregation) ──

    pub fn signal_status(&self, vd: Option<&VirtualDisplay>) -> SyphonOutSignal {
        vd.map(|v| v.signal_status())
            .unwrap_or(SyphonOutSignal::NoSourceSelected)
    }

    pub fn is_active(&self, vd: Option<&VirtualDisplay>) -> bool {
        vd.map(|v| v.is_active()).unwrap_or(false)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn make_po(id: u32) -> PhysicalOutput {
        PhysicalOutput::new(id, std::ptr::null_mut())
    }

    fn make_vd() -> VirtualDisplay {
        VirtualDisplay::new("vd-1", "Main", 1920, 1080)
    }

    #[test]
    fn new_defaults() {
        let po = make_po(1);
        assert_eq!(po.display_fps, 60.0);
        assert_eq!(po.last_vd_mode, SyphonOutMode::Off);
        assert_eq!(po.last_frame_serial, 0);
    }

    #[test]
    fn signal_status_no_vd() {
        let po = make_po(1);
        assert_eq!(po.signal_status(None), SyphonOutSignal::NoSourceSelected);
    }

    #[test]
    fn is_active_no_vd() {
        let po = make_po(1);
        assert!(!po.is_active(None));
    }

    #[test]
    fn is_active_with_vd() {
        let po = make_po(1);
        let vd = make_vd();
        assert!(po.is_active(Some(&vd)));
    }
}
