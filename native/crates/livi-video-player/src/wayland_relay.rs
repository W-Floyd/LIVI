// SPDX-FileCopyrightText: 2025-2026 Lasse Heitgres
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms: see NOTICE

//! Stands between a waylandsink and the compositor, so that the compositor dying
//! does not strand a frame. waylandsink (1.26-1.28) holds a ref on the frame it
//! renders until its wl_display.sync comes back, and its window never drops that
//! ref when the sync is still out at teardown. Once the compositor is gone the
//! sync never returns: the frame, its buffer pool and the decoder behind it
//! (V4L2 fd, CMA) stay pinned for the life of the process. The relay passes bytes
//! and fds through untouched, notes which syncs are out, and answers them itself
//! when the compositor goes away.

use gstreamer as gst;
use std::collections::HashSet;
use std::io::ErrorKind;
use std::os::fd::{AsRawFd, FromRawFd, OwnedFd, RawFd};
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::PathBuf;
use std::sync::atomic::{AtomicU32, Ordering};
use std::thread::JoinHandle;
use std::time::Duration;

/// libwayland sends at most this many fds per sendmsg.
const MAX_FDS: usize = 28;
/// A side that cannot take a write for this long counts as gone.
const STALL: Duration = Duration::from_secs(2);
const WL_DISPLAY: u32 = 1;
const SYNC: u16 = 0;
const DELETE_ID: u16 = 1;
const DONE: u16 = 0;

pub(crate) struct Relay {
    stop: Option<UnixStream>,
    thread: Option<JoinHandle<()>>,
    path: PathBuf,
}

impl Relay {
    /// Points `sink` at a fresh relay socket in front of $WAYLAND_DISPLAY.
    pub(crate) fn front(sink: &gst::Element) -> Option<Relay> {
        use gstreamer::prelude::*;
        if sink.factory().is_none_or(|f| f.name() != "waylandsink") {
            return None;
        }
        compositor_socket()?;
        static NEXT: AtomicU32 = AtomicU32::new(0);
        let path = PathBuf::from(std::env::var_os("XDG_RUNTIME_DIR")?).join(format!(
            "livi-video-{}-{}",
            std::process::id(),
            NEXT.fetch_add(1, Ordering::Relaxed)
        ));
        let _ = std::fs::remove_file(&path);
        let listener = UnixListener::bind(&path)
            .inspect_err(|e| eprintln!("[gst_video] wayland relay: bind {path:?}: {e}"))
            .ok()?;
        let (stop, stopped) = UnixStream::pair().ok()?;
        let thread = std::thread::Builder::new()
            .name("wl-relay".into())
            .spawn(move || serve(listener, stopped))
            .ok()?;
        sink.set_property("display", path.to_str()?);
        Some(Relay {
            stop: Some(stop),
            thread: Some(thread),
            path,
        })
    }
}

impl Drop for Relay {
    fn drop(&mut self) {
        drop(self.stop.take());
        if let Some(t) = self.thread.take() {
            let _ = t.join();
        }
        let _ = std::fs::remove_file(&self.path);
    }
}

fn compositor_socket() -> Option<PathBuf> {
    let name = PathBuf::from(std::env::var_os("WAYLAND_DISPLAY")?);
    if name.is_absolute() {
        return Some(name);
    }
    Some(PathBuf::from(std::env::var_os("XDG_RUNTIME_DIR")?).join(name))
}

fn readable(fds: &[RawFd], timeout: Option<Duration>) -> Vec<bool> {
    let mut polls: Vec<libc::pollfd> = fds
        .iter()
        .map(|&fd| libc::pollfd {
            fd,
            events: libc::POLLIN,
            revents: 0,
        })
        .collect();
    let ms = timeout.map_or(-1, |t| t.as_millis() as libc::c_int);
    loop {
        let n = unsafe { libc::poll(polls.as_mut_ptr(), polls.len() as _, ms) };
        if n >= 0 || std::io::Error::last_os_error().kind() != ErrorKind::Interrupted {
            break;
        }
    }
    polls.iter().map(|p| p.revents != 0).collect()
}

