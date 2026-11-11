// SPDX-FileCopyrightText: 2025-2026 Lasse Heitgres
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms: see NOTICE

//! What the car and programs outside LIVI push into its telemetry, merged into one snapshot.
//!
//! Push over Socket.IO to `ws://<livi-host>:4000`, event `telemetry:push`, for example
//! `io('ws://livi.local:4000').emit('telemetry:push', { speedKph: 73 })`, or as plain HTTP,
//! `curl -d '{"speedKph":73}' http://livi.local:4000/telemetry`. From a shell LIVI's own core
//! does it, `livi-core telemetry set speedKph=73 gps.lat=53.59`, `livi-core telemetry help`
//! lists the rest.
//!
//! A push may carry any subset of the fields. `gps`, `can`, `climate`, `tirePressure` and
//! `notification` merge
//! field by field, so `{ gps: { lat: 50 } }` keeps the last `lng`, every other field is replaced
//! whole. LIVI sends the merged snapshot to every client as `telemetry:update`.
//!
//! Where each field goes, ✓ used, · not used, TODO the receiver takes it and LIVI does not send
//! it yet. LIVI holds every field in its store and hands it to every Socket.IO client.
//!
//! | Field                               | LIVI | Android Auto | CarPlay Classic | CarPlay Ultra |
//! |-------------------------------------|------|--------------|-----------------|---------------|
//! | speedKph                            | ✓    | ✓            | TODO            | TODO          |
//! | rpm                                 | ✓    | ✓            | ·               | ✓             |
//! | gear                                | ✓    | ✓            | ✓               | ✓             |
//! | reverse                             | ✓    | ✓ (gear)     | ✓ (gear)        | ✓ (gear)      |
//! | steeringDeg                         | ✓    | ·            | ·               | ·             |
//! | turnSignal                          | ✓    | ✓            | ·               | TODO          |
//! | lights, highBeam, hazards           | ✓    | ✓            | ·               | ·             |
//! | parkingBrake                        | ✓    | ✓            | ·               | ·             |
//! | ignition, vehicleReady              | ✓    | ·            | ·               | ·             |
//! | drivingRegulation(B)                | ✓    | ·            | ·               | ·             |
//! | door*Open, door*Locked              | ✓    | ·            | ·               | ·             |
//! | trunkOpen, hoodOpen, chargePortOpen | ✓    | ·            | ·               | ·             |
//! | auxBatteryPct                       | ✓    | ·            | ·               | ·             |
//! | nightMode                           | ·    | ✓            | ✓               | ✓             |
//! | mainUiNightMode, mainMapNightMode   | ·    | ·            | ✓               | ✓             |
//! | clusterUiNightMode                  | ·    | ·            | ✓               | ✓             |
//! | clusterMapNightMode                 | ·    | ·            | ✓               | ✓             |
//! | appearanceSetting                   | ·    | ·            | ✓               | ✓             |
//! | darkMode                            | ✓    | ·            | ·               | ·             |
//! | path                                | ✓    | ·            | ·               | ·             |
//! | volume                              | ✓    | ·            | ·               | ✓             |
//! | fuelPct                             | ✓    | ✓            | ✓ (warning, %)  | ✓             |
//! | rangeKm                             | ✓    | ✓            | ✓               | ✓             |
//! | rangeClimateOffKm                   | ✓    | ·            | ·               | ·             |
//! | rangeFuelKm, rangeElectricKm        | ✓    | ·            | ✓ (hybrid)      | ✓ (hybrid)    |
//! | fuelRateLph                         | ✓    | ·            | ·               | ·             |
//! | consumption*                        | ✓    | ·            | ·               | ✓             |
//! | batteryCapacityKwh, batteryLevelKwh | ✓    | ✓            | ✓ (electric)    | ✓ (electric)  |
//! | batteryUsableKwh                    | ✓    | ✓            | ·               | ·             |
//! | charging, activeConnector           | ✓    | ·            | ✓ (electric)    | ✓ (electric)  |
//! | chargerReady, chargeTime*Min        | ✓    | ·            | ·               | ·             |
//! | chargeLimit*, rangeAtChargeLimit*  | ✓    | ·            | ·               | ·             |
//! | tripEnergyKwh, efficiencyAvg        | ✓    | ·            | ·               | ·             |
//! | climatePowerW, batteryHeaterW       | ✓    | ·            | ·               | ·             |
//! | rangeMaxElectricKm                  | ✓    | ·            | ✓ (electric)    | ✓ (electric)  |
//! | carType                             | ✓    | ✓            | ✓               | ✓             |
//! | evConnectorTypes                    | ✓    | ✓            | ✓               | ✓             |
//! | evMaxAcPowerKw, evMaxDcPowerKw      | ✓    | ✓            | ✓               | ✓             |
//! | coolantC                            | ✓    | ·            | ·               | TODO          |
//! | iatC, transmissionC                 | ✓    | ·            | ·               | ·             |
//! | oilC                                | ✓    | ·            | ·               | ·             |
//! | ambientC                            | ✓    | ✓            | ✓               | ✓             |
//! | baroKpa                             | ✓    | ✓            | ·               | ·             |
//! | mapKpa, boostKpa, throttlePct       | ✓    | ·            | ·               | ·             |
//! | lambda, afr                         | ✓    | ·            | ·               | ·             |
//! | batteryV                            | ✓    | ·            | ·               | ·             |
//! | ambientLux                          | ✓    | ·            | ·               | ·             |
//! | dimmerPct                           | ✓    | ·            | ·               | ·             |
//! | odometerKm                          | ✓    | ✓            | ·               | ✓             |
//! | odometerTripKm                      | ✓    | ✓            | ·               | ·             |
//! | drivingStatus                       | ✓    | ✓            | ·               | ·             |
//! | gps                                 | ✓    | ✓            | ✓               | ✓             |
//! | tirePressure                        | ✓    | ✓            | ·               | ✓             |
//! | can                                 | ✓    | ·            | ·               | ·             |
//! | gnss                                | ✓    | ·            | ·               | ·             |
//! | climate                             | ✓    | ·            | ·               | ✓             |
//! | steeringWheelHeating, rear*Heating  | ✓    | ·            | ·               | ·             |
//! | climateKey                          | ✓    | ·            | ·               | ·             |
//! | notification                        | ·    | ·            | ·               | ✓             |
//!
//! With `autoSwitchOnReverse` on, `gear` and `reverse` also bring the camera to the front of the
//! main screen while the car reverses.
//!
//! A new field gets its unit in its name and in its doc comment here, its receiver in core
//! (`cp_telemetry.rs` for CarPlay, `aa_telemetry.rs` for Android Auto) and a line above.

