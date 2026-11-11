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

use crate::compositor::{self, Content, Frame, Server, WindowEvent};
use crate::gl_import::{DRM_FORMAT_NV12, DRM_FORMAT_YUV420, GlImporter, is_planar_yuv};
use crate::gl_scene::{self, Scene};
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
    /// Scenes (video, planar YUV): the GPU draws the window into this, which Godot samples.
    target: Option<(Rid, gl_scene::Target)>,
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

    fn show_image(&mut self, gl: &GlImporter, scene: Option<&Scene>, image: *mut c_void, w: i32, h: i32) {
        if self.target.is_some() {
            self.free_gl(gl, scene);
        }
        match self.native {
            Some((_, tex, nw, nh)) if (nw, nh) == (w, h) => gl.attach(tex, image),
            _ => {
                self.free_gl(gl, scene);
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

    /// Draws `sc` into this window's target, made or resized as needed.
    fn show_scene(&mut self, gl: &GlImporter, scene: &Scene, sc: &compositor::Scene, layers: &[gl_scene::Layer]) -> bool {
        let (w, h) = (sc.width as i32, sc.height as i32);
        if self.target.as_ref().is_none_or(|(_, t)| (t.w, t.h) != (w, h)) {
            self.free_gl(gl, Some(scene));
            let t = match scene.new_target(w, h) {
                Ok(t) => t,
                Err(e) => {
                    godot_error!("compositor: {e}");
                    return false;
                }
            };
            let rid = RenderingServer::singleton().texture_create_from_native_handle(
                TextureType::TYPE_2D,
                Format::RGBA8,
                t.tex as u64,
                w,
                h,
                1,
            );
            self.target = Some((rid, t));
        }
        let Some((rid, t)) = &mut self.target else { return false };
        scene.render(t, sc.canvas.as_ref().map(|(g, f)| (*g, &f.rgba[..])), layers);
        self.rid = *rid;
        (self.w, self.h) = (w, h);
        self.base_mut().emit_changed();
        true
    }

    /// Frees whatever GL objects and RenderingServer textures this window holds.
    fn free_gl(&mut self, gl: &GlImporter, scene: Option<&Scene>) {
        if let Some((rid, tex, ..)) = self.native.take() {
            RenderingServer::singleton().free_rid(rid);
            gl.delete_texture(tex);
        }
        if let Some((rid, t)) = self.target.take() {
            RenderingServer::singleton().free_rid(rid);
            if let Some(scene) = scene {
                scene.free_target(t);
            }
        }
    }
}

/// What a dmabuf imported as: one image per plane for planar YUV, otherwise one. `texs` are the
/// GL textures the scene renderer samples, made on first use as a layer.
struct Imported {
    images: Vec<*mut c_void>,
    texs: Vec<u32>,
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
    images: HashMap<u64, Imported>,
    scene: Option<Scene>,
    /// LIVI_SHELL_YUV_MATRIX=601|709 forces the YUV matrix; by default the buffer size picks it.
    force_709: Option<bool>,
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
    /// The window's client wants text typed: `text_field(id)` says what kind.
    #[signal]
    fn text_input_wanted(id: i64);
    /// It no longer does: it disabled its text input, lost keyboard focus, or closed.
    #[signal]
    fn text_input_released(id: i64);

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
        // LIVI_SHELL_NO_DMABUF: offer wl_shm only, for clients that cope (and to tell which path a blank window is on).
        let no_dmabuf = std::env::var("LIVI_SHELL_NO_DMABUF").map(|v| !v.is_empty()).unwrap_or(false);
        match if no_dmabuf { Err("disabled by LIVI_SHELL_NO_DMABUF".to_string()) } else { GlImporter::new() } {
            Ok(gl) => {
                let scene = match Scene::new(&gl) {
                    Ok(s) => Some(s),
                    Err(e) => {
                        godot_warn!("compositor: planar YUV off: {e}");
                        None
                    }
                };
                let all = gl.formats();
                let yuv: Vec<String> = all.iter().filter(|f| is_planar_yuv(f.fourcc)).map(|f| format!("{:08x}:{:x}", f.fourcc, f.modifier)).collect();
                if scene.is_some() {
                    godot_print!("compositor: planar YUV dmabuf: {}", if yuv.is_empty() { "none (EGL imports no R8/GR88 planes)".into() } else { yuv.join(" ") });
                }
                let formats: Vec<(u32, u64)> = all
                    .iter()
                    .filter(|f| scene.is_some() || !is_planar_yuv(f.fourcc))
                    .map(|f| (f.fourcc, f.modifier))
                    .collect();
                match server.enable_dmabuf(&formats, gl.render_node()) {
                    Ok(()) => {
                        self.gl = Some(gl);
                        self.scene = scene;
                    }
                    Err(e) => self.dmabuf_off = e.to_string(),
                }
                self.force_709 = match std::env::var("LIVI_SHELL_YUV_MATRIX").as_deref() {
                    Ok("601") => Some(false),
                    Ok("709") => Some(true),
                    _ => None,
                };
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

    /// Pointer at (x, y) in the window's surface, or out of every window with id -1.
    #[func]
    fn pointer_motion(&mut self, id: i64, x: f64, y: f64) {
        if let Some(s) = self.server.as_mut() {
            s.pointer_motion((id >= 0).then_some(id as u64), x, y);
        }
    }

    /// `button` is Godot's mouse button index.
    #[func]
    fn pointer_button(&mut self, button: i64, pressed: bool) {
        if let (Some(s), Some(b)) = (self.server.as_mut(), crate::keys::evdev_button(button)) {
            s.pointer_button(b, pressed);
        }
    }

    #[func]
    fn touch_down(&mut self, id: i64, slot: i64, x: f64, y: f64) {
        if let Some(s) = self.server.as_mut() {
            s.touch_down(id as u64, slot as u32, x, y);
        }
    }

    #[func]
    fn touch_motion(&mut self, id: i64, slot: i64, x: f64, y: f64) {
        if let Some(s) = self.server.as_mut() {
            s.touch_motion(id as u64, slot as u32, x, y);
        }
    }

    #[func]
    fn touch_up(&mut self, slot: i64) {
        if let Some(s) = self.server.as_mut() {
            s.touch_up(slot as u32);
        }
    }

    /// Keyboard focus to the window, or to none with -1.
    #[func]
    fn keyboard_focus(&mut self, id: i64) {
        if let Some(s) = self.server.as_mut() {
            s.keyboard_focus((id >= 0).then_some(id as u64));
        }
    }

    /// A key by Godot's physical keycode, to the focused window. False when it has no mapping.
    #[func]
    fn key(&mut self, physical_keycode: i64, pressed: bool) -> bool {
        match (self.server.as_mut(), crate::keys::evdev(physical_keycode)) {
            (Some(s), Some(code)) => {
                s.key(code, pressed);
                true
            }
            _ => false,
        }
    }

    /// The field the window wants text for, while it does, else empty: `hint` and `purpose`
    /// (zwp_text_input_v3's content hint bits and purpose), `cursor` (a Rect2 in the window's
    /// frame pixels, when the client gave one), and `text`, `caret` and `anchor` (bytes) when it
    /// told the text around the cursor.
    #[func]
    fn text_field(&self, id: i64) -> VarDictionary {
        let mut out = VarDictionary::new();
        let Some(s) = self.server.as_ref() else { return out };
        let Some(f) = s.text_field(id as u64) else { return out };
        let k = s.state.windows.iter().find(|w| w.id == id as u64).map_or(1.0, |w| w.buffer_scale) as f32;
        out.set("hint", f.hint as i64);
        out.set("purpose", f.purpose as i64);
        if let Some([x, y, w, h]) = f.rect {
            out.set("cursor", Rect2::new(Vector2::new(x as f32 * k, y as f32 * k), Vector2::new(w as f32 * k, h as f32 * k)));
        }
        if let Some((text, caret, anchor)) = f.surrounding {
            out.set("text", &gs(text));
            out.set("caret", caret as i64);
            out.set("anchor", anchor as i64);
        }
        out
    }

    /// Whether the window's client has bound zwp_text_input_v3; without it only keys reach it.
    #[func]
    fn has_text_input(&self, id: i64) -> bool {
        self.server.as_ref().is_some_and(|s| s.has_text_input(id as u64))
    }

    /// Types into the focused window: its enabled text input's commit_string, else key presses
    /// on a US layout. False when neither takes it all.
    #[func]
    fn type_text(&mut self, text: GString) -> bool {
        self.server.as_mut().is_some_and(|s| s.type_text(&text.to_string()))
    }

    /// Types into the focused window as key presses on a US layout only, under whatever
    /// modifiers `key` holds down. False, sending nothing, when a character has no key.
    #[func]
    fn type_keys(&mut self, text: GString) -> bool {
        self.server.as_mut().is_some_and(|s| s.type_keys(&text.to_string()))
    }

    /// Deletes `before` and `after` bytes around the cursor of the enabled field. False with none.
    #[func]
    fn text_delete(&mut self, before: i64, after: i64) -> bool {
        self.server.as_ref().is_some_and(|s| s.state.text_input.delete_surrounding(before.max(0) as u32, after.max(0) as u32))
    }

    /// Text being composed at the cursor of the enabled field, replaced by the next commit; empty
    /// clears it. `caret_begin`, `caret_end`: bytes into it.
    #[func]
    fn text_preedit(&mut self, text: GString, caret_begin: i64, caret_end: i64) -> bool {
        self.server.as_ref().is_some_and(|s| s.state.text_input.preedit(&text.to_string(), caret_begin as i32, caret_end as i32))
    }

    #[func]
    fn close(&mut self, id: i64) {
        if let Some(s) = self.server.as_mut() {
            s.close(id as u64);
        }
    }

    #[func]
    fn window_count(&self) -> i64 {
        self.server.as_ref().map_or(0, |s| s.state.windows.len() as i64)
    }

    /// The window's texture becomes its video at the buffer's own size, not as the client
    /// scaled it (see `compositor::Window::native`).
    #[func]
    fn set_native(&mut self, id: i64, on: bool) {
        if let Some(s) = self.server.as_mut() {
            s.state.set_native(id as u64, on);
        }
    }

    /// Clients whose PID or process group is `pid` get scale `scale` (wp_fractional_scale, else
    /// the nearest whole scale), and windows the panel's size divided by it; 0 forgets the PID.
    /// Before the process connects: a client's scale is looked up once.
    #[func]
    fn set_process_scale(&mut self, pid: i64, scale: f64) {
        if let Some(s) = self.server.as_mut() {
            if scale > 0.0 {
                s.state.launch_scales.insert(pid as i32, scale);
            } else {
                s.state.launch_scales.remove(&(pid as i32));
            }
        }
    }

    /// Where hosted apps show, in panel pixels: windows are configured to it (over their scale),
    /// open ones at once. Projection video keeps the whole panel.
    #[func]
    fn set_app_area(&mut self, width: i64, height: i64) {
        if let Some(s) = self.server.as_mut() {
            s.state.set_app_area(width as i32, height as i32);
        }
    }

    /// Clients whose PID or process group is `pid` start their windows fullscreen rather than
    /// maximized; false forgets the PID.
    #[func]
    fn set_process_fullscreen(&mut self, pid: i64, on: bool) {
        if let Some(s) = self.server.as_mut() {
            if on {
                s.state.launch_fullscreen.insert(pid as i32);
            } else {
                s.state.launch_fullscreen.remove(&(pid as i32));
            }
        }
    }

    /// Makes the window's client fullscreen or maximized now, all its windows; the app may still
    /// ask otherwise.
    #[func]
    fn set_window_fullscreen(&mut self, id: i64, on: bool) {
        if let Some(s) = self.server.as_mut() {
            s.state.set_window_fullscreen(id as u64, on);
        }
    }

    /// Whether the window is fullscreen (else maximized).
    #[func]
    fn window_fullscreen(&self, id: i64) -> bool {
        self.server.as_ref().and_then(|s| s.state.windows.iter().find(|w| w.id == id as u64)).is_some_and(|w| w.fullscreen)
    }

    /// Closes the window's popups (menus, popovers), or every window's for -1.
    #[func]
    fn dismiss_popups(&mut self, id: i64) {
        if let Some(s) = self.server.as_mut() {
            s.state.dismiss_popups((id >= 0).then_some(id as u64));
        }
    }

    /// Scales the window's client now, all its windows.
    #[func]
    fn set_window_scale(&mut self, id: i64, scale: f64) {
        if let Some(s) = self.server.as_mut() {
            s.state.set_window_scale(id as u64, scale);
        }
    }

    /// The scale asked of the window's client, or 0 for no window.
    #[func]
    fn window_scale(&self, id: i64) -> f64 {
        self.server.as_ref().and_then(|s| s.state.windows.iter().find(|w| w.id == id as u64)).map_or(0.0, |w| w.scale)
    }

    /// The app scale for a viewer `view_mm` from the panel (`compositor::default_scale`).
    #[func]
    fn default_app_scale(view_mm: f64) -> f64 {
        compositor::default_scale(view_mm)
    }

    /// The PID of the window's client, or -1.
    #[func]
    fn window_pid(&self, id: i64) -> i64 {
        self.server.as_ref().and_then(|s| s.window_pid(id as u64)).map_or(-1, |p| p as i64)
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
                    if let Some(gl) = &self.gl {
                        tex.bind_mut().free_gl(gl, self.scene.as_ref());
                    }
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
                        Some(imp) => imp.images[0],
                        None => match gl.import(&dmabuf) {
                            Ok(i) => {
                                self.images.insert(key, Imported { images: vec![i], texs: Vec::new() });
                                i
                            }
                            Err(e) => {
                                godot_error!("compositor: {} ({}): {e}", w.app_id, w.id);
                                continue;
                            }
                        },
                    };
                    use smithay::backend::allocator::Buffer;
                    let size = dmabuf.size();
                    tex.bind_mut().show_image(gl, self.scene.as_ref(), image, size.w, size.h);
                    let took = t.elapsed();
                    s.imports += 1;
                    s.import += took;
                    s.import_max = s.import_max.max(took);
                }
                Content::Scene(sc) => {
                    let (Some(gl), Some(scene)) = (&self.gl, &self.scene) else { continue };
                    let layers: Vec<_> = sc
                        .layers
                        .iter()
                        .filter_map(|l| match scene_layer(gl, &mut self.images, l, self.force_709) {
                            Ok(l) => Some(l),
                            Err(e) => {
                                godot_error!("compositor: {} ({}): {e}", w.app_id, w.id);
                                None
                            }
                        })
                        .collect();
                    if tex.bind_mut().show_scene(gl, scene, &sc, &layers) {
                        let took = t.elapsed();
                        s.imports += 1;
                        s.import += took;
                        s.import_max = s.import_max.max(took);
                    }
                }
            }
        }
        for key in server.state.gone_buffers.drain(..) {
            if let (Some(imp), Some(gl)) = (self.images.remove(&key), &self.gl) {
                imp.texs.iter().for_each(|&t| gl.delete_texture(t));
                imp.images.iter().for_each(|&i| gl.destroy_image(i));
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
                        tex.bind_mut().free_gl(gl, self.scene.as_ref());
                    }
                    self.signals().window_unmapped().emit(id as i64);
                }
                WindowEvent::TextInput(id, true) => self.signals().text_input_wanted().emit(id as i64),
                WindowEvent::TextInput(id, false) => self.signals().text_input_released().emit(id as i64),
            }
        }
    }
}

