//! The Godot shell's extension: the link to livi-core, and the test harness's native half.

pub mod apps;
mod apps_node;
#[cfg(target_os = "linux")]
pub mod compositor;
pub mod fake_core;
#[cfg(target_os = "linux")]
mod gl_import;
#[cfg(target_os = "linux")]
mod gl_scene;
pub mod golden;
pub mod keys;
pub mod scenario;
pub mod settings;
#[cfg(target_os = "linux")]
pub mod test_client;
#[cfg(target_os = "linux")]
mod wayland_node;
pub mod yuv;

use std::collections::VecDeque;
use std::sync::{Arc, Condvar, Mutex};
use std::time::Duration;

use godot::classes::image::Format;
use godot::classes::{INode, Image, Json, Node};
use godot::prelude::*;
use livi_core_client::{Client, Event};
use livi_core_proto::input::Input;
use livi_core_proto::message::Action;
use serde_json::Value;

use crate::fake_core::FakeCore;
use crate::settings::{Controller as SettingsController, Out};

struct Shell;

#[gdextension]
unsafe impl ExtensionLibrary for Shell {}

fn gs(s: impl AsRef<str>) -> GString {
    GString::from(s.as_ref())
}

fn to_variant(v: &Value) -> Variant {
    Json::parse_string(&GString::from(&v.to_string()))
}

fn from_variant(v: &Variant) -> Result<Value, String> {
    let mut v: Value = serde_json::from_str(&Json::stringify(v).to_string()).map_err(|e| e.to_string())?;
    scenario::whole_floats_to_ints(&mut v);
    Ok(v)
}

/// Events cross from the client's reader thread; `count` lets the fake wait for its own.
#[derive(Default)]
struct Inbox {
    queue: Mutex<(VecDeque<Event>, u64)>,
    arrived: Condvar,
}

/// The shell's connection to livi-core, real or fake. Events are emitted on the main thread.
#[derive(GodotClass)]
#[class(base = Node, init)]
pub struct CoreLink {
    client: Option<Client>,
    fake: Option<FakeCore>,
    inbox: Arc<Inbox>,
    /// Events the fake has caused so far.
    fake_events: u64,
    settings: SettingsController,
    base: Base<Node>,
}

#[godot_api]
impl INode for CoreLink {
    fn process(&mut self, _delta: f64) {
        self.drain();
    }
}

#[godot_api]
impl CoreLink {
    #[signal]
    fn welcome(version: GString);
    #[signal]
    fn changed(sections: PackedStringArray);
    #[signal]
    fn gone(reason: GString);
    /// The core asks the UI to show a page, as a path (`/projection`, `/media/fm`).
    #[signal]
    fn open_page(path: GString);

    /// Connects to the running core; an empty path means its default socket.
    #[func]
    fn connect_core(&mut self, path: GString) -> GString {
        let path = match path.to_string() {
            p if p.is_empty() => livi_core_client::socket_path(),
            p => p.into(),
        };
        let stream = match livi_core_client::wait_for_socket(&path, Duration::from_secs(2)) {
            Ok(s) => s,
            Err(e) => return gs(format!("{}: {e}", path.display())),
        };
        self.start(stream)
    }

    /// One attempt at the core's default socket, without waiting: for retrying from the main
    /// loop while the core is down or restarting.
    #[func]
    fn try_connect_core(&mut self) -> GString {
        match std::os::unix::net::UnixStream::connect(livi_core_client::socket_path()) {
            Ok(stream) => self.start(stream),
            Err(e) => gs(e.to_string()),
        }
    }

    /// Starts an in-process fake core with `fixture` (a partial state) and waits for its welcome.
    #[func]
    fn start_fake(&mut self, fixture: Variant) -> GString {
        let fixture = match from_variant(&fixture) {
            Ok(v) => v,
            Err(e) => return gs(e),
        };
        let (fake, theirs) = match FakeCore::new() {
            Ok(p) => p,
            Err(e) => return gs(e.to_string()),
        };
        let err = self.start(theirs);
        if !err.is_empty() {
            return err;
        }
        self.fake = Some(fake);
        self.fake_call(|f| f.welcome(fixture))
    }

