class_name SettingsPage
extends Control
## Settings: LIVI's own (the tree and values stock LIVI's UI shows, from livi-ui-model through
## `Core.settings_*`, which also sends what each touch changes) and the shell's look. Sections on
## the left, the open one's rows on the right; both lists drag. A short choice is set in place,
## a long one opens its list; a change that restarts the phone's connection waits for Apply.

signal back_pressed

const LOOK := "look"
## Choices with up to this many options, all short, are set in place.
const INLINE_OPTIONS := 4
const INLINE_CHARS := 28
## Sliders send while they move, at most this often, as stock's do.
const SLIDE_MS := 100
## A second tap within this arms nothing: it restarts or powers off.
const CONFIRM_MS := 4000
## Core sections whose change can show on a settings page.
const READS := ["config", "system", "sessions", "devices", "precondition", "telemetry", "mfi", "dab", "fm", "update", "cluster", "cameras"]
const REFRESH_S := 0.25

var top_inset := 0.0

## The section open: LOOK, or an index into LIVI's sections.
var section: Variant = 0
var _view := {}
var _shown_json := ""
var _look_pick := ""
var _armed := -1
var _armed_ms := 0
var _sliding := false
var _slide_ms := 0
var _dirty := false
var _dirty_s := 0.0

var _header: Control
var _back: Button
var _title: Label
var _apply: Button
var _apply_note: Label
var _sections: DragScroll
var _heading: Control
var _up: Button
var _heading_label: Label
var _rows: DragScroll


func _init() -> void:
	name = "Settings"
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_header = Control.new()
	_header.name = "Header"
	_header.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_header)
	_back = _flat_button("Back", "back")
	_back.pressed.connect(func(): back_pressed.emit())
	_header.add_child(_back)
	_title = UI.label("Settings", "display", "title")
	_header.add_child(_title)
	_apply_note = UI.label("Restarts the phone connection", "body", "caption", "dim")
	_header.add_child(_apply_note)
	_apply = Button.new()
	_apply.name = "Apply"
	_apply.focus_mode = Control.FOCUS_NONE
	_apply.pressed.connect(_on_apply)
	_header.add_child(_apply)
	_sections = DragScroll.new()
	_sections.name = "Sections"
	add_child(_sections)
	_heading = Control.new()
	_heading.name = "Heading"
	_heading.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_heading)
	_up = _flat_button("Up", "back")
	_up.pressed.connect(_on_up)
	_heading.add_child(_up)
	_heading_label = UI.label("", "strong", "title")
	_heading_label.name = "Title"
	_heading_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_heading.add_child(_heading_label)
	_rows = DragScroll.new()
	_rows.name = "Rows"
	add_child(_rows)


func _ready() -> void:
	ThemeManager.changed.connect(_style)
	Core.changed.connect(_on_core_changed)
	Core.welcome.connect(func(_v): _refresh())
	resized.connect(_place)
	Core.settings_section(int(section) if section is int else -1)
	_style()


func _exit_tree() -> void:
	Core.settings_leave()


func _process(delta: float) -> void:
	_dirty_s += delta
	if _dirty and not _sliding and _dirty_s >= REFRESH_S:
		_dirty = false
		_refresh()
	if _armed >= 0 and Time.get_ticks_msec() - _armed_ms > CONFIRM_MS:
		_armed = -1
		_refresh(true)


func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), ThemeManager.c.bg)
	var x: float = _sections.position.x + _sections.size.x + ThemeManager.px.gap
	draw_rect(Rect2(x, _sections.position.y, 2, _sections.size.y), ThemeManager.c.line)


func _on_core_changed(sections: PackedStringArray) -> void:
	for s in sections:
		if s in READS:
			if not _dirty:
				_dirty_s = 0.0
			_dirty = true
			return


## Opens a section: LOOK or LIVI's by index.
func open_section(s: Variant) -> void:
	section = s
	_look_pick = ""
	_armed = -1
	Core.settings_section(s if s is int else -1)
	_rows.offset = 0.0
	_refresh(true)


