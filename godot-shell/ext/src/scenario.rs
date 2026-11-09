//! Scenario files: YAML read into JSON, which GDScript parses into its own types.

use serde_json::Value;

pub fn yaml_to_json(text: &str) -> Result<Value, String> {
    serde_norway::from_str(text).map_err(|e| e.to_string())
}

/// `PreconditionBattery: { on: true }` as written in a scenario, to the wire's
/// `{ "kind": "preconditionBattery", "on": true }`.
pub fn action_from_scenario(v: &Value) -> Result<Value, String> {
    let obj = v.as_object().filter(|o| o.len() == 1).ok_or("an action is one `Name: {fields}`")?;
    let (name, fields) = obj.iter().next().ok_or("empty action")?;
    let mut kind = name.clone();
    if let Some(first) = kind.get(..1) {
        kind.replace_range(..1, &first.to_lowercase());
    }
    let mut out = match fields {
        Value::Object(f) => f.clone(),
        Value::Null => Default::default(),
        _ => return Err(format!("{name}: fields must be a map")),
    };
    out.insert("kind".into(), Value::String(kind));
    Ok(Value::Object(out))
}

/// Whether every field in `want` is in `got` with the same value; arrays match element-wise.
pub fn subset(want: &Value, got: &Value) -> bool {
    match (want, got) {
        (Value::Object(w), Value::Object(g)) => {
            w.iter().all(|(k, w)| g.get(k).is_some_and(|g| subset(w, g)))
        }
        (Value::Array(w), Value::Array(g)) => {
            w.len() == g.len() && w.iter().zip(g).all(|(w, g)| subset(w, g))
        }
        (Value::Number(w), Value::Number(g)) => w.as_f64() == g.as_f64(),
        (w, g) => w == g,
    }
}

#[cfg(test)]
mod tests {
    use serde_json::json;

    use super::*;

    #[test]
    fn actions_from_scenarios() {
        let cases = [
            (
                json!({ "PreconditionBattery": { "on": true } }),
                Ok(json!({ "kind": "preconditionBattery", "on": true })),
            ),
            (json!({ "Quit": null }), Ok(json!({ "kind": "quit" }))),
            (json!({ "A": {}, "B": {} }), Err(())),
            (json!({ "Quit": 3 }), Err(())),
        ];
        for (input, want) in cases {
            assert_eq!(action_from_scenario(&input).map_err(|_| ()), want, "{input}");
        }
    }

    #[test]
    fn subsets() {
        let got = json!({ "kind": "pointer", "screen": "main", "points": [{ "x": 0.5, "y": 1 }] });
        let cases = [
            (json!({ "kind": "pointer" }), true),
            (json!({ "points": [{ "y": 1.0 }] }), true),
            (json!({ "points": [{ "y": 0.9 }] }), false),
            (json!({ "points": [] }), false),
            (json!({ "screen": "aux" }), false),
            (json!({ "missing": 1 }), false),
        ];
        for (want, ok) in cases {
            assert_eq!(subset(&want, &got), ok, "{want}");
        }
    }

    #[test]
    fn yaml_reads_flow_and_block_maps() {
        let v = yaml_to_json("name: x\nsteps:\n  - wait: { frames: 3 }\n").unwrap();
        assert_eq!(v, json!({ "name": "x", "steps": [{ "wait": { "frames": 3 } }] }));
    }
}