fn serve(listener: UnixListener, stopped: UnixStream) {
    loop {
        let ready = readable(&[listener.as_raw_fd(), stopped.as_raw_fd()], None);
        if ready[1] {
            return;
        }
        let Ok((client, _)) = listener.accept() else {
            // E.g. out of fds: do not spin.
            std::thread::sleep(Duration::from_millis(100));
            continue;
        };
        let Some(upstream) = compositor_socket().and_then(|p| UnixStream::connect(p).ok()) else {
            // As if the compositor were not there: the sink fails to connect.
            continue;
        };
        if Session::new(client, upstream).run(&stopped) {
            return;
        }
    }
}

/// Splits a byte stream into wayland messages; only headers and the first
/// argument matter here.
#[derive(Default)]
struct Framer {
    carry: Vec<u8>,
    lost: bool,
}

impl Framer {
    fn feed(&mut self, bytes: &[u8], mut each: impl FnMut(u32, u16, Option<u32>)) {
        if self.lost {
            return;
        }
        self.carry.extend_from_slice(bytes);
        let mut at = 0;
        while self.carry.len() - at >= 8 {
            let word =
                |i: usize| u32::from_ne_bytes(self.carry[at + i..at + i + 4].try_into().unwrap());
            let object = word(0);
            let size = (word(4) >> 16) as usize;
            let opcode = (word(4) & 0xffff) as u16;
            if size < 8 || !size.is_multiple_of(4) {
                // Not wayland after all: pass bytes on, stop tracking.
                self.lost = true;
                self.carry.clear();
                return;
            }
            if self.carry.len() - at < size {
                break;
            }
            each(object, opcode, (size >= 12).then(|| word(8)));
            at += size;
        }
        self.carry.drain(..at);
    }
}

struct Session {
    client: UnixStream,
    upstream: Option<UnixStream>,
    /// wl_display.sync callbacks the compositor has not answered.
    syncs: HashSet<u32>,
    requests: Framer,
    events: Framer,
}

impl Session {
    fn new(client: UnixStream, upstream: UnixStream) -> Self {
        Session {
            client,
            upstream: Some(upstream),
            syncs: HashSet::new(),
            requests: Framer::default(),
            events: Framer::default(),
        }
    }

    /// Returns true when told to stop.
    fn run(mut self, stopped: &UnixStream) -> bool {
        let mut buf = vec![0u8; 64 * 1024];
        loop {
            let mut fds = vec![self.client.as_raw_fd(), stopped.as_raw_fd()];
            if let Some(up) = &self.upstream {
                fds.push(up.as_raw_fd());
            }
            let ready = readable(&fds, None);
            if ready[1] {
                return true;
            }
            if ready.get(2) == Some(&true) {
                match self.relay_events(&mut buf) {
                    None => self.compositor_gone(),
                    Some(false) => return false,
                    Some(true) => {}
                }
            }
            if ready[0] && !self.relay_requests(&mut buf) {
                return false;
            }
        }
    }

    fn relay_requests(&mut self, buf: &mut [u8]) -> bool {
        let Some((n, fds)) = receive(&self.client, buf) else {
            return false;
        };
        let syncs = &mut self.syncs;
        let mut fresh = Vec::new();
        self.requests.feed(&buf[..n], |object, opcode, arg| {
            if object == WL_DISPLAY
                && opcode == SYNC
                && let Some(id) = arg
            {
                syncs.insert(id);
                fresh.push(id);
            }
        });
        match &self.upstream {
            Some(up) => {
                if !send(up, &buf[..n], &fds) {
                    self.compositor_gone();
                }
            }
            None => {
                for id in fresh {
                    self.answer(id);
                }
            }
        }
        true
    }

    /// None once the compositor is gone, false once the sink is.
    fn relay_events(&mut self, buf: &mut [u8]) -> Option<bool> {
        let (n, fds) = receive(self.upstream.as_ref()?, buf)?;
        let syncs = &mut self.syncs;
        self.events.feed(&buf[..n], |object, opcode, arg| {
            if opcode == DONE && object != WL_DISPLAY {
                syncs.remove(&object);
            } else if object == WL_DISPLAY
                && opcode == DELETE_ID
                && let Some(id) = arg
            {
                syncs.remove(&id);
            }
        });
        Some(send(&self.client, &buf[..n], &fds))
    }

    /// From here on every sync, pending or new, is answered at once, so the sink
    /// lets go of the frame it was holding for it.
    fn compositor_gone(&mut self) {
        if self.upstream.take().is_none() {
            return;
        }
        for id in std::mem::take(&mut self.syncs) {
            self.answer(id);
        }
    }