func _style() -> void:
	theme = ThemeManager.godot_theme
	offset_top = top_inset
	UI.restyle(self)
	for b in [_back, _up]:
		_style_flat(b)
	for st in ["normal", "hover", "pressed", "hover_pressed"]:
		_apply.add_theme_stylebox_override(st, _flat_box(ThemeManager.c.accent))
	for k in ["font_color", "font_hover_color", "font_pressed_color", "font_hover_pressed_color"]:
		_apply.add_theme_color_override(k, ThemeManager.c.on_accent)
	_refresh(true)
	_place()


func _place() -> void:
	var g: float = ThemeManager.px.gap
	var bar := TitleBar.bar_height()
	var left := g * 1.5 + _rail_inset()
	_header.position = Vector2.ZERO
	_header.size = Vector2(size.x, bar)
	var s := maxf(bar, ThemeManager.px.touch)
	_back.size = Vector2(s, s)
	_back.position = Vector2(left, (bar - s) / 2.0)
	_title.position = Vector2(left + s + g, (bar - _title.get_combined_minimum_size().y) / 2.0)
	var ah: float = ThemeManager.px.touch
	_apply.size = Vector2(maxf(_apply.get_combined_minimum_size().x, ah * 2.2), ah)
	_apply.position = Vector2(size.x - g * 1.5 - _apply.size.x, (bar - ah) / 2.0)
	var note := _apply_note.get_combined_minimum_size()
	_apply_note.position = Vector2(_apply.position.x - g - note.x, (bar - note.y) / 2.0)
	var col := clampf(size.x * 0.26, 340.0, 520.0)
	_sections.position = Vector2(left, bar + g)
	_sections.size = Vector2(col, size.y - bar - g * 2)
	var rx := left + col + g * 3
	var rw := size.x - rx - g * 1.5
	var hh: float = ThemeManager.px.touch
	_heading.position = Vector2(rx, bar + g)
	_heading.size = Vector2(rw, hh)
	_up.size = Vector2(hh, hh)
	_up.position = Vector2.ZERO
	var lx: float = hh + g * 0.5 if _up.visible else 0.0
	_heading_label.position = Vector2(lx, (hh - _heading_label.get_combined_minimum_size().y) / 2.0)
	_heading_label.size.x = rw - lx
	_rows.position = Vector2(rx, bar + g * 2 + hh)
	_rows.size = Vector2(rw, size.y - _rows.position.y - g)
	queue_redraw()


## The nav rail sits over the left edge when there is one; the lists start clear of it.
func _rail_inset() -> float:
	var rail := get_tree().root.find_child("NavRail", true, false) as Control if is_inside_tree() else null
	return rail.size.x if rail and rail.visible else 0.0


## Redraws from the core's view, unless nothing a row shows has changed. `force` redraws anyway.
func _refresh(force := false) -> void:
	if not is_inside_tree():
		return
	var v = Core.settings_view()
	_view = v if v is Dictionary else {}
	var key := JSON.stringify([_view, section, _look_pick, _armed])
	if key == _shown_json and not force:
		return
	_shown_json = key
	_build()


func _build() -> void:
	var look := section is String
	_apply.text = str(_view.get("applyText", "Apply"))
	_apply.visible = bool(_view.get("apply", false))
	_apply_note.visible = _apply.visible
	_build_sections()
	for c in _rows.list.get_children():
		_rows.list.remove_child(c)
		c.queue_free()
	var g: float = ThemeManager.px.gap
	_rows.list.add_theme_constant_override("separation", roundi(g * 0.6))
	var titles: Array = _view.get("titles", [])
	if look:
		_heading_label.text = "Look" if _look_pick == "" else _look_row(_look_pick).label
		_up.visible = _look_pick != ""
		if _look_pick == "":
			for r in _look_rows():
				_rows.list.add_child(_row(r, r.key))
		else:
			_add_picks(_look_row(_look_pick).options, func(i): _look_set(_look_pick, _look_row(_look_pick).options[i].value); _look_pick = ""; _refresh(true))
	else:
		_heading_label.text = str(titles[-1]) if not titles.is_empty() else ""
		_up.visible = titles.size() > 1
		_build_livi()
	_place()


