class_name StatTile
extends Card
## One live value with its unit and a secondary value, and a bar for the value's share: the
## battery's charge and range.

var value := "–":
	set(v):
		value = v
		if _value: _value.text = v
var unit := "%":
	set(v):
		unit = v
		if _unit: _unit.text = v
var sub_label := "Range":
	set(v):
		sub_label = v
		if _sub_label: _sub_label.text = v
var sub_value := "":
	set(v):
		sub_value = v
		if _sub_value: _sub_value.text = v
## What the value is: bolt for charge, fuel for the tank.
var icon_name := "bolt":
	set(v):
		icon_name = v
		if _icon:
			_icon.get_meta("icon")[0] = v
			UI.style_icon(_icon)
## 0 to 1; negative hides the bar.
var fraction := -1.0:
	set(v):
		fraction = v
		if _bar:
			_bar.visible = v >= 0.0
			_bar.queue_redraw()
## Home's dashboard hero: larger type, the bar along the card's foot.
var hero := false:
	set(v):
		if v == hero:
			return
		hero = v
		if _bar: _restyle()

var _icon: TextureRect
var _value: Label
var _unit: Label
var _sub_label: Label
var _sub_value: Label
var _bar: Control
var _fill: Control
## The hero's type over the tile's.
const HERO_SCALE := 1.8


func _build() -> void:
	_value = UI.label(value, "display", "display")
	_unit = UI.label(unit, "body", "title", "dim")
	_sub_label = UI.label(sub_label, "body", "caption", "dim")
	_sub_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_sub_value = UI.label(sub_value, "display", "title")
	_sub_value.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	# The unit sits on the number's baseline: lifted by the difference in their descents.
	var lift := MarginContainer.new()
	lift.name = "UnitLift"
	lift.add_child(_unit)
	lift.size_flags_vertical = Control.SIZE_SHRINK_END
	_icon = UI.icon(icon_name, "icon", "dim")
	var number := UI.hbox([_icon, _value, lift], 0.3)
	number.alignment = BoxContainer.ALIGNMENT_BEGIN
	var sub := UI.vbox([_sub_label, _sub_value], 0)
	sub.size_flags_vertical = Control.SIZE_SHRINK_END
	_bar = Control.new()
	_bar.draw.connect(_draw_bar)
	_fill = Control.new()
	_fill.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_fill.size_flags_vertical = Control.SIZE_EXPAND_FILL
	add_child(UI.vbox([UI.hbox([number, UI.spacer(), sub]), _fill, _bar], 0.6))


func _style() -> void:
	var f := ThemeManager.fonts
	var k := HERO_SCALE if hero else 1.0
	var big := roundi(ThemeManager.px.display * k)
	var mid := roundi(ThemeManager.px.title * k)
	_value.add_theme_font_size_override("font_size", big)
	_unit.add_theme_font_size_override("font_size", mid)
	_sub_value.add_theme_font_size_override("font_size", mid)
	_sub_label.add_theme_font_size_override("font_size", roundi(ThemeManager.px.caption * (1.25 if hero else 1.0)))
	_icon.get_meta("icon")[1] = "status" if hero else "icon"
	UI.style_icon(_icon)
	var lift: float = f.display.get_descent(big) - f.body.get_descent(mid)
	(_unit.get_parent() as MarginContainer).add_theme_constant_override("margin_bottom", roundi(max(0.0, lift)))
	# Pushes the bar to the hero's foot; nothing (no extra gap) in the column.
	_fill.visible = hero
	_bar.custom_minimum_size.y = roundi(ThemeManager.px.gap * (2.0 if hero else 1.2))
	_bar.visible = fraction >= 0.0
	_bar.queue_redraw()


func _draw_bar() -> void:
	var r := Rect2(Vector2.ZERO, _bar.size)
	var radius := r.size.y / 2.0
	_rounded(r, radius, ThemeManager.c.surface2)
	if fraction > 0.0:
		_rounded(Rect2(r.position, Vector2(max(r.size.y, r.size.x * clampf(fraction, 0, 1)), r.size.y)), radius, ThemeManager.c.accent)


func _rounded(r: Rect2, radius: float, color: Color) -> void:
	var b := StyleBoxFlat.new()
	b.bg_color = color
	b.set_corner_radius_all(roundi(radius))
	b.anti_aliasing = true
	_bar.draw_style_box(b, r)
