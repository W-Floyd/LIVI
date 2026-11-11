class_name EvSettings
extends Control
## The EV page's settings, as stock's EV settings has them: charging (limits, AC current), the
## schedule (departures, off-peak hours, climate at departure), the battery (conditioning,
## winter mode) and electricity use (V2L limit, utility mode). Sections on the left, the open
## one's rows on the right, over the EV page. A row takes a change only where EvSettingsLink has
## a path to the car, else says why not; it shows the car's state, not the tap.

signal closed

const SECTIONS := [["charging", "Charging", "bolt"], ["schedule", "Schedule", "clock"],
	["battery", "Battery", "therm"], ["power", "Electricity use", "v2l"]]
const DAYS := ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
## Stock's steps: limits by 10 % (owner's manual). The V2L and climate ranges are stock's
## pickers' as remembered, not yet read off the car.
const LIMIT := {min = 50.0, max = 100.0, step = 10.0}
const V2L_LIMIT := {min = 20.0, max = 80.0, step = 10.0}
const CLIMATE_C := {min = 17.0, max = 27.0, step = 0.5}
## The schedules' minute fields are 3 bits (0x8C0F, 0x8C55): tens of minutes.
const MINUTE_STEP := 10
const READS := ["telemetry", "config", "precondition"]
## Telemetry the rows show beyond the settings' own fields.
const ALSO := ["batteryConditioning", "batteryConditioningError", "preconditionState", "preconditionWhy"]

var section := "charging"

var _back: Button
var _title: Label
var _sections: DragScroll
var _heading: Label
var _rows: DragScroll
var _shown := ""
var _t := {}


func _init() -> void:
	name = "EvSettings"
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	visible = false
	_back = _flat_button("Back", "back")
	_back.pressed.connect(close)
	add_child(_back)
	_title = UI.label("EV settings", "display", "title")
	_title.name = "Title"
	add_child(_title)
	_sections = DragScroll.new()
	_sections.name = "Sections"
	add_child(_sections)
	_heading = UI.label("", "strong", "title")
	_heading.name = "Heading"
	add_child(_heading)
	_rows = DragScroll.new()
	_rows.name = "Rows"
	add_child(_rows)


func _ready() -> void:
	ThemeManager.changed.connect(_style)
	Core.changed.connect(_on_core_changed)
	resized.connect(_place)
	_style()


## Shows the settings at a section: "charging", "schedule", "battery" or "power".
func open(s: String) -> void:
	section = s
	visible = true
	_rows.offset = 0.0
	_refresh(true)


func close() -> void:
	if visible:
		visible = false
		closed.emit()


func _on_core_changed(sections: PackedStringArray) -> void:
	if visible and Array(sections).any(func(s): return s in READS):
		_refresh()


func _style() -> void:
	theme = ThemeManager.godot_theme
	UI.restyle(self)
	_style_flat(_back)
	_refresh(true)
	_place()


func _place() -> void:
	var g: float = ThemeManager.px.gap
	var bar := TitleBar.bar_height()
	var left := g * 1.5
	var s := maxf(bar, ThemeManager.px.touch)
	_back.size = Vector2(s, s)
	_back.position = Vector2(left, (bar - s) / 2.0)
	_title.position = Vector2(left + s + g, (bar - _title.get_combined_minimum_size().y) / 2.0)
	var col := clampf(size.x * 0.22, 300.0, 440.0)
	_sections.position = Vector2(left, bar + g)
	_sections.size = Vector2(col, size.y - bar - g * 2)
	var rx := left + col + g * 3
	var rw := size.x - rx - g * 1.5
	var hh: float = ThemeManager.px.touch
	_heading.position = Vector2(rx, bar + g + (hh - _heading.get_combined_minimum_size().y) / 2.0)
	_heading.size.x = rw
	_rows.position = Vector2(rx, bar + g * 2 + hh)
	_rows.size = Vector2(rw, size.y - _rows.position.y - g)
	queue_redraw()