func _build_sections() -> void:
	for c in _sections.list.get_children():
		_sections.list.remove_child(c)
		c.queue_free()
	_sections.list.add_theme_constant_override("separation", roundi(ThemeManager.px.gap * 0.5))
	# The shell's own first: LIVI's list runs past the panel's height.
	var items: Array = [[LOOK, "Look", "brush"]]
	var i := 0
	for s in _view.get("sections", []):
		items.append([i, str(s.get("label", "")), _section_icon(str(s.get("icon", "")))])
		i += 1
	for it in items:
		var b := Button.new()
		b.name = it[1].validate_node_name()
		b.focus_mode = Control.FOCUS_NONE
		b.toggle_mode = true
		b.set_pressed_no_signal(typeof(it[0]) == typeof(section) and it[0] == section)
		b.text = it[1]
		b.alignment = HORIZONTAL_ALIGNMENT_LEFT
		b.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		b.clip_text = true
		b.icon = Icons.texture(it[2], ThemeManager.px.icon)
		b.custom_minimum_size.y = ThemeManager.px.touch * 1.15
		b.add_theme_stylebox_override("normal", _flat_box(Color(0, 0, 0, 0)))
		b.add_theme_stylebox_override("hover", _flat_box(Color(0, 0, 0, 0)))
		b.add_theme_stylebox_override("pressed", _flat_box(ThemeManager.c.accent))
		b.add_theme_stylebox_override("hover_pressed", _flat_box(ThemeManager.c.accent))
		var target = it[0]
		b.pressed.connect(func(): if not _sections.dragged: open_section(target))
		_sections.list.add_child(b)


## LIVI's icon names (Material's) to the shell's few.
func _section_icon(material_name: String) -> String:
	const MAP := {
		SmartphoneOutlined = "phone", TuneOutlined = "tune", DirectionsCarOutlined = "car",
		VolumeUpOutlined = "vol", MonitorOutlined = "monitor", ContrastOutlined = "contrast",
		MemoryOutlined = "chip"}
	return MAP.get(material_name, "gear")


func _build_livi() -> void:
	match str(_view.get("kind", "")):
		"list":
			var d = _view.get("dialog")
			if d is Dictionary:
				_rows.list.add_child(_dialog(d))
			var rows: Array = _view.get("rows", [])
			for i in rows.size():
				var r: Dictionary = rows[i]
				if i == _armed:
					r = r.duplicate()
					r.label = "Tap again: %s" % r.label
					r.alert = true
				_rows.list.add_child(_row(r, i))
		"select":
			var opts: Array = _view.get("options", [])
			_add_picks(opts, func(i): if not bool(_view.get("readOnly", false)): Core.settings_pick(-1, i); _refresh(true))
		"number":
			_rows.list.add_child(_number_page())
		"slider":
			var r := {kind = "value", label = _heading_label.text, enabled = true, slider = {level = _view.get("level", 0.0), text = _view.get("text", "")}}
			_rows.list.add_child(_row(r, -1))
		"text", "color":
			var r := {kind = "info", label = str(_view.get("value", "")), value = "", enabled = true}
			_rows.list.add_child(_row(r, -1))
			_rows.list.add_child(_note("Typing needs a keyboard, which this panel does not have yet."))
		_:
			_rows.list.add_child(_note("This page needs LIVI's own settings screen."))


