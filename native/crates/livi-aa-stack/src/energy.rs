// SPDX-FileCopyrightText: 2025-2026 Lasse Heitgres
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms: see NOTICE

//! Android Auto's vehicle energy model, sensor 23, which Google Maps plans electric routes with.
//! The layout and what is known of each field: `vehicle_energy.proto`.

use livi_aa_proto::{
    BatteryConfig, ChargePowerLimits, ChargeTimePoint, ChargeTimeTable, ChargeTimes, ChargingPrefs,
    EnergyPower, Quantity, RoadLoad, Scalar, VehicleEnergyModel,
};

/// The share of a charger's output the battery keeps, the rest heats cables and converters.
/// An estimate: evkx.net times its charging curves with it.
pub const CHARGE_EFFICIENCY: f64 = 0.95;

/// Every known model holds back 2.4 to 3.8 % of the capacity below the gauge's zero.
const RESERVE_SHARE: f64 = 0.03;

/// Maps keys its charge times by the charger's power, so each class a route may pass gets a row.
const DC_CHARGERS_KW: [f64; 8] = [350.0, 250.0, 200.0, 150.0, 120.0, 100.0, 50.0, 25.0];
const AC_CHARGERS_KW: [f64; 5] = [22.0, 11.0, 7.4, 3.7, 1.4];

/// Where the charge-time rows have a point, in % of the charge: coarse where charging is fast,
/// fine near full where it slows.
const TABLE_SOC: [f64; 29] = [
    0.0, 5.0, 10.0, 15.0, 20.0, 25.0, 30.0, 35.0, 40.0, 45.0, 50.0, 55.0, 60.0, 65.0, 70.0, 75.0,
    80.0, 85.0, 90.0, 91.0, 92.0, 93.0, 94.0, 95.0, 96.0, 97.0, 98.0, 99.0, 99.5,
];
const STEP_PCT: f64 = 0.1;

#[derive(Debug, Clone, PartialEq)]
pub struct EnergyModel {
    pub current_wh: i64,
    pub capacity_wh: i64,
    pub outside_c: Option<f64>,
    pub air_density_kg_per_m3: f64,
    pub max_charge_power_w: Option<i64>,
    pub max_discharge_power_w: Option<i64>,
    pub max_ac_power_w: Option<i64>,
    /// A in N, B in N/(m/s), C in N/(m/s)².
    pub road_load: Option<[f64; 3]>,
    /// `[state of charge %, kW]`, the fastest DC charging at each level as a charger reports it.
    pub charge_curve: Vec<[f64; 2]>,
}

/// What LIVI sent as the road load before a car could have its own: Wh per km off the range as A,
/// and Maps' own demo values near B and C. Wrong in kind, yet Maps plans routes with it.
pub fn road_load_from_range(current_wh: i64, range_m: i64) -> Option<[f64; 3]> {
    (current_wh > 0 && range_m > 0)
        .then(|| [current_wh as f64 / range_m as f64 * 1000.0, 2.0, 0.36])
}

/// The points that make sense, by state of charge.
fn curve(points: &[[f64; 2]]) -> Vec<[f64; 2]> {
    let mut c: Vec<[f64; 2]> = points
        .iter()
        .copied()
        .filter(|[soc, kw]| {
            soc.is_finite() && (0.0..=100.0).contains(soc) && kw.is_finite() && *kw > 0.0
        })
        .collect();
    c.sort_by(|a, b| a[0].total_cmp(&b[0]));
    c.dedup_by(|b, a| a[0] == b[0]);
    c
}

/// kW at `soc`, linear between the points and flat beyond the ends.
fn kw_at(curve: &[[f64; 2]], soc: f64) -> f64 {
    let (Some(first), Some(last)) = (curve.first(), curve.last()) else {
        return 0.0;
    };
    if soc <= first[0] {
        return first[1];
    }
    if soc >= last[0] {
        return last[1];
    }
    let i = curve.partition_point(|p| p[0] <= soc);
    let ([s0, k0], [s1, k1]) = (curve[i - 1], curve[i]);
    k0 + (k1 - k0) * (soc - s0) / (s1 - s0)
}

