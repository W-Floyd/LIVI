class_name StatusBar
extends PanelContainer
## Clock, outside temperature, phone and charge. Information only: nothing here is a small
## tap target.

var clock := "--:--":
	set(v):
		clock = v
		if _clock: _clock.text = v
var outside := "":
	set(v):
		outside = v
		if _outside: _outside.text = v
var phone := "":
	set(v):
		phone = v
		if _phone: _phone.text = v
var charge := "":
	set(v):
		charge = v
		if _charge: _charge.text = v

var charge_icon := "bolt":
	set(v):
		charge_icon = v
		if _charge_icon:
			_charge_icon.get_meta("icon")[0] = v
			UI.style_icon(_charge_icon)

var _clock: Label
var _outside: Label
var _phone: Label
var _charge: Label
var _charge_icon: TextureRect


func _init() -> void:
	_clock = UI.label(clock, "display", "body")
	_outside = UI.label(outside, "body", "caption", "dim")
	_phone = UI.label(phone, "body", "caption", "dim")
	_charge = UI.label(charge, "body", "caption", "dim")
	_charge_icon = UI.icon(charge_icon, "icon", "dim")
	add_child(UI.hbox([
		_clock,
		UI.hbox([UI.icon("temp", "icon", "dim"), _outside], 0.3),
		UI.spacer(),
		UI.hbox([UI.icon("phone", "icon", "dim"), _phone], 0.3),
		UI.icon("bars", "icon", "dim"),
		UI.hbox([_charge_icon, _charge], 0.3),
	], 1.5))


func _ready() -> void:
	ThemeManager.changed.connect(_style)
	resized.connect(_style)
	_style()


func _style() -> void:
	UI.restyle(self)
	var b := StyleBoxFlat.new()
	b.bg_color = ThemeManager.c.bg
	b.border_width_bottom = 2
	b.border_color = ThemeManager.c.line
	b.content_margin_left = ThemeManager.px.gap * 2
	b.content_margin_right = ThemeManager.px.gap * 2
	if ThemeManager.floating():
		# The surface shader fills it, over the map.
		b.bg_color = Color.WHITE
		b.border_width_bottom = 0
	elif ThemeManager.is_scene():
		b.bg_color = Color(0, 0, 0, 0)
		b.border_width_bottom = 0
	add_theme_stylebox_override("panel", b)
	custom_minimum_size.y = ThemeManager.px.status
	material = ThemeManager.surface_material(size)
