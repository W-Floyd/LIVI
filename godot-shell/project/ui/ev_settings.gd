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
## Stock's steps: limits by 10 % (owner's manual). The V2L range is stock's picker's as
## remembered, not yet read off the car.
const LIMIT := {min = 50.0, max = 100.0, step = 10.0}
const V2L_LIMIT := {min = 20.0, max = 80.0, step = 10.0}
## The schedules' minute fields are 3 bits (0x8C0F, 0x8C55): tens of minutes.
const MINUTE_STEP := 10
const READS := ["telemetry", "config", "precondition", "evSchedule"]
## Telemetry the rows show beyond the settings' own fields.
const ALSO := ["batteryConditioning", "batteryConditioningError", "preconditionState", "preconditionWhy",
	"evScheduleWrites"]

var section := "charging"

var _back: Button
var _title: Label
var _sections: DragScroll
var _rows: DragScroll
var _shown := ""
var _notes: Array = []
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
	# Wide enough for the longest section's name, up to a third of the page; past that, ellipsized.
	var col := clampf(maxf(size.x * 0.22, _sections_width()), 300.0, maxf(300.0, size.x / 3.0))
	_sections.position = Vector2(left, bar + g)
	_sections.size = Vector2(col, size.y - bar - g * 2)
	var rx := left + col + g * 3
	var rw := size.x - rx - g * 1.5
	# No heading over the rows: the section list shows which is open.
	_rows.position = Vector2(rx, bar + g)
	_rows.size = Vector2(rw, size.y - _rows.position.y - g)
	_fit_rows()
	queue_redraw()


## A choice keeps one line and a title its line, the controls going under the text when they do
## not fit beside it; either wraps only where the row is narrower than it alone.
func _fit_rows() -> void:
	var room := floorf(_rows.size.x - ThemeManager.px.gap * 2.4) - 1.0
	for c: HFlowContainer in _rows.list.find_children("Choice", "HFlowContainer", true, false):
		var whole := maxf(0.0, c.get_child_count() - 1) * c.get_theme_constant("h_separation")
		for b: Control in c.get_children():
			whole += b.get_combined_minimum_size().x
		c.custom_minimum_size.x = minf(whole, room)
	for t: Control in _rows.list.find_children("Text", "VBoxContainer", true, false):
		var l: Label = t.get_node("Label")
		var w := l.get_theme_font("font").get_string_size(l.text, HORIZONTAL_ALIGNMENT_LEFT, -1, l.get_theme_font_size("font_size")).x
		t.custom_minimum_size.x = minf(ceilf(w) + 1.0, room)


