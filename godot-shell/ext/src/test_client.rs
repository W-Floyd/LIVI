//! A Wayland client that draws known pictures, standing in for hosted apps and, later, for
//! LIVI's video planes. Used by the compositor's tests and by scenarios (`fixtures.clients`).

use std::fs::File;
use std::io;
use std::os::fd::{AsFd, AsRawFd, FromRawFd, OwnedFd};

use wayland_client::protocol::wl_buffer::{self, WlBuffer};
use wayland_client::protocol::wl_callback::{self, WlCallback};
use wayland_client::protocol::wl_compositor::WlCompositor;
use wayland_client::protocol::wl_registry::{self, WlRegistry};
use wayland_client::protocol::wl_shm::{self, WlShm};
use wayland_client::protocol::wl_shm_pool::WlShmPool;
use wayland_client::protocol::wl_surface::WlSurface;
use wayland_client::protocol::wl_keyboard::{self, WlKeyboard};
use wayland_client::protocol::wl_pointer::{self, WlPointer};
use wayland_client::protocol::wl_seat::{self, WlSeat};
use wayland_client::protocol::wl_touch::{self, WlTouch};
use wayland_client::{Connection, Dispatch, QueueHandle, WEnum, delegate_noop};
use wayland_protocols::wp::linux_dmabuf::zv1::client::zwp_linux_buffer_params_v1::{self, ZwpLinuxBufferParamsV1};
use wayland_protocols::wp::linux_dmabuf::zv1::client::zwp_linux_dmabuf_v1::ZwpLinuxDmabufV1;
use wayland_protocols::xdg::shell::client::xdg_surface::{self, XdgSurface};
use wayland_protocols::xdg::shell::client::xdg_toplevel::{self, XdgToplevel};
use wayland_protocols::xdg::shell::client::xdg_wm_base::{self, XdgWmBase};

#[derive(Debug, Clone, Copy, PartialEq)]
pub enum Pattern {
    /// 64 px checks, dark and light grey, with a red top-left cell to show orientation.
    Grid,
    /// Eight vertical colour bars.
    Bars,
}

impl Pattern {
    pub fn parse(s: &str) -> Option<Pattern> {
        match s {
            "grid" => Some(Pattern::Grid),
            "bars" => Some(Pattern::Bars),
            _ => None,
        }
    }

    /// RGBA at (x, y).
    pub fn pixel(self, x: u32, y: u32, width: u32) -> [u8; 4] {
        match self {
            Pattern::Grid if x < 64 && y < 64 => [220, 40, 40, 255],
            Pattern::Grid if (x / 64 + y / 64) % 2 == 0 => [60, 60, 60, 255],
            Pattern::Grid => [200, 200, 200, 255],
            Pattern::Bars => {
                const BARS: [[u8; 4]; 8] = [
                    [255, 255, 255, 255],
                    [255, 255, 0, 255],
                    [0, 255, 255, 255],
                    [0, 255, 0, 255],
                    [255, 0, 255, 255],
                    [255, 0, 0, 255],
                    [0, 0, 255, 255],
                    [0, 0, 0, 255],
                ];
                BARS[(x * 8 / width.max(1)).min(7) as usize]
            }
        }
    }
}

#[derive(Debug, Clone)]
pub struct Opts {
    pub app_id: String,
    pub title: String,
    pub width: u32,
    pub height: u32,
    pub pattern: Pattern,
    /// Redraw on every frame callback with a white column at `frame % width`; stop after this
    /// many frames. Without it, one frame and then idle until closed.
    pub animate: Option<u32>,
    /// Send linear XRGB dmabufs (from /dev/udmabuf) instead of shm.
    pub dmabuf: bool,
    /// Also append each input event, one line each, to this file as it arrives.
    pub events: Option<std::path::PathBuf>,
}

/// What a run saw: frames drawn, and every input event in the order it came, such as
/// `pointer button 272 pressed` or `touch down 0 320.0 180.0`; positions are surface-local.
#[derive(Debug, Default)]
pub struct Report {
    pub drawn: u32,
    pub events: Vec<String>,
}

#[derive(Default)]
struct App {
    compositor: Option<WlCompositor>,
    shm: Option<WlShm>,
    wm_base: Option<XdgWmBase>,
    dmabuf: Option<ZwpLinuxDmabufV1>,
    configured: bool,
    closed: bool,
    frame_due: bool,
    /// Per buffer: attached and not yet released.
    busy: Vec<bool>,
    seat: Option<WlSeat>,
    has_input: bool,
    events: Vec<String>,
    log: Option<File>,
}

