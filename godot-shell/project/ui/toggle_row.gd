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
	var surface: ShaderMaterial = null if button_pressed else ThemeManager.surface_material(size)
	material = surface
	for s in ["normal", "hover", "focus", "disabled"]:
		if surface:
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
	var row: HBoxContainer = _label.get_parent().get_parent()
	custom_minimum_size.y = max(ThemeManager.px.touch * 1.3, row.get_combined_minimum_size().y + ThemeManager.px.gap * 1.6)
	var m := roundi(ThemeManager.px.gap * 1.2)
	row.offset_left = m
	row.offset_right = -m
	# Foreground follows the state: on-accent over the accent fill.
	var on := button_pressed
	_label.add_theme_color_override("font_color", ThemeManager.c.on_accent if on else ThemeManager.c.text)
	_detail.add_theme_color_override("font_color", ThemeManager.c.on_accent if on else ThemeManager.c.dim)
	_icon.modulate = ThemeManager.c.on_accent if on else ThemeManager.c.text
