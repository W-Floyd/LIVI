//! The Wayland server the shell embeds, with no Godot types: Godot's main thread calls
//! `dispatch` once a frame, takes each window's newest frame, and calls `frame_done` after.

use std::collections::HashMap;
use std::io;
use std::os::unix::net::UnixStream;
use std::sync::{Arc, Mutex};
use std::time::Instant;

use smithay::backend::allocator::Buffer;
use smithay::backend::allocator::dmabuf::Dmabuf;

use crate::gl_import::is_planar_yuv;
use smithay::backend::allocator::{Format as DrmFormat, Fourcc, Modifier};
use smithay::delegate_compositor;
use smithay::delegate_dmabuf;
use smithay::delegate_output;
use smithay::delegate_viewporter;
use smithay::delegate_data_device;
use smithay::delegate_fractional_scale;
use smithay::wayland::fractional_scale::{FractionalScaleHandler, FractionalScaleManagerState, with_fractional_scale};
use smithay::wayland::selection::SelectionHandler;
use smithay::wayland::selection::data_device::{ClientDndGrabHandler, DataDeviceHandler, DataDeviceState, ServerDndGrabHandler};
use smithay::output::{Mode, Output, PhysicalProperties, Subpixel};
use smithay::wayland::output::{OutputHandler, OutputManagerState};
use smithay::wayland::viewporter::{ViewportCachedState, ViewporterState};
use smithay::delegate_seat;
use smithay::delegate_shm;
use smithay::delegate_xdg_shell;
use smithay::backend::input::{ButtonState, KeyState, TouchSlot};
use smithay::input::keyboard::{FilterResult, KeyboardHandle, Keycode, XkbConfig};
use smithay::input::pointer::{ButtonEvent, MotionEvent as PointerMotion, PointerHandle};
use smithay::input::touch::{DownEvent as TouchDown, MotionEvent as TouchMotion, TouchHandle, UpEvent as TouchUp};
use smithay::input::{Seat, SeatHandler, SeatState};
use smithay::utils::{Logical, Point, Rectangle, SERIAL_COUNTER, Transform};
use smithay::reexports::wayland_server::Resource;
use smithay::reexports::wayland_server::backend::{ClientData, ClientId, DisconnectReason, ObjectId};
use smithay::reexports::wayland_server::protocol::wl_buffer::WlBuffer;
use smithay::reexports::wayland_server::protocol::wl_output::WlOutput;
use smithay::reexports::wayland_server::protocol::wl_seat::WlSeat;
use smithay::reexports::wayland_server::protocol::wl_shm::Format;
use smithay::reexports::wayland_server::protocol::wl_surface::WlSurface;
use smithay::reexports::wayland_server::{Client, Display, DisplayHandle, ListeningSocket};
use smithay::utils::Serial;
use smithay::wayland::buffer::BufferHandler;
use smithay::wayland::compositor::{
    BufferAssignment, CompositorClientState, CompositorHandler, CompositorState,
    SubsurfaceCachedState, SurfaceAttributes, TraversalAction, get_parent, send_surface_state,
    with_states, with_surface_tree_downward,
};
use smithay::wayland::shell::xdg::{
    PopupSurface, PositionerState, SurfaceCachedState, ToplevelSurface, XdgPopupSurfaceData, XdgShellHandler,
    XdgShellState, XdgToplevelSurfaceData,
};
use smithay::wayland::dmabuf::{
    DmabufFeedbackBuilder, DmabufGlobal, DmabufHandler, DmabufState, ImportNotifier, get_dmabuf,
};
use smithay::wayland::shm::{ShmHandler, ShmState, with_buffer_contents};
use smithay::reexports::wayland_protocols::wp::text_input::zv3::server::zwp_text_input_manager_v3::ZwpTextInputManagerV3;

use crate::text_input::{Field, TextInputs};

/// A client's newest picture, as straight RGBA8 rows with no padding.
#[derive(Debug, Clone, PartialEq)]
pub struct Frame {
    pub width: u32,
    pub height: u32,
    pub rgba: Vec<u8>,
}

/// What a commit brought: shm is copied out at once; a dmabuf is handed over as it is, with a
/// key that stays the same while the client reuses the buffer, so imports can be cached.
#[derive(Debug, Clone)]
pub enum Content {
    Pixels(Frame),
    Dmabuf { key: u64, dmabuf: Dmabuf },
    /// A window with dmabuf layers (video subsurfaces, planar YUV) that the GPU draws over the
    /// shm canvas, if any.
    Scene(Scene),
}

/// A dmabuf placed in a window, `w` x `h` window pixels at (`x`, `y`) showing `src` (0..1) of the buffer.
#[derive(Debug, Clone)]
pub struct SceneLayer {
    pub key: u64,
    pub dmabuf: Dmabuf,
    pub x: i32,
    pub y: i32,
    pub w: i32,
    pub h: i32,
    pub src: [f32; 4],
}

#[derive(Debug, Clone)]
pub struct Scene {
    pub width: u32,
    pub height: u32,
    /// The shm layers laid out as one picture, `width` x `height`, with a generation that changes
    /// whenever the picture does, so it is uploaded once and not per video frame.
    pub canvas: Option<(u64, Arc<Frame>)>,
    /// Bottom to top.
    pub layers: Vec<SceneLayer>,
}

/// A dmabuf a surface shows, held until a frame has been drawn without it.
struct DmaLayer {
    surface: WlSurface,
    buffer: WlBuffer,
    key: u64,
    dmabuf: Dmabuf,
}

pub struct Window {
    pub id: u64,
    toplevel: ToplevelSurface,
    pub app_id: String,
    pub title: String,
    /// Set by each commit with a new buffer; the embedder takes it.
    pub frame: Option<Content>,
    pub mapped: bool,
    /// The dmabuf on screen, held until a frame has been drawn without it.
    shown: Option<WlBuffer>,
    /// The toplevel surface's own latest shm picture, under its subsurfaces.
    root_frame: Option<Frame>,
    /// Or its own RGB dmabuf, the bottom layer once anything shows over it.
    root_dma: Option<(u64, Dmabuf)>,
    /// `frame` is laid out from layers, not the toplevel's own picture.
    composited: bool,
    /// The canvas last handed out in a `Scene`, and the window size it was laid out for.
    canvas: Option<(u64, Arc<Frame>)>,
    canvas_size: (u32, u32),
    /// The window is its largest dmabuf layer at the buffer's own size, wherever the client put
    /// and scaled it: projection video, which waylandsink fits to the 1920x720 configure and the
    /// shell crops 1:1 as the core's touch mapping assumes.
    native: bool,
    /// The scale asked of the client (`State::set_window_scale`); its windows are configured at
    /// the panel's size divided by it.
    pub scale: f64,
    /// Buffer pixels per surface unit, as the toplevel's last real buffer came: the window's
    /// frames are in buffer pixels and input is in surface units, whatever the client honoured.
    pub buffer_scale: f64,
}

#[derive(Debug, Clone, PartialEq)]
pub enum WindowEvent {
    /// The first buffer arrived; app_id and title are known by then.
    Mapped(u64),
    Unmapped(u64),
    /// The window's client wants text typed (true), or no longer does.
    TextInput(u64, bool),
}

pub struct State {
    compositor: CompositorState,
    xdg_shell: XdgShellState,
    shm: ShmState,
    seat_state: SeatState<State>,
    _seat: Seat<State>,
    pointer: PointerHandle<State>,
    keyboard: KeyboardHandle<State>,
    touch: TouchHandle<State>,
    dmabuf: DmabufState,
    dmabuf_global: Option<DmabufGlobal>,
    // Kept alive: the globals vanish with them. Clients (Waydroid's) ask for an output to size themselves.
    output: Output,
    _output_manager: OutputManagerState,
    _viewporter: ViewporterState,
    // GTK 4 will not use a compositor without wl_data_device_manager.
    data_device: DataDeviceState,
    _fractional: FractionalScaleManagerState,
    dh: DisplayHandle,
    /// Scales by the PID the shell started a client as; a client matches by its own PID or its
    /// process group, so what an app forks is scaled with it.
    pub launch_scales: HashMap<i32, f64>,
    /// Where hosted apps show, in panel pixels (`set_app_area`): the panel less what the shell
    /// keeps beside it. Projection video keeps the whole panel.
    pub app_area: (i32, i32),
    pub windows: Vec<Window>,
    pub events: Vec<WindowEvent>,
    next_id: u64,
    buffer_keys: HashMap<ObjectId, u64>,
    /// Each subsurface's latest shm picture. Android's compositor draws a layer per subsurface and
    /// leaves the toplevel itself a placeholder, so a window is these laid over each other.
    layers: HashMap<ObjectId, Frame>,
    /// The same for dmabuf pictures: subsurfaces, and a toplevel whose format only the GPU converts.
    dma_layers: HashMap<ObjectId, DmaLayer>,
    next_gen: u64,
    next_key: u64,
    /// Keys of dmabufs the client destroyed; the embedder frees what it imported for them.
    pub gone_buffers: Vec<u64>,
    /// Released at the next frame_done, then the one after: one drawn frame later.
    release_next: Vec<WlBuffer>,
    release_now: Vec<WlBuffer>,
    pub text_input: TextInputs,
    /// Popups that asked for a grab: a press outside every popup dismisses them all, and is not
    /// passed on; nor is its pointer release.
    grabbed: Vec<WlSurface>,
    swallow_release: bool,
}

pub struct Server {
    display: Display<State>,
    socket: Option<ListeningSocket>,
    socket_name: String,
    pub state: State,
    started: Instant,
}

#[derive(Default)]
struct ClientState {
    compositor: CompositorClientState,
    /// Looked up on first need, from `State::launch_scales`.
    scale: Mutex<Option<f64>>,
}

/// The panel, the one output: 12.3 inches at 8:3.
pub const PANEL_PX: (i32, i32) = (1920, 720);
pub const PANEL_MM: (i32, i32) = (293, 110);
/// The scales offered to apps, as the 120ths wp_fractional_scale counts in divide evenly.
pub const SCALE_STEP: f64 = 0.25;
pub const SCALE_RANGE: (f64, f64) = (1.0, 2.0);

/// The app scale at which a logical pixel looks as big as CSS's reference pixel (1/96 inch at
/// 28 inches: 0.0213 degrees) from `view_mm` away, to the nearest step:
/// `px_per_mm * 25.4 / 96 * view_mm / 711.2`. The panel from 750 mm: 1.83, so 1.75.
pub fn default_scale(view_mm: f64) -> f64 {
    let px_per_mm = PANEL_PX.0 as f64 / PANEL_MM.0 as f64;
    let s = px_per_mm * 25.4 / 96.0 * view_mm / 711.2;
    ((s / SCALE_STEP).round() * SCALE_STEP).clamp(SCALE_RANGE.0, SCALE_RANGE.1)
}

