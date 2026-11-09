//! The compositor as a Godot node: each frame it handles clients, uploads new buffers to
//! textures, emits window signals, and then lets clients draw again.

use std::collections::HashMap;
use std::time::{Duration, Instant};

use godot::classes::image::Format;
use godot::classes::{INode, Image, ImageTexture, Node};
use godot::prelude::*;

use crate::compositor::{Server, WindowEvent};
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
    /// Buffers taken per app_id.
    frames: HashMap<String, u64>,
}

#[derive(GodotClass)]
#[class(base = Node, init)]
pub struct WaylandCompositor {
    server: Option<Server>,
    textures: HashMap<u64, Gd<ImageTexture>>,
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

    /// Listens on `name` in XDG_RUNTIME_DIR, or the first free `wayland-N` when empty.
    /// Returns an error.
    #[func]
    fn listen(&mut self, name: GString) -> GString {
        let mut server = match Server::new() {
            Ok(s) => s,
            Err(e) => return gs(e.to_string()),
        };
        if let Err(e) = server.listen(&name.to_string()) {
            return gs(format!("{name}: {e}"));
        }
        self.server = Some(server);
        GString::new()
    }

    #[func]
    fn socket_name(&self) -> GString {
        self.server.as_ref().map(|s| gs(s.socket_name())).unwrap_or_default()
    }

    #[func]
    fn texture(&self, id: i64) -> Option<Gd<ImageTexture>> {
        self.textures.get(&(id as u64)).cloned()
    }

    /// Milliseconds and counts since `reset_stats`: `dispatch_ms`/`upload_ms` (mean and `_max`),
    /// `uploads`, `upload_mb`, and `frames`, buffers taken per app_id.
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
        out.set("frames", &frames);
        out
    }

    #[func]
    fn reset_stats(&mut self) {
        self.stats = Stats::default();
    }

    /// The newest mapped window with this app_id, or -1.
    #[func]
    fn find_window(&self, app_id: GString) -> i64 {
        let app_id = app_id.to_string();
        self.server
            .as_ref()
            .and_then(|s| {
                s.state
                    .windows
                    .iter()
                    .rev()
                    .find(|w| w.mapped && w.app_id == app_id)
            })
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
            let Some(f) = w.frame.take() else { continue };
            let t = Instant::now();
            s.bytes += f.rgba.len() as u64;
            *s.frames.entry(w.app_id.clone()).or_default() += 1;
            let data = PackedByteArray::from(f.rgba);
            let Some(img) =
                Image::create_from_data(f.width as i32, f.height as i32, false, Format::RGBA8, &data)
            else {
                continue;
            };
            match self.textures.get_mut(&w.id) {
                Some(tex) if (tex.get_width(), tex.get_height()) == (img.get_width(), img.get_height()) => {
                    tex.update(&img)
                }
                Some(tex) => tex.set_image(&img),
                None => {
                    if let Some(tex) = ImageTexture::create_from_image(&img) {
                        self.textures.insert(w.id, tex);
                    }
                }
            }
            let took = t.elapsed();
            s.uploads += 1;
            s.upload += took;
            s.upload_max = s.upload_max.max(took);
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
                    self.signals()
                        .window_mapped()
                        .emit(id as i64, &gs(app_id), &gs(title));
                }
                WindowEvent::Unmapped(id) => {
                    self.textures.remove(&id);
                    self.signals().window_unmapped().emit(id as i64);
                }
            }
        }
    }
}
