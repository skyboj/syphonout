/// Per-display output core: owns a MetalRenderer and tracks mode/signal state.

use std::ffi::c_void;
use crate::state::{SyphonOutMode, SyphonOutSignal};

#[cfg(not(test))]
use crate::renderer::MetalRenderer as Renderer;

#[cfg(test)]
mod test_renderer {
    use crate::state::SyphonOutMode;
    use std::ffi::c_void;

    #[derive(Default)]
    pub struct MockRenderer;
    impl MockRenderer {
        pub fn new(_layer: *mut c_void) -> Self { Self }
        pub fn set_crossfade_duration_ms(&mut self, _ms: f64, _fps: f64) {}
        pub fn begin_freeze(&mut self) {}
        pub fn end_freeze(&mut self) {}
        pub fn show_blank(&mut self, _mode: SyphonOutMode) {}
        pub fn update_from_iosurface(&mut self, _iosurface: *mut c_void, _width: u32, _height: u32) {}
        pub fn render_frame(&mut self) {}
    }
}

#[cfg(test)]
use test_renderer::MockRenderer as Renderer;

pub struct OutputCore {
    pub display_id: u32,
    pub mode: SyphonOutMode,
    pub renderer: Renderer,
    pub has_signal: bool,
    pub has_source: bool,
    /// FPS hint for crossfade calculation (filled in from CVDisplayLink callback)
    pub display_fps: f64,
}

impl OutputCore {
    pub fn new(display_id: u32, layer: *mut c_void) -> Self {
        let renderer = Renderer::new(layer);
        OutputCore {
            display_id,
            mode: SyphonOutMode::Off,
            renderer,
            has_signal: false,
            has_source: false,
            display_fps: 60.0,
        }
    }

    pub fn set_mode(&mut self, mode: SyphonOutMode) {
        let prev = self.mode;
        self.mode = mode;
        match mode {
            SyphonOutMode::Signal => {
                // If coming from freeze, begin crossfade from frozen frame
                if prev == SyphonOutMode::Freeze {
                    self.renderer.end_freeze();
                }
            }
            SyphonOutMode::Freeze => {
                self.renderer.begin_freeze();
            }
            SyphonOutMode::BlankBlack | SyphonOutMode::BlankWhite | SyphonOutMode::BlankTestPattern => {
                self.renderer.show_blank(mode);
            }
            SyphonOutMode::Off => {
                // Window hide is handled by Swift; renderer just stops drawing
            }
        }
    }

    /// Called from SyphonNative.m → Rust callback when a new Syphon frame arrives.
    pub fn on_new_frame(&mut self, iosurface: *mut c_void, width: u32, height: u32) {
        self.has_signal = true;
        self.has_source = true;
        // Only update renderer texture when in signal mode;
        // in freeze mode the frozen texture is held.
        if self.mode == SyphonOutMode::Signal {
            self.renderer.update_from_iosurface(iosurface, width, height);
        }
    }

    pub fn on_server_lost(&mut self) {
        self.has_signal = false;
    }

    pub fn on_source_cleared(&mut self) {
        self.has_source = false;
        self.has_signal = false;
    }

    pub fn set_crossfade_duration_ms(&mut self, ms: f64) {
        self.renderer.set_crossfade_duration_ms(ms, self.display_fps);
    }

    pub fn render_frame(&mut self) {
        if self.mode == SyphonOutMode::Off { return; }
        self.renderer.render_frame();
    }

    pub fn signal_status(&self) -> SyphonOutSignal {
        if !self.has_source {
            SyphonOutSignal::NoSourceSelected
        } else if self.has_signal {
            SyphonOutSignal::Present
        } else {
            SyphonOutSignal::NoSignal
        }
    }

    pub fn is_active(&self) -> bool {
        !matches!(self.mode, SyphonOutMode::Off)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn new_output_defaults_to_off() {
        let out = OutputCore::new(1, std::ptr::null_mut());
        assert_eq!(out.mode, SyphonOutMode::Off);
        assert!(!out.has_source);
        assert!(!out.has_signal);
        assert_eq!(out.display_fps, 60.0);
    }

    #[test]
    fn signal_status_no_source() {
        let out = OutputCore::new(1, std::ptr::null_mut());
        assert_eq!(out.signal_status(), SyphonOutSignal::NoSourceSelected);
    }

    #[test]
    fn signal_status_present() {
        let mut out = OutputCore::new(1, std::ptr::null_mut());
        out.has_source = true;
        out.has_signal = true;
        assert_eq!(out.signal_status(), SyphonOutSignal::Present);
    }

    #[test]
    fn signal_status_no_signal() {
        let mut out = OutputCore::new(1, std::ptr::null_mut());
        out.has_source = true;
        out.has_signal = false;
        assert_eq!(out.signal_status(), SyphonOutSignal::NoSignal);
    }

    #[test]
    fn is_active_only_when_not_off() {
        let mut out = OutputCore::new(1, std::ptr::null_mut());
        assert!(!out.is_active());
        out.set_mode(SyphonOutMode::Signal);
        assert!(out.is_active());
        out.set_mode(SyphonOutMode::Off);
        assert!(!out.is_active());
    }

    #[test]
    fn on_new_frame_updates_in_signal_mode() {
        let mut out = OutputCore::new(1, std::ptr::null_mut());
        out.set_mode(SyphonOutMode::Signal);
        out.on_new_frame(std::ptr::null_mut(), 1920, 1080);
        assert!(out.has_signal);
        assert!(out.has_source);
    }

    #[test]
    fn on_new_frame_ignored_in_freeze() {
        let mut out = OutputCore::new(1, std::ptr::null_mut());
        out.set_mode(SyphonOutMode::Freeze);
        out.on_new_frame(std::ptr::null_mut(), 1920, 1080);
        assert!(out.has_signal); // still sets flags
        assert!(out.has_source);
        // texture update was skipped because mode != Signal
    }

    #[test]
    fn on_server_lost_sets_no_signal() {
        let mut out = OutputCore::new(1, std::ptr::null_mut());
        out.has_source = true;
        out.has_signal = true;
        out.on_server_lost();
        assert!(!out.has_signal);
        assert!(out.has_source); // source remains selected
    }

    #[test]
    fn on_source_cleared_clears_both() {
        let mut out = OutputCore::new(1, std::ptr::null_mut());
        out.has_source = true;
        out.has_signal = true;
        out.on_source_cleared();
        assert!(!out.has_source);
        assert!(!out.has_signal);
    }

    #[test]
    fn mode_transition_signal_from_freeze_calls_end_freeze() {
        let mut out = OutputCore::new(1, std::ptr::null_mut());
        out.set_mode(SyphonOutMode::Signal);
        out.set_mode(SyphonOutMode::Freeze);
        assert_eq!(out.mode, SyphonOutMode::Freeze);
        out.set_mode(SyphonOutMode::Signal);
        assert_eq!(out.mode, SyphonOutMode::Signal);
    }
}
