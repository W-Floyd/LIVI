// SPDX-FileCopyrightText: 2025-2026 Lasse Heitgres
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms: see NOTICE

use std::time::{SystemTime, UNIX_EPOCH};

use livi_core_proto::config::{BatteryPreconditioning, CarType, EvConnectorType};
use livi_core_proto::message::Action;
use serde_json::Value;

use super::info;
use crate::i18n::Strings;
use crate::icons::settings_icon;
use crate::settings::view::{Change, Row, RowKind, Tool};

fn finite(v: &Value) -> Option<f64> {
    v.as_f64().filter(|f| f.is_finite())
}

pub fn now_s() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0, |d| d.as_secs())
}

/// The manual request's switch, what the car reports of its own conditioning, and what the
/// automatic preconditioning does.
pub fn precondition(state: &Value, t: &Strings, now: u64) -> Vec<Row> {
    let mode = serde_json::from_value(state["config"]["batteryPreconditioning"].clone())
        .unwrap_or(BatteryPreconditioning::Auto);
    let until = state["precondition"]["manualUntil"].as_u64();
    let left = until.map(|u| u.saturating_sub(now).div_ceil(60).to_string());
    let conditioning = match state["telemetry"]["batteryConditioning"].as_bool() {
        Some(true) => t.t("settings.conditioningOn", "On"),
        Some(false) => t.t("settings.conditioningOff", "Off"),
        None => t.t("settings.conditioningUnknown", "Unknown"),
    };
    vec![
        Row {
            kind: RowKind::Switch,
            label: t.t("settings.preconditionNow", "Precondition Battery"),
            icon: settings_icon("preconditionNow"),
            value: left
                .map(|m| {
                    t.with(
                        "settings.minutesLeft",
                        "{{minutes}} min left",
                        &[("minutes", &m)],
                    )
                })
                .unwrap_or_default(),
            checked: until.is_some(),
            enabled: mode == BatteryPreconditioning::Auto,
            change: Some(Change::Act(Action::PreconditionBattery {
                on: until.is_none(),
            })),
            ..Row::default()
        },
        info(
            t.t("settings.batteryConditioning", "Conditioning"),
            Some("batteryConditioning"),
            conditioning,
        ),
        info(
            t.t("settings.preconditionRoute", "On a Route to a Fast Charger"),
            Some("batteryPreconditioning"),
            route_precondition(&state["telemetry"], t),
        ),
    ]
}

/// What the car integration's automatic preconditioning does, as it reports it. Its reasons are
/// its own words, untranslated.
fn route_precondition(tel: &Value, t: &Strings) -> String {
    let why = tel["preconditionWhy"].as_str().filter(|w| !w.is_empty());
    match tel["preconditionState"].as_str() {
        None => t.t("settings.preconditionUnreported", "Not reported by the car"),
        Some("running") => t.t("settings.preconditionRunning", "Running"),
        Some("off") => t.t("settings.conditioningOff", "Off"),
        Some(_) => match why {
            Some(w) => {
                let mut c = w.chars();
                c.next()
                    .map(|f| f.to_uppercase().chain(c).collect())
                    .unwrap_or_default()
            }
            None => t.t("settings.preconditionArmed", "Armed"),
        },
    }
}

pub fn readings(state: &Value, t: &Strings) -> Vec<Row> {
    let tel = &state["telemetry"];
    let config = &state["config"];
    let capacity = finite(&tel["batteryCapacityKwh"]);
    let level = finite(&tel["batteryLevelKwh"]);
    let electric = serde_json::from_value::<CarType>(config["carType"].clone())
        .is_ok_and(|c| c == CarType::Electric);
    let charge = match (level, capacity) {
        (Some(l), Some(c)) if c != 0.0 => Some(l / c * 100.0),
        _ if electric => finite(&tel["fuelPct"]),
        _ => None,
    };
    let connectors: Vec<String> =
        serde_json::from_value::<Vec<EvConnectorType>>(config["evConnectorTypes"].clone())
            .unwrap_or_default()
            .iter()
            .map(|c| format!("{c:?}"))
            .collect();
    let mut out = Vec::new();
    if let Some(c) = capacity {
        out.push(info(
            t.t("settings.batteryCapacity", "Battery Capacity"),
            None,
            format!("{c:.1} kWh"),
        ));
    }
    if let Some(c) = charge {
        out.push(info(
            t.t("settings.stateOfCharge", "State of Charge"),
            None,
            format!("{} %", c.round()),
        ));
    }
    if !connectors.is_empty() {
        out.push(info(
            t.t("settings.evConnectors", "Charging Connectors"),
            None,
            connectors.join(", "),
        ));
    }
    out
}