    /// Sets a value in the fake's state, at a `/`-separated path, and waits until the shell has it.
    #[func]
    fn fake_set(&mut self, path: GString, value: Variant) -> GString {
        let path: Vec<String> = path
            .to_string()
            .split('/')
            .filter(|s| !s.is_empty())
            .map(String::from)
            .collect();
        match from_variant(&value) {
            Ok(value) => self.fake_call(|f| f.set(path, value)),
            Err(e) => gs(e),
        }
    }

    /// The fake asks the shell to show a page, as the core does from the car's telemetry.
    #[func]
    fn fake_open_page(&mut self, path: GString) -> GString {
        self.fake_call(|f| f.open_page(path.to_string()))
    }

    /// Every message the shell has sent the fake, as wire JSON, oldest first.
    #[func]
    fn fake_sent(&mut self) -> Variant {
        let sent = self.fake.as_mut().map(|f| f.sent().to_vec()).unwrap_or_default();
        to_variant(&serde_json::to_value(sent).unwrap_or_default())
    }

    #[func]
    fn fake_clear(&mut self) {
        if let Some(f) = self.fake.as_mut() {
            f.clear();
        }
    }

    /// The core's state at a JSON pointer such as `/telemetry/fuelPct`; null when absent.
    #[func]
    fn get_value(&self, pointer: GString) -> Variant {
        let Some(client) = &self.client else {
            return Variant::nil();
        };
        let mirror = client.mirror();
        match mirror.json.pointer(&pointer.to_string()) {
            Some(v) => to_variant(v),
            None => Variant::nil(),
        }
    }

    /// Sends an action in wire form, `{ kind: "preconditionBattery", on: true }`. Returns an error.
    #[func]
    fn act(&mut self, action: Variant) -> GString {
        let action: Action = match from_variant(&action).and_then(|v| {
            serde_json::from_value(v).map_err(|e| e.to_string())
        }) {
            Ok(a) => a,
            Err(e) => return gs(e),
        };
        match &self.client {
            Some(c) => {
                c.act(action);
                GString::new()
            }
            None => "not connected".into(),
        }
    }

    /// Sends input in wire form, `{ kind: "pointer", screen: "main", points: [...] }`.
    #[func]
    fn input(&mut self, input: Variant) -> GString {
        let input: Input = match from_variant(&input).and_then(|v| {
            serde_json::from_value(v).map_err(|e| e.to_string())
        }) {
            Ok(i) => i,
            Err(e) => return gs(e),
        };
        match &self.client {
            Some(c) => {
                c.input(input);
                GString::new()
            }
            None => "not connected".into(),
        }
    }

    /// LIVI's settings page open now, evaluated against the core's state: `sections`, `titles`
    /// (the pages down to it), `kind` (list, select, number, text, color, slider, unsupported)
    /// and what that kind shows, and `apply` while a restart-only change waits.
    #[func]
    fn settings_view(&mut self) -> Variant {
        let state = self.state();
        to_variant(&self.settings.view(&state))
    }

    /// The touches on the settings page: each sends what stock LIVI's settings UI sends. Rows
    /// are indices into the last view's rows; `-1` for `row` means the page open now.
    #[func]
    fn settings_section(&mut self, i: i64) {
        self.settings_do(|c, _| c.open_section(i));
    }

    #[func]
    fn settings_open(&mut self, row: i64) {
        self.settings_do(|c, _| c.open(row.max(0) as usize));
    }

    #[func]
    fn settings_back(&mut self) {
        self.settings_do(|c, _| c.back());
    }

    #[func]
    fn settings_toggle(&mut self, row: i64) {
        self.settings_do(|c, s| c.toggle(row.max(0) as usize, s));
    }

