// SPDX-FileCopyrightText: 2025-2026 Lasse Heitgres
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms: see NOTICE

//! The user's edits of the car's EV schedules, and changes of its charge limits and AC charging
//! current. LIVI only states the edit at GET /navigation; the car integration sends it and
//! reports back in telemetry (`evScheduleWrite`, `evChargeWrite`), which ends it.

use std::sync::Arc;
use std::time::Duration;

use livi_core_proto::state::{
    EvCharge, EvChargeEdit, EvChargeRequest, EvSchedule, EvScheduleEdit, EvScheduleOutcome,
    EvScheduleRequest,
};
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
    gate(
        telemetry,
        "evScheduleWrites",
        "the schedules",
        s.request.is_some(),
    )?;
    set.check()?;
    let id = s.last.as_ref().map_or(0, |l| l.id) + 1;
    Ok(EvScheduleRequest { id, at: now, set })
}

/// The request for a charge change `set` made now, or why none can be made.
pub fn charge_request(
    s: &EvCharge,
    telemetry: &Map<String, Value>,
    set: EvChargeEdit,
    now: u64,
) -> Result<EvChargeRequest, String> {
    gate(
        telemetry,
        "evChargeWrites",
        "the charge settings",
        s.request.is_some(),
    )?;
    set.check()?;
    let id = s.last.as_ref().map_or(0, |l| l.id) + 1;
    Ok(EvChargeRequest { id, at: now, set })
}

/// Why no change can go now: the car link does not send these (`writes`), the car is not
/// parked, or one is still on its way.
fn gate(
    telemetry: &Map<String, Value>,
    writes: &str,
    what: &str,
    pending: bool,
) -> Result<(), String> {
    if telemetry.get(writes) != Some(&Value::Bool(true)) {
        return Err(format!("the car link does not set {what}"));
    }
    if let Some(why) = not_parked(telemetry) {
        return Err(why);
    }
    if pending {
        return Err("an edit is still on its way to the car".into());
    }
    Ok(())
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

/// The end of request `id` made at `at`, if the car integration's report or the time says so.
fn ended(id: u64, at: u64, report: Option<&Value>, now: u64) -> Option<EvScheduleOutcome> {
    let report = report.filter(|r| r["id"].as_u64() == Some(id));
    let why = report
        .and_then(|r| r["why"].as_str())
        .unwrap_or_default()
        .to_string();
    match report.and_then(|r| r["state"].as_str()) {
        Some("confirmed") => Some(EvScheduleOutcome { id, ok: true, why }),
        Some("failed") => Some(EvScheduleOutcome { id, ok: false, why }),
        _ if now >= at + ANSWER_WITHIN => Some(EvScheduleOutcome {
            id,
            ok: false,
            why: "the car link did not answer".into(),
        }),
        _ => None,
    }
}

pub async fn follow(core: Arc<Core>) {
    let mut state = core.hub.watch();
    loop {
        let due = {
            let s = state.borrow_and_update();
            let at = [
                s.ev_schedule.request.as_ref().map(|r| r.at),
                s.ev_charge.request.as_ref().map(|r| r.at),
            ];
            at.into_iter().flatten().min()
        };
        if due.is_some() {
            core.hub.update(|s| {
                let now = now_s();
                let sched = s
                    .ev_schedule
                    .request
                    .as_ref()
                    .and_then(|r| ended(r.id, r.at, s.telemetry.get("evScheduleWrite"), now));
                if let Some(out) = sched {
                    log("schedule edit", &out);
                    s.ev_schedule = EvSchedule {
                        request: None,
                        last: Some(out),
                    };
                }
                let charge = s
                    .ev_charge
                    .request
                    .as_ref()
                    .and_then(|r| ended(r.id, r.at, s.telemetry.get("evChargeWrite"), now));
                if let Some(out) = charge {
                    log("charge change", &out);
                    s.ev_charge = EvCharge {
                        request: None,
                        last: Some(out),
                    };
                }
            });
        }
        let wait = due.map(|a| Duration::from_secs((a + ANSWER_WITHIN).saturating_sub(now_s())));
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

fn log(what: &str, out: &EvScheduleOutcome) {
    match out.ok {
        true => println!("[core] ev {what} {} confirmed", out.id),
        false => println!("[core] ev {what} {} failed: {}", out.id, out.why),
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
    fn a_charge_change_goes_only_where_the_car_link_takes_it_parked_and_on_stocks_steps() {
        let ac = |pct| EvChargeEdit {
            charge_limit_ac_pct: Some(pct),
            ..Default::default()
        };
        let current = |pct| EvChargeEdit {
            charging_current_pct: Some(pct),
            ..Default::default()
        };
        let pending = EvCharge {
            request: Some(EvChargeRequest {
                id: 2,
                at: 1,
                set: ac(80),
            }),
            last: None,
        };
        let after = EvCharge {
            request: None,
            last: Some(EvScheduleOutcome {
                id: 2,
                ok: true,
                why: String::new(),
            }),
        };
        let writes = json!({ "evChargeWrites": true, "drivingRegulation": false, "gear": "P" });
        for (s, t, set, want) in [
            (&EvCharge::default(), writes.clone(), ac(80), Ok(1)),
            (&after, writes.clone(), current(60), Ok(3)),
            (
                &EvCharge::default(),
                writes.clone(),
                EvChargeEdit {
                    charge_limit_dc_pct: Some(100),
                    charging_current_pct: Some(90),
                    ..Default::default()
                },
                Ok(1),
            ),
            // The schedules' word is not the charge settings'.
            (
                &EvCharge::default(),
                json!({ "evScheduleWrites": true }),
                ac(80),
                Err("does not set the charge settings"),
            ),
            (
                &EvCharge::default(),
                json!({ "evChargeWrites": true, "gear": "R" }),
                ac(80),
                Err("in R"),
            ),
            (&pending, writes.clone(), ac(90), Err("still on its way")),
            (
                &EvCharge::default(),
                writes.clone(),
                ac(75),
                Err("AC limit 75 %: 50 to 100 in tens"),
            ),
            (
                &EvCharge::default(),
                writes.clone(),
                EvChargeEdit {
                    charge_limit_dc_pct: Some(40),
                    ..Default::default()
                },
                Err("DC limit 40 %"),
            ),
            (
                &EvCharge::default(),
                writes.clone(),
                current(80),
                Err("charging current 80 %: 100, 90 or 60"),
            ),
            (
                &EvCharge::default(),
                writes.clone(),
                EvChargeEdit::default(),
                Err("nothing to change"),
            ),
        ] {
            let got = charge_request(s, &tel(t.clone()), set.clone(), 100);
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
                ended(req.id, req.at, report.as_ref(), now),
                want,
                "{report:?} at {now}"
            );
        }
    }
}
