class_name AppKeyboard
extends Control
## The on-screen keyboard for a hosted app's field, on the driver's side of the app page. What is
## typed goes to the app's window: through its text input (zwp_text_input_v3) when it has one
## enabled, else as key presses; backspace and Done are keys, as every client takes them. The
## shell gives the app the rest of the width meanwhile, so the field and what it finds show beside.

## Done or cancel: the keyboard is going. `submitted`: Done, which sent Enter.
signal closed(submitted: bool)

const SLIDE_S := 0.22
## zwp_text_input_v3's content purposes and hints the keyboard acts on.
const PURPOSE_DIGITS := 2
const PURPOSE_NUMBER := 3
const PURPOSE_PHONE := 4
const PURPOSE_URL := 5
const PURPOSE_EMAIL := 6
const PURPOSE_PASSWORD := 8
const PURPOSE_PIN := 9
const HINT_AUTO_CAPITALIZATION := 0x4
const HINT_HIDDEN_TEXT := 0x40
const HINT_SENSITIVE_DATA := 0x80

## The compositor's window the keys go to.
var window_id := -1
## A password or PIN: no preview of the text, no key pop.
var secret := false
var keyboard: Keyboard
## The field's text as the app reports it (GTK does, Godot does not), shown over the keys.
var _preview: Label
var _closing := false
var _tween: Tween
var _driver_left := true


func _init() -> void:
	name = "AppKeyboard"
	mouse_filter = Control.MOUSE_FILTER_STOP
	_preview = UI.label("", "body", "title", "dim")
	_preview.name = "Preview"
	_preview.clip_text = true
	_preview.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_preview.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	add_child(_preview)
	keyboard = Keyboard.new()
	add_child(keyboard)
	keyboard.typed.connect(_type)
	keyboard.erased.connect(_key.bind(KEY_BACKSPACE))
	keyboard.submitted.connect(func(): _key(KEY_ENTER); close(true))
	keyboard.cancelled.connect(close.bind(false))
	resized.connect(_place)


func _ready() -> void:
	ThemeManager.changed.connect(_style)
	_style()


## For `field`, as `Wayland.text_field` gives it (empty: a client without text input, typed to
## as keys): the keypad for numbers, a web address's or email's keys, nothing shown of a password.
func configure(id: int, field: Dictionary) -> void:
	window_id = id
	var purpose := int(field.get("purpose", 0))
	var hint := int(field.get("hint", 0))
	secret = purpose in [PURPOSE_PASSWORD, PURPOSE_PIN] or hint & (HINT_HIDDEN_TEXT | HINT_SENSITIVE_DATA) != 0
	keyboard.quiet = secret
	keyboard.extras = ["/", ":", "-"] if purpose == PURPOSE_URL else ["_", "-", "@"] if purpose == PURPOSE_EMAIL else []
	keyboard.decimals = purpose == PURPOSE_NUMBER
	keyboard.negative = purpose == PURPOSE_NUMBER
	keyboard.mode = "number" if purpose in [PURPOSE_DIGITS, PURPOSE_NUMBER, PURPOSE_PHONE, PURPOSE_PIN] else "text"
	if hint & HINT_AUTO_CAPITALIZATION and str(field.get("text", "x")).strip_edges() == "":
		keyboard.shift = 1
		keyboard._style_keys()
	_refresh()


func _process(_delta: float) -> void:
	_refresh()


func _refresh() -> void:
	var f: Dictionary = Wayland.text_field(window_id) if window_id >= 0 else {}
	var show := not secret and f.has("text")
	var t := str(f.get("text", ""))
	if show != _preview.visible:
		_preview.visible = show
		_place()
	if show and _preview.text != t:
		_preview.text = t


func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), ThemeManager.c.surface)


func _style() -> void:
	theme = ThemeManager.godot_theme
	UI.style_labels(self)
	_place()
	queue_redraw()


func _place() -> void:
	var g: float = ThemeManager.px.gap
	var top := 0.0
	if _preview.visible:
		var h: float = ThemeManager.px.touch
		_preview.position = Vector2(g * 2.0, g)
		_preview.size = Vector2(size.x - g * 4.0, h)
		top = h + g
	keyboard.position = Vector2(0, top)
	keyboard.size = Vector2(size.x, size.y - top)


func _type(s: String) -> void:
	if not _closing and not Wayland.type_text(s):
		push_warning("keyboard: %s cannot be typed into window %d" % [s, window_id])


func _key(k: Key) -> void:
	if _closing:
		return
	Wayland.key(k, true)
	Wayland.key(k, false)


## In from the driver's edge at `x`, out the same way; at once under reduced motion.
func slide_in(x: float, driver_left: bool) -> void:
	_driver_left = driver_left
	_slide(x, _away(x), true)


func _away(x: float) -> float:
	return -size.x if _driver_left else x + size.x


func close(submitted := false) -> void:
	if _closing:
		return
	_closing = true
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	for k in find_children("*", "Button", true, false):
		k.mouse_filter = Control.MOUSE_FILTER_IGNORE
	closed.emit(submitted)
	_slide(position.x, _away(position.x), false)


func closing() -> bool:
	return _closing


func _slide(home: float, away: float, opening: bool) -> void:
	if _tween:
		_tween.kill()
	if ThemeManager.reduced_motion:
		position.x = home
		if not opening:
			queue_free()
		return
	_tween = create_tween().set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT if opening else Tween.EASE_IN)
	if opening:
		position.x = away
		_tween.tween_property(self, "position:x", home, SLIDE_S)
	else:
		_tween.tween_property(self, "position:x", away, SLIDE_S)
		_tween.tween_callback(queue_free)


## True while sliding in or out.
func moving() -> bool:
	return _tween != null and _tween.is_running()