use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::gnss::{GnssInfo, GpsFix};

#[derive(Debug, Clone, Default, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct TelemetrySnapshot {
    /// Unix milliseconds, LIVI fills it in when a push has none.
    pub ts: Option<u64>,
    pub speed_kph: Option<f64>,
    pub rpm: Option<f64>,
    /// A number for a manual gearbox, -1 reverse, 0 neutral, 1 to 10. A string for an automatic,
    /// P, R, N, D, S or M1 to M10.
    pub gear: Option<Value>,
    /// Negative is left.
    pub steering_deg: Option<f64>,
    /// Wins over `gear`.
    pub reverse: Option<bool>,
    /// Low beam.
    pub lights: Option<bool>,
    /// Android Auto shows high beam whatever `lights` says.
    pub high_beam: Option<bool>,
    pub hazards: Option<bool>,
    /// Taken as `turn` too, the name it had before.
    pub turn_signal: Option<TurnSignal>,
    pub parking_brake: Option<bool>,
    /// The ignition (IGN1) is on.
    pub ignition: Option<bool>,
    /// The car is READY to drive; for an electric car, its DC-DC runs.
    pub vehicle_ready: Option<bool>,
    /// The car's own lockout of video and the keyboard, as its head unit applies it: true out of
    /// Park. The car decides when, the head unit applies no speed of its own.
    pub driving_regulation: Option<bool>,
    /// The stricter lockout, from Park and the parking brake together.
    pub driving_regulation_b: Option<bool>,
    pub door_driver_open: Option<bool>,
    /// The front passenger's door.
    pub door_passenger_open: Option<bool>,
    pub door_rear_left_open: Option<bool>,
    pub door_rear_right_open: Option<bool>,
    pub door_driver_locked: Option<bool>,
    pub door_passenger_locked: Option<bool>,
    pub door_rear_left_locked: Option<bool>,
    pub door_rear_right_locked: Option<bool>,
    pub trunk_open: Option<bool>,
    pub hood_open: Option<bool>,
    /// The charging flap.
    pub charge_port_open: Option<bool>,
    pub coolant_c: Option<f64>,
    pub oil_c: Option<f64>,
    /// Automatic transmission oil.
    pub transmission_c: Option<f64>,
    /// Intake air.
    pub iat_c: Option<f64>,
    /// Outside, Android Auto and CarPlay get it too.
    pub ambient_c: Option<f64>,
    /// The 12 V battery.
    pub battery_v: Option<f64>,
    /// The 12 V battery's charge, 0 to 100.
    pub aux_battery_pct: Option<f64>,
    /// 0 to 100, for an electric car the state of charge.
    pub fuel_pct: Option<f64>,
    pub range_km: Option<f64>,
    /// The car's range were the climate switched off, `rangeKm` being the range as it runs.
    pub range_climate_off_km: Option<f64>,
    /// Hybrids only, the range on the tank.
    pub range_fuel_km: Option<f64>,
    /// Hybrids only, the range on the battery.
    pub range_electric_km: Option<f64>,
    pub fuel_rate_lph: Option<f64>,
    pub consumption_l_per100_km: Option<f64>,
    pub consumption_avg_l_per100_km: Option<f64>,
    /// Gross capacity. With `batteryLevelKwh`, turns on electric routing in Android Auto, whatever
    /// `carType` says.
    pub battery_capacity_kwh: Option<f64>,
    /// The energy left. CarPlay takes it from `fuelPct` and the capacity when absent, Android
    /// Auto's energy model goes out only with it.
    pub battery_level_kwh: Option<f64>,
    /// What a full gauge holds, LIVI learns it from `batteryLevelKwh` over `fuelPct` and keeps it
    /// across starts. Android Auto's energy model takes it over `batteryCapacityKwh`.
    pub battery_usable_kwh: Option<f64>,
    /// True while the battery charges.
    pub charging: Option<bool>,
    /// The `EvConnectorType` name of the plug that charges, such as `Combo2`.
    pub active_connector: Option<String>,
    /// The on-board charger reports ready.
    pub charger_ready: Option<bool>,
    /// Until the battery is full at the charging going on.
    pub charge_time_to_full_min: Option<f64>,
    /// The car's estimates to its charge limit, on a fast charger, on AC, and on a DC charger
    /// at the power the driver set.
    pub charge_time_dc_min: Option<f64>,
    pub charge_time_ac_min: Option<f64>,
    pub charge_time_dc_custom_min: Option<f64>,
    /// Where AC and DC charging stop, 0 to 100.
    pub charge_limit_ac_pct: Option<f64>,
    pub charge_limit_dc_pct: Option<f64>,
    /// The range once charged to each limit.
    pub range_at_charge_limit_ac_km: Option<f64>,
    pub range_at_charge_limit_dc_km: Option<f64>,
    /// The battery's energy used on this trip.
    pub trip_energy_kwh: Option<f64>,
    /// Distance per kWh in the cluster's unit (km or mi); the scale is a guess.
    pub efficiency_avg: Option<f64>,
    /// What the climate draws.
    pub climate_power_w: Option<f64>,
    /// What the battery's heater draws.
    pub battery_heater_w: Option<f64>,
    /// The range on a full battery.
    pub range_max_electric_km: Option<f64>,
    /// A `CarType` name such as `HybridDiesel`, written into the settings when it differs.
    pub car_type: Option<String>,
    /// `EvConnectorType` names such as `Combo2`, written into the settings when they differ.
    pub ev_connector_types: Option<Vec<String>>,
    /// The fastest AC charging the car takes, written into the settings when it differs.
    pub ev_max_ac_power_kw: Option<f64>,
    /// The fastest DC charging the car takes, written into the settings when it differs.
    pub ev_max_dc_power_kw: Option<f64>,
    /// Manifold absolute pressure.
    pub map_kpa: Option<f64>,
    /// Android Auto also gets it on its environment channel.
    pub baro_kpa: Option<f64>,
    pub boost_kpa: Option<f64>,
    /// Throttle position, 0 to 100.
    pub throttle_pct: Option<f64>,
    /// 1.0 is stoichiometric.
    pub lambda: Option<f64>,
    /// Air to fuel ratio.
    pub afr: Option<f64>,
    /// Android Auto gets it in steps of 0.1 km.
    pub odometer_km: Option<f64>,
    pub odometer_trip_km: Option<f64>,
    /// Android Auto's driving restrictions as they are, 0 is none.
    pub driving_status: Option<u32>,
    pub ambient_lux: Option<f64>,
    /// The dimmer of the panel lights, 0 to 100.
    pub dimmer_pct: Option<f64>,
    /// Day or night for Android Auto and CarPlay, LIVI's own look follows `darkMode`. It sets the
    /// four below at once, those of them in the same push apply after it. LIVI's appearance
    /// setting at Day or Night sets it too. Any of the five turns that setting to Auto.
    pub night_mode: Option<bool>,
    /// Day or night for the UI on the main screen. Each of the four is saved as the setting of the
    /// same name and the phone starts with it. A map is never darker than its UI: a UI takes its
    /// map along, a dark map darkens its UI, and only a dark UI keeps a light map.
    pub main_ui_night_mode: Option<bool>,
    /// The map on the main screen, sent to the phone as its night mode.
    pub main_map_night_mode: Option<bool>,
    /// The UI on the cluster.
    pub cluster_ui_night_mode: Option<bool>,
    /// The map on the cluster.
    pub cluster_map_night_mode: Option<bool>,
    /// How carplay treats the four above, `auto`, `user` or `always`, saved as the setting of the
    /// same name, `user` when never set.
    pub appearance_setting: Option<String>,
    /// LIVI's own look, dark or light. A push sets the Dark Mode setting, a change of that
    /// setting shows up here.
    pub dark_mode: Option<bool>,
    /// A page such as `/media` or `/settings/devices`, LIVI's main screen opens it once each time
    /// it changes. A path that names no page is ignored. `/projection` brings the projection to the
    /// front on every push, and what follows asks the running CarPlay or Android Auto session to
    /// show that app: for CarPlay it is a `requestUI` URL (`/projection/maps`,
    /// `/projection/mobilephone`, `/projection/comgooglemaps://?daddr=…`), for Android Auto the
    /// known categories (maps, nowplaying, radio, mobilephone) map to its hard keys.
    pub path: Option<String>,
    /// The head unit's level, 0 to 1. It sets `huVolume`, which drives the amplifier and, while
    /// linked, the system mixer.
    pub volume: Option<f64>,
    /// Send the whole fix every time or only what the sensor delivers.
    pub gps: Option<GpsFix>,
    /// Only LIVI's own receiver sends it, a push replaces it whole.
    pub gnss: Option<GnssInfo>,
    pub tire_pressure: Option<TirePressure>,
    pub telltales: Option<Telltales>,
    pub dash_test: Option<bool>,
    /// No receiver uses it, it is for tooling and diagnostics.
    pub can: Option<CanFrame>,
    pub climate: Option<Climate>,
    /// 0 is off; the levels above it are not known.
    pub steering_wheel_heating: Option<u8>,
    /// 0 (off) to 3, as the front seats' in `climate`.
    pub rear_left_seat_heating: Option<u8>,
    pub rear_right_seat_heating: Option<u8>,
    /// The dashboard's climate key is held.
    pub climate_key: Option<bool>,
    pub notification: Option<Notification>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum TurnSignal {
    None,
    Left,
    Right,
}

