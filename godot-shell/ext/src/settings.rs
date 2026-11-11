//! LIVI's settings as the stock UI has them (livi-ui-model's tree and view), driven from the
//! shell: a stack into the tree, the screen it shows as plain JSON for GDScript, and the core
//! messages each touch sends, as livi-ui's settings controller sends them.

use livi_core_proto::message::{Action, Radio as CoreRadio, ToCore};
use livi_ui_model::i18n::Strings;
use livi_ui_model::settings::custom::Watch;
use livi_ui_model::settings::node::Radio;
use livi_ui_model::settings::restart::{pending, sessions_open};
use livi_ui_model::settings::schema;
use livi_ui_model::settings::view::{Change, Dialog, Facts, Row, RowKind, Screen, Settings};
use serde_json::{Value, json};

/// Inline steppers stop here: past it, a number opens its own page with coarser steps.
/// What a touch sends the core: an action, or a message of its own (link speed).
#[derive(Debug, Clone, PartialEq)]
pub enum Out {
    Act(Action),
    Msg(ToCore),
}

const INLINE_STEPS: f64 = 60.0;

pub struct Controller {
    model: Settings,
    /// Into the tree; empty is the section list, `[section, ...]` below it.
    stack: Vec<usize>,
    strings: Strings,
    /// The config the phone sessions started with: a restart-only key differing from it waits
    /// for Apply.
    baseline: Option<Value>,
    rows: Vec<Row>,
    dialog: Option<Dialog>,
    dismissed: Option<String>,
    watching: Vec<Watch>,
}

impl Default for Controller {
    fn default() -> Self {
        Self::new()
    }
}

impl Controller {
    pub fn new() -> Self {
        Self {
            model: Settings::new(schema()).with_facts(Facts {
                name: "LIVI".into(),
                source: "https://github.com/f-io/LIVI".into(),
                license: "GPL-3.0-or-later".into(),
                version: env!("CARGO_PKG_VERSION").into(),
                sha: "dev".into(),
                ..Facts::default()
            }),
            stack: Vec::new(),
            strings: Strings::new("en"),
            baseline: None,
            rows: Vec::new(),
            dialog: None,
            dismissed: None,
            watching: Vec::new(),
        }
    }

    /// The screen at the stack, for the page to draw; also what later row indices refer to.
    pub fn view(&mut self, state: &Value) -> Value {
        let lang = state["config"]["language"].as_str().unwrap_or("en");
        if self.strings.lang() != lang {
            self.strings = Strings::new(lang);
        }
        if self.model.screen(&self.stack, state, &self.strings).is_none() {
            self.stack.clear();
        }
        let open = sessions_open(state);
        if !open || self.baseline.is_none() {
            self.baseline = Some(state["config"].clone());
        }
        let waiting = self.baseline.as_ref().is_some_and(|b| pending(&state["config"], b));
        let t = &self.strings;
        let sections: Vec<Value> = match self.model.screen(&[], state, t) {
            Some(Screen::List { rows, .. }) => rows
                .iter()
                .map(|r| json!({ "label": r.label, "icon": r.icon, "enabled": r.enabled }))
                .collect(),
            _ => Vec::new(),
        };
        let titles: Vec<String> = (1..=self.stack.len())
            .filter_map(|n| {
                let node = self.model.node(&self.stack[..n])?;
                Some(livi_ui_model::settings::view::label(
                    t,
                    node.page_title.as_ref().unwrap_or(&node.label),
                ))
            })
            .collect();
        let mut out = json!({
            "depth": self.stack.len(),
            "section": self.stack.first().map_or(-1, |&i| i as i64),
            "sections": sections,
            "titles": titles,
            "apply": open && waiting,
            "applyText": t.t("settings.apply", "Apply"),
        });
        let Some(screen) = self.model.screen(&self.stack, state, t) else {
            return out;
        };
        let body = match screen {
            Screen::List { rows, dialog, .. } => {
                let shown: Vec<Value> = rows.iter().map(|r| self.row_json(r, state)).collect();
                self.rows = rows;
                let dialog = dialog.filter(|d| self.dismissed.as_ref() != Some(&d.key));
                let dj = dialog.as_ref().map(|d| {
                    json!({ "title": d.title, "rows": d.rows.iter().map(plain_row).collect::<Vec<_>>() })
                });
                self.dialog = dialog;
                json!({ "kind": "list", "rows": shown, "dialog": dj })
            }
            Screen::Select { options, read_only, .. } => json!({
                "kind": "select",
                "readOnly": read_only,
                "options": options.iter().map(|p| json!({ "label": p.label, "selected": p.selected, "offline": p.offline })).collect::<Vec<_>>(),
            }),
            Screen::Number { value, min, max, step, text, .. } => json!({
                "kind": "number", "value": value, "min": min, "max": max, "step": step, "text": text,
            }),
            Screen::Text { value, .. } => json!({ "kind": "text", "value": value }),
            Screen::Color { value, .. } => json!({ "kind": "color", "value": value }),
            Screen::Slider { level, text, .. } => json!({ "kind": "slider", "level": level, "text": text }),
            Screen::Calibration { .. } => json!({ "kind": "unsupported" }),
            Screen::Custom { .. } => json!({ "kind": "unsupported" }),
        };
        if let (Value::Object(o), Value::Object(b)) = (&mut out, body) {
            o.extend(b);
        }
        out
    }

