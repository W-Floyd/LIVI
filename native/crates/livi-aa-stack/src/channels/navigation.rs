// SPDX-FileCopyrightText: 2025-2026 Lasse Heitgres
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms: see NOTICE

use crate::channels::text;
use crate::log::detail;
use crate::wire::{WIRE_LEN, WIRE_VARINT, decode_fields, decode_varint_value};
use livi_aa_proto::consts::nav_msg;
use livi_aa_proto::{
    EnergyAtDistance, NavigationChargingStation, VehicleEnergyForecast,
    VehicleEnergyForecastNotification,
};
use prost::Message;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum NavigationState {
    Unavailable,
    Active,
    Inactive,
    Rerouting,
}

impl NavigationState {
    pub fn name(self) -> &'static str {
        match self {
            Self::Unavailable => "unavailable",
            Self::Active => "active",
            Self::Inactive => "inactive",
            Self::Rerouting => "rerouting",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum NavigationTurnSide {
    Left,
    Right,
    Unspecified,
}

impl NavigationTurnSide {
    pub fn name(self) -> &'static str {
        match self {
            Self::Left => "left",
            Self::Right => "right",
            Self::Unspecified => "unspecified",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum NavigationTurnEvent {
    Unknown,
    Depart,
    NameChange,
    SlightTurn,
    Turn,
    SharpTurn,
    UTurn,
    OnRamp,
    OffRamp,
    Fork,
    Merge,
    RoundaboutEnter,
    RoundaboutExit,
    RoundaboutEnterAndExit,
    Straight,
    FerryBoat,
    FerryTrain,
    Destination,
}

impl NavigationTurnEvent {
    pub const ALL: [Self; 18] = [
        Self::Unknown,
        Self::Depart,
        Self::NameChange,
        Self::SlightTurn,
        Self::Turn,
        Self::SharpTurn,
        Self::UTurn,
        Self::OnRamp,
        Self::OffRamp,
        Self::Fork,
        Self::Merge,
        Self::RoundaboutEnter,
        Self::RoundaboutExit,
        Self::RoundaboutEnterAndExit,
        Self::Straight,
        Self::FerryBoat,
        Self::FerryTrain,
        Self::Destination,
    ];

    pub fn name(self) -> &'static str {
        match self {
            Self::Unknown => "unknown",
            Self::Depart => "depart",
            Self::NameChange => "name-change",
            Self::SlightTurn => "slight-turn",
            Self::Turn => "turn",
            Self::SharpTurn => "sharp-turn",
            Self::UTurn => "u-turn",
            Self::OnRamp => "on-ramp",
            Self::OffRamp => "off-ramp",
            Self::Fork => "fork",
            Self::Merge => "merge",
            Self::RoundaboutEnter => "roundabout-enter",
            Self::RoundaboutExit => "roundabout-exit",
            Self::RoundaboutEnterAndExit => "roundabout-enter-and-exit",
            Self::Straight => "straight",
            Self::FerryBoat => "ferry-boat",
            Self::FerryTrain => "ferry-train",
            Self::Destination => "destination",
        }
    }
}

#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct NavigationTurnUpdate {
    pub road: Option<String>,
    pub turn_side: Option<NavigationTurnSide>,
    pub event: Option<NavigationTurnEvent>,
    pub image: Option<Vec<u8>>,
    pub turn_number: Option<u32>,
    pub turn_angle: Option<u32>,
}

#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct NavigationDistanceUpdate {
    pub distance_meters: u32,
    pub time_to_turn_seconds: u32,
    pub display_distance_e3: Option<u32>,
    pub display_unit: Option<u32>,
}

#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct NavigationStateUpdate {
    pub maneuver_type: Option<u32>,
    pub road_name: Option<String>,
    pub cue: Option<String>,
    pub destination_address: Option<String>,
    /// The route's next destination; `None` when the message lists none, as below protocol 1.6.
    pub next_destination: Option<NextDestination>,
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct NextDestination {
    /// Present only when the destination is a charging stop.
    pub charger: Option<ChargerPlan>,
}

/// The phone sends −1 for a value it has not planned; that reads as `None`.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct ChargerPlan {
    pub power_w: Option<u32>,
    pub charge_s: Option<u32>,
    pub departure_wh: Option<u32>,
}

