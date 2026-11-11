class_name AppKeyboard
extends Control
## The on-screen keyboard for a hosted app's field, on the driver's side of the app page. What is
## typed goes to the app's window: through its text input (zwp_text_input_v3) when it has one
## enabled, else as key presses; backspace and Done are keys, as every client takes them. The
## shell gives the app the rest of the width meanwhile, so the field and what it finds show beside.
## A terminal gets a row of Esc, Tab, Ctrl, Alt, Super, arrows and F-keys (any app, by the bar's
## toggle); Ctrl, Alt and Super are sticky, and while one is down letters go as keys under it:
## VTE ignores a commit of a control character.

## Done or cancel: the keyboard is going. `submitted`: Done, which sent Enter.
signal closed(submitted: bool)

const SLIDE_S := 0.12
## A second tap on a modifier within this locks it.
const MOD_TAP_S := 0.4
## zwp_text_input_v3's content purposes and hints the keyboard acts on.
const PURPOSE_DIGITS := 2
const PURPOSE_NUMBER := 3
const PURPOSE_PHONE := 4
const PURPOSE_URL := 5
const PURPOSE_EMAIL := 6
const PURPOSE_PASSWORD := 8
const PURPOSE_PIN := 9
const PURPOSE_TERMINAL := 13
const HINT_AUTO_CAPITALIZATION := 0x4
const HINT_HIDDEN_TEXT := 0x40
const HINT_SENSITIVE_DATA := 0x80
const HINT_MULTILINE := 0x200
## Terminals by app_id, for those launched without a desktop entry saying TerminalEmulator.
const TERMINALS := ["org.gnome.Console", "kgx", "org.gnome.Terminal", "org.gnome.Ptyxis", "foot", "footclient",
	"Alacritty", "kitty", "org.wezfurlong.wezterm", "xterm", "XTerm", "org.kde.konsole", "konsole",
	"org.freedesktop.weston.wayland-terminal", "com.raggesilver.BlackBox", "io.elementary.terminal"]
const MODS := {"ctrl": KEY_CTRL, "alt": KEY_ALT, "super": KEY_META}
const ROW := ["esc", "tab", "ctrl", "alt", "super", "left", "down", "up", "right", "fn"]
const KEYS := {esc = KEY_ESCAPE, tab = KEY_TAB, left = KEY_LEFT, down = KEY_DOWN, up = KEY_UP, right = KEY_RIGHT}
const ICONS := {left = "back", right = "chevron", up = "chevron_up", down = "chevron_down"}
## In key widths; the rest are one.
const WIDTHS := {"super": 1.5, "left": 0.85, "down": 0.85, "up": 0.85, "right": 0.85}

## The compositor's window the keys go to.
var window_id := -1
## A password or PIN: no preview of the text, no key pop.
var secret := false
## The app is a terminal (set before `configure`): the extra row shows from the start.
var terminal := false
## Done is Enter, which sends Return and keeps the keyboard; the bar's hide key puts it away.
var enter_key := false
var keyboard: Keyboard
## Off 0, for the next key 1, locked 2.
var mods := {"ctrl": 0, "alt": 0, "super": 0}
var extras_on := false
## The extra row is F1 to F12.
var fn_on := false
## The field's text as the app reports it (GTK does, Godot does not), shown over the keys.
var _preview: Label
var _toggle: Button
var _hide: Button
var _extras: Control
var _mod_at := {}
var _now := 0.0
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
	_toggle = Button.new()
	_toggle.name = "ExtrasToggle"
	_toggle.text = "Esc Ctrl"
	_toggle.toggle_mode = true
	_toggle.focus_mode = Control.FOCUS_NONE
	_toggle.toggled.connect(func(on): set_extras(on))
	Keyboard.touch_only(_toggle)
	add_child(_toggle)
	_hide = Button.new()
	_hide.name = "Hide"
	_hide.tooltip_text = "Hide the keyboard"
	_hide.focus_mode = Control.FOCUS_NONE
	_hide.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_hide.visible = false
	_hide.pressed.connect(close.bind(false))
	Keyboard.touch_only(_hide)
	add_child(_hide)
	_extras = Control.new()
	_extras.name = "Extras"
	_extras.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_extras.visible = false
	add_child(_extras)
	keyboard = Keyboard.new()
	add_child(keyboard)
	keyboard.typed.connect(_type)
	keyboard.erased.connect(_key.bind(KEY_BACKSPACE))
	keyboard.submitted.connect(_submit)
	keyboard.cancelled.connect(close.bind(false))
	resized.connect(_place)


func _ready() -> void:
	ThemeManager.changed.connect(_style)
	_style()


func _submit() -> void:
	_key(KEY_ENTER)
	if not enter_key:
		close(true)


static func terminal_app(app_id: String) -> bool:
	return app_id in TERMINALS