/// What clients without wp_fractional_scale are told, through wl_surface and wl_output.
fn integer_scale(s: f64) -> i32 {
    (s.round() as i32).max(1)
}

/// The window size, in surface units, that fills `area` (panel pixels) at scale `s`.
fn logical_size(area: (i32, i32), s: f64) -> (i32, i32) {
    ((area.0 as f64 / s).round() as i32, (area.1 as f64 / s).round() as i32)
}

/// livi-gst-host's projection video: waylandsink fits it to the configure, and the core's crop and
/// touch mapping assume the whole panel.
fn is_video(app_id: &str) -> bool {
    app_id.starts_with("livi-video")
}

fn toplevel_app_id(surface: &WlSurface) -> String {
    with_states(surface, |states| {
        states
            .data_map
            .get::<XdgToplevelSurfaceData>()
            .and_then(|d| d.lock().ok())
            .and_then(|d| d.app_id.clone())
            .unwrap_or_default()
    })
}

impl ClientData for ClientState {
    fn disconnected(&self, _: ClientId, _: DisconnectReason) {}
}

impl Server {
    /// A server with no socket yet: `listen` opens one, `insert_client` takes a client directly.
    pub fn new() -> io::Result<Server> {
        let display: Display<State> = Display::new().map_err(io::Error::other)?;
        let dh = display.handle();
        let mut seat_state = SeatState::new();
        let mut seat = seat_state.new_wl_seat(&dh, "seat0");
        let pointer = seat.add_pointer();
        let touch = seat.add_touch();
        // The keymap is xkb's default (us); delay and rate are milliseconds and keys per second.
        let keyboard = seat.add_keyboard(XkbConfig::default(), 400, 25).map_err(io::Error::other)?;
        let output = Output::new(
            "livi-0".into(),
            PhysicalProperties { size: PANEL_MM.into(), subpixel: Subpixel::Unknown, make: "LIVI".into(), model: "panel".into() },
        );
        let mode = Mode { size: PANEL_PX.into(), refresh: 60_000 };
        output.create_global::<State>(&dh);
        output.change_current_state(Some(mode), None, None, Some((0, 0).into()));
        output.set_preferred(mode);
        let state = State {
            output,
            _output_manager: OutputManagerState::new_with_xdg_output::<State>(&dh),
            _viewporter: ViewporterState::new::<State>(&dh),
            data_device: DataDeviceState::new::<State>(&dh),
            _fractional: FractionalScaleManagerState::new::<State>(&dh),
            dh: dh.clone(),
            launch_scales: HashMap::new(),
            app_area: PANEL_PX,
            pointer,
            keyboard,
            touch,
            // v6, for preferred_buffer_scale.
            compositor: CompositorState::new_v6::<State>(&dh),
            xdg_shell: XdgShellState::new::<State>(&dh),
            shm: ShmState::new::<State>(&dh, vec![Format::Abgr8888, Format::Xbgr8888]),
            seat_state,
            _seat: seat,
            dmabuf: DmabufState::new(),
            dmabuf_global: None,
            windows: Vec::new(),
            events: Vec::new(),
            next_id: 1,
            buffer_keys: HashMap::new(),
            layers: HashMap::new(),
            dma_layers: HashMap::new(),
            next_gen: 1,
            next_key: 1,
            gone_buffers: Vec::new(),
            release_next: Vec::new(),
            release_now: Vec::new(),
            text_input: TextInputs::default(),
            grabbed: Vec::new(),
            swallow_release: false,
        };
        dh.create_global::<State, ZwpTextInputManagerV3, _>(1, ());
        Ok(Server {
            display,
            socket: None,
            socket_name: String::new(),
            state,
            started: Instant::now(),
        })
    }

    /// Listens on `name` in `XDG_RUNTIME_DIR`, or the first free `wayland-N` when empty.
    pub fn listen(&mut self, name: &str) -> io::Result<&str> {
        let socket = if name.is_empty() {
            ListeningSocket::bind_auto("wayland", 1..33)
        } else {
            ListeningSocket::bind(name)
        }
        .map_err(io::Error::other)?;
        self.socket_name = socket
            .socket_name()
            .map(|n| n.to_string_lossy().into_owned())
            .unwrap_or_default();
        self.socket = Some(socket);
        Ok(&self.socket_name)
    }

    pub fn socket_name(&self) -> &str {
        &self.socket_name
    }

    /// Offers linux-dmabuf with these (fourcc, modifier) pairs. With a render node it also
    /// sends v4 feedback, which Mesa's EGL clients need to pick the device.
    pub fn enable_dmabuf(&mut self, formats: &[(u32, u64)], main_device: Option<libc::dev_t>) -> io::Result<()> {
        let formats: Vec<DrmFormat> = formats
            .iter()
            .filter_map(|&(code, modifier)| {
                Some(DrmFormat {
                    code: Fourcc::try_from(code).ok()?,
                    modifier: Modifier::from(modifier),
                })
            })
            .collect();
        if formats.is_empty() {
            return Err(io::Error::other("no dmabuf formats to offer"));
        }
        let dh = self.display.handle();
        let global = match main_device {
            Some(dev) => {
                let feedback = DmabufFeedbackBuilder::new(dev, formats).build().map_err(io::Error::other)?;
                self.state.dmabuf.create_global_with_default_feedback::<State>(&dh, &feedback)
            }
            None => self.state.dmabuf.create_global::<State>(&dh, formats),
        };
        self.state.dmabuf_global = Some(global);
        Ok(())
    }

    /// Takes in new clients and handles every request that has arrived, without blocking.
    pub fn dispatch(&mut self) -> io::Result<()> {
        while let Some(stream) = self.socket.as_ref().map(|s| s.accept()).transpose()?.flatten() {
            self.insert_client(stream)?;
        }
        self.display.dispatch_clients(&mut self.state)?;
        self.state.text_input_events();
        self.display.flush_clients()?;
        Ok(())
    }

    pub fn insert_client(&mut self, stream: UnixStream) -> io::Result<Client> {
        self.display
            .handle()
            .insert_client(stream, Arc::new(ClientState::default()))
    }

    /// Tells every window its frame was shown, so it may draw the next one, and hands back the
    /// dmabufs a frame has since been drawn without.
    pub fn frame_done(&mut self) {
        self.state.dma_layers.retain(|_, d| d.surface.is_alive());
        for b in self.state.release_now.drain(..) {
            b.release();
        }
        self.state.release_now = std::mem::take(&mut self.state.release_next);
        let ms = self.started.elapsed().as_millis() as u32;
        let roots = self.state.windows.iter().map(|w| w.toplevel.wl_surface().clone());
        let popups = self.state.xdg_shell.popup_surfaces().iter().map(|p| p.wl_surface().clone());
        for root in roots.chain(popups).collect::<Vec<_>>() {
            with_surface_tree_downward(
                &root,
                (),
                |_, _, _| TraversalAction::DoChildren(()),
                |_, states, _| {
                    let mut attrs = states.cached_state.get::<SurfaceAttributes>();
                    for cb in attrs.current().frame_callbacks.drain(..) {
                        cb.done(ms);
                    }
                },
                |_, _, _| true,
            );
        }
        let _ = self.display.flush_clients();
    }

    pub fn display_handle(&self) -> DisplayHandle {
        self.display.handle()
    }

    /// Asks the window to close, as its close button would.
    pub fn close(&mut self, window: u64) {
        if let Some(w) = self.state.windows.iter().find(|w| w.id == window) {
            w.toplevel.send_close();
        }
    }

    /// The PID of the window's client, from the socket's credentials.
    pub fn window_pid(&self, window: u64) -> Option<i32> {
        let w = self.state.windows.iter().find(|w| w.id == window)?;
        let client = w.toplevel.wl_surface().client()?;
        client.get_credentials(&self.display.handle()).ok().map(|c| c.pid)
    }

    fn time(&self) -> u32 {
        self.started.elapsed().as_millis() as u32
    }

    /// The surface under (x, y) in the window's frame, the topmost popup or else the toplevel,
    /// with its origin in toplevel units, and (x, y) in toplevel units.
    fn focus(&self, window: u64, x: f64, y: f64) -> Option<((WlSurface, Point<f64, Logical>), Point<f64, Logical>)> {
        let w = self.state.windows.iter().find(|w| w.id == window && w.mapped)?;
        let k = w.buffer_scale;
        let at: Point<f64, Logical> = (x / k, y / k).into();
        let surface = self.state.popup_at(w.toplevel.wl_surface(), at);
        let origin = surface.as_ref().map_or((0, 0).into(), popup_location).to_f64();
        Some(((surface.unwrap_or_else(|| w.toplevel.wl_surface().clone()), origin), at))
    }

    /// A press while a popup holds a grab: outside every popup it dismisses them, and is eaten.
    fn grab_eats(&mut self, on: Option<&WlSurface>) -> bool {
        if self.state.grabbed.is_empty() || on.is_some_and(|s| popup_data(s).is_some()) {
            return false;
        }
        self.state.dismiss_popups(None);
        true
    }

    /// Moves the pointer to (x, y) in the window's frame, or out of every window with `None`.
    /// Positions below are frame pixels, as the window's texture has them.
    pub fn pointer_motion(&mut self, window: Option<u64>, x: f64, y: f64) {
        let (focus, location) = match window.and_then(|w| self.focus(w, x, y)) {
            Some((f, at)) => (Some(f), at),
            None => (None, (x, y).into()),
        };
        let event = PointerMotion { location, serial: SERIAL_COUNTER.next_serial(), time: self.time() };
        let pointer = self.state.pointer.clone();
        pointer.motion(&mut self.state, focus, &event);
        pointer.frame(&mut self.state);
    }

    /// `button` is an evdev code: BTN_LEFT is 0x110.
    pub fn pointer_button(&mut self, button: u32, pressed: bool) {
        if pressed {
            let on = self.state.pointer.current_focus();
            if self.grab_eats(on.as_ref()) {
                self.state.swallow_release = true;
                return;
            }
        } else if std::mem::take(&mut self.state.swallow_release) {
            return;
        }
        let state = if pressed { ButtonState::Pressed } else { ButtonState::Released };
        self.state.text_input.rearm |= pressed;
        let event = ButtonEvent { button, state, serial: SERIAL_COUNTER.next_serial(), time: self.time() };
        let pointer = self.state.pointer.clone();
        pointer.button(&mut self.state, &event);
        pointer.frame(&mut self.state);
    }