func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), ThemeManager.c.bg)
	var x: float = _sections.position.x + _sections.size.x + ThemeManager.px.gap
	draw_rect(Rect2(x, _sections.position.y, 2, _sections.size.y), ThemeManager.c.line)


## Rebuilds when what the rows show changed: telemetry changes many times a second, the
## settings' fields seldom.
func _refresh(force := false) -> void:
	if not visible or not is_inside_tree():
		return
	var tel = Core.get_value("/telemetry")
	var all: Dictionary = tel if tel is Dictionary else {}
	_t = {}
	for id in EvSettingsLink.SETTINGS:
		var s: Dictionary = EvSettingsLink.SETTINGS[id]
		for k in ["read", "proposed"]:
			if s.has(k) and all.has(s[k]):
				_t[s[k]] = all[s[k]]
	for k in ALSO:
		if all.has(k):
			_t[k] = all[k]
	var key := JSON.stringify([_t, section, EvSettingsLink.fake, _requesting(),
		Core.get_value("/config/batteryPreconditioning"), Core.get_value("/config/batteryPreconditioningManualMinutes"),
		Core.get_value("/config/temperatureUnit")])
	if key == _shown and not force:
		return
	_shown = key
	_build()


func _build() -> void:
	for c in _sections.list.get_children():
		_sections.list.remove_child(c)
		c.queue_free()
	_sections.list.add_theme_constant_override("separation", roundi(ThemeManager.px.gap * 0.5))
	for it in SECTIONS:
		var b := Button.new()
		b.name = it[0]
		b.focus_mode = Control.FOCUS_NONE
		b.toggle_mode = true
		b.set_pressed_no_signal(it[0] == section)
		b.text = it[1]
		b.alignment = HORIZONTAL_ALIGNMENT_LEFT
		b.icon = Icons.texture(it[2], ThemeManager.px.icon)
		b.custom_minimum_size.y = ThemeManager.px.touch * 1.15
		b.add_theme_stylebox_override("normal", _flat_box(Color(0, 0, 0, 0)))
		b.add_theme_stylebox_override("hover", _flat_box(Color(0, 0, 0, 0)))
		b.add_theme_stylebox_override("pressed", _flat_box(ThemeManager.c.accent))
		b.add_theme_stylebox_override("hover_pressed", _flat_box(ThemeManager.c.accent))
		var target: String = it[0]
		b.pressed.connect(func(): if not _sections.dragged: open(target))
		_sections.list.add_child(b)
	for c in _rows.list.get_children():
		_rows.list.remove_child(c)
		c.queue_free()
	_rows.list.add_theme_constant_override("separation", roundi(ThemeManager.px.gap * 0.6))
	for it in SECTIONS:
		if it[0] == section:
			_heading.text = it[1]
	var add := func(c: Control): _rows.list.add_child(c)
	match section:
		"charging":
			add.call(_group("Charge limit"))
			add.call(_number_row("charge_limit_ac", "AC charger", LIMIT, _pct))
			add.call(_number_row("charge_limit_dc", "DC charger", LIMIT, _pct))
			add.call(_group("AC charging current"))
			add.call(_choice_row("ac_current", "Charging current", EvSettingsLink.AC_CURRENT, ["Maximum", "Reduced", "Minimum"],
				"Lower it if a charger stops."))
		"schedule":
			add.call(_group("Next departure"))
			add.call(_departure_row("departure_1", "Departure 1"))
			add.call(_departure_row("departure_2", "Departure 2"))
			add.call(_group("Charging"))
			add.call(_switch_row("scheduled_charging", "Scheduled charging", "Full by the departure."))
			add.call(_off_peak_row())
			add.call(_choice_row("off_peak_mode", "Off-peak charging", EvSettingsLink.OFF_PEAK_MODES, ["Prioritise", "Only"]))
			add.call(_group("Climate"))
			add.call(_switch_row("scheduled_climate", "Climate at departure", "While plugged in."))
			add.call(_number_row("climate_temp", "Temperature", CLIMATE_C, _temp))
			add.call(_switch_row("climate_defog", "Front defog"))
		"battery":
			add.call(_conditioning_row())
			add.call(_route_row())
			add.call(_switch_row("winter_mode", "Winter mode", "Keeps the battery warm in the cold."))
		"power":
			add.call(_number_row("v2l_limit", "V2L discharge limit", V2L_LIMIT, _pct, "V2L stops at this charge."))
			add.call(_utility_row())
	UI.style_boxes(_rows.list)