## For `field`, as `Wayland.text_field` gives it (empty: a client without text input, typed to
## as keys): the keypad for numbers, a web address's or email's keys, nothing shown of a password,
## the extra row for a terminal (VTE says so by its purpose).
func configure(id: int, field: Dictionary) -> void:
	window_id = id
	var purpose := int(field.get("purpose", 0))
	var hint := int(field.get("hint", 0))
	terminal = terminal or purpose == PURPOSE_TERMINAL
	# Return is a key of the text there, not the end of it: Enter, and the keyboard stays.
	enter_key = terminal or hint & HINT_MULTILINE != 0
	_hide.visible = enter_key
	# text-input-v3 has no search purpose; a web address is the one field whose action is known.
	keyboard.done_label = "Enter" if enter_key else "Go" if purpose == PURPOSE_URL else "Done"
	secret = purpose in [PURPOSE_PASSWORD, PURPOSE_PIN] or hint & (HINT_HIDDEN_TEXT | HINT_SENSITIVE_DATA) != 0
	keyboard.quiet = secret
	keyboard.extras = ["/", ":", "-"] if purpose == PURPOSE_URL else ["_", "-", "@"] if purpose == PURPOSE_EMAIL else []
	keyboard.decimals = purpose == PURPOSE_NUMBER
	keyboard.negative = purpose == PURPOSE_NUMBER
	keyboard.mode = "number" if purpose in [PURPOSE_DIGITS, PURPOSE_NUMBER, PURPOSE_PHONE, PURPOSE_PIN] else "text"
	if hint & HINT_AUTO_CAPITALIZATION and str(field.get("text", "x")).strip_edges() == "":
		keyboard.shift = 1
		keyboard._style_shift()
	set_extras(terminal)
	_style_toggle()
	_place()
	_refresh()


## Named for a terminal; elsewhere, where it is rarely wanted, a small icon at the bar's end.
func _style_toggle() -> void:
	_toggle.text = "Esc Ctrl" if terminal else ""
	_toggle.tooltip_text = "" if terminal else "Esc, Ctrl and arrows"
	_toggle.icon = null if terminal else Icons.texture("tune", ThemeManager.px.icon * 0.8)
	_toggle.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER


## Shows or hides the extra row.
func set_extras(on: bool) -> void:
	_toggle.set_pressed_no_signal(on)
	if on == extras_on and _extras.get_child_count() > 0:
		return
	extras_on = on
	_extras.visible = on
	if not on:
		for m in mods:
			mods[m] = 0
	_build_extras()
	_place()


func _process(delta: float) -> void:
	_now += delta
	_refresh()


func _refresh() -> void:
	var f: Dictionary = Wayland.text_field(window_id) if window_id >= 0 else {}
	var show := not secret and f.has("text")
	var t := str(f.get("text", ""))
	if show != _preview.visible:
		_preview.visible = show
	if show and _preview.text != t:
		_preview.text = t


func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), ThemeManager.c.surface)


func _style() -> void:
	theme = ThemeManager.godot_theme
	UI.style_labels(self)
	_toggle.add_theme_font_size_override("font_size", ThemeManager.font_size("caption"))
	_hide.icon = Icons.texture("chevron_down", ThemeManager.px.icon)
	_style_toggle()
	_style_extras()
	_place()
	queue_redraw()


## A bar (the field's text; on the app's side the extra row's toggle, and the hide key outermost
## while Enter replaces Done), the extra row, the keys.
func _place() -> void:
	var g: float = ThemeManager.px.gap
	var h: float = ThemeManager.px.touch
	var pad := g * 1.5
	var hw := h * 1.5 + g if _hide.visible else 0.0
	_hide.size = Vector2(h * 1.5, h - g)
	_hide.position = Vector2(size.x - h * 1.5 - pad if _driver_left else pad, g * 0.5)
	var tw := maxf(_toggle.get_combined_minimum_size().x, h * 2.0) if terminal else h
	_toggle.size = Vector2(tw, h - g)
	_toggle.position = Vector2(size.x - tw - pad - hw if _driver_left else pad + hw, g * 0.5)
	_preview.size = Vector2(size.x - tw - hw - pad * 3.0, h)
	_preview.position = Vector2(pad if _driver_left else tw + hw + pad * 2.0, 0)
	var top := h
	if extras_on:
		_extras.position = Vector2(0, top)
		_extras.size = Vector2(size.x, h * 1.1)
		_place_extras()
		top += _extras.size.y
	keyboard.position = Vector2(0, top)
	keyboard.size = Vector2(size.x, size.y - top)


func _ids() -> Array:
	if not fn_on:
		return ROW
	var out := ["fn"]
	for i in range(1, 13):
		out.append("f%d" % i)
	return out