    pub fn touch_down(&mut self, window: u64, slot: u32, x: f64, y: f64) {
        let Some((focus, location)) = self.focus(window, x, y) else { return };
        // Eaten, the slot has no focus: its motion and up go nowhere.
        if self.grab_eats(Some(&focus.0)) {
            return;
        }
        let event = TouchDown {
            slot: TouchSlot::from(Some(slot)),
            location,
            serial: SERIAL_COUNTER.next_serial(),
            time: self.time(),
        };
        self.state.text_input.rearm = true;
        let touch = self.state.touch.clone();
        touch.down(&mut self.state, Some(focus), &event);
        touch.frame(&mut self.state);
    }

    pub fn touch_motion(&mut self, window: u64, slot: u32, x: f64, y: f64) {
        let (focus, location) = match self.focus(window, x, y) {
            Some((f, at)) => (Some(f), at),
            None => (None, (x, y).into()),
        };
        let event = TouchMotion { slot: TouchSlot::from(Some(slot)), location, time: self.time() };
        let touch = self.state.touch.clone();
        touch.motion(&mut self.state, focus, &event);
        touch.frame(&mut self.state);
    }

    pub fn touch_up(&mut self, slot: u32) {
        let event = TouchUp { slot: TouchSlot::from(Some(slot)), serial: SERIAL_COUNTER.next_serial(), time: self.time() };
        let touch = self.state.touch.clone();
        touch.up(&mut self.state, &event);
        touch.frame(&mut self.state);
    }

    /// Gives the window keyboard focus, or takes it from every window with `None`.
    pub fn keyboard_focus(&mut self, window: Option<u64>) {
        let focus = window.and_then(|w| self.focus(w, 0.0, 0.0)).map(|((s, _), _)| s);
        let keyboard = self.state.keyboard.clone();
        keyboard.set_focus(&mut self.state, focus.clone(), SERIAL_COUNTER.next_serial());
        self.state.text_input.set_focus(focus);
        self.state.text_input_events();
    }

    /// `code` is an evdev key code (KEY_A is 30), sent to the focused window.
    pub fn key(&mut self, code: u32, pressed: bool) {
        let state = if pressed { KeyState::Pressed } else { KeyState::Released };
        let (serial, time) = (SERIAL_COUNTER.next_serial(), self.time());
        let keyboard = self.state.keyboard.clone();
        // xkb numbers keys from 8.
        keyboard.input::<(), _>(&mut self.state, Keycode::new(code + 8), state, serial, time, |_, _, _| {
            FilterResult::Forward
        });
    }

    /// The field the window wants text for, while it does.
    pub fn text_field(&self, window: u64) -> Option<Field> {
        let w = self.state.windows.iter().find(|w| w.id == window)?;
        self.state.text_input.field(w.toplevel.wl_surface()).cloned()
    }

    /// Whether the window's client has bound zwp_text_input_v3: if not, only keys reach it.
    pub fn has_text_input(&self, window: u64) -> bool {
        let w = self.state.windows.iter().find(|w| w.id == window);
        w.and_then(|w| w.toplevel.wl_surface().client()).is_some_and(|c| self.state.text_input.bound(&c))
    }

    /// Types `text` into the focused window: through its enabled text input, else as key presses
    /// on a US layout. False when neither could take all of it (nothing is sent then).
    pub fn type_text(&mut self, text: &str) -> bool {
        if self.state.text_input.commit_string(text) {
            return true;
        }
        let Some(keys) = text.chars().map(crate::keys::us_key).collect::<Option<Vec<_>>>() else {
            return false;
        };
        const SHIFT: u32 = 42;
        for (code, shift) in keys {
            if shift {
                self.key(SHIFT, true);
            }
            self.key(code, true);
            self.key(code, false);
            if shift {
                self.key(SHIFT, false);
            }
        }
        true
    }
}


/// shm's ARGB and XRGB are little-endian words, so B, G, R, A in memory.
fn to_rgba(src: &[u8], width: u32, height: u32, stride: usize, format: Format) -> Option<Vec<u8>> {
    // (alpha opaque, bytes are R G B A in memory rather than B G R A)
    let (opaque, rgb_order) = match format {
        Format::Argb8888 => (false, false),
        Format::Xrgb8888 => (true, false),
        Format::Abgr8888 => (false, true),
        Format::Xbgr8888 => (true, true),
        other => {
            eprintln!("compositor: shm format {other:?} not handled");
            return None;
        }
    };
    let row = width as usize * 4;
    if height == 0 || stride < row || src.len() < stride * (height as usize - 1) + row {
        return None;
    }
    let mut out = Vec::with_capacity(row * height as usize);
    for y in 0..height as usize {
        for px in src[y * stride..y * stride + row].chunks_exact(4) {
            let (r, b) = if rgb_order { (px[0], px[2]) } else { (px[2], px[0]) };
            out.extend_from_slice(&[r, px[1], b, if opaque { 255 } else { px[3] }]);
        }
    }
    Some(out)
}

fn read_shm(buffer: &WlBuffer) -> Option<Frame> {
    with_buffer_contents(buffer, |ptr, len, data| {
        // SAFETY: smithay maps the pool for the call's duration and checks `len` against it.
        let pool = unsafe { std::slice::from_raw_parts(ptr, len) };
        let src = pool.get(data.offset.max(0) as usize..)?;
        let (w, h) = (data.width.max(0) as u32, data.height.max(0) as u32);
        let rgba = to_rgba(src, w, h, data.stride.max(0) as usize, data.format)?;
        Some(Frame {
            width: w,
            height: h,
            rgba,
        })
    })
    .ok()
    .flatten()
}

impl CompositorHandler for State {
    fn compositor_state(&mut self) -> &mut CompositorState {
        &mut self.compositor
    }

    fn client_compositor_state<'a>(&self, client: &'a Client) -> &'a CompositorClientState {
        &client
            .get_data::<ClientState>()
            .expect("every client is inserted with ClientState")
            .compositor
    }

    /// Before the client can ask: wp_fractional_scale sends what is set here when it is bound.
    fn new_surface(&mut self, surface: &WlSurface) {
        let Some(client) = surface.client() else { return };
        let s = self.client_scale(&client);
        with_states(surface, |states| {
            with_fractional_scale(states, |f| f.set_preferred_scale(s));
            send_surface_state(surface, states, integer_scale(s), Transform::Normal);
        });
    }

    fn commit(&mut self, surface: &WlSurface) {
        let mut root = surface.clone();
        while let Some(parent) = get_parent(&root) {
            root = parent;
        }
        // A popup's surfaces are layers of its toplevel's window.
        let root = toplevel_of(&root);
        if &root != surface {
            self.commit_layer(&root, surface);
            return;
        }
        let Some(i) = self.windows.iter().position(|w| w.toplevel.wl_surface() == surface) else {
            return;
        };
        if !self.windows[i].toplevel.is_initial_configure_sent() {
            // The app_id is set by now, before the first buffer: video or app, sized to match.
            let size = self.window_size(&self.windows[i]);
            self.windows[i].toplevel.with_pending_state(|st| st.size = Some(size.into()));
            self.windows[i].toplevel.send_configure();
            return;
        }
        let assignment = with_states(surface, |states| {
            states
                .cached_state
                .get::<SurfaceAttributes>()
                .current()
                .buffer
                .take()
        });
        match assignment {
            Some(BufferAssignment::NewBuffer(buffer)) => {
                let buf_w = match get_dmabuf(&buffer) {
                    Ok(d) => d.size().w,
                    Err(_) => with_buffer_contents(&buffer, |_, _, d| d.width).unwrap_or(0),
                };
                // Not a placeholder's single pixel, which a viewport stretches over the window.
                if buf_w > 1 {
                    self.windows[i].buffer_scale = buffer_per_unit(surface, buf_w);
                }
                let mut shm = false;
                let content = if let Ok(dmabuf) = get_dmabuf(&buffer) {
                    let dmabuf = dmabuf.clone();
                    let key = self.buffer_key(&buffer);
                    if is_planar_yuv(dmabuf.format().code as u32) {
                        // Drawn by the GPU as a layer, which also converts it.
                        if let Some(old) = self.windows[i].shown.take() {
                            self.release_next.push(old);
                        }
                        self.set_dma_layer(surface, buffer, key, dmabuf);
                        None
                    } else {
                        // Read by the GPU until a frame is drawn with its successor.
                        if let Some(old) = self.windows[i].shown.replace(buffer) {
                            self.release_next.push(old);
                        }
                        self.windows[i].root_frame = None;
                        self.windows[i].root_dma = Some((key, dmabuf.clone()));
                        Some(Content::Dmabuf { key, dmabuf })
                    }
                } else {
                    let frame = read_shm(&buffer);
                    // Copied out, so the client may reuse it at once.
                    buffer.release();
                    if let Some(old) = self.windows[i].shown.take() {
                        self.release_next.push(old);
                    }
                    if let Some(old) = self.dma_layers.remove(&surface.id()) {
                        self.release_next.push(old.buffer);
                    }
                    let Some(frame) = frame else { return };
                    self.windows[i].root_dma = None;
                    self.windows[i].root_frame = Some(frame.clone());
                    shm = true;
                    Some(Content::Pixels(frame))
                };
                let window = &mut self.windows[i];
                let (app_id, title) = with_states(surface, |states| {
                    let data = states
                        .data_map
                        .get::<XdgToplevelSurfaceData>()
                        .and_then(|d| d.lock().ok());
                    data.map(|d| {
                        (
                            d.app_id.clone().unwrap_or_default(),
                            d.title.clone().unwrap_or_default(),
                        )
                    })
                    .unwrap_or_default()
                });
                window.app_id = app_id;
                window.title = title;
                if content.is_some() {
                    window.frame = content;
                    if !window.mapped {
                        window.mapped = true;
                        let id = window.id;
                        self.events.push(WindowEvent::Mapped(id));
                    }
                }
                self.recomposite(i, shm);
            }
            Some(BufferAssignment::Removed) if self.windows[i].mapped => {
                let id = self.windows[i].id;
                self.dismiss_popups(Some(id));
                let window = &mut self.windows[i];
                window.mapped = false;
                window.frame = None;
                window.root_dma = None;
                window.root_frame = None;
                let id = window.id;
                if let Some(old) = window.shown.take() {
                    self.release_next.push(old);
                }
                self.events.push(WindowEvent::Unmapped(id));
            }
            _ => {}
        }
    }
}