/// Seconds from each of `TABLE_SOC` to full, with `kw(soc)` coming out of the charger.
fn seconds_to_full(capacity_wh: f64, kw: impl Fn(f64) -> f64) -> Option<Vec<f64>> {
    let steps = (100.0 / STEP_PCT).round() as usize;
    let wh_per_step = capacity_wh * STEP_PCT / 100.0;
    let mut from = vec![0.0; steps + 1];
    for i in (0..steps).rev() {
        let w = kw((i as f64 + 0.5) * STEP_PCT) * 1000.0 * CHARGE_EFFICIENCY;
        if w.is_nan() || w <= 0.0 {
            return None;
        }
        from[i] = from[i + 1] + wh_per_step * 3600.0 / w;
    }
    Some(
        TABLE_SOC
            .iter()
            .map(|soc| {
                let at = soc / STEP_PCT;
                let (lo, hi) = (at.floor() as usize, at.ceil() as usize);
                from[lo] + (from[hi] - from[lo]) * (at - lo as f64)
            })
            .collect(),
    )
}

fn table(capacity_wh: f64, charger_kw: f64, kw: impl Fn(f64) -> f64) -> Option<ChargeTimeTable> {
    let seconds = seconds_to_full(capacity_wh, kw)?;
    Some(ChargeTimeTable {
        charger_power_w: Some((charger_kw * 1000.0).round() as i32),
        points: TABLE_SOC
            .iter()
            .zip(seconds)
            .map(|(soc, s)| ChargeTimePoint {
                to_full_wh: Some((capacity_wh * (100.0 - soc) / 100.0).round() as i32),
                to_full_s: Some(s.round() as i32),
            })
            .collect(),
    })
}

/// One row per charger class: DC rows follow the curve, capped by the charger, AC rows by the
/// smaller of the charger and the car's onboard charger.
pub fn charge_times(
    capacity_wh: i64,
    max_ac_power_w: Option<i64>,
    points: &[[f64; 2]],
) -> ChargeTimes {
    let cap = capacity_wh as f64;
    let curve = curve(points);
    let mut rows = Vec::new();
    if !curve.is_empty() {
        for charger in DC_CHARGERS_KW {
            rows.extend(table(cap, charger, |soc| kw_at(&curve, soc).min(charger)));
        }
    }
    if let Some(ac_kw) = max_ac_power_w
        .map(|w| w as f64 / 1000.0)
        .filter(|kw| *kw > 0.0)
    {
        for charger in AC_CHARGERS_KW {
            let limit = charger.min(ac_kw);
            rows.extend(table(cap, charger, |soc| {
                if curve.is_empty() {
                    limit
                } else {
                    kw_at(&curve, soc).min(limit)
                }
            }));
        }
    }
    ChargeTimes {
        by_charger_power: rows,
    }
}

fn charge_limits(capacity_wh: i64, points: &[[f64; 2]]) -> ChargePowerLimits {
    ChargePowerLimits {
        max_charge_power: curve(points)
            .iter()
            .map(|[soc, kw]| EnergyPower {
                energy_wh: Some((capacity_wh as f64 * soc / 100.0).round() as i32),
                power_w: Some((kw * 1000.0).round() as u32),
            })
            .collect(),
    }
}

