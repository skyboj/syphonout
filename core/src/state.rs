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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn mode_discriminants_match_c_ffi() {
        assert_eq!(SyphonOutMode::Signal as u32, 0);
        assert_eq!(SyphonOutMode::Freeze as u32, 1);
        assert_eq!(SyphonOutMode::BlankBlack as u32, 2);
        assert_eq!(SyphonOutMode::BlankWhite as u32, 3);
        assert_eq!(SyphonOutMode::BlankTestPattern as u32, 4);
        assert_eq!(SyphonOutMode::Off as u32, 5);
    }

    #[test]
    fn icon_discriminants_match_c_ffi() {
        assert_eq!(SyphonOutIcon::Solid as u32, 0);
        assert_eq!(SyphonOutIcon::Half as u32, 1);
        assert_eq!(SyphonOutIcon::Empty as u32, 2);
    }

    #[test]
    fn signal_discriminants_match_c_ffi() {
        assert_eq!(SyphonOutSignal::Present as u32, 0);
        assert_eq!(SyphonOutSignal::NoSignal as u32, 1);
        assert_eq!(SyphonOutSignal::NoSourceSelected as u32, 2);
    }

    #[test]
    fn server_description_new_and_clone() {
        let s = ServerDescription::new("uuid-1", "Main", "OBS");
        assert_eq!(s.uuid, "uuid-1");
        assert_eq!(s.name, "Main");
        assert_eq!(s.app_name, "OBS");
        let cloned = s.clone();
        assert_eq!(cloned.uuid, "uuid-1");
    }

    #[test]
    fn server_description_with_c_repr_non_null_pointers() {
        let s = ServerDescription::new("abc", "def", "ghi");
        s.with_c_repr(|info| {
            assert!(!info.uuid.is_null());
            assert!(!info.name.is_null());
            assert!(!info.app_name.is_null());
        });
    }
}