impl ChargerPlan {
    fn of(power_w: Option<i32>, charge_s: Option<i32>, departure_wh: Option<i32>) -> Self {
        let planned = |v: Option<i32>| v.and_then(|v| u32::try_from(v).ok());
        Self {
            power_w: planned(power_w),
            charge_s: planned(charge_s),
            departure_wh: planned(departure_wh),
        }
    }
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct EnergyAtStop {
    /// Negative when Maps forecasts arriving short of the stop.
    pub arrival_wh: Option<i32>,
    pub distance_m: Option<u32>,
    pub time_s: Option<u32>,
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct EnergyForecastUpdate {
    pub next_stop: Option<EnergyAtStop>,
    pub charging: Option<ChargerPlan>,
}

#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct NavigationPositionUpdate {
    pub step_distance_meters: Option<u32>,
    pub step_distance_display: Option<String>,
    pub time_to_step_seconds: Option<u32>,
    pub destination_meters: Option<u32>,
    pub destination_display: Option<String>,
    pub destination_units: Option<u32>,
    pub eta_text: Option<String>,
    pub time_to_arrival_seconds: Option<u32>,
    pub current_road_name: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum NavigationEvent {
    Start,
    Stop,
    Status(NavigationState),
    Turn(NavigationTurnUpdate),
    Distance(NavigationDistanceUpdate),
    State(NavigationStateUpdate),
    Position(NavigationPositionUpdate),
    EnergyForecast(EnergyForecastUpdate),
}

fn opt<T: std::fmt::Debug>(v: &Option<T>) -> String {
    v.as_ref()
        .map_or_else(|| "undefined".to_string(), |v| format!("{v:?}"))
}

fn decode_forecast(payload: &[u8]) -> Option<VehicleEnergyForecast> {
    VehicleEnergyForecastNotification::decode(payload)
        .ok()
        .and_then(|n| VehicleEnergyForecast::decode(n.serialized_forecast?.as_slice()).ok())
}

fn forecast_update(f: &VehicleEnergyForecast) -> EnergyForecastUpdate {
    let unsigned = |v: Option<i32>| v.and_then(|v| u32::try_from(v).ok());
    EnergyForecastUpdate {
        next_stop: f.next_stop.as_ref().map(|e| EnergyAtStop {
            arrival_wh: e.arrival_energy_wh,
            distance_m: unsigned(e.distance_m),
            time_s: unsigned(e.time_to_arrival_seconds),
        }),
        charging: f.next_charging_stop.as_ref().map(|c| {
            ChargerPlan::of(
                c.max_rated_power_w,
                c.charging_seconds,
                c.min_departure_energy_wh,
            )
        }),
    }
}

/// Maps' own forecast for the route the energy model planned, as a log line.
fn forecast_text(payload: &[u8]) -> String {
    let Some(f) = decode_forecast(payload) else {
        return format!("undecodable len={}", payload.len());
    };
    let at = |e: &Option<EnergyAtDistance>| {
        e.as_ref().map_or_else(
            || "undefined".to_string(),
            |e| {
                format!(
                    "(wh={} m={} s={})",
                    opt(&e.arrival_energy_wh),
                    opt(&e.distance_m),
                    opt(&e.time_to_arrival_seconds)
                )
            },
        )
    };
    let charge = f.next_charging_stop.as_ref().map_or_else(
        || "undefined".to_string(),
        |c| {
            format!(
                "(w={} s={} departure_wh={})",
                opt(&c.max_rated_power_w),
                opt(&c.charging_seconds),
                opt(&c.min_departure_energy_wh)
            )
        },
    );
    format!(
        "next_stop={} empty={} quality={} charging={charge}",
        at(&f.next_stop),
        at(&f.empty),
        opt(&f.quality)
    )
}

#[derive(Debug, Default)]
pub struct NavigationChannel;

impl NavigationChannel {
    pub fn handle_message(&mut self, msg_id: u16, payload: &[u8]) -> Option<NavigationEvent> {
        match msg_id {
            nav_msg::START => {
                println!("[NavigationChannel] START");
                Some(NavigationEvent::Start)
            }
            nav_msg::STOP => {
                println!("[NavigationChannel] STOP");
                Some(NavigationEvent::Stop)
            }
            nav_msg::STATUS => {
                let s = decode_status(payload);
                detail!("[NavigationChannel] status={s:?}");
                Some(NavigationEvent::Status(s))
            }
            nav_msg::NEXT_TURN => {
                let t = decode_turn_event(payload);
                detail!(
                    "[NavigationChannel] turn road={} event={} side={} angle={} image={}",
                    opt(&t.road),
                    opt(&t.event),
                    opt(&t.turn_side),
                    opt(&t.turn_angle),
                    t.image
                        .as_ref()
                        .map_or("none".to_string(), |i| format!("{}B", i.len()))
                );
                Some(NavigationEvent::Turn(t))
            }
            nav_msg::NEXT_TURN_DISTANCE => {
                let d = decode_distance_event(payload);
                detail!(
                    "[NavigationChannel] distance {}m t={}s display={}/{}",
                    d.distance_meters,
                    d.time_to_turn_seconds,
                    opt(&d.display_distance_e3),
                    opt(&d.display_unit)
                );
                Some(NavigationEvent::Distance(d))
            }
            nav_msg::STATE => {
                let s = decode_state(payload);
                println!(
                    "[NavigationChannel] state maneuver={} road={} dest={}",
                    opt(&s.maneuver_type),
                    opt(&s.road_name),
                    opt(&s.destination_address)
                );
                Some(NavigationEvent::State(s))
            }
            nav_msg::CURRENT_POSITION => {
                let p = decode_position(payload);
                println!(
                    "[NavigationChannel] position dest={}m eta={} ttarr={}s step={}m",
                    opt(&p.destination_meters),
                    opt(&p.eta_text),
                    opt(&p.time_to_arrival_seconds),
                    opt(&p.step_distance_meters)
                );
                Some(NavigationEvent::Position(p))
            }
            nav_msg::VEHICLE_ENERGY_FORECAST => {
                println!(
                    "[NavigationChannel] energy forecast {}",
                    forecast_text(payload)
                );
                decode_forecast(payload)
                    .map(|f| NavigationEvent::EnergyForecast(forecast_update(&f)))
            }
            other => {
                println!(
                    "[NavigationChannel] unhandled msgId=0x{other:x} len={}",
                    payload.len()
                );
                None
            }
        }
    }
}

pub fn decode_status(payload: &[u8]) -> NavigationState {
    let mut raw = 0;
    for f in decode_fields(payload) {
        if f.field == 1 && f.wire == WIRE_VARINT {
            raw = decode_varint_value(f.bytes);
        }
    }
    match raw {
        1 => NavigationState::Active,
        2 => NavigationState::Inactive,
        3 => NavigationState::Rerouting,
        _ => NavigationState::Unavailable,
    }
}

pub fn decode_turn_event(payload: &[u8]) -> NavigationTurnUpdate {
    let mut out = NavigationTurnUpdate::default();
    for f in decode_fields(payload) {
        match f.field {
            1 => out.road = Some(text(f.bytes)),
            2 => {
                out.turn_side = Some(match decode_varint_value(f.bytes) {
                    1 => NavigationTurnSide::Left,
                    2 => NavigationTurnSide::Right,
                    _ => NavigationTurnSide::Unspecified,
                })
            }
            3 => out.event = Some(next_turn(decode_varint_value(f.bytes))),
            4 => out.image = Some(f.bytes.to_vec()),
            5 => out.turn_number = Some(decode_varint_value(f.bytes)),
            6 => out.turn_angle = Some(decode_varint_value(f.bytes)),
            _ => {}
        }
    }
    out
}

pub fn decode_distance_event(payload: &[u8]) -> NavigationDistanceUpdate {
    let mut out = NavigationDistanceUpdate::default();
    for f in decode_fields(payload) {
        match f.field {
            1 => out.distance_meters = decode_varint_value(f.bytes),
            2 => out.time_to_turn_seconds = decode_varint_value(f.bytes),
            3 => out.display_distance_e3 = Some(decode_varint_value(f.bytes)),
            4 => out.display_unit = Some(decode_varint_value(f.bytes)),
            _ => {}
        }
    }
    out
}

pub fn decode_state(payload: &[u8]) -> NavigationStateUpdate {
    let mut out = NavigationStateUpdate::default();
    for f in decode_fields(payload) {
        let road_unset = out.road_name.as_deref().is_none_or(str::is_empty);
        if f.field == 1 && f.wire == WIRE_LEN && out.maneuver_type.is_none() && road_unset {
            for s in decode_fields(f.bytes) {
                if s.field == 1 && s.wire == WIRE_LEN {
                    for m in decode_fields(s.bytes) {
                        if m.field == 1 && m.wire == WIRE_VARINT {
                            out.maneuver_type = Some(decode_varint_value(m.bytes));
                        }
                    }
                } else if s.field == 2 && s.wire == WIRE_LEN {
                    for r in decode_fields(s.bytes) {
                        if r.field == 1 && r.wire == WIRE_LEN {
                            out.road_name = Some(text(r.bytes));
                        }
                    }
                } else if s.field == 4 && s.wire == WIRE_LEN && out.cue.is_none() {
                    for c in decode_fields(s.bytes) {
                        if c.field == 1 && c.wire == WIRE_LEN && out.cue.is_none() {
                            out.cue = Some(text(c.bytes));
                        }
                    }
                }
            }
        } else if f.field == 2 && f.wire == WIRE_LEN {
            if out.next_destination.is_none() {
                out.next_destination = Some(next_destination(f.bytes));
            }
            if out.destination_address.is_none() {
                for d in decode_fields(f.bytes) {
                    if d.field == 1 && d.wire == WIRE_LEN {
                        out.destination_address = Some(text(d.bytes));
                    }
                }
            }
        }
    }
    out
}

fn next_destination(b: &[u8]) -> NextDestination {
    let charger = decode_fields(b)
        .find(|d| d.field == 2 && d.wire == WIRE_LEN)
        .and_then(|d| NavigationChargingStation::decode(d.bytes).ok())
        .map(|c| {
            ChargerPlan::of(
                c.max_rated_power_watts,
                c.estimated_charging_time_seconds,
                c.min_departure_energy_wh,
            )
        });
    NextDestination { charger }
}

pub fn decode_position(payload: &[u8]) -> NavigationPositionUpdate {
    let mut out = NavigationPositionUpdate::default();
    for f in decode_fields(payload) {
        if f.field == 1 && f.wire == WIRE_LEN {
            for s in decode_fields(f.bytes) {
                if s.field == 1 && s.wire == WIRE_LEN {
                    let d = decode_distance(s.bytes);
                    out.step_distance_meters = d.meters;
                    out.step_distance_display = d.display;
                } else if s.field == 2 && s.wire == WIRE_VARINT {
                    out.time_to_step_seconds = Some(decode_varint_value(s.bytes));
                }
            }
        } else if f.field == 2 && f.wire == WIRE_LEN && out.destination_meters.is_none() {
            for dd in decode_fields(f.bytes) {
                if dd.field == 1 && dd.wire == WIRE_LEN {
                    let d = decode_distance(dd.bytes);
                    out.destination_meters = d.meters;
                    out.destination_display = d.display;
                    out.destination_units = d.units;
                } else if dd.field == 2 && dd.wire == WIRE_LEN {
                    out.eta_text = Some(text(dd.bytes));
                } else if dd.field == 3 && dd.wire == WIRE_VARINT {
                    out.time_to_arrival_seconds = Some(decode_varint_value(dd.bytes));
                }
            }
        } else if f.field == 3 && f.wire == WIRE_LEN {
            for r in decode_fields(f.bytes) {
                if r.field == 1 && r.wire == WIRE_LEN {
                    out.current_road_name = Some(text(r.bytes));
                }
            }
        }
    }
    out
}

#[derive(Default)]
struct Distance {
    meters: Option<u32>,
    display: Option<String>,
    units: Option<u32>,
}

fn decode_distance(b: &[u8]) -> Distance {
    let mut out = Distance::default();
    for f in decode_fields(b) {
        if f.field == 1 && f.wire == WIRE_VARINT {
            out.meters = Some(decode_varint_value(f.bytes));
        } else if f.field == 2 && f.wire == WIRE_LEN {
            out.display = Some(text(f.bytes));
        } else if f.field == 3 && f.wire == WIRE_VARINT {
            out.units = Some(decode_varint_value(f.bytes));
        }
    }
    out
}

fn next_turn(v: u32) -> NavigationTurnEvent {
    use NavigationTurnEvent as E;
    match v {
        1 => E::Depart,
        2 => E::NameChange,
        3 => E::SlightTurn,
        4 => E::Turn,
        5 => E::SharpTurn,
        6 => E::UTurn,
        7 => E::OnRamp,
        8 => E::OffRamp,
        9 => E::Fork,
        10 => E::Merge,
        11 => E::RoundaboutEnter,
        12 => E::RoundaboutExit,
        13 => E::RoundaboutEnterAndExit,
        14 => E::Straight,
        16 => E::FerryBoat,
        17 => E::FerryTrain,
        19 => E::Destination,
        _ => E::Unknown,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::wire::{field_len_delim, field_varint};
    use livi_aa_proto::ChargingStopEnergy;

    fn s(field: u32, v: &str) -> Vec<u8> {
        field_len_delim(field, v.as_bytes())
    }

    #[test]
    fn the_energy_forecast_reads_as_a_line() {
        let inner = VehicleEnergyForecast {
            next_stop: Some(EnergyAtDistance {
                distance_m: Some(120_000),
                arrival_energy_wh: Some(-1500),
                time_to_arrival_seconds: None,
            }),
            empty: None,
            quality: Some(2),
            next_charging_stop: None,
        };
        let wrapped = VehicleEnergyForecastNotification {
            serialized_forecast: Some(inner.encode_to_vec()),
        };
        assert_eq!(
            forecast_text(&wrapped.encode_to_vec()),
            "next_stop=(wh=-1500 m=120000 s=undefined) empty=undefined quality=2 charging=undefined"
        );
        assert_eq!(
            forecast_text(&[0x0a, 0x00]),
            "next_stop=undefined empty=undefined quality=undefined charging=undefined"
        );
        assert_eq!(forecast_text(&[0xff]), "undecodable len=1");

        let charging = VehicleEnergyForecast {
            next_charging_stop: Some(ChargingStopEnergy {
                min_departure_energy_wh: Some(-1),
                max_rated_power_w: Some(400_000),
                charging_seconds: Some(1200),
            }),
            ..inner
        };
        let wrap = |f: &VehicleEnergyForecast| {
            VehicleEnergyForecastNotification {
                serialized_forecast: Some(f.encode_to_vec()),
            }
            .encode_to_vec()
        };
        for (payload, event) in [
            (vec![0xff], None),
            (
                vec![0x0a, 0x00],
                Some(NavigationEvent::EnergyForecast(Default::default())),
            ),
            (
                wrap(&charging),
                Some(NavigationEvent::EnergyForecast(EnergyForecastUpdate {
                    next_stop: Some(EnergyAtStop {
                        arrival_wh: Some(-1500),
                        distance_m: Some(120_000),
                        time_s: None,
                    }),
                    charging: Some(ChargerPlan {
                        power_w: Some(400_000),
                        charge_s: Some(1200),
                        departure_wh: None,
                    }),
                })),
            ),
        ] {
            assert_eq!(
                NavigationChannel.handle_message(nav_msg::VEHICLE_ENERGY_FORECAST, &payload),
                event
            );
        }
    }

    #[test]
    fn the_channel_sorts_its_messages() {
        let mut n = NavigationChannel;
        assert_eq!(
            n.handle_message(nav_msg::START, &[]),
            Some(NavigationEvent::Start)
        );
        assert_eq!(
            n.handle_message(nav_msg::STOP, &[]),
            Some(NavigationEvent::Stop)
        );
        for (raw, state) in [
            (1, NavigationState::Active),
            (2, NavigationState::Inactive),
            (3, NavigationState::Rerouting),
            (7, NavigationState::Unavailable),
        ] {
            assert_eq!(
                n.handle_message(nav_msg::STATUS, &field_varint(1, raw)),
                Some(NavigationEvent::Status(state))
            );
        }
        let turn = [
            s(1, "Main St"),
            field_varint(2, 2),
            field_varint(3, 4),
            field_len_delim(4, &[9]),
            field_varint(5, 2),
            field_varint(6, 90),
        ]
        .concat();
        assert_eq!(
            n.handle_message(nav_msg::NEXT_TURN, &turn),
            Some(NavigationEvent::Turn(NavigationTurnUpdate {
                road: Some("Main St".into()),
                turn_side: Some(NavigationTurnSide::Right),
                event: Some(NavigationTurnEvent::Turn),
                image: Some(vec![9]),
                turn_number: Some(2),
                turn_angle: Some(90),
            }))
        );
        let dist = [
            field_varint(1, 250),
            field_varint(2, 20),
            field_varint(3, 250),
            field_varint(4, 1),
        ]
        .concat();
        assert_eq!(
            n.handle_message(nav_msg::NEXT_TURN_DISTANCE, &dist),
            Some(NavigationEvent::Distance(NavigationDistanceUpdate {
                distance_meters: 250,
                time_to_turn_seconds: 20,
                display_distance_e3: Some(250),
                display_unit: Some(1),
            }))
        );
        assert_eq!(n.handle_message(0x8999, &[]), None);
    }

    #[test]
    fn state_and_position_take_the_first_step_and_destination() {
        let step = [
            field_len_delim(1, &field_varint(1, 8)),
            field_len_delim(2, &s(1, "Ring")),
            field_len_delim(4, &[s(1, "cue1"), s(1, "cue2")].concat()),
        ]
        .concat();
        let second = [
            field_len_delim(1, &field_varint(1, 7)),
            field_len_delim(2, &s(1, "Other")),
        ]
        .concat();
        let state = [
            field_len_delim(1, &step),
            field_len_delim(1, &second),
            field_len_delim(2, &s(1, "Home")),
            field_len_delim(2, &s(1, "Work")),
        ]
        .concat();
        assert_eq!(
            decode_state(&state),
            NavigationStateUpdate {
                maneuver_type: Some(8),
                road_name: Some("Ring".into()),
                cue: Some("cue1".into()),
                destination_address: Some("Home".into()),
                next_destination: Some(NextDestination { charger: None }),
            }
        );
        let charger = |departure: i64, power: i64, secs: i64| {
            field_len_delim(
                2,
                &[
                    field_varint(1, departure),
                    field_varint(2, power),
                    field_varint(3, secs),
                ]
                .concat(),
            )
        };
        for (destinations, next) in [
            (vec![], None),
            (
                vec![
                    [s(1, "Ionna"), charger(77_400, 180_000, 1500)].concat(),
                    s(1, "Home"),
                ],
                Some(ChargerPlan {
                    power_w: Some(180_000),
                    charge_s: Some(1500),
                    departure_wh: Some(77_400),
                }),
            ),
            (
                vec![[s(1, "Ionna"), charger(-1, 50_000, -1)].concat()],
                Some(ChargerPlan {
                    power_w: Some(50_000),
                    ..Default::default()
                }),
            ),
            (
                vec![s(1, "Home"), [s(1, "Ionna"), charger(1, 1, 1)].concat()],
                None,
            ),
        ] {
            let listed = !destinations.is_empty();
            let payload: Vec<u8> = destinations
                .iter()
                .flat_map(|d| field_len_delim(2, d))
                .collect();
            assert_eq!(
                decode_state(&payload).next_destination,
                listed.then_some(NextDestination { charger: next })
            );
        }
        let distance =
            |m: i64, d: &str, u: i64| [field_varint(1, m), s(2, d), field_varint(3, u)].concat();
        let position = [
            field_len_delim(
                1,
                &[
                    field_len_delim(1, &distance(300, "300 m", 1)),
                    field_varint(2, 25),
                ]
                .concat(),
            ),
            field_len_delim(
                2,
                &[
                    field_len_delim(1, &distance(12000, "12 km", 2)),
                    s(2, "21:58"),
                    field_varint(3, 900),
                ]
                .concat(),
            ),
            field_len_delim(2, &field_len_delim(1, &distance(1, "x", 1))),
            field_len_delim(3, &s(1, "B1")),
        ]
        .concat();
        assert_eq!(
            decode_position(&position),
            NavigationPositionUpdate {
                step_distance_meters: Some(300),
                step_distance_display: Some("300 m".into()),
                time_to_step_seconds: Some(25),
                destination_meters: Some(12000),
                destination_display: Some("12 km".into()),
                destination_units: Some(2),
                eta_text: Some("21:58".into()),
                time_to_arrival_seconds: Some(900),
                current_road_name: Some("B1".into()),
            }
        );
        let mut n = NavigationChannel;
        assert!(matches!(
            n.handle_message(nav_msg::STATE, &state),
            Some(NavigationEvent::State(_))
        ));
        assert!(matches!(
            n.handle_message(nav_msg::CURRENT_POSITION, &position),
            Some(NavigationEvent::Position(_))
        ));
        for v in 0..21 {
            let _ = next_turn(v);
        }
        assert_eq!(next_turn(19), NavigationTurnEvent::Destination);
        assert_eq!(next_turn(15), NavigationTurnEvent::Unknown);
    }
}
