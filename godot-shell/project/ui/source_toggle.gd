class_name SourceToggle
extends Card
## What home's slot shows, "<navigation app> | <phone>": a segmented pill in the status bar in
## place of the phone's name (with the bar off, under the cards on the slot's side), while both
## are there. The chosen segment is filled with the accent.

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

## The phone's name on its segment.
var phone_name := "":
	set(v):
		if v != phone_name:
			phone_name = v
			_restyle_segments()
## Stacked, icons only: in a status bar column.
var vertical := false:
	set(v):
		if v != vertical:
			vertical = v
			if _box:
				_box.vertical = v
			_restyle_segments()

var _phone: Button
var _nav: Button
var _box: BoxContainer
## The phone's signal on its segment, after its name, in a row.
var _bars: TextureRect


func _build() -> void:
	name = "Source"
	_box = BoxContainer.new()
	_box.name = "Box"
	_box.add_theme_constant_override("separation", 0)
	_phone = _segment("Phone", "phone")
	_bars = UI.icon("bars", "icon")
	_bars.name = "Bars"
	_phone.add_child(_bars)
	_nav = _segment("Nav", "nav")
	_box.add_child(_nav)
	_box.add_child(_phone)
	add_child(_box)


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
	for pair in [[_phone, phone_name if phone_name != "" else "Phone", "phone"], [_nav, nav_name if nav_name != "" else "Maps", "pin"]]:
		var b: Button = pair[0]
		var on := (b == _phone) == (source == "phone")
		b.text = "" if vertical else pair[1]
		b.tooltip_text = pair[1]
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
		b.custom_minimum_size = Vector2(h, h) if vertical else Vector2(clampf(ceilf(w), h * 1.6, h * 4.0), h)
		b.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER if vertical else HORIZONTAL_ALIGNMENT_LEFT
		if vertical:
			box.content_margin_left = 0
			box.content_margin_right = 0
		elif b == _phone:
			# Room for the signal after the name.
			var bw: float = ThemeManager.px.icon + g * 0.5
			box.content_margin_right += bw
			b.custom_minimum_size.x += ceilf(bw)
			_bars.visible = true
			_bars.modulate = ink
			_bars.size = Vector2(ThemeManager.px.icon, h)
			_bars.position = Vector2(b.custom_minimum_size.x - g * 1.2 - ThemeManager.px.icon, 0.0)
		if vertical:
			_bars.visible = false
	update_minimum_size()
