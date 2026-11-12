// SPDX-FileCopyrightText: 2025-2026 Lasse Heitgres
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms: see NOTICE

//! Builds and starts planes on a worker thread: opening a hardware decoder and
//! connecting to a loaded compositor can take seconds, and every other op
//! (OP_FEED_OPEN, whose caller gives up after 4 s) waits behind the dispatch.

use std::sync::mpsc::{Sender, channel};
use std::sync::{Arc, Mutex, MutexGuard};

use crate::Plane;

type Job = Box<dyn FnOnce() + Send>;

/// One thread for every build, so a plane torn down while building has let go
/// of the decoder and the display before the next build asks for them.
pub struct Builder {
    jobs: Sender<Job>,
}

impl Builder {
    pub fn new() -> Self {
        let (jobs, queue) = channel::<Job>();
        std::thread::Builder::new()
            .name("plane-build".into())
            .spawn(move || {
                for job in queue {
                    job();
                }
            })
            .expect("spawn plane-build");
        Self { jobs }
    }

    /// A plane that takes ops at once and hands them on, in order, once `build` returns it.
    pub fn build<P: Plane + Send>(
        &self,
        id: u32,
        build: impl FnOnce() -> Option<P> + Send + 'static,
    ) -> Building<P> {
        let state = Arc::new(Mutex::new(State::Building(Vec::new())));
        let shared = state.clone();
        let job: Job = Box::new(move || {
            if matches!(*lock(&shared), State::Gone) {
                return;
            }
            let Some(plane) = build() else {
                eprintln!("livi: create player 0x{id:x} FAILED");
                let mut st = lock(&shared);
                if !matches!(*st, State::Gone) {
                    *st = State::Failed;
                }
                return;
            };
            // Ops that came while building, then those that came while applying them.
            loop {
                let ops = {
                    let mut st = lock(&shared);
                    match &mut *st {
                        State::Building(ops) if !ops.is_empty() => std::mem::take(ops),
                        State::Building(_) => {
                            *st = State::Ready(plane);
                            return;
                        }
                        // Dropped while building: torn down here, off the dispatch thread.
                        _ => return,
                    }
                };
                for op in ops {
                    op.apply(&plane);
                }
            }
        });
        let _ = self.jobs.send(job);
        Building { state }
    }
}

enum Op {
    Start,
    Push(Vec<u8>),
    Flush,
    Gamma([f64; 5]),
}

impl Op {
    fn apply<P: Plane>(self, p: &P) {
        match self {
            Op::Start => p.start(),
            Op::Push(nal) => p.push(&nal),
            Op::Flush => p.flush(),
            Op::Gamma([gamma, contrast, r, g, b]) => p.set_gamma(gamma, contrast, r, g, b),
        }
    }
}

enum State<P> {
    Building(Vec<Op>),
    Ready(P),
    Failed,
    Gone,
}

pub struct Building<P> {
    state: Arc<Mutex<State<P>>>,
}

impl<P: Plane + Send> Building<P> {
    fn op(&self, op: Op) {
        match &mut *lock(&self.state) {
            State::Building(ops) => ops.push(op),
            State::Ready(p) => op.apply(p),
            State::Failed | State::Gone => {}
        }
    }
}

impl<P: Plane + Send> Plane for Building<P> {
    fn start(&self) {
        self.op(Op::Start);
    }

    fn push(&self, nal: &[u8]) {
        self.op(Op::Push(nal.to_vec()));
    }

    fn flush(&self) {
        self.op(Op::Flush);
    }

    fn set_gamma(&self, gamma: f64, contrast: f64, r: f64, g: f64, b: f64) {
        self.op(Op::Gamma([gamma, contrast, r, g, b]));
    }

    fn failed(&self) -> bool {
        match &*lock(&self.state) {
            State::Ready(p) => p.failed(),
            State::Failed => true,
            State::Building(_) | State::Gone => false,
        }
    }
}

impl<P> Drop for Building<P> {
    fn drop(&mut self) {
        // A built plane is torn down here, outside the lock; one still building, by the worker.
        let was = std::mem::replace(&mut *lock(&self.state), State::Gone);
        drop(was);
    }
}

fn lock<T>(m: &Mutex<T>) -> MutexGuard<'_, T> {
    m.lock().unwrap_or_else(|e| e.into_inner())
}
