/// Syphon server registry — updated by callbacks from SyphonNative.m.
///
/// The actual Syphon wire protocol (NSDistributedNotificationCenter discovery,
/// CFMessagePort frame IPC) lives in SyphonNative.m (Obj-C). This module
/// stores the resulting server list. Selection (which server feeds which VD)
/// lives in VirtualDisplay, not here.

use std::collections::HashMap;
use crate::state::ServerDescription;

#[derive(Default)]
pub struct SyphonRegistry {
    /// Live server list, keyed by UUID.
    pub servers: HashMap<String, ServerDescription>,
}

impl SyphonRegistry {
    pub fn announce(&mut self, uuid: String, name: String, app_name: String) {
        self.servers.insert(uuid.clone(), ServerDescription::new(uuid, name, app_name));
    }

    pub fn retire(&mut self, uuid: &str) {
        self.servers.remove(uuid);
    }

    pub fn server_list(&self) -> Vec<&ServerDescription> {
        self.servers.values().collect()
    }

    pub fn server_name(&self, uuid: &str) -> Option<&str> {
        self.servers.get(uuid).map(|s| s.name.as_str())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn announce_adds_server() {
        let mut r = SyphonRegistry::default();
        r.announce("u1".into(), "Main".into(), "OBS".into());
        assert_eq!(r.server_list().len(), 1);
        assert_eq!(r.servers["u1"].name, "Main");
    }

    #[test]
    fn retire_removes_server() {
        let mut r = SyphonRegistry::default();
        r.announce("u1".into(), "Main".into(), "OBS".into());
        r.retire("u1");
        assert!(r.servers.is_empty());
    }

    #[test]
    fn server_name_lookup() {
        let mut r = SyphonRegistry::default();
        r.announce("u1".into(), "Main".into(), "OBS".into());
        assert_eq!(r.server_name("u1"), Some("Main"));
        assert_eq!(r.server_name("missing"), None);
    }

    #[test]
    fn server_list_returns_all() {
        let mut r = SyphonRegistry::default();
        r.announce("u1".into(), "A".into(), "OBS".into());
        r.announce("u2".into(), "B".into(), "OBS".into());
        let list = r.server_list();
        assert_eq!(list.len(), 2);
    }
}