/// A sensor may push one wheel at a time.
#[derive(Debug, Clone, Default, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct TirePressure {
    pub front_left_kpa: Option<f64>,
    pub front_right_kpa: Option<f64>,
    pub rear_left_kpa: Option<f64>,
    pub rear_right_kpa: Option<f64>,
}

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Telltales {
    pub brake: Option<bool>,
    pub seat_belt: Option<bool>,
    pub airbag: Option<bool>,
    pub side_airbag: Option<bool>,
    pub oil_pressure: Option<bool>,
    pub coolant: Option<bool>,
    pub charging: Option<bool>,
    pub abs: Option<bool>,
    pub esc: Option<bool>,
    pub tyre_pressure: Option<bool>,
    pub engine: Option<bool>,
    pub brake_wear: Option<bool>,
    pub preheat: Option<bool>,
    pub choke: Option<bool>,
    pub rear_fog: Option<bool>,
    pub passenger_airbag_off: Option<bool>,
    pub windscreen_defrost: Option<bool>,
    pub rear_defrost: Option<bool>,
    pub position: Option<bool>,
    pub parking_lamps: Option<bool>,
    pub front_fog: Option<bool>,
    pub auto_high_beam: Option<bool>,
}

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize)]
pub struct CanFrame {
    pub id: u32,
    pub data: Vec<u8>,
    pub bus: Option<u8>,
}