    fn row_json(&self, r: &Row, state: &Value) -> Value {
        let mut v = plain_row(r);
        let opens = r.kind == RowKind::Route
            || r.kind == RowKind::Custom
            || (r.kind == RowKind::Value && self.model.opens(&self.stack, r.node));
        v["opens"] = json!(opens && r.change.is_none() && r.action.is_none());
        // Stock's restart and power-off pages act as they open: the shell asks first.
        let mut below = self.stack.clone();
        below.push(r.node);
        v["confirms"] = json!(r.kind == RowKind::Route
            && self
                .model
                .watches(&below)
                .iter()
                .any(|w| matches!(w, Watch::Act(Action::Restart | Action::Quit))));
        // What the row's own page would show, so a short choice or a small number can be set
        // in place instead of a page away.
        if r.kind == RowKind::Value && r.change.is_none() && r.action.is_none() {
            let mut at = self.stack.clone();
            at.push(r.node);
            match self.model.screen(&at, state, &self.strings) {
                Some(Screen::Select { options, read_only, .. }) => {
                    v["options"] = options
                        .iter()
                        .map(|p| json!({ "label": p.label, "selected": p.selected }))
                        .collect();
                    v["readOnly"] = json!(read_only);
                }
                Some(Screen::Number { value, min: Some(lo), max: Some(hi), step, text, .. })
                    if (hi - lo) / step <= INLINE_STEPS =>
                {
                    v["number"] = json!({ "value": value, "min": lo, "max": hi, "step": step, "text": text });
                }
                Some(Screen::Slider { level, text, .. }) => {
                    v["slider"] = json!({ "level": level, "text": text });
                }
                Some(Screen::Text { .. }) => v["edit"] = json!("text"),
                Some(Screen::Color { .. }) => v["edit"] = json!("color"),
                _ => {}
            }
        }
        v
    }

    /// The sections' list: `-1` closes any section.
    pub fn open_section(&mut self, i: i64) -> Vec<Out> {
        self.stack = if i < 0 { Vec::new() } else { vec![i as usize] };
        Vec::new()
    }

    /// A row that opens its page.
    pub fn open(&mut self, row: usize) -> Vec<Out> {
        if let Some(r) = self.rows.get(row)
            && self.model.opens(&self.stack, r.node)
        {
            self.stack.push(r.node);
        }
        Vec::new()
    }

    /// Up one page, not past the section.
    pub fn back(&mut self) -> Vec<Out> {
        if self.stack.len() > 1 {
            self.stack.pop();
        }
        Vec::new()
    }

    pub fn toggle(&mut self, row: usize, state: &Value) -> Vec<Out> {
        let Some(r) = self.rows.get(row).filter(|r| r.enabled).cloned() else {
            return Vec::new();
        };
        if let Some(change) = r.change {
            let mut out = vec![change];
            out.extend(r.action.map(Change::Act));
            return send(out);
        }
        send(self.model.toggle(&self.stack, r.node, state).into_iter().collect())
    }

    /// A button, item or device row: its action, its change, or both.
    pub fn press(&mut self, row: usize) -> Vec<Out> {
        let Some(r) = self.rows.get(row).filter(|r| r.enabled).cloned() else {
            return Vec::new();
        };
        send(r.action.map(Change::Act).into_iter().chain(r.change).collect())
    }

    /// An option of the select page open now (`row < 0`), or of a row's select set in place.
    /// The select page closes once picked, as stock's does.
    pub fn pick(&mut self, row: i64, option: usize, state: &Value) -> Vec<Out> {
        let at = match self.child(row) {
            Some(at) => at,
            None => return Vec::new(),
        };
        let changes = self.model.pick(&at, option, state, &self.strings);
        if row < 0 && !changes.is_empty() {
            self.stack.pop();
        }
        send(changes)
    }