pub fn model(m: &EnergyModel) -> Option<VehicleEnergyModel> {
    if m.capacity_wh <= 0 || m.current_wh <= 0 || m.capacity_wh > i64::from(i32::MAX) {
        return None;
    }
    let wh = |v: i64| Quantity {
        value: Some(v.clamp(0, i64::from(i32::MAX)) as i32),
    };
    let watts = |w: Option<i64>| {
        w.filter(|w| *w > 0)
            .map(|w| w.min(i64::from(u32::MAX)) as u32)
    };
    let scalar = |v: f64| Scalar {
        value: Some(v as f32),
    };
    let limits = charge_limits(m.capacity_wh, &m.charge_curve);
    let times = charge_times(m.capacity_wh, m.max_ac_power_w, &m.charge_curve);
    Some(VehicleEnergyModel {
        battery: Some(BatteryConfig {
            config_id: Some(1),
            reserve_wh: Some(wh((m.capacity_wh as f64 * RESERVE_SHARE).round() as i64)),
            current_wh: Some(wh(m.current_wh)),
            capacity_wh: Some(wh(m.capacity_wh)),
            air_density_kg_per_m3: Some(m.air_density_kg_per_m3 as f32),
            outside_temperature_c: m.outside_c.filter(|c| c.is_finite()).map(|c| c as f32),
            max_charge_power_w: watts(m.max_charge_power_w),
            max_discharge_power_w: watts(m.max_discharge_power_w),
            regen_braking_capable: Some(true),
        }),
        road_load: m
            .road_load
            .filter(|abc| abc.iter().all(|v| v.is_finite()))
            .map(|[a, b, c]| RoadLoad {
                a_n: Some(scalar(a)),
                b_n_per_mps: Some(scalar(b)),
                c_n_per_mps2: Some(scalar(c)),
            }),
        charge_limits: (!limits.max_charge_power.is_empty()).then_some(limits),
        charge_times: (!times.by_charger_power.is_empty()).then_some(times),
        charging_prefs: Some(ChargingPrefs { mode: Some(1) }),
    })
}

#[cfg(test)]
mod tests {
    use prost::Message;

    use super::*;

    fn ev(curve: Vec<[f64; 2]>) -> EnergyModel {
        EnergyModel {
            current_wh: 37_000,
            capacity_wh: 74_000,
            outside_c: Some(-5.5),
            air_density_kg_per_m3: 1.225,
            max_charge_power_w: Some(240_000),
            max_discharge_power_w: None,
            max_ac_power_w: Some(10_900),
            road_load: Some([106.7, 2.278, 0.4655]),
            charge_curve: curve,
        }
    }

    /// Tag bytes of the fields present, in order.
    fn tags(mut bytes: &[u8]) -> Vec<u32> {
        let mut out = Vec::new();
        while !bytes.is_empty() {
            let key = prost::encoding::decode_varint(&mut bytes).unwrap();
            let (field, wire) = ((key >> 3) as u32, key & 7);
            out.push(field);
            match wire {
                0 => {
                    prost::encoding::decode_varint(&mut bytes).unwrap();
                }
                2 => {
                    let len = prost::encoding::decode_varint(&mut bytes).unwrap() as usize;
                    bytes = &bytes[len..];
                }
                5 => bytes = &bytes[4..],
                _ => panic!("wire type {wire}"),
            }
        }
        out
    }

    #[test]
    fn the_model_lands_on_the_fields_maps_reads() {
        let m = model(&ev(vec![[0.0, 200.0], [50.0, 200.0], [100.0, 20.0]])).unwrap();
        let bytes = m.encode_to_vec();
        assert_eq!(tags(&bytes), [1, 2, 4, 8, 12]);
        let battery = m.battery.as_ref().unwrap().encode_to_vec();
        assert_eq!(tags(&battery), [1, 2, 3, 4, 6, 7, 9, 11]);
        assert_eq!(battery[..2], [0x08, 0x01]);
        assert_eq!(
            battery[2..6],
            [0x12, 0x03, 0x08, 0xac],
            "reserve, 2220 Wh as field 2.1"
        );
        assert_eq!(&battery[battery.len() - 2..], [0x58, 0x01]);

        let back = VehicleEnergyModel::decode(bytes.as_slice()).unwrap();
        let b = back.battery.unwrap();
        assert_eq!(b.reserve_wh.unwrap().value, Some(2220));
        assert_eq!(b.current_wh.unwrap().value, Some(37_000));
        assert_eq!(b.capacity_wh.unwrap().value, Some(74_000));
        assert_eq!(b.outside_temperature_c, Some(-5.5));
        assert_eq!(b.max_charge_power_w, Some(240_000));
        assert_eq!(b.max_discharge_power_w, None);
        let road = back.road_load.unwrap();
        assert_eq!(road.a_n.unwrap().value, Some(106.7));
        assert_eq!(road.c_n_per_mps2.unwrap().value, Some(0.4655));
        let limits = back.charge_limits.unwrap().max_charge_power;
        assert_eq!(
            limits
                .iter()
                .map(|p| (p.energy_wh.unwrap(), p.power_w.unwrap()))
                .collect::<Vec<_>>(),
            [(0, 200_000), (37_000, 200_000), (74_000, 20_000)]
        );
        assert_eq!(
            back.charge_times.unwrap().by_charger_power.len(),
            DC_CHARGERS_KW.len() + AC_CHARGERS_KW.len()
        );
    }

