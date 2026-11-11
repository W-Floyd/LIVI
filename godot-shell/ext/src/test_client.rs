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
use wayland_client::protocol::wl_subcompositor::WlSubcompositor;
use wayland_client::protocol::wl_subsurface::WlSubsurface;
use wayland_client::protocol::wl_surface::WlSurface;
use wayland_client::protocol::wl_keyboard::{self, WlKeyboard};
use wayland_client::protocol::wl_pointer::{self, WlPointer};
use wayland_client::protocol::wl_seat::{self, WlSeat};
use wayland_client::protocol::wl_touch::{self, WlTouch};
use wayland_client::{Connection, Dispatch, QueueHandle, WEnum, delegate_noop};
use wayland_client::protocol::wl_surface;
use wayland_protocols::wp::fractional_scale::v1::client::wp_fractional_scale_manager_v1::WpFractionalScaleManagerV1;
use wayland_protocols::wp::fractional_scale::v1::client::wp_fractional_scale_v1::{self, WpFractionalScaleV1};
use wayland_protocols::wp::viewporter::client::wp_viewport::WpViewport;
use wayland_protocols::wp::viewporter::client::wp_viewporter::WpViewporter;
use wayland_protocols::wp::linux_dmabuf::zv1::client::zwp_linux_buffer_params_v1::{self, ZwpLinuxBufferParamsV1};
use wayland_protocols::wp::linux_dmabuf::zv1::client::zwp_linux_dmabuf_v1::ZwpLinuxDmabufV1;
use wayland_protocols::xdg::shell::client::xdg_popup::{self, XdgPopup};
use wayland_protocols::xdg::shell::client::xdg_positioner::{self, XdgPositioner};
use wayland_protocols::xdg::shell::client::xdg_surface::{self, XdgSurface};
use wayland_protocols::xdg::shell::client::xdg_toplevel::{self, XdgToplevel};
use wayland_protocols::xdg::shell::client::xdg_wm_base::{self, XdgWmBase};
use wayland_protocols::wp::text_input::zv3::client::zwp_text_input_manager_v3::ZwpTextInputManagerV3;
use wayland_protocols::wp::text_input::zv3::client::zwp_text_input_v3::{self, ContentHint, ContentPurpose, ZwpTextInputV3};

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

/// Which scale the client draws at, of what the compositor prefers.
#[derive(Debug, Clone, Copy, PartialEq, Default)]
pub enum Honour {
    /// Neither: buffers are the size asked for, at scale 1.
    #[default]
    None,
    /// wp_fractional_scale_v1, the buffer sized by it and shown at the logical size by viewporter.
    Fractional,
    /// wl_surface.preferred_buffer_scale, as wl_surface.set_buffer_scale.
    Integer,
}

impl Honour {
    pub fn parse(s: &str) -> Option<Honour> {
        match s {
            "none" => Some(Honour::None),
            "fractional" => Some(Honour::Fractional),
            "integer" => Some(Honour::Integer),
            _ => None,
        }
    }
}

/// Pixel layout of a dmabuf; planar ones are limited-range YUV, BT.601 or BT.709 by size as the
/// compositor picks.
#[derive(Debug, Clone, Copy, PartialEq)]
pub enum Format {
    Xrgb8888,
    Nv12,
    I420,
}

impl Format {
    fn fourcc(self) -> u32 {
        match self {
            Format::Xrgb8888 => XRGB8888,
            Format::Nv12 => 0x3231_564e,
            Format::I420 => 0x3231_5559,
        }
    }

    /// (offset, stride) of each plane, and the buffer's size in bytes, for a `w` x `h` picture.
    pub fn planes(self, w: u32, h: u32) -> (Vec<(u32, u32)>, usize) {
        // Hardware strides are aligned; the compositor must honour them rather than assume w.
        let ys = match self {
            Format::Xrgb8888 => w * 4,
            _ => w.next_multiple_of(64),
        };
        let planes = match self {
            Format::Xrgb8888 => vec![(0, ys)],
            Format::Nv12 => vec![(0, ys), (ys * h, ys)],
            Format::I420 => {
                let cs = ys / 2;
                vec![(0, ys), (ys * h, cs), (ys * h + cs * h.div_ceil(2), cs)]
            }
        };
        let (off, stride) = *planes.last().unwrap();
        let rows = if self == Format::Xrgb8888 { h } else { h.div_ceil(2) };
        // udmabuf takes whole pages.
        (planes, ((off + stride * rows) as usize).next_multiple_of(4096))
    }
}

