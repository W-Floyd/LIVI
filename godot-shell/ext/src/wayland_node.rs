//! The compositor as a Godot node: each frame it handles clients, turns new buffers into
//! textures (shm copied, dmabuf imported without a copy), emits window signals, and then lets
//! clients draw again.

use std::collections::HashMap;
use std::ffi::c_void;
use std::time::{Duration, Instant};

use godot::classes::image::Format;
use godot::classes::rendering_server::TextureType;
use godot::classes::{INode, ITexture2D, Image, ImageTexture, Node, RenderingServer, Texture2D};
use godot::prelude::*;

use crate::compositor::{Content, Frame, Server, WindowEvent};
use crate::gl_import::GlImporter;
use crate::gs;

/// Since the last `reset_stats`: what compositing costs the shell's main thread.
#[derive(Default)]
struct Stats {
    pumps: u64,
    dispatch: Duration,
    dispatch_max: Duration,
    upload: Duration,
    upload_max: Duration,
    uploads: u64,
    bytes: u64,
    imports: u64,
    import: Duration,
    import_max: Duration,
    /// Buffers taken per app_id.
    frames: HashMap<String, u64>,
}

/// One window's picture, the same object for the window's whole life, whichever way its
/// buffers arrive. Controls showing it redraw when it emits `changed`.
#[derive(GodotClass)]
#[class(base = Texture2D, init)]
pub struct WindowTexture {
    #[init(val = Rid::Invalid)]
    rid: Rid,
    w: i32,
    h: i32,
    /// shm frames, uploaded by Godot.
    image: Option<Gd<ImageTexture>>,
    /// dmabuf frames: a GL texture of ours, re-pointed at each buffer's EGLImage, and the
    /// RenderingServer texture wrapping it.
    native: Option<(Rid, u32, i32, i32)>,
    base: Base<Texture2D>,
}

#[godot_api]
impl ITexture2D for WindowTexture {
    fn get_width(&self) -> i32 {
        self.w
    }

    fn get_height(&self) -> i32 {
        self.h
    }

    fn get_rid(&self) -> Rid {
        self.rid
    }
}

impl WindowTexture {
    fn show_pixels(&mut self, f: Frame) -> bool {
        let data = PackedByteArray::from(f.rgba);
        let Some(img) = Image::create_from_data(f.width as i32, f.height as i32, false, Format::RGBA8, &data)
        else {
            return false;
        };
        match &mut self.image {
            Some(tex) if (tex.get_width(), tex.get_height()) == (img.get_width(), img.get_height()) => tex.update(&img),
            _ => self.image = ImageTexture::create_from_image(&img),
        }
        let Some(tex) = &self.image else { return false };
        self.rid = tex.get_rid();
        (self.w, self.h) = (img.get_width(), img.get_height());
        self.base_mut().emit_changed();
        true
    }

    fn show_image(&mut self, gl: &GlImporter, image: *mut c_void, w: i32, h: i32) {
        match self.native {
            Some((_, tex, nw, nh)) if (nw, nh) == (w, h) => gl.attach(tex, image),
            _ => {
                self.free_native(gl);
                let tex = gl.new_texture();
                gl.attach(tex, image);
                let rid = RenderingServer::singleton().texture_create_from_native_handle(
                    TextureType::TYPE_2D,
                    Format::RGBA8,
                    tex as u64,
                    w,
                    h,
                    1,
                );
                self.native = Some((rid, tex, w, h));
            }
        }
        if let Some((rid, ..)) = self.native {
            self.rid = rid;
        }
        (self.w, self.h) = (w, h);
        self.base_mut().emit_changed();
    }

    fn free_native(&mut self, gl: &GlImporter) {
        if let Some((rid, tex, ..)) = self.native.take() {
            RenderingServer::singleton().free_rid(rid);
            gl.delete_texture(tex);
        }
    }
}

#[derive(GodotClass)]
#[class(base = Node, init)]
pub struct WaylandCompositor {
    server: Option<Server>,
    textures: HashMap<u64, Gd<WindowTexture>>,
    gl: Option<GlImporter>,
    /// Why dmabuf is off, or empty when it's on.
    dmabuf_off: String,
    /// EGLImages by buffer key, while the client keeps the buffer.
    images: HashMap<u64, *mut c_void>,
    stats: Stats,
    base: Base<Node>,
}

#[godot_api]
impl INode for WaylandCompositor {
    fn process(&mut self, _delta: f64) {
        self.pump();
    }
}

#[godot_api]
impl WaylandCompositor {
    /// After its first buffer, so `texture(id)` is ready.
    #[signal]
    fn window_mapped(id: i64, app_id: GString, title: GString);
    #[signal]
    fn window_unmapped(id: i64);

    /// Listens on `name` in XDG_RUNTIME_DIR, or the first free `wayland-N` when empty, and
    /// offers dmabuf when Godot's GL context can import it. Returns an error.
    #[func]
    fn listen(&mut self, name: GString) -> GString {
        let mut server = match Server::new() {
            Ok(s) => s,
            Err(e) => return gs(e.to_string()),
        };
        if let Err(e) = server.listen(&name.to_string()) {
            return gs(format!("{name}: {e}"));
        }
        match GlImporter::new() {
            Ok(gl) => {
                let formats: Vec<(u32, u64)> = gl.formats().iter().map(|f| (f.fourcc, f.modifier)).collect();
                match server.enable_dmabuf(&formats, gl.render_node()) {
                    Ok(()) => self.gl = Some(gl),
                    Err(e) => self.dmabuf_off = e.to_string(),
                }
            }
            Err(e) => self.dmabuf_off = e,
        }
        if !self.dmabuf_off.is_empty() {
            godot_warn!("compositor: dmabuf off: {}", self.dmabuf_off);
        }
        self.server = Some(server);
        GString::new()
    }