    /// A slider row (`row >= 0`) or the slider page open now, at `level` in 0..1.
    pub fn level(&mut self, row: i64, level: f32) -> Vec<Out> {
        let index = if row < 0 { None } else { self.rows.get(row as usize).map(|r| r.node) };
        if row >= 0 && index.is_none() {
            return Vec::new();
        }
        send(self.model.level(&self.stack, index, level).into_iter().collect())
    }

    /// A number as shown (in the row's unit), for the number page open now or a row's stepper.
    pub fn number(&mut self, row: i64, value: f64, state: &Value) -> Vec<Out> {
        match self.child(row) {
            Some(at) => send(self.model.number(&at, value, state).into_iter().collect()),
            None => Vec::new(),
        }
    }

    pub fn dialog_press(&mut self, i: usize) -> Vec<Out> {
        let Some(d) = &self.dialog else { return Vec::new() };
        let Some(r) = d.rows.get(i).filter(|r| r.enabled) else {
            return Vec::new();
        };
        if r.local == Some(livi_ui_model::settings::view::Local::CloseDialog) {
            self.dismissed = Some(d.key.clone());
            return Vec::new();
        }
        send(r.action.clone().map(Change::Act).into_iter().collect())
    }

    /// Restarts the phone sessions with the waiting settings.
    pub fn apply(&mut self, state: &Value) -> Vec<Out> {
        self.baseline = Some(state["config"].clone());
        vec![act(Action::ApplySettings)]
    }

    /// What the custom pages on the screen open now watch (link speed, an update check, and
    /// stock's restart and power-off pages, which act on opening), started and stopped as the
    /// stack moves; `leaving` stops them all.
    pub fn follow_watches(&mut self, leaving: bool) -> Vec<Out> {
        let now = if leaving { Vec::new() } else { self.model.watches(&self.stack) };
        let before = std::mem::replace(&mut self.watching, now.clone());
        let mut out = Vec::new();
        for w in before.iter().filter(|w| !now.contains(w)) {
            if *w == Watch::LinkSpeed {
                out.push(Out::Msg(ToCore::LinkSpeed { on: false }));
            }
        }
        for w in now.iter().filter(|w| !before.contains(w)) {
            out.push(match w {
                Watch::LinkSpeed => Out::Msg(ToCore::LinkSpeed { on: true }),
                Watch::Act(a) => act(a.clone()),
            });
        }
        out
    }

    /// The stack to the select or number node: the open page (`row < 0`) or a row's child.
    fn child(&self, row: i64) -> Option<Vec<usize>> {
        if row < 0 {
            return Some(self.stack.clone());
        }
        let r = self.rows.get(row as usize)?;
        let mut at = self.stack.clone();
        at.push(r.node);
        Some(at)
    }
}

fn kind_name(k: RowKind) -> &'static str {
    match k {
        RowKind::Route => "route",
        RowKind::Value => "value",
        RowKind::Switch => "switch",
        RowKind::Slider => "slider",
        RowKind::KeyBinding => "keyBinding",
        RowKind::Custom => "custom",
        RowKind::Devices => "devices",
        RowKind::Info => "info",
        RowKind::Button => "button",
        RowKind::Progress => "progress",
        RowKind::Item => "item",
        RowKind::Device => "device",
        RowKind::Picture => "picture",
        RowKind::Pick => "pick",
    }
}

fn plain_row(r: &Row) -> Value {
    json!({
        "kind": kind_name(r.kind),
        "label": r.label,
        "icon": r.icon,
        "value": r.value,
        "checked": r.checked,
        "level": r.level,
        "enabled": r.enabled,
        "swatch": r.swatch,
        "button": r.button,
        "outlined": r.outlined,
        "dimmed": r.dimmed,
        "mono": r.mono,
        "alert": r.alert,
        "acts": r.action.is_some() || r.change.is_some(),
    })
}

fn act(a: Action) -> Out {
    Out::Act(a)
}

