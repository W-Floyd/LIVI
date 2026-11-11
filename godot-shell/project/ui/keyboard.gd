class_name Keyboard
extends Control
## An on-screen keyboard for a finger: QWERTY with shift and caps lock, two layers of numbers and
## symbols, or a numeric keypad. Keys act as they go down, as a finger expects; backspace repeats
## while held. Its own layout fills whatever size it is given.

signal typed(text: String)
signal erased
signal submitted
signal cancelled

## A second shift tap within this locks caps.
const CAPS_TAP_S := 0.4
const REPEAT_DELAY_S := 0.45
const REPEAT_S := 0.07
## How long a tapped key stays lit: a quick tap is only a frame or two down.
const LIT_S := 0.12
const POP_S := 0.12

## Rows of keys: a character, or [id, width in key units]. Ids name the specials.
const LAYERS := {
	letters = [
		["q", "w", "e", "r", "t", "y", "u", "i", "o", "p", ["back", 1.5]],
		["a", "s", "d", "f", "g", "h", "j", "k", "l", ["done", 2.5]],
		[["shift", 1.25], "z", "x", "c", "v", "b", "n", "m", ",", ".", ["shift", 1.25]],
		[["symbols", 1.75], ["cancel", 1.75], ["space", 5.0], "'", "-", "@"],
	],
	symbols = [
		["1", "2", "3", "4", "5", "6", "7", "8", "9", "0", ["back", 1.5]],
		["@", "#", "$", "%", "&", "*", "(", ")", "+", ["done", 2.5]],
		[["more", 2.5], "!", "\"", ":", ";", "/", "?", "=", "_", "."],
		[["letters", 1.75], ["cancel", 1.75], ["space", 5.0], "'", "-", ","],
	],
	more = [
		["1", "2", "3", "4", "5", "6", "7", "8", "9", "0", ["back", 1.5]],
		["[", "]", "{", "}", "<", ">", "~", "`", "|", ["done", 2.5]],
		[["symbols", 2.5], "\\", "^", "_", ".", ",", "'", "-", "/", "@"],
		[["letters", 1.75], ["cancel", 1.75], ["space", 5.0], "!", "?", "#"],
	],
	number = [
		["1", "2", "3", ["back", 1.5]],
		["4", "5", "6", ["cancel", 1.5]],
		["7", "8", "9", ["sign", 1.5]],
		[".", "0", ["done", 2.5]],
	],
}
const NAMES := {back = "Backspace", done = "Done", shift = "Shift", symbols = "Symbols", letters = "Letters", more = "More", cancel = "Cancel", space = "Space", sign = "Sign"}
const LABELS := {symbols = "?123", letters = "ABC", more = "=\\<", space = "", done = "Done", sign = "±"}

## text | number: a keypad, for numbers.
var mode := "text":
	set(v):
		mode = v
		layer = "number" if v == "number" else "letters"
		shift = 0
		# Built keys are kept: only the letters' last row depends on the field.
		if _layers.is_empty() or _build_queued or extras != _built_extras:
			_queue_build()
		else:
			_show(layer)
			_style_ids(["shift", "sign", "."])
			_style_shift()
## The keypad's point and sign keys.
var decimals := true
var negative := false
## Off: the next letter is lower case. 1: that one is upper case. 2: caps lock.
var shift := 0
var layer := "letters"
## Three keys in place of the letters' last three ("'", "-", "@"): a field's own, such as "/"
## and ":" for a web address. Set before `mode`.
var extras: Array = []
## No pop as a key goes down: nothing that shows a password's characters from across the car.
var quiet := false
## What the Done key says: the field's action ("Go"), or "Enter" where it is a key like any other.
var done_label := "Done":
	set(v):
		done_label = v
		_style_ids(["done"])
## Done dimmed while what is typed would not be taken.
var done_ready := true:
	set(v):
		done_ready = v
		_style_ids(["done"])

## The layer showing, named Keys; the others are built the frame after, hidden, named
## Keys_<layer>, so a layer key switches at once and the keyboard's first frame waits for one.
var _keys: Control
var _layers := {}
var _build_queued := false
## `extras` as the letters were built with.
var _built_extras: Array = []
var _held: Button
var _repeat := 0.0
var _shift_at := -1.0
var _now := 0.0