#[derive(Debug, Clone)]
pub struct Opts {
    pub app_id: String,
    pub title: String,
    /// In surface units: the buffer is this times the scale honoured, the pattern drawn to match.
    /// 0x0: the size of the first configure.
    pub width: u32,
    pub height: u32,
    pub pattern: Pattern,
    /// Redraw on every frame callback with a white column at `frame % width`; stop after this
    /// many frames. Without it, one frame and then idle until closed.
    pub animate: Option<u32>,
    /// Send linear dmabufs (from /dev/udmabuf) instead of shm.
    pub dmabuf: bool,
    /// What the dmabufs hold.
    pub format: Format,
    /// Show the picture as waylandsink does: a subsurface scaled by viewporter (1.5x, or fitted) and centred
    /// under a placeholder toplevel scaled to the 1920x720 panel.
    pub video: bool,
    /// Also append each input event, one line each, to this file as it arrives.
    pub events: Option<std::path::PathBuf>,
    /// Not with `video`. Unless `None`, each new buffer size is an event, `buffer 960x540`.
    pub honour: Honour,
    /// Binds zwp_text_input_v3 with this content purpose: a tap in the window's top half enables
    /// it (the field), one in the bottom half disables it. What arrives is an event: `text
    /// commit hi`, `text delete 1 0`, `text preedit ab`.
    pub text_input: Option<u32>,
    /// Asks to be maximized before the first commit, as Firefox does.
    pub maximize: bool,
    /// A tap on the window opens a grabbing popup menu there, 160x96 units of bars (a dmabuf with
    /// `dmabuf`) in a transparent `MENU_SHADOW` outside its window geometry, below and right of the
    /// tap and slid to fit. Events: `popup configure X Y W H`, `popup done`, and input on it as
    /// `popup touch down 0 X Y` (surface-local, so shadow included).
    pub popup: bool,
}

const POPUP_SIZE: (i32, i32) = (160, 96);
/// Units of transparent shadow on each side of the menu.
pub const MENU_SHADOW: i32 = 8;
const ARGB8888: u32 = 0x3432_5241;

/// zwp_text_input_v3's content purposes by name.
pub fn purpose(name: &str) -> Option<u32> {
    const NAMES: [&str; 14] =
        ["normal", "alpha", "digits", "number", "phone", "url", "email", "name", "password", "pin", "date", "time", "datetime", "terminal"];
    NAMES.iter().position(|n| *n == name).map(|i| i as u32)
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
    subcompositor: Option<WlSubcompositor>,
    viewporter: Option<WpViewporter>,
    fractional: Option<WpFractionalScaleManagerV1>,
    /// The compositor's latest preferences: 120ths, and the whole scale.
    scale_120: u32,
    buffer_scale: i32,
    honour: Honour,
    /// A preference honoured changed since the buffers were made.
    rescale: bool,
    shm: Option<WlShm>,
    wm_base: Option<XdgWmBase>,
    dmabuf: Option<ZwpLinuxDmabufV1>,
    configured: bool,
    /// The latest toplevel configure's size; 0 when the compositor leaves it to the client.
    configure_size: (u32, u32),
    closed: bool,
    frame_due: bool,
    /// Per buffer: attached and not yet released.
    busy: Vec<bool>,
    seat: Option<WlSeat>,
    has_input: bool,
    events: Vec<String>,
    log: Option<File>,
    text_manager: Option<ZwpTextInputManagerV3>,
    text: Option<TextField>,
    /// The window's height in surface units: taps above half of it are on the field.
    height: f64,
    pointer_at: (f64, f64),
    /// Draws at each configure's size.
    follow: bool,
    /// With `Opts::popup`: the toplevel's xdg_surface, and the open popup.
    menu_parent: Option<XdgSurface>,
    menu: Option<Menu>,
    /// The menu's latest configure.
    menu_size: (i32, i32),
    /// The menu is a dmabuf, as the window is.
    menu_dmabuf: bool,
    pointer_on_menu: bool,
}

struct Menu {
    surface: WlSurface,
    xdg: XdgSurface,
    popup: XdgPopup,
    viewport: Option<WpViewport>,
    /// The picture, once configured.
    buffer: Option<(Option<WlShmPool>, WlBuffer, File)>,
}

/// User data telling the popup's xdg_surface from the toplevel's.
struct MenuTag;

/// The client's one text field, on zwp_text_input_v3.
struct TextField {
    input: ZwpTextInputV3,
    purpose: u32,
    entered: bool,
    enabled: bool,
    /// Since the last done.
    commit: Option<String>,
    delete: Option<(u32, u32)>,
    preedit: Option<String>,
}

