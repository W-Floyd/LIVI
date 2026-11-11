class_name SettingsPage
extends Control
## Settings: LIVI's own (the tree and values stock LIVI's UI shows, from livi-ui-model through
## `Core.settings_*`, which also sends what each touch changes), the shell's look, and the apps'
## that describe theirs (`load_apps`). Sections on
## the left, the open one's rows on the right; both lists drag. A short choice is set in place,
## a long one opens its list; a change that restarts the phone's connection waits for Apply.

signal back_pressed

const LOOK := "look"
## The driving lockout's choices (Drive).
const DRIVING := "driving"
## Choices with up to this many options, all short, are set in place.
const INLINE_OPTIONS := 4
const INLINE_CHARS := 28
## Sliders send while they move, at most this often, as stock's do.
const SLIDE_MS := 100
## A second tap within this acts: restarts, powers off, forgets a phone, removes a file.
const CONFIRM_MS := 4000
## Core sections whose change can show on a settings page.
const READS := ["config", "system", "sessions", "devices", "precondition", "telemetry", "mfi", "dab", "fm", "update", "cluster", "cameras"]
const REFRESH_S := 0.25
## An app's values file is read again this often while its section is open: the app writes it too.
const APP_WATCH_S := 0.5
## Apps' settings: `<dir>/*.json`, one schema per app (godot-maps installs one): `id`, `title`,
## `icon` (an Icons name), `values` (its values file, under `config_home`), and `sections`:
## [{title, rows: [{key, kind: toggle | choice | slider | text | info, label, detail, default,
## options: [{value, label}] (choice), min, max, labels (slider)}]}]. The values file is a JSON
## object of key -> value; a key missing is its default. Rewritten whole, through a rename.
static var app_dirs := default_app_dirs()
static var config_home := default_config_home()

var top_inset := 0.0

## The section open: LOOK, or an index into LIVI's sections.
var section: Variant = 0
var _view := {}
var _shown_json := ""
## The look's or an app's row whose options are open.
var _look_pick := ""
## "app:<id>" -> that app's schema.
var _apps := {}
var _app_text := ""
var _app_watch_s := 0.0
## What a second tap acts on: a row's index, or "row/tool".
var _armed := ""
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
var _entry: TextEntry


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
	Drive.changed.connect(func(): if _driving(): _refresh(true))
	resized.connect(_place)
	_apps = load_apps()
	Core.settings_section(int(section) if section is int else -1)
	_style()


func _exit_tree() -> void:
	Core.settings_leave()


func _process(delta: float) -> void:
	_dirty_s += delta
	if _dirty and not _sliding and _dirty_s >= REFRESH_S:
		_dirty = false
		_refresh()
	if _armed != "" and Time.get_ticks_msec() - _armed_ms > CONFIRM_MS:
		_armed = ""
		_refresh(true)
	_app_watch_s += delta
	if _app_open() and not _sliding and _app_watch_s >= APP_WATCH_S:
		_app_watch_s = 0.0
		if _app_file_text() != _app_text:
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