impl State {
    /// Text-input changes as window events, the last per window: Godot's LineEdit enables,
    /// disables and enables again in one go when tapped.
    fn text_input_events(&mut self) {
        let changes = std::mem::take(&mut self.text_input.changes);
        for (n, (surface, on)) in changes.iter().enumerate() {
            if changes[n + 1..].iter().any(|(s, _)| s == surface) {
                continue;
            }
            if let Some(w) = self.windows.iter().find(|w| w.toplevel.wl_surface() == surface) {
                self.events.push(WindowEvent::TextInput(w.id, *on));
            }
        }
    }

    /// The client's scale: by its PID, else its process group, in `launch_scales`; else 1.
    pub fn client_scale(&self, client: &Client) -> f64 {
        let Some(data) = client.get_data::<ClientState>() else { return 1.0 };
        let mut slot = data.scale.lock().unwrap_or_else(|e| e.into_inner());
        *slot.get_or_insert_with(|| {
            let Ok(pid) = client.get_credentials(&self.dh).map(|c| c.pid) else { return 1.0 };
            // SAFETY: a plain syscall on a number.
            let group = unsafe { libc::getpgid(pid) };
            self.launch_scales.get(&pid).or_else(|| self.launch_scales.get(&group)).copied().unwrap_or(1.0)
        })
    }

    /// Scales the window's client, every window of it, at once: wp_fractional_scale and
    /// preferred_buffer_scale may change at any time, and a new configure gives the new size.
    pub fn set_window_scale(&mut self, id: u64, s: f64) {
        let Some(client) = self.windows.iter().find(|w| w.id == id).and_then(|w| w.toplevel.wl_surface().client()) else {
            return;
        };
        let s = s.clamp(0.25, 8.0);
        if let Some(data) = client.get_data::<ClientState>() {
            *data.scale.lock().unwrap_or_else(|e| e.into_inner()) = Some(s);
        }
        for o in self.output.client_outputs(&client) {
            send_output_scale(&o, s);
        }
        for w in self.windows.iter_mut().filter(|w| w.toplevel.wl_surface().client().as_ref() == Some(&client)) {
            w.scale = s;
            with_surface_tree_downward(
                w.toplevel.wl_surface(),
                (),
                |_, _, _| TraversalAction::DoChildren(()),
                |surface, states, _| {
                    with_fractional_scale(states, |f| f.set_preferred_scale(s));
                    send_surface_state(surface, states, integer_scale(s), Transform::Normal);
                },
                |_, _, _| true,
            );
        }
        self.reconfigure(|w| w.toplevel.wl_surface().client().as_ref() == Some(&client));
    }

    /// The size a window is configured at: the app area (the panel, for projection video) over
    /// its client's scale.
    fn window_size(&self, w: &Window) -> (i32, i32) {
        let video = is_video(&toplevel_app_id(w.toplevel.wl_surface()));
        logical_size(if video { PANEL_PX } else { self.app_area }, w.scale)
    }

    /// Configures the matching windows at their size again, those whose size changed.
    fn reconfigure(&mut self, matches: impl Fn(&Window) -> bool) {
        for i in 0..self.windows.len() {
            if !matches(&self.windows[i]) || !self.windows[i].toplevel.is_initial_configure_sent() {
                continue;
            }
            let size = self.window_size(&self.windows[i]);
            let w = &self.windows[i];
            w.toplevel.with_pending_state(|st| st.size = Some(size.into()));
            w.toplevel.send_pending_configure();
        }
    }

    /// A state request is answered with a configure (the protocol wants one), as the window is;
    /// before the initial configure, the first commit sends that.
    fn answer_state_request(&mut self, toplevel: &ToplevelSurface) {
        let Some(w) = self.windows.iter().find(|w| &w.toplevel == toplevel) else { return };
        if !toplevel.is_initial_configure_sent() {
            return;
        }
        let size = self.window_size(w);
        toplevel.with_pending_state(|st| st.size = Some(size.into()));
        toplevel.send_configure();
    }

    /// Where hosted apps show, in panel pixels; open windows are configured to it at once.
    pub fn set_app_area(&mut self, w: i32, h: i32) {
        let area = (w.clamp(1, PANEL_PX.0), h.clamp(1, PANEL_PX.1));
        if area != self.app_area {
            self.app_area = area;
            self.reconfigure(|_| true);
        }
    }

    /// See `Window::native`. Lays the window out again at once, so a still picture follows.
    pub fn set_native(&mut self, id: u64, on: bool) {
        let Some(i) = self.windows.iter().position(|w| w.id == id) else { return };
        if self.windows[i].native != on {
            self.windows[i].native = on;
            self.recomposite(i, true);
        }
    }

    /// A subsurface of window `root` committed: keep its picture, then lay the window out again.
    fn commit_layer(&mut self, root: &WlSurface, surface: &WlSurface) {
        let Some(i) = self.windows.iter().position(|w| w.toplevel.wl_surface() == root) else {
            return;
        };
        let assignment = with_states(surface, |states| {
            states.cached_state.get::<SurfaceAttributes>().current().buffer.take()
        });
        let mut shm_changed = false;
        match assignment {
            Some(BufferAssignment::NewBuffer(buffer)) => {
                if let Ok(dmabuf) = get_dmabuf(&buffer) {
                    let dmabuf = dmabuf.clone();
                    let key = self.buffer_key(&buffer);
                    self.set_dma_layer(surface, buffer, key, dmabuf);
                    shm_changed = self.layers.remove(&surface.id()).is_some();
                } else {
                    match read_shm(&buffer) {
                        Some(f) => {
                            self.layers.insert(surface.id(), f);
                        }
                        None => {
                            self.layers.remove(&surface.id());
                        }
                    }
                    buffer.release();
                    shm_changed = true;
                    if let Some(old) = self.dma_layers.remove(&surface.id()) {
                        self.release_next.push(old.buffer);
                    }
                }
            }
            Some(BufferAssignment::Removed) => {
                shm_changed = self.layers.remove(&surface.id()).is_some();
                if let Some(old) = self.dma_layers.remove(&surface.id()) {
                    self.release_next.push(old.buffer);
                }
            }
            None => {}
        }
        self.recomposite(i, shm_changed);
    }

    fn buffer_key(&mut self, buffer: &WlBuffer) -> u64 {
        *self.buffer_keys.entry(buffer.id()).or_insert_with(|| {
            self.next_key += 1;
            self.next_key
        })
    }

    /// `surface` now shows this dmabuf; the one it showed is released a frame later.
    fn set_dma_layer(&mut self, surface: &WlSurface, buffer: WlBuffer, key: u64, dmabuf: Dmabuf) {
        let layer = DmaLayer { surface: surface.clone(), buffer, key, dmabuf };
        if let Some(old) = self.dma_layers.insert(surface.id(), layer) {
            if old.buffer != self.dma_layers[&surface.id()].buffer {
                self.release_next.push(old.buffer);
            }
        }
    }

    /// Window `i` as its toplevel's own picture with every subsurface's over it, bottom to top; the
    /// window is as big as the toplevel's picture, or where the layers reach if that is a placeholder.
    /// Dmabuf layers go to the GPU as a `Scene` over the shm picture; `shm_changed` says whether
    /// that picture needs laying out again.
    fn recomposite(&mut self, i: usize, shm_changed: bool) {
        let root = self.windows[i].toplevel.wl_surface().clone();
        let mut placed: Vec<(ObjectId, Point<i32, Logical>)> = Vec::new();
        // The toplevel's tree, then each popup's above it, parents first.
        let popups = self.popups_of(&root);
        let trees = std::iter::once((root.clone(), (0, 0).into()))
            .chain(popups.iter().map(|p| (p.wl_surface().clone(), popup_location(p.wl_surface()))));
        for (top, at) in trees {
            with_surface_tree_downward(
                &top,
                at,
                |_, states, loc| {
                    let sub = states.cached_state.get::<SubsurfaceCachedState>().current().location;
                    TraversalAction::DoChildren(*loc + sub)
                },
                // The state passed down is the parent's: a surface's own offset is added here.
                |surf, states, loc| {
                    let own = states.cached_state.get::<SubsurfaceCachedState>().current().location;
                    placed.push((surf.id(), *loc + own))
                },
                |_, _, _| true,
            );
        }
        // Subsurfaces sit at surface units; the window's frame is in its buffer's pixels.
        let k = self.windows[i].buffer_scale;
        let px = |v: f64| (v * k).round() as i32;
        for (_, loc) in &mut placed {
            *loc = (px(loc.x as f64), px(loc.y as f64)).into();
        }
        let root_id = root.id();
        let has_layers = placed.iter().any(|(id, _)| *id != root_id && self.layers.contains_key(id));
        let dma: Vec<(Point<i32, Logical>, &DmaLayer)> =
            placed.iter().filter_map(|(id, loc)| Some((*loc, self.dma_layers.get(id)?))).collect();
        if !has_layers && dma.is_empty() {
            // Nothing over the toplevel any more: the window is its own picture again.
            let win = &mut self.windows[i];
            if !std::mem::take(&mut win.composited) {
                return;
            }
            let own = match (&win.root_dma, &win.root_frame) {
                (Some((key, dmabuf)), _) => Some(Content::Dmabuf { key: *key, dmabuf: dmabuf.clone() }),
                (None, Some(f)) if f.width > 1 || f.height > 1 => Some(Content::Pixels(f.clone())),
                _ => None,
            };
            if let Some(own) = own.filter(|_| win.mapped) {
                win.frame = Some(own);
                win.canvas = None;
                win.canvas_size = (0, 0);
            }
            return;
        }
        let base = self.windows[i].root_frame.clone();
        let real_base = base.as_ref().filter(|f| f.width > 1 || f.height > 1);
        // Only video's placeholder toplevel: an app's own picture is the window, with its popups,
        // even if the projection view set it native when it took the window over.
        if self.windows[i].native && real_base.is_none() && self.windows[i].root_dma.is_none() {
            let largest = dma.iter().map(|(_, d)| *d).max_by_key(|d| {
                let s = d.dmabuf.size();
                s.w as i64 * s.h as i64
            });
            if let Some(d) = largest {
                let buf = d.dmabuf.size();
                let (_, _, src) = layer_geometry(d);
                let w = ((src[2] - src[0]) * buf.w as f32).round().max(1.0) as i32;
                let h = ((src[3] - src[1]) * buf.h as f32).round().max(1.0) as i32;
                let layer = SceneLayer { key: d.key, dmabuf: d.dmabuf.clone(), x: 0, y: 0, w, h, src };
                let win = &mut self.windows[i];
                win.canvas = None;
                win.canvas_size = (w as u32, h as u32);
                win.frame = Some(Content::Scene(Scene { width: w as u32, height: h as u32, canvas: None, layers: vec![layer] }));
                win.composited = true;
                if !win.mapped {
                    win.mapped = true;
                    self.events.push(WindowEvent::Mapped(win.id));
                }
                return;
            }
        }
        let (mut w, mut h) = real_base.map_or((0, 0), |f| (f.width, f.height));
        for (id, loc) in &placed {
            if let Some(f) = self.layers.get(id) {
                w = w.max((loc.x.max(0) as u32) + f.width);
                h = h.max((loc.y.max(0) as u32) + f.height);
            }
        }
        let mut layers = Vec::new();
        // Over the shm canvas, so an shm popup over a dmabuf toplevel is hidden; clients use one
        // kind for all their surfaces.
        if let Some((key, dmabuf)) = &self.windows[i].root_dma {
            let buf = dmabuf.size();
            w = w.max(buf.w as u32);
            h = h.max(buf.h as u32);
            layers.push(SceneLayer { key: *key, dmabuf: dmabuf.clone(), x: 0, y: 0, w: buf.w, h: buf.h, src: [0.0, 0.0, 1.0, 1.0] });
        }
        for (loc, d) in &dma {
            let (lw, lh, src) = layer_geometry(d);
            let (lw, lh) = (px(lw as f64).max(1), px(lh as f64).max(1));
            w = w.max((loc.x.max(0) + lw) as u32);
            h = h.max((loc.y.max(0) + lh) as u32);
            layers.push(SceneLayer { key: d.key, dmabuf: d.dmabuf.clone(), x: loc.x, y: loc.y, w: lw, h: lh, src });
        }
        if !dma.is_empty() && real_base.is_none() {
            // A video window's toplevel is a placeholder scaled to the whole window by viewporter.
            if let Some(d) = with_states(&root, |s| s.cached_state.get::<ViewportCachedState>().current().dst) {
                w = w.max(px(d.w as f64).max(0) as u32);
                h = h.max(px(d.h as f64).max(0) as u32);
            }
        }
        if w == 0 || h == 0 {
            return;
        }
        let needs_canvas = has_layers || real_base.is_some();
        let placed_shm: Vec<(Point<i32, Logical>, &Frame)> =
            placed.iter().filter(|(id, _)| *id != root_id).filter_map(|(id, loc)| Some((*loc, self.layers.get(id)?))).collect();
        let build = || {
            let mut canvas = vec![0u8; (w * h * 4) as usize];
            if let Some(f) = real_base {
                blit(&mut canvas, w, h, f, 0, 0);
            }
            for (loc, f) in &placed_shm {
                blit(&mut canvas, w, h, f, loc.x, loc.y);
            }
            Frame { width: w, height: h, rgba: canvas }
        };
        let content = if layers.is_empty() {
            self.windows[i].canvas = None;
            self.windows[i].canvas_size = (0, 0);
            Content::Pixels(build())
        } else {
            let win = &self.windows[i];
            if shm_changed || win.canvas_size != (w, h) {
                let canvas = needs_canvas.then(|| {
                    self.next_gen += 1;
                    (self.next_gen, Arc::new(build()))
                });
                let win = &mut self.windows[i];
                win.canvas = canvas;
                win.canvas_size = (w, h);
            }
            Content::Scene(Scene { width: w, height: h, canvas: self.windows[i].canvas.clone(), layers })
        };
        let window = &mut self.windows[i];
        window.frame = Some(content);
        window.composited = true;
        if !window.mapped {
            window.mapped = true;
            let id = window.id;
            self.events.push(WindowEvent::Mapped(id));
        }
    }

