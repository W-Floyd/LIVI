class_name HardKeys
extends CanvasLayer
## The head unit's hard keys (micomd's virtual keyboard, through cage) and the volume overlay.
## Under the stock UI GNOME took the volume keys and LIVI followed the sink; here the shell
## steps the core's `huVolume`, which the core writes to the sink (`huVolumeLinkSystem`). The
## other keys go to the core as LIVI's bindings name them, as the stock UI sent them.

## Godot key to the key code LIVI's bindings use (winit's names). Only keys no typing needs, so
## a hosted window keeps its keyboard.
const CODES := {
	KEY_VOLUMEUP: "AudioVolumeUp",
	KEY_VOLUMEDOWN: "AudioVolumeDown",
	KEY_VOLUMEMUTE: "AudioVolumeMute",
	KEY_MEDIAPLAY: "MediaPlayPause",
	KEY_MEDIASTOP: "MediaStop",
	KEY_MEDIANEXT: "MediaTrackNext",
	KEY_MEDIAPREVIOUS: "MediaTrackPrevious",
	KEY_HOME: "Home",
	KEY_F13: "F13", KEY_F14: "F14", KEY_F15: "F15", KEY_F16: "F16",
	KEY_F17: "F17", KEY_F18: "F18", KEY_F19: "F19", KEY_F20: "F20",
	KEY_F21: "F21", KEY_F22: "F22", KEY_F23: "F23", KEY_F24: "F24",
}
## GNOME's default volume step, what the keys did under the stock UI.
const STEP := 0.06
## Presses faster than the core's echo build on the level last sent, not the stale mirror.
const PENDING_MS := 500
const SHOWN_S := 1.5

var _sent := -1.0
var _sent_at := -PENDING_MS
var _unmuted := 0.0
var _seen = null

var _card: PanelContainer
var _icon: TextureRect
var _bar: Control
var _percent: Label
var _hide: Timer
## The other overlay: a glowing line along the bottom edge, lit to the level, no text.
var _glow: Control
var _glow_tween: Tween
## Smooth falloffs, white, tinted when drawn: stacked strokes band visibly.
var _bloom := _falloff(false)
var _flare := _falloff(true)
## The level as drawn, eased toward the core's so a step slides instead of jumping.
var _drawn := 0.0
var _level_tween: Tween
## 1 at a change, easing to 0: the line flares up and settles.
var _pulse := 0.0
var _pulse_tween: Tween


## The level after `code` from `level`; -1 for a key that is not a volume key.
static func volume_after(code: String, level: float, unmuted: float) -> float:
	match code:
		"AudioVolumeUp":
			return snappedf(clampf(level + STEP, 0.0, 1.0), 0.01)
		"AudioVolumeDown":
			return snappedf(clampf(level - STEP, 0.0, 1.0), 0.01)
		"AudioVolumeMute":
			return 0.0 if level > 0.0 else (unmuted if unmuted > 0.0 else STEP)
	return -1.0


## The binding `code` is set to in `bindings` (`next`, `voiceAssistant`, ...); "" when none.
static func bound_to(bindings, code: String) -> String:
	if not bindings is Dictionary:
		return ""
	for b in bindings:
		if bindings[b] == code:
			return b
	return ""


func _init() -> void:
	layer = 10
	_card = PanelContainer.new()
	_card.name = "Volume"
	_card.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_card.visible = false
	_icon = UI.icon("vol", "icon")
	_bar = Control.new()
	_bar.draw.connect(_draw_bar)
	_percent = UI.label("", "body", "body")
	_card.add_child(UI.hbox([_icon, _bar, _percent], 1.0))
	add_child(_card)
	_hide = Timer.new()
	_hide.one_shot = true
	_hide.wait_time = SHOWN_S
	_hide.timeout.connect(_hide_overlay)
	_glow = Control.new()
	_glow.name = "VolumeLine"
	_glow.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_glow.modulate.a = 0.0
	_glow.draw.connect(_draw_glow)
	add_child(_glow)
	add_child(_hide)


func _ready() -> void:
	ThemeManager.changed.connect(_style)
	# A level already there (or a new core's) is no change to show.
	_seen = Core.get_value("/config/huVolume")
	Core.welcome.connect(func(_v): _seen = Core.get_value("/config/huVolume"))
	Core.changed.connect(_on_core_changed)
	_style()


func _input(event: InputEvent) -> void:
	if not event is InputEventKey:
		return
	var key: Key = event.physical_keycode if event.physical_keycode != KEY_NONE else event.keycode
	var code: String = CODES.get(key, "")
	if code == "":
		return
	if _volume(code, event.pressed, event.echo) or _to_core(code, event.pressed, event.echo):
		get_viewport().set_input_as_handled()


func _volume(code: String, pressed: bool, echo: bool) -> bool:
	var now := Time.get_ticks_msec()
	var current = _sent if now - _sent_at < PENDING_MS else Core.get_value("/config/huVolume")
	if not current is float:
		current = 0.0
	var next := volume_after(code, current, _unmuted)
	if next < 0.0:
		return false
	# Held, mute would toggle on every repeat.
	if not pressed or (echo and code == "AudioVolumeMute"):
		return true
	if code == "AudioVolumeMute" and current > 0.0:
		_unmuted = current
	_sent = next
	_sent_at = now
	var err: String = Core.act({kind = "setConfig", patch = {huVolume = next}})
	if err != "":
		push_warning("volume: %s" % err)
	return true


