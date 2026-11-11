class_name SourceToggle
extends Card
## What home's slot shows, "Phone | <navigation app>": a segmented pill under the cards on the
## slot's side, while both are there. The chosen segment is filled with the accent.

## A segment tapped: "phone" or "nav".
signal picked(source: String)

## "phone" or "nav".
var source := "phone":
	set(v):
		if v != source:
			source = v
			_restyle_segments()
var nav_name := "":
	set(v):
		if v != nav_name:
			nav_name = v
			_restyle_segments()

var _phone: Button
var _nav: Button


func _build() -> void:
	name = "Source"
	var box := HBoxContainer.new()
	box.name = "Box"
	box.add_theme_constant_override("separation", 0)
	_phone = _segment("Phone", "phone")
	_nav = _segment("Nav", "nav")
	box.add_child(_phone)
	box.add_child(_nav)
	add_child(box)


func _segment(node_name: String, pick: String) -> Button:
	var b := Button.new()
	b.name = node_name
	b.focus_mode = Control.FOCUS_NONE
	b.clip_text = true
	b.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	b.pressed.connect(func(): picked.emit(pick))
	return b


func _style() -> void:
	var g: float = ThemeManager.px.gap
	var h: float = ThemeManager.px.touch
	var pad := roundf(g * 0.3)
	var panel: StyleBox = get_theme_stylebox("panel")
	panel.set_content_margin_all(pad)
	if panel is StyleBoxFlat:
		# A pill: no card's accent edge on one side.
		panel.set_corner_radius_all(roundi(h / 2.0 + pad))
		panel.border_width_left = panel.border_width_right
	_restyle_segments()


func _restyle_segments() -> void:
	if _phone == null or ThemeManager.c.is_empty():
		return
	var g: float = ThemeManager.px.gap
	var h: float = ThemeManager.px.touch
	var font: Font = ThemeManager.fonts.strong
	var fs := ThemeManager.font_size("caption")
	for pair in [[_phone, "Phone", "phone"], [_nav, nav_name if nav_name != "" else "Maps", "pin"]]:
		var b: Button = pair[0]
		var on := (b == _phone) == (source == "phone")
		b.text = pair[1]
		b.icon = Icons.texture(pair[2], ThemeManager.px.icon)
		var box := StyleBoxFlat.new()
		box.bg_color = ThemeManager.c.accent if on else Color(0, 0, 0, 0)
		box.set_corner_radius_all(roundi(h / 2.0))
		box.content_margin_left = g
		box.content_margin_right = g * 1.2
		box.anti_aliasing = true
		for s in ["normal", "hover", "pressed", "hover_pressed", "focus", "disabled"]:
			b.add_theme_stylebox_override(s, box)
		var ink: Color = ThemeManager.c.on_accent if on else ThemeManager.c.text
		for k in ["font_color", "font_hover_color", "font_pressed_color", "font_hover_pressed_color", "font_focus_color"]:
			b.add_theme_color_override(k, ink)
		for k in ["icon_normal_color", "icon_hover_color", "icon_pressed_color", "icon_hover_pressed_color", "icon_focus_color"]:
			b.add_theme_color_override(k, ink)
		b.add_theme_font_override("font", font)
		b.add_theme_font_size_override("font_size", fs)
		b.add_theme_constant_override("h_separation", roundi(g * 0.5))
		# As wide as its word, within a few touch targets: a long app name is cut short.
		var w: float = font.get_string_size(b.text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x + ThemeManager.px.icon + g * 2.7
		b.custom_minimum_size = Vector2(clampf(ceilf(w), h * 1.6, h * 4.0), h)
	update_minimum_size()
