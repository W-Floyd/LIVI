//! `WaylandCompositor` where there is no Wayland (macOS): the same API, so the project loads
//! and its pages can be laid out and tested. Hosted apps never show. On macOS the core's
//! projection video does, as the stock frontend shows it (livi-video-view): livi-output sends the
//! planes to sockets served here, and they are drawn by a native view under Godot's, in the
//! rectangle the shell gives (`place_video`) and shows transparent. Each plane on the main
//! screen is a window here, `livi-video-<tag>`, with a texture of the stream's size and no
//! pixels, so the shell lays it out and maps touches as it does a Wayland one.

use godot::classes::{INode, Node, Texture2D};
use godot::prelude::*;

use crate::panel;

#[derive(GodotClass)]
#[class(base = Node, init)]
pub struct WaylandCompositor {
    #[cfg(target_os = "macos")]
    video: video::Windows,
    base: Base<Node>,
}

#[godot_api]
impl INode for WaylandCompositor {
    fn process(&mut self, _delta: f64) {
        #[cfg(target_os = "macos")]
        for e in self.video.follow() {
            match e {
                video::Change::Mapped(id, app_id) => self.signals().window_mapped().emit(id, &GString::from(&app_id), &GString::new()),
                video::Change::Unmapped(id) => self.signals().window_unmapped().emit(id),
            }
        }
    }
}

#[godot_api]
impl WaylandCompositor {
    #[signal]
    fn window_mapped(id: i64, app_id: GString, title: GString);
    #[signal]
    fn window_unmapped(id: i64);
    #[signal]
    fn text_input_wanted(id: i64);
    #[signal]
    fn text_input_released(id: i64);

    /// No error: a stub is what this build is for.
    #[func]
    fn listen(&mut self, _name: GString) -> GString {
        godot_print!("compositor: stub, no Wayland on this system: hosted apps will not show");
        GString::new()
    }

    /// Serves livi-output's video planes and draws them under this window, which turns
    /// transparent where the shell leaves it so. Returns an error; empty off macOS.
    #[func]
    fn host_video(&mut self) -> GString {
        #[cfg(target_os = "macos")]
        if let Err(e) = video::host(self.base().get_tree()) {
            return GString::from(&e);
        }
        GString::new()
    }

    /// Where window `id`'s picture shows: `clip`, a rectangle of this window in its pixels, and
    /// `content` where the whole visible area would be (past `clip` when only part shows). An
    /// empty `clip` hides it.
    #[func]
    fn place_video(&mut self, _id: i64, _clip: Rect2, _content: Rect2) {
        #[cfg(target_os = "macos")]
        video::place(_clip, _content);
    }

    #[func]
    fn stub(&self) -> bool {
        true
    }

    #[func]
    fn socket_name(&self) -> GString {
        GString::new()
    }

    #[func]
    fn dmabuf_status(&self) -> GString {
        "stub compositor".into()
    }

    #[func]
    fn texture(&self, _id: i64) -> Option<Gd<Texture2D>> {
        #[cfg(target_os = "macos")]
        return self.video.texture(_id);
        #[cfg(not(target_os = "macos"))]
        None
    }

    #[func]
    fn stats(&self) -> VarDictionary {
        let mut out = VarDictionary::new();
        for k in ["dispatch_ms", "dispatch_ms_max", "upload_ms", "upload_ms_max", "upload_mb", "import_ms", "import_ms_max"] {
            out.set(k, 0.0);
        }
        for k in ["uploads", "imports"] {
            out.set(k, 0i64);
        }
        out.set("frames", &VarDictionary::new());
        out
    }

    #[func]
    fn reset_stats(&mut self) {}
    #[func]
    fn pointer_motion(&mut self, _id: i64, _x: f64, _y: f64) {}
    #[func]
    fn pointer_button(&mut self, _button: i64, _pressed: bool) {}
    #[func]
    fn touch_down(&mut self, _id: i64, _slot: i64, _x: f64, _y: f64) {}
    #[func]
    fn touch_motion(&mut self, _id: i64, _slot: i64, _x: f64, _y: f64) {}
    #[func]
    fn touch_up(&mut self, _slot: i64) {}
    #[func]
    fn keyboard_focus(&mut self, _id: i64) {}
    #[func]
    fn key(&mut self, _physical_keycode: i64, _pressed: bool) -> bool {
        false
    }
    #[func]
    fn text_field(&self, _id: i64) -> VarDictionary {
        VarDictionary::new()
    }
    #[func]
    fn has_text_input(&self, _id: i64) -> bool {
        false
    }
    #[func]
    fn type_text(&mut self, _text: GString) -> bool {
        false
    }
    #[func]
    fn type_keys(&mut self, _text: GString) -> bool {
        false
    }
    #[func]
    fn text_delete(&mut self, _before: i64, _after: i64) -> bool {
        false
    }
    #[func]
    fn text_preedit(&mut self, _text: GString, _caret_begin: i64, _caret_end: i64) -> bool {
        false
    }
    #[func]
    fn close(&mut self, _id: i64) {}
    #[func]
    fn window_count(&self) -> i64 {
        #[cfg(target_os = "macos")]
        return self.video.count();
        #[cfg(not(target_os = "macos"))]
        0
    }
    #[func]
    fn set_native(&mut self, _id: i64, _on: bool) {}
    #[func]
    fn set_process_scale(&mut self, _pid: i64, _scale: f64) {}
    #[func]
    fn set_app_area(&mut self, _width: i64, _height: i64) {}
    #[func]
    fn set_window_area(&mut self, _id: i64, _width: i64, _height: i64) {}
    #[func]
    fn set_window_paused(&mut self, _id: i64, _on: bool) {}
    #[func]
    fn set_process_fullscreen(&mut self, _pid: i64, _on: bool) {}
    #[func]
    fn set_window_fullscreen(&mut self, _id: i64, _on: bool) {}
    #[func]
    fn window_fullscreen(&self, _id: i64) -> bool {
        false
    }
    #[func]
    fn dismiss_popups(&mut self, _id: i64) {}
    #[func]
    fn set_window_scale(&mut self, _id: i64, _scale: f64) {}
    #[func]
    fn window_scale(&self, _id: i64) -> f64 {
        0.0
    }
    #[func]
    fn default_app_scale(view_mm: f64) -> f64 {
        panel::default_scale(view_mm)
    }
    #[func]
    fn window_pid(&self, _id: i64) -> i64 {
        -1
    }
    #[func]
    fn find_window(&self, _app_id: GString) -> i64 {
        #[cfg(target_os = "macos")]
        return self.video.find(&_app_id.to_string());
        #[cfg(not(target_os = "macos"))]
        -1
    }
}