    fn answer(&mut self, id: u32) {
        self.syncs.remove(&id);
        let mut done = Vec::with_capacity(12);
        done.extend_from_slice(&id.to_ne_bytes());
        done.extend_from_slice(&((12u32 << 16) | u32::from(DONE)).to_ne_bytes());
        done.extend_from_slice(&0u32.to_ne_bytes());
        let _ = send(&self.client, &done, &[]);
    }
}

/// None once the peer hung up.
fn receive(from: &UnixStream, buf: &mut [u8]) -> Option<(usize, Vec<OwnedFd>)> {
    const SPACE: usize = unsafe { libc::CMSG_SPACE((MAX_FDS * size_of::<RawFd>()) as _) } as usize;
    let mut control = [0u64; SPACE.div_ceil(8)];
    let mut iov = libc::iovec {
        iov_base: buf.as_mut_ptr().cast(),
        iov_len: buf.len(),
    };
    let mut msg: libc::msghdr = unsafe { std::mem::zeroed() };
    msg.msg_iov = &mut iov;
    msg.msg_iovlen = 1;
    msg.msg_control = control.as_mut_ptr().cast();
    msg.msg_controllen = SPACE as _;
    let n = loop {
        let n = unsafe {
            libc::recvmsg(
                from.as_raw_fd(),
                &mut msg,
                libc::MSG_CMSG_CLOEXEC | libc::MSG_DONTWAIT,
            )
        };
        if n >= 0 {
            break n as usize;
        }
        match std::io::Error::last_os_error().kind() {
            ErrorKind::Interrupted => continue,
            ErrorKind::WouldBlock => return Some((0, Vec::new())),
            _ => return None,
        }
    };
    let mut fds = Vec::new();
    let mut cmsg = unsafe { libc::CMSG_FIRSTHDR(&msg) };
    while !cmsg.is_null() {
        let c = unsafe { &*cmsg };
        if c.cmsg_level == libc::SOL_SOCKET && c.cmsg_type == libc::SCM_RIGHTS {
            let header = unsafe { libc::CMSG_LEN(0) } as usize;
            let count = (c.cmsg_len as usize - header) / size_of::<RawFd>();
            let data = unsafe { libc::CMSG_DATA(cmsg) }.cast::<RawFd>();
            for i in 0..count {
                let fd = unsafe { std::ptr::read_unaligned(data.add(i)) };
                fds.push(unsafe { OwnedFd::from_raw_fd(fd) });
            }
        }
        cmsg = unsafe { libc::CMSG_NXTHDR(&msg, cmsg) };
    }
    (n > 0 || !fds.is_empty()).then_some((n, fds))
}

/// The fds ride with the first byte. False once the peer is gone or stalled.
fn send(to: &UnixStream, mut bytes: &[u8], fds: &[OwnedFd]) -> bool {
    const SPACE: usize = unsafe { libc::CMSG_SPACE((MAX_FDS * size_of::<RawFd>()) as _) } as usize;
    let mut control = [0u64; SPACE.div_ceil(8)];
    let mut fds = &fds[..fds.len().min(MAX_FDS)];
    while !bytes.is_empty() || !fds.is_empty() {
        let mut iov = libc::iovec {
            iov_base: bytes.as_ptr().cast_mut().cast(),
            iov_len: bytes.len(),
        };
        let mut msg: libc::msghdr = unsafe { std::mem::zeroed() };
        msg.msg_iov = &mut iov;
        msg.msg_iovlen = 1;
        if !fds.is_empty() {
            let len = fds.len() * size_of::<RawFd>();
            msg.msg_control = control.as_mut_ptr().cast();
            msg.msg_controllen = unsafe { libc::CMSG_SPACE(len as _) } as _;
            unsafe {
                let c = libc::CMSG_FIRSTHDR(&msg);
                (*c).cmsg_level = libc::SOL_SOCKET;
                (*c).cmsg_type = libc::SCM_RIGHTS;
                (*c).cmsg_len = libc::CMSG_LEN(len as _) as _;
                let data = libc::CMSG_DATA(c).cast::<RawFd>();
                for (i, fd) in fds.iter().enumerate() {
                    std::ptr::write_unaligned(data.add(i), fd.as_raw_fd());
                }
            }
        }
        let n = unsafe {
            libc::sendmsg(
                to.as_raw_fd(),
                &msg,
                libc::MSG_NOSIGNAL | libc::MSG_DONTWAIT,
            )
        };
        if n < 0 {
            match std::io::Error::last_os_error().kind() {
                ErrorKind::Interrupted => continue,
                ErrorKind::WouldBlock => {
                    if !writable(to.as_raw_fd()) {
                        return false;
                    }
                    continue;
                }
                _ => return false,
            }
        }
        fds = &[];
        bytes = &bytes[n as usize..];
    }
    true
}

