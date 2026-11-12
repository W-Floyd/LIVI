// SPDX-FileCopyrightText: 2025-2026 Lasse Heitgres
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms: see NOTICE

//! Fed audio, taken where the core's socket is read so nothing on the main
//! loop can hold up the speakers. The ops that must stay in step with the
//! samples (open, active, volume, data, stop) are applied here in arrival
//! order; open and stop also go on to the main loop, which builds and drops
//! the pipelines.

use std::collections::{HashMap, VecDeque};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, MutexGuard};

use livi_output_proto::ops::*;
use livi_output_proto::{Framer, Message, TooLarge};

use crate::{Output, Speaker};

// Samples for an active stream whose pipeline the main loop has not built
// yet; the pipeline's own backlog bound trims what is handed over late.
const PENDING_MAX_BYTES: usize = 1 << 20;

struct Lane<S> {
    active: Arc<AtomicBool>,
    level: Option<f64>,
    out: Option<Arc<Output<S>>>,
    pending: VecDeque<Vec<u8>>,
    pending_bytes: usize,
}

pub(crate) struct Lanes<S> {
    map: Mutex<HashMap<u32, Lane<S>>>,
}

impl<S: Speaker> Lanes<S> {
    pub(crate) fn new() -> Arc<Self> {
        Arc::new(Self {
            map: Mutex::new(HashMap::new()),
        })
    }

    fn map(&self) -> MutexGuard<'_, HashMap<u32, Lane<S>>> {
        self.map.lock().unwrap_or_else(|e| e.into_inner())
    }

    /// Applies what belongs to a lane; true when the main loop needs the op as well.
    pub(crate) fn route(&self, op: u8, id: u32, rest: &[u8]) -> bool {
        match op {
            OP_AUDIO_OPEN => {
                self.map().insert(
                    id,
                    Lane {
                        active: Arc::new(AtomicBool::new(false)),
                        level: None,
                        out: None,
                        pending: VecDeque::new(),
                        pending_bytes: 0,
                    },
                );
                true
            }
            OP_AUDIO_STOP => {
                let gone = self.map().remove(&id);
                drop(gone);
                true
            }
            OP_AUDIO_ACTIVE => {
                if let Some(lane) = self.map().get(&id) {
                    lane.active
                        .store(rest.first().is_some_and(|b| b & 1 != 0), Ordering::Relaxed);
                }
                false
            }
            OP_AUDIO_VOLUME => {
                let Some(level) = rest
                    .get(..8)
                    .map(|b| f64::from_le_bytes(b.try_into().unwrap()))
                else {
                    return false;
                };
                let ms = rest
                    .get(8..12)
                    .map_or(0, |b| u32::from_le_bytes(b.try_into().unwrap()));
                if let Some(lane) = self.map().get_mut(&id) {
                    lane.level = Some(level);
                    if let Some(out) = &lane.out {
                        out.get().set_volume(level, ms.into());
                    }
                }
                false
            }
            OP_AUDIO_DATA => {
                let mut map = self.map();
                let Some(lane) = map.get_mut(&id) else {
                    return false;
                };
                if !lane.active.load(Ordering::Relaxed) {
                    return false;
                }
                match &lane.out {
                    Some(out) => out.get().push_samples(rest),
                    None => {
                        lane.pending_bytes += rest.len();
                        lane.pending.push_back(rest.to_vec());
                        while lane.pending_bytes > PENDING_MAX_BYTES
                            && let Some(old) = lane.pending.pop_front()
                        {
                            lane.pending_bytes -= old.len();
                        }
                    }
                }
                false
            }
            _ => true,
        }
    }

    /// Hands a built pipeline to its lane, with the level and samples that came
    /// meanwhile; None when the stream was stopped before it was built.
    pub(crate) fn install(&self, id: u32, out: &Arc<Output<S>>) -> Option<Arc<AtomicBool>> {
        let mut map = self.map();
        let lane = map.get_mut(&id)?;
        let speaker = out.get();
        if let Some(level) = lane.level {
            speaker.set_volume(level, 0);
        }
        for chunk in lane.pending.drain(..) {
            speaker.push_samples(&chunk);
        }
        lane.pending_bytes = 0;
        lane.out = Some(out.clone());
        Some(lane.active.clone())
    }

    pub(crate) fn forget(&self, id: u32) {
        let gone = self.map().remove(&id);
        drop(gone);
    }

    /// Swaps in a pipeline for a new output at the level last told, so a volume
    /// change racing the swap is not lost. Returns the old one, to be dropped
    /// outside the lock.
    pub(crate) fn replace(&self, id: u32, out: &Output<S>, speaker: S) -> Arc<S> {
        let map = self.map();
        if let Some(level) = map.get(&id).and_then(|l| l.level) {
            speaker.set_volume(level, 0);
        }
        out.replace(speaker)
    }
}

/// Splits the core's byte stream: fed audio is applied on the spot, the rest
/// is returned for the main loop in arrival order.
pub struct Inlet<S> {
    framer: Framer,
    lanes: Arc<Lanes<S>>,
}

impl<S: Speaker> Inlet<S> {
    pub(crate) fn new(lanes: Arc<Lanes<S>>) -> Self {
        Self {
            framer: Framer::new(),
            lanes,
        }
    }

    /// A frame past the bound desyncs the stream: the error ends it.
    pub fn take(&mut self, chunk: &[u8]) -> Result<Vec<Message>, TooLarge> {
        self.framer.push(chunk);
        let mut rest = Vec::new();
        while let Some(m) = self.framer.next_message() {
            let m = m?;
            if self.lanes.route(m.op, m.id, &m.rest) {
                rest.push(m);
            }
        }
        Ok(rest)
    }
}