## Opens a section: LOOK, an app's ("app:<id>") or LIVI's by index.
func open_section(s: Variant) -> void:
	section = s
	_look_pick = ""
	_armed = ""
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
	var left := g * 1.5
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
		_heading_label.text = str(_apps[section].get("title", "")) if _app_open() and _look_pick == "" \
			else ("Driving" if _driving() else "Look") if _look_pick == "" else _look_row(_look_pick).label
		_up.visible = _look_pick != ""
		if _look_pick == "":
			for r in _look_rows():
				_rows.list.add_child(_group_heading(r.label) if r.kind == "heading" else _row(r, r.key))
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
	var items: Array = [[LOOK, "Look", "brush"], [DRIVING, "Driving", "car"]]
	for id in _apps:
		var icon := str(_apps[id].get("icon", ""))
		items.append([id, str(_apps[id].get("title", id)), icon if Icons.PATHS.has(icon) else "gear"])
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
				# Skipped, not removed: a row's index is what a touch sends back.
				if r.get("hidden", false):
					continue
				if str(i) == _armed:
					r = r.duplicate()
					r.label = "Tap again: %s" % r.label
					r.alert = true
				_rows.list.add_child(_row(r, i))
		"select":
			var opts: Array = _view.get("options", [])
			_add_picks(opts, func(i): if not bool(_view.get("readOnly", false)): Core.settings_pick(-1, i); _refresh(true))
		"number":
			_rows.list.add_child(_number_page())
			_rows.list.add_child(_keypad_button())
		"slider":
			var r := {kind = "value", label = _heading_label.text, enabled = true, slider = {level = _view.get("level", 0.0), text = _view.get("text", "")}}
			_rows.list.add_child(_row(r, -1))
		"text", "color":
			var r := {kind = "info", label = str(_view.get("value", "")), value = "", enabled = true}
			_rows.list.add_child(_row(r, -1))
			_type_text()
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
	var tools: Array = r.get("tools", [])
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
		elif bool(r.get("acts", false)) and kind != "button" and kind != "item":
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

	var armed_tool := -1
	for j in tools.size():
		if _armed == "%s/%d" % [id, j]:
			armed_tool = j
	var title := str(r.get("label", ""))
	if armed_tool >= 0:
		title = "Tap again: %s" % str(tools[armed_tool].get("label", ""))
	var label := UI.label(title, "strong", "body", "crit" if r.get("alert", false) or armed_tool >= 0 else "text")
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
	elif kind == "progress":
		side = _progress(float(r.get("level", 0.0)))
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
	var lead := _lead(r)
	if lead:
		parts.append(lead)
	parts.append(text)
	if side:
		if side is Label or side is SwitchMark:
			side.mouse_filter = Control.MOUSE_FILTER_IGNORE
		parts.append(side)
	if r.get("device") is Dictionary:
		parts.append(_device_marks(r.device, bool(r.get("dimmed", false))))
	for j in tools.size():
		parts.append(_tool_button(tools[j], int(id), j, j == armed_tool))
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
	# A phone's row stays lit for its tools: offline only dims what it shows of the phone.
	if r.get("device") is Dictionary:
		if r.get("dimmed", false):
			text.modulate.a = 0.5
			if lead:
				lead.modulate.a = 0.5
	elif not enabled or r.get("dimmed", false):
		b.modulate.a = 0.5
	if tap != "":
		b.pressed.connect(func(): if not _rows.dragged: _livi_or_look(id, tap))
	return b


## What leads a row: its file or folder, the phone's kind (lit while it is the one shown), a
## station's logo or initials, or a picture (the phone icon).
func _lead(r: Dictionary) -> Control:
	var px: float = ThemeManager.px.icon
	if str(r.get("kind", "")) == "picture":
		var tex := _png(str(r.get("value", "")))
		if tex == null:
			return null
		var pic := TextureRect.new()
		pic.name = "Picture"
		pic.texture = tex
		pic.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		pic.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		pic.custom_minimum_size = Vector2.ONE * ThemeManager.px.touch * 2.4
		pic.mouse_filter = Control.MOUSE_FILTER_IGNORE
		return pic
	if r.get("device") is Dictionary:
		var d: Dictionary = r.device
		var lit := str(d.get("presence", "")) == "active"
		var ic := UI.icon(str(d.get("protocol", "phone")), "icon", "accent" if lit else "dim")
		ic.name = "Protocol"
		return ic
	if r.get("badge") is Dictionary:
		return Badge.new(r.badge, _png(str(r.badge.get("logo", "")) if r.badge.get("logo") != null else ""), px * 1.5)
	if str(r.get("glyph", "")) != "":
		return UI.icon(str(r.glyph), "icon", "dim")
	return null