impl App {
    fn note(&mut self, line: String) {
        if let Some(f) = &mut self.log {
            use std::io::Write;
            let _ = writeln!(f, "{line}");
        }
        self.events.push(line);
    }
}

/// Runs until the compositor closes the window or goes away, or the animation ends.
pub fn run(conn: Connection, opts: &Opts) -> io::Result<Report> {
    let err = |e: &dyn std::fmt::Display| io::Error::other(e.to_string());
    let mut queue = conn.new_event_queue();
    let qh = queue.handle();
    conn.display().get_registry(&qh, ());
    let mut app = App::default();
    if let Some(path) = &opts.events {
        app.log = Some(File::create(path)?);
    }
    queue.roundtrip(&mut app).map_err(|e| err(&e))?;
    let (Some(compositor), Some(shm), Some(wm_base)) =
        (app.compositor.clone(), app.shm.clone(), app.wm_base.clone())
    else {
        return Err(io::Error::other("compositor lacks wl_compositor, wl_shm or xdg_wm_base"));
    };

    let surface = compositor.create_surface(&qh, ());
    let xdg = wm_base.get_xdg_surface(&surface, &qh, ());
    let toplevel = xdg.get_toplevel(&qh, ());
    toplevel.set_app_id(opts.app_id.clone());
    toplevel.set_title(opts.title.clone());
    surface.commit();
    while !app.configured {
        queue.blocking_dispatch(&mut app).map_err(|e| err(&e))?;
    }

    let (w, h) = (opts.width, opts.height);
    let stride = w * 4;
    // udmabuf takes whole pages.
    let size = ((stride * h) as usize).next_multiple_of(4096);
    let dmabuf = match (opts.dmabuf, app.dmabuf.clone()) {
        (false, _) => None,
        (true, Some(d)) => Some(d),
        (true, None) => return Err(io::Error::other("compositor lacks zwp_linux_dmabuf_v1")),
    };
    // Three buffers, each reused only once the compositor has released it, as Mesa's clients
    // do: a dmabuf comes back a frame after its successor is shown, so two would halve the rate.
    let mut slots = Vec::new();
    for i in 0..3 {
        let file = memfd(size, dmabuf.is_some())?;
        // SAFETY: a fresh memfd of `size` bytes, mapped shared until the end of this function.
        let map = unsafe {
            libc::mmap(std::ptr::null_mut(), size, libc::PROT_READ | libc::PROT_WRITE, libc::MAP_SHARED, file.as_raw_fd(), 0)
        };
        if map == libc::MAP_FAILED {
            return Err(io::Error::last_os_error());
        }
        let (buffer, pool) = match &dmabuf {
            Some(d) => {
                let fd = udmabuf(&file, size)?;
                let params = d.create_params(&qh, ());
                // LINEAR: modifier 0.
                params.add(fd.as_fd(), 0, 0, stride, 0, 0);
                let buffer = params.create_immed(w as i32, h as i32, XRGB8888, zwp_linux_buffer_params_v1::Flags::empty(), &qh, i);
                params.destroy();
                (buffer, None)
            }
            None => {
                let pool = shm.create_pool(file.as_fd(), size as i32, &qh, ());
                let buffer = pool.create_buffer(0, w as i32, h as i32, stride as i32, wl_shm::Format::Xrgb8888, &qh, i);
                (buffer, Some(pool))
            }
        };
        app.busy.push(false);
        slots.push((buffer, pool, map, file));
    }

    let mut drawn = 0;
    loop {
        let i = loop {
            if let Some(i) = app.busy.iter().position(|b| !b) {
                break Some(i);
            }
            if app.closed || queue.blocking_dispatch(&mut app).is_err() {
                break None;
            }
        };
        let Some(i) = i else { break };
        // SAFETY: slot i's mapping, which the compositor has released.
        let pixels = unsafe { std::slice::from_raw_parts_mut(slots[i].2 as *mut u8, (stride * h) as usize) };
        draw(pixels, opts, drawn);
        app.busy[i] = true;
        surface.attach(Some(&slots[i].0), 0, 0);
        surface.damage_buffer(0, 0, w as i32, h as i32);
        if opts.animate.is_some() {
            surface.frame(&qh, ());
            app.frame_due = false;
        }
        surface.commit();
        drawn += 1;
        if opts.animate.is_some_and(|n| drawn >= n) {
            break;
        }
        while !app.closed && !(opts.animate.is_some() && app.frame_due) {
            if queue.blocking_dispatch(&mut app).is_err() {
                app.closed = true;
            }
        }
        if app.closed {
            break;
        }
    }
    let _ = conn.flush();
    toplevel.destroy();
    xdg.destroy();
    surface.destroy();
    for (buffer, pool, map, _file) in slots {
        buffer.destroy();
        if let Some(p) = pool {
            p.destroy();
        }
        // SAFETY: unmapping a mapping made above; nothing reads it after this.
        unsafe { libc::munmap(map, size) };
    }
    let _ = queue.roundtrip(&mut app);
    Ok(Report { drawn, events: app.events })
}