    /// The live popups over the toplevel `root`, parents before children.
    fn popups_of(&self, root: &WlSurface) -> Vec<PopupSurface> {
        self.xdg_shell.popup_surfaces().iter().filter(|p| p.alive() && &toplevel_of(p.wl_surface()) == root).cloned().collect()
    }

    /// The topmost shown popup of `root` whose window geometry holds `at` (toplevel units).
    fn popup_at(&self, root: &WlSurface, at: Point<f64, Logical>) -> Option<WlSurface> {
        self.popups_of(root).into_iter().rev().map(|p| p.wl_surface().clone()).find(|s| {
            let shown = self.layers.contains_key(&s.id()) || self.dma_layers.contains_key(&s.id());
            let size = popup_data(s).map_or(Default::default(), |(_, g)| g.size);
            shown && Rectangle::new(geometry_origin(s), size).to_f64().contains(at)
        })
    }

    /// Sends popup_done to the window's popups, or every window's, topmost first.
    pub fn dismiss_popups(&mut self, window: Option<u64>) {
        let roots: Vec<WlSurface> =
            self.windows.iter().filter(|w| window.is_none_or(|id| w.id == id)).map(|w| w.toplevel.wl_surface().clone()).collect();
        for root in roots {
            for p in self.popups_of(&root).into_iter().rev() {
                p.send_popup_done();
                self.grabbed.retain(|s| s != p.wl_surface());
            }
        }
    }

    /// Where a popup goes: as its positioner asks, kept inside its window (the app area at the
    /// client's scale) by the adjustments the positioner allows.
    fn place_popup(&self, parent: Option<&WlSurface>, positioner: PositionerState) -> Rectangle<i32, Logical> {
        let window = parent.and_then(|p| {
            let root = toplevel_of(p);
            Some((p.clone(), self.windows.iter().find(|w| w.toplevel.wl_surface() == &root)?))
        });
        let Some((parent, w)) = window else { return positioner.get_geometry() };
        // The window, in the parent's window-geometry coordinates.
        let origin = geometry_origin(&parent);
        positioner.get_unconstrained_geometry(Rectangle::new((-origin.x, -origin.y).into(), self.window_size(w).into()))
    }
}

/// Source over destination into `canvas`, w x h RGBA, with `f` at (x0, y0).
fn blit(canvas: &mut [u8], w: u32, h: u32, f: &Frame, x0: i32, y0: i32) {
    for y in 0..f.height as i32 {
        let dy = y0 + y;
        if dy < 0 || dy >= h as i32 {
            continue;
        }
        for x in 0..f.width as i32 {
            let dx = x0 + x;
            if dx < 0 || dx >= w as i32 {
                continue;
            }
            let s = ((y as u32 * f.width + x as u32) * 4) as usize;
            let d = ((dy as u32 * w + dx as u32) * 4) as usize;
            let a = f.rgba[s + 3] as u32;
            if a == 255 {
                canvas[d..d + 4].copy_from_slice(&f.rgba[s..s + 4]);
            } else if a > 0 {
                for k in 0..3 {
                    canvas[d + k] = ((f.rgba[s + k] as u32 * a + canvas[d + k] as u32 * (255 - a)) / 255) as u8;
                }
                canvas[d + 3] = (a + canvas[d + 3] as u32 * (255 - a) / 255).min(255) as u8;
            }
        }
    }
}

/// An xdg_popup's parent surface and its geometry (relative to the parent's window geometry).
fn popup_data(surface: &WlSurface) -> Option<(WlSurface, Rectangle<i32, Logical>)> {
    with_states(surface, |states| {
        let d = states.data_map.get::<XdgPopupSurfaceData>()?.lock().ok()?;
        Some((d.parent.clone()?, d.current.geometry))
    })
}

fn window_geometry_loc(surface: &WlSurface) -> Point<i32, Logical> {
    with_states(surface, |states| {
        states.cached_state.get::<SurfaceCachedState>().current().geometry.map_or((0, 0).into(), |g| g.loc)
    })
}

/// Where the surface's window geometry starts, in its toplevel surface's units.
fn geometry_origin(surface: &WlSurface) -> Point<i32, Logical> {
    match popup_data(surface) {
        Some((parent, geometry)) => geometry_origin(&parent) + geometry.loc,
        None => window_geometry_loc(surface),
    }
}

/// Where a popup's surface sits, in its toplevel surface's units.
fn popup_location(surface: &WlSurface) -> Point<i32, Logical> {
    geometry_origin(surface) - window_geometry_loc(surface)
}

/// The toplevel a popup (or popup of a popup) belongs to; any other surface is its own.
fn toplevel_of(surface: &WlSurface) -> WlSurface {
    let mut s = surface.clone();
    while let Some((parent, _)) = popup_data(&s) {
        s = parent;
    }
    s
}

/// Buffer pixels per surface unit across: what the viewport's destination (or source) or the
/// buffer scale makes of a `buf_w` wide buffer.
fn buffer_per_unit(surface: &WlSurface, buf_w: i32) -> f64 {
    with_states(surface, |states| {
        let vp = *states.cached_state.get::<ViewportCachedState>().current();
        let scale = states.cached_state.get::<SurfaceAttributes>().current().buffer_scale.max(1) as f64;
        let w = vp.dst.map(|d| d.w as f64).or(vp.src.map(|r| r.size.w)).unwrap_or(buf_w as f64 / scale);
        if w > 0.0 { buf_w as f64 / w } else { 1.0 }
    })
}

/// A dmabuf layer's size in surface units and the 0..1 part of the buffer it shows, from its
/// viewporter state (source crop, destination size) and buffer scale.
fn layer_geometry(d: &DmaLayer) -> (i32, i32, [f32; 4]) {
    let buf = d.dmabuf.size();
    with_states(&d.surface, |states| {
        let vp = *states.cached_state.get::<ViewportCachedState>().current();
        let scale = states.cached_state.get::<SurfaceAttributes>().current().buffer_scale.max(1) as f64;
        let (bw, bh) = (buf.w as f64 / scale, buf.h as f64 / scale);
        let (src, size) = match vp.src {
            Some(r) => (
                [(r.loc.x / bw) as f32, (r.loc.y / bh) as f32, ((r.loc.x + r.size.w) / bw) as f32, ((r.loc.y + r.size.h) / bh) as f32],
                (r.size.w.round() as i32, r.size.h.round() as i32),
            ),
            None => ([0.0, 0.0, 1.0, 1.0], (bw.round() as i32, bh.round() as i32)),
        };
        let (w, h) = vp.dst.map_or(size, |d| (d.w, d.h));
        (w.max(1), h.max(1), src)
    })
}

impl DmabufHandler for State {
    fn dmabuf_state(&mut self) -> &mut DmabufState {
        &mut self.dmabuf
    }

    /// Accepted as offered: the formats came from what Godot's EGL can import, and an import
    /// that still fails shows up when the embedder takes the frame.
    fn dmabuf_imported(&mut self, _: &DmabufGlobal, _: Dmabuf, notifier: ImportNotifier) {
        let _ = notifier.successful::<State>();
    }
}

impl XdgShellHandler for State {
    fn xdg_shell_state(&mut self) -> &mut XdgShellState {
        &mut self.xdg_shell
    }

