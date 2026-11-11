class_name TextEntry
extends CanvasLayer
## Typing a value over the whole panel: the keyboard on the driver's side, and on the other only
## the field's name and what is typed so far, large. A layer of its own, over the page and the
## nav rail, so nothing else takes a touch; the page it opens from is hidden until it closes.
## Takes a hardware keyboard's keys too.

## Done, and `on_commit` took the text; or cancelled.
signal closed(taken: bool)

## Of the panel's width.
const KEYBOARD_SHARE := 0.7
const SLIDE_S := 0.24
const BLINK_S := 1.0
const LAYER := 50

## `(text) -> bool`: true when the value was taken. Done then closes; false keeps typing.
var on_commit: Callable

var label := ""
var text := ""
## text | number
var kind := "text"
## Shown as dots until the eye is tapped.
var secret := false
var min_len := 0
var max_len := 0
var decimals := true
var negative := false

var keyboard: Keyboard
var _root: Control
var _side: Control
var _title: Label
var _value: ValueView
var _hint: Label
var _eye: Button
var _shown := false
var _closing := false
var _bad := false
var _host: CanvasItem
var _tween: Tween


## Opens over `host` (hidden meanwhile). `field`: label, value, kind (text, number), secret,
## min_len, max_len; for numbers decimals and negative.
static func edit(host: Node, field: Dictionary) -> TextEntry:
	var e := TextEntry.new()
	e.label = str(field.get("label", ""))
	e.text = str(field.get("value", ""))
	e.kind = str(field.get("kind", "text"))
	e.secret = bool(field.get("secret", false))
	e.min_len = int(field.get("min_len", 0))
	e.max_len = int(field.get("max_len", 0))
	e.decimals = bool(field.get("decimals", true))
	e.negative = bool(field.get("negative", false))
	host.add_child(e)
	return e


func _init() -> void:
	name = "Entry"
	layer = LAYER
	_root = Control.new()
	_root.name = "Root"
	_root.mouse_filter = Control.MOUSE_FILTER_STOP
	_root.draw.connect(func(): _root.draw_rect(Rect2(Vector2.ZERO, _root.size), ThemeManager.c.bg))
	add_child(_root)
	_side = Control.new()
	_side.name = "Field"
	_side.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(_side)
	_title = UI.label("", "strong", "title", "dim")
	_title.name = "Label"
	_title.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_side.add_child(_title)
	_value = ValueView.new()
	_value.name = "Value"
	_side.add_child(_value)
	_hint = UI.label("", "body", "body", "dim")
	_hint.name = "Hint"
	_side.add_child(_hint)
	_eye = Button.new()
	_eye.name = "Show"
	_eye.focus_mode = Control.FOCUS_NONE
	_eye.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_eye.pressed.connect(func(): _shown = not _shown; _update())
	_side.add_child(_eye)
	keyboard = Keyboard.new()
	_root.add_child(keyboard)
	keyboard.typed.connect(_type)
	keyboard.erased.connect(_erase)
	keyboard.submitted.connect(_done)
	keyboard.cancelled.connect(close.bind(false))
	# No typing while the car is driven.
	var lock := DriveCover.new()
	lock.typing = true
	lock.dismissed.connect(close.bind(false))
	keyboard.add_child(lock)


func _ready() -> void:
	_host = get_parent() as CanvasItem
	if _host:
		_host.visible = false
	_root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	keyboard.decimals = decimals
	keyboard.negative = negative
	keyboard.mode = kind
	_title.text = label
	_eye.visible = secret
	ThemeManager.changed.connect(_style)
	_root.resized.connect(_place)
	_style()
	_slide(true)


func _process(delta: float) -> void:
	_value.blink += delta


func _style() -> void:
	_root.theme = ThemeManager.godot_theme
	UI.restyle(_root)
	_eye.custom_minimum_size = Vector2.ONE * ThemeManager.px.touch
	for s in ["normal", "hover", "focus", "pressed", "hover_pressed"]:
		var f := StyleBoxFlat.new()
		f.bg_color = ThemeManager.c.surface2 if s.contains("pressed") else Color(0, 0, 0, 0)
		f.set_corner_radius_all(roundi(ThemeManager.px.radius))
		_eye.add_theme_stylebox_override(s, f)
	for k in ["icon_normal_color", "icon_hover_color", "icon_pressed_color", "icon_hover_pressed_color", "icon_focus_color"]:
		_eye.add_theme_color_override(k, ThemeManager.c.text)
	_update()
	_place()
	_root.queue_redraw()


