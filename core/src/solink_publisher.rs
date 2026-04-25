/// SOLink Publisher — Rust core for OBS tool plugin
/// 
/// Manages IOSurface triple-buffer, shared memory publishing, and discovery
/// for zero-copy video streaming from OBS to SyphonOut.
/// 
/// Architecture:
///   1. OBS tool plugin creates a SolinkPublisher with server name + resolution
///   2. Publisher creates IOSurface triple-buffer and shared memory region
///   3. Each frame: OBS texture → IOSurface → atomic publish via SHM
///   4. Discovery announces via NSDistributedNotificationCenter
///   5. SyphonOut subscribes via SOLinkClient.m
/// 
/// All high-performance operations (IOSurface management, atomic updates)
/// are implemented in Rust for safety and speed.

use std::ffi::{c_void, CString};
use std::sync::{Arc, Mutex};
use std::collections::HashMap;
use std::ptr;

use metal::{Device, Texture, TextureDescriptor, TextureUsage, PixelFormat};
use objc2::msg_send;
use objc2::runtime::AnyObject;

// CoreFoundation for IOSurface
#[link(name = "CoreFoundation", kind = "framework")]
extern "C" {
    fn CFRetain(cf: *mut c_void);
    fn CFRelease(cf: *mut c_void);
}

// IOSurface framework
#[link(name = "IOSurface", kind = "framework")]
extern "C" {
    fn IOSurfaceCreate(properties: *mut c_void) -> *mut c_void;
    fn IOSurfaceGetID(surface: *mut c_void) -> u32;
    fn IOSurfaceLock(surface: *mut c_void, options: u32, seed: *mut u32) -> i32;
    fn IOSurfaceUnlock(surface: *mut c_void, options: u32, seed: *mut u32) -> i32;
    fn IOSurfaceGetWidth(surface: *mut c_void) -> usize;
    fn IOSurfaceGetHeight(surface: *mut c_void) -> usize;
    fn IOSurfaceGetBytesPerRow(surface: *mut c_void) -> usize;
}

// Shared memory constants (mirror solink-protocol.h)
const SOLINK_BUFFER_COUNT: usize = 3;
const SOLINK_SHM_NAME_MAX: usize = 33;
const SOLINK_MAGIC: u32 = 0x4B4E4C53; // "SOLN" in little-endian
const SOLINK_PIXEL_FORMAT_BGRA8: u32 = 0;

/// IOSurface triple-buffer pool
struct SurfacePool {
    surfaces: [*mut c_void; SOLINK_BUFFER_COUNT],
    textures: [Option<Texture>; SOLINK_BUFFER_COUNT],
    width: u32,
    height: u32,
    pixel_format: u32,
}

impl SurfacePool {
    fn new(width: u32, height: u32, pixel_format: u32) -> Option<Self> {
        let mut surfaces = [ptr::null_mut(); SOLINK_BUFFER_COUNT];
        let textures = [None, None, None];
        
        // TODO: Implement IOSurface creation
        // For now, placeholder
        Some(Self {
            surfaces,
            textures,
            width,
            height,
            pixel_format,
        })
    }
    
    fn get_surface_id(&self, index: usize) -> u32 {
        if index >= SOLINK_BUFFER_COUNT || self.surfaces[index].is_null() {
            0
        } else {
            unsafe { IOSurfaceGetID(self.surfaces[index]) }
        }
    }
    
    fn get_texture(&mut self, index: usize, device: &Device) -> Option<&Texture> {
        if index >= SOLINK_BUFFER_COUNT {
            return None;
        }
        
        // Create texture from IOSurface if not already created
        if self.textures[index].is_none() && !self.surfaces[index].is_null() {
            let descriptor = TextureDescriptor::new();
            descriptor.set_width(self.width as u64);
            descriptor.set_height(self.height as u64);
            descriptor.set_pixel_format(PixelFormat::BGRA8Unorm);
            descriptor.set_usage(TextureUsage::SHADER_READ);
            
            // Create texture from IOSurface
            // Note: metal::Texture::from_iosurface not exposed in metal crate
            // May need to use objc2 directly
        }
        
        self.textures[index].as_ref()
    }
}

impl Drop for SurfacePool {
    fn drop(&mut self) {
        for surface in &self.surfaces {
            if !surface.is_null() {
                unsafe { CFRelease(*surface); }
            }
        }
    }
}

/// Shared memory header (matches solink-protocol.h C struct)
#[repr(C)]
struct SolinkHeader {
    magic: u32,
    version: u32,
    width: u32,
    height: u32,
    pixel_format: u32,
    buffer_count: u32,
    iosurface_ids: [u32; SOLINK_BUFFER_COUNT],
    _pad0: u32,
    frame_counter: std::sync::atomic::AtomicU64,
    current_index: std::sync::atomic::AtomicU32,
    publisher_pid: std::sync::atomic::AtomicU32,
    timestamp_ns: std::sync::atomic::AtomicU64,
    server_name: [u8; 32],
    app_name: [u8; 16],
    _reserved: [u8; 16],
}