# ---- rows ----

## Why a row takes no change, or its own detail.
func _why(id: String, detail := "") -> String:
	match EvSettingsLink.state(id, _t):
		"unavailable":
			return "Not available: LIVI cannot read or set this yet"
		"read_only":
			return "Read only: LIVI cannot set this on the car yet"
		"unreported":
			return "Not reported by the car yet" if EvSettingsLink.writable(id) \
				else "Not reported by the car; read only"
	return detail


## A row takes a change once LIVI can send it and knows the value to change.
func _live(id: String) -> bool:
	return EvSettingsLink.state(id, _t) == "ok"


func _send(id: String, v: Variant) -> void:
	var err := EvSettingsLink.write(id, v)
	if err != "":
		push_error("ev settings: %s" % err)


func _row(id: String, label: String, detail: String, control: Control, below: Control = null, lead: Control = null) -> PanelContainer:
	var p := PanelContainer.new()
	p.name = id
	p.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var box := _flat_box(ThemeManager.c.surface)
	box.content_margin_left = ThemeManager.px.gap * 1.2
	box.content_margin_right = ThemeManager.px.gap * 1.2
	box.content_margin_top = ThemeManager.px.gap * 0.5
	box.content_margin_bottom = ThemeManager.px.gap * 0.5
	p.add_theme_stylebox_override("panel", box)
	var l := UI.label(label, "strong", "body")
	l.name = "Label"
	var parts: Array = [l]
	if detail != "":
		var d := UI.label(detail, "body", "caption", "dim")
		d.name = "Detail"
		d.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		parts.append(d)
	var text := UI.vbox(parts, 0)
	text.name = "Text"
	text.alignment = BoxContainer.ALIGNMENT_CENTER
	text.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var line := UI.hbox([text], 1.0)
	line.name = "Line"
	line.custom_minimum_size.y = ThemeManager.px.touch * 1.15
	for c in [lead, control]:
		if c:
			c.size_flags_vertical = Control.SIZE_SHRINK_CENTER
			line.add_child(c)
	var lines := UI.vbox([line], 0.5)
	lines.name = "Lines"
	if below:
		lines.add_child(below)
	p.add_child(lines)
	return p


func _group(text: String) -> Label:
	var l := UI.label(text.to_upper(), "strong", "caption", "dim")
	l.name = ("%s heading" % text).validate_node_name()
	return l


func _number_row(id: String, label: String, r: Dictionary, fmt: Callable, detail := "") -> Control:
	var v = EvSettingsLink.value(id, _t)
	var step: float = r.step
	var on := _live(id) and v != null
	var at := float(v) if v != null else 0.0
	var box := _stepper(fmt.call(v) if v != null else "–", on and at - step >= r.min - 1e-6, on and at + step <= r.max + 1e-6,
		func(): _send(id, clampf(snappedf(at - step, step), r.min, r.max)),
		func(): _send(id, clampf(snappedf(at + step, step), r.min, r.max)))
	return _row(id, label, _why(id, detail), box)


func _choice_row(id: String, label: String, values: Array, labels: Array, detail := "") -> Control:
	var v = EvSettingsLink.value(id, _t)
	var box := HBoxContainer.new()
	box.name = "Choice"
	box.add_theme_constant_override("separation", roundi(ThemeManager.px.gap * 0.4))
	var on := _live(id)
	for i in values.size():
		var b := _toggle(values[i], labels[i], v == values[i], on)
		var want: String = values[i]
		b.pressed.connect(func():
			_keep(b, v == want)
			if not _rows.dragged and v != want:
				_send(id, want))
		box.add_child(b)
	return _row(id, label, _why(id, detail), box)


