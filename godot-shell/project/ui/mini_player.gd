class_name MiniPlayer
extends Card
## What's playing, with the three controls a driver needs. One line each for title and
## source, cut with an ellipsis: no scrolling text.

signal control(name: String)  # playPause | next | prev

var title := "":
	set(v):
		title = v
		if _title: _title.text = v
var subtitle := "":
	set(v):
		subtitle = v
		if _subtitle: _subtitle.text = v
var playing := false:
	set(v):
		playing = v
		if _play: _style()

var _art: Panel
var _title: Label
var _subtitle: Label
var _prev: Button
var _play: Button
var _next: Button


func _build() -> void:
	_art = Panel.new()
	_title = UI.label(title, "strong", "body")
	_subtitle = UI.label(subtitle, "body", "caption", "dim")
	for l in [_title, _subtitle]:
		l.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		l.clip_text = true
	var meta := UI.vbox([_title, _subtitle], 0)
	meta.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	meta.alignment = BoxContainer.ALIGNMENT_CENTER
	_prev = _button("prev", "Previous")
	_play = _button("pause", "Pause")
	_next = _button("next", "Next")
	_prev.pressed.connect(func(): control.emit("prev"))
	_play.pressed.connect(func(): control.emit("playPause"))
	_next.pressed.connect(func(): control.emit("next"))
	var buttons := UI.hbox([_prev, _play, _next], 0)
	buttons.set_meta("gap", 0.0)
	add_child(UI.hbox([_art, meta, buttons], 1.0))


func has_content() -> bool:
	return title != ""


func _button(icon: String, name: String) -> Button:
	var b := Button.new()
	b.name = name
	b.tooltip_text = name
	b.focus_mode = Control.FOCUS_NONE
	b.expand_icon = false
	b.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
	b.set_meta("icon_name", icon)
	return b


func _style() -> void:
	var t: float = ThemeManager.px.touch
	_art.custom_minimum_size = Vector2(t, t)
	var art := StyleBoxFlat.new()
	art.bg_color = ThemeManager.c.surface2
	art.border_color = ThemeManager.c.accent
	art.set_border_width_all(roundi(t * 0.08))
	art.set_corner_radius_all(roundi(ThemeManager.px.radius))
	_art.add_theme_stylebox_override("panel", art)
	_play.set_meta("icon_name", "pause" if playing else "play")
	_play.tooltip_text = "Pause" if playing else "Play"
	(_play.get_parent() as BoxContainer).add_theme_constant_override("separation", roundi(ThemeManager.px.touch_gap))
	for b in [_prev, _play, _next]:
		b.custom_minimum_size = Vector2(t, t)
		b.icon = Icons.texture(b.get_meta("icon_name"), ThemeManager.px.icon)
	# The main control is the accent; the others are quiet.
	var accent := StyleBoxFlat.new()
	accent.bg_color = ThemeManager.c.accent
	accent.set_corner_radius_all(roundi(ThemeManager.px.radius))
	for s in ["normal", "hover", "pressed", "hover_pressed"]:
		_play.add_theme_stylebox_override(s, accent)
	for k in ["icon_normal_color", "icon_hover_color", "icon_pressed_color", "icon_hover_pressed_color"]:
		_play.add_theme_color_override(k, ThemeManager.c.on_accent)