## One row: label (and value) on the left, its control on the right. `id` is LIVI's row index or
## a look key.
func _row(r: Dictionary, id: Variant) -> Button:
	var g: float = ThemeManager.px.gap
	var b := Button.new()
	b.name = str(r.get("label", "row")).validate_node_name()
	b.focus_mode = Control.FOCUS_NONE
	var enabled := bool(r.get("enabled", true))
	var kind := str(r.get("kind", "value"))
	var opts: Array = r.get("options", [])
	var inline := _inline(opts) and not bool(r.get("readOnly", false))
	var tap := ""
	if enabled:
		if kind == "switch":
			tap = "toggle"
		elif r.has("slider") or inline or r.has("number"):
			tap = ""
		elif bool(r.get("opens", false)) or (opts.size() > 0 and not bool(r.get("readOnly", false))):
			tap = "open"
		elif bool(r.get("acts", false)) and kind != "button":
			tap = "press"
	b.mouse_filter = Control.MOUSE_FILTER_STOP if tap != "" else Control.MOUSE_FILTER_IGNORE
	var box: StyleBox = ThemeManager.card_box() if ThemeManager.material == "solid" and not ThemeManager.is_scene() else _flat_box(ThemeManager.c.surface)
	box.content_margin_top = 0
	box.content_margin_bottom = 0
	for s in ["normal", "hover", "disabled", "focus"]:
		b.add_theme_stylebox_override(s, box)
	var down := _flat_box(ThemeManager.c.surface2)
	b.add_theme_stylebox_override("pressed", down)
	b.add_theme_stylebox_override("hover_pressed", down)

	var label := UI.label(str(r.get("label", "")), "strong", "body", "crit" if r.get("alert", false) else "text")
	label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	label.clip_text = true
	var text_parts: Array = [label]
	var value := str(r.get("value", ""))
	var side: Control = null
	if r.has("slider"):
		side = _slider(r.slider, id)
	elif inline:
		side = _segments(opts, id)
	elif r.has("number"):
		side = _stepper(r.number, id)
	elif kind == "switch":
		side = SwitchMark.new(bool(r.get("checked", false)))
	elif kind == "button" and str(r.get("button", "")) != "":
		var act := Button.new()
		act.name = "Act"
		act.focus_mode = Control.FOCUS_NONE
		act.text = str(r.button)
		act.custom_minimum_size = Vector2(ThemeManager.px.touch * 2.0, ThemeManager.px.touch)
		act.disabled = not enabled
		act.pressed.connect(func(): if not _rows.dragged: _livi_or_look(id, "press"))
		side = act
	# The value says what a control would; with a control, the row says it already.
	if value != "" and side == null:
		var v := UI.label(value, "body", "body", "dim")
		v.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		v.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		v.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		v.size_flags_stretch_ratio = 0.8
		v.clip_text = true
		side = v
	if str(r.get("detail", "")) != "":
		text_parts.append(UI.label(str(r.detail), "body", "caption", "dim"))
	var text := UI.vbox(text_parts, 0)
	text.alignment = BoxContainer.ALIGNMENT_CENTER
	text.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var parts: Array = []
	if r.get("swatch") != null and str(r.get("swatch", "")) != "":
		var sw := ColorRect.new()
		sw.color = Color.from_string(str(r.swatch), ThemeManager.c.dim)
		sw.custom_minimum_size = Vector2.ONE * ThemeManager.px.icon
		sw.mouse_filter = Control.MOUSE_FILTER_IGNORE
		parts.append(sw)
	parts.append(text)
	if side:
		if side is Label or side is SwitchMark:
			side.mouse_filter = Control.MOUSE_FILTER_IGNORE
		parts.append(side)
	if tap == "open":
		parts.append(UI.icon("chevron", "icon", "dim"))
	var row := UI.hbox(parts, 1.0)
	row.name = "Box"
	row.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	row.offset_left = g * 1.2
	row.offset_right = -g * 1.2
	UI.style_boxes(row)
	b.add_child(row)
	# Outside the tree a container's minimum is not known yet: follow it.
	var fit := func(): b.custom_minimum_size.y = maxf(ThemeManager.px.touch * 1.3, row.get_combined_minimum_size().y + g * 1.4)
	row.minimum_size_changed.connect(fit)
	fit.call()
	if not enabled or r.get("dimmed", false):
		b.modulate.a = 0.5
	if tap != "":
		b.pressed.connect(func(): if not _rows.dragged: _livi_or_look(id, tap))
	return b


func _inline(opts: Array) -> bool:
	if opts.is_empty() or opts.size() > INLINE_OPTIONS:
		return false
	var chars := 0
	for o in opts:
		chars += str(o.get("label", "")).length()
	return chars <= INLINE_CHARS


