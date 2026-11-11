// SPDX-FileCopyrightText: 2025-2026 Lasse Heitgres
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms: see NOTICE

//! A plane whose compositor died must free everything once dropped: on the unit a
//! held frame pins the decoder's CMA. Needs a compositor to kill: set
//! LIVI_TEST_COMPOSITOR to a command serving $WAYLAND_DISPLAY (e.g. weston
//! headless), and LIVI_GST_SWDEC=1; skipped otherwise.

use super::*;
use std::process::{Child, Command};
use std::time::{Duration, Instant};

fn socket() -> Option<std::path::PathBuf> {
    let name = std::env::var_os("WAYLAND_DISPLAY")?;
    Some(std::path::PathBuf::from(std::env::var_os("XDG_RUNTIME_DIR")?).join(name))
}

fn compositor(cmd: &str) -> Child {
    let path = socket().unwrap();
    let _ = std::fs::remove_file(&path);
    let child = Command::new("sh").args(["-c", cmd]).spawn().unwrap();
    let until = Instant::now() + Duration::from_secs(10);
    while !path.exists() {
        assert!(Instant::now() < until, "compositor never listened");
        std::thread::sleep(Duration::from_millis(50));
    }
    std::thread::sleep(Duration::from_millis(200));
    child
}

fn encoded(frames: u32) -> Vec<Vec<u8>> {
    let desc = format!(
        "videotestsrc num-buffers={frames} pattern=ball \
         ! video/x-raw,format=I420,width=320,height=240,framerate=30/1 \
         ! x264enc tune=zerolatency key-int-max=10 \
         ! h264parse config-interval=-1 \
         ! video/x-h264,stream-format=byte-stream,alignment=au \
         ! appsink name=out sync=false"
    );
    let pipeline = gst::parse::launch(&desc)
        .unwrap()
        .downcast::<gst::Pipeline>()
        .unwrap();
    let out = pipeline
        .by_name("out")
        .unwrap()
        .downcast::<gst_app::AppSink>()
        .unwrap();
    pipeline.set_state(gst::State::Playing).unwrap();
    let mut aus = Vec::new();
    while let Ok(sample) = out.pull_sample() {
        let buf = sample.buffer().unwrap().map_readable().unwrap();
        aus.push(buf.to_vec());
    }
    pipeline.set_state(gst::State::Null).unwrap();
    aus
}

/// Shared-memory frames (waylandsink's pool) and every other descriptor.
fn open_fds() -> (usize, usize) {
    let mut shm = 0;
    let mut all = 0;
    for e in std::fs::read_dir("/proc/self/fd").unwrap().flatten() {
        all += 1;
        if std::fs::read_link(e.path()).is_ok_and(|t| t.to_string_lossy().contains("memfd:")) {
            shm += 1;
        }
    }
    (shm, all)
}

fn play(player: &Player, aus: &[Vec<u8>]) {
    for au in aus {
        player.push(au);
        std::thread::sleep(Duration::from_millis(33));
    }
}

#[test]
fn a_plane_outliving_its_compositor_frees_its_frames_when_dropped() {
    let Ok(cmd) = std::env::var("LIVI_TEST_COMPOSITOR") else {
        eprintln!("skipped: LIVI_TEST_COMPOSITOR unset");
        return;
    };
    ensure_init();
    let aus = encoded(40);
    let before = open_fds();
    for round in 0..8 {
        let mut shell = compositor(&cmd);
        let player = Player::new(VideoCodec::H264, 0, &[]).unwrap();
        player.start();
        play(&player, &aus[..20]);
        let _ = shell.kill();
        let _ = shell.wait();
        play(&player, &aus[20..]);
        drop(player);
        assert_eq!(open_fds(), before, "round {round}");
    }
}