func _init() -> void:
	name = "Keyboard"
	mouse_filter = Control.MOUSE_FILTER_STOP
	resized.connect(_place)


## A finger's press comes as a touch and, first, as the mouse Godot emulates from it: the button
## takes the touch alone, so a key acts once and on the press.
static func touch_only(b: BaseButton) -> void:
	b.gui_input.connect(func(e: InputEvent): if e is InputEventMouse and e.device == InputEvent.DEVICE_ID_EMULATION: b.accept_event())


func _ready() -> void:
	ThemeManager.changed.connect(_queue_build)
	_queue_build()


## Once, at the end of this frame, however many settings changed: before it is drawn.
func _queue_build() -> void:
	if not _build_queued:
		_build_queued = true
		_build.call_deferred()


func _process(delta: float) -> void:
	_now += delta
	if _held == null:
		return
	if not is_instance_valid(_held) or not _held.is_pressed():
		_held = null
		return
	_repeat += delta
	while _repeat >= REPEAT_S:
		_repeat -= REPEAT_S
		erased.emit()


func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), ThemeManager.c.surface)


## The key with this id or character, for tests and for a host that wants to point at one.
func key(id: String) -> Button:
	if _build_queued:
		_build()
	return _keys.get_node_or_null(NodePath(_node_name(id))) as Button if _keys else null


## The layer showing now; the rest the next frame.
func _build() -> void:
	_build_queued = false
	if not is_inside_tree():
		return
	for l in _layers.values():
		remove_child(l)
		l.queue_free()
	_layers.clear()
	_keys = null
	_held = null
	_built_extras = extras.duplicate()
	_show(layer)
	if not get_tree().process_frame.is_connected(_ensure_all):
		get_tree().process_frame.connect(_ensure_all, CONNECT_ONE_SHOT)


func _ensure_all() -> void:
	for l in LAYERS:
		_ensure(l)


## The layer's keys, built, styled and placed if they are not yet.
func _ensure(l: String) -> Control:
	if _layers.has(l):
		return _layers[l]
	var c := Control.new()
	c.name = "Keys_" + l
	c.mouse_filter = Control.MOUSE_FILTER_IGNORE
	c.visible = false
	c.set_meta("layer", l)
	add_child(c)
	_layers[l] = c
	for row in _rows(l):
		for k in row:
			var id: String = k[0] if k is Array else k
			var b := _key_button(id)
			# A second shift: same key, its own node.
			if c.has_node(NodePath(b.name)):
				b.name = b.name + "2"
			b.set_meta("layer", l)
			c.add_child(b)
			_style_key(b)
	_place_layer(l)
	return c


## The layer's keys in front, named Keys.
func _show(l: String) -> void:
	var c := _ensure(l)
	if _keys:
		_keys.visible = false
		_keys.name = "Keys_" + str(_keys.get_meta("layer"))
	layer = l
	_keys = c
	_keys.name = "Keys"
	_keys.visible = true


func _key_button(id: String) -> Button:
	var b := Button.new()
	b.name = _node_name(id)
	b.focus_mode = Control.FOCUS_NONE
	b.set_meta("id", id)
	b.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
	b.vertical_icon_alignment = VERTICAL_ALIGNMENT_CENTER
	# Neither the label nor the icon may make a key wider than its place (`_place_layer`).
	b.clip_text = true
	b.expand_icon = true
	touch_only(b)
	b.button_down.connect(_down.bind(b))
	return b


static func _node_name(id: String) -> String:
	if NAMES.has(id):
		return NAMES[id]
	if id.validate_node_name() == id and id != "":
		return id
	return "U%04X" % id.unicode_at(0)


## A layer's rows, with `extras` in the letters' last row; narrow, that row's characters go
## (the symbols layer has them) and space takes their room.
func _rows(l: String) -> Array:
	var rows: Array = LAYERS[l]
	if l != "letters" or (extras.size() != 3 and not _narrow):
		return rows
	rows = rows.duplicate(true)
	var last: Array = rows[-1]
	if _narrow:
		rows[-1] = last.filter(func(k): return k is Array).map(func(k): return ["space", 8.0] if k[0] == "space" else k)
	else:
		rows[-1] = last.slice(0, last.size() - 3) + extras
	return rows


