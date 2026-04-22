/// A Virtual Display is the *logical video channel* owned by the user.
///
/// It carries:
///   - a user-visible `name` and a stable `uuid`
///   - the preferred logical `size` (width × height, in pixels)
///   - a current operating `mode` (signal / freeze / blank / off)
///   - the `source_uuid` it is subscribed to (Syphon or SOLink, prefixed)
///   - signal flags (`has_source`, `has_signal`) derived from frame arrivals
///   - the latest `IOSurfaceRef` (retained in Rust) plus `frame_serial` so
///     PhysicalOutputs can detect new frames without pointer comparison.
///
/// VirtualDisplay does NOT own a CAMetalLayer or Metal textures.
/// One or more PhysicalOutputs may be assigned to a VirtualDisplay
/// simultaneously — that is how mirroring is expressed.

use std::ffi::c_void;
use crate::state::{SyphonOutMode, SyphonOutSignal};

#[link(name = "CoreFoundation", kind = "framework")]
extern "C" {
    fn CFRetain(cf: *mut c_void);
    fn CFRelease(cf: *mut c_void);
}

pub struct VirtualDisplay {
    pub uuid: String,
    pub name: String,
    pub width: u32,
    pub height: u32,
    pub mode: SyphonOutMode,

    /// The source feeding this VD. Prefix identifies the bridge:
    ///   "solink:<raw>"  — obs-solink publisher
    ///   otherwise       — Syphon server UUID
    pub source_uuid: Option<String>,

    pub has_source: bool,
    pub has_signal: bool,

    /// Retained IOSurfaceRef of the latest frame, or None.
    pub iosurface: Option<*mut c_void>,
    pub frame_width: u32,
    pub frame_height: u32,
    /// Monotonically incremented on every new frame.
    pub frame_serial: u64,
}

impl VirtualDisplay {
    pub fn new(uuid: impl Into<String>, name: impl Into<String>, width: u32, height: u32) -> Self {
        Self {
            uuid: uuid.into(),
            name: name.into(),
            width,
            height,
            mode: SyphonOutMode::Signal,
            source_uuid: None,
            has_source: false,
            has_signal: false,
            iosurface: None,
            frame_width: 0,
            frame_height: 0,
            frame_serial: 0,
        }
    }

    pub fn set_mode(&mut self, mode: SyphonOutMode) {
        self.mode = mode;
    }

    pub fn set_source(&mut self, uuid: impl Into<String>) {
        self.source_uuid = Some(uuid.into());
        self.has_source = true;
        self.has_signal = false;
    }

    pub fn clear_source(&mut self) {
        self.source_uuid = None;
        self.has_source = false;
        self.has_signal = false;
    }

    pub fn on_server_lost(&mut self) {
        self.has_signal = false;
    }

    /// Called from the bridge (SyphonNative/SOLinkClient) when a new
    /// IOSurface frame arrives for this VD.
    pub fn on_new_frame(&mut self, iosurface: *mut c_void, width: u32, height: u32) {
        if iosurface.is_null() { return; }
        if let Some(old) = self.iosurface.take() {
            unsafe { CFRelease(old); }
        }
        unsafe { CFRetain(iosurface); }
        self.iosurface = Some(iosurface);
        self.frame_width = width;
        self.frame_height = height;
        self.frame_serial += 1;
        self.has_signal = true;
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

impl Drop for VirtualDisplay {
    fn drop(&mut self) {
        if let Some(s) = self.iosurface.take() {
            unsafe { CFRelease(s); }
        }
    }
}

// SAFETY: iosurface is an opaque refcounted pointer; Send/Sync is safe
// because we manage it with CFRetain/CFRelease internally.
unsafe impl Send for VirtualDisplay {}
unsafe impl Sync for VirtualDisplay {}

#[cfg(test)]
mod tests {
    use super::*;

    fn vd() -> VirtualDisplay {
        VirtualDisplay::new("vd-1", "Main", 1920, 1080)
    }

    #[test]
    fn defaults() {
        let v = vd();
        assert_eq!(v.mode, SyphonOutMode::Signal);
        assert!(!v.has_source);
        assert!(!v.has_signal);
        assert_eq!(v.width, 1920);
        assert_eq!(v.signal_status(), SyphonOutSignal::NoSourceSelected);
        assert_eq!(v.frame_serial, 0);
    }

    #[test]
    fn set_source_flips_has_source() {
        let mut v = vd();
        v.set_source("solink:abc");
        assert!(v.has_source);
        assert!(!v.has_signal);
        assert_eq!(v.signal_status(), SyphonOutSignal::NoSignal);
    }

    #[test]
    fn clear_source_drops_both_flags() {
        let mut v = vd();
        v.set_source("uuid");
        v.has_signal = true;
        v.clear_source();
        assert!(!v.has_source);
        assert!(!v.has_signal);
    }

    #[test]
    fn server_lost_only_clears_signal() {
        let mut v = vd();
        v.set_source("uuid");
        v.has_signal = true;
        v.on_server_lost();
        assert!(v.has_source);
        assert!(!v.has_signal);
        assert_eq!(v.signal_status(), SyphonOutSignal::NoSignal);
    }

    #[test]
    fn off_is_inactive() {
        let mut v = vd();
        assert!(v.is_active());
        v.set_mode(SyphonOutMode::Off);
        assert!(!v.is_active());
    }

    #[test]
    fn mode_can_be_set_to_freeze() {
        let mut v = vd();
        v.set_mode(SyphonOutMode::Freeze);
        assert_eq!(v.mode, SyphonOutMode::Freeze);
    }
}
