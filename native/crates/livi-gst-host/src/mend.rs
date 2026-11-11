// SPDX-FileCopyrightText: 2025-2026 Lasse Heitgres
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms: see NOTICE

//! Rebuilds video planes whose pipeline died under a running stream: a pipeline
//! error, or the display server going away (its windows go with it, silently:
//! waylandsink just stops getting frame callbacks).

use std::time::{Duration, Instant};

use super::*;

/// The first retry is immediate; a plane that keeps breaking waits longer each time.
const FIRST_WAIT: Duration = Duration::from_secs(1);
const LONGEST_WAIT: Duration = Duration::from_secs(30);
/// A rebuild that has held this long counts as a fix: the next failure starts over.
const SETTLED: Duration = Duration::from_secs(30);
/// Rebuilds that never held (about 1.5 min of tries): the plane waits for the
/// display to change or a new create instead of retrying forever.
pub(super) const GIVE_UP_AFTER: u32 = 8;

#[derive(Default)]
pub(super) struct Mend {
    tries: u32,
    last: Option<Instant>,
    due: Option<Instant>,
    parked: bool,
}

impl Mend {
    /// False once the plane has been parked.
    fn schedule(&mut self, id: u32, now: Instant) -> bool {
        if self.tries >= GIVE_UP_AFTER {
            eprintln!(
                "[gst-host] plane 0x{id:x} failed {} rebuilds in a row, giving up until the display changes{}",
                self.tries,
                cma_free()
                    .map(|kb| format!(" (CmaFree {kb} kB)"))
                    .unwrap_or_default()
            );
            self.parked = true;
            self.due = None;
            return false;
        }
        self.due = Some(now + wait(self.tries));
        true
    }
}

/// Contiguous memory left for decoders (Linux), worth logging around a rebuild.
fn cma_free() -> Option<u64> {
    let info = std::fs::read_to_string("/proc/meminfo").ok()?;
    info.lines()
        .find_map(|l| l.strip_prefix("CmaFree:"))?
        .trim()
        .trim_end_matches("kB")
        .trim()
        .parse()
        .ok()
}

pub(super) fn wait(tries: u32) -> Duration {
    match tries {
        0 => Duration::ZERO,
        n => FIRST_WAIT
            .saturating_mul(1 << (n - 1).min(16))
            .min(LONGEST_WAIT),
    }
}

impl<O: Outside> Host<O> {
    pub fn mend_planes(&mut self, now: Instant) {
        let display = self.outside.display();
        let moved = display != 0 && self.display != 0 && display != self.display;
        if display != 0 {
            if moved {
                eprintln!("[gst-host] display server restarted, rebuilding video planes");
                for (id, m) in &mut self.mends {
                    m.tries = 0;
                    if std::mem::take(&mut m.parked) {
                        m.schedule(*id, now);
                    }
                }
            }
            self.display = display;
        }

        let broken: Vec<u32> = self
            .planes
            .borrow()
            .iter()
            .filter(|(_, p)| moved || p.failed())
            .map(|(id, _)| *id)
            .collect();
        for id in broken {
            let m = self.mends.entry(id).or_default();
            if m.due.is_some() || m.parked {
                continue;
            }
            if m.last.is_some_and(|t| now.duration_since(t) >= SETTLED) {
                m.tries = 0;
            }
            m.schedule(id, now);
        }

        let due: Vec<u32> = self
            .mends
            .iter()
            .filter(|(_, m)| m.due.is_some_and(|t| t <= now))
            .map(|(id, _)| *id)
            .collect();
        for id in due {
            self.rebuild(id, now);
        }
    }

    fn rebuild(&mut self, id: u32, now: Instant) {
        let Some((codec, data)) = self.plane_specs.get(&id).cloned() else {
            self.mends.remove(&id);
            return;
        };
        let m = self.mends.entry(id).or_default();
        m.tries += 1;
        m.last = Some(now);
        m.due = None;
        let tries = m.tries;
        let held = cma_free();
        // The old pipeline lets go of the decoder and the display before the new one asks.
        self.planes.borrow_mut().remove(&id);
        let cma = match (held, cma_free()) {
            (Some(held), Some(freed)) => {
                format!(", CmaFree {held} kB, {freed} kB once the old pipeline let go")
            }
            _ => String::new(),
        };
        eprintln!("[gst-host] rebuilding plane 0x{id:x} (try {tries}{cma})");
        let Some(plane) = self.outside.create_plane(id, codec, &data) else {
            eprintln!("[gst-host] rebuild of plane 0x{id:x} FAILED");
            if let Some(m) = self.mends.get_mut(&id) {
                m.schedule(id, now);
            }
            return;
        };
        plane.start();
        self.prime(id, &plane, true);
        self.planes.borrow_mut().insert(id, plane);
        self.wire.reply(REPLY_REBUILT, id, &[]);
    }
}
