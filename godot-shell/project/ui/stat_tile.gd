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

## Smaller type on one line, for home when the full tile has no room.
var compact := false:
	set(v):
		if v == compact:
			return
		compact = v
		if _bar: _restyle()

## A narrow column: the value over a bar that fills upward, the secondary value under it (home's
## split layout).
var vertical := false:
	set(v):
		if v == vertical:
			return
		vertical = v
		if _bar:
			_arrange()
			_restyle()

## Room kept along the card's foot for a row placed over it (home's Precondition, `HomeCards.foot`).
var foot := 0.0:
	set(v):
		if v == foot:
			return
		foot = v
		if _foot:
			_foot.custom_minimum_size.y = v
			_foot.visible = v > 0.0

var _icon: TextureRect
var _value: Label
var _unit: Label
var _sub_label: Label
var _sub_value: Label
var _bar: Control
var _fill: Control
var _foot: Control
var _number: HBoxContainer
var _sub: VBoxContainer
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
	_number = UI.hbox([_icon, _value, lift], 0.3)
	_sub = UI.vbox([_sub_label, _sub_value], 0)
	_bar = Control.new()
	_bar.draw.connect(_draw_bar)
	_fill = Control.new()
	_fill.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_fill.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_foot = Control.new()
	_foot.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_foot.visible = false
	_arrange()


## Into a row with the bar under it, or the column.
func _arrange() -> void:
	for n in [_number, _sub, _fill, _bar, _foot]:
		if n.get_parent():
			n.get_parent().remove_child(n)
	for c in get_children():
		remove_child(c)
		c.queue_free()
	var side := HORIZONTAL_ALIGNMENT_CENTER if vertical else HORIZONTAL_ALIGNMENT_RIGHT
	_sub_label.horizontal_alignment = side
	_sub_value.horizontal_alignment = side
	_number.alignment = BoxContainer.ALIGNMENT_CENTER if vertical else BoxContainer.ALIGNMENT_BEGIN
	_sub.size_flags_vertical = Control.SIZE_SHRINK_END
	_bar.size_flags_horizontal = Control.SIZE_SHRINK_CENTER if vertical else Control.SIZE_FILL
	_bar.size_flags_vertical = Control.SIZE_EXPAND_FILL if vertical else Control.SIZE_FILL
	if vertical:
		add_child(UI.vbox([_number, _bar, _sub, _foot], 0.6))
	else:
		add_child(UI.vbox([UI.hbox([_number, UI.spacer(), _sub]), _fill, _bar, _foot], 0.6))


func _style() -> void:
	var f := ThemeManager.fonts
	var k := HERO_SCALE if hero else 1.0
	var big := roundi(ThemeManager.px.display * k)
	var mid := roundi(ThemeManager.px.title * k)
	if compact:
		big = roundi(ThemeManager.px.title * 1.3)
		mid = roundi(ThemeManager.px.body)
	_sub_label.visible = not compact
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
	_bar.custom_minimum_size = Vector2(0, roundi(ThemeManager.px.gap * (2.0 if hero else 0.8 if compact else 1.2)))
	if vertical:
		_bar.custom_minimum_size = Vector2(roundi(ThemeManager.px.touch * 0.9), roundi(ThemeManager.px.touch * 1.5))
	_bar.visible = fraction >= 0.0
	_bar.queue_redraw()


func _draw_bar() -> void:
	var r := Rect2(Vector2.ZERO, _bar.size)
	if vertical:
		var rv := minf(r.size.x / 2.0, ThemeManager.px.radius)
		_rounded(r, rv, ThemeManager.c.surface2)
		if fraction > 0.0:
			var h := maxf(rv * 2.0, r.size.y * clampf(fraction, 0, 1))
			_rounded(Rect2(r.position.x, r.end.y - h, r.size.x, h), rv, ThemeManager.c.accent)
		return
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