    #[test]
    fn no_model_without_energy_and_no_tables_without_a_curve() {
        assert_eq!(
            model(&EnergyModel {
                current_wh: 0,
                ..ev(Vec::new())
            }),
            None
        );
        assert_eq!(
            model(&EnergyModel {
                capacity_wh: 0,
                ..ev(Vec::new())
            }),
            None
        );
        let bare = model(&EnergyModel {
            outside_c: None,
            max_charge_power_w: None,
            max_ac_power_w: None,
            road_load: None,
            ..ev(vec![[10.0, f64::NAN], [120.0, 50.0]])
        })
        .unwrap();
        assert_eq!(tags(&bare.encode_to_vec()), [1, 12]);
        assert_eq!(
            tags(&bare.battery.unwrap().encode_to_vec()),
            [1, 2, 3, 4, 6, 11]
        );
    }

    #[test]
    fn charge_times_integrate_the_curve_capped_by_the_charger() {
        let times = charge_times(50_000, Some(11_000), &[[0.0, 100.0], [100.0, 100.0]]);
        let row = |kw: f64| {
            times
                .by_charger_power
                .iter()
                .find(|r| r.charger_power_w == Some((kw * 1000.0) as i32))
                .unwrap()
        };
        let to_full = |r: &ChargeTimeTable| {
            r.points
                .iter()
                .map(|p| (p.to_full_wh.unwrap(), p.to_full_s.unwrap()))
                .collect::<Vec<_>>()
        };
        for (kw, takes) in [(350.0, 100.0), (50.0, 50.0), (22.0, 11.0), (7.4, 7.4)] {
            let points = to_full(row(kw));
            assert_eq!(points.len(), TABLE_SOC.len());
            assert_eq!(points[0].0, 50_000);
            assert_eq!(points.last().unwrap().0, 250);
            let empty = 50_000.0 * 3600.0 / (takes * 1000.0 * CHARGE_EFFICIENCY);
            assert!((f64::from(points[0].1) - empty).abs() <= 1.0, "{kw} kW");
            assert!(
                points
                    .windows(2)
                    .all(|w| w[0].0 > w[1].0 && w[0].1 > w[1].1)
            );
        }

        let tapering = charge_times(74_000, None, &[[50.0, 200.0], [100.0, 20.0], [0.0, 200.0]]);
        let last_half = |r: &ChargeTimeTable| r.points[10].to_full_s.unwrap();
        let fast = last_half(&tapering.by_charger_power[0]);
        // 37 kWh over 200 → 20 kW, mean of 1/P for a linear fall: ln(10)/180 per kW.
        let expect = 37_000.0 * 3600.0 / (1000.0 * CHARGE_EFFICIENCY) * (10f64.ln() / 180.0);
        assert!(
            (f64::from(fast) - expect).abs() < expect * 0.001,
            "{fast} vs {expect}"
        );
        assert_eq!(tapering.by_charger_power.len(), DC_CHARGERS_KW.len());
    }
}
