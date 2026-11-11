//! livi-shell-test-client [--app-id ID] [--title T] [--size WxH] [--pattern grid|bars]
//!     [--animate FRAMES] [--buffer shm|dmabuf|nv12|i420] [--video] [--events FILE]
//!     [--honour none|fractional|integer]
//!     [--text-input normal|number|email|url|password|...] [--maximize] [--popup]
//! Connects to WAYLAND_DISPLAY and shows a known picture; see test_client.rs.

#[cfg(target_os = "linux")]
fn main() {
    use livi_godot_shell::test_client::{Format, Honour, Opts, Pattern, run};
    let mut opts = Opts {
        app_id: "org.livi.test".into(),
        title: "test".into(),
        width: 640,
        height: 360,
        pattern: Pattern::Grid,
        animate: None,
        dmabuf: false,
        format: Format::Xrgb8888,
        video: false,
        events: None,
        honour: Honour::None,
        text_input: None,
        maximize: false,
        popup: false,
    };
    let mut args = std::env::args().skip(1);
    let usage = || -> ! {
        eprintln!("usage: livi-shell-test-client [--app-id ID] [--title T] [--size WxH] [--pattern grid|bars] [--animate N] [--buffer shm|dmabuf|nv12|i420] [--video] [--events FILE] [--honour none|fractional|integer] [--text-input PURPOSE] [--maximize] [--popup]");
        std::process::exit(2)
    };
    while let Some(a) = args.next() {
        let flag = match a.as_str() {
            "--video" => Some(&mut opts.video),
            "--maximize" => Some(&mut opts.maximize),
            "--popup" => Some(&mut opts.popup),
            _ => None,
        };
        if let Some(f) = flag {
            *f = true;
            continue;
        }
        let v = args.next().unwrap_or_else(|| usage());
        match a.as_str() {
            "--app-id" => opts.app_id = v,
            "--title" => opts.title = v,
            "--size" => {
                let (w, h) = v.split_once('x').unwrap_or_else(|| usage());
                opts.width = w.parse().unwrap_or_else(|_| usage());
                opts.height = h.parse().unwrap_or_else(|_| usage());
            }
            "--pattern" => opts.pattern = Pattern::parse(&v).unwrap_or_else(|| usage()),
            "--animate" => opts.animate = Some(v.parse().unwrap_or_else(|_| usage())),
            "--events" => opts.events = Some(v.into()),
            "--honour" => opts.honour = Honour::parse(&v).unwrap_or_else(|| usage()),
            "--text-input" => opts.text_input = Some(livi_godot_shell::test_client::purpose(&v).unwrap_or_else(|| usage())),
            "--buffer" => {
                (opts.dmabuf, opts.format) = match v.as_str() {
                    "shm" => (false, Format::Xrgb8888),
                    "dmabuf" => (true, Format::Xrgb8888),
                    "nv12" => (true, Format::Nv12),
                    "i420" => (true, Format::I420),
                    _ => usage(),
                }
            }
            _ => usage(),
        }
    }
    let conn = wayland_client::Connection::connect_to_env().unwrap_or_else(|e| {
        eprintln!("livi-shell-test-client: {e}");
        std::process::exit(1)
    });
    if let Err(e) = run(conn, &opts) {
        eprintln!("livi-shell-test-client: {e}");
        std::process::exit(1);
    }
}

#[cfg(not(target_os = "linux"))]
fn main() {
    eprintln!("livi-shell-test-client: Linux only");
}
