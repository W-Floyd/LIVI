//! The Wayland server the shell embeds, with no Godot types: Godot's main thread calls
//! `dispatch` once a frame, takes each window's newest frame, and calls `frame_done` after.

use std::io;
use std::os::unix::net::UnixStream;
use std::sync::Arc;
use std::time::Instant;

use smithay::delegate_compositor;
use smithay::delegate_seat;
use smithay::delegate_shm;
use smithay::delegate_xdg_shell;
use smithay::input::{Seat, SeatHandler, SeatState};
use smithay::reexports::wayland_server::backend::{ClientData, ClientId, DisconnectReason};
use smithay::reexports::wayland_server::protocol::wl_buffer::WlBuffer;
use smithay::reexports::wayland_server::protocol::wl_seat::WlSeat;
use smithay::reexports::wayland_server::protocol::wl_shm::Format;
use smithay::reexports::wayland_server::protocol::wl_surface::WlSurface;
use smithay::reexports::wayland_server::{Client, Display, DisplayHandle, ListeningSocket};
use smithay::utils::Serial;
use smithay::wayland::buffer::BufferHandler;
use smithay::wayland::compositor::{
    BufferAssignment, CompositorClientState, CompositorHandler, CompositorState,
    SurfaceAttributes, with_states,
};
use smithay::wayland::shell::xdg::{
    PopupSurface, PositionerState, ToplevelSurface, XdgShellHandler, XdgShellState,
    XdgToplevelSurfaceData,
};
use smithay::wayland::shm::{ShmHandler, ShmState, with_buffer_contents};

/// A client's newest picture, as straight RGBA8 rows with no padding.
#[derive(Debug, Clone, PartialEq)]
pub struct Frame {
    pub width: u32,
    pub height: u32,
    pub rgba: Vec<u8>,
}

pub struct Window {
    pub id: u64,
    toplevel: ToplevelSurface,
    pub app_id: String,
    pub title: String,
    /// Set by each commit with a new buffer; the embedder takes it.
    pub frame: Option<Frame>,
    pub mapped: bool,
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
    pub windows: Vec<Window>,
    pub events: Vec<WindowEvent>,
    next_id: u64,
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
        let seat = seat_state.new_wl_seat(&dh, "seat0");
        let state = State {
            compositor: CompositorState::new::<State>(&dh),
            xdg_shell: XdgShellState::new::<State>(&dh),
            shm: ShmState::new::<State>(&dh, vec![]),
            seat_state,
            _seat: seat,
            windows: Vec::new(),
            events: Vec::new(),
            next_id: 1,
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

    /// Tells every window its frame was shown, so it may draw the next one.
    pub fn frame_done(&mut self) {
        let ms = self.started.elapsed().as_millis() as u32;
        for w in &self.state.windows {
            with_states(w.toplevel.wl_surface(), |states| {
                let mut attrs = states.cached_state.get::<SurfaceAttributes>();
                for cb in attrs.current().frame_callbacks.drain(..) {
                    cb.done(ms);
                }
            });
        }
        let _ = self.display.flush_clients();
    }

    pub fn display_handle(&self) -> DisplayHandle {
        self.display.handle()
    }
}

impl State {
    fn window_of(&mut self, surface: &WlSurface) -> Option<&mut Window> {
        self.windows
            .iter_mut()
            .find(|w| w.toplevel.wl_surface() == surface)
    }
}

/// shm's ARGB and XRGB are little-endian words, so B, G, R, A in memory.
fn to_rgba(src: &[u8], width: u32, height: u32, stride: usize, format: Format) -> Option<Vec<u8>> {
    let opaque = match format {
        Format::Argb8888 => false,
        Format::Xrgb8888 => true,
        _ => return None,
    };
    let row = width as usize * 4;
    if height == 0 || stride < row || src.len() < stride * (height as usize - 1) + row {
        return None;
    }
    let mut out = Vec::with_capacity(row * height as usize);
    for y in 0..height as usize {
        for px in src[y * stride..y * stride + row].chunks_exact(4) {
            out.extend_from_slice(&[px[2], px[1], px[0], if opaque { 255 } else { px[3] }]);
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
        let Some(window) = self.window_of(surface) else {
            return;
        };
        if !window.toplevel.is_initial_configure_sent() {
            window.toplevel.send_configure();
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
                let frame = read_shm(&buffer);
                // Copied out, so the client may reuse it at once.
                buffer.release();
                let Some(frame) = frame else { return };
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
                window.frame = Some(frame);
                if !window.mapped {
                    window.mapped = true;
                    let id = window.id;
                    self.events.push(WindowEvent::Mapped(id));
                }
            }
            Some(BufferAssignment::Removed) if window.mapped => {
                window.mapped = false;
                window.frame = None;
                let id = window.id;
                self.events.push(WindowEvent::Unmapped(id));
            }
            _ => {}
        }
    }
}

impl XdgShellHandler for State {
    fn xdg_shell_state(&mut self) -> &mut XdgShellState {
        &mut self.xdg_shell
    }

    fn new_toplevel(&mut self, toplevel: ToplevelSurface) {
        let id = self.next_id;
        self.next_id += 1;
        self.windows.push(Window {
            id,
            toplevel,
            app_id: String::new(),
            title: String::new(),
            frame: None,
            mapped: false,
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
    fn buffer_destroyed(&mut self, _: &WlBuffer) {}
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

    fn client(server: &mut Server, opts: Opts) -> thread::JoinHandle<u32> {
        let (ours, theirs) = UnixStream::pair().unwrap();
        server.insert_client(ours).unwrap();
        thread::spawn(move || test_client::run(Connection::from_socket(theirs).unwrap(), &opts).unwrap())
    }

    fn opts(pattern: Pattern, animate: Option<u32>) -> Opts {
        Opts {
            app_id: "org.test.app".into(),
            title: "test".into(),
            width: 96,
            height: 64,
            pattern,
            animate,
        }
    }

    #[test]
    fn a_client_buffer_becomes_its_window_frame() {
        let mut server = Server::new().unwrap();
        let _client = client(&mut server, opts(Pattern::Grid, None));
        assert!(pump(&mut server, |s| s.events.contains(&WindowEvent::Mapped(1))));
        let w = &server.state.windows[0];
        assert_eq!((w.app_id.as_str(), w.title.as_str()), ("org.test.app", "test"));
        let f = w.frame.as_ref().unwrap();
        assert_eq!((f.width, f.height, f.rgba.len()), (96, 64, 96 * 64 * 4));
        let at = |x: u32, y: u32| &f.rgba[((y * 96 + x) * 4) as usize..][..4];
        for (x, y) in [(0, 0), (70, 0), (70, 63), (95, 63)] {
            assert_eq!(at(x, y), Pattern::Grid.pixel(x, y, 96), "({x}, {y})");
        }
    }

    #[test]
    fn frame_callbacks_pace_the_client_and_it_unmaps_when_done() {
        let mut server = Server::new().unwrap();
        let client = client(&mut server, opts(Pattern::Bars, Some(5)));
        assert!(pump(&mut server, |s| s.events.contains(&WindowEvent::Unmapped(1))));
        assert_eq!(client.join().unwrap(), 5);
        assert!(server.state.windows.is_empty());
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
