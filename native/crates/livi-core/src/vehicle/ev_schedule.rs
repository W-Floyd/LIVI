// SPDX-FileCopyrightText: 2025-2026 Lasse Heitgres
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms: see NOTICE

//! The user's edits of the car's EV schedules. LIVI only states the edit at GET /navigation; the
//! car integration sends it and reports back in telemetry (`evScheduleWrite`), which ends it.

use std::sync::Arc;
use std::time::Duration;

use livi_core_proto::state::{EvSchedule, EvScheduleEdit, EvScheduleOutcome, EvScheduleRequest};
use serde_json::{Map, Value};

use crate::server::Core;
use crate::vehicle::precondition::now_s;

/// How long an edit waits for the car integration's word: micom-livi gives each of an edit's
/// two writes 10 s to be reported back, and a car link gone mid-edit must not block the next.
const ANSWER_WITHIN: u64 = 30;

/// The request for `set` made now, or why none can be made.
pub fn request(
    s: &EvSchedule,
    telemetry: &Map<String, Value>,
    set: EvScheduleEdit,
    now: u64,
) -> Result<EvScheduleRequest, String> {
    if telemetry.get("evScheduleWrites") != Some(&Value::Bool(true)) {
        return Err("the car link does not set the schedules".into());
    }
    if let Some(why) = not_parked(telemetry) {
        return Err(why);
    }
    if s.request.is_some() {
        return Err("an edit is still on its way to the car".into());
    }
    set.check()?;
    let id = s.last.as_ref().map_or(0, |l| l.id) + 1;
    Ok(EvScheduleRequest { id, at: now, set })
}

/// Out of Park by the car's own lockout or its gear.
fn not_parked(telemetry: &Map<String, Value>) -> Option<String> {
    if telemetry.get("drivingRegulation") == Some(&Value::Bool(true)) {
        return Some("the car is not parked".into());
    }
    match telemetry.get("gear").and_then(Value::as_str) {
        Some(g) if g != "P" => Some(format!("the car is in {g}, not parked")),
        _ => None,
    }
}

/// The request's end, if the car integration's report or the time says so.
fn ended(req: &EvScheduleRequest, report: Option<&Value>, now: u64) -> Option<EvScheduleOutcome> {
    let report = report.filter(|r| r["id"].as_u64() == Some(req.id));
    let why = report
        .and_then(|r| r["why"].as_str())
        .unwrap_or_default()
        .to_string();
    match report.and_then(|r| r["state"].as_str()) {
        Some("confirmed") => Some(EvScheduleOutcome {
            id: req.id,
            ok: true,
            why,
        }),
        Some("failed") => Some(EvScheduleOutcome {
            id: req.id,
            ok: false,
            why,
        }),
        _ if now >= req.at + ANSWER_WITHIN => Some(EvScheduleOutcome {
            id: req.id,
            ok: false,
            why: "the car link did not answer".into(),
        }),
        _ => None,
    }
}

pub async fn follow(core: Arc<Core>) {
    let mut state = core.hub.watch();
    loop {
        let at = {
            let s = state.borrow_and_update();
            s.ev_schedule.request.as_ref().map(|r| r.at)
        };
        if at.is_some() {
            core.hub.update(|s| {
                let Some(req) = &s.ev_schedule.request else {
                    return;
                };
                if let Some(out) = ended(req, s.telemetry.get("evScheduleWrite"), now_s()) {
                    match out.ok {
                        true => println!("[core] ev schedule edit {} confirmed", out.id),
                        false => println!("[core] ev schedule edit {} failed: {}", out.id, out.why),
                    }
                    s.ev_schedule = EvSchedule {
                        request: None,
                        last: Some(out),
                    };
                }
            });
        }
        let wait = at.map(|a| Duration::from_secs((a + ANSWER_WITHIN).saturating_sub(now_s())));
        tokio::select! {
            changed = state.changed() => {
                if changed.is_err() {
                    return;
                }
            }
            _ = tokio::time::sleep(wait.unwrap_or(Duration::MAX)), if wait.is_some() => {}
        }
    }
}

#[cfg(test)]
mod tests {
    use livi_core_proto::state::DepartureEdit;
    use serde_json::json;