    #[func]
    fn socket_name(&self) -> GString {
        self.server.as_ref().map(|s| gs(s.socket_name())).unwrap_or_default()
    }

    /// Empty when dmabuf is offered; otherwise why not.
    #[func]
    fn dmabuf_status(&self) -> GString {
        gs(&self.dmabuf_off)
    }

    #[func]
    fn texture(&self, id: i64) -> Option<Gd<WindowTexture>> {
        self.textures.get(&(id as u64)).cloned()
    }

    /// Milliseconds and counts since `reset_stats`: `dispatch_ms`, `upload_ms` (shm) and
    /// `import_ms` (dmabuf), each mean and `_max`; `uploads`, `imports`, `upload_mb`; and
    /// `frames`, buffers taken per app_id.
    #[func]
    fn stats(&self) -> VarDictionary {
        let s = &self.stats;
        let ms = |d: Duration| d.as_secs_f64() * 1000.0;
        let mean = |d: Duration, n: u64| if n == 0 { 0.0 } else { ms(d) / n as f64 };
        let mut frames = VarDictionary::new();
        for (app_id, n) in &s.frames {
            frames.set(&gs(app_id), *n as i64);
        }
        let mut out = VarDictionary::new();
        out.set("dispatch_ms", mean(s.dispatch, s.pumps));
        out.set("dispatch_ms_max", ms(s.dispatch_max));
        out.set("upload_ms", mean(s.upload, s.uploads));
        out.set("upload_ms_max", ms(s.upload_max));
        out.set("uploads", s.uploads as i64);
        out.set("upload_mb", s.bytes as f64 / 1e6);
        out.set("import_ms", mean(s.import, s.imports));
        out.set("import_ms_max", ms(s.import_max));
        out.set("imports", s.imports as i64);
        out.set("frames", &frames);
        out
    }

    #[func]
    fn reset_stats(&mut self) {
        self.stats = Stats::default();
    }

    #[func]
    fn window_count(&self) -> i64 {
        self.server.as_ref().map_or(0, |s| s.state.windows.len() as i64)
    }

    /// The newest mapped window with this app_id, or -1.
    #[func]
    fn find_window(&self, app_id: GString) -> i64 {
        let app_id = app_id.to_string();
        self.server
            .as_ref()
            .and_then(|s| s.state.windows.iter().rev().find(|w| w.mapped && w.app_id == app_id))
            .map_or(-1, |w| w.id as i64)
    }
}

impl WaylandCompositor {
    fn pump(&mut self) {
        let Some(server) = self.server.as_mut() else {
            return;
        };
        let t = Instant::now();
        if let Err(e) = server.dispatch() {
            godot_error!("compositor: {e}");
        }
        let s = &mut self.stats;
        let took = t.elapsed();
        s.pumps += 1;
        s.dispatch += took;
        s.dispatch_max = s.dispatch_max.max(took);
        for w in &mut server.state.windows {
            let Some(content) = w.frame.take() else { continue };
            *s.frames.entry(w.app_id.clone()).or_default() += 1;
            let tex = self.textures.entry(w.id).or_insert_with(WindowTexture::new_gd);
            let t = Instant::now();
            match content {
                Content::Pixels(f) => {
                    s.bytes += f.rgba.len() as u64;
                    if tex.bind_mut().show_pixels(f) {
                        let took = t.elapsed();
                        s.uploads += 1;
                        s.upload += took;
                        s.upload_max = s.upload_max.max(took);
                    }
                }
                Content::Dmabuf { key, dmabuf } => {
                    let Some(gl) = &self.gl else { continue };
                    let image = match self.images.get(&key) {
                        Some(&i) => i,
                        None => match gl.import(&dmabuf) {
                            Ok(i) => *self.images.entry(key).or_insert(i),
                            Err(e) => {
                                godot_error!("compositor: {} ({}): {e}", w.app_id, w.id);
                                continue;
                            }
                        },
                    };
                    use smithay::backend::allocator::Buffer;
                    let size = dmabuf.size();
                    tex.bind_mut().show_image(gl, image, size.w, size.h);
                    let took = t.elapsed();
                    s.imports += 1;
                    s.import += took;
                    s.import_max = s.import_max.max(took);
                }
            }
        }
        for key in server.state.gone_buffers.drain(..) {
            if let (Some(image), Some(gl)) = (self.images.remove(&key), &self.gl) {
                gl.destroy_image(image);
            }
        }
        let events = std::mem::take(&mut server.state.events);
        let windows: HashMap<u64, (String, String)> = server
            .state
            .windows
            .iter()
            .map(|w| (w.id, (w.app_id.clone(), w.title.clone())))
            .collect();
        server.frame_done();
        for ev in events {
            match ev {
                WindowEvent::Mapped(id) => {
                    let (app_id, title) = windows.get(&id).cloned().unwrap_or_default();
                    self.signals().window_mapped().emit(id as i64, &gs(app_id), &gs(title));
                }
                WindowEvent::Unmapped(id) => {
                    if let (Some(mut tex), Some(gl)) = (self.textures.remove(&id), &self.gl) {
                        tex.bind_mut().free_native(gl);
                    }
                    self.signals().window_unmapped().emit(id as i64);
                }
            }
        }
    }
}