impl App {
    /// A tap at height `y`: the top half is the field, which takes text; the bottom half not.
    fn tap(&mut self, y: f64) {
        let Some(t) = &mut self.text else { return };
        if !t.entered {
            return;
        }
        let on = y < self.height / 2.0;
        if on {
            t.input.enable();
            let hint = if matches!(t.purpose, 8 | 9) { ContentHint::SensitiveData | ContentHint::HiddenText } else { ContentHint::None };
            t.input.set_content_type(hint, ContentPurpose::try_from(t.purpose).unwrap_or(ContentPurpose::Normal));
            t.input.set_cursor_rectangle(10, 20, 2, 16);
        } else if t.enabled {
            t.input.disable();
        } else {
            return;
        }
        t.input.commit();
        let changed = on != t.enabled;
        t.enabled = on;
        if changed {
            self.note(format!("text {}", if on { "enabled" } else { "disabled" }));
        }
    }
}

impl App {
    /// With `Opts::popup`, a press at (x, y) on the window opens the menu there.
    fn open_menu(&mut self, serial: u32, x: f64, y: f64, qh: &QueueHandle<Self>) {
        let (Some(parent), None, Some(compositor), Some(wm), Some(seat)) =
            (&self.menu_parent, &self.menu, &self.compositor, &self.wm_base, &self.seat)
        else {
            return;
        };
        let surface = compositor.create_surface(qh, ());
        let xdg = wm.get_xdg_surface(&surface, qh, MenuTag);
        let pos = wm.create_positioner(qh, ());
        pos.set_size(POPUP_SIZE.0, POPUP_SIZE.1);
        pos.set_anchor_rect(x as i32, y as i32, 1, 1);
        pos.set_anchor(xdg_positioner::Anchor::BottomRight);
        pos.set_gravity(xdg_positioner::Gravity::BottomRight);
        pos.set_constraint_adjustment(xdg_positioner::ConstraintAdjustment::SlideX | xdg_positioner::ConstraintAdjustment::SlideY);
        let popup = xdg.get_popup(Some(parent), &pos, qh, ());
        pos.destroy();
        popup.grab(seat, serial);
        let viewport = (self.honour == Honour::Fractional).then(|| self.viewporter.as_ref().map(|v| v.get_viewport(&surface, qh, ()))).flatten();
        surface.commit();
        self.menu = Some(Menu { surface, xdg, popup, viewport, buffer: None });
    }

    /// Draws the configured menu: bars, at the scale the window honours.
    fn draw_menu(&mut self, w: i32, h: i32, qh: &QueueHandle<Self>) -> io::Result<()> {
        let k = match self.honour {
            Honour::None => 1.0,
            Honour::Fractional => self.scale_120.max(1) as f64 / 120.0,
            Honour::Integer => self.buffer_scale.max(1) as f64,
        };
        let (Some(menu), Some(shm)) = (&mut self.menu, &self.shm) else { return Ok(()) };
        let dmabuf = self.dmabuf.as_ref().filter(|_| self.menu_dmabuf);
        // A transparent shadow around the menu, outside its window geometry, as toolkits draw.
        let m = MENU_SHADOW;
        let (sw, sh) = (w + 2 * m, h + 2 * m);
        let (bw, bh) = ((sw as f64 * k).round() as i32, (sh as f64 * k).round() as i32);
        let bytes = ((bw * bh * 4) as usize).next_multiple_of(4096);
        let file = memfd(bytes, dmabuf.is_some())?;
        // SAFETY: a fresh memfd of `bytes` bytes, unmapped below.
        let map = unsafe { libc::mmap(std::ptr::null_mut(), bytes, libc::PROT_READ | libc::PROT_WRITE, libc::MAP_SHARED, file.as_raw_fd(), 0) };
        if map == libc::MAP_FAILED {
            return Err(io::Error::last_os_error());
        }
        let px = unsafe { std::slice::from_raw_parts_mut(map as *mut u8, bytes) };
        for (i, out) in px[..(bw * bh * 4) as usize].chunks_exact_mut(4).enumerate() {
            let (x, y) = (((i as i32 % bw) as f64 / k) as i32 - m, ((i as i32 / bw) as f64 / k) as i32 - m);
            if x < 0 || y < 0 || x >= w || y >= h {
                out.copy_from_slice(&[0; 4]);
                continue;
            }
            let [r, g, b, _] = Pattern::Bars.pixel(x as u32, 0, w as u32);
            out.copy_from_slice(&[b, g, r, 0xff]);
        }
        unsafe { libc::munmap(map, bytes) };
        let (pool, buffer) = match dmabuf {
            Some(d) => {
                let fd = udmabuf(&file, bytes)?;
                let params = d.create_params(qh, ());
                params.add(fd.as_fd(), 0, 0, bw as u32 * 4, 0, 0);
                let buffer = params.create_immed(bw, bh, ARGB8888, zwp_linux_buffer_params_v1::Flags::empty(), qh, usize::MAX);
                params.destroy();
                (None, buffer)
            }
            None => {
                let pool = shm.create_pool(file.as_fd(), bytes as i32, qh, ());
                let buffer = pool.create_buffer(0, bw, bh, bw * 4, wl_shm::Format::Argb8888, qh, usize::MAX);
                (Some(pool), buffer)
            }
        };
        menu.xdg.set_window_geometry(m, m, w, h);
        match (&menu.viewport, self.honour) {
            (Some(vp), _) => vp.set_destination(sw, sh),
            (None, Honour::Integer) => menu.surface.set_buffer_scale(k as i32),
            _ => {}
        }
        menu.surface.attach(Some(&buffer), 0, 0);
        menu.surface.damage_buffer(0, 0, bw, bh);
        menu.surface.commit();
        if let Some((p, b, _)) = menu.buffer.replace((pool, buffer, file)) {
            b.destroy();
            if let Some(p) = p {
                p.destroy();
            }
        }
        Ok(())
    }

