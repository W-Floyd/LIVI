//! Whether the car is being driven, for the shell's lockouts (PLAN.md, "While driving"). Driving
//! is not being in Park, as NHTSA has it: a car stopped at a light is still driven.

use godot::prelude::*;
use serde_json::Value;

/// Parked signals must hold this long before the lockout lifts: a shuffle through P between R
/// and D does not flash the covers off.
pub const RELEASE_MS: u64 = 1500;
/// With speed alone, a lockout begins at this speed and lifts below `STOP_KPH`.
pub const START_KPH: f64 = 5.0;
pub const STOP_KPH: f64 = 1.0;
/// With speed alone, how long the car must stand before it counts as parked: it cannot tell a
/// light from a parking space.
pub const STOPPED_MS: u64 = 10_000;

/// The car's telemetry that decides it, as the core has it.
#[derive(Debug, Default, Clone, PartialEq)]
pub struct Inputs {
    pub regulation: Option<bool>,
    pub gear: Option<Value>,
    pub reverse: Option<bool>,
    pub speed_kph: Option<f64>,
    pub parking_brake: Option<bool>,
    pub ignition: Option<bool>,
}

impl Inputs {
    pub fn from_telemetry(t: &Value) -> Inputs {
        let b = |k: &str| t.get(k).and_then(Value::as_bool);
        Inputs {
            regulation: b("drivingRegulation"),
            gear: t.get("gear").filter(|g| !g.is_null()).cloned(),
            reverse: b("reverse"),
            speed_kph: t.get("speedKph").and_then(Value::as_f64),
            parking_brake: b("parkingBrake"),
            ignition: b("ignition"),
        }
    }
}

/// What a decision went by, strongest first.
#[derive(Debug, Default, Clone, Copy, PartialEq, Eq)]
pub enum Source {
    /// Nothing known: parked, as on a bench.
    #[default]
    None,
    Ignition,
    /// The car's own lockout signal (stock's video and keyboard lockout).
    Regulation,
    Gear,
    ParkingBrake,
    Speed,
}

impl Source {
    pub fn name(self) -> &'static str {
        match self {
            Source::None => "",
            Source::Ignition => "ignition",
            Source::Regulation => "regulation",
            Source::Gear => "gear",
            Source::ParkingBrake => "parking_brake",
            Source::Speed => "speed",
        }
    }
}

/// Driving as the signals say right now, and how long the opposite must hold to lift it.
fn signal(i: &Inputs, moving: bool) -> (bool, Source, u64) {
    let fast = |v: f64| v >= if moving { STOP_KPH } else { START_KPH };
    if i.ignition == Some(false) {
        return (false, Source::Ignition, 0);
    }
    if let Some(r) = i.regulation {
        return (r, Source::Regulation, RELEASE_MS);
    }
    if i.reverse == Some(true) {
        return (true, Source::Gear, RELEASE_MS);
    }
    // An automatic's letter; a manual's number has no Park, so speed decides for it.
    if let Some(g) = i.gear.as_ref().and_then(Value::as_str) {
        return (!g.eq_ignore_ascii_case("p"), Source::Gear, RELEASE_MS);
    }
    let speed = i.speed_kph.unwrap_or(0.0);
    if let Some(on) = i.parking_brake {
        return (!on || fast(speed), Source::ParkingBrake, RELEASE_MS);
    }
    if i.speed_kph.is_some() {
        return (fast(speed), Source::Speed, STOPPED_MS);
    }
    (false, Source::None, 0)
}

/// Driving with hysteresis: it starts at once, and lifts once parked has held for its time.
#[derive(Debug, Default)]
pub struct Driving {
    pub moving: bool,
    pub source: Source,
    parked_since: Option<u64>,
}

impl Driving {
    pub fn update(&mut self, i: &Inputs, now_ms: u64) -> bool {
        let (want, source, hold) = signal(i, self.moving);
        self.source = source;
        if want {
            self.moving = true;
            self.parked_since = None;
        } else if self.moving {
            let since = *self.parked_since.get_or_insert(now_ms);
            if now_ms.saturating_sub(since) >= hold {
                self.moving = false;
                self.parked_since = None;
            }
        }
        self.moving
    }
}

