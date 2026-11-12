// SPDX-FileCopyrightText: 2025-2026 Lasse Heitgres
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms: see NOTICE

use core::ffi::{c_char, c_int, c_void};
use std::cell::RefCell;
use std::ffi::CString;
use std::io::{BufRead, ErrorKind, Read, Write};
use std::os::fd::{AsRawFd, FromRawFd};
use std::os::unix::net::UnixStream;
use std::path::Path;
use std::rc::Rc;
use std::sync::atomic::{AtomicI32, AtomicPtr, AtomicU64, Ordering};
use std::sync::{Arc, Mutex, Weak, mpsc};
use std::time::{Duration, Instant};

use glib::{ControlFlow, IOCondition, SourceId};

use crate::gst::Gst;
use crate::{Host, Wire};

const STATS_SECONDS: u32 = 5;
const VISUALIZER_INTERVAL_MS: u64 = 20;
const URL_STATUS_INTERVAL_MS: u64 = 500;
const CHUNK: usize = 65536;
const TICK_MS: u64 = 100;
const STALL_MS: u64 = 500;

struct SocketWire {
    sock: Arc<UnixStream>,
    write: Mutex<()>,
}

impl Wire for SocketWire {
    fn reply(&self, op: u8, id: u32, rest: &[u8]) {
        let _guard = self.write.lock().unwrap_or_else(|e| e.into_inner());
        let mut sock: &UnixStream = &self.sock;
        let _ = sock.write_all(&livi_output_proto::encode_reply(op, id, rest));
    }
}

pub fn run(sock_path: &str, crash_log: &str) {
    glib::set_prgname(Some("livi-video"));
    stamp_stderr();
    livi_video_player::ensure_init();
    arm_crash_handler(crash_log);

    let Ok(sock) = UnixStream::connect(sock_path) else {
        eprintln!("[output] connect to {sock_path} failed");
        std::process::exit(1);
    };
    let _sources = attach(sock, || std::process::exit(0));
    glib::MainLoop::new(None, false).run();
}

pub fn serve(sock_path: &Path) {
    livi_video_player::ensure_init();
    let sock = match UnixStream::connect(sock_path) {
        Ok(sock) => sock,
        Err(e) => {
            eprintln!("[output] connect to {} failed: {e}", sock_path.display());
            return;
        }
    };
    let main = glib::MainLoop::new(None, false);
    let quit = main.clone();
    let sources = attach(sock, move || quit.quit());
    main.run();
    for source in sources {
        source.remove();
    }
}