const XRGB8888: u32 = 0x3432_5258;

/// A dmabuf over the memfd's pages, through /dev/udmabuf: CPU memory any importer can take,
/// which needs no GPU allocator in the client.
fn udmabuf(memfd: &File, size: usize) -> io::Result<OwnedFd> {
    #[repr(C)]
    struct Create {
        memfd: u32,
        flags: u32,
        offset: u64,
        size: u64,
    }
    const UDMABUF_CREATE: libc::c_ulong = 0x4018_7542; // _IOW('u', 0x42, struct udmabuf_create)
    const UDMABUF_FLAGS_CLOEXEC: u32 = 1;
    let dev = std::fs::OpenOptions::new().read(true).write(true).open("/dev/udmabuf")?;
    let create = Create { memfd: memfd.as_raw_fd() as u32, flags: UDMABUF_FLAGS_CLOEXEC, offset: 0, size: size as u64 };
    // SAFETY: the ioctl reads `create` and returns a new fd or -1.
    let fd = unsafe { libc::ioctl(dev.as_raw_fd(), UDMABUF_CREATE as _, &create) };
    if fd < 0 {
        return Err(io::Error::last_os_error());
    }
    // SAFETY: a fresh fd, owned from here on.
    Ok(unsafe { OwnedFd::from_raw_fd(fd) })
}

fn draw(px: &mut [u8], opts: &Opts, frame: u32) {
    let w = opts.width;
    let marker = opts.animate.map(|_| frame % w);
    for (i, out) in px.chunks_exact_mut(4).enumerate() {
        let (x, y) = (i as u32 % w, i as u32 / w);
        let [r, g, b, _] = if marker == Some(x) {
            [255; 4]
        } else {
            opts.pattern.pixel(x, y, w)
        };
        // XRGB8888, little-endian.
        out.copy_from_slice(&[b, g, r, 0xff]);
    }
}

/// `sealed`: udmabuf refuses a memfd that could still shrink.
fn memfd(size: usize, sealed: bool) -> io::Result<File> {
    let flags = libc::MFD_CLOEXEC | if sealed { libc::MFD_ALLOW_SEALING } else { 0 };
    // SAFETY: plain syscall with a static name; the fd is owned by the File from here on.
    let fd = unsafe { libc::memfd_create(c"livi-shell-test".as_ptr(), flags) };
    if fd < 0 {
        return Err(io::Error::last_os_error());
    }
    let file = unsafe { File::from_raw_fd(fd) };
    file.set_len(size as u64)?;
    if sealed && unsafe { libc::fcntl(fd, libc::F_ADD_SEALS, libc::F_SEAL_SHRINK) } < 0 {
        return Err(io::Error::last_os_error());
    }
    Ok(file)
}

impl Dispatch<WlRegistry, ()> for App {
    fn event(
        app: &mut Self,
        registry: &WlRegistry,
        event: wl_registry::Event,
        _: &(),
        _: &Connection,
        qh: &QueueHandle<Self>,
    ) {
        let wl_registry::Event::Global { name, interface, version } = event else {
            return;
        };
        match interface.as_str() {
            "wl_compositor" => app.compositor = Some(registry.bind(name, version.min(4), qh, ())),
            "wl_shm" => app.shm = Some(registry.bind(name, 1, qh, ())),
            "xdg_wm_base" => app.wm_base = Some(registry.bind(name, 1, qh, ())),
            "zwp_linux_dmabuf_v1" => app.dmabuf = Some(registry.bind(name, version.min(3), qh, ())),
            "wl_seat" => app.seat = Some(registry.bind(name, version.min(7), qh, ())),
            _ => {}
        }
    }
}

impl Dispatch<XdgWmBase, ()> for App {
    fn event(_: &mut Self, base: &XdgWmBase, event: xdg_wm_base::Event, _: &(), _: &Connection, _: &QueueHandle<Self>) {
        if let xdg_wm_base::Event::Ping { serial } = event {
            base.pong(serial);
        }
    }
}