## A segmented choice: the selected option in the accent.
func _segments(opts: Array, id: Variant) -> HBoxContainer:
	var box := HBoxContainer.new()
	box.name = "Choice"
	box.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_theme_constant_override("separation", roundi(ThemeManager.px.gap * 0.4))
	for i in opts.size():
		var o: Dictionary = opts[i]
		var b := Button.new()
		b.name = str(o.get("label", i)).validate_node_name()
		b.text = str(o.get("label", ""))
		b.focus_mode = Control.FOCUS_NONE
		b.toggle_mode = true
		b.set_pressed_no_signal(bool(o.get("selected", false)))
		b.custom_minimum_size = Vector2(ThemeManager.px.touch * 1.6, ThemeManager.px.touch)
		b.add_theme_stylebox_override("hover", b.get_theme_stylebox("normal"))
		b.add_theme_stylebox_override("hover_pressed", b.get_theme_stylebox("pressed"))
		b.pressed.connect(func(): if not _rows.dragged: _pick(id, i))
		box.add_child(b)
	return box


func _slider(s: Dictionary, id: Variant) -> HBoxContainer:
	var sl := HSlider.new()
	sl.name = "Slider"
	sl.min_value = 0.0
	sl.max_value = 1.0
	sl.step = 0.01
	sl.value = float(s.get("level", 0.0))
	sl.focus_mode = Control.FOCUS_NONE
	sl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sl.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	sl.custom_minimum_size = Vector2(size.x * 0.22, ThemeManager.px.touch)
	_style_slider(sl)
	var text := UI.label(str(s.get("text", "")), "body", "body", "dim")
	text.custom_minimum_size.x = ThemeManager.px.body * 3.2
	text.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	sl.drag_started.connect(func(): _sliding = true)
	sl.value_changed.connect(func(v):
		var now := Time.get_ticks_msec()
		if _sliding and now - _slide_ms >= SLIDE_MS:
			_slide_ms = now
			Core.settings_level(int(id), v))
	sl.drag_ended.connect(func(_changed):
		_sliding = false
		_slide_ms = 0
		Core.settings_level(int(id), sl.value)
		_refresh())
	var box := UI.hbox([sl, text], 0.8)
	box.name = "Level"
	box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	box.size_flags_stretch_ratio = 1.4
	return box


func _style_slider(sl: HSlider) -> void:
	var h := roundi(ThemeManager.px.gap * 0.7)
	var track := _flat_box(ThemeManager.c.surface2)
	track.set_corner_radius_all(h)
	track.content_margin_top = h / 2.0
	track.content_margin_bottom = h / 2.0
	var fill := _flat_box(ThemeManager.c.accent)
	fill.set_corner_radius_all(h)
	fill.content_margin_top = h / 2.0
	fill.content_margin_bottom = h / 2.0
	sl.add_theme_stylebox_override("slider", track)
	sl.add_theme_stylebox_override("grabber_area", fill)
	sl.add_theme_stylebox_override("grabber_area_highlight", fill)
	var dot := _dot(ThemeManager.px.touch * 0.55, ThemeManager.c.accent)
	sl.add_theme_icon_override("grabber", dot)
	sl.add_theme_icon_override("grabber_highlight", dot)


## A stepper for a number with few steps: minus, the value, plus.
func _stepper(n: Dictionary, id: Variant) -> HBoxContainer:
	var step := float(n.get("step", 1.0))
	var v := float(n.get("value", 0.0))
	var minus := _flat_button("Minus", "minus")
	var plus := _flat_button("Plus", "plus")
	for b in [minus, plus]:
		_style_flat(b)
		b.add_theme_stylebox_override("normal", _flat_box(ThemeManager.c.surface2))
	minus.disabled = v - step < float(n.get("min", -INF)) - 1e-9
	plus.disabled = v + step > float(n.get("max", INF)) + 1e-9
	minus.pressed.connect(func(): if not _rows.dragged: Core.settings_number(int(id), v - step); _refresh(true))
	plus.pressed.connect(func(): if not _rows.dragged: Core.settings_number(int(id), v + step); _refresh(true))
	var text := UI.label(str(n.get("text", "")), "strong", "body")
	text.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	text.custom_minimum_size.x = ThemeManager.px.body * 4.0
	var box := UI.hbox([minus, text, plus], 0.5)
	box.name = "Stepper"
	return box


