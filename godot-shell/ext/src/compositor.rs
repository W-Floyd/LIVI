//! The Wayland server the shell embeds, with no Godot types: Godot's main thread calls
//! `dispatch` once a frame, takes each window's newest frame, and calls `frame_done` after.

use std::collections::HashMap;
use std::io;
use std::os::unix::net::UnixStream;
use std::sync::Arc;
use std::time::Instant;

use smithay::backend::allocator::dmabuf::Dmabuf;
use smithay::backend::allocator::{Format as DrmFormat, Fourcc, Modifier};
use smithay::delegate_compositor;
use smithay::delegate_dmabuf;
use smithay::delegate_output;
use smithay::delegate_viewporter;
use smithay::output::{Mode, Output, PhysicalProperties, Subpixel};
use smithay::wayland::output::{OutputHandler, OutputManagerState};
use smithay::wayland::viewporter::ViewporterState;
use smithay::delegate_seat;
use smithay::delegate_shm;
use smithay::delegate_xdg_shell;
use smithay::backend::input::{ButtonState, KeyState, TouchSlot};
use smithay::input::keyboard::{FilterResult, KeyboardHandle, Keycode, XkbConfig};
use smithay::input::pointer::{ButtonEvent, MotionEvent as PointerMotion, PointerHandle};
use smithay::input::touch::{DownEvent as TouchDown, MotionEvent as TouchMotion, TouchHandle, UpEvent as TouchUp};
use smithay::input::{Seat, SeatHandler, SeatState};
use smithay::utils::{Logical, Point, SERIAL_COUNTER};
use smithay::reexports::wayland_server::Resource;
use smithay::reexports::wayland_server::backend::{ClientData, ClientId, DisconnectReason, ObjectId};
use smithay::reexports::wayland_server::protocol::wl_buffer::WlBuffer;
use smithay::reexports::wayland_server::protocol::wl_seat::WlSeat;
use smithay::reexports::wayland_server::protocol::wl_shm::Format;
use smithay::reexports::wayland_server::protocol::wl_surface::WlSurface;
use smithay::reexports::wayland_server::{Client, Display, DisplayHandle, ListeningSocket};
use smithay::utils::Serial;
use smithay::wayland::buffer::BufferHandler;
use smithay::wayland::compositor::{
    BufferAssignment, CompositorClientState, CompositorHandler, CompositorState,
    SubsurfaceCachedState, SurfaceAttributes, TraversalAction, get_parent, with_states,
    with_surface_tree_downward,
};
use smithay::wayland::shell::xdg::{
    PopupSurface, PositionerState, ToplevelSurface, XdgShellHandler, XdgShellState,
    XdgToplevelSurfaceData,
};
use smithay::wayland::dmabuf::{
    DmabufFeedbackBuilder, DmabufGlobal, DmabufHandler, DmabufState, ImportNotifier, get_dmabuf,
};
use smithay::wayland::shm::{ShmHandler, ShmState, with_buffer_contents};

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
}

