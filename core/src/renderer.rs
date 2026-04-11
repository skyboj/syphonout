/// Metal renderer for one CAMetalLayer output.
///
/// The `CAMetalLayer *` is created in Swift and passed via FFI.
/// Shader functions live in `Shaders.metal` (compiled by Xcode → default.metallib).
/// Key interop note: the `metal` crate uses its own embedded `objc` runtime.
/// When calling ObjC methods via `objc2::msg_send!`, we cast metal pointers to
/// `*mut AnyObject` (both are raw ObjC id pointers at the machine level).

use metal::{
    foreign_types::{ForeignType, ForeignTypeRef},
    CommandQueue, Device, MTLClearColor, MTLLoadAction, MTLPixelFormat,
    MTLPrimitiveType, MTLStoreAction, MTLSamplerMinMagFilter, MTLSamplerMipFilter,
    MTLTextureType, MTLTextureUsage,
    RenderPassDescriptor, RenderPipelineDescriptor, RenderPipelineState,
    SamplerDescriptor, SamplerState, TextureDescriptor, TextureRef,
};
use std::ffi::c_void;
use objc2::msg_send;
use objc2::runtime::AnyObject;

use crate::state::SyphonOutMode;

struct Pipelines {
    passthrough: RenderPipelineState,
    crossfade:   RenderPipelineState,
    solid_color: RenderPipelineState,
    smpte_bars:  RenderPipelineState,
}

pub struct MetalRenderer {
    device:   Device,
    queue:    CommandQueue,
    pipelines: Option<Pipelines>,
    sampler:  SamplerState,

    /// Raw CAMetalLayer *. Retained alive by Swift's NSWindow content view.
    layer: *mut AnyObject,

    current_texture:  Option<metal::Texture>,
    previous_texture: Option<metal::Texture>,
    frozen_texture:   Option<metal::Texture>,

    crossfade_alpha:   f32,
    is_crossfading:    bool,
    crossfade_step:    f32,

    blank_color:       Option<[f32; 4]>,
    show_test_pattern: bool,
}

// SAFETY: CAMetalLayer * lives as long as the Swift NSWindow; Metal is thread-safe.
unsafe impl Send for MetalRenderer {}
unsafe impl Sync for MetalRenderer {}

impl MetalRenderer {
    pub fn new(layer: *mut c_void) -> Self {
        let layer = layer as *mut AnyObject;

        // Get MTLDevice from CAMetalLayer via ObjC runtime
        let device_ptr: *mut AnyObject = unsafe { msg_send![layer, device] };
        let device: Device = unsafe { ForeignType::from_ptr(device_ptr as *mut _) };

        let queue = device.new_command_queue();

        let sd = SamplerDescriptor::new();
        sd.set_min_filter(MTLSamplerMinMagFilter::Linear);
        sd.set_mag_filter(MTLSamplerMinMagFilter::Linear);
        sd.set_mip_filter(MTLSamplerMipFilter::NotMipmapped);
        let sampler = device.new_sampler(&sd);

        let mut r = MetalRenderer {
            device,
            queue,
            pipelines: None,
            sampler,
            layer,
            current_texture: None,
            previous_texture: None,
            frozen_texture: None,
            crossfade_alpha: 1.0,
            is_crossfading: false,
            crossfade_step: 1.0 / 6.0,   // 100ms @ 60fps
            blank_color: None,
            show_test_pattern: false,
        };
        r.build_pipelines();
        r
    }

    pub fn set_crossfade_duration_ms(&mut self, ms: f64, fps: f64) {
        let frames = (ms / 1000.0 * fps).max(1.0);
        self.crossfade_step = (1.0 / frames) as f32;
    }

    // ── Texture updates ──────────────────────────────────────────────────────

    /// Zero-copy: bind IOSurface to MTLTexture and begin crossfade.
    pub fn update_from_iosurface(&mut self, iosurface: *mut c_void, width: u32, height: u32) {
        let desc = TextureDescriptor::new();
        desc.set_pixel_format(MTLPixelFormat::BGRA8Unorm);
        desc.set_width(width as u64);
        desc.set_height(height as u64);
        desc.set_texture_type(MTLTextureType::D2);
        desc.set_usage(MTLTextureUsage::ShaderRead);

        // newTextureWithDescriptor:iosurface:plane: — GPU binds IOSurface memory directly.
        // Cast device/desc pointers to *mut AnyObject so objc2::msg_send! accepts them.
        let device_raw: *mut AnyObject = self.device.as_ptr() as *mut AnyObject;
        let desc_raw = desc.as_ptr() as *mut c_void;

        let tex_ptr: *mut AnyObject = unsafe {
            msg_send![device_raw, newTextureWithDescriptor: desc_raw, iosurface: iosurface, plane: 0u64]
        };
        if tex_ptr.is_null() { return; }

        let tex: metal::Texture = unsafe { ForeignType::from_ptr(tex_ptr as *mut _) };

        self.previous_texture = self.current_texture.take();
        self.current_texture  = Some(tex);
        self.blank_color       = None;
        self.show_test_pattern = false;

        if self.previous_texture.is_some() {
            self.crossfade_alpha = 0.0;
            self.is_crossfading  = true;
        } else {
            self.crossfade_alpha = 1.0;
        }
    }

    // ── Mode transitions ─────────────────────────────────────────────────────

    pub fn begin_freeze(&mut self) {
        self.frozen_texture = self.current_texture.as_ref().map(|t| {
            unsafe { ForeignType::from_ptr(t.as_ptr()) }
        });
    }

    pub fn end_freeze(&mut self) {
        if self.frozen_texture.is_some() {
            self.previous_texture = self.frozen_texture.take();
            self.crossfade_alpha  = 0.0;
            self.is_crossfading   = true;
        }
    }