## The number page: the value, and steps of one, ten and a hundred times the number's step.
func _number_page() -> Control:
	var step := float(_view.get("step", 1.0))
	var v := float(_view.get("value", 0.0))
	var row := HBoxContainer.new()
	row.name = "Number"
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", roundi(ThemeManager.px.gap))
	var add := func(by: float):
		var b := Button.new()
		b.name = ("%+g" % by).validate_node_name()
		b.text = "%+g" % by
		b.focus_mode = Control.FOCUS_NONE
		b.custom_minimum_size = Vector2(ThemeManager.px.touch * 1.6, ThemeManager.px.touch * 1.2)
		b.pressed.connect(func(): if not _rows.dragged: Core.settings_number(-1, v + by); _refresh(true))
		row.add_child(b)
	for by in [-100.0, -10.0, -1.0]:
		add.call(by * step)
	var text := UI.label(str(_view.get("text", "")), "display", "display")
	text.custom_minimum_size.x = ThemeManager.px.display * 3.5
	text.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	row.add_child(text)
	for by in [1.0, 10.0, 100.0]:
		add.call(by * step)
	return row


## A list of options with a check on the chosen one; `on_pick` gets the index.
func _add_picks(opts: Array, on_pick: Callable) -> void:
	for i in opts.size():
		var o: Dictionary = opts[i]
		var r := {kind = "pick", label = str(o.get("label", "")), enabled = not bool(o.get("offline", false))}
		var b := _row(r, -1)
		b.mouse_filter = Control.MOUSE_FILTER_STOP
		if bool(o.get("selected", false)):
			var check := UI.icon("check", "icon", "accent")
			b.get_node("Box").add_child(check)
		b.pressed.connect(func(): if not _rows.dragged: on_pick.call(i))
		_rows.list.add_child(b)


func _dialog(d: Dictionary) -> Control:
	var card := PanelContainer.new()
	card.name = "Dialog"
	var box := _flat_box(ThemeManager.c.surface2)
	box.set_content_margin_all(ThemeManager.px.gap * 1.2)
	card.add_theme_stylebox_override("panel", box)
	var items: Array = [UI.label(str(d.get("title", "")), "strong", "body")]
	var rows: Array = d.get("rows", [])
	for i in rows.size():
		var r: Dictionary = rows[i]
		if bool(r.get("acts", false)) or str(r.get("button", "")) != "":
			var b := Button.new()
			b.text = str(r.get("button", "")) if str(r.get("button", "")) != "" else str(r.get("label", ""))
			b.focus_mode = Control.FOCUS_NONE
			b.custom_minimum_size.y = ThemeManager.px.touch
			b.disabled = not bool(r.get("enabled", true))
			b.pressed.connect(func(): if not _rows.dragged: Core.settings_dialog(i); _refresh(true))
			items.append(b)
		else:
			items.append(UI.label(str(r.get("label", "")), "body", "body", "dim"))
	var v := UI.vbox(items, 0.6)
	UI.style_boxes(v)
	card.add_child(v)
	return card


func _note(text: String) -> Label:
	var l := UI.label(text, "body", "body", "dim")
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	return l


func _livi_or_look(id: Variant, what: String) -> void:
	if id is String:
		match what:
			"toggle":
				_look_set(id, not ThemeManager.get(id))
			"open":
				_look_pick = id
				_rows.offset = 0.0
				_refresh(true)
		return
	var i := int(id)
	match what:
		"toggle":
			Core.settings_toggle(i)
		"press":
			Core.settings_press(i)
		"open":
			var r: Dictionary = _view.get("rows", [])[i]
			if bool(r.get("confirms", false)) and _armed != i:
				_armed = i
				_armed_ms = Time.get_ticks_msec()
				_refresh(true)
				return
			_armed = -1
			Core.settings_open(i)
			_rows.offset = 0.0
	_refresh(true)


func _pick(id: Variant, i: int) -> void:
	if id is String:
		_look_set(id, _look_row(id).options[i].value)
		return
	Core.settings_pick(int(id), i)
	_refresh(true)