impl Dispatch<XdgSurface, ()> for App {
    fn event(app: &mut Self, xdg: &XdgSurface, event: xdg_surface::Event, _: &(), _: &Connection, _: &QueueHandle<Self>) {
        if let xdg_surface::Event::Configure { serial } = event {
            xdg.ack_configure(serial);
            app.configured = true;
        }
    }
}

impl Dispatch<XdgToplevel, ()> for App {
    fn event(app: &mut Self, _: &XdgToplevel, event: xdg_toplevel::Event, _: &(), _: &Connection, _: &QueueHandle<Self>) {
        if let xdg_toplevel::Event::Close = event {
            app.closed = true;
        }
    }
}

impl Dispatch<WlCallback, ()> for App {
    fn event(app: &mut Self, _: &WlCallback, event: wl_callback::Event, _: &(), _: &Connection, _: &QueueHandle<Self>) {
        if let wl_callback::Event::Done { .. } = event {
            app.frame_due = true;
        }
    }
}

impl Dispatch<WlBuffer, usize> for App {
    fn event(app: &mut Self, _: &WlBuffer, event: wl_buffer::Event, i: &usize, _: &Connection, _: &QueueHandle<Self>) {
        if let wl_buffer::Event::Release = event {
            app.busy[*i] = false;
        }
    }
}

delegate_noop!(App: WlCompositor);
delegate_noop!(App: WlShmPool);
delegate_noop!(App: ignore WlShm);
delegate_noop!(App: ignore WlSurface);
delegate_noop!(App: ignore ZwpLinuxDmabufV1);
delegate_noop!(App: ignore ZwpLinuxBufferParamsV1);

impl Dispatch<WlSeat, ()> for App {
    fn event(app: &mut Self, seat: &WlSeat, event: wl_seat::Event, _: &(), _: &Connection, qh: &QueueHandle<Self>) {
        let wl_seat::Event::Capabilities { capabilities: WEnum::Value(caps) } = event else {
            return;
        };
        if app.has_input {
            return;
        }
        app.has_input = true;
        if caps.contains(wl_seat::Capability::Pointer) {
            seat.get_pointer(qh, ());
        }
        if caps.contains(wl_seat::Capability::Keyboard) {
            seat.get_keyboard(qh, ());
        }
        if caps.contains(wl_seat::Capability::Touch) {
            seat.get_touch(qh, ());
        }
    }
}

fn pressed(down: bool) -> &'static str {
    if down { "pressed" } else { "released" }
}

impl Dispatch<WlPointer, ()> for App {
    fn event(app: &mut Self, _: &WlPointer, event: wl_pointer::Event, _: &(), _: &Connection, _: &QueueHandle<Self>) {
        match event {
            wl_pointer::Event::Enter { surface_x, surface_y, .. } => app.note(format!("pointer enter {surface_x:.1} {surface_y:.1}")),
            wl_pointer::Event::Motion { surface_x, surface_y, .. } => app.note(format!("pointer motion {surface_x:.1} {surface_y:.1}")),
            wl_pointer::Event::Leave { .. } => app.note("pointer leave".into()),
            wl_pointer::Event::Button { button, state, .. } => {
                let down = state == WEnum::Value(wl_pointer::ButtonState::Pressed);
                app.note(format!("pointer button {button} {}", pressed(down)));
            }
            _ => {}
        }
    }
}

impl Dispatch<WlTouch, ()> for App {
    fn event(app: &mut Self, _: &WlTouch, event: wl_touch::Event, _: &(), _: &Connection, _: &QueueHandle<Self>) {
        match event {
            wl_touch::Event::Down { id, x, y, .. } => app.note(format!("touch down {id} {x:.1} {y:.1}")),
            wl_touch::Event::Motion { id, x, y, .. } => app.note(format!("touch motion {id} {x:.1} {y:.1}")),
            wl_touch::Event::Up { id, .. } => app.note(format!("touch up {id}")),
            _ => {}
        }
    }
}

impl Dispatch<WlKeyboard, ()> for App {
    fn event(app: &mut Self, _: &WlKeyboard, event: wl_keyboard::Event, _: &(), _: &Connection, _: &QueueHandle<Self>) {
        match event {
            wl_keyboard::Event::Enter { .. } => app.note("keyboard enter".into()),
            wl_keyboard::Event::Leave { .. } => app.note("keyboard leave".into()),
            wl_keyboard::Event::Key { key, state, .. } => {
                let down = state == WEnum::Value(wl_keyboard::KeyState::Pressed);
                app.note(format!("key {key} {}", pressed(down)));
            }
            _ => {}
        }
    }
}