fn attach(sock: UnixStream, hung_up: impl Fn() + 'static) -> Vec<SourceId> {
    let sock = Arc::new(sock);
    let wire = Arc::new(SocketWire {
        sock: sock.clone(),
        write: Mutex::new(()),
    });
    let host = Rc::new(RefCell::new(Host::new(Gst, wire)));

    // The socket is read on a thread of its own, which plays fed audio there
    // and then; the rest reaches the main loop through `ops` in order, the
    // wake pair only nudging it. None marks the core's hang-up.
    let (ops, queued) = mpsc::channel();
    let (woken, wake) = UnixStream::pair().expect("wake pair");
    let _ = woken.set_nonblocking(true);
    let _ = wake.set_nonblocking(true);
    let mut inlet = host.borrow().inlet();
    std::thread::Builder::new()
        .name("output-in".into())
        .spawn(move || {
            let mut chunk = vec![0u8; CHUNK];
            let mut from: &UnixStream = &sock;
            loop {
                let n = match from.read(&mut chunk) {
                    Ok(0) => break,
                    Ok(n) => n,
                    Err(e) if e.kind() == ErrorKind::Interrupted => continue,
                    Err(_) => break,
                };
                let taken = match inlet.take(&chunk[..n]) {
                    Ok(taken) => taken,
                    Err(e) => {
                        eprintln!("[output] {e}");
                        break;
                    }
                };
                if taken.is_empty() {
                    continue;
                }
                for m in taken {
                    if ops.send(Some(m)).is_err() {
                        return;
                    }
                }
                let _ = (&wake).write(&[1]);
            }
            let _ = ops.send(None);
            let _ = (&wake).write(&[1]);
        })
        .expect("socket reader thread");

    let reading = host.clone();
    let mut sources = vec![glib_unix::unix_fd_add_local(
        woken.as_raw_fd(),
        IOCondition::IN | IOCondition::HUP | IOCondition::ERR,
        move |_, _| {
            let mut drain = [0u8; 256];
            while (&woken).read(&mut drain).is_ok_and(|n| n > 0) {}
            while let Ok(m) = queued.try_recv() {
                match m {
                    Some(m) => reading.borrow_mut().take(m),
                    None => {
                        hung_up();
                        break;
                    }
                }
            }
            ControlFlow::Continue
        },
    )];

    let beat = Arc::new(AtomicU64::new(0));
    let since = Instant::now();
    watch_loop(Arc::downgrade(&beat), since);
    sources.push(glib::timeout_add_local(
        Duration::from_millis(TICK_MS),
        move || {
            beat.store(since.elapsed().as_millis() as u64, Ordering::Relaxed);
            ControlFlow::Continue
        },
    ));

    let visualizer_host = host.clone();
    sources.push(glib::timeout_add_local(
        std::time::Duration::from_millis(VISUALIZER_INTERVAL_MS),
        move || {
            visualizer_host.borrow_mut().pump_visualizer();
            ControlFlow::Continue
        },
    ));

    let status_host = host.clone();
    sources.push(glib::timeout_add_local(
        std::time::Duration::from_millis(URL_STATUS_INTERVAL_MS),
        move || {
            status_host.borrow().pump_url_status();
            status_host.borrow().pump_audio_delays();
            status_host
                .borrow_mut()
                .mend_planes(std::time::Instant::now());
            ControlFlow::Continue
        },
    ));

    sources.push(glib::timeout_add_seconds_local(STATS_SECONDS, move || {
        for line in host.borrow().take_stats() {
            eprintln!("{line}");
        }
        ControlFlow::Continue
    }));
    sources
}

/// Logs main-loop stalls past [`STALL_MS`], each once as it starts and again
/// with its length once the loop runs; ends when the beat's source is removed.
fn watch_loop(beat: Weak<AtomicU64>, since: Instant) {
    let _ = std::thread::Builder::new()
        .name("output-watch".into())
        .spawn(move || {
            let mut stalled_at: Option<u64> = None;
            loop {
                std::thread::sleep(Duration::from_millis(TICK_MS));
                let Some(beat) = beat.upgrade() else { return };
                let last = beat.load(Ordering::Relaxed);
                let gap = (since.elapsed().as_millis() as u64).saturating_sub(last);
                match stalled_at {
                    None if gap > STALL_MS => {
                        stalled_at = Some(last);
                        eprintln!("[output] main loop stalled, {gap} ms so far");
                    }
                    Some(from) if gap <= STALL_MS => {
                        stalled_at = None;
                        eprintln!(
                            "[output] main loop ran again after {} ms",
                            last.saturating_sub(from)
                        );
                    }
                    _ => {}
                }
            }
        });
}

static CRASH_PATH: AtomicPtr<c_char> = AtomicPtr::new(core::ptr::null_mut());
static LOG_FD: AtomicI32 = AtomicI32::new(libc::STDERR_FILENO);

