/// Syphon server registry — updated by callbacks from SyphonNative.m.
///
/// The actual Syphon wire protocol (NSDistributedNotificationCenter discovery,
/// CFMessagePort frame IPC) lives in SyphonNative.m (Obj-C). This module
/// stores the resulting server list and per-display IOSurface textures.

use std::collections::HashMap;
use crate::state::ServerDescription;

#[derive(Default)]
pub struct SyphonRegistry {
    /// Live server list, keyed by UUID.
    pub servers: HashMap<String, ServerDescription>,
    /// Per-display: UUID of the server assigned to that display.
    pub selected: HashMap<u32, String>,
}

impl SyphonRegistry {
    pub fn announce(&mut self, uuid: String, name: String, app_name: String) {
        self.servers.insert(uuid.clone(), ServerDescription::new(uuid, name, app_name));
    }

    pub fn retire(&mut self, uuid: &str) {
        self.servers.remove(uuid);
        // Clear any outputs that were watching the retired server
        self.selected.retain(|_, v| v.as_str() != uuid);
    }

    pub fn select(&mut self, display_id: u32, uuid: String) {
        self.selected.insert(display_id, uuid);
    }

    pub fn clear_selection(&mut self, display_id: u32) {
        self.selected.remove(&display_id);
    }

    pub fn selected_uuid(&self, display_id: u32) -> Option<&str> {
        self.selected.get(&display_id).map(|s| s.as_str())
    }

    pub fn server_list(&self) -> Vec<&ServerDescription> {
        self.servers.values().collect()
    }

    pub fn selected_server_name(&self, display_id: u32) -> Option<&str> {
        let uuid = self.selected.get(&display_id)?;
        self.servers.get(uuid).map(|s| s.name.as_str())
    }
}