## As the stock UI: a bound key's press goes to the core, which knows what each does in
## projection; the release only for the voice assistant, which holds while pressed.
func _to_core(code: String, pressed: bool, echo: bool) -> bool:
	var binding := bound_to(Core.get_value("/config/bindings"), code)
	if binding == "":
		return false
	if pressed and not (echo and binding == "voiceAssistant"):
		Core.input({kind = "key", code = code, down = true})
	elif not pressed and binding == "voiceAssistant":
		Core.input({kind = "key", code = code, down = false})
	return true


func _on_core_changed(sections: PackedStringArray) -> void:
	if not "config" in sections:
		return
	var level = Core.get_value("/config/huVolume")
	if not level is float or level == _seen:
		return
	var first: bool = _seen == null
	_seen = level
	if first or Core.get_value("/config/overlayMessages") == false:
		return
	_percent.text = "%d %%" % roundi(clampf(level, 0.0, 1.0) * 100.0)
	_icon.get_meta("icon")[2] = "dim" if level <= 0.0 else "text"
	UI.style_icon(_icon)
	_ease_to(clampf(level, 0.0, 1.0))
	if ThemeManager.volume_style == "glow":
		_card.visible = false
		_glow.queue_redraw()
		_fade_glow(1.0)
	else:
		_glow.modulate.a = 0.0
		_card.visible = true
	_place.call_deferred()
	_hide.start()


func _ease_to(level: float) -> void:
	if _level_tween:
		_level_tween.kill()
	# Shown from hidden: start where it is, not slide up from the last time.
	if ThemeManager.reduced_motion or (not _card.visible and _glow.modulate.a <= 0.01):
		_set_drawn(level)
		return
	if _pulse_tween:
		_pulse_tween.kill()
	_pulse_tween = create_tween().set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	_pulse_tween.tween_method(func(v): _pulse = v; _glow.queue_redraw(), 1.0, 0.0, 0.9)
	_level_tween = create_tween().set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	_level_tween.tween_method(_set_drawn, _drawn, level, 0.5)


func _set_drawn(v: float) -> void:
	_drawn = v
	_bar.queue_redraw()
	_glow.queue_redraw()


func _hide_overlay() -> void:
	_card.visible = false
	_fade_glow(0.0)


func _fade_glow(to: float) -> void:
	if _glow_tween:
		_glow_tween.kill()
	if ThemeManager.reduced_motion:
		_glow.modulate.a = to
		return
	_glow_tween = create_tween()
	_glow_tween.tween_property(_glow, "modulate:a", to, 0.18 if to > 0.0 else 0.45)


## Lit from the left to the level: a soft bloom rising from the bottom edge, a bright core, and
## a flare where it ends.
func _draw_glow() -> void:
	var w := _glow.size.x
	var h := _glow.size.y
	var end := w * _drawn
	var c: Color = ThemeManager.c.accent
	_glow.draw_rect(Rect2(0, h - 3.0, w, 3.0), Color(c, 0.15))
	var rise := h * (0.75 + 0.25 * _pulse)
	_glow.draw_texture_rect(_bloom, Rect2(0, h - rise, end, rise), false, Color(c.lightened(0.25 * _pulse), 0.7 + 0.3 * _pulse))
	_glow.draw_rect(Rect2(0, h - 3.0, end, 3.0), c.lightened(0.5))
	var f := h * 1.3
	_glow.draw_texture_rect(_flare, Rect2(end - f / 2.0, h - f / 2.0, f, f), false, Color(c.lightened(0.2), 0.35))


## A white falloff, alpha easing out from full: up from the bottom edge, or out from the centre.
static func _falloff(radial: bool) -> GradientTexture2D:
	var g := Gradient.new()
	g.offsets = PackedFloat32Array()
	g.colors = PackedColorArray()
	for i in 17:
		var x := i / 16.0
		g.add_point(x, Color(1, 1, 1, pow(1.0 - x, 2.6)))
	var tex := GradientTexture2D.new()
	tex.gradient = g
	if radial:
		tex.fill = GradientTexture2D.FILL_RADIAL
		tex.fill_from = Vector2(0.5, 0.5)
		tex.fill_to = Vector2(1.0, 0.5)
		tex.width = 256
		tex.height = 256
	else:
		tex.fill_from = Vector2(0.5, 1.0)
		tex.fill_to = Vector2(0.5, 0.0)
		tex.width = 4
		tex.height = 256
	return tex


func _draw_bar() -> void:
	var h: float = maxf(4.0, ThemeManager.px.gap * 0.4)
	var r := Rect2(0, (_bar.size.y - h) / 2.0, _bar.size.x, h)
	_bar.draw_rect(r, ThemeManager.c.line)
	r.size.x *= _drawn
	_bar.draw_rect(r, ThemeManager.c.accent)


func _style() -> void:
	UI.restyle(_card)
	_card.add_theme_stylebox_override("panel", ThemeManager.card_box())
	_bar.custom_minimum_size = Vector2(ThemeManager.px.touch * 3.0, ThemeManager.px.icon)
	# Wide enough for "100 %", so the card does not jump as the level changes.
	_percent.custom_minimum_size.x = ThemeManager.fonts.body.get_string_size("100 %", HORIZONTAL_ALIGNMENT_LEFT, -1, ThemeManager.font_size("body")).x
	_percent.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_place.call_deferred()


## Top center, below a status bar along the top, as the stock overlay sat.
func _place() -> void:
	_card.reset_size()
	var vp := get_viewport().get_visible_rect().size
	var top: float = ThemeManager.px.status if ThemeManager.status_position == "top" else 0.0
	_card.position = Vector2((vp.x - _card.size.x) / 2.0, top + ThemeManager.px.gap)
	_glow.position = Vector2(0, vp.y - 60.0)
	_glow.size = Vector2(vp.x, 60.0)