/// The car's climate as CarPlay shows it. Without a running session an outside source keeps it
/// current, a new session starts from it.
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Climate {
    /// Who set it last: `carplay` the phone, `external` a push that names no source, `saved` the
    /// last run, `default` LIVI's start values. Anything but `carplay` reaches the phone.
    pub source: Option<String>,
    pub on: Option<bool>,
    pub auto: Option<bool>,
    pub ac: Option<bool>,
    pub max_ac: Option<bool>,
    pub max_defrost: Option<bool>,
    pub recirculation: Option<bool>,
    /// The passenger side follows the driver's temperature.
    pub zones_synced: Option<bool>,
    /// 16 to 28 in steps of 0.5, the ends show as LO and HI.
    pub driver_target_c: Option<f64>,
    pub passenger_target_c: Option<f64>,
    /// Measured by the car.
    pub driver_cabin_c: Option<f64>,
    pub passenger_cabin_c: Option<f64>,
    /// 0 to 7, 0 is off.
    pub fan_level: Option<u8>,
    pub fan_auto: Option<bool>,
    /// 0 or 1.
    pub front_window_heating: Option<u8>,
    pub rear_window_heating: Option<u8>,
    pub vent_upper: Option<bool>,
    pub vent_middle: Option<bool>,
    pub vent_lower: Option<bool>,
    /// AUTO picks the vents.
    pub vents_auto: Option<bool>,
    /// 0 (off) to 3.
    pub driver_seat_heating: Option<u8>,
    pub passenger_seat_heating: Option<u8>,
}