fn writable(fd: RawFd) -> bool {
    let mut p = libc::pollfd {
        fd,
        events: libc::POLLOUT,
        revents: 0,
    };
    let n = unsafe { libc::poll(&mut p, 1, STALL.as_millis() as _) };
    n > 0 && p.revents & libc::POLLOUT != 0
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::{Read, Write};

    fn message(object: u32, opcode: u16, args: &[u32]) -> Vec<u8> {
        let size = 8 + 4 * args.len() as u32;
        let mut m = object.to_ne_bytes().to_vec();
        m.extend_from_slice(&((size << 16) | u32::from(opcode)).to_ne_bytes());
        for a in args {
            m.extend_from_slice(&a.to_ne_bytes());
        }
        m
    }

    #[test]
    fn the_framer_finds_every_message_however_the_stream_is_cut() {
        let stream = [
            message(1, 0, &[7]),
            message(3, 2, &[]),
            message(5, 1, &[1, 2, 3]),
            message(1, 1, &[7]),
        ]
        .concat();
        let want = vec![
            (1, 0, Some(7)),
            (3, 2, None),
            (5, 1, Some(1)),
            (1, 1, Some(7)),
        ];
        for cut in 1..stream.len() {
            let mut f = Framer::default();
            let mut got = Vec::new();
            for chunk in stream.chunks(cut) {
                f.feed(chunk, |o, op, a| got.push((o, op, a)));
            }
            assert_eq!(got, want, "chunks of {cut}");
            assert!(f.carry.is_empty(), "chunks of {cut}");
        }
    }

    #[test]
    fn syncs_out_when_the_compositor_dies_are_answered_and_later_ones_at_once() {
        let (client, sink_end) = UnixStream::pair().unwrap();
        let (upstream, compositor) = UnixStream::pair().unwrap();
        let (stop, stopped) = UnixStream::pair().unwrap();
        let session = std::thread::spawn(move || Session::new(sink_end, upstream).run(&stopped));
        let read_exact = |s: &UnixStream, n: usize| {
            let mut out = vec![0; n];
            (&*s).read_exact(&mut out).unwrap();
            out
        };
        // Two syncs out, the compositor answers the first.
        (&client).write_all(&message(1, 0, &[10])).unwrap();
        (&client).write_all(&message(1, 0, &[11])).unwrap();
        assert_eq!(
            read_exact(&compositor, 24),
            [message(1, 0, &[10]), message(1, 0, &[11])].concat()
        );
        (&compositor).write_all(&message(10, 0, &[5])).unwrap();
        assert_eq!(read_exact(&client, 12), message(10, 0, &[5]));
        drop(compositor);
        assert_eq!(read_exact(&client, 12), message(11, 0, &[0]));
        (&client).write_all(&message(1, 0, &[12])).unwrap();
        assert_eq!(read_exact(&client, 12), message(12, 0, &[0]));
        drop(stop);
        assert!(session.join().unwrap());
    }

    #[test]
    fn fds_ride_through_with_their_bytes() {
        let (client, sink_end) = UnixStream::pair().unwrap();
        let (upstream, compositor) = UnixStream::pair().unwrap();
        let (_stop, stopped) = UnixStream::pair().unwrap();
        std::thread::spawn(move || Session::new(sink_end, upstream).run(&stopped));
        let (a, mut b) = UnixStream::pair().unwrap();
        let bytes = message(4, 2, &[0]);
        assert!(send(&client, &bytes, &[OwnedFd::from(a)]));
        let mut buf = [0u8; 64];
        assert!(readable(&[compositor.as_raw_fd()], Some(STALL))[0]);
        let (n, fds) = receive(&compositor, &mut buf).unwrap();
        assert_eq!(&buf[..n], &bytes[..]);
        assert_eq!(fds.len(), 1);
        UnixStream::from(fds.into_iter().next().unwrap())
            .write_all(b"x")
            .unwrap();
        let mut one = [0u8];
        b.read_exact(&mut one).unwrap();
        assert_eq!(&one, b"x");
    }
}