/// livi-ui's `send`: each change as the action that carries it.
fn send(changes: Vec<Change>) -> Vec<Out> {
    changes
        .into_iter()
        .map(|c| match c {
            Change::Config(patch) => act(Action::SetConfig { patch }),
            Change::DongleOn(radio) => act(Action::SetDongleRadio {
                radio: match radio {
                    Radio::Wifi => CoreRadio::Wifi,
                    Radio::Bt => CoreRadio::Bt,
                },
                on: true,
            }),
            Change::Act(a) => act(a),
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use livi_core_proto::state::State;

    use super::*;

    fn state(partial: Value) -> Value {
        State::filled(partial)
    }

    fn row(view: &Value, label: &str) -> usize {
        view["rows"]
            .as_array()
            .unwrap()
            .iter()
            .position(|r| r["label"] == label)
            .unwrap_or_else(|| panic!("no row {label} in {}", view["rows"]))
    }

    fn section(c: &mut Controller, s: &Value, label: &str) -> Value {
        let v = c.view(s);
        let i = v["sections"].as_array().unwrap().iter().position(|r| r["label"] == label).unwrap();
        c.open_section(i as i64);
        c.view(s)
    }

    fn config(out: &[Out]) -> Vec<Value> {
        out.iter()
            .filter_map(|o| match o {
                Out::Act(Action::SetConfig { patch }) => Some(patch.clone()),
                _ => None,
            })
            .collect()
    }

    /// Each touch sends what stock's settings UI sends for it.
    #[test]
    fn touches_send_what_stock_sends() {
        type Touch = fn(&mut Controller, usize, &Value) -> Vec<Out>;
        let cases: [(&str, &str, Value, Touch, Vec<Value>); 5] = [
            ("Appearance", "Dark Mode", json!({ "config": { "darkMode": true } }),
                |c, r, s| c.toggle(r, s), vec![json!({ "darkMode": false })]),
            ("Appearance", "Phone Appearance", json!({}),
                |c, r, s| c.pick(r as i64, 2, s), vec![json!({ "appearanceMode": "night" })]),
            ("Audio", "Sampling Frequency", json!({}),
                |c, r, s| c.pick(r as i64, 0, s), vec![json!({ "samplingFrequency": 0 })]),
            ("Audio", "Head Unit", json!({}),
                |c, r, _| c.level(r as i64, 0.25), vec![json!({ "huVolume": 0.25 })]),
            ("Audio", "Disable Audio", json!({ "config": { "disableAudioOutput": false } }),
                |c, r, s| c.toggle(r, s), vec![json!({ "disableAudioOutput": true })]),
        ];
        for (sec, label, partial, touch, want) in cases {
            let s = state(partial);
            let mut c = Controller::new();
            let v = section(&mut c, &s, sec);
            assert_eq!(v["kind"], "list", "{sec}");
            let r = row(&v, label);
            assert_eq!(config(&touch(&mut c, r, &s)), want, "{sec} / {label}");
            // Set in place: the page stays where it was.
            assert_eq!(c.view(&s)["depth"], 1, "{sec} / {label}");
        }
    }

    #[test]
    fn short_choices_and_sliders_come_inline_and_pages_open() {
        let s = state(json!({}));
        let mut c = Controller::new();
        let v = section(&mut c, &s, "Appearance");
        let phone = &v["rows"][row(&v, "Phone Appearance")];
        assert_eq!(phone["options"].as_array().map(Vec::len), Some(3));
        let audio = section(&mut c, &s, "Audio");
        assert!(audio["rows"][row(&audio, "Head Unit")]["slider"]["level"].is_number());
        let v = section(&mut c, &s, "Appearance");
        c.open(row(&v, "UI Colors"));
        let colors = c.view(&s);
        assert_eq!((colors["depth"].as_u64(), colors["kind"].as_str()), (Some(2), Some("list")));
        assert_eq!(colors["titles"], json!(["Appearance", "UI Colors"]));
        c.back();
        assert_eq!(c.view(&s)["depth"], 1);
    }

    #[test]
    fn a_restart_setting_waits_for_apply_while_a_phone_is_connected() {
        let mut c = Controller::new();
        let open = |cfg: Value| state(json!({ "sessions": { "total": 1 }, "config": cfg }));
        assert_eq!(c.view(&open(json!({ "carName": "LIVI" })))["apply"], false);
        let changed = open(json!({ "carName": "Kia" }));
        assert_eq!(c.view(&changed)["apply"], true);
        assert_eq!(c.apply(&changed), vec![Out::Act(Action::ApplySettings)]);
        assert_eq!(c.view(&changed)["apply"], false);
        // No session: nothing to restart, the change is simply taken.
        let mut c = Controller::new();
        c.view(&state(json!({ "config": { "carName": "LIVI" } })));
        assert_eq!(c.view(&state(json!({ "config": { "carName": "Kia" } })))["apply"], false);
    }
}
