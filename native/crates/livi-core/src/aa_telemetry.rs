// SPDX-FileCopyrightText: 2025-2026 Lasse Heitgres
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms: see NOTICE

use livi_aa_stack::energy::{self, EnergyModel};
use livi_aa_stack::manager::{AaCmd, AaHandle};
use livi_aa_stack::sensors::{GpsFix, Sensor};
use livi_core_proto::config::Config;
use serde_json::{Map, Value};
use tokio::time::Instant;

const ENERGY_MODEL_EVERY: std::time::Duration = std::time::Duration::from_secs(10);

/// Dry air: p / (R·T) with R = 287.05 J/(kg·K), and the standard atmosphere's sea level.
const AIR_GAS_CONSTANT: f64 = 287.05;
const SEA_LEVEL_KPA: f64 = 101.325;
const STANDARD_AIR_DENSITY: f64 = 1.225;

pub const LOW_FUEL_PCT: f64 = 10.0;

pub const REVERSE: i64 = 102;

const TIRE_PRESSURE: &str = "tirePressure";
const WHEELS: [&str; 4] = [
    "frontLeftKpa",
    "frontRightKpa",
    "rearLeftKpa",
    "rearRightKpa",
];

pub fn gear(gear: Option<&Value>, reverse: Option<bool>) -> Option<i64> {
    match gear {
        Some(Value::Number(n)) => match n.as_f64() {
            Some(-1.0) => return Some(REVERSE),
            Some(0.0) => return Some(0),
            Some(g) if (1.0..=10.0).contains(&g) && g.fract() == 0.0 => return Some(g as i64),
            _ => {}
        },
        Some(Value::String(s)) => {
            let g = s.trim().to_uppercase();
            match g.as_str() {
                "P" => return Some(101),
                "R" => return Some(REVERSE),
                "N" => return Some(0),
                "D" | "S" => return Some(100),
                _ => {}
            }
            if let Some(n) = g.strip_prefix('M').filter(|d| (1..=2).contains(&d.len()))
                && n.bytes().all(|b| b.is_ascii_digit())
                && let Ok(n) = n.parse::<i64>()
                && (1..=10).contains(&n)
            {
                return Some(n);
            }
        }
        _ => {}
    }
    (reverse == Some(true)).then_some(REVERSE)
}

fn round(v: f64) -> i64 {
    (v + 0.5).floor() as i64
}

fn num(map: &Map<String, Value>, key: &str) -> Option<f64> {
    map.get(key).and_then(Value::as_f64)
}

fn flag(map: &Map<String, Value>, key: &str) -> Option<bool> {
    map.get(key).and_then(Value::as_bool)
}

#[derive(Default)]
struct Sent {
    speed_mm_s: Option<i32>,
    rpm_e3: Option<i32>,
    gear: Option<i64>,
    night_mode: Option<bool>,
    parking_brake: Option<bool>,
    driving_status: Option<i64>,
    lights: Option<(Option<i32>, Option<i32>, Option<bool>)>,
    fuel: Option<(i32, Option<i32>, Option<bool>)>,
    odometer: Option<(i32, Option<i32>)>,
    environment: Option<(Option<i32>, Option<i32>)>,
    tire_pressure: Option<[i32; 4]>,
    gps: Option<GpsFix>,
    energy_model_at: Option<Instant>,
}

/// What the energy model takes from the settings rather than the car's telemetry.
#[derive(Default)]
struct EnergySetup {
    road_load: Option<[f64; 3]>,
    charge_curve: Vec<[f64; 2]>,
    max_dc_kw: Option<f64>,
    max_ac_kw: Option<f64>,
    max_discharge_kw: Option<f64>,
}

#[derive(Default)]
pub struct AaTelemetry {
    sent: Sent,
    energy: EnergySetup,
}

fn air_density(next: &Map<String, Value>) -> f64 {
    let Some(c) = num(next, "ambientC").filter(|c| c.is_finite() && *c > -100.0) else {
        return STANDARD_AIR_DENSITY;
    };
    let kpa = num(next, "baroKpa")
        .filter(|p| (50.0..=110.0).contains(p))
        .unwrap_or(SEA_LEVEL_KPA);
    kpa * 1000.0 / (AIR_GAS_CONSTANT * (c + 273.15))
}