#[derive(Debug, Clone, PartialEq)]
pub enum WindowEvent {
    /// The first buffer arrived; app_id and title are known by then.
    Mapped(u64),
    Unmapped(u64),
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
    _output: Output,
    _output_manager: OutputManagerState,
    _viewporter: ViewporterState,
    pub windows: Vec<Window>,
    pub events: Vec<WindowEvent>,
    next_id: u64,
    buffer_keys: HashMap<ObjectId, u64>,
    /// Each subsurface's latest shm picture. Android's compositor draws a layer per subsurface and
    /// leaves the toplevel itself a placeholder, so a window is these laid over each other.
    layers: HashMap<ObjectId, Frame>,
    next_key: u64,
    /// Keys of dmabufs the client destroyed; the embedder frees what it imported for them.
    pub gone_buffers: Vec<u64>,
    /// Released at the next frame_done, then the one after: one drawn frame later.
    release_next: Vec<WlBuffer>,
    release_now: Vec<WlBuffer>,
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
        // The panel: 1920 x 720, 12.3 inches (about 310 x 116 mm), the one output.
        let output = Output::new(
            "livi-0".into(),
            PhysicalProperties { size: (310, 116).into(), subpixel: Subpixel::Unknown, make: "LIVI".into(), model: "panel".into() },
        );
        let mode = Mode { size: (1920, 720).into(), refresh: 60_000 };
        output.create_global::<State>(&dh);
        output.change_current_state(Some(mode), None, None, Some((0, 0).into()));
        output.set_preferred(mode);
        let state = State {
            _output: output,
            _output_manager: OutputManagerState::new_with_xdg_output::<State>(&dh),
            _viewporter: ViewporterState::new::<State>(&dh),
            pointer,
            keyboard,
            touch,
            compositor: CompositorState::new::<State>(&dh),
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
            next_key: 1,
            gone_buffers: Vec::new(),
            release_next: Vec::new(),
            release_now: Vec::new(),
        };
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
        for b in self.state.release_now.drain(..) {
            b.release();
        }
        self.state.release_now = std::mem::take(&mut self.state.release_next);
        let ms = self.started.elapsed().as_millis() as u32;
        for w in &self.state.windows {
            with_surface_tree_downward(
                w.toplevel.wl_surface(),
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

    fn time(&self) -> u32 {
        self.started.elapsed().as_millis() as u32
    }

    /// The window's surface, its origin placed at (0, 0): every position below is local to it.
    fn focus(&self, window: u64) -> Option<(WlSurface, Point<f64, Logical>)> {
        let w = self.state.windows.iter().find(|w| w.id == window && w.mapped)?;
        Some((w.toplevel.wl_surface().clone(), (0.0, 0.0).into()))
    }

    /// Moves the pointer to (x, y) in the window, or out of every window with `None`.
    pub fn pointer_motion(&mut self, window: Option<u64>, x: f64, y: f64) {
        let focus = window.and_then(|w| self.focus(w));
        let event = PointerMotion { location: (x, y).into(), serial: SERIAL_COUNTER.next_serial(), time: self.time() };
        let pointer = self.state.pointer.clone();
        pointer.motion(&mut self.state, focus, &event);
        pointer.frame(&mut self.state);
    }

    /// `button` is an evdev code: BTN_LEFT is 0x110.
    pub fn pointer_button(&mut self, button: u32, pressed: bool) {
        let state = if pressed { ButtonState::Pressed } else { ButtonState::Released };
        let event = ButtonEvent { button, state, serial: SERIAL_COUNTER.next_serial(), time: self.time() };
        let pointer = self.state.pointer.clone();
        pointer.button(&mut self.state, &event);
        pointer.frame(&mut self.state);
    }

    pub fn touch_down(&mut self, window: u64, slot: u32, x: f64, y: f64) {
        let Some(focus) = self.focus(window) else { return };
        let event = TouchDown {
            slot: TouchSlot::from(Some(slot)),
            location: (x, y).into(),
            serial: SERIAL_COUNTER.next_serial(),
            time: self.time(),
        };
        let touch = self.state.touch.clone();
        touch.down(&mut self.state, Some(focus), &event);
        touch.frame(&mut self.state);
    }

    pub fn touch_motion(&mut self, window: u64, slot: u32, x: f64, y: f64) {
        let focus = self.focus(window);
        let event = TouchMotion { slot: TouchSlot::from(Some(slot)), location: (x, y).into(), time: self.time() };
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
        let focus = window.and_then(|w| self.focus(w)).map(|(s, _)| s);
        let keyboard = self.state.keyboard.clone();
        keyboard.set_focus(&mut self.state, focus, SERIAL_COUNTER.next_serial());
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

    fn commit(&mut self, surface: &WlSurface) {
        let mut root = surface.clone();
        while let Some(parent) = get_parent(&root) {
            root = parent;
        }
        if &root != surface {
            self.commit_layer(&root, surface);
            return;
        }
        let Some(i) = self.windows.iter().position(|w| w.toplevel.wl_surface() == surface) else {
            return;
        };
        if !self.windows[i].toplevel.is_initial_configure_sent() {
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
                let content = if let Ok(dmabuf) = get_dmabuf(&buffer) {
                    let dmabuf = dmabuf.clone();
                    let key = *self.buffer_keys.entry(buffer.id()).or_insert_with(|| {
                        self.next_key += 1;
                        self.next_key
                    });
                    // Read by the GPU until a frame is drawn with its successor.
                    if let Some(old) = self.windows[i].shown.replace(buffer) {
                        self.release_next.push(old);
                    }
                    Content::Dmabuf { key, dmabuf }
                } else {
                    let frame = read_shm(&buffer);
                    // Copied out, so the client may reuse it at once.
                    buffer.release();
                    if let Some(old) = self.windows[i].shown.take() {
                        self.release_next.push(old);
                    }
                    let Some(frame) = frame else { return };
                    self.windows[i].root_frame = Some(frame.clone());
                    Content::Pixels(frame)
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
                window.frame = Some(content);
                if !window.mapped {
                    window.mapped = true;
                    let id = window.id;
                    self.events.push(WindowEvent::Mapped(id));
                }
                self.recomposite(i);
            }
            Some(BufferAssignment::Removed) if self.windows[i].mapped => {
                let window = &mut self.windows[i];
                window.mapped = false;
                window.frame = None;
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
    /// A subsurface of window `root` committed: keep its picture, then lay the window out again.
    fn commit_layer(&mut self, root: &WlSurface, surface: &WlSurface) {
        let Some(i) = self.windows.iter().position(|w| w.toplevel.wl_surface() == root) else {
            return;
        };
        let assignment = with_states(surface, |states| {
            states.cached_state.get::<SurfaceAttributes>().current().buffer.take()
        });
        match assignment {
            Some(BufferAssignment::NewBuffer(buffer)) => {
                if get_dmabuf(&buffer).is_err() {
                    match read_shm(&buffer) {
                        Some(f) => {
                            self.layers.insert(surface.id(), f);
                        }
                        None => {
                            self.layers.remove(&surface.id());
                        }
                    }
                }
                buffer.release();
            }
            Some(BufferAssignment::Removed) => {
                self.layers.remove(&surface.id());
            }
            None => {}
        }
        self.recomposite(i);
    }

    /// Window `i` as its toplevel's own picture with every subsurface's over it, bottom to top; the
    /// window is as big as the toplevel's picture, or where the layers reach if that is a placeholder.
    fn recomposite(&mut self, i: usize) {
        let root = self.windows[i].toplevel.wl_surface().clone();
        let mut placed: Vec<(ObjectId, Point<i32, Logical>)> = Vec::new();
        with_surface_tree_downward(
            &root,
            Point::<i32, Logical>::from((0, 0)),
            |_, states, loc| {
                let sub = states.cached_state.get::<SubsurfaceCachedState>().current().location;
                TraversalAction::DoChildren(*loc + sub)
            },
            |surf, _, loc| placed.push((surf.id(), *loc)),
            |_, _, _| true,
        );
        let root_id = root.id();
        let has_layers = placed.iter().any(|(id, _)| *id != root_id && self.layers.contains_key(id));
        if !has_layers {
            return;
        }
        let base = self.windows[i].root_frame.clone();
        let mut w = base.as_ref().map(|f| f.width).unwrap_or(0);
        let mut h = base.as_ref().map(|f| f.height).unwrap_or(0);
        if w <= 1 && h <= 1 {
            w = 0;
            h = 0;
        }
        for (id, loc) in &placed {
            if let Some(f) = self.layers.get(id) {
                w = w.max((loc.x.max(0) as u32) + f.width);
                h = h.max((loc.y.max(0) as u32) + f.height);
            }
        }
        if w == 0 || h == 0 {
            return;
        }
        let mut canvas = vec![0u8; (w * h * 4) as usize];
        let mut blit = |f: &Frame, x0: i32, y0: i32| {
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
        };
        if let Some(f) = base.as_ref().filter(|f| f.width > 1 || f.height > 1) {
            blit(f, 0, 0);
        }
        for (id, loc) in &placed {
            if *id != root_id {
                if let Some(f) = self.layers.get(id) {
                    blit(f, loc.x, loc.y);
                }
            }
        }
        let window = &mut self.windows[i];
        window.frame = Some(Content::Pixels(Frame { width: w, height: h, rgba: canvas }));
        if !window.mapped {
            window.mapped = true;
            let id = window.id;
            self.events.push(WindowEvent::Mapped(id));
        }
    }
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
        toplevel.with_pending_state(|s| {
            s.size = Some((1920, 720).into());
            s.states.set(XdgState::Fullscreen);
            s.states.set(XdgState::Activated);
        });
        toplevel.send_configure();
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
        });
    }

    fn toplevel_destroyed(&mut self, toplevel: ToplevelSurface) {
        let Some(i) = self.windows.iter().position(|w| w.toplevel == toplevel) else {
            return;
        };
        let w = self.windows.remove(i);
        if w.mapped {
            self.events.push(WindowEvent::Unmapped(w.id));
        }
    }

    fn new_popup(&mut self, _: PopupSurface, _: PositionerState) {}

    fn grab(&mut self, _: PopupSurface, _: WlSeat, _: Serial) {}

    fn reposition_request(&mut self, _: PopupSurface, _: PositionerState, _: u32) {}
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

impl OutputHandler for State {}

#[cfg(test)]
mod tests {
    use std::thread;
    use std::time::Duration;

    use wayland_client::Connection;

    use super::*;
    use crate::test_client::{self, Opts, Pattern};

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
            events: None,
        }
    }

    /// A frame's pixels whichever way they came; a dmabuf is read through a CPU mapping.
    fn pixels(content: &Content) -> Frame {
        match content {
            Content::Pixels(f) => f.clone(),
            Content::Dmabuf { dmabuf, .. } => {
                use smithay::backend::allocator::Buffer;
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
    fn a_client_buffer_becomes_its_window_frame() {
        for dmabuf in [false, true] {
            let mut server = server();
            let _client = client(&mut server, opts(Pattern::Grid, None, dmabuf));
            assert!(pump(&mut server, |s| s.events.contains(&WindowEvent::Mapped(1))), "dmabuf={dmabuf}");
            let w = &server.state.windows[0];
            assert_eq!((w.app_id.as_str(), w.title.as_str()), ("org.test.app", "test"));
            let content = w.frame.as_ref().unwrap();
            assert_eq!(matches!(content, Content::Dmabuf { .. }), dmabuf);
            let f = pixels(content);
            assert_eq!((f.width, f.height, f.rgba.len()), (96, 64, 96 * 64 * 4));
            let at = |x: u32, y: u32| &f.rgba[((y * 96 + x) * 4) as usize..][..4];
            for (x, y) in [(0, 0), (70, 0), (70, 63), (95, 63)] {
                assert_eq!(at(x, y), Pattern::Grid.pixel(x, y, 96), "dmabuf={dmabuf} ({x}, {y})");
            }
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

    /// Each kind of input reaches the window at the position given, in order.
    #[test]
    fn input_reaches_the_window_at_surface_positions() {
        type Send = fn(&mut Server);
        let steps: &[(Send, &[&str])] = &[
            (|s| s.pointer_motion(Some(1), 10.5, 20.0), &["pointer enter 10.5 20.0"]),
            (|s| s.pointer_motion(Some(1), 12.0, 22.5), &["pointer motion 12.0 22.5"]),
            (|s| s.pointer_button(0x110, true), &["pointer button 272 pressed"]),
            (|s| s.pointer_button(0x110, false), &["pointer button 272 released"]),
            (|s| s.pointer_motion(None, 0.0, 0.0), &["pointer leave"]),
            (|s| s.touch_down(1, 0, 30.0, 40.0), &["touch down 0 30.0 40.0"]),
            (|s| s.touch_motion(1, 0, 31.0, 41.5), &["touch motion 0 31.0 41.5"]),
            (|s| s.touch_up(0), &["touch up 0"]),
            (|s| s.keyboard_focus(Some(1)), &["keyboard enter"]),
            (|s| s.key(30, true), &["key 30 pressed"]),
            (|s| s.key(30, false), &["key 30 released"]),
            (|s| s.keyboard_focus(None), &["keyboard leave"]),
        ];
        let mut server = server();
        let client = client(&mut server, opts(Pattern::Grid, None, false));
        assert!(pump(&mut server, |s| s.events.contains(&WindowEvent::Mapped(1))));
        for (send, _) in steps {
            send(&mut server);
            server.dispatch().unwrap();
        }
        server.close(1);
        assert!(pump(&mut server, |s| s.windows.is_empty()));
        let got = client.join().unwrap().events;
        let want: Vec<&str> = steps.iter().flat_map(|(_, w)| w.iter().copied()).collect();
        assert_eq!(got, want);
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