func _sections_width() -> float:
	var font := get_theme_font("font", "Button")
	var fs := get_theme_font_size("font_size", "Button")
	var w := 0.0
	for it in SECTIONS:
		w = maxf(w, font.get_string_size(it[1], HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x)
	return w + ThemeManager.px.icon + get_theme_constant("h_separation", "Button") + ThemeManager.px.gap * 2 + 2


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
	var key := JSON.stringify([_t, section, EvSettingsLink.fake, _requesting(), Core.get_value("/evSchedule"), Drive.moving,
		Core.get_value("/config/batteryPreconditioning"), Core.get_value("/config/batteryPreconditioningManualMinutes")])
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
		b.clip_text = true
		b.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
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
	_notes = []
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
			var failed := EvSettingsLink.failed()
			if failed != "":
				add.call(_row("schedule_failed", "The car did not take the last change",
					"%s%s. Shown as the car has it." % [failed.substr(0, 1).to_upper(), failed.substr(1)], null))
			add.call(_group("Next departure"))
			add.call(_departure_row("departure_1", "Departure 1"))
			add.call(_departure_row("departure_2", "Departure 2"))
			add.call(_group("Charging"))
			add.call(_switch_row("scheduled_charging", "Scheduled charging", "Full by the departure."))
			add.call(_off_peak_row())
			add.call(_mode_row())
			add.call(_group("Climate"))
			add.call(_switch_row("scheduled_climate", "Climate at departure", "While plugged in."))
			add.call(_climate_temp_row())
			add.call(_switch_row("climate_defog", "Front defog"))
		"battery":
			add.call(_conditioning_row())
			add.call(_route_row())
			add.call(_switch_row("winter_mode", "Winter mode", "Keeps the battery warm in the cold."))
		"power":
			add.call(_number_row("v2l_limit", "V2L discharge limit", V2L_LIMIT, _pct, "V2L stops at this charge."))
			add.call(_utility_row())
	if not _notes.is_empty():
		var n := UI.label("\n".join(_notes), "body", "caption", "dim")
		n.name = "Note"
		n.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		_rows.list.add_child(n)
		_rows.list.move_child(n, 0)
	UI.style_boxes(_rows.list)
	_fit_rows()


# ---- rows ----

## A row's own detail, or that the car has not reported it.
func _why(id: String, detail := "") -> String:
	return "Not reported by the car yet" if EvSettingsLink.state(id, _t) == "unreported" else detail


## A row's tag when it takes no change; why goes in the section's note, once for every row it
## holds for.
func _lock(id: String) -> String:
	var tag := "Read only"
	var why := "LIVI cannot set these on the car yet"
	match EvSettingsLink.state(id, _t):
		"ok":
			return ""
		"unavailable":
			tag = "Not available"
		"unreported":
			if EvSettingsLink.writable(id):
				return ""
		"read_only":
			var b := EvSettingsLink.blocked(id, _t)
			if b != "":
				why = b
				if b == "Sending to the car…":
					tag = "Sending…"
	if not why in _notes:
		_notes.append(why)
	return tag


## A row takes a change once LIVI can send it and knows the value to change.
func _live(id: String) -> bool:
	return EvSettingsLink.state(id, _t) == "ok"


func _send(id: String, v: Variant) -> void:
	var err := EvSettingsLink.write(id, v)
	if err != "":
		push_error("ev settings: %s" % err)


func _row(id: String, label: String, detail: String, control: Control, below: Control = null, lead: Control = null, tag := "") -> PanelContainer:
	var p := PanelContainer.new()
	p.name = id
	p.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var box := _flat_box(ThemeManager.c.surface)
	box.content_margin_left = ThemeManager.px.gap * 1.2
	box.content_margin_right = ThemeManager.px.gap * 1.2
	box.content_margin_top = ThemeManager.px.gap * 0.4
	box.content_margin_bottom = ThemeManager.px.gap * 0.4
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
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	# A flow: controls too wide beside the text go under it, at the row's end, not past the page.
	var line := _flow([text], 1.0)
	line.name = "Line"
	line.alignment = FlowContainer.ALIGNMENT_END
	line.custom_minimum_size.y = ThemeManager.px.touch
	if tag != "":
		var tl := UI.label(tag, "body", "caption", "dim")
		tl.name = "Label"
		var t := UI.hbox([UI.icon("lock", "caption", "dim"), tl], 0.3)
		t.name = "Tag"
		t.alignment = BoxContainer.ALIGNMENT_CENTER
		line.add_child(t)
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
	return _row(id, label, _why(id, detail), box, null, null, _lock(id))


func _choice_row(id: String, label: String, values: Array, labels: Array, detail := "", can := true) -> Control:
	var v = _with_pending(id)
	var box := _flow([], 0.4)
	box.name = "Choice"
	var on := _live(id) and can
	for i in values.size():
		var b := _toggle(values[i], labels[i], v == values[i], on)
		var want: String = values[i]
		b.pressed.connect(func():
			_keep(b, v == want)
			if not _rows.dragged and v != want:
				_send(id, want))
		box.add_child(b)
	return _row(id, label, _why(id, detail), box, null, null, _lock(id) if can else "Read only")


func _switch_row(id: String, label: String, detail := "") -> Control:
	var v = _with_pending(id)
	return _row(id, label, _why(id, detail), _switch(v == true, _live(id), func(): _send(id, not (v == true))), null, null, _lock(id))


## Times and days of one departure. A change sends only what it changes; the car link keeps the
## rest as the car has it. A part the car has not reported takes no change.
func _departure_row(id: String, label: String) -> Control:
	var v = _with_pending(id)
	var d := _departure(v)
	var on := _live(id) and v is Dictionary
	var detail := _why(id, _departure_text(d))
	var tag := _lock(id)
	var is_on = d.get("on")
	var sw := _switch(is_on == true, on and is_on != null, func(): _send(id, {on = not (is_on == true)}))
	var h = d.get("hour")
	var m = d.get("minute")
	var time := _time("Time", h, m, on and h != null and m != null, func(nh, nm): _send(id, {hour = nh, minute = nm}))
	var days := _flow([], 0.3)
	days.name = "Days"
	var set_days: Array = d.get("days", [null, null, null, null, null, null, null])
	var all_known := not set_days.has(null)
	for i in DAYS.size():
		var b := _toggle(DAYS[i], DAYS[i].substr(0, 2), set_days[i] == true, on and all_known)
		b.custom_minimum_size.x = ThemeManager.px.touch * 1.1
		b.pressed.connect(func():
			_keep(b, set_days[i] == true)
			if not _rows.dragged:
				var n := set_days.duplicate()
				n[i] = not (n[i] == true)
				_send(id, {days = n}))
		days.add_child(b)
	return _row(id, label, detail, sw, days, time, tag)


## A departure as the car reports it: on, hour, minute, days (Monday first), each null where the
## car has not said; empty for none.
static func _departure(v: Variant) -> Dictionary:
	if not v is Dictionary:
		return {}
	var days := []
	var got: Array = v.get("days", []) if v.get("days") is Array else []
	for i in DAYS.size():
		days.append(got[i] if i < got.size() and got[i] is bool else null)
	return {on = v.get("on") if v.get("on") is bool else null, hour = _int_or_null(v.get("hour")),
		minute = _int_or_null(v.get("minute")), days = days}


static func _off_peak(v: Variant) -> Dictionary:
	if not v is Dictionary:
		return {}
	return {startHour = _int_or_null(v.get("startHour")), startMinute = _int_or_null(v.get("startMinute")),
		endHour = _int_or_null(v.get("endHour")), endMinute = _int_or_null(v.get("endMinute"))}


static func _int_or_null(v: Variant) -> Variant:
	return int(v) if v is int or v is float else null


static func _clock(h: Variant, m: Variant) -> String:
	return "%s:%s" % ["%02d" % h if h != null else "––", "%02d" % m if m != null else "––"]


func _departure_text(d: Dictionary) -> String:
	if d.is_empty():
		return ""
	if d.get("on") == null:
		return "%s, on or off not reported" % _clock(d.get("hour"), d.get("minute"))
	if d.get("on") != true:
		return "Off"
	var days: Array = d.get("days", [])
	if days.has(null):
		return "%s, days not reported" % _clock(d.get("hour"), d.get("minute"))
	var names := []
	for i in mini(days.size(), DAYS.size()):
		if days[i]:
			names.append(DAYS[i])
	var when := "every day" if names.size() == 7 else ", ".join(names) if not names.is_empty() else "once"
	return "%s, %s" % [_clock(d.get("hour"), d.get("minute")), when]


func _off_peak_row() -> Control:
	var id := "off_peak"
	var v = _with_pending(id)
	var d := _off_peak(v)
	var on := _live(id) and v is Dictionary
	var sh = d.get("startHour")
	var sm = d.get("startMinute")
	var eh = d.get("endHour")
	var em = d.get("endMinute")
	var start := _time("Start", sh, sm, on and sh != null and sm != null,
		func(h, m): _send(id, {startHour = h, startMinute = m}))
	var end := _time("End", eh, em, on and eh != null and em != null,
		func(h, m): _send(id, {endHour = h, endMinute = m}))
	var to := UI.label("to", "body", "body", "dim")
	var below := _flow([start, to, end], 1.0)
	below.name = "Below"
	return _row(id, "Off-peak hours", _why(id, "Cheapest hours to charge."), null, below, null, _lock(id))


## The car's off-peak charging mode. A mode LIVI does not know (the car's code 1) is shown and
## never sent: the car link would echo it back with any off-peak change, so it refuses those too.
func _mode_row() -> Control:
	var id := "off_peak_mode"
	var v = _with_pending(id)
	var known: bool = v in EvSettingsLink.OFF_PEAK_MODES
	var detail := ""
	if v is String and not known:
		detail = "The car reports %s, not known to LIVI" % v
	return _choice_row(id, "Off-peak charging", EvSettingsLink.OFF_PEAK_MODES, ["Off", "Prioritise", "Only"], detail, known)


## The car's code for the climate's temperature: its encoding is not known, so it is shown as
## the code and never set.
func _climate_temp_row() -> Control:
	var id := "climate_temp"
	var v = EvSettingsLink.value(id, _t)
	var value := UI.label("code %d" % int(v) if v != null else "–", "strong", "body")
	value.name = "Value"
	var detail := "The car's code, not yet known in degrees" if v != null else _why(id)
	return _row(id, "Temperature", detail, value, null, null, "Read only" if v != null else _lock(id))


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
	return _row(id, "Utility mode", _why(id, "Parked and READY. Off with the start button."), act, null, null, _lock(id))


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


## Hours and tens of minutes, each wrapping; null shows as unknown and takes no change.
func _time(box_name: String, hv: Variant, mv: Variant, on: bool, change: Callable) -> HBoxContainer:
	on = on and hv != null and mv != null
	var h := int(hv) if hv != null else 0
	var m := int(mv) if mv != null else 0
	var hours := _stepper("%02d" % h if hv != null else "––", on, on,
		func(): change.call(posmod(h - 1, 24), m), func(): change.call(posmod(h + 1, 24), m))
	hours.name = "Hour"
	var mins := _stepper("%02d" % m if mv != null else "––", on, on,
		func(): change.call(h, posmod(m - MINUTE_STEP, 60)), func(): change.call(h, posmod(m + MINUTE_STEP, 60)))
	mins.name = "Minute"
	for s in [hours, mins]:
		(s.get_node("Value") as Label).custom_minimum_size.x = ThemeManager.px.body * 1.8
	var colon := UI.label(":", "strong", "body")
	var box := UI.hbox([hours, colon, mins], 0.3)
	box.name = box_name
	return box


## Wraps its children, each kept whole, to the next line where they do not fit.
func _flow(children: Array, gap: float) -> HFlowContainer:
	var f := HFlowContainer.new()
	f.mouse_filter = Control.MOUSE_FILTER_IGNORE
	f.add_theme_constant_override("h_separation", roundi(ThemeManager.px.gap * gap))
	f.add_theme_constant_override("v_separation", roundi(ThemeManager.px.gap * 0.5))
	for c in children:
		f.add_child(c)
	return f


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


## A setting as shown: the car's value, with the edit on its way to the car over it.
func _with_pending(id: String) -> Variant:
	var v = EvSettingsLink.value(id, _t)
	var p = EvSettingsLink.pending()
	var key: String = EvSettingsLink.SCHEDULE_KEYS.get(id, "")
	if not (p is Dictionary and key != "" and p.has(key)):
		return v
	if v is Dictionary and p[key] is Dictionary:
		var n: Dictionary = v.duplicate(true)
		n.merge(p[key], true)
		return n
	return p[key]


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