## A phone's link, battery, signal and presence, as stock's device row shows them.
func _device_marks(d: Dictionary, dimmed: bool) -> Control:
	var parts: Array = []
	var t = d.get("transport")
	if t != null and str(t) != "":
		var ic := UI.icon(str(t), "icon", "dim")
		ic.name = "Transport"
		parts.append(ic)
	if d.get("battery") != null:
		parts.append(BatteryMark.new(int(d.battery), bool(d.get("charging", false))))
	if d.get("signal") != null:
		parts.append(SignalMark.new(int(d.signal)))
	parts.append(PresenceDot.new(str(d.get("presence", "offline"))))
	var box := UI.hbox(parts, 0.8)
	box.name = "Device"
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	for c in box.get_children():
		if c is Control:
			c.mouse_filter = Control.MOUSE_FILTER_IGNORE
			c.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	if dimmed:
		box.modulate.a = 0.45
	return box


## A row's tool: an icon button (tinted when on), or a switch; armed, it turns critical.
func _tool_button(t: Dictionary, row: int, j: int, armed: bool) -> Control:
	var enabled := bool(t.get("enabled", true))
	var b: Button
	if bool(t.get("switch", false)):
		b = Button.new()
		b.add_child(SwitchMark.new(bool(t.get("on", false))))
		b.custom_minimum_size = Vector2(ThemeManager.px.touch * 1.6, ThemeManager.px.touch)
		var sw: Control = b.get_child(0)
		sw.mouse_filter = Control.MOUSE_FILTER_IGNORE
		sw.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
		for st in ["normal", "hover", "pressed", "hover_pressed", "focus", "disabled"]:
			b.add_theme_stylebox_override(st, _flat_box(Color(0, 0, 0, 0)))
	else:
		b = _flat_button(str(t.get("icon", "")), str(t.get("icon", "close")))
		_style_flat(b)
		var tint = t.get("tint")
		var c: Color = ThemeManager.c.crit if armed else (Color.from_string(str(tint), ThemeManager.c.text) if tint != null else ThemeManager.c.text)
		for k in ["icon_normal_color", "icon_hover_color", "icon_pressed_color", "icon_focus_color"]:
			b.add_theme_color_override(k, c)
		if armed:
			b.add_theme_stylebox_override("normal", _flat_box(Color(ThemeManager.c.crit, 0.18)))
	b.name = "Tool%d" % j
	b.tooltip_text = str(t.get("label", ""))
	b.focus_mode = Control.FOCUS_NONE
	b.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	b.disabled = not enabled
	b.pressed.connect(func(): if not _rows.dragged: _tool(row, j, t))
	return b


func _progress(level: float) -> Control:
	var bar := ProgressBar.new()
	bar.name = "Progress"
	bar.min_value = 0.0
	bar.max_value = 1.0
	bar.value = clampf(level, 0.0, 1.0)
	bar.show_percentage = false
	bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	bar.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bar.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	bar.custom_minimum_size = Vector2(size.x * 0.2, ThemeManager.px.gap * 0.7)
	var track := _flat_box(ThemeManager.c.surface2)
	var fill := _flat_box(ThemeManager.c.accent)
	for f in [track, fill]:
		f.set_corner_radius_all(roundi(ThemeManager.px.gap * 0.35))
		f.content_margin_left = 0
		f.content_margin_right = 0
	bar.add_theme_stylebox_override("background", track)
	bar.add_theme_stylebox_override("fill", fill)
	return bar


static var _pngs := {}


