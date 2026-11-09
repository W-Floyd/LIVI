// SPDX-FileCopyrightText: 2025-2026 Lasse Heitgres
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms: see NOTICE

//! The user's manual battery preconditioning request. LIVI only states it at GET /navigation;
//! a car integration does the car's side.

use std::sync::Arc;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use livi_core_proto::config::{BatteryPreconditioning, Config};
use serde_json::{Value, json};

use crate::server::Core;

pub fn now_s() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0, |d| d.as_secs())
}

/// When a request made now ends, or why none can be made.
pub fn request(config: &Config, now: u64) -> Result<u64, String> {
    if config.battery_preconditioning == BatteryPreconditioning::Off {
        return Err("battery preconditioning is off".into());
    }
    Ok(now + u64::from(config.battery_preconditioning_manual_minutes) * 60)
}

/// The request still standing: none once it ran out, the session ended, or the setting is off.
fn kept(
    until: Option<u64>,
    mode: BatteryPreconditioning,
    now: u64,
    session_ended: bool,
) -> Option<u64> {
    until.filter(|u| *u > now && !session_ended && mode == BatteryPreconditioning::Auto)
}

/// What GET /navigation carries for the car integration.
pub fn api(config: &Config, until: Option<u64>) -> Value {
    json!({
        "mode": config.battery_preconditioning,
        "manual": until.is_some(),
        "manualUntil": until,
    })
}

pub async fn follow(core: Arc<Core>) {
    let mut state = core.hub.watch();
    let mut session = state.borrow().sessions.active;
    loop {
        let (until, active) = {
            let s = state.borrow_and_update();
            (s.precondition.manual_until, s.sessions.active)
        };
        let ended = session.is_some() && active.is_none();
        session = active;
        if until.is_some() {
            core.hub.update(|s| {
                let mode = s.config.battery_preconditioning;
                let now = now_s();
                s.precondition.manual_until = kept(s.precondition.manual_until, mode, now, ended);
                if s.precondition.manual_until.is_none() {
                    let why = match () {
                        _ if mode == BatteryPreconditioning::Off => "the setting is off",
                        _ if ended => "the session ended",
                        _ => "its time ran out",
                    };
                    println!("[core] battery preconditioning request ended: {why}");
                }
            });
        }
        let wait = until.map(|u| Duration::from_secs(u.saturating_sub(now_s())));
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
    use super::*;
    use crate::config_file::defaults;

    #[test]
    fn a_manual_request_ends_on_time_with_the_session_or_when_switched_off() {
        use BatteryPreconditioning::{Auto, Off};
        for (until, mode, now, ended, want) in [
            (None, Auto, 100, false, None),
            (Some(200), Auto, 100, false, Some(200)),
            (Some(200), Auto, 199, false, Some(200)),
            (Some(200), Auto, 200, false, None),
            (Some(200), Auto, 300, false, None),
            (Some(200), Auto, 100, true, None),
            (Some(200), Off, 100, false, None),
        ] {
            assert_eq!(
                kept(until, mode, now, ended),
                want,
                "{until:?} {mode:?} at {now}, session ended {ended}"
            );
        }
    }

    #[test]
    fn a_request_lasts_the_configured_minutes_unless_off() {
        let mut config = defaults();
        assert_eq!(request(&config, 1000), Ok(1000 + 30 * 60));
        config.battery_preconditioning_manual_minutes = 5;
        assert_eq!(request(&config, 1000), Ok(1300));
        config.battery_preconditioning = BatteryPreconditioning::Off;
        assert!(request(&config, 1000).is_err());
    }
}
