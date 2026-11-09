//! A Wayland client that draws known pictures, standing in for hosted apps and, later, for
//! LIVI's video planes. Used by the compositor's tests and by scenarios (`fixtures.clients`).

use std::fs::File;
use std::io;
use std::os::fd::{AsFd, FromRawFd};

use wayland_client::protocol::wl_buffer::WlBuffer;
use wayland_client::protocol::wl_callback::{self, WlCallback};
use wayland_client::protocol::wl_compositor::WlCompositor;
use wayland_client::protocol::wl_registry::{self, WlRegistry};
use wayland_client::protocol::wl_shm::{self, WlShm};
use wayland_client::protocol::wl_shm_pool::WlShmPool;
use wayland_client::protocol::wl_surface::WlSurface;
use wayland_client::{Connection, Dispatch, QueueHandle, delegate_noop};
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
}

#[derive(Default)]
struct App {
    compositor: Option<WlCompositor>,
    shm: Option<WlShm>,
    wm_base: Option<XdgWmBase>,
    configured: bool,
    closed: bool,
    frame_due: bool,
}

/// Runs until the compositor closes the window or goes away, or the animation ends. Returns
/// the number of frames drawn.
pub fn run(conn: Connection, opts: &Opts) -> io::Result<u32> {
    let err = |e: &dyn std::fmt::Display| io::Error::other(e.to_string());
    let mut queue = conn.new_event_queue();
    let qh = queue.handle();
    conn.display().get_registry(&qh, ());
    let mut app = App::default();
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
    let size = (w * h * 4) as usize;
    let file = memfd(size)?;
    // SAFETY: a fresh memfd of `size` bytes, mapped shared for the pool's lifetime.
    let map = unsafe {
        libc::mmap(
            std::ptr::null_mut(),
            size,
            libc::PROT_READ | libc::PROT_WRITE,
            libc::MAP_SHARED,
            std::os::fd::AsRawFd::as_raw_fd(&file),
            0,
        )
    };
    if map == libc::MAP_FAILED {
        return Err(io::Error::last_os_error());
    }
    // SAFETY: the mapping above, which outlives this function's use of it.
    let pixels = unsafe { std::slice::from_raw_parts_mut(map as *mut u8, size) };
    let pool = shm.create_pool(file.as_fd(), size as i32, &qh, ());
    let buffer = pool.create_buffer(0, w as i32, h as i32, (w * 4) as i32, wl_shm::Format::Xrgb8888, &qh, ());

    let mut drawn = 0;
    loop {
        draw(pixels, opts, drawn);
        surface.attach(Some(&buffer), 0, 0);
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
    buffer.destroy();
    pool.destroy();
    let _ = queue.roundtrip(&mut app);
    // SAFETY: unmapping the mapping made above; `pixels` is not used after this.
    unsafe { libc::munmap(map, size) };
    Ok(drawn)
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

fn memfd(size: usize) -> io::Result<File> {
    // SAFETY: plain syscall with a static name; the fd is owned by the File from here on.
    let fd = unsafe { libc::memfd_create(c"livi-shell-test".as_ptr(), libc::MFD_CLOEXEC) };
    if fd < 0 {
        return Err(io::Error::last_os_error());
    }
    let file = unsafe { File::from_raw_fd(fd) };
    file.set_len(size as u64)?;
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

delegate_noop!(App: WlCompositor);
delegate_noop!(App: WlShmPool);
delegate_noop!(App: ignore WlShm);
delegate_noop!(App: ignore WlBuffer);
delegate_noop!(App: ignore WlSurface);