    #[func]
    fn settings_press(&mut self, row: i64) {
        self.settings_do(|c, _| c.press(row.max(0) as usize));
    }

    /// A row's tool button, `tool` its index in the row's `tools`.
    #[func]
    fn settings_tool(&mut self, row: i64, tool: i64) {
        self.settings_do(|c, _| c.tool(row.max(0) as usize, tool.max(0) as usize));
    }

    #[func]
    fn settings_pick(&mut self, row: i64, option: i64) {
        self.settings_do(|c, s| c.pick(row, option.max(0) as usize, s));
    }

    #[func]
    fn settings_level(&mut self, row: i64, level: f64) {
        self.settings_do(|c, _| c.level(row, level as f32));
    }

    #[func]
    fn settings_number(&mut self, row: i64, value: f64) {
        self.settings_do(|c, s| c.number(row, value, s));
    }

    #[func]
    fn settings_dialog(&mut self, i: i64) {
        self.settings_do(|c, _| c.dialog_press(i.max(0) as usize));
    }

    #[func]
    fn settings_apply(&mut self) {
        self.settings_do(|c, s| c.apply(s));
    }

    /// The page closed: stops what its custom pages watched.
    #[func]
    fn settings_leave(&mut self) {
        let out = self.settings.follow_watches(true);
        self.send_all(out);
    }
}

impl CoreLink {
    fn state(&self) -> Value {
        self.client.as_ref().map(|c| c.mirror().json.clone()).unwrap_or(Value::Null)
    }

    fn settings_do(&mut self, f: impl FnOnce(&mut SettingsController, &Value) -> Vec<Out>) {
        let state = self.state();
        let mut out = f(&mut self.settings, &state);
        out.extend(self.settings.follow_watches(false));
        self.send_all(out);
    }

    fn send_all(&self, out: Vec<Out>) {
        let Some(c) = &self.client else { return };
        for o in out {
            match o {
                Out::Act(a) => c.act(a),
                Out::Msg(m) => c.send(&m),
            }
        }
    }

    fn start(&mut self, stream: std::os::unix::net::UnixStream) -> GString {
        // Fresh per connection: the previous client's reader still ends with a Gone event.
        self.inbox = Arc::new(Inbox::default());
        self.fake = None;
        self.fake_events = 0;
        let inbox = self.inbox.clone();
        let client = Client::start(stream, "godot-shell", move |ev, _| {
            let mut q = inbox.queue.lock().unwrap_or_else(|e| e.into_inner());
            q.0.push_back(ev);
            q.1 += 1;
            inbox.arrived.notify_all();
        });
        match client {
            Ok(c) => {
                self.client = Some(c);
                GString::new()
            }
            Err(e) => gs(e.to_string()),
        }
    }

    /// Runs one fake call that causes one client event, waits for it, and emits it now, so
    /// scenarios see the change in the same frame.
    fn fake_call(&mut self, f: impl FnOnce(&mut FakeCore) -> std::io::Result<()>) -> GString {
        let Some(fake) = self.fake.as_mut() else {
            return "no fake core".into();
        };
        if let Err(e) = f(fake) {
            return gs(e.to_string());
        }
        self.fake_events += 1;
        let want = self.fake_events;
        let q = self.inbox.queue.lock().unwrap_or_else(|e| e.into_inner());
        let (q, timeout) = self
            .inbox
            .arrived
            .wait_timeout_while(q, Duration::from_secs(5), |q| q.1 < want)
            .unwrap_or_else(|e| e.into_inner());
        drop(q);
        self.drain();
        if timeout.timed_out() {
            return "the client did not take the fake's message".into();
        }
        GString::new()
    }