    pub fn show_blank(&mut self, mode: SyphonOutMode) {
        self.show_test_pattern = false;
        self.is_crossfading    = false;
        match mode {
            SyphonOutMode::BlankBlack       => self.blank_color = Some([0.0, 0.0, 0.0, 1.0]),
            SyphonOutMode::BlankWhite       => self.blank_color = Some([1.0, 1.0, 1.0, 1.0]),
            SyphonOutMode::BlankTestPattern => { self.blank_color = None; self.show_test_pattern = true; }
            _ => {}
        }
    }

    // ── Render ───────────────────────────────────────────────────────────────

    pub fn render_frame(&mut self) {
        let Some(pipes) = &self.pipelines else { return };

        // Advance crossfade
        if self.is_crossfading {
            self.crossfade_alpha = (self.crossfade_alpha + self.crossfade_step).min(1.0);
            if self.crossfade_alpha >= 1.0 {
                self.is_crossfading   = false;
                self.previous_texture = None;
            }
        }

        // Acquire CAMetalLayer drawable
        let drawable: *mut AnyObject = unsafe { msg_send![self.layer, nextDrawable] };
        if drawable.is_null() { return; }
        let raw_tex: *mut AnyObject = unsafe { msg_send![drawable, texture] };
        if raw_tex.is_null() { return; }

        // Render pass targeting the drawable texture
        let rp = RenderPassDescriptor::new();
        {
            let ca = rp.color_attachments().object_at(0).unwrap();
            let tex_ref: &TextureRef = unsafe { ForeignTypeRef::from_ptr(raw_tex as *mut _) };
            ca.set_texture(Some(tex_ref));
            ca.set_load_action(MTLLoadAction::Clear);
            ca.set_store_action(MTLStoreAction::Store);
            ca.set_clear_color(MTLClearColor { red: 0.0, green: 0.0, blue: 0.0, alpha: 1.0 });
        }

        let cmd = self.queue.new_command_buffer();
        let enc = cmd.new_render_command_encoder(&rp);

        let display_tex = self.frozen_texture.as_ref().or(self.current_texture.as_ref());

        // metal 0.29 API: set_fragment_bytes(index, length, bytes)
        //                 set_fragment_texture(index, Option<&TextureRef>)
        //                 set_fragment_sampler_state(index, Option<&SamplerStateRef>)

        if self.show_test_pattern {
            enc.set_render_pipeline_state(&pipes.smpte_bars);
            enc.draw_primitives(MTLPrimitiveType::Triangle, 0, 6);

        } else if let Some(color) = self.blank_color {
            enc.set_render_pipeline_state(&pipes.solid_color);
            unsafe { enc.set_fragment_bytes(0, 16, color.as_ptr() as *const _) };
            enc.draw_primitives(MTLPrimitiveType::Triangle, 0, 6);

        } else if self.is_crossfading {
            if let (Some(prev), Some(curr)) = (&self.previous_texture, display_tex) {
                enc.set_render_pipeline_state(&pipes.crossfade);
                enc.set_fragment_texture(0, Some(prev.as_ref()));
                enc.set_fragment_texture(1, Some(curr.as_ref()));
                enc.set_fragment_sampler_state(0, Some(self.sampler.as_ref()));
                let alpha = self.crossfade_alpha;
                unsafe { enc.set_fragment_bytes(0, 4, &alpha as *const f32 as *const _) };
                enc.draw_primitives(MTLPrimitiveType::Triangle, 0, 6);
            }

        } else if let Some(tex) = display_tex {
            enc.set_render_pipeline_state(&pipes.passthrough);
            enc.set_fragment_texture(0, Some(tex.as_ref()));
            enc.set_fragment_sampler_state(0, Some(self.sampler.as_ref()));
            enc.draw_primitives(MTLPrimitiveType::Triangle, 0, 6);

        } else {
            // No source → black
            enc.set_render_pipeline_state(&pipes.solid_color);
            let black: [f32; 4] = [0.0, 0.0, 0.0, 1.0];
            unsafe { enc.set_fragment_bytes(0, 16, black.as_ptr() as *const _) };
            enc.draw_primitives(MTLPrimitiveType::Triangle, 0, 6);
        }

        enc.end_encoding();

        // Present drawable via ObjC (cast cmd ptr to AnyObject for objc2 compat)
        let cmd_raw: *mut AnyObject = cmd.as_ptr() as *mut AnyObject;
        let (): () = unsafe { msg_send![cmd_raw, presentDrawable: drawable] };
        cmd.commit();
    }

    // ── Pipeline setup ───────────────────────────────────────────────────────

    fn build_pipelines(&mut self) {
        let library = self.device.new_default_library();

        let vert = match library.get_function("vertexShader", None) {
            Ok(f)  => f,
            Err(e) => { eprintln!("[SyphonOut] missing vertexShader: {e}"); return; }
        };

        let make = |frag_name: &str| -> Option<RenderPipelineState> {
            let frag = library.get_function(frag_name, None).ok()?;
            let desc = RenderPipelineDescriptor::new();
            desc.set_vertex_function(Some(&vert));
            desc.set_fragment_function(Some(&frag));
            desc.color_attachments()
                .object_at(0)?
                .set_pixel_format(MTLPixelFormat::BGRA8Unorm);
            self.device.new_render_pipeline_state(&desc).ok()
        };

        let (Some(p), Some(c), Some(s), Some(t)) = (
            make("passthroughFragment"),
            make("crossfadeFragment"),
            make("solidColorFragment"),
            make("smpteBarsFragment"),
        ) else {
            eprintln!("[SyphonOut] One or more render pipelines failed to compile");
            return;
        };

        self.pipelines = Some(Pipelines { passthrough: p, crossfade: c, solid_color: s, smpte_bars: t });
    }
}
