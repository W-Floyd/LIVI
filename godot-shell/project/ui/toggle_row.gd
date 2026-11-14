class_name ToggleRow
extends Button
## A full-width setting: icon, what it does, and a detail under it. On uses the accent, and
## the label says the state in words too. At least the touch-target height.

var icon_name := "therm"
var label := "":
	set(v):
		label = v
		if _label: _label.text = v
var detail := "":
	set(v):
		detail = v
		if _detail: _detail.text = v
## A control at the row's end with its own taps, such as an AutoChip; the text gives way to it.
var trailing: Control:
	set(v):
		if trailing:
			remove_child(trailing)
		trailing = v
		if v:
			add_child(v)
		if _label:
			_style()

## One line, a touch target high: the label (`short_label` where set) without the detail, for
## home when the full row has no room. A full row too shows `short_label` where `label` would be
## cut.
var compact := false:
	set(v):
		if v != compact:
			compact = v
			if _label:
				_style()
var short_label := ""
## Compact, the icon alone (and the trailing control): the state is the fill.
var icon_only := false:
	set(v):
		if v != icon_only:
			icon_only = v
			if _label:
				_style()

## Inside another card: a quieter fill of its own, no card surface.
var inset := false:
	set(v):
		if v != inset:
			inset = v
			if _label:
				_style()

var _icon: TextureRect
var _label: Label
var _detail: Label


func _init() -> void:
	toggle_mode = true
	focus_mode = Control.FOCUS_NONE
	_icon = UI.icon(icon_name)
	_label = UI.label(label, "strong", "body")
	_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_detail = UI.label(detail, "body", "caption", "dim")
	_detail.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	var text := UI.vbox([_label, _detail], 0)
	text.alignment = BoxContainer.ALIGNMENT_CENTER
	text.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var row := UI.hbox([_icon, text], 0.8)
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(row)
	toggled.connect(func(_on): _style())


func _ready() -> void:
	ThemeManager.changed.connect(_style)
	resized.connect(_style)
	_style()


func _style() -> void:
	# Off, over the map, it's a frosted or glass surface; on, it's the solid accent.
	var surface: ShaderMaterial = null if button_pressed or inset else ThemeManager.surface_material(size)
	material = surface
	# A pack's own button image stays.
	var flat := inset and not button_pressed and not ThemeManager.is_scene() \
		and not ThemeManager.godot_theme.get_stylebox("normal", "Button") is StyleBoxTexture
	for s in ["normal", "hover", "focus", "disabled"]:
		if flat:
			var b := StyleBoxFlat.new()
			b.bg_color = ThemeManager.c.surface2
			b.set_corner_radius_all(roundi(ThemeManager.px.radius))
			b.anti_aliasing = true
			add_theme_stylebox_override(s, b)
		elif surface:
			var b: StyleBox = ThemeManager.card_box()
			b.content_margin_top = 0
			b.content_margin_bottom = 0
			add_theme_stylebox_override(s, b)
		elif ThemeManager.is_scene():
			add_theme_stylebox_override(s, StyleBoxEmpty.new())
		else:
			remove_theme_stylebox_override(s)
	_icon.get_meta("icon")[0] = icon_name
	UI.restyle(self)
	_detail.visible = not compact
	_label.visible = not (compact and icon_only)
	_label.text = short_label if compact and short_label != "" else label
	# One line: the detail after the label where the row has room for both.
	if compact and not icon_only and detail != "":
		var f: Font = _label.get_theme_font("font")
		var both := "%s · %s" % [_label.text, detail]
		var room: float = size.x - compact_width(false) - ThemeManager.px.gap * 0.8
		if f.get_string_size(both, HORIZONTAL_ALIGNMENT_LEFT, -1, _label.get_theme_font_size("font_size")).x <= room:
			_label.text = both
	var row: HBoxContainer = _label.get_parent().get_parent()
	if compact:
		custom_minimum_size.y = ThemeManager.px.touch
		# A pill, like the chips beside it.
		for st in ["normal", "hover", "pressed", "hover_pressed", "focus", "disabled"]:
			var b = get_theme_stylebox(st)
			if b is StyleBoxFlat:
				b = b.duplicate()
				b.set_corner_radius_all(roundi(ThemeManager.px.touch * 0.5))
				add_theme_stylebox_override(st, b)
	else:
		for st in ["pressed", "hover_pressed"]:
			remove_theme_stylebox_override(st)
		custom_minimum_size.y = max(ThemeManager.px.touch * 1.3, row.get_combined_minimum_size().y + ThemeManager.px.gap * 1.6)
	var m := roundi(ThemeManager.px.gap * 1.2)
	row.offset_left = m
	row.offset_right = -m
	if trailing and trailing.visible:
		var t := trailing.get_combined_minimum_size()
		trailing.size = t
		trailing.position = Vector2(size.x - m - t.x, (size.y - t.y) * 0.5).round()
		row.offset_right = -(m + t.x + ThemeManager.px.gap)
	# The short label whole rather than the long one cut.
	if not compact and short_label != "":
		var f: Font = _label.get_theme_font("font")
		var room: float = size.x + row.offset_right - row.offset_left - _icon.get_combined_minimum_size().x - row.get_theme_constant("separation")
		if f.get_string_size(label, HORIZONTAL_ALIGNMENT_LEFT, -1, _label.get_theme_font_size("font_size")).x > room:
			_label.text = short_label
	# Foreground follows the state: on-accent over the accent fill.
	var on := button_pressed
	_label.add_theme_color_override("font_color", ThemeManager.c.on_accent if on else ThemeManager.c.text)
	_detail.add_theme_color_override("font_color", ThemeManager.c.on_accent if on else ThemeManager.c.dim)
	_icon.modulate = ThemeManager.c.on_accent if on else ThemeManager.c.text
	if trailing and "on_accent" in trailing:
		trailing.on_accent = on


## The compact row's width that shows its icon, label (`with_label`) and trailing control whole.
func compact_width(with_label := true) -> float:
	var w := 0.0
	if with_label:
		var f: Font = _label.get_theme_font("font")
		w = f.get_string_size(short_label if short_label != "" else label, HORIZONTAL_ALIGNMENT_LEFT, -1, _label.get_theme_font_size("font_size")).x + ThemeManager.px.gap * 0.8
	var m := roundf(ThemeManager.px.gap * 1.2)
	w += _icon.get_combined_minimum_size().x + m * 2.0
	if trailing and trailing.visible:
		w += trailing.get_combined_minimum_size().x + ThemeManager.px.gap
	return ceilf(w)