    fn close_menu(&mut self) {
        let Some(m) = self.menu.take() else { return };
        m.popup.destroy();
        m.xdg.destroy();
        if let Some(vp) = m.viewport {
            vp.destroy();
        }
        m.surface.destroy();
        if let Some((p, b, _)) = m.buffer {
            b.destroy();
            if let Some(p) = p {
                p.destroy();
            }
        }
        self.pointer_on_menu = false;
    }

    fn on_menu(&self, surface: &WlSurface) -> bool {
        self.menu.as_ref().is_some_and(|m| &m.surface == surface)
    }

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
    let mut app = App { honour: opts.honour, height: opts.height as f64, ..App::default() };
    if let Some(path) = &opts.events {
        app.log = Some(File::create(path)?);
    }
    queue.roundtrip(&mut app).map_err(|e| err(&e))?;
    let (Some(compositor), Some(shm), Some(wm_base)) =
        (app.compositor.clone(), app.shm.clone(), app.wm_base.clone())
    else {
        return Err(io::Error::other("compositor lacks wl_compositor, wl_shm or xdg_wm_base"));
    };

    if let Some(purpose) = opts.text_input {
        let (Some(m), Some(seat)) = (app.text_manager.clone(), app.seat.clone()) else {
            return Err(io::Error::other("compositor lacks zwp_text_input_manager_v3 or wl_seat"));
        };
        let input = m.get_text_input(&seat, &qh, ());
        app.text = Some(TextField { input, purpose, entered: false, enabled: false, commit: None, delete: None, preedit: None });
    }

    let surface = compositor.create_surface(&qh, ());
    let xdg = wm_base.get_xdg_surface(&surface, &qh, ());
    let toplevel = xdg.get_toplevel(&qh, ());
    toplevel.set_app_id(opts.app_id.clone());
    toplevel.set_title(opts.title.clone());
    if opts.maximize {
        toplevel.set_maximized();
    }
    if opts.popup {
        app.menu_parent = Some(xdg.clone());
        app.menu_dmabuf = opts.dmabuf;
    }
    // Before the first commit, so the first buffer can be the right size.
    let mut scaled = None;
    if opts.honour == Honour::Fractional {
        let (Some(fs), Some(vp)) = (app.fractional.clone(), app.viewporter.clone()) else {
            return Err(io::Error::other("compositor lacks wp_fractional_scale_manager_v1 or wp_viewporter"));
        };
        scaled = Some((fs.get_fractional_scale(&surface, &qh, ()), vp.get_viewport(&surface, &qh, ())));
    }
    surface.commit();
    while !app.configured {
        queue.blocking_dispatch(&mut app).map_err(|e| err(&e))?;
    }
    let mut sized = opts.clone();
    // Sized by the compositor: each new configure size is drawn at, and is an event.
    app.follow = (opts.width == 0 || opts.height == 0) && !opts.video;
    if opts.width == 0 || opts.height == 0 {
        (sized.width, sized.height) = app.configure_size;
    }
    let opts = &sized;
    app.height = opts.height as f64;