## The driver's side: left for a left-hand drive car.
func driver_left() -> bool:
	return ThemeManager.hand != "rhd"


func _place() -> void:
	var w := _root.size.x
	var h := _root.size.y
	var kw := roundf(w * KEYBOARD_SHARE)
	keyboard.size = Vector2(kw, h)
	keyboard.position = Vector2(_keyboard_x(), 0)
	var g: float = ThemeManager.px.gap
	var pad := g * 3.0
	var sx := kw + pad if driver_left() else pad
	var sw := w - kw - pad * 2.0
	_side.position = Vector2(sx, 0)
	_side.size = Vector2(sw, h)
	var t: float = ThemeManager.px.touch
	var th := _title.get_combined_minimum_size().y
	_title.position = Vector2(0, pad)
	_title.size = Vector2(sw - (t + g if secret else 0.0), maxf(th, t))
	_eye.size = Vector2(t, t)
	_eye.position = Vector2(sw - t, pad + (maxf(th, t) - t) / 2.0)
	var top := pad + maxf(th, t) + g
	var hh := _hint.get_combined_minimum_size().y
	_value.position = Vector2(0, top)
	_value.size = Vector2(sw, h - top - hh - pad - g)
	_hint.position = Vector2(0, h - pad - hh)
	_hint.size = Vector2(sw, hh)


func _keyboard_x() -> float:
	return 0.0 if driver_left() else _root.size.x - keyboard.size.x


## In from the driver's edge, the field fading up; out the same way. At once under reduced motion.
func _slide(opening: bool) -> void:
	if _tween:
		_tween.kill()
	var home := _keyboard_x()
	var away := -keyboard.size.x if driver_left() else _root.size.x
	if _root.size.x <= 0.0:
		away = -1e4 if driver_left() else 1e4
	if ThemeManager.reduced_motion:
		if not opening:
			queue_free()
		return
	_tween = create_tween().set_parallel().set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT if opening else Tween.EASE_IN)
	if opening:
		# The page is hidden already: the ground is there at once, the field fades up over it.
		keyboard.position.x = away
		_side.modulate.a = 0.0
		_tween.tween_property(keyboard, "position:x", home, SLIDE_S)
		_tween.tween_property(_side, "modulate:a", 1.0, SLIDE_S * 0.6)
	else:
		# The page is back underneath: all of it fades.
		_tween.tween_property(keyboard, "position:x", away, SLIDE_S)
		_tween.tween_property(_root, "modulate:a", 0.0, SLIDE_S)
		_tween.chain().tween_callback(queue_free)


## True while sliding in or out.
func moving() -> bool:
	return _tween != null and _tween.is_running()


func close(taken: bool) -> void:
	if _closing:
		return
	_closing = true
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	keyboard.mouse_filter = Control.MOUSE_FILTER_IGNORE
	for k in keyboard.find_children("*", "Button", true, false):
		k.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if is_instance_valid(_host):
		_host.visible = true
	closed.emit(taken)
	_slide(false)


func _type(s: String) -> void:
	if _closing:
		return
	if kind == "number":
		if s == "-":
			text = text.substr(1) if text.begins_with("-") else ("-" + text if negative else text)
		elif s == "." or s == ",":
			if decimals and not text.contains("."):
				text += "."
		elif s.is_valid_int():
			text += s
		_changed()
		return
	if max_len > 0 and text.length() + s.length() > max_len:
		_bad = true
		_update()
		return
	text += s
	_changed()


func _erase() -> void:
	if _closing or text.is_empty():
		return
	text = text.left(-1)
	_changed()


func _changed() -> void:
	_bad = false
	_value.blink = 0.0
	_update()


func _done() -> void:
	if _closing:
		return
	if not valid() or (on_commit.is_valid() and not on_commit.call(text)):
		_bad = true
		_update()
		return
	close(true)


## What the field's own rules allow; the host's `on_commit` has the last word.
func valid() -> bool:
	if kind == "number":
		return text.replace(",", ".").is_valid_float()
	var n := text.length()
	return n >= min_len and (max_len <= 0 or n <= max_len)


