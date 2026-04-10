use std::ffi::CString;

/// Output operating mode — C-repr so cbindgen exports it correctly.
#[repr(C)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SyphonOutMode {
    Signal = 0,
    Freeze = 1,
    BlankBlack = 2,
    BlankWhite = 3,
    BlankTestPattern = 4,
    Off = 5,
}

/// Global menu-bar icon state.
#[repr(C)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SyphonOutIcon {
    /// ● All active outputs have live signal
    Solid = 0,
    /// ◑ At least one output frozen / no signal
    Half = 1,
    /// ○ All outputs blank or off
    Empty = 2,
}

/// Per-output signal status.
#[repr(C)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SyphonOutSignal {
    Present = 0,
    NoSignal = 1,
    NoSourceSelected = 2,
}

/// Server description, passed to Swift callbacks.
/// All pointers are valid only for the duration of the callback invocation.
#[repr(C)]
pub struct SyphonOutServerInfo {
    pub uuid: *const libc::c_char,
    pub name: *const libc::c_char,
    pub app_name: *const libc::c_char,
}

/// Owned server description stored inside Rust state.
#[derive(Debug, Clone)]
pub struct ServerDescription {
    pub uuid: String,
    pub name: String,
    pub app_name: String,
}

impl ServerDescription {
    pub fn new(uuid: impl Into<String>, name: impl Into<String>, app_name: impl Into<String>) -> Self {
        Self { uuid: uuid.into(), name: name.into(), app_name: app_name.into() }
    }

    /// Construct temporary C strings and call `f` with a SyphonOutServerInfo.
    /// The pointers are valid only within the closure.
    pub fn with_c_repr<F: FnOnce(&SyphonOutServerInfo)>(&self, f: F) {
        let uuid_c = CString::new(self.uuid.as_str()).unwrap_or_default();
        let name_c = CString::new(self.name.as_str()).unwrap_or_default();
        let app_c = CString::new(self.app_name.as_str()).unwrap_or_default();
        let info = SyphonOutServerInfo {
            uuid: uuid_c.as_ptr(),
            name: name_c.as_ptr(),
            app_name: app_c.as_ptr(),
        };
        f(&info);
    }
}