    fn new_toplevel(&mut self, toplevel: ToplevelSurface) {
        // The panel is the only place a window can be: fullscreen on it.
        use smithay::reexports::wayland_protocols::xdg::shell::server::xdg_toplevel::State as XdgState;
        let scale = toplevel.wl_surface().client().map_or(1.0, |c| self.client_scale(&c));
        // wl_output's integer scale reaches only surfaces on the output.
        self.output.enter(toplevel.wl_surface());
        // The size goes with the initial configure, on the first commit, once the app_id is known.
        toplevel.with_pending_state(|s| {
            s.states.set(XdgState::Fullscreen);
            s.states.set(XdgState::Activated);
        });
        let id = self.next_id;
        self.next_id += 1;
        self.windows.push(Window {
            id,
            toplevel,
            app_id: String::new(),
            title: String::new(),
            frame: None,
            mapped: false,
            shown: None,
            root_frame: None,
            root_dma: None,
            composited: false,
            canvas: None,
            canvas_size: (0, 0),
            native: false,
            scale,
            buffer_scale: 1.0,
        });
    }

    fn toplevel_destroyed(&mut self, toplevel: ToplevelSurface) {
        let Some(i) = self.windows.iter().position(|w| w.toplevel == toplevel) else {
            return;
        };
        if self.text_input.focus() == Some(toplevel.wl_surface()) {
            self.text_input.set_focus(None);
            self.text_input_events();
        }
        let id = self.windows[i].id;
        self.dismiss_popups(Some(id));
        let w = self.windows.remove(i);
        if w.mapped {
            self.events.push(WindowEvent::Unmapped(w.id));
        }
    }

    /// Configured at once: GTK 4 blocks until a popup's first configure (a touch in an entry
    /// opens its text handles as popups).
    fn new_popup(&mut self, popup: PopupSurface, positioner: PositionerState) {
        let geometry = self.place_popup(popup.get_parent_surface().as_ref(), positioner);
        popup.with_pending_state(|s| {
            s.geometry = geometry;
            s.positioner = positioner;
        });
        // GTK 3 takes a popup's scale from the outputs it is on.
        self.output.enter(popup.wl_surface());
        let _ = popup.send_configure();
    }

    // Fullscreen at the app area whatever is asked. smithay's defaults configure at once, which
    // before the first commit is the initial configure, sizeless: Firefox maximizes then, and
    // drew at its own default size.
    fn maximize_request(&mut self, toplevel: ToplevelSurface) {
        self.answer_state_request(&toplevel);
    }

    fn unmaximize_request(&mut self, toplevel: ToplevelSurface) {
        self.answer_state_request(&toplevel);
    }

    fn fullscreen_request(&mut self, toplevel: ToplevelSurface, _: Option<WlOutput>) {
        self.answer_state_request(&toplevel);
    }

    fn unfullscreen_request(&mut self, toplevel: ToplevelSurface) {
        self.answer_state_request(&toplevel);
    }

    fn grab(&mut self, popup: PopupSurface, _: WlSeat, _: Serial) {
        if !self.grabbed.contains(popup.wl_surface()) {
            self.grabbed.push(popup.wl_surface().clone());
        }
    }

    /// GTK 4 blocks until a reposition is answered.
    fn reposition_request(&mut self, popup: PopupSurface, positioner: PositionerState, token: u32) {
        let geometry = self.place_popup(popup.get_parent_surface().as_ref(), positioner);
        popup.with_pending_state(|s| {
            s.geometry = geometry;
            s.positioner = positioner;
        });
        // With its configure.
        popup.send_repositioned(token);
    }

    fn popup_destroyed(&mut self, popup: PopupSurface) {
        let surface = popup.wl_surface();
        self.grabbed.retain(|s| s != surface);
        self.layers.remove(&surface.id());
        if let Some(old) = self.dma_layers.remove(&surface.id()) {
            self.release_next.push(old.buffer);
        }
        let root = toplevel_of(surface);
        if let Some(i) = self.windows.iter().position(|w| w.toplevel.wl_surface() == &root) {
            self.recomposite(i, true);
        }
    }
}

impl ShmHandler for State {
    fn shm_state(&self) -> &ShmState {
        &self.shm
    }
}

impl BufferHandler for State {
    fn buffer_destroyed(&mut self, buffer: &WlBuffer) {
        if let Some(key) = self.buffer_keys.remove(&buffer.id()) {
            self.gone_buffers.push(key);
        }
    }
}

impl SeatHandler for State {
    type KeyboardFocus = WlSurface;
    type PointerFocus = WlSurface;
    type TouchFocus = WlSurface;

    fn seat_state(&mut self) -> &mut SeatState<State> {
        &mut self.seat_state
    }
}

delegate_compositor!(State);
delegate_xdg_shell!(State);
delegate_shm!(State);
delegate_seat!(State);
delegate_dmabuf!(State);
delegate_output!(State);
delegate_viewporter!(State);

impl ClientDndGrabHandler for State {}
impl ServerDndGrabHandler for State {}
impl SelectionHandler for State {
    type SelectionUserData = ();
}
impl DataDeviceHandler for State {
    fn data_device_state(&self) -> &DataDeviceState {
        &self.data_device
    }
}
delegate_data_device!(State);

/// wl_output's scale is per bound resource, so each client gets its own.
fn send_output_scale(o: &WlOutput, s: f64) {
    if o.version() >= 2 {
        o.scale(integer_scale(s));
        o.done();
    }
}

impl OutputHandler for State {
    fn output_bound(&mut self, _: Output, o: WlOutput) {
        let s = o.client().map_or(1.0, |c| self.client_scale(&c));
        if integer_scale(s) != 1 {
            send_output_scale(&o, s);
        }
    }
}

impl FractionalScaleHandler for State {}
delegate_fractional_scale!(State);

#[cfg(test)]
mod tests {
    use std::thread;
    use std::time::Duration;

    use wayland_client::Connection;

    use std::os::fd::AsRawFd;

    use super::*;
    use crate::test_client::{self, Format as BufFormat, Honour, Opts, Pattern};

    /// Dispatches and completes frames until `done` holds; false after five seconds.
    fn pump(server: &mut Server, mut done: impl FnMut(&State) -> bool) -> bool {
        let until = Instant::now() + Duration::from_secs(5);
        while Instant::now() < until {
            server.dispatch().unwrap();
            if done(&server.state) {
                return true;
            }
            server.frame_done();
            thread::sleep(Duration::from_millis(1));
        }
        false
    }

    const XRGB8888: u32 = 0x3432_5258;
    const LINEAR: u64 = 0;

    fn server() -> Server {
        let mut server = Server::new().unwrap();
        server.enable_dmabuf(&[(XRGB8888, LINEAR)], None).unwrap();
        server
    }

    fn client(server: &mut Server, opts: Opts) -> thread::JoinHandle<test_client::Report> {
        let (ours, theirs) = UnixStream::pair().unwrap();
        server.insert_client(ours).unwrap();
        thread::spawn(move || test_client::run(Connection::from_socket(theirs).unwrap(), &opts).unwrap())
    }

    fn opts(pattern: Pattern, animate: Option<u32>, dmabuf: bool) -> Opts {
        Opts {
            app_id: "org.test.app".into(),
            title: "test".into(),
            width: 96,
            height: 64,
            pattern,
            animate,
            dmabuf,
            format: BufFormat::Xrgb8888,
            video: false,
            events: None,
            honour: Honour::None,
            text_input: None,
            maximize: false,
            popup: false,
        }
    }

    /// Clients of this test process get scale `s`, through `launch_scales` as launched apps do.
    fn scaled(s: f64) -> Server {
        let mut server = server();
        server.state.launch_scales.insert(std::process::id() as i32, s);
        server
    }

    /// Buffer pixels per surface unit a client draws at for scale `s`.
    fn honoured(h: Honour, s: f64) -> f64 {
        match h {
            Honour::None => 1.0,
            Honour::Fractional => s,
            Honour::Integer => integer_scale(s) as f64,
        }
    }

    /// A frame's pixels whichever way they came; a dmabuf is read through a CPU mapping, and a
    /// scene's RGB layers are laid over its canvas as the GPU would (nearest pixel).
    fn pixels(content: &Content) -> Frame {
        match content {
            Content::Scene(sc) => {
                let (w, h) = (sc.width, sc.height);
                let mut out = sc.canvas.as_ref().map_or_else(|| Frame { width: w, height: h, rgba: vec![0; (w * h * 4) as usize] }, |(_, f)| (**f).clone());
                for l in &sc.layers {
                    let src = pixels(&Content::Dmabuf { key: l.key, dmabuf: l.dmabuf.clone() });
                    for y in 0..l.h {
                        for x in 0..l.w {
                            let (dx, dy) = (l.x + x, l.y + y);
                            if dx < 0 || dy < 0 || dx >= w as i32 || dy >= h as i32 {
                                continue;
                            }
                            let u = l.src[0] + (l.src[2] - l.src[0]) * (x as f32 + 0.5) / l.w as f32;
                            let v = l.src[1] + (l.src[3] - l.src[1]) * (y as f32 + 0.5) / l.h as f32;
                            let (sx, sy) = ((u * src.width as f32) as u32, (v * src.height as f32) as u32);
                            let s = ((sy.min(src.height - 1) * src.width + sx.min(src.width - 1)) * 4) as usize;
                            let d = ((dy as u32 * w + dx as u32) * 4) as usize;
                            out.rgba[d..d + 4].copy_from_slice(&src.rgba[s..s + 4]);
                        }
                    }
                }
                out
            }
            Content::Pixels(f) => f.clone(),
            Content::Dmabuf { dmabuf, .. } => {
                use std::os::fd::AsRawFd;
                let size = dmabuf.size();
                let stride = dmabuf.strides().next().unwrap() as usize;
                let len = stride * size.h as usize;
                let fd = dmabuf.handles().next().unwrap().as_raw_fd();
                // SAFETY: a read-only mapping of the client's buffer, unmapped below.
                let map = unsafe { libc::mmap(std::ptr::null_mut(), len, libc::PROT_READ, libc::MAP_SHARED, fd, 0) };
                assert_ne!(map, libc::MAP_FAILED, "mmap of the dmabuf");
                let src = unsafe { std::slice::from_raw_parts(map as *const u8, len) };
                let rgba = to_rgba(src, size.w as u32, size.h as u32, stride, Format::Xrgb8888).unwrap();
                unsafe { libc::munmap(map, len) };
                Frame { width: size.w as u32, height: size.h as u32, rgba }
            }
        }
    }