/// Prefixes every stderr line, the C libraries' too, with the wall-clock time,
/// to date it against the journal. Lines already stamped pass as they are.
fn stamp_stderr() {
    let mut ends = [0 as c_int; 2];
    // SAFETY: ends is a writable array of two ints.
    if unsafe { libc::pipe(ends.as_mut_ptr()) } != 0 {
        return;
    }
    let [from, to] = ends;
    // SAFETY: fcntl takes a plain fd and flags.
    let log = unsafe { libc::fcntl(libc::STDERR_FILENO, libc::F_DUPFD_CLOEXEC, 3) };
    // SAFETY: dup2 takes plain fds; to was just opened by pipe.
    if log < 0 || unsafe { libc::dup2(to, libc::STDERR_FILENO) } < 0 {
        // SAFETY: each fd closed here is ours and closed once.
        unsafe {
            libc::close(from);
            libc::close(to);
            if log >= 0 {
                libc::close(log);
            }
        }
        return;
    }
    // SAFETY: to is ours, now duplicated onto stderr, and closed once; from is ours.
    unsafe {
        libc::close(to);
        libc::fcntl(from, libc::F_SETFD, libc::FD_CLOEXEC);
    }
    LOG_FD.store(log, Ordering::Relaxed);
    // SAFETY: from is the pipe's read end, owned by nothing else.
    let lines = std::io::BufReader::new(unsafe { std::fs::File::from_raw_fd(from) });
    let _ = std::thread::Builder::new()
        .name("output-log".into())
        .spawn(move || {
            // SAFETY: log stays open for the process's life; ManuallyDrop never closes it.
            let mut out = std::mem::ManuallyDrop::new(unsafe { std::fs::File::from_raw_fd(log) });
            for line in lines.split(b'\n').map_while(Result::ok) {
                let line = String::from_utf8_lossy(&line);
                let line = if is_stamped(&line) {
                    format!("{line}\n")
                } else {
                    format!("{}\n", livi_video_player::stamped(&line))
                };
                let _ = out.write_all(line.as_bytes());
            }
        });
}

fn is_stamped(line: &str) -> bool {
    let b = line.as_bytes();
    b.len() >= 14 && b[0] == b'[' && b[3] == b':' && b[6] == b':' && b[9] == b'.' && b[13] == b']'
}

const SIG_DFL: usize = 0;

unsafe extern "C" {
    #[cfg(not(target_env = "musl"))]
    fn backtrace(buffer: *mut *mut c_void, size: c_int) -> c_int;
    #[cfg(not(target_env = "musl"))]
    fn backtrace_symbols_fd(buffer: *const *mut c_void, size: c_int, fd: c_int);
    fn signal(sig: c_int, handler: usize) -> usize;
}

// musl has no execinfo: the crash dump is the header alone.
#[cfg(target_env = "musl")]
unsafe fn backtrace(_: *mut *mut c_void, _: c_int) -> c_int {
    0
}
#[cfg(target_env = "musl")]
unsafe fn backtrace_symbols_fd(_: *const *mut c_void, _: c_int, _: c_int) {}

extern "C" fn on_crash(sig: c_int) {
    const HEADER: &[u8] = b"\n=== livi-output CRASH backtrace ===\n";
    let mut frames = [core::ptr::null_mut::<c_void>(); 64];
    // SAFETY: frames is writable for frames.len() pointers.
    let depth = unsafe { backtrace(frames.as_mut_ptr(), frames.len() as c_int) };

    // SAFETY: HEADER is valid for its length and backtrace filled depth entries of frames.
    let dump = |fd: c_int| unsafe {
        let _ = libc::write(fd, HEADER.as_ptr().cast(), HEADER.len());
        backtrace_symbols_fd(frames.as_ptr(), depth, fd);
    };
    dump(LOG_FD.load(Ordering::Relaxed));

    let path = CRASH_PATH.load(Ordering::Relaxed);
    if !path.is_null() {
        // SAFETY: path is the leaked CString from arm_crash_handler, never freed.
        let fd = unsafe {
            libc::open(
                path,
                libc::O_CREAT | libc::O_WRONLY | libc::O_TRUNC,
                0o644 as c_int,
            )
        };
        if fd >= 0 {
            dump(fd);
            // SAFETY: fd was opened above and is closed once.
            unsafe { libc::close(fd) };
        }
    }

    // SAFETY: restores the default action and re-raises, both take plain ints.
    unsafe {
        signal(sig, SIG_DFL);
        libc::raise(sig);
    }
}

fn arm_crash_handler(crash_log: &str) {
    if !crash_log.is_empty()
        && let Ok(path) = CString::new(crash_log)
    {
        CRASH_PATH.store(path.into_raw(), Ordering::Relaxed);
    }
    // SAFETY: on_crash is an extern "C" fn(c_int), the handler type signal expects.
    unsafe {
        signal(libc::SIGSEGV, on_crash as *const () as usize);
        signal(libc::SIGABRT, on_crash as *const () as usize);
    }
}