    let dmabuf = match (opts.dmabuf, app.dmabuf.clone()) {
        (false, _) => None,
        (true, Some(d)) => Some(d),
        (true, None) => return Err(io::Error::other("compositor lacks zwp_linux_dmabuf_v1")),
    };
    // Where the picture goes: the toplevel, or in video mode a subsurface scaled by viewporter
    // under a placeholder toplevel, with the toplevel's own picture a transparent pixel.
    let mut keep = Vec::new();
    let target = if opts.video {
        let (w, h) = (opts.width, opts.height);
        let (Some(sub), Some(vp)) = (app.subcompositor.clone(), app.viewporter.clone()) else {
            return Err(io::Error::other("compositor lacks wl_subcompositor or wp_viewporter"));
        };
        let video = compositor.create_surface(&qh, ());
        let subsurface = sub.get_subsurface(&video, &surface, &qh, ());
        // 1.5x, or fitted to the panel as waylandsink does when that would overflow.
        let (dw, dh) = if w * 3 / 2 <= PANEL.0 && h * 3 / 2 <= PANEL.1 {
            (w * 3 / 2, h * 3 / 2)
        } else {
            let s = f64::min(PANEL.0 as f64 / w as f64, PANEL.1 as f64 / h as f64);
            ((w as f64 * s).round() as u32, (h as f64 * s).round() as u32)
        };
        subsurface.set_position((PANEL.0 as i32 - dw as i32) / 2, (PANEL.1 as i32 - dh as i32) / 2);
        subsurface.set_desync();
        let video_vp = vp.get_viewport(&video, &qh, ());
        video_vp.set_destination(dw as i32, dh as i32);
        let root_vp = vp.get_viewport(&surface, &qh, ());
        root_vp.set_destination(PANEL.0 as i32, PANEL.1 as i32);
        let pool_file = memfd(4096, false)?;
        let pool = shm.create_pool(pool_file.as_fd(), 4096, &qh, ());
        let pixel = pool.create_buffer(0, 1, 1, 4, wl_shm::Format::Argb8888, &qh, usize::MAX);
        surface.attach(Some(&pixel), 0, 0);
        surface.commit();
        keep.push((subsurface, video_vp, root_vp, pool, pixel, pool_file));
        video
    } else {
        surface.clone()
    };

    let mut slots: Vec<Slot> = Vec::new();
    let mut size = Size::default();
    let mut drawn = 0;
    loop {
        let (cw, ch) = app.configure_size;
        if app.follow && cw > 0 && ch > 0 && (cw, ch) != (sized.width, sized.height) {
            (sized.width, sized.height) = (cw, ch);
            app.height = ch as f64;
            app.rescale = true;
            app.note(format!("configure {cw}x{ch}"));
        }
        let opts = &sized;
        if slots.is_empty() || app.rescale {
            app.rescale = false;
            size = Size::of(opts, &app);
            free(std::mem::take(&mut slots));
            slots = alloc(opts, &size, &shm, dmabuf.as_ref(), &qh)?;
            app.busy = vec![false; slots.len()];
            match (&scaled, opts.honour) {
                (Some((_, vp)), _) => vp.set_destination(opts.width as i32, opts.height as i32),
                (None, Honour::Integer) => target.set_buffer_scale(size.integer),
                _ => {}
            }
            if opts.honour != Honour::None {
                app.note(format!("buffer {}x{}", size.w, size.h));
            }
        }
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
        let pixels = unsafe { std::slice::from_raw_parts_mut(slots[i].map as *mut u8, size.bytes) };
        if opts.dmabuf && opts.format != Format::Xrgb8888 {
            draw_yuv(pixels, opts, drawn, &size.planes);
        } else {
            draw(&mut pixels[..(size.planes[0].1 * size.h) as usize], opts, &size, drawn);
        }
        app.busy[i] = true;
        target.attach(Some(&slots[i].buffer), 0, 0);
        target.damage_buffer(0, 0, size.w as i32, size.h as i32);
        if opts.animate.is_some() {
            target.frame(&qh, ());
            app.frame_due = false;
        }
        target.commit();
        drawn += 1;
        if opts.animate.is_some_and(|n| drawn >= n) {
            break;
        }
        while !app.closed && !app.rescale && !(opts.animate.is_some() && app.frame_due) {
            if queue.blocking_dispatch(&mut app).is_err() {
                app.closed = true;
            }
        }
        if app.closed {
            break;
        }
    }
    let _ = conn.flush();
    for (subsurface, video_vp, root_vp, pool, pixel, _) in keep {
        pixel.destroy();
        pool.destroy();
        video_vp.destroy();
        root_vp.destroy();
        subsurface.destroy();
    }
    if sized.video {
        target.destroy();
    }
    if let Some((fs, vp)) = scaled {
        fs.destroy();
        vp.destroy();
    }
    app.close_menu();
    toplevel.destroy();
    xdg.destroy();
    surface.destroy();
    free(slots);
    let _ = queue.roundtrip(&mut app);
    Ok(Report { drawn, events: app.events })
}