    #[test]
    /// At any scale the client honours, the frame is its buffer, the picture drawn at that many
    /// pixels per surface unit, and a scale changed live is drawn at anew. 96 x 64 surface units.
    fn a_client_buffer_becomes_its_window_frame() {
        let cases: &[(bool, Honour, f64, Option<f64>)] = &[
            (false, Honour::None, 1.0, None),
            (true, Honour::None, 1.0, None),
            (false, Honour::Fractional, 1.5, Some(2.0)),
            (true, Honour::Fractional, 1.75, Some(1.25)),
            (false, Honour::Integer, 2.0, Some(1.0)),
            // The nearest whole scale.
            (false, Honour::Integer, 1.5, None),
            (false, Honour::None, 1.5, Some(2.0)),
        ];
        for &(dmabuf, honour, scale, then) in cases {
            let case = format!("dmabuf={dmabuf} {honour:?} {scale}");
            let mut server = scaled(scale);
            let mut o = opts(Pattern::Grid, None, dmabuf);
            o.honour = honour;
            let _client = client(&mut server, o);
            assert!(pump(&mut server, |s| s.events.contains(&WindowEvent::Mapped(1))), "{case}");
            let w = &server.state.windows[0];
            assert_eq!((w.app_id.as_str(), w.title.as_str(), w.scale), ("org.test.app", "test", scale), "{case}");
            assert_eq!(matches!(w.frame.as_ref().unwrap(), Content::Dmabuf { .. }), dmabuf, "{case}");
            for s in std::iter::once(scale).chain(then) {
                let k = honoured(honour, s);
                let (fw, fh) = ((96.0 * k).round() as u32, (64.0 * k).round() as u32);
                if s != scale {
                    server.state.set_window_scale(1, s);
                    assert!(
                        pump(&mut server, |st| st.windows[0].frame.as_ref().is_some_and(|c| pixels(c).width == fw)),
                        "{case} -> {s}: no {fw} px frame"
                    );
                }
                let w = &server.state.windows[0];
                assert_eq!(w.buffer_scale, k, "{case} -> {s}");
                let f = pixels(w.frame.as_ref().unwrap());
                assert_eq!((f.width, f.height, f.rgba.len()), (fw, fh, (fw * fh * 4) as usize), "{case} -> {s}");
                let at = |x: u32, y: u32| &f.rgba[((y * fw + x) * 4) as usize..][..4];
                // Each side of the red cell's edge, 64 units in, and the far corners.
                let edge = (64.0 * k) as u32;
                for (x, y) in [(0, 0), (edge - 1, 0), (edge, 0), (fw - 1, edge - 1), (fw - 1, fh - 1)] {
                    let want = Pattern::Grid.pixel((x as f64 / k) as u32, (y as f64 / k) as u32, 96);
                    assert_eq!(at(x, y), want, "{case} -> {s} ({x}, {y})");
                }
            }
        }
    }

    #[test]
    fn scales_for_the_panel() {
        // The panel from 750 mm (rules.yaml's view_mm), a desktop's distance, and closer and farther.
        for (view_mm, want) in [(750.0, 1.75), (711.2, 1.75), (600.0, 1.5), (400.0, 1.0), (2000.0, 2.0)] {
            assert_eq!(default_scale(view_mm), want, "{view_mm} mm");
        }
        // The panel, and the area beside a docked rail under the status bar.
        let beside = (1823, 657);
        for (area, s, size, int) in [
            (PANEL_PX, 1.0, (1920, 720), 1),
            (PANEL_PX, 1.25, (1536, 576), 1),
            (PANEL_PX, 1.5, (1280, 480), 2),
            (PANEL_PX, 1.75, (1097, 411), 2),
            (PANEL_PX, 2.0, (960, 360), 2),
            (beside, 1.0, (1823, 657), 1),
            (beside, 1.75, (1042, 375), 2),
        ] {
            assert_eq!((logical_size(area, s), integer_scale(s)), (size, int), "{area:?} {s}");
        }
    }

    /// A window is configured at the app area over its scale, projection video at the panel's;
    /// a new area reconfigures open windows. The client draws at what it is configured to, also
    /// when it asks to be maximized before its first commit.
    #[test]
    fn windows_are_configured_to_the_app_area() {
        let beside = (1823, 657);
        for (app_id, s, area, want, then, maximize) in [
            ("org.test.app", 1.0, PANEL_PX, (1920, 720), (1823, 657), false),
            ("org.test.app", 1.75, beside, (1042, 375), (1097, 411), false),
            ("livi-video-main", 1.0, beside, (1920, 720), (1920, 720), false),
            ("org.test.app", 1.0, beside, (1823, 657), (1920, 720), true),
            ("org.test.app", 1.75, beside, (1042, 375), (1097, 411), true),
        ] {
            let mut server = scaled(s);
            server.state.set_app_area(area.0, area.1);
            let mut o = opts(Pattern::Grid, None, false);
            o.app_id = app_id.into();
            o.maximize = maximize;
            (o.width, o.height) = (0, 0);
            let _client = client(&mut server, o);
            let case = format!("{app_id} {s} {area:?} maximize={maximize}");
            assert!(pump(&mut server, |st| st.events.contains(&WindowEvent::Mapped(1))), "{case}");
            let f = pixels(server.state.windows[0].frame.as_ref().unwrap());
            assert_eq!((f.width as i32, f.height as i32), want, "{case}");
            let next = if area == PANEL_PX { beside } else { PANEL_PX };
            server.state.set_app_area(next.0, next.1);
            let size = server.state.windows[0].toplevel.with_pending_state(|st| st.size);
            assert_eq!(size, Some(then.into()), "{case} then {next:?}");
        }
    }

    /// Video as waylandsink sends it: a placeholder toplevel scaled to the panel, with the
    /// planar YUV dmabuf in a viewporter-scaled subsurface, reaches the embedder as a scene with
    /// the layer where the client put it, whatever the plane layout; or, native, as the buffer.
    #[test]
    fn a_planar_video_subsurface_becomes_a_scene_layer() {
        const NV12: u32 = 0x3231_564e;
        const YU12: u32 = 0x3231_5559;
        for (format, planes) in [(BufFormat::Nv12, 2), (BufFormat::I420, 3)] {
            let mut server = Server::new().unwrap();
            server.enable_dmabuf(&[(XRGB8888, LINEAR), (NV12, LINEAR), (YU12, LINEAR)], None).unwrap();
            let mut o = opts(Pattern::Bars, None, true);
            (o.format, o.video) = (format, true);
            let _client = client(&mut server, o);
            assert!(pump(&mut server, |s| s.events.contains(&WindowEvent::Mapped(1))), "{format:?}");
            let Some(Content::Scene(sc)) = &server.state.windows[0].frame else { panic!("{format:?}: not a scene") };
            assert_eq!((sc.width, sc.height), (1920, 720));
            assert!(sc.canvas.is_none());
            let [l] = &sc.layers[..] else { panic!("{format:?}: {} layers", sc.layers.len()) };
            assert_eq!((l.x, l.y, l.w, l.h, l.src), (888, 312, 144, 96, [0.0, 0.0, 1.0, 1.0]));
            assert_eq!(l.dmabuf.num_planes(), planes);
            // Luma of the first (white) and last (black) bars, through a CPU mapping.
            let (offset, stride) = (l.dmabuf.offsets().next().unwrap() as usize, l.dmabuf.strides().next().unwrap() as usize);
            let len = offset + stride * 64;
            let fd = l.dmabuf.handles().next().unwrap().as_raw_fd();
            // SAFETY: a read-only mapping of the client's buffer, unmapped below.
            let map = unsafe { libc::mmap(std::ptr::null_mut(), len.next_multiple_of(4096), libc::PROT_READ, libc::MAP_SHARED, fd, 0) };
            assert_ne!(map, libc::MAP_FAILED, "mmap of the dmabuf");
            let y = unsafe { std::slice::from_raw_parts(map as *const u8, len) };
            assert_eq!((y[offset], y[offset + 95]), (235, 16), "{format:?}");
            unsafe { libc::munmap(map, len.next_multiple_of(4096)) };
            // Native: the window is the buffer at its own size, the client's scaling undone.
            server.state.set_native(1, true);
            let Some(Content::Scene(sc)) = &server.state.windows[0].frame else { panic!("{format:?}: native: not a scene") };
            assert_eq!((sc.width, sc.height), (96, 64), "{format:?}");
            let [l] = &sc.layers[..] else { panic!("{format:?}: native: {} layers", sc.layers.len()) };
            assert_eq!((l.x, l.y, l.w, l.h, l.src), (0, 0, 96, 64, [0.0, 0.0, 1.0, 1.0]));
        }
    }

    /// For dmabuf this also checks releases: the client has three buffers, so it stalls unless
    /// each is handed back after a frame drawn with the other.
    #[test]
    fn frame_callbacks_pace_the_client_and_it_unmaps_when_done() {
        for dmabuf in [false, true] {
            let mut server = server();
            let client = client(&mut server, opts(Pattern::Bars, Some(5), dmabuf));
            assert!(pump(&mut server, |s| s.events.contains(&WindowEvent::Unmapped(1))), "dmabuf={dmabuf}");
            assert_eq!(client.join().unwrap().drawn, 5);
            assert!(server.state.windows.is_empty());
        }
    }

    /// Each kind of input reaches the window at the position given, in order: positions in the
    /// window's frame, which is `k` buffer pixels per surface unit, land on the surface.
    #[test]
    fn input_reaches_the_window_at_surface_positions() {
        type Send = fn(&mut Server, f64);
        let steps: &[(Send, &[&str])] = &[
            (|s, k| s.pointer_motion(Some(1), 10.5 * k, 20.0 * k), &["pointer enter 10.5 20.0"]),
            (|s, k| s.pointer_motion(Some(1), 12.0 * k, 22.5 * k), &["pointer motion 12.0 22.5"]),
            (|s, _| s.pointer_button(0x110, true), &["pointer button 272 pressed"]),
            (|s, _| s.pointer_button(0x110, false), &["pointer button 272 released"]),
            (|s, _| s.pointer_motion(None, 0.0, 0.0), &["pointer leave"]),
            (|s, k| s.touch_down(1, 0, 30.0 * k, 40.0 * k), &["touch down 0 30.0 40.0"]),
            (|s, k| s.touch_motion(1, 0, 31.0 * k, 41.5 * k), &["touch motion 0 31.0 41.5"]),
            (|s, _| s.touch_up(0), &["touch up 0"]),
            (|s, _| s.keyboard_focus(Some(1)), &["keyboard enter"]),
            (|s, _| s.key(30, true), &["key 30 pressed"]),
            (|s, _| s.key(30, false), &["key 30 released"]),
            (|s, _| s.keyboard_focus(None), &["keyboard leave"]),
        ];
        let cases = [(Honour::None, 1.0), (Honour::Fractional, 1.5), (Honour::Integer, 2.0), (Honour::None, 1.75)];
        for (honour, scale) in cases {
            let k = honoured(honour, scale);
            let mut server = scaled(scale);
            let mut o = opts(Pattern::Grid, None, false);
            o.honour = honour;
            let client = client(&mut server, o);
            assert!(pump(&mut server, |s| s.events.contains(&WindowEvent::Mapped(1))));
            assert_eq!(server.state.windows[0].buffer_scale, k, "{honour:?} {scale}");
            for (send, _) in steps {
                send(&mut server, k);
                server.dispatch().unwrap();
            }
            server.close(1);
            assert!(pump(&mut server, |s| s.windows.is_empty()));
            let got: Vec<String> = client.join().unwrap().events.into_iter().filter(|e| !e.starts_with("buffer ")).collect();
            let want: Vec<&str> = steps.iter().flat_map(|(_, w)| w.iter().copied()).collect();
            assert_eq!(got, want, "{honour:?} {scale}");
        }
    }