/// A CarPlay notification. It lands in the notification center, and with
/// a matching theme installed also in the dashboard.
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Notification {
    pub title: Option<String>,
    pub text: Option<String>,
    /// An SF Symbol such as `snowflake`, or the name of a PNG in `~/.config/LIVI/carplay-images`
    /// such as `livi`. A PNG shows only once the phone fetched the folder, from the next CarPlay
    /// start and in practice only with a theme, else just SF Symbols work.
    pub symbol: Option<String>,
    /// True shows it, false closes it.
    pub open: Option<bool>,
}

#[cfg(test)]
mod tests {
    use serde_json::json;

    use super::*;

    #[test]
    fn fields_keep_the_names_producers_send() {
        let snapshot = TelemetrySnapshot {
            consumption_l_per100_km: Some(6.5),
            iat_c: Some(30.0),
            range_climate_off_km: Some(251.0),
            turn_signal: Some(TurnSignal::Left),
            can: Some(CanFrame {
                id: 1,
                data: vec![2],
                bus: None,
            }),
            tire_pressure: Some(TirePressure {
                rear_left_kpa: Some(230.0),
                ..Default::default()
            }),
            climate: Some(Climate {
                driver_target_c: Some(21.5),
                ..Default::default()
            }),
            dash_test: Some(true),
            driving_regulation_b: Some(true),
            door_passenger_open: Some(true),
            door_rear_left_locked: Some(false),
            charge_port_open: Some(true),
            aux_battery_pct: Some(87.0),
            charge_time_dc_custom_min: Some(42.0),
            range_at_charge_limit_ac_km: Some(410.0),
            climate_power_w: Some(1400.0),
            rear_right_seat_heating: Some(2),
            telltales: Some(Telltales {
                passenger_airbag_off: Some(true),
                ..Default::default()
            }),
            ..Default::default()
        };
        let named = serde_json::to_value(&snapshot).unwrap();
        assert_eq!(named["consumptionLPer100Km"], 6.5);
        assert_eq!(named["iatC"], 30.0);
        assert_eq!(named["rangeClimateOffKm"], 251.0);
        assert_eq!(named["turnSignal"], "left");
        assert_eq!(named["tirePressure"]["rearLeftKpa"], 230.0);
        assert_eq!(
            (&named["can"]["id"], &named["can"]["data"]),
            (&json!(1), &json!([2]))
        );
        assert_eq!(named["climate"]["driverTargetC"], 21.5);
        assert_eq!(named["telltales"]["passengerAirbagOff"], true);
        assert_eq!(named["dashTest"], true);
        // micom-livi's names (go-micomd cmd/micom-livi).
        for (name, want) in [
            ("drivingRegulationB", json!(true)),
            ("doorPassengerOpen", json!(true)),
            ("doorRearLeftLocked", json!(false)),
            ("chargePortOpen", json!(true)),
            ("auxBatteryPct", json!(87.0)),
            ("chargeTimeDcCustomMin", json!(42.0)),
            ("rangeAtChargeLimitAcKm", json!(410.0)),
            ("climatePowerW", json!(1400.0)),
            ("rearRightSeatHeating", json!(2)),
        ] {
            assert_eq!(named[name], want, "{name}");
        }
        let unknown = serde_json::from_value::<Climate>(json!({ "seatCooling": 1 }));
        assert!(
            unknown.is_err(),
            "a climate key the contract does not name is refused"
        );
    }
}