    use super::*;

    fn tel(v: Value) -> Map<String, Value> {
        v.as_object().cloned().unwrap_or_default()
    }

    #[test]
    fn an_edit_goes_only_where_the_car_link_takes_it_parked_and_valid() {
        let on = EvScheduleEdit {
            climate: Some(true),
            ..Default::default()
        };
        let pending = EvSchedule {
            request: Some(EvScheduleRequest {
                id: 4,
                at: 1,
                set: on.clone(),
            }),
            last: None,
        };
        let after = EvSchedule {
            request: None,
            last: Some(EvScheduleOutcome {
                id: 4,
                ok: false,
                why: String::new(),
            }),
        };
        let writes = json!({ "evScheduleWrites": true, "drivingRegulation": false, "gear": "P" });
        let minute = EvScheduleEdit {
            departure1: Some(DepartureEdit {
                minute: Some(15),
                ..Default::default()
            }),
            ..Default::default()
        };
        let mode = EvScheduleEdit {
            charging_mode: Some("code 1".into()),
            ..Default::default()
        };
        for (s, t, set, want) in [
            (&EvSchedule::default(), writes.clone(), on.clone(), Ok(1)),
            (&after, writes.clone(), on.clone(), Ok(5)),
            (
                &EvSchedule::default(),
                json!({}),
                on.clone(),
                Err("does not set"),
            ),
            (
                &EvSchedule::default(),
                json!({ "evScheduleWrites": false }),
                on.clone(),
                Err("does not set"),
            ),
            (
                &EvSchedule::default(),
                json!({ "evScheduleWrites": true, "drivingRegulation": true }),
                on.clone(),
                Err("not parked"),
            ),
            (
                &EvSchedule::default(),
                json!({ "evScheduleWrites": true, "gear": "D" }),
                on.clone(),
                Err("in D"),
            ),
            (
                &pending,
                writes.clone(),
                on.clone(),
                Err("still on its way"),
            ),
            (
                &EvSchedule::default(),
                writes.clone(),
                minute,
                Err("minute 15"),
            ),
            (
                &EvSchedule::default(),
                writes.clone(),
                mode,
                Err("charging mode code 1"),
            ),
            (
                &EvSchedule::default(),
                writes.clone(),
                EvScheduleEdit::default(),
                Err("nothing to change"),
            ),
        ] {
            let got = request(s, &tel(t.clone()), set.clone(), 100);
            match (&got, want) {
                (Ok(r), Ok(id)) => assert_eq!((r.id, r.at, &r.set), (id, 100, &set), "{t}"),
                (Err(e), Err(w)) => assert!(e.contains(w), "{t}: {e}, want {w}"),
                _ => panic!("{t} {set:?}: {got:?}, want {want:?}"),
            }
        }
    }

    #[test]
    fn an_edit_ends_with_the_car_links_word_or_its_silence() {
        let req = EvScheduleRequest {
            id: 2,
            at: 100,
            set: EvScheduleEdit::default(),
        };
        let out = |ok: bool, why: &str| {
            Some(EvScheduleOutcome {
                id: 2,
                ok,
                why: why.into(),
            })
        };
        for (report, now, want) in [
            (None, 101, None),
            (Some(json!({ "id": 2, "state": "sending" })), 101, None),
            (
                Some(json!({ "id": 2, "state": "confirmed" })),
                101,
                out(true, ""),
            ),
            (
                Some(json!({ "id": 2, "state": "failed", "why": "the car is in D, not parked" })),
                101,
                out(false, "the car is in D, not parked"),
            ),
            (Some(json!({ "id": 1, "state": "confirmed" })), 101, None),
            (Some(json!({ "id": 1, "state": "confirmed" })), 129, None),
            (
                Some(json!({ "id": 1, "state": "confirmed" })),
                130,
                out(false, "the car link did not answer"),
            ),
            (
                Some(json!({ "id": 2, "state": "sending" })),
                130,
                out(false, "the car link did not answer"),
            ),
        ] {
            assert_eq!(
                ended(&req, report.as_ref(), now),
                want,
                "{report:?} at {now}"
            );
        }
    }
}