func _switch_row(id: String, label: String, detail := "") -> Control:
	var v = EvSettingsLink.value(id, _t)
	return _row(id, label, _why(id, detail), _switch(v == true, _live(id), func(): _send(id, not (v == true))))


## Times and days of one departure; each change sends the whole of it, as stock's 0x0C06 does.
func _departure_row(id: String, label: String) -> Control:
	var v = EvSettingsLink.value(id, _t)
	var d := _departure(v)
	var on := _live(id) and v is Dictionary
	var send := func(patch: Dictionary):
		var n := d.duplicate(true)
		n.merge(patch, true)
		_send(id, n)
	var detail := _why(id, _departure_text(d))
	var sw := _switch(d.get("on") == true, on, func(): send.call({on = not (d.get("on") == true)}))
	var time := _time("Time", int(d.get("hour", 0)), int(d.get("minute", 0)), on and v != null,
		func(h, m): send.call({hour = h, minute = m}))
	var days := HBoxContainer.new()
	days.name = "Days"
	days.add_theme_constant_override("separation", roundi(ThemeManager.px.gap * 0.3))
	var set_days: Array = d.get("days", [false, false, false, false, false, false, false])
	for i in DAYS.size():
		var b := _toggle(DAYS[i], DAYS[i].substr(0, 2), bool(set_days[i]), on)
		b.custom_minimum_size.x = ThemeManager.px.touch * 1.1
		b.pressed.connect(func():
			_keep(b, bool(set_days[i]))
			if not _rows.dragged:
				var n := set_days.duplicate()
				n[i] = not bool(n[i])
				send.call({days = n}))
		days.add_child(b)
	return _row(id, label, detail, sw, days, time)


## A departure as the page sends it: on, hour, minute, days (Monday first); empty for none.
static func _departure(v: Variant) -> Dictionary:
	if not v is Dictionary:
		return {}
	var days := []
	var got: Array = v.get("days", []) if v.get("days") is Array else []
	for i in DAYS.size():
		days.append(i < got.size() and got[i] == true)
	return {on = v.get("on") == true, hour = int(v.get("hour", 0)), minute = int(v.get("minute", 0)), days = days}


static func _off_peak(v: Variant) -> Dictionary:
	if not v is Dictionary:
		return {}
	return {start_hour = int(v.get("start_hour", 0)), start_minute = int(v.get("start_minute", 0)),
		end_hour = int(v.get("end_hour", 0)), end_minute = int(v.get("end_minute", 0))}


func _departure_text(d: Dictionary) -> String:
	if d.is_empty():
		return ""
	if d.get("on") != true:
		return "Off"
	var days: Array = d.get("days", [])
	var names := []
	for i in mini(days.size(), DAYS.size()):
		if days[i]:
			names.append(DAYS[i])
	var when := "every day" if names.size() == 7 else ", ".join(names) if not names.is_empty() else "once"
	return "%02d:%02d, %s" % [int(d.get("hour", 0)), int(d.get("minute", 0)), when]


func _off_peak_row() -> Control:
	var id := "off_peak"
	var v = EvSettingsLink.value(id, _t)
	var d := _off_peak(v)
	var on := _live(id) and v is Dictionary
	var send := func(patch: Dictionary):
		var n := d.duplicate(true)
		n.merge(patch, true)
		_send(id, n)
	var start := _time("Start", int(d.get("start_hour", 0)), int(d.get("start_minute", 0)), on,
		func(h, m): send.call({start_hour = h, start_minute = m}))
	var end := _time("End", int(d.get("end_hour", 0)), int(d.get("end_minute", 0)), on,
		func(h, m): send.call({end_hour = h, end_minute = m}))
	var to := UI.label("to", "body", "body", "dim")
	var below := UI.hbox([start, to, end], 1.0)
	below.name = "Below"
	return _row(id, "Off-peak hours", _why(id, "Cheapest hours to charge."), null, below)