## Letters narrower than a finger's touch size.
var _narrow := false


func _place() -> void:
	var narrow: bool = size.x > 0.0 and (size.x - ThemeManager.px.gap * 3.0) / 11.5 < ThemeManager.px.touch
	if narrow != _narrow and not _layers.is_empty():
		_narrow = narrow
		_build()
		return
	_narrow = narrow
	for l in _layers:
		_place_layer(l)


func _place_layer(l: String) -> void:
	var rows: Array = _rows(l)
	var g: float = ThemeManager.px.gap
	var pad := g * 1.5
	var units := 0.0
	for row in rows:
		units = maxf(units, _row_units(row))
	var u := (size.x - pad * 2.0) / units
	var kh := minf((size.y - pad * 2.0) / rows.size(), ThemeManager.px.touch * 2.2)
	if l == "number":
		# A keypad's keys need not be as wide as the whole side.
		u = minf(u, kh * 1.6)
	var top := (size.y - kh * rows.size()) / 2.0
	var i := 0
	var keys: Array = _layers[l].get_children()
	for r in rows.size():
		var row: Array = rows[r]
		var x := (size.x - _row_units(row) * u) / 2.0
		for k in row:
			var w: float = (k[1] if k is Array else 1.0) * u
			var b: Button = keys[i]
			b.position = Vector2(x + g * 0.4, top + r * kh + g * 0.4)
			b.size = Vector2(w - g * 0.8, kh - g * 0.8)
			b.pivot_offset = b.size / 2.0
			b.add_theme_constant_override("icon_max_width", roundi(minf(ThemeManager.px.icon * 1.3, minf(b.size.x, b.size.y) * 0.6)))
			_fit_font(b)
			x += w
			i += 1