/// A scene layer's plane textures, importing the dmabuf on first sight. Each plane's texture is
/// bound to its EGLImage once: the image tracks the buffer's memory.
fn scene_layer(gl: &GlImporter, images: &mut HashMap<u64, Imported>, l: &compositor::SceneLayer, force_709: Option<bool>) -> Result<gl_scene::Layer, String> {
    use smithay::backend::allocator::Buffer;
    let code = l.dmabuf.format().code as u32;
    if !images.contains_key(&l.key) {
        let imgs = if is_planar_yuv(code) { gl.import_planes(&l.dmabuf)? } else { vec![gl.import(&l.dmabuf)?] };
        images.insert(l.key, Imported { images: imgs, texs: Vec::new() });
    }
    let imp = images.get_mut(&l.key).ok_or("no import")?;
    if imp.texs.is_empty() {
        imp.texs = imp.images.iter().map(|_| gl.new_texture()).collect();
    }
    // Every frame, as `show_image` does: attached once, a GTK window's layer on the unit showed
    // stale content (a terminal without its text) while direct frames were current.
    for (&t, &i) in imp.texs.iter().zip(&imp.images) {
        gl.attach(t, i);
    }
    let kind = match code {
        DRM_FORMAT_NV12 => gl_scene::Kind::Nv12,
        DRM_FORMAT_YUV420 => gl_scene::Kind::I420,
        _ => gl_scene::Kind::Rgb { opaque: !smithay::backend::allocator::format::has_alpha(l.dmabuf.format().code) },
    };
    let size = l.dmabuf.size();
    let mut tex = [0; 3];
    for (t, &n) in tex.iter_mut().zip(&imp.texs) {
        *t = n;
    }
    Ok(gl_scene::Layer {
        x: l.x,
        y: l.y,
        w: l.w,
        h: l.h,
        src: l.src,
        kind,
        tex,
        hd: force_709.unwrap_or_else(|| crate::yuv::is_709(size.w as u32, size.h as u32)),
    })
}