/// `Driving` for GDScript: `update` with the core's `/telemetry` and a clock in ms.
#[derive(GodotClass)]
#[class(init, base = RefCounted)]
pub struct DriveState {
    inner: Driving,
}

#[godot_api]
impl DriveState {
    #[func]
    fn update(&mut self, telemetry: Variant, now_ms: i64) -> bool {
        let t = if telemetry.is_nil() { Value::Null } else { crate::from_variant(&telemetry).unwrap_or(Value::Null) };
        self.inner.update(&Inputs::from_telemetry(&t), now_ms.max(0) as u64)
    }

    /// Parked signals are holding: updates must go on as time passes, push or not.
    #[func]
    fn pending(&self) -> bool {
        self.inner.parked_since.is_some()
    }

    /// What the last update went by: `regulation`, `gear`, `parking_brake`, `speed`,
    /// `ignition`, or "" for nothing known.
    #[func]
    fn source(&self) -> GString {
        GString::from(self.inner.source.name())
    }
}

#[cfg(test)]
mod tests {
    use serde_json::json;

    use super::*;

    #[test]
    fn driving_follows_the_strongest_signal_with_hysteresis() {
        // Each case: telemetry pushes in order, each at a time in ms, and driving after it.
        for (name, steps) in [
            ("nothing known is parked", vec![(json!({}), 0, false)]),
            ("the regulation wins over gear and speed", vec![
                (json!({ "drivingRegulation": true, "gear": "P", "speedKph": 0 }), 0, true),
                (json!({ "drivingRegulation": false, "gear": "D", "speedKph": 50 }), 100, true),
                (json!({ "drivingRegulation": false, "gear": "D", "speedKph": 50 }), 100 + RELEASE_MS, false),
            ]),
            ("out of Park is driving, stopped or not", vec![
                (json!({ "gear": "D", "speedKph": 0 }), 0, true),
                (json!({ "gear": "N" }), 60_000, true),
            ]),
            ("a shuffle through P keeps it", vec![
                (json!({ "gear": "R" }), 0, true),
                (json!({ "gear": "P" }), 100, true),
                (json!({ "gear": "D" }), 600, true),
                (json!({ "gear": "P" }), 700, true),
                (json!({ "gear": "p" }), 700 + RELEASE_MS, false),
            ]),
            ("reverse is driving whatever the gear says", vec![(json!({ "gear": "P", "reverse": true }), 0, true)]),
            ("ignition off parks at once", vec![
                (json!({ "gear": "D" }), 0, true),
                (json!({ "gear": "D", "ignition": false }), 10, false),
            ]),
            ("a manual's gear leaves it to the brake and speed", vec![
                (json!({ "gear": 0, "parkingBrake": false }), 0, true),
                (json!({ "gear": 0, "parkingBrake": true, "speedKph": 0 }), 10, true),
                (json!({ "gear": 0, "parkingBrake": true, "speedKph": 0 }), 10 + RELEASE_MS, false),
                (json!({ "gear": 1, "parkingBrake": true, "speedKph": 8 }), 5000, true),
            ]),
            ("speed alone starts above walking pace and stops after standing", vec![
                (json!({ "speedKph": 3 }), 0, false),
                (json!({ "speedKph": 6 }), 100, true),
                (json!({ "speedKph": 2 }), 200, true),
                (json!({ "speedKph": 0 }), 300, true),
                (json!({ "speedKph": 0 }), 300 + STOPPED_MS - 1, true),
                (json!({ "speedKph": 0.5 }), 300 + STOPPED_MS, false),
                (json!({ "speedKph": 4 }), 20_000, false),
            ]),
            ("moving again restarts the wait", vec![
                (json!({ "speedKph": 30 }), 0, true),
                (json!({ "speedKph": 0 }), 1000, true),
                (json!({ "speedKph": 2 }), 5000, true),
                (json!({ "speedKph": 0 }), 6000, true),
                (json!({ "speedKph": 0 }), 1000 + STOPPED_MS, true),
                (json!({ "speedKph": 0 }), 6000 + STOPPED_MS, false),
            ]),
        ] {
            let mut d = Driving::default();
            for (i, (t, at, want)) in steps.into_iter().enumerate() {
                assert_eq!(d.update(&Inputs::from_telemetry(&t), at), want, "{name}: step {i}, {t} at {at} ms ({:?})", d.source);
            }
        }
    }
}