/// The buffers' size and layout for the scale honoured now.
#[derive(Default)]
struct Size {
    w: u32,
    h: u32,
    /// Buffer pixels per surface unit.
    scale: f64,
    integer: i32,
    planes: Vec<(u32, u32)>,
    bytes: usize,
}

impl Size {
    fn of(opts: &Opts, app: &App) -> Size {
        let integer = app.buffer_scale.max(1);
        let scale = match opts.honour {
            Honour::None => 1.0,
            Honour::Fractional => app.scale_120.max(1) as f64 / 120.0,
            Honour::Integer => integer as f64,
        };
        // As the protocol has it: the logical size times the scale, rounded.
        let (w, h) = ((opts.width as f64 * scale).round() as u32, (opts.height as f64 * scale).round() as u32);
        let format = if opts.dmabuf { opts.format } else { Format::Xrgb8888 };
        let (planes, bytes) = format.planes(w, h);
        Size { w, h, scale, integer, planes, bytes }
    }
}

struct Slot {
    buffer: WlBuffer,
    pool: Option<WlShmPool>,
    map: *mut libc::c_void,
    bytes: usize,
    _file: File,
}

/// Three buffers, each reused only once the compositor has released it, as Mesa's clients
/// do: a dmabuf comes back a frame after its successor is shown, so two would halve the rate.
fn alloc(opts: &Opts, size: &Size, shm: &WlShm, dmabuf: Option<&ZwpLinuxDmabufV1>, qh: &QueueHandle<App>) -> io::Result<Vec<Slot>> {
    let mut slots = Vec::new();
    for i in 0..3 {
        let file = memfd(size.bytes, dmabuf.is_some())?;
        // SAFETY: a fresh memfd of `size.bytes` bytes, mapped shared until `free`.
        let map = unsafe {
            libc::mmap(std::ptr::null_mut(), size.bytes, libc::PROT_READ | libc::PROT_WRITE, libc::MAP_SHARED, file.as_raw_fd(), 0)
        };
        if map == libc::MAP_FAILED {
            return Err(io::Error::last_os_error());
        }
        let (w, h) = (size.w as i32, size.h as i32);
        let (buffer, pool) = match dmabuf {
            Some(d) => {
                let fd = udmabuf(&file, size.bytes)?;
                let params = d.create_params(qh, ());
                // LINEAR: modifier 0. One fd for every plane.
                for (n, &(offset, stride)) in size.planes.iter().enumerate() {
                    params.add(fd.as_fd(), n as u32, offset, stride, 0, 0);
                }
                let buffer = params.create_immed(w, h, opts.format.fourcc(), zwp_linux_buffer_params_v1::Flags::empty(), qh, i);
                params.destroy();
                (buffer, None)
            }
            None => {
                let pool = shm.create_pool(file.as_fd(), size.bytes as i32, qh, ());
                let buffer = pool.create_buffer(0, w, h, size.planes[0].1 as i32, wl_shm::Format::Xrgb8888, qh, i);
                (buffer, Some(pool))
            }
        };
        slots.push(Slot { buffer, pool, map, bytes: size.bytes, _file: file });
    }
    Ok(slots)
}

fn free(slots: Vec<Slot>) {
    for s in slots {
        s.buffer.destroy();
        if let Some(p) = s.pool {
            p.destroy();
        }
        // SAFETY: unmapping a mapping `alloc` made; nothing reads it after this.
        unsafe { libc::munmap(s.map, s.bytes) };
    }
}

const XRGB8888: u32 = 0x3432_5258;
const PANEL: (u32, u32) = (1920, 720);

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

/// The pattern in surface units, so a scaled buffer shows the same picture, sharper.
fn draw(px: &mut [u8], opts: &Opts, size: &Size, frame: u32) {
    let w = opts.width;
    let marker = opts.animate.map(|_| frame % w);
    for (i, out) in px.chunks_exact_mut(4).enumerate() {
        let (bx, by) = (i as u32 % size.w, i as u32 / size.w);
        let (x, y) = ((bx as f64 / size.scale) as u32, (by as f64 / size.scale) as u32);
        let [r, g, b, _] = if marker == Some(x) {
            [255; 4]
        } else {
            opts.pattern.pixel(x, y, w)
        };
        // XRGB8888, little-endian.
        out.copy_from_slice(&[b, g, r, 0xff]);
    }
}