fn watts(kw: Option<f64>) -> Option<i64> {
    kw.filter(|kw| kw.is_finite() && *kw > 0.0)
        .map(|kw| round(kw * 1000.0))
}

impl AaTelemetry {
    pub fn configure(&mut self, cfg: &Config) {
        self.energy = EnergySetup {
            road_load: cfg
                .ev_road_load
                .map(|r| [r.a_n, r.b_n_per_mps, r.c_n_per_mps2]),
            charge_curve: cfg.ev_charge_curve.clone().unwrap_or_default(),
            max_dc_kw: cfg.ev_max_dc_power_kw,
            max_ac_kw: cfg.ev_max_ac_power_kw,
            max_discharge_kw: cfg.ev_max_discharge_power_kw,
        };
    }

    fn energy_model(&self, next: &Map<String, Value>) -> Option<EnergyModel> {
        let level_kwh = num(next, "batteryLevelKwh").filter(|l| *l > 0.0)?;
        let capacity_kwh = num(next, "batteryUsableKwh")
            .filter(|c| *c > 0.0)
            .or_else(|| num(next, "batteryCapacityKwh"))
            .filter(|c| *c > 0.0)?;
        let current_wh = round(level_kwh * 1000.0);
        let e = &self.energy;
        let road_load = e.road_load.or_else(|| {
            let range_km = num(next, "rangeKm")?;
            energy::road_load_from_range(current_wh, round(range_km * 1000.0))
        });
        Some(EnergyModel {
            current_wh,
            capacity_wh: round(capacity_kwh * 1000.0),
            outside_c: num(next, "ambientC").filter(|c| c.is_finite()),
            air_density_kg_per_m3: air_density(next),
            max_charge_power_w: watts(e.max_dc_kw),
            max_discharge_power_w: watts(e.max_discharge_kw),
            max_ac_power_w: watts(e.max_ac_kw),
            road_load,
            charge_curve: e.charge_curve.clone(),
        })
    }

    pub fn hydrate(&mut self, snap: &Map<String, Value>, aa: &AaHandle) {
        self.sent = Sent::default();
        if !snap.is_empty() {
            self.follow(&Map::new(), snap, aa);
        }
    }

    pub fn follow(&mut self, prev: &Map<String, Value>, next: &Map<String, Value>, aa: &AaHandle) {
        for sensor in self.sensors(prev, next, Instant::now()) {
            aa.send(AaCmd::Sensor(sensor));
        }
    }