func _build_extras() -> void:
	for b in _extras.get_children():
		_extras.remove_child(b)
		b.queue_free()
	if not extras_on:
		return
	for id in _ids():
		var b := Button.new()
		b.name = _label(id)
		b.set_meta("id", id)
		b.focus_mode = Control.FOCUS_NONE
		b.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
		b.clip_text = true
		b.expand_icon = true
		b.add_theme_constant_override("icon_max_width", roundi(ThemeManager.px.icon))
		Keyboard.touch_only(b)
		b.button_down.connect(_extra.bind(id))
		_extras.add_child(b)
	_style_extras()
	_place_extras()


func _place_extras() -> void:
	var n := _extras.get_child_count()
	if n == 0:
		return
	var g: float = ThemeManager.px.gap
	var pad := g * 1.5
	var units := 0.0
	for b in _extras.get_children():
		units += WIDTHS.get(b.get_meta("id"), 1.0)
	var u := (_extras.size.x - pad * 2.0) / units
	var x := pad
	for b in _extras.get_children():
		var w: float = WIDTHS.get(b.get_meta("id"), 1.0) * u
		b.position = Vector2(x + g * 0.4, g * 0.4)
		b.size = Vector2(w - g * 0.8, _extras.size.y - g * 0.8)
		x += w


## A modifier for the next key is tinted, a locked one the accent, as shift and caps lock are.
func _style_extras() -> void:
	for b in _extras.get_children():
		var id: String = b.get_meta("id")
		var state: int = mods.get(id, 0)
		if id == "fn" and fn_on:
			state = 2
		var fill: Color = ThemeManager.c.bg
		var ink: Color = ThemeManager.c.text
		if state == 1:
			fill = ThemeManager.c.surface2.lerp(ThemeManager.c.accent, 0.35)
		elif state == 2:
			fill = ThemeManager.c.accent
			ink = ThemeManager.c.on_accent
		b.text = "" if ICONS.has(id) else _label(id)
		b.icon = Icons.texture(ICONS[id], ThemeManager.px.icon) if ICONS.has(id) else null
		b.add_theme_font_size_override("font_size", ThemeManager.font_size("caption"))
		var normal := keyboard._box(fill)
		# A tenth of the keyboard each: "Super" needs all of it.
		normal.content_margin_left = 0
		normal.content_margin_right = 0
		for s in ["normal", "hover", "focus", "disabled"]:
			b.add_theme_stylebox_override(s, normal)
		for s in ["pressed", "hover_pressed"]:
			b.add_theme_stylebox_override(s, keyboard._box(ThemeManager.c.accent))
		for k in ["font_color", "font_hover_color", "font_focus_color", "icon_normal_color", "icon_hover_color", "icon_focus_color"]:
			b.add_theme_color_override(k, ink)
		for k in ["font_pressed_color", "font_hover_pressed_color", "icon_pressed_color", "icon_hover_pressed_color"]:
			b.add_theme_color_override(k, ThemeManager.c.on_accent)


## Esc, Ctrl, F12: also the key's node name.
static func _label(id: String) -> String:
	return id.to_upper() if id.begins_with("f") and id != "fn" else id.capitalize()


func _extra(id: String) -> void:
	if _closing:
		return
	if MODS.has(id):
		var m: int = mods[id]
		if m == 1 and _now - float(_mod_at.get(id, -1.0)) < MOD_TAP_S:
			mods[id] = 2
		else:
			mods[id] = 1 if m == 0 else 0
		_mod_at[id] = _now
		_style_extras()
	elif id == "fn":
		fn_on = not fn_on
		_build_extras()
	elif id.begins_with("f"):
		# KEY_F1 to KEY_F12 are consecutive.
		_key(KEY_F1 + int(id.substr(1)) - 1)
	else:
		_key(KEYS[id])


func _held() -> Array:
	return mods.keys().filter(func(m): return mods[m] > 0)


## `send` with the modifiers down; one tapped for the next key is spent.
func _with_mods(send: Callable) -> bool:
	var held := _held()
	for m in held:
		Wayland.key(MODS[m], true)
	var ok: bool = send.call()
	held.reverse()
	for m in held:
		Wayland.key(MODS[m], false)
		if mods[m] == 1:
			mods[m] = 0
	if not held.is_empty():
		_style_extras()
	return ok


func _type(s: String) -> void:
	if _closing:
		return
	var ok: bool = Wayland.type_text(s) if _held().is_empty() else _with_mods(func() -> bool: return Wayland.type_keys(s))
	if not ok:
		push_warning("keyboard: %s cannot be typed into window %d" % [s, window_id])


func _key(k: int) -> void:
	if _closing:
		return
	_with_mods(func() -> bool:
		Wayland.key(k, true)
		Wayland.key(k, false)
		return true)


## In from the driver's edge at `x`, out the same way; at once under reduced motion.
func slide_in(x: float, driver_left: bool) -> void:
	_driver_left = driver_left
	_place()
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