#[cfg(target_os = "macos")]
mod video {
    use std::sync::OnceLock;

    use godot::classes::display_server::HandleType;
    use godot::classes::image::Format;
    use godot::classes::window::Flags;
    use godot::classes::{DisplayServer, Image, ImageTexture, SceneTree, Texture2D};
    use godot::prelude::*;
    use livi_video_view::Area;

    const SCREEN: &str = "main";

    pub enum Change {
        Mapped(i64, String),
        Unmapped(i64),
    }

    struct Window {
        id: u32,
        app_id: String,
        size: Vector2i,
        texture: Gd<ImageTexture>,
    }

    #[derive(Default)]
    pub struct Windows(Vec<Window>);

    impl Windows {
        /// A plane is a window once the core has placed it: its stream size comes with that.
        pub fn follow(&mut self) -> Vec<Change> {
            let planes: Vec<_> = livi_video_view::drawn()
                .into_iter()
                .filter(|p| p.screen == SCREEN && p.region.tier_w > 0.0 && p.region.tier_h > 0.0)
                .collect();
            let mut out = Vec::new();
            self.0.retain(|w| {
                let kept = planes.iter().any(|p| p.id == w.id);
                if !kept {
                    out.push(Change::Unmapped(w.id.into()));
                }
                kept
            });
            for p in planes {
                let size = Vector2i::new(p.region.tier_w as i32, p.region.tier_h as i32);
                if let Some(w) = self.0.iter_mut().find(|w| w.id == p.id) {
                    if w.size != size {
                        w.size = size;
                        w.texture.set_size_override(size);
                        w.texture.emit_changed();
                    }
                    continue;
                }
                let Some(img) = Image::create_empty(1, 1, false, Format::RGBA8) else { continue };
                let Some(mut texture) = ImageTexture::create_from_image(&img) else { continue };
                texture.set_size_override(size);
                let app_id = format!("livi-video-{}", p.tag);
                out.push(Change::Mapped(p.id.into(), app_id.clone()));
                self.0.push(Window { id: p.id, app_id, size, texture });
            }
            out
        }

        pub fn texture(&self, id: i64) -> Option<Gd<Texture2D>> {
            self.0.iter().find(|w| i64::from(w.id) == id).map(|w| w.texture.clone().upcast())
        }

        pub fn count(&self) -> i64 {
            self.0.len() as i64
        }

        pub fn find(&self, app_id: &str) -> i64 {
            self.0.iter().rev().find(|w| w.app_id == app_id).map_or(-1, |w| w.id.into())
        }
    }

    pub fn host(tree: Gd<SceneTree>) -> Result<(), String> {
        static SERVED: OnceLock<Result<(), String>> = OnceLock::new();
        SERVED
            .get_or_init(|| {
                // Beside the core's socket, as the stock frontend has them.
                let core = livi_core_client::socket_path();
                let dir = core.parent().ok_or("no runtime dir")?;
                std::fs::create_dir_all(dir).map_err(|e| format!("{}: {e}", dir.display()))?;
                let planes = dir.join("ui-planes.sock");
                livi_video_view::serve(&dir.join("compositor.ctrl"), &planes).map_err(|e| format!("video: {e}"))?;
                godot_print!("compositor: video planes at {}", planes.display());
                Ok(())
            })
            .clone()?;
        let mut root = tree.get_root();
        root.set_transparent_background(true);
        root.set_flag(Flags::TRANSPARENT, true);
        let view = DisplayServer::singleton().window_get_native_handle(HandleType::WINDOW_VIEW);
        if view == 0 {
            return Err("no native view to draw video under".into());
        }
        livi_video_view::set_window(SCREEN, view as usize);
        Ok(())
    }

    pub fn place(clip: Rect2, content: Rect2) {
        let r = |r: Rect2| [r.position.x as f64, r.position.y as f64, r.size.x as f64, r.size.y as f64];
        livi_video_view::set_area(SCREEN, Some(Area { clip: r(clip), content: r(content) }));
    }
}