    fn sensors(
        &mut self,
        prev: &Map<String, Value>,
        next: &Map<String, Value>,
        now: Instant,
    ) -> Vec<Sensor> {
        let changed = |key: &str| next.contains_key(key) && prev.get(key) != next.get(key);
        let sent = &mut self.sent;
        let mut out = Vec::new();

        if changed("speedKph")
            && let Some(kph) = num(next, "speedKph")
        {
            let v = round(kph * 1000.0 / 3.6).max(0) as i32;
            if sent.speed_mm_s != Some(v) {
                sent.speed_mm_s = Some(v);
                out.push(Sensor::Speed(v));
            }
        }
        if changed("rpm")
            && let Some(rpm) = num(next, "rpm")
        {
            let v = round(rpm * 1000.0).max(0) as i32;
            if sent.rpm_e3 != Some(v) {
                sent.rpm_e3 = Some(v);
                out.push(Sensor::Rpm(v));
            }
        }
        if (changed("gear") || changed("reverse"))
            && let Some(g) = gear(next.get("gear"), flag(next, "reverse"))
            && sent.gear != Some(g)
        {
            sent.gear = Some(g);
            out.push(Sensor::Gear(g as i32));
        }
        if changed("nightMode")
            && let Some(night) = flag(next, "nightMode")
            && sent.night_mode != Some(night)
        {
            sent.night_mode = Some(night);
            out.push(Sensor::NightMode(night));
        }
        if changed("parkingBrake")
            && let Some(on) = flag(next, "parkingBrake")
            && sent.parking_brake != Some(on)
        {
            sent.parking_brake = Some(on);
            out.push(Sensor::ParkingBrake(on));
        }
        if changed("drivingStatus")
            && let Some(status) = num(next, "drivingStatus")
            && sent.driving_status != Some(status as i64)
        {
            sent.driving_status = Some(status as i64);
            out.push(Sensor::DrivingStatus(status as i32));
        }

        if ["lights", "highBeam", "hazards", "turnSignal"]
            .iter()
            .any(|k| changed(k))
        {
            let head = if flag(next, "highBeam") == Some(true) {
                Some(3)
            } else {
                flag(next, "lights").map(|on| if on { 2 } else { 1 })
            };
            let turn = match next.get("turnSignal").and_then(Value::as_str) {
                Some("left") => Some(2),
                Some("right") => Some(3),
                Some("none") => Some(1),
                _ => None,
            };
            let hazards = flag(next, "hazards");
            let lights = (head, turn, hazards);
            if sent.lights.unwrap_or_default() != lights {
                sent.lights = Some(lights);
                out.push(Sensor::Light {
                    head_light: head,
                    hazard_lights: hazards,
                    turn_indicator: turn,
                });
            }
        }

        if (changed("fuelPct") || changed("rangeKm"))
            && let Some(pct) = num(next, "fuelPct")
        {
            let level = round(pct).clamp(0, 100) as i32;
            let range = num(next, "rangeKm").map(|km| round(km).max(0) as i32);
            let low = Some(pct < LOW_FUEL_PCT);
            if sent.fuel != Some((level, range, low)) {
                sent.fuel = Some((level, range, low));
                out.push(Sensor::Fuel {
                    level_percent: level,
                    range_km: range,
                    low_fuel_warning: low,
                });
            }
        }

        if (changed("odometerKm") || changed("odometerTripKm"))
            && let Some(km) = num(next, "odometerKm")
        {
            let total = round(km * 10.0) as i32;
            let trip = num(next, "odometerTripKm").map(|t| round(t * 10.0) as i32);
            if sent.odometer != Some((total, trip)) {
                sent.odometer = Some((total, trip));
                out.push(Sensor::Odometer {
                    total_km_e1: total,
                    trip_km_e1: trip,
                });
            }
        }

        if changed("ambientC") || changed("baroKpa") {
            let temp = num(next, "ambientC").map(|c| round(c * 1000.0) as i32);
            let pressure = num(next, "baroKpa").map(|k| round(k * 1000.0) as i32);
            if sent.environment.unwrap_or_default() != (temp, pressure) {
                sent.environment = Some((temp, pressure));
                out.push(Sensor::Environment {
                    temperature_e3: temp,
                    pressure_e3: pressure,
                });
            }
        }

        if changed(TIRE_PRESSURE)
            && let Some(tires) = next.get(TIRE_PRESSURE).and_then(Value::as_object)
            && let [Some(fl), Some(fr), Some(rl), Some(rr)] =
                WHEELS.map(|w| num(tires, w).map(|kpa| round(kpa.max(0.0) * 100.0) as i32))
        {
            let pressures = [fl, fr, rl, rr];
            if sent.tire_pressure != Some(pressures) {
                sent.tire_pressure = Some(pressures);
                out.push(Sensor::TirePressure(pressures));
            }
        }

        if changed("gps")
            && let Some(gps) = next.get("gps").and_then(Value::as_object)
            && let (Some(lat), Some(lng)) = (num(gps, "lat"), num(gps, "lng"))
        {
            let fix = GpsFix {
                lat_deg: lat,
                lng_deg: lng,
                accuracy_m: num(gps, "accuracyM"),
                altitude_m: num(gps, "alt"),
                speed_ms: num(gps, "speedMs"),
                bearing_deg: num(gps, "heading"),
            };
            if sent.gps != Some(fix) {
                sent.gps = Some(fix);
                out.push(Sensor::Gps(fix));
            }
        }

        if sent
            .energy_model_at
            .is_none_or(|at| now.duration_since(at) >= ENERGY_MODEL_EVERY)
            && let Some(model) = self.energy_model(next)
        {
            out.push(Sensor::VehicleEnergyModel(Box::new(model)));
            self.sent.energy_model_at = Some(now);
        }
        out
    }
}