func _update() -> void:
	if _value == null:
		return
	var masked := secret and not _shown
	_value.masked = masked
	_value.text = text
	_eye.icon = Icons.texture("eye" if masked else "eye_off", ThemeManager.px.icon * 1.2)
	var hint := ""
	if kind == "text":
		if min_len > 0 and max_len > 0:
			hint = "%d to %d characters" % [min_len, max_len]
		elif max_len > 0:
			hint = "Up to %d characters" % max_len
		elif min_len > 0:
			hint = "At least %d characters" % min_len
		if max_len > 0 or min_len > 0:
			hint += "  ·  %d" % text.length()
	elif _bad:
		hint = "Not a number"
	_hint.text = hint
	_hint.add_theme_color_override("font_color", ThemeManager.c.crit if _bad else ThemeManager.c.dim)
	keyboard.done_ready = valid()


func _input(event: InputEvent) -> void:
	if _closing or not event is InputEventKey or not event.pressed:
		return
	var k: InputEventKey = event
	if k.ctrl_pressed or k.alt_pressed or k.meta_pressed:
		return
	match k.keycode:
		KEY_ESCAPE:
			if not k.echo:
				close(false)
		KEY_ENTER, KEY_KP_ENTER:
			if not k.echo:
				_done()
		KEY_BACKSPACE:
			_erase()
		_:
			var s := _char(k)
			if s == "":
				return
			_type(s)
	get_viewport().set_input_as_handled()


## The character a key types: its unicode, or for a bare keycode (no layout behind it) the
## letter, digit or space it names.
static func _char(k: InputEventKey) -> String:
	if k.unicode >= 32:
		return String.chr(k.unicode)
	var c := k.keycode
	if c >= KEY_A and c <= KEY_Z:
		var l := String.chr(c)
		return l if k.shift_pressed else l.to_lower()
	if (c >= KEY_0 and c <= KEY_9) or c == KEY_SPACE:
		return String.chr(c)
	return ""


## The value, large, wrapped to the width, a caret after it; the font steps down to fit.
class ValueView:
	extends Control
	var text := "":
		set(v):
			text = v
			queue_redraw()
	## Dots for the characters: drawn, as not every theme's face has a bullet.
	var masked := false:
		set(v):
			masked = v
			queue_redraw()
	## Seconds since the last edit: the caret blinks from it, unless motion is reduced.
	var blink := 0.0:
		set(v):
			var was := _caret_on()
			blink = v
			if _caret_on() != was:
				queue_redraw()

	func _init() -> void:
		mouse_filter = Control.MOUSE_FILTER_IGNORE
		resized.connect(queue_redraw)

	func _caret_on() -> bool:
		return ThemeManager.reduced_motion or fmod(blink, TextEntry.BLINK_S) < TextEntry.BLINK_S * 0.5

	func _draw() -> void:
		var font: Font = ThemeManager.fonts.display
		var fs := ThemeManager.font_size("display")
		var floor_fs := ThemeManager.font_size("title")
		var lines := _wrap(font, fs)
		while fs > floor_fs and lines.size() * font.get_height(fs) > size.y:
			fs -= 2
			lines = _wrap(font, fs)
		var lh := font.get_height(fs)
		var y := 0.0
		var x := 0.0
		for line in lines:
			if masked:
				for i in line.length():
					draw_circle(Vector2(_pitch(fs) * (i + 0.5), y + lh * 0.55), fs * 0.16, ThemeManager.c.text, true, -1.0, true)
				x = _pitch(fs) * line.length()
			else:
				draw_string(font, Vector2(0, y + font.get_ascent(fs)), line, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, ThemeManager.c.text)
				x = font.get_string_size(line, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
			y += lh
		if _caret_on():
			x += 2.0
			var cy := maxf(0.0, y - lh)
			draw_rect(Rect2(x, cy + lh * 0.12, maxf(3.0, fs * 0.06), lh * 0.76), ThemeManager.c.accent)

	func _pitch(fs: int) -> float:
		return fs * 0.5

	## Breaks at spaces where it can, else anywhere: a password has no spaces.
	func _wrap(font: Font, fs: int) -> PackedStringArray:
		var out := PackedStringArray()
		var w := size.x - fs * 0.2
		if masked:
			var per := maxi(1, floori(w / _pitch(fs)))
			for i in range(0, maxi(1, text.length()), per):
				out.append(text.substr(i, per))
			return out
		var line := ""
		for ch in text:
			if line != "" and font.get_string_size(line + ch, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x > w:
				var cut := line.rfind(" ")
				if cut > 0 and ch != " ":
					out.append(line.left(cut + 1))
					line = line.substr(cut + 1)
				else:
					out.append(line)
					line = ""
			line += ch
		out.append(line)
		return out