## LIVI's request, which micom-livi turns into the car's conditioning mode while it lasts; the
## car's own word beside it.
func _conditioning_row() -> Control:
	var id := "battery_conditioning"
	var asking := _requesting()
	var mode = EvSettingsLink.value(id, _t)
	var err := CarStatus.conditioning_error(_t.get("batteryConditioningError"))
	var mins = Core.get_value("/config/batteryPreconditioningManualMinutes")
	var detail := "Asks for %d min; the car decides" % (int(mins) if mins != null else 30)
	if err != "":
		detail = "The car: " + err
	elif _t.get("batteryConditioning") == true:
		detail = "The car is conditioning"
	elif mode is String:
		detail = "The car's mode: %s" % mode
	var allowed: bool = Core.get_value("/config/batteryPreconditioning") != "off"
	# Off in LIVI is off for the request too (the core refuses it).
	var sw := _switch(asking, EvSettingsLink.writable(id) and (allowed or asking), func(): _send(id, not asking))
	return _row(id, "Battery conditioning", detail if allowed or asking else "Off in LIVI's settings", sw)


## LIVI's own setting: warm the battery on a route to a fast charger (micom-livi -precondition).
func _route_row() -> Control:
	var on: bool = Core.get_value("/config/batteryPreconditioning") != "off"
	var state = _t.get("preconditionState")
	var why = _t.get("preconditionWhy")
	var detail := "Not reported by the car link"
	if state == "running":
		detail = "Warming for the charger"
	elif not on:
		detail = "Off"
	elif state != null:
		detail = str(why) if why is String and why != "" else "Armed"
	var sw := _switch(on, true, func():
		var err: String = Core.act({kind = "setConfig", patch = {batteryPreconditioning = "off" if on else "auto"}})
		if err != "":
			push_error("ev settings: %s" % err))
	return _row("route_precondition", "Before a fast charger", detail, sw)


func _utility_row() -> Control:
	var id := "utility_mode"
	var v = EvSettingsLink.value(id, _t)
	var act := Button.new()
	act.name = "Act"
	act.focus_mode = Control.FOCUS_NONE
	act.text = "On" if v == true else "Activate"
	act.custom_minimum_size = Vector2(ThemeManager.px.touch * 2.4, ThemeManager.px.touch)
	# Stock turns it off only with the start button; READY and Park to turn it on.
	act.disabled = not _live(id) or v == true
	act.pressed.connect(func(): if not _rows.dragged: _send(id, true))
	return _row(id, "Utility mode", _why(id, "Parked and READY. Off with the start button."), act)


# ---- controls ----

func _stepper(text: String, can_down: bool, can_up: bool, down: Callable, up: Callable) -> HBoxContainer:
	var minus := _flat_button("Minus", "minus")
	var plus := _flat_button("Plus", "plus")
	for b in [minus, plus]:
		_style_flat(b)
		b.add_theme_stylebox_override("normal", _flat_box(ThemeManager.c.surface2))
		b.add_theme_stylebox_override("hover", _flat_box(ThemeManager.c.surface2))
	minus.disabled = not can_down
	plus.disabled = not can_up
	minus.pressed.connect(func(): if not _rows.dragged: down.call())
	plus.pressed.connect(func(): if not _rows.dragged: up.call())
	var v := UI.label(text, "strong", "body")
	v.name = "Value"
	v.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	v.custom_minimum_size.x = ThemeManager.px.body * 3.6
	var box := UI.hbox([minus, v, plus], 0.5)
	box.name = "Stepper"
	return box


## Hours and tens of minutes, each wrapping.
func _time(box_name: String, h: int, m: int, on: bool, change: Callable) -> HBoxContainer:
	var hours := _stepper("%02d" % h, on, on, func(): change.call(posmod(h - 1, 24), m), func(): change.call(posmod(h + 1, 24), m))
	hours.name = "Hour"
	var mins := _stepper("%02d" % m, on, on,
		func(): change.call(h, posmod(m - MINUTE_STEP, 60)), func(): change.call(h, posmod(m + MINUTE_STEP, 60)))
	mins.name = "Minute"
	for s in [hours, mins]:
		(s.get_node("Value") as Label).custom_minimum_size.x = ThemeManager.px.body * 1.8
	var colon := UI.label(":", "strong", "body")
	var box := UI.hbox([hours, colon, mins], 0.3)
	box.name = box_name
	return box