#[cfg(test)]
mod tests {
    use livi_core_proto::config::EvRoadLoad;
    use serde_json::json;

    use super::*;

    fn map(v: Value) -> Map<String, Value> {
        v.as_object().cloned().unwrap()
    }

    #[test]
    fn gears_read_as_the_phone_counts_them() {
        assert_eq!(gear(Some(&json!(-1)), None), Some(102));
        assert_eq!(gear(Some(&json!(0)), None), Some(0));
        assert_eq!(gear(Some(&json!(4)), None), Some(4));
        assert_eq!(gear(Some(&json!(11)), None), None);
        assert_eq!(gear(Some(&json!(" p ")), None), Some(101));
        assert_eq!(gear(Some(&json!("D")), None), Some(100));
        assert_eq!(gear(Some(&json!("S")), None), Some(100));
        assert_eq!(gear(Some(&json!("M3")), None), Some(3));
        assert_eq!(gear(Some(&json!("M11")), None), None);
        assert_eq!(gear(Some(&json!("M123")), None), None);
        assert_eq!(gear(Some(&json!("x")), Some(true)), Some(102));
        assert_eq!(gear(None, None), None);
    }

    #[test]
    fn only_what_the_phone_would_see_differently_goes_out() {
        let mut t = AaTelemetry::default();
        let now = Instant::now();
        let first = map(json!({ "speedKph": 73.4, "rpm": 2.5, "gear": "D", "nightMode": true }));
        let sent = t.sensors(&Map::new(), &first, now);
        assert_eq!(
            sent,
            [
                Sensor::Speed(20_389),
                Sensor::Rpm(2500),
                Sensor::Gear(100),
                Sensor::NightMode(true),
            ]
        );
        let tick = map(json!({ "speedKph": 73.40001, "rpm": 2.5, "gear": "D", "nightMode": true }));
        assert!(t.sensors(&first, &tick, now).is_empty());
    }

    #[test]
    fn tire_pressures_wait_for_all_four_wheels() {
        let mut t = AaTelemetry::default();
        let now = Instant::now();
        let three = map(json!({ "tirePressure": {
            "frontLeftKpa": 240, "frontRightKpa": 245, "rearLeftKpa": 230
        } }));
        assert!(
            t.sensors(&Map::new(), &three, now).is_empty(),
            "no wheel may shift its place"
        );
        let four = map(json!({ "tirePressure": {
            "frontLeftKpa": 240, "frontRightKpa": 245.004, "rearLeftKpa": 230, "rearRightKpa": -1
        } }));
        assert_eq!(
            t.sensors(&three, &four, now),
            [Sensor::TirePressure([24_000, 24_500, 23_000, 0])]
        );
        let same = map(json!({ "tirePressure": {
            "frontLeftKpa": 240, "frontRightKpa": 245, "rearLeftKpa": 230, "rearRightKpa": 0
        } }));
        assert!(t.sensors(&four, &same, now).is_empty());
    }