## A base64 PNG (the phone icon, a station's logo) as a texture; null when it is not one.
static func _png(b64: String) -> Texture2D:
	if b64 == "":
		return null
	var key := b64.hash()
	if not _pngs.has(key):
		var img := Image.new()
		var ok := img.load_png_from_buffer(Marshalls.base64_to_raw(b64)) == OK
		_pngs[key] = ImageTexture.create_from_image(img) if ok else null
	return _pngs[key]


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
	sl.step = float(s.get("step", 0.01))
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
		if _sliding and now - _slide_ms >= SLIDE_MS and id is int:
			_slide_ms = now
			Core.settings_level(int(id), v))
	sl.drag_ended.connect(func(_changed):
		_sliding = false
		_slide_ms = 0
		if id is String:
			_look_set(id, lerpf(float(s.get("min", 0.0)), float(s.get("max", 1.0)), sl.value))
		else:
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


## A text page opens straight onto the keyboard: Done sends what stock's commit sends and goes
## back up (stock's page closes once taken); cancel goes back up with nothing sent.
func _type_text() -> void:
	if is_instance_valid(_entry):
		return
	var lo = _view.get("minLen")
	var hi = _view.get("maxLen")
	_entry = TextEntry.edit(self, {label = _heading_label.text, value = _view.get("value", ""),
		secret = bool(_view.get("secret", false)), min_len = int(lo) if lo != null else 0, max_len = int(hi) if hi != null else 0})
	_entry.on_commit = func(t: String) -> bool: return Core.settings_text(-1, t)
	_entry.closed.connect(func(taken: bool):
		_entry = null
		if not taken:
			Core.settings_back()
		_rows.offset = 0.0
		_refresh(true))


func _keypad_button() -> Button:
	var b := Button.new()
	b.name = "Type"
	b.text = "Type a value"
	b.icon = Icons.texture("keyboard", ThemeManager.px.icon)
	b.focus_mode = Control.FOCUS_NONE
	b.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	b.custom_minimum_size.y = ThemeManager.px.touch
	b.pressed.connect(func(): if not _rows.dragged: _type_number())
	return b


func _type_number() -> void:
	if is_instance_valid(_entry):
		return
	var v := float(_view.get("value", 0.0))
	var lo = _view.get("min")
	_entry = TextEntry.edit(self, {label = _heading_label.text, kind = "number",
		value = str(int(v)) if is_equal_approx(v, roundf(v)) else str(v),
		decimals = float(_view.get("step", 1.0)) < 1.0, negative = lo == null or float(lo) < 0.0})
	_entry.on_commit = func(t: String) -> bool:
		Core.settings_number(-1, float(t.replace(",", ".")))
		return true
	_entry.closed.connect(func(_taken: bool):
		_entry = null
		_refresh(true))


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
				_look_set(id, not bool(_look_row(id).get("checked", false)))
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
			var r: Dictionary = _view.get("rows", [])[i]
			Core.settings_press(i)
			# Stock shows the phone it just switched to.
			if str(r.get("local", "")) == "projection":
				_to_projection()
				return
		"open":
			var r: Dictionary = _view.get("rows", [])[i]
			if bool(r.get("confirms", false)) and _armed != str(i):
				_arm(str(i))
				return
			_armed = ""
			Core.settings_open(i)
			_rows.offset = 0.0
	_refresh(true)


func _arm(key: String) -> void:
	_armed = key
	_armed_ms = Time.get_ticks_msec()
	_refresh(true)


func _tool(row: int, j: int, t: Dictionary) -> void:
	var key := "%d/%d" % [row, j]
	if bool(t.get("confirms", false)) and _armed != key:
		_arm(key)
		return
	_armed = ""
	Core.settings_tool(row, j)
	_refresh(true)


func _to_projection() -> void:
	var shell := get_parent()
	if shell and shell.has_method("open_page"):
		shell.open_page.call_deferred("projection")


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


## The shell's own look, or the open app's settings, as rows in the same shape as LIVI's.
func _look_rows() -> Array:
	if _app_open():
		return _app_rows()
	var themes := []
	for t in ThemeManager.theme_names():
	if _driving():
		return _driving_rows()
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
		_look_choice("volume_style", "Volume indicator", [["card", "Card"], ["glow", "Line"]]),
		_look_choice("app_scale", "App size", [[0, "Auto (%d %%)" % Launcher.auto_scale()]] + Launcher.SCALES.map(func(p): return [p, "%d %%" % p]),
			"Apps from the launcher; hold an app's tile for its own"),
		{key = "home_phone", kind = "switch", label = "Phone on home", detail = "Android Auto or CarPlay beside the cards", checked = ThemeManager.home_phone, enabled = true},
		_look_choice("status_position", "Status bar", [["top", "Top"], ["bottom", "Bottom"], ["left", "Left"], ["right", "Right"], ["off", "Off"]]),
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
	if _app_open():
		_app_set(key, value)
		return
	var look := {}
	look[key] = value
	ThemeManager.set_look(look)
	if _driving():
		if key == "developer":
			Drive.set_developer(bool(value))
		else:
			Drive.set_mode(str(value))
		return
	ThemeManager.save_look()


## `$XDG_DATA_HOME`, then each of `$XDG_DATA_DIRS`, under `livi-shell/settings`.
static func default_app_dirs() -> PackedStringArray:
	var home := OS.get_environment("XDG_DATA_HOME")
func _driving() -> bool:
	return section is String and section == DRIVING


## The lockout while driving (Drive). While the car is driven its choice can only go back to
## following the car, and the developer options wait until it parks.
func _driving_rows() -> Array:
	var by := {regulation = "the car's driving lockout", gear = "the gear", parking_brake = "the parking brake and speed",
		speed = "speed", ignition = "the ignition"}
	var facts := []
	var gear = Core.get_value("/telemetry/gear")
	if gear != null:
		facts.append("gear %s" % str(gear))
	var now := "Driving" if Drive.moving else "Parked"
	if Drive.override() == "passenger":
		now = "Driving, unlocked for a passenger"
	var detail: String = ("By %s" % by[Drive.source]) if by.has(Drive.source) else "No driving data from the car"
	if not facts.is_empty():
		detail += " · " + ", ".join(facts)
	var modes := [["car", "Follow the car"], ["passenger", "Passenger mode"]]
	if Drive.developer:
		modes.append(["offroad", "Always offroad"])
	var details := {car = "Locks apps and typing as the car says", passenger = "A passenger can unlock each drive",
		offroad = "Never locks: for testing only"}
	var options := []
	var shown := ""
	for m in modes:
		var sel: bool = Drive.mode == m[0]
		options.append({label = m[1], value = m[0], selected = sel, offline = not Drive.may_set_mode(m[0]) and not sel})
		if sel:
			shown = m[1]
	var mode_detail: String = details[Drive.mode]
	if Drive.moving and Drive.mode == "car":
		mode_detail = "Change it when parked"
	return [
		{key = "now", kind = "info", label = now, detail = detail, enabled = true},
		{key = "mode", kind = "value", label = "While driving", detail = mode_detail, value = "" if _inline(options) else shown,
			options = options, enabled = not Drive.moving or Drive.mode != "car"},
		{key = "developer", kind = "switch", label = "Developer options", detail = "Offers Always offroad" if not Drive.moving else "Change it when parked",
			checked = Drive.developer, enabled = not Drive.moving},
	]


	var dirs := PackedStringArray([home if home != "" else OS.get_environment("HOME").path_join(".local/share")])
	var data := OS.get_environment("XDG_DATA_DIRS")
	dirs.append_array((data if data != "" else "/usr/local/share:/usr/share").split(":", false))
	var out := PackedStringArray()
	for d in dirs:
		out.append(d.path_join("livi-shell/settings"))
	return out


static func default_config_home() -> String:
	var d := OS.get_environment("XDG_CONFIG_HOME")
	return d if d != "" else OS.get_environment("HOME").path_join(".config")


## The apps' schemas in `app_dirs`, by "app:<id>"; an earlier dir's wins, as XDG's do.
static func load_apps() -> Dictionary:
	var out := {}
	for dir in app_dirs:
		for f in DirAccess.get_files_at(dir) if DirAccess.dir_exists_absolute(dir) else PackedStringArray():
			if not f.ends_with(".json"):
				continue
			var d = JSON.parse_string(FileAccess.get_file_as_string(dir.path_join(f)))
			if not d is Dictionary or not d.get("sections") is Array:
				continue
			var values := str(d.get("values", ""))
			if values == "" or values.begins_with("/") or ".." in values.split("/"):
				push_warning("settings: %s: values must be a path under the config dir" % f)
				continue
			var id := "app:" + str(d.get("id", f.get_basename()))
			if not out.has(id):
				out[id] = d
	return out


func _app_open() -> bool:
	return section is String and _apps.has(section)


func _app_file() -> String:
	return config_home.path_join(str(_apps[section].values))


func _app_file_text() -> String:
	return FileAccess.get_file_as_string(_app_file()) if FileAccess.file_exists(_app_file()) else ""


func _app_values() -> Dictionary:
	_app_text = _app_file_text()
	var d = JSON.parse_string(_app_text) if _app_text != "" else null
	return d if d is Dictionary else {}


## The open app's schema as rows, a heading before each of its sections.
func _app_rows() -> Array:
	var values := _app_values()
	var rows := []
	for sec in _apps[section].sections:
		rows.append({key = "", kind = "heading", label = str(sec.get("title", ""))})
		for r in sec.get("rows", []):
			var key := str(r.get("key", ""))
			rows.append(_app_row(r, values.get(key, r.get("default"))))
	return rows


func _app_row(r: Dictionary, v: Variant) -> Dictionary:
	var out := {key = str(r.get("key", "")), kind = "value", label = str(r.get("label", "")), detail = str(r.get("detail", "")), enabled = true}
	match str(r.get("kind", "")):
		"toggle":
			out.kind = "switch"
			out.checked = v is bool and v
		"choice":
			var options := []
			var shown := ""
			for o in r.get("options", []):
				var sel := _same(o.get("value"), v)
				options.append({label = str(o.get("label", "")), value = o.get("value"), selected = sel})
				if sel:
					shown = str(o.get("label", ""))
			out.options = options
			out.value = "" if _inline(options) else shown
		"slider":
			var lo := float(r.get("min", 0.0))
			var hi := float(r.get("max", 1.0))
			var level := clampf((float(v) - lo) / (hi - lo), 0.0, 1.0) if hi > lo and (v is float or v is int) else 0.0
			var labels: Array = r.get("labels", [])
			# Labels name evenly spaced stops; the slider snaps to them.
			var stops := labels.size() - 1
			var text := str(labels[roundi(level * stops)]) if stops >= 0 else str(snappedf(lerpf(lo, hi, level), 0.01))
			out.slider = {level = level, text = text, step = 1.0 / stops if stops > 0 else 0.01, min = lo, max = hi}
		_:
			out.value = str(v) if v != null else ""
	return out


static func _same(a: Variant, b: Variant) -> bool:
	if (a is float or a is int) and (b is float or b is int):
		return is_equal_approx(float(a), float(b))
	return typeof(a) == typeof(b) and a == b


## Sets one key in the open app's values file, keeping the rest as they are now.
func _app_set(key: String, value: Variant) -> void:
	var values := _app_values()
	values[key] = value
	var path := _app_file()
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var text := JSON.stringify(values, "  ")
	var f := FileAccess.open(path + ".tmp", FileAccess.WRITE)
	if f == null:
		push_error("settings: cannot write %s" % path)
		return
	f.store_string(text)
	f.close()
	DirAccess.rename_absolute(path + ".tmp", path)
	_app_text = text
	_refresh(true)


func _group_heading(text: String) -> Label:
	var l := UI.label(text.to_upper(), "strong", "caption", "dim")
	l.name = ("%s heading" % text).validate_node_name()
	return l


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


## A station's logo, or its initials on its colour, as stock's badge.
class Badge:
	extends Control
	var initials := ""
	var color := Color.GRAY
	var logo: Texture2D

	func _init(b: Dictionary, tex: Texture2D, px: float) -> void:
		name = "Badge"
		initials = str(b.get("initials", ""))
		color = Color.from_string(str(b.get("color", "#808080")), Color.GRAY)
		logo = tex
		custom_minimum_size = Vector2.ONE * px
		size_flags_vertical = Control.SIZE_SHRINK_CENTER
		mouse_filter = Control.MOUSE_FILTER_IGNORE

	func _draw() -> void:
		var r := Rect2(Vector2.ZERO, size)
		if logo:
			draw_texture_rect(logo, r, false)
			return
		var box := StyleBoxFlat.new()
		box.bg_color = color
		box.set_corner_radius_all(roundi(size.y * 0.2))
		box.anti_aliasing = true
		draw_style_box(box, r)
		var font: Font = ThemeManager.fonts.strong
		var fs := roundi(size.y * 0.4)
		var w := font.get_string_size(initials, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
		draw_string(font, Vector2((size.x - w) / 2.0, size.y / 2.0 + fs * 0.35), initials, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, Color.WHITE)


## Battery: an outline filled to the level, red under 10, amber under 20; a bolt while charging.
class BatteryMark:
	extends Control
	var level := 0
	var charging := false

	func _init(l: int, c: bool) -> void:
		name = "Battery"
		level = clampi(l, 0, 100)
		charging = c
		custom_minimum_size = Vector2(ThemeManager.px.icon * 2.0, ThemeManager.px.icon)

	func _draw() -> void:
		var h := size.y * 0.72
		var y := (size.y - h) / 2.0
		var w := size.x - h * 0.18
		var line := maxf(1.5, h * 0.08)
		draw_rect(Rect2(line / 2.0, y, w - line, h), ThemeManager.c.dim, false, line, true)
		draw_rect(Rect2(w, y + h * 0.3, h * 0.14, h * 0.4), ThemeManager.c.dim)
		var c := Color("#ff3b30") if level < 10 else (Color("#ffcc00") if level < 20 else Color("#34c759"))
		var inner := w - line * 4
		draw_rect(Rect2(line * 2, y + line * 1.5, maxf(line, inner * level / 100.0), h - line * 3), c)
		var font: Font = ThemeManager.fonts.strong
		var fs := roundi(h * 0.62)
		var text := str(level)
		var tw := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
		var at := Vector2(w - line * 3 - tw, y + h / 2.0 + fs * 0.36)
		draw_string_outline(font, at, text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, 3, ThemeManager.c.bg)
		draw_string(font, at, text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, ThemeManager.c.text)
		if charging:
			draw_texture_rect(Icons.texture("bolt", h), Rect2(line, y, h * 0.8, h), false, ThemeManager.c.text)


## Signal: five rising bars, lit to the level.
class SignalMark:
	extends Control
	var level := 0

	func _init(l: int) -> void:
		name = "Signal"
		level = clampi(l, 0, 5)
		custom_minimum_size = Vector2(ThemeManager.px.icon * 1.1, ThemeManager.px.icon * 0.7)

	func _draw() -> void:
		var bw := size.x / 5.0
		for i in 5:
			var h := size.y * (0.3 + 0.175 * i)
			var c: Color = ThemeManager.c.text if i < level else Color(ThemeManager.c.dim, 0.35)
			draw_rect(Rect2(i * bw, size.y - h, bw * 0.62, h), c)


## Presence: filled in the accent while shown, in the text colour while there, a ring offline.
class PresenceDot:
	extends Control
	var presence := ""

	func _init(p: String) -> void:
		name = "Presence"
		presence = p
		custom_minimum_size = Vector2.ONE * ThemeManager.px.icon * 0.5

	func _draw() -> void:
		var r := size.x / 2.0
		match presence:
			"active":
				draw_circle(size / 2.0, r, ThemeManager.c.accent, true, -1.0, true)
			"available":
				draw_circle(size / 2.0, r, ThemeManager.c.text, true, -1.0, true)
			_:
				draw_circle(size / 2.0, r - 1.0, ThemeManager.c.dim, false, 2.0, true)
