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
		_build()
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
		_style_keys()
## Done dimmed while what is typed would not be taken.
var done_ready := true:
	set(v):
		done_ready = v
		_style_keys()

var _keys: Control
var _held: Button
var _repeat := 0.0
var _shift_at := -1.0
var _now := 0.0


func _init() -> void:
	name = "Keyboard"
	mouse_filter = Control.MOUSE_FILTER_STOP
	_keys = Control.new()
	_keys.name = "Keys"
	_keys.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_keys)
	resized.connect(_place)


func _ready() -> void:
	ThemeManager.changed.connect(_build)
	_build()


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
	return _keys.get_node_or_null(NodePath(_node_name(id))) as Button


func _build() -> void:
	for k in _keys.get_children():
		_keys.remove_child(k)
		k.queue_free()
	_held = null
	for row in _rows():
		for k in row:
			var id: String = k[0] if k is Array else k
			if _keys.has_node(NodePath(_node_name(id))):
				# A second shift: same key, its own node.
				var twin := _key_button(id)
				twin.name = _node_name(id) + "2"
				_keys.add_child(twin)
			else:
				_keys.add_child(_key_button(id))
	_style_keys()
	_place()


func _key_button(id: String) -> Button:
	var b := Button.new()
	b.name = _node_name(id)
	b.focus_mode = Control.FOCUS_NONE
	b.set_meta("id", id)
	b.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
	b.vertical_icon_alignment = VERTICAL_ALIGNMENT_CENTER
	b.expand_icon = false
	b.button_down.connect(_down.bind(b))
	if id in ["symbols", "letters", "more"]:
		# On release: a finger's press comes as a touch and as Godot's mouse from it, and on the
		# second the new layer's key in the same place would switch straight back.
		b.pressed.connect(func(): layer = id; _build())
	return b


static func _node_name(id: String) -> String:
	if NAMES.has(id):
		return NAMES[id]
	if id.validate_node_name() == id and id != "":
		return id
	return "U%04X" % id.unicode_at(0)


## The layer's rows, with `extras` in the letters' last row.
func _rows() -> Array:
	var rows: Array = LAYERS[layer]
	if layer != "letters" or extras.size() != 3:
		return rows
	rows = rows.duplicate(true)
	var last: Array = rows[-1]
	rows[-1] = last.slice(0, last.size() - 3) + extras
	return rows


func _place() -> void:
	var rows: Array = _rows()
	var g: float = ThemeManager.px.gap
	var pad := g * 1.5
	var units := 0.0
	for row in rows:
		units = maxf(units, _row_units(row))
	var u := (size.x - pad * 2.0) / units
	var kh := minf((size.y - pad * 2.0) / rows.size(), ThemeManager.px.touch * 2.2)
	if layer == "number":
		# A keypad's keys need not be as wide as the whole side.
		u = minf(u, kh * 1.6)
	var top := (size.y - kh * rows.size()) / 2.0
	var i := 0
	var keys := _keys.get_children()
	for r in rows.size():
		var row: Array = rows[r]
		var x := (size.x - _row_units(row) * u) / 2.0
		for k in row:
			var w: float = (k[1] if k is Array else 1.0) * u
			var b: Button = keys[i]
			b.position = Vector2(x + g * 0.4, top + r * kh + g * 0.4)
			b.size = Vector2(w - g * 0.8, kh - g * 0.8)
			b.pivot_offset = b.size / 2.0
			x += w
			i += 1


func _row_units(row: Array) -> float:
	var n := 0.0
	for k in row:
		n += k[1] if k is Array else 1.0
	return n


func _style_keys() -> void:
	if _keys == null:
		return
	var fs := roundi(ThemeManager.px.title * 1.3)
	for b in _keys.get_children():
		var id: String = b.get_meta("id")
		var special := id.length() > 1
		b.text = _label(id)
		b.icon = null
		var icon := _icon(id)
		if icon != "":
			b.icon = Icons.texture(icon, ThemeManager.px.icon * 1.3)
		b.add_theme_font_override("font", ThemeManager.fonts.strong)
		b.add_theme_font_size_override("font_size", fs if not special or id == "sign" else ThemeManager.font_size("body"))
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
		b.disabled = (id == "sign" and not negative) or (id == "." and layer == "number" and not decimals)
		b.modulate.a = 0.45 if b.disabled or (id == "done" and not done_ready) else 1.0
	queue_redraw()


func _label(id: String) -> String:
	if id == "done":
		return done_label
	if LABELS.has(id):
		return LABELS[id]
	if _icon(id) != "":
		return ""
	return id.to_upper() if shift > 0 and layer == "letters" else id


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
			_style_keys()
		"symbols", "letters", "more":
			pass
		"sign":
			typed.emit("-")
		_:
			typed.emit(id.to_upper() if shift > 0 and layer == "letters" else id)
			if shift == 1:
				shift = 0
				_style_keys()


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