    #[test]
    fn bundles_carry_their_fields_together() {
        let mut t = AaTelemetry::default();
        let now = Instant::now();
        let snap = map(json!({
            "highBeam": true, "turnSignal": "left", "hazards": false,
            "fuelPct": 8.4, "rangeKm": 120.5,
            "odometerKm": 12345.67, "odometerTripKm": 12.34,
            "ambientC": -2.5, "baroKpa": 101.3,
            "gps": { "lat": 52.5, "lng": 13.4, "alt": 34.0, "speedMs": 3.0, "heading": 90.0 },
            "batteryCapacityKwh": 77.0
        }));
        let sent = t.sensors(&Map::new(), &snap, now);
        assert!(sent.contains(&Sensor::Light {
            head_light: Some(3),
            hazard_lights: Some(false),
            turn_indicator: Some(2)
        }));
        assert!(sent.contains(&Sensor::Fuel {
            level_percent: 8,
            range_km: Some(121),
            low_fuel_warning: Some(true)
        }));
        assert!(sent.contains(&Sensor::Odometer {
            total_km_e1: 123_457,
            trip_km_e1: Some(123)
        }));
        assert!(sent.contains(&Sensor::Environment {
            temperature_e3: Some(-2500),
            pressure_e3: Some(101_300)
        }));
        assert!(
            sent.iter()
                .any(|s| matches!(s, Sensor::Gps(f) if f.lat_deg == 52.5))
        );
        let model = |sent: Vec<Sensor>| {
            sent.into_iter().find_map(|s| match s {
                Sensor::VehicleEnergyModel(m) => Some(*m),
                _ => None,
            })
        };
        assert_eq!(model(sent), None, "no model without the battery's energy");

        let with_level = map(json!({
            "batteryCapacityKwh": 77.4, "rangeKm": 119.0, "batteryLevelKwh": 30.0, "ambientC": 15.0
        }));
        let first = model(t.sensors(&snap, &with_level, now)).unwrap();
        assert_eq!((first.current_wh, first.capacity_wh), (30_000, 77_400));
        assert_eq!(first.outside_c, Some(15.0));
        assert!((first.air_density_kg_per_m3 - 1.225).abs() < 0.001);
        assert_eq!(
            first.road_load,
            energy::road_load_from_range(30_000, 119_000),
            "without a configured road load, the one LIVI always sent"
        );
        assert_eq!(
            (first.max_charge_power_w, first.charge_curve.len()),
            (None, 0)
        );
        let lower = map(json!({ "batteryCapacityKwh": 77.4, "batteryLevelKwh": 29.0 }));
        assert_eq!(
            model(t.sensors(&with_level, &lower, now)),
            None,
            "not that often"
        );

        t.configure(&Config {
            ev_road_load: Some(EvRoadLoad {
                a_n: 106.7,
                b_n_per_mps: 2.278,
                c_n_per_mps2: 0.4655,
            }),
            ev_charge_curve: Some(vec![[1.0, 205.0], [100.0, 12.0]]),
            ev_max_dc_power_kw: Some(240.0),
            ev_max_ac_power_kw: Some(10.9),
            ..livi_core_proto::config::defaults()
        });
        let learned = map(json!({
            "batteryCapacityKwh": 77.4, "batteryUsableKwh": 74.0, "batteryLevelKwh": 29.0,
            "ambientC": -10.0, "baroKpa": 95.0
        }));
        let m = model(t.sensors(&lower, &learned, now + ENERGY_MODEL_EVERY)).unwrap();
        assert_eq!((m.current_wh, m.capacity_wh), (29_000, 74_000));
        assert_eq!(m.road_load, Some([106.7, 2.278, 0.4655]));
        assert_eq!(m.charge_curve, [[1.0, 205.0], [100.0, 12.0]]);
        assert_eq!(
            (
                m.max_charge_power_w,
                m.max_ac_power_w,
                m.max_discharge_power_w
            ),
            (Some(240_000), Some(10_900), None)
        );
        assert!((m.air_density_kg_per_m3 - 95_000.0 / (287.05 * 263.15)).abs() < 1e-9);
    }

    #[test]
    fn plain_lights_without_high_beam() {
        let mut t = AaTelemetry::default();
        let now = Instant::now();
        let off = t.sensors(
            &Map::new(),
            &map(json!({ "lights": false, "turnSignal": "none" })),
            now,
        );
        assert_eq!(
            off,
            [Sensor::Light {
                head_light: Some(1),
                hazard_lights: None,
                turn_indicator: Some(1)
            }]
        );
        let on = t.sensors(
            &Map::new(),
            &map(json!({ "lights": true, "turnSignal": "right" })),
            now,
        );
        assert_eq!(
            on,
            [Sensor::Light {
                head_light: Some(2),
                hazard_lights: None,
                turn_indicator: Some(3)
            }]
        );
    }
}
