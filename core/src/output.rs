/// Per-display output core: owns a MetalRenderer and tracks mode/signal state.

use std::ffi::c_void;
use crate::renderer::MetalRenderer;
use crate::state::{SyphonOutMode, SyphonOutSignal};

pub struct OutputCore {
    pub display_id: u32,
    pub mode: SyphonOutMode,
    pub renderer: MetalRenderer,
    pub has_signal: bool,
    pub has_source: bool,
    /// FPS hint for crossfade calculation (filled in from CVDisplayLink callback)
    pub display_fps: f64,
}

impl OutputCore {
    pub fn new(display_id: u32, layer: *mut c_void) -> Self {
        let renderer = MetalRenderer::new(layer);
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