/// Shared memory manager
struct SharedMemory {
    shm_name: String,
    header: *mut SolinkHeader,
    size: usize,
}

impl SharedMemory {
    fn create(name: &str, pool: &SurfacePool, width: u32, height: u32, 
              pixel_format: u32, server_name: &str, app_name: &str) -> Option<Self> {
        // TODO: Implement shared memory creation
        // For MVP, use existing C implementation via FFI
        None
    }
    
    fn publish_frame(&self, index: u32) {
        if self.header.is_null() {
            return;
        }
        
        unsafe {
            // Update current_index atomically
            (*self.header).current_index.store(index, std::sync::atomic::Ordering::Release);
            
            // Increment frame counter
            (*self.header).frame_counter.fetch_add(1, std::sync::atomic::Ordering::Release);
            
            // Update timestamp
            let now = std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos() as u64;
            (*self.header).timestamp_ns.store(now, std::sync::atomic::Ordering::Release);
        }
    }
}

impl Drop for SharedMemory {
    fn drop(&mut self) {
        if !self.header.is_null() {
            // TODO: Unmap shared memory
        }
    }
}

/// Main SOLink publisher instance
pub struct SolinkPublisher {
    uuid: String,
    server_name: String,
    width: u32,
    height: u32,
    
    surface_pool: Option<SurfacePool>,
    shared_memory: Option<SharedMemory>,
    
    last_write_idx: u32,
    active: bool,
}

impl SolinkPublisher {
    pub fn new(server_name: &str, width: u32, height: u32) -> Self {
        let uuid = uuid::Uuid::new_v4().to_string();
        
        Self {
            uuid,
            server_name: server_name.to_string(),
            width,
            height,
            surface_pool: None,
            shared_memory: None,
            last_write_idx: 0,
            active: false,
        }
    }
    
    pub fn start(&mut self) -> bool {
        if self.active {
            return false;
        }
        
        // Create surface pool
        let pool = match SurfacePool::new(self.width, self.height, SOLINK_PIXEL_FORMAT_BGRA8) {
            Some(pool) => pool,
            None => return false,
        };
        
        // Create shared memory
        let shm = match SharedMemory::create(
            &self.uuid,
            &pool,
            self.width,
            self.height,
            SOLINK_PIXEL_FORMAT_BGRA8,
            &self.server_name,
            "OBS"
        ) {
            Some(shm) => shm,
            None => return false,
        };
        
        // Update IOSurface IDs in shared memory header
        if let Some(shm_header) = shm.header.as_mut() {
            for i in 0..SOLINK_BUFFER_COUNT {
                shm_header.iosurface_ids[i] = pool.get_surface_id(i);
            }
        }
        
        self.surface_pool = Some(pool);
        self.shared_memory = Some(shm);
        self.active = true;
        
        // TODO: Announce via discovery
        true
    }
    
    pub fn stop(&mut self) {
        if !self.active {
            return;
        }
        
        // TODO: Retire via discovery
        
        self.shared_memory = None;
        self.surface_pool = None;
        self.active = false;
    }
    
    pub fn publish_frame(&mut self, texture: &Texture) -> bool {
        if !self.active {
            return false;
        }
        
        let next_idx = (self.last_write_idx + 1) % SOLINK_BUFFER_COUNT as u32;
        
        // TODO: Copy texture to IOSurface
        // This is complex - need to get Metal texture -> IOSurface
        
        // Publish via shared memory
        if let Some(shm) = &self.shared_memory {
            shm.publish_frame(next_idx);
        }
        
        self.last_write_idx = next_idx;
        true
    }
    
    pub fn update_resolution(&mut self, width: u32, height: u32) -> bool {
        if self.active {
            // Cannot change resolution while active
            return false;
        }
        
        self.width = width;
        self.height = height;
        true
    }
    
    pub fn is_active(&self) -> bool {
        self.active
    }
    
    pub fn get_uuid(&self) -> &str {
        &self.uuid
    }
    
    pub fn get_server_name(&self) -> &str {
        &self.server_name
    }
}

/// Global publisher instance (singleton for now)
static PUBLISHER: std::sync::OnceLock<Mutex<Option<SolinkPublisher>>> = std::sync::OnceLock::new();

fn get_publisher() -> &'static Mutex<Option<SolinkPublisher>> {
    PUBLISHER.get_or_init(|| Mutex::new(None))
}