## The key's size (`fs` meta), smaller until its label fits its width.
func _fit_font(b: Button) -> void:
	var fs: int = b.get_meta("fs", 0)
	if fs <= 0 or b.size.x <= 0.0:
		return
	fs = mini(fs, roundi(b.size.y * 0.6))
	var room: float = b.size.x - ThemeManager.px.gap
	var f: Font = ThemeManager.fonts.strong
	while fs > 8 and b.text != "" and f.get_string_size(b.text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x > room:
		fs -= 1
	b.add_theme_font_size_override("font_size", fs)


func _row_units(row: Array) -> float:
	var n := 0.0
	for k in row:
		n += k[1] if k is Array else 1.0
	return n


func _style_keys() -> void:
	if _keys == null:
		return
	for c in _layers.values():
		for b in c.get_children():
			_style_key(b)
	queue_redraw()


## Only these keys, in every built layer: a label or state that changed.
func _style_ids(ids: Array) -> void:
	for c in _layers.values():
		for b in c.get_children():
			if b.get_meta("id") in ids:
				_style_key(b)


## After shift: the letters' case and the shift keys, not every key's boxes.
func _style_shift() -> void:
	if not _layers.has("letters"):
		return
	for b in _layers["letters"].get_children():
		var id: String = b.get_meta("id")
		if id == "shift":
			_style_key(b)
		elif id.length() == 1:
			b.text = _label(id, "letters")
			_fit_font(b)


func _style_key(b: Button) -> void:
	var fs := roundi(ThemeManager.px.title * 1.3)
	var id: String = b.get_meta("id")
	var l: String = b.get_meta("layer")
	var special := id.length() > 1
	b.text = _label(id, l)
	b.icon = null
	var icon := _icon(id)
	if icon != "":
		b.icon = Icons.texture(icon, ThemeManager.px.icon * 1.3)
	b.add_theme_font_override("font", ThemeManager.fonts.strong)
	b.set_meta("fs", fs if not special or id == "sign" else ThemeManager.font_size("body"))
	b.add_theme_font_size_override("font_size", b.get_meta("fs"))
	_fit_font(b)
	var fill: Color = ThemeManager.c.surface2
	var ink: Color = ThemeManager.c.text
	if id == "done":
		fill = ThemeManager.c.accent
		ink = ThemeManager.c.on_accent
	elif id == "shift" and shift > 0:
		fill = ThemeManager.c.accent if shift == 2 else ThemeManager.c.surface2.lerp(ThemeManager.c.accent, 0.35)
		ink = ThemeManager.c.on_accent if shift == 2 else ThemeManager.c.text
	elif special:
		fill = ThemeManager.c.bg
	var normal := _box(fill)
	var lit := _box(ThemeManager.c.accent)
	b.set_meta("normal", normal)
	b.set_meta("lit", lit)
	for s in ["normal", "hover", "focus", "disabled"]:
		b.add_theme_stylebox_override(s, normal)
	for s in ["pressed", "hover_pressed"]:
		b.add_theme_stylebox_override(s, lit)
	for k in ["font_color", "font_hover_color", "font_focus_color", "font_disabled_color"]:
		b.add_theme_color_override(k, ink)
	for k in ["icon_normal_color", "icon_hover_color", "icon_focus_color", "icon_disabled_color"]:
		b.add_theme_color_override(k, ink)
	for k in ["font_pressed_color", "font_hover_pressed_color", "icon_pressed_color", "icon_hover_pressed_color"]:
		b.add_theme_color_override(k, ThemeManager.c.on_accent)
	b.disabled = (id == "sign" and not negative) or (id == "." and l == "number" and not decimals)
	b.modulate.a = 0.45 if b.disabled or (id == "done" and not done_ready) else 1.0


func _label(id: String, l: String) -> String:
	if id == "done":
		return done_label
	if LABELS.has(id):
		return LABELS[id]
	if _icon(id) != "":
		return ""
	return id.to_upper() if shift > 0 and l == "letters" else id


func _icon(id: String) -> String:
	match id:
		"back":
			return "backspace"
		"cancel":
			return "close"
		"shift":
			return ["shift", "shift_on", "caps"][shift]
	return ""


func _box(fill: Color) -> StyleBoxFlat:
	var f := StyleBoxFlat.new()
	f.bg_color = fill
	f.set_corner_radius_all(roundi(maxf(ThemeManager.px.radius, ThemeManager.px.gap * 0.6)))
	f.content_margin_left = ThemeManager.px.gap * 0.5
	f.content_margin_right = ThemeManager.px.gap * 0.5
	f.anti_aliasing = true
	return f


func _down(b: Button) -> void:
	var id: String = b.get_meta("id")
	_feedback(b)
	match id:
		"back":
			erased.emit()
			_held = b
			_repeat = -REPEAT_DELAY_S
		"done":
			submitted.emit()
		"cancel":
			cancelled.emit()
		"space":
			typed.emit(" ")
		"shift":
			if shift == 2:
				shift = 0
			elif shift == 1 and _now - _shift_at < CAPS_TAP_S:
				shift = 2
			else:
				shift = 1 - shift
			_shift_at = _now
			_style_shift()
		"symbols", "letters", "more":
			_show(id)
		"sign":
			typed.emit("-")
		_:
			typed.emit(id.to_upper() if shift > 0 and layer == "letters" else id)
			if shift == 1:
				shift = 0
				_style_shift()


func _unlight(id: int) -> void:
	var b := instance_from_id(id) as Button
	if is_instance_valid(b) and b.has_meta("normal"):
		b.add_theme_stylebox_override("normal", b.get_meta("normal"))


## Lit for a moment, and a small pop unless motion is reduced.
func _feedback(b: Button) -> void:
	b.add_theme_stylebox_override("normal", b.get_meta("lit"))
	# By id: a layer change frees the key before the timer ends.
	get_tree().create_timer(LIT_S).timeout.connect(_unlight.bind(b.get_instance_id()))
	if ThemeManager.reduced_motion or quiet:
		return
	b.scale = Vector2.ONE
	var t := b.create_tween().set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	t.tween_property(b, "scale", Vector2.ONE * 1.06, POP_S * 0.4)
	t.tween_property(b, "scale", Vector2.ONE, POP_S * 0.6)