/// A planar YUV picture: luma per pixel, chroma from the top-left pixel of each 2x2 block.
fn draw_yuv(buf: &mut [u8], opts: &Opts, frame: u32, planes: &[(u32, u32)]) {
    let (w, h) = (opts.width, opts.height);
    let marker = opts.animate.map(|_| frame % w);
    let hd = crate::yuv::is_709(w, h);
    let yuv = |x: u32, y: u32| {
        let [r, g, b, _] = if marker == Some(x) { [255; 4] } else { opts.pattern.pixel(x, y, w) };
        crate::yuv::rgb_to_yuv([r, g, b], hd)
    };
    let (yo, ys) = (planes[0].0 as usize, planes[0].1 as usize);
    for y in 0..h {
        for x in 0..w {
            buf[yo + y as usize * ys + x as usize] = yuv(x, y)[0];
        }
    }
    for cy in 0..h.div_ceil(2) {
        for cx in 0..w.div_ceil(2) {
            let [_, u, v] = yuv((cx * 2).min(w - 1), (cy * 2).min(h - 1));
            let (cx, cy) = (cx as usize, cy as usize);
            if planes.len() == 2 {
                let at = planes[1].0 as usize + cy * planes[1].1 as usize + cx * 2;
                buf[at] = u;
                buf[at + 1] = v;
            } else {
                buf[planes[1].0 as usize + cy * planes[1].1 as usize + cx] = u;
                buf[planes[2].0 as usize + cy * planes[2].1 as usize + cx] = v;
            }
        }
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
            // v6 sends preferred_buffer_scale.
            "wl_compositor" => app.compositor = Some(registry.bind(name, version.min(6), qh, ())),
            "wp_fractional_scale_manager_v1" => app.fractional = Some(registry.bind(name, 1, qh, ())),
            "wl_subcompositor" => app.subcompositor = Some(registry.bind(name, 1, qh, ())),
            "wp_viewporter" => app.viewporter = Some(registry.bind(name, 1, qh, ())),
            "wl_shm" => app.shm = Some(registry.bind(name, 1, qh, ())),
            "xdg_wm_base" => app.wm_base = Some(registry.bind(name, 1, qh, ())),
            "zwp_linux_dmabuf_v1" => app.dmabuf = Some(registry.bind(name, version.min(3), qh, ())),
            "wl_seat" => app.seat = Some(registry.bind(name, version.min(7), qh, ())),
            "zwp_text_input_manager_v3" => app.text_manager = Some(registry.bind(name, 1, qh, ())),
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

impl Dispatch<XdgSurface, MenuTag> for App {
    fn event(app: &mut Self, xdg: &XdgSurface, event: xdg_surface::Event, _: &MenuTag, _: &Connection, qh: &QueueHandle<Self>) {
        if let xdg_surface::Event::Configure { serial } = event {
            xdg.ack_configure(serial);
            let size = app.menu_size;
            if let Err(e) = app.draw_menu(size.0, size.1, qh) {
                eprintln!("test client: menu: {e}");
            }
        }
    }
}

impl Dispatch<XdgPopup, ()> for App {
    fn event(app: &mut Self, _: &XdgPopup, event: xdg_popup::Event, _: &(), _: &Connection, _: &QueueHandle<Self>) {
        match event {
            xdg_popup::Event::Configure { x, y, width, height } => {
                app.menu_size = (width, height);
                app.note(format!("popup configure {x} {y} {width} {height}"));
            }
            xdg_popup::Event::PopupDone => {
                app.note("popup done".into());
                app.close_menu();
            }
            _ => {}
        }
    }
}

delegate_noop!(App: XdgPositioner);

impl Dispatch<XdgToplevel, ()> for App {
    fn event(app: &mut Self, _: &XdgToplevel, event: xdg_toplevel::Event, _: &(), _: &Connection, _: &QueueHandle<Self>) {
        match event {
            xdg_toplevel::Event::Close => app.closed = true,
            xdg_toplevel::Event::Configure { width, height, .. } => {
                let size = (width.max(0) as u32, height.max(0) as u32);
                app.rescale |= app.follow && size != app.configure_size && size.0 > 0 && size.1 > 0;
                app.configure_size = size;
            }
            _ => {}
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
            if let Some(b) = app.busy.get_mut(*i) {
                *b = false;
            }
        }
    }
}

delegate_noop!(App: WlCompositor);
delegate_noop!(App: WlSubcompositor);
delegate_noop!(App: WlSubsurface);
delegate_noop!(App: WpViewporter);
delegate_noop!(App: WpViewport);
delegate_noop!(App: WlShmPool);
delegate_noop!(App: ignore WlShm);
delegate_noop!(App: WpFractionalScaleManagerV1);

impl Dispatch<WlSurface, ()> for App {
    fn event(app: &mut Self, _: &WlSurface, event: wl_surface::Event, _: &(), _: &Connection, _: &QueueHandle<Self>) {
        if let wl_surface::Event::PreferredBufferScale { factor } = event
            && factor != app.buffer_scale
        {
            app.buffer_scale = factor;
            app.rescale |= app.honour == Honour::Integer;
        }
    }
}

impl Dispatch<WpFractionalScaleV1, ()> for App {
    fn event(app: &mut Self, _: &WpFractionalScaleV1, event: wp_fractional_scale_v1::Event, _: &(), _: &Connection, _: &QueueHandle<Self>) {
        if let wp_fractional_scale_v1::Event::PreferredScale { scale } = event
            && scale != app.scale_120
        {
            app.scale_120 = scale;
            app.rescale |= app.honour == Honour::Fractional;
        }
    }
}
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
    fn event(app: &mut Self, _: &WlPointer, event: wl_pointer::Event, _: &(), _: &Connection, qh: &QueueHandle<Self>) {
        match event {
            wl_pointer::Event::Enter { surface, surface_x, surface_y, .. } => {
                app.pointer_at = (surface_x, surface_y);
                app.pointer_on_menu = app.on_menu(&surface);
                let on = if app.pointer_on_menu { "popup " } else { "" };
                app.note(format!("{on}pointer enter {surface_x:.1} {surface_y:.1}"))
            }
            wl_pointer::Event::Button { serial, button, state, .. } if app.menu_parent.is_some() => {
                let down = state == WEnum::Value(wl_pointer::ButtonState::Pressed);
                let on = if app.pointer_on_menu { "popup " } else { "" };
                app.note(format!("{on}pointer button {button} {}", pressed(down)));
                if down && !app.pointer_on_menu {
                    app.open_menu(serial, app.pointer_at.0, app.pointer_at.1, qh);
                }
            }
            wl_pointer::Event::Motion { surface_x, surface_y, .. } => {
                app.pointer_at = (surface_x, surface_y);
                app.note(format!("pointer motion {surface_x:.1} {surface_y:.1}"))
            }
            wl_pointer::Event::Leave { .. } => app.note("pointer leave".into()),
            wl_pointer::Event::Button { button, state, .. } => {
                let down = state == WEnum::Value(wl_pointer::ButtonState::Pressed);
                app.note(format!("pointer button {button} {}", pressed(down)));
                if down {
                    app.tap(app.pointer_at.1);
                }
            }
            _ => {}
        }
    }
}

impl Dispatch<WlTouch, ()> for App {
    fn event(app: &mut Self, _: &WlTouch, event: wl_touch::Event, _: &(), _: &Connection, qh: &QueueHandle<Self>) {
        match event {
            wl_touch::Event::Down { serial, surface, id, x, y, .. } => {
                if app.on_menu(&surface) {
                    app.note(format!("popup touch down {id} {x:.1} {y:.1}"));
                } else {
                    app.note(format!("touch down {id} {x:.1} {y:.1}"));
                    app.tap(y);
                    app.open_menu(serial, x, y, qh);
                }
            }
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

delegate_noop!(App: ZwpTextInputManagerV3);

impl Dispatch<ZwpTextInputV3, ()> for App {
    fn event(app: &mut Self, _: &ZwpTextInputV3, event: zwp_text_input_v3::Event, _: &(), _: &Connection, _: &QueueHandle<Self>) {
        use zwp_text_input_v3::Event;
        let Some(t) = &mut app.text else { return };
        match event {
            Event::Enter { .. } => {
                t.entered = true;
                app.note("text enter".into());
            }
            Event::Leave { .. } => {
                // Leaving disables the field, as clients do.
                t.entered = false;
                t.enabled = false;
                app.note("text leave".into());
            }
            Event::CommitString { text } => t.commit = Some(text.unwrap_or_default()),
            Event::DeleteSurroundingText { before_length, after_length } => t.delete = Some((before_length, after_length)),
            Event::PreeditString { text, .. } => t.preedit = Some(text.unwrap_or_default()),
            Event::Done { .. } => {
                // In the protocol's order: delete, then commit, then preedit.
                let lines: Vec<String> = [
                    t.delete.take().map(|(b, a)| format!("text delete {b} {a}")),
                    t.commit.take().map(|s| format!("text commit {s}")),
                    t.preedit.take().map(|s| format!("text preedit {s}")),
                ]
                .into_iter()
                .flatten()
                .collect();
                for l in lines {
                    app.note(l);
                }
            }
            _ => {}
        }
    }
}