    fn drain(&mut self) {
        let events: Vec<Event> = {
            let mut q = self.inbox.queue.lock().unwrap_or_else(|e| e.into_inner());
            q.0.drain(..).collect()
        };
        for ev in events {
            match ev {
                Event::Welcome { version } => {
                    self.signals().welcome().emit(&GString::from(&version));
                }
                Event::Changed(sections) => {
                    let s: PackedStringArray = sections.iter().map(GString::from).collect();
                    self.signals().changed().emit(&s);
                }
                Event::Gone(reason) => {
                    self.signals().gone().emit(&GString::from(&reason));
                }
                Event::OpenPage(path) => {
                    self.signals().open_page().emit(&GString::from(&path));
                }
                Event::Spectrum(_) => {}
            }
        }
    }
}

/// YAML for the shell's own data files (themes, rules), which GDScript cannot parse.
#[derive(GodotClass)]
#[class(base = RefCounted, init)]
pub struct Yaml {
    base: Base<RefCounted>,
}

#[godot_api]
impl Yaml {
    /// The document as Godot values; a String with the error when it does not parse.
    #[func]
    fn parse(text: GString) -> Variant {
        match scenario::yaml_to_json(&text.to_string()) {
            Ok(v) => to_variant(&v),
            Err(e) => e.to_variant(),
        }
    }
}

/// Static helpers for the scenario runner.
#[derive(GodotClass)]
#[class(base = RefCounted, init)]
pub struct ShellTest {
    base: Base<RefCounted>,
}

#[godot_api]
impl ShellTest {
    /// A scenario file's contents; a String with the error when it does not parse.
    #[func]
    fn load_yaml(text: GString) -> Variant {
        match scenario::yaml_to_json(&text.to_string()) {
            Ok(v) => to_variant(&v),
            Err(e) => e.to_variant(),
        }
    }

    /// `{ PreconditionBattery: { on: true } }` to wire form; a String with the error otherwise.
    #[func]
    fn action_from_scenario(action: Variant) -> Variant {
        match from_variant(&action).and_then(|v| scenario::action_from_scenario(&v)) {
            Ok(v) => to_variant(&v),
            Err(e) => e.to_variant(),
        }
    }

    #[func]
    fn subset(want: Variant, got: Variant) -> bool {
        match (from_variant(&want), from_variant(&got)) {
            (Ok(w), Ok(g)) => scenario::subset(&w, &g),
            _ => false,
        }
    }

    /// `{ differing: int, compared: int (pixels outside the mask), diff: Image }`, or `{ error: String }` when the sizes differ.
    /// `mask` is an array of Rect2i regions that may vary.
    #[func]
    fn compare_images(
        golden: Gd<Image>,
        actual: Gd<Image>,
        tolerance: i64,
        mask: Array<Rect2i>,
    ) -> VarDictionary {
        let mut out = VarDictionary::new();
        let (w, h) = (golden.get_width(), golden.get_height());
        if (w, h) != (actual.get_width(), actual.get_height()) {
            out.set("error", format!("golden is {w}x{h}, got {}x{}", actual.get_width(), actual.get_height()));
            return out;
        }
        let rgba = |img: &Gd<Image>| {
            let mut img = img.duplicate_resource();
            img.convert(Format::RGBA8);
            img.get_data().to_vec()
        };
        let mask: Vec<golden::Rect> = mask
            .iter_shared()
            .map(|r| golden::Rect {
                x: r.position.x.max(0) as u32,
                y: r.position.y.max(0) as u32,
                w: r.size.x.max(0) as u32,
                h: r.size.y.max(0) as u32,
            })
            .collect();
        let tol = tolerance.clamp(0, 255) as u8;
        match golden::compare(&rgba(&golden), &rgba(&actual), w as u32, tol, &mask) {
            Some(d) => {
                out.set("differing", d.differing as i64);
                out.set("compared", d.compared as i64);
                let bytes = PackedByteArray::from(d.image);
                if let Some(img) = Image::create_from_data(w, h, false, Format::RGBA8, &bytes) {
                    out.set("diff", &img);
                }
            }
            None => out.set("error", "pixel data does not match the size"),
        }
        out
    }
}