func _switch(checked: bool, on: bool, toggle: Callable) -> Button:
	var b := Button.new()
	b.name = "Switch"
	b.focus_mode = Control.FOCUS_NONE
	b.toggle_mode = true
	b.set_pressed_no_signal(checked)
	b.disabled = not on
	b.custom_minimum_size = Vector2(ThemeManager.px.touch * 1.8, ThemeManager.px.touch)
	for s in ["normal", "hover", "pressed", "hover_pressed", "disabled", "focus"]:
		b.add_theme_stylebox_override(s, StyleBoxEmpty.new())
	var mark := SettingsPage.SwitchMark.new(checked)
	mark.mouse_filter = Control.MOUSE_FILTER_IGNORE
	mark.size = mark.custom_minimum_size
	mark.set_anchors_and_offsets_preset(Control.PRESET_CENTER, Control.PRESET_MODE_KEEP_SIZE)
	b.add_child(mark)
	b.pressed.connect(func():
		_keep(b, checked)
		if not _rows.dragged:
			toggle.call())
	_dim(b, not on)
	return b


func _toggle(node_name: String, text: String, checked: bool, on: bool) -> Button:
	var b := Button.new()
	b.name = node_name.validate_node_name()
	b.text = text
	b.focus_mode = Control.FOCUS_NONE
	b.toggle_mode = true
	b.set_pressed_no_signal(checked)
	b.disabled = not on
	b.custom_minimum_size = Vector2(ThemeManager.px.touch * 1.6, ThemeManager.px.touch)
	b.add_theme_stylebox_override("hover", b.get_theme_stylebox("normal"))
	b.add_theme_stylebox_override("hover_pressed", b.get_theme_stylebox("pressed"))
	return b


## A toggle shows the car's state, not the tap: it changes when the car reports it.
func _keep(b: Button, checked: bool) -> void:
	b.set_pressed_no_signal(checked)


func _dim(c: Control, off: bool) -> void:
	c.modulate.a = 0.45 if off else 1.0


func _pct(v: Variant) -> String:
	return "%d %%" % roundi(float(v))


func _temp(v: Variant) -> String:
	var c := float(v)
	if Units.fahrenheit():
		return "%d °F" % roundi(c * 9.0 / 5.0 + 32.0)
	return "%s °C" % String.num(c, 1)


func _requesting() -> bool:
	return Core.get_value("/precondition/manualUntil") != null


func _flat_button(button_name: String, icon_name: String) -> Button:
	var b := Button.new()
	b.name = button_name
	b.focus_mode = Control.FOCUS_NONE
	b.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
	b.vertical_icon_alignment = VERTICAL_ALIGNMENT_CENTER
	b.set_meta("icon_name", icon_name)
	b.custom_minimum_size = Vector2.ONE * ThemeManager.px.touch
	return b


func _style_flat(b: Button) -> void:
	b.icon = Icons.texture(b.get_meta("icon_name"), ThemeManager.px.icon * 1.2)
	b.custom_minimum_size = Vector2.ONE * ThemeManager.px.touch
	for s in ["normal", "hover", "focus", "disabled"]:
		b.add_theme_stylebox_override(s, _flat_box(Color(0, 0, 0, 0)))
	b.add_theme_stylebox_override("pressed", _flat_box(ThemeManager.c.surface2))
	for k in ["icon_normal_color", "icon_hover_color", "icon_pressed_color", "icon_focus_color"]:
		b.add_theme_color_override(k, ThemeManager.c.text)
	b.add_theme_color_override("icon_disabled_color", ThemeManager.c.dim)


func _flat_box(fill: Color) -> StyleBoxFlat:
	var f := StyleBoxFlat.new()
	f.bg_color = fill
	f.set_corner_radius_all(roundi(ThemeManager.px.radius))
	f.content_margin_left = ThemeManager.px.gap
	f.content_margin_right = ThemeManager.px.gap
	f.anti_aliasing = true
	return f