    /// Typing reaches the window through zwp_text_input_v3 while its field is enabled, else as
    /// keys on a US layout; the shell hears when the field wants text and when it stops (disable,
    /// focus gone). Each step waits until the server sees `until`, then the client gets `lines`.
    #[test]
    fn text_reaches_the_field_or_falls_back_to_keys() {
        type Step = (fn(&mut Server) -> bool, fn(&State) -> bool, &'static [&'static str]);
        let any: fn(&State) -> bool = |_| true;
        let wanted: fn(&State) -> bool = |s| s.events.contains(&WindowEvent::TextInput(1, true));
        let released: fn(&State) -> bool = |s| s.events.contains(&WindowEvent::TextInput(1, false));
        let tap_field: fn(&mut Server) -> bool = |s| {
            s.state.events.clear();
            s.touch_down(1, 0, 10.0, 10.0);
            s.touch_up(0);
            true
        };
        let tap_outside: fn(&mut Server) -> bool = |s| {
            s.state.events.clear();
            s.touch_down(1, 0, 10.0, 60.0);
            s.touch_up(0);
            true
        };
        let with_v3: &[Step] = &[
            (|s| { s.keyboard_focus(Some(1)); true }, any, &["keyboard enter", "text enter"]),
            (tap_field, wanted, &["touch down 0 10.0 10.0", "text enabled"]),
            (
                |s| s.text_field(1) == Some(Field { hint: 0x80 | 0x40, purpose: 8, rect: Some([10, 20, 2, 16]), surrounding: None }) && s.has_text_input(1),
                any,
                &[],
            ),
            // Changes in one dispatch come as the last: Godot enables, disables and enables on a tap.
            (
                |s| {
                    let surface = s.state.windows[0].toplevel.wl_surface().clone();
                    s.state.events.clear();
                    s.state.text_input.changes = [true, false, true].map(|on| (surface.clone(), on)).to_vec();
                    s.state.text_input_events();
                    s.state.events == [WindowEvent::TextInput(1, true)]
                },
                any,
                &[],
            ),
            (|s| s.type_text("hé!"), any, &["text commit hé!"]),
            (|s| s.state.text_input.delete_surrounding(1, 0), any, &["text delete 1 0"]),
            (|s| s.state.text_input.preedit("ab", 2, 2), any, &["text preedit ab"]),
            // Enabled again by a tap while enabled: asked again, for a keyboard put away.
            (tap_field, wanted, &["touch down 0 10.0 10.0"]),
            (tap_outside, released, &["touch down 0 10.0 60.0", "text disabled"]),
            // Disabled: keys, and nothing for what a US layout cannot type.
            (|s| s.text_field(1).is_none() && s.type_text("a"), any, &["key 30 pressed", "key 30 released"]),
            (|s| !s.type_text("é"), any, &[]),
            (tap_field, wanted, &["text enabled"]),
            (|s| { s.state.events.clear(); s.keyboard_focus(None); true }, released, &["keyboard leave", "text leave"]),
            (|s| !s.state.text_input.commit_string("x"), any, &[]),
        ];
        let without: &[Step] = &[
            (|s| { s.keyboard_focus(Some(1)); !s.has_text_input(1) }, any, &["keyboard enter"]),
            (tap_field, any, &["touch down 0 10.0 10.0"]),
            (|s| s.text_field(1).is_none() && s.type_text("Hi"), any, &["key 42 pressed", "key 35 pressed", "key 35 released", "key 42 released", "key 23 pressed"]),
        ];
        for (text_input, steps) in [(Some(8), with_v3), (None, without)] {
            let mut server = server();
            let mut o = opts(Pattern::Grid, None, false);
            o.text_input = text_input;
            let client = client(&mut server, o);
            assert!(pump(&mut server, |s| s.events.contains(&WindowEvent::Mapped(1))));
            for (n, (send, until, _)) in steps.iter().enumerate() {
                assert!(send(&mut server), "{text_input:?} step {n}");
                assert!(pump(&mut server, until), "{text_input:?} step {n}: not seen");
                // The client's answer, before the next step.
                for _ in 0..20 {
                    server.dispatch().unwrap();
                    thread::sleep(Duration::from_millis(2));
                }
            }
            server.close(1);
            assert!(pump(&mut server, |s| s.windows.is_empty()));
            let got: Vec<String> = client.join().unwrap().events;
            let want: Vec<&str> = steps.iter().flat_map(|(_, _, w)| w.iter().copied()).collect();
            let mut rest = got.iter();
            for w in &want {
                assert!(rest.any(|g| g == w), "{text_input:?}: no {w:?} in order in {got:?}");
            }
        }
    }

    /// A tap opens the client's grabbing menu below and right of it, slid to stay in the window,
    /// drawn over the window at its scale. A tap on the menu reaches it; one outside dismisses it
    /// and goes no further, as does the shell dismissing it. `native` (the projection view's,
    /// which may land on an app's window) leaves an app window as it is.
    #[test]
    fn popups_show_over_their_window_and_take_input() {
        let area = (1200, 600);
        for (dmabuf, honour, s, native) in [
            (false, Honour::None, 1.0, false),
            (false, Honour::Fractional, 1.5, false),
            (false, Honour::Integer, 2.0, false),
            (true, Honour::None, 1.0, false),
            (true, Honour::Fractional, 1.75, false),
            (false, Honour::None, 1.0, true),
            (true, Honour::Fractional, 1.75, true),
        ] {
            let case = format!("dmabuf={dmabuf} {honour:?} {s} native={native}");
            let (lw, lh) = logical_size(area, s);
            let mut server = scaled(s);
            server.state.set_app_area(area.0, area.1);
            let mut o = opts(Pattern::Grid, None, dmabuf);
            (o.width, o.height, o.honour, o.popup) = (0, 0, honour, true);
            let client = client(&mut server, o);
            assert!(pump(&mut server, |st| st.events.contains(&WindowEvent::Mapped(1))), "{case}");
            server.state.set_native(1, native);
            // As drawn: 686 units at 1.75 are 1201 px.
            let k = server.state.windows[0].buffer_scale;
            assert!((k - honoured(honour, s)).abs() < 0.01, "{case}: buffer scale {k}");
            // 50 units from the right edge: the 160-unit menu slides left to fit.
            let tap = (lw as f64 - 50.0, 100.0);
            let menu = (lw - 160, 101);
            // The window's picture at a point in surface units.
            let at = move |st: &State, x: i32, y: i32| {
                let f = pixels(st.windows[0].frame.as_ref().unwrap());
                let (px, py) = ((x as f64 * k).round() as u32, (y as f64 * k).round() as u32);
                f.rgba[((py * f.width + px) * 4) as usize..][..4].to_vec()
            };
            let mid = (menu.0 + 80, menu.1 + 48);
            let magenta = Pattern::Bars.pixel(80, 0, 160).to_vec();
            let grid = |x: i32, y: i32| Pattern::Grid.pixel(x as u32, y as u32, 0).to_vec();
            let open = |server: &mut Server| {
                server.touch_down(1, 0, tap.0 * k, tap.1 * k);
                server.touch_up(0);
                pump(server, |st| at(st, mid.0, mid.1) == magenta)
            };
            assert!(open(&mut server), "{case}: no menu");
            // The window is all there under it, at its own size.
            let f = pixels(server.state.windows[0].frame.as_ref().unwrap());
            assert_eq!(f.width, (lw as f64 * k).round() as u32, "{case}: frame width");
            for (x, y) in [(menu.0 - 2, mid.1), (10, 10), (lw - 10, lh - 10)] {
                assert_eq!(at(&server.state, x, y), grid(x, y), "{case}: window at ({x}, {y})");
            }
            server.touch_down(1, 0, mid.0 as f64 * k, mid.1 as f64 * k);
            server.touch_up(0);
            server.touch_down(1, 0, 10.0 * k, 10.0 * k);
            server.touch_up(0);
            assert!(pump(&mut server, |st| at(st, mid.0, mid.1) == grid(mid.0, mid.1)), "{case}: menu stayed after a tap outside");
            assert!(open(&mut server), "{case}: no menu again");
            server.state.dismiss_popups(Some(1));
            assert!(pump(&mut server, |st| at(st, mid.0, mid.1) == grid(mid.0, mid.1)), "{case}: menu stayed after dismiss");
            server.close(1);
            assert!(pump(&mut server, |s| s.windows.is_empty()));
            let got = client.join().unwrap().events;
            let down = format!("touch down 0 {:.1} {:.1}", tap.0, tap.1);
            let configure = format!("popup configure {} {} 160 96", menu.0, menu.1);
            let want = [&down, &configure, "popup touch down 0 80.0 48.0", "popup done", &down, &configure, "popup done"];
            let mut rest = got.iter();
            for w in want {
                assert!(rest.any(|g| g == w), "{case}: no {w:?} in order in {got:?}");
            }
            assert!(!got.iter().any(|g| g.starts_with("touch down 0 10.0")), "{case}: the dismissing tap went through: {got:?}");
        }
    }

    #[test]
    fn shm_formats_to_rgba() {
        // One BGRA pixel per row, stride 8: four bytes of padding after each row.
        let src = [10, 20, 30, 40, 0, 0, 0, 0, 1, 2, 3, 4];
        let cases = [
            (Format::Argb8888, 2, Some(vec![30, 20, 10, 40, 3, 2, 1, 4])),
            (Format::Xrgb8888, 2, Some(vec![30, 20, 10, 255, 3, 2, 1, 255])),
            (Format::Rgb565, 2, None),
            // Rows past the end of the pool.
            (Format::Argb8888, 3, None),
        ];
        for (format, h, want) in cases {
            assert_eq!(to_rgba(&src, 1, h, 8, format), want, "{format:?} h={h}");
        }
    }
}