func _on_up() -> void:
	if section is String:
		_look_pick = ""
	else:
		Core.settings_back()
	_rows.offset = 0.0
	_refresh(true)


func _on_apply() -> void:
	Core.settings_apply()
	_refresh(true)


## The shell's own look, as rows in the same shape as LIVI's.
func _look_rows() -> Array:
	var themes := []
	for t in ThemeManager.theme_names():
		themes.append([t, t.capitalize()])
	var rows := [
		_look_choice("theme_name", "Theme", themes),
		_look_choice("appearance_mode", "Day or night", [["auto", "Auto"], ["day", "Day"], ["night", "Night"]],
			"Auto follows LIVI's appearance"),
		_look_choice("hand", "Steering wheel", [["lhd", "Left"], ["rhd", "Right"]]),
		_look_choice("near", "Nearer the driver", [["projection", "Phone"], ["panel", "Panel"]]),
		_look_choice("text_scale", "Text size", [[0.9, "Small"], [1.0, "Standard"], [1.2, "Large"], [1.4, "Larger"]]),
		_look_choice("material", "Surfaces", [["solid", "Solid"], ["frosted", "Frosted"], ["glass", "Glass"]]),
		{key = "reduced_motion", kind = "switch", label = "Reduced motion", detail = "No animated transitions", checked = ThemeManager.reduced_motion, enabled = true},
		_look_choice("quality", "3D quality", [["normal", "Normal"], ["low", "Low"]]),
		_look_choice("ev_page", "Electric vehicle page", [["auto", "Auto"], ["image", "Image"], ["live", "Live"]]),
	]
	return rows


func _look_choice(key: String, label: String, opts: Array, detail := "") -> Dictionary:
	var now = ThemeManager.get(key)
	var options := []
	var shown := ""
	for o in opts:
		var sel: bool = is_equal_approx(float(o[0]), float(now)) if o[0] is float else str(o[0]) == str(now)
		options.append({label = o[1], value = o[0], selected = sel})
		if sel:
			shown = o[1]
	return {key = key, kind = "value", label = label, detail = detail, value = "" if _inline(options) else shown, options = options, enabled = true}


func _look_row(key: String) -> Dictionary:
	for r in _look_rows():
		if r.key == key:
			return r
	return {label = "", options = []}


func _look_set(key: String, value: Variant) -> void:
	var look := {}
	look[key] = value
	ThemeManager.set_look(look)
	ThemeManager.save_look()


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


static var _dots := {}


static func _dot(px: float, color: Color) -> Texture2D:
	var key := "%d:%s" % [roundi(px), color.to_html()]
	if not _dots.has(key):
		var svg := '<svg xmlns="http://www.w3.org/2000/svg" width="24" height="24"><circle cx="12" cy="12" r="11" fill="#%s"/></svg>' % color.to_html(false)
		var img := Image.new()
		img.load_svg_from_string(svg, maxf(8.0, px) / 24.0)
		_dots[key] = ImageTexture.create_from_image(img)
	return _dots[key]


## An on/off switch: a track in the accent when on, the knob at that end.
class SwitchMark:
	extends Control
	var on := false

	func _init(checked: bool) -> void:
		on = checked
		name = "Switch"
		custom_minimum_size = Vector2(ThemeManager.px.touch * 1.5, ThemeManager.px.touch * 0.8)
		size_flags_vertical = Control.SIZE_SHRINK_CENTER

	func _draw() -> void:
		var h := size.y
		var track := StyleBoxFlat.new()
		track.bg_color = ThemeManager.c.accent if on else ThemeManager.c.surface2
		track.set_corner_radius_all(roundi(h / 2.0))
		track.border_color = ThemeManager.c.line
		track.set_border_width_all(0 if on else 2)
		track.anti_aliasing = true
		draw_style_box(track, Rect2(Vector2.ZERO, size))
		var r := h * 0.36
		var x := size.x - h / 2.0 if on else h / 2.0
		draw_circle(Vector2(x, h / 2.0), r, ThemeManager.c.on_accent if on else ThemeManager.c.dim, true, -1.0, true)
