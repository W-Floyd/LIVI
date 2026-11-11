class_name AutoChip
extends Button
## A compact on/off inside a card: a short word in a pill, filled when on. A touch target of its
## own. `on_accent` when the card under it is the accent fill.

var on_accent := false:
	set(v):
		on_accent = v
		_style()


func _init(word := "") -> void:
	text = word
	toggle_mode = true
	focus_mode = Control.FOCUS_NONE
	toggled.connect(func(_on): _style())


func _ready() -> void:
	ThemeManager.changed.connect(_style)
	_style()


func _style() -> void:
	if ThemeManager.c.is_empty():
		return
	var h: float = ThemeManager.px.touch
	add_theme_font_override("font", ThemeManager.fonts.strong)
	add_theme_font_size_override("font_size", ThemeManager.font_size("caption"))
	custom_minimum_size = Vector2(h * 1.6, h)
	var fill: Color = ThemeManager.c.on_accent if on_accent else ThemeManager.c.accent
	var ink: Color = ThemeManager.c.accent if on_accent else ThemeManager.c.on_accent
	var line: Color = ThemeManager.c.on_accent if on_accent else ThemeManager.c.dim
	var word: Color = ink if button_pressed else line
	var b := StyleBoxFlat.new()
	b.bg_color = fill if button_pressed else Color(0, 0, 0, 0)
	b.border_color = fill if button_pressed else line
	b.set_border_width_all(maxi(1, roundi(ThemeManager.px.gap * 0.15)))
	b.set_corner_radius_all(roundi(h * 0.5))
	b.content_margin_left = ThemeManager.px.gap
	b.content_margin_right = ThemeManager.px.gap
	for s in ["normal", "hover", "pressed", "hover_pressed", "disabled", "focus"]:
		add_theme_stylebox_override(s, b)
	for s in ["font_color", "font_hover_color", "font_pressed_color", "font_hover_pressed_color", "font_focus_color"]:
		add_theme_color_override(s, word)
	add_theme_color_override("font_disabled_color", line)
	# Disabled: the card says why.
	modulate.a = 0.45 if disabled else 1.0