fn layout_name(cluster: &Value, id: &str) -> String {
    cluster["theme"]["displays"]
        .as_array()
        .into_iter()
        .flatten()
        .flat_map(|d| d["layouts"].as_array().into_iter().flatten())
        .find(|l| l["id"].as_str() == Some(id))
        .and_then(|l| l["name"].as_str())
        .unwrap_or(id)
        .to_string()
}

pub fn layouts(state: &Value, t: &Strings) -> Vec<Row> {
    let cluster = &state["cluster"];
    let arranged = cluster["arranged"].as_array().cloned().unwrap_or_default();
    let last = arranged.len().saturating_sub(1);
    arranged
        .iter()
        .enumerate()
        .map(|(i, l)| {
            let id = l["id"].as_str().unwrap_or("").to_string();
            let on = l["on"].as_bool().unwrap_or(false);
            let name = layout_name(cluster, &id);
            let label = t.t(&format!("settings.layout_{}", id.replace('.', "_")), &name);
            let mv = |icon: &'static str, key: &str, text: &str, by: i32, enabled: bool| Tool {
                icon,
                label: t.t(key, text),
                on: false,
                tint: None,
                enabled,
                switch: false,
                action: Action::MoveClusterLayout {
                    layout: id.clone(),
                    by,
                },
            };
            Row {
                kind: RowKind::Item,
                label: label.clone(),
                enabled: true,
                tools: vec![
                    Tool {
                        icon: "",
                        label,
                        on,
                        tint: None,
                        enabled: true,
                        switch: true,
                        action: Action::ShowClusterLayout {
                            layout: id.clone(),
                            on: !on,
                        },
                    },
                    mv("ExpandLess", "settings.moveUp", "Move up", -1, i > 0),
                    mv("ExpandMore", "settings.moveDown", "Move down", 1, i < last),
                ],
                ..Row::default()
            }
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use serde_json::json;

    use super::*;

    #[test]
    fn an_electric_car_reads_its_charge_from_the_fuel_level() {
        let s = json!({ "telemetry": { "fuelPct": 63.4 }, "config": { "carType": 10, "evConnectorTypes": [2, 5] } });
        let rows = readings(&s, &Strings::new("en"));
        assert_eq!(rows[0].value, "63 %");
        assert_eq!(rows[1].value, "Mennekes, Combo2");
    }

    #[test]
    fn layouts_switch_and_move() {
        let s = json!({ "cluster": {
            "theme": { "displays": [ { "layouts": [ { "id": "x.one", "name": "One" } ] } ] },
            "arranged": [ { "id": "x.one", "on": true }, { "id": "x.two", "on": false } ] } });
        let rows = layouts(&s, &Strings::new("en"));
        assert_eq!(rows[0].label, "One");
        assert_eq!(rows[1].label, "x.two");
        assert!(rows[0].tools[0].switch && rows[0].tools[0].on);
        assert!(!rows[0].tools[1].enabled && !rows[1].tools[2].enabled);
    }

    #[test]
    fn the_precondition_switch_shows_its_request_and_the_car() {
        // (state, on, enabled, time left, conditioning, automatic on a route)
        for (s, on, enabled, left, car, route) in [
            (
                json!({}),
                false,
                true,
                "",
                "Unknown",
                "Not reported by the car",
            ),
            (
                json!({ "precondition": { "manualUntil": 1601 }, "telemetry": { "batteryConditioning": true, "preconditionState": "running", "preconditionWhy": "" } }),
                true,
                true,
                "11 min left",
                "On",
                "Running",
            ),
            (
                json!({ "config": { "batteryPreconditioning": "off" }, "telemetry": { "batteryConditioning": false, "preconditionState": "off", "preconditionWhy": "off in LIVI's settings" } }),
                false,
                false,
                "",
                "Off",
                "Off",
            ),
            (
                json!({ "telemetry": { "preconditionState": "armed", "preconditionWhy": "the charger is 11 kW, not above 50" } }),
                false,
                true,
                "",
                "Unknown",
                "The charger is 11 kW, not above 50",
            ),
            (
                json!({ "telemetry": { "preconditionState": "armed" } }),
                false,
                true,
                "",
                "Unknown",
                "Armed",
            ),
        ] {
            let rows = precondition(&s, &Strings::new("en"), 1000);
            assert_eq!(
                (rows[0].checked, rows[0].enabled, rows[0].value.as_str()),
                (on, enabled, left),
                "{s}"
            );
            assert_eq!(
                rows[0].change,
                Some(Change::Act(Action::PreconditionBattery { on: !on }))
            );
            assert_eq!(rows[1].value, car, "{s}");
            assert_eq!(rows[2].value, route, "{s}");
        }
    }
}
