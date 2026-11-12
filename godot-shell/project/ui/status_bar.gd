class_name StatusBar
extends PanelContainer
## Clock, outside temperature, phone and charge. Information only: nothing here is a small
## tap target. A row along the top or bottom edge, or a column along the left or right one
## (`edge`), the items stacked.

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
		if v == charge_icon:
			return
		charge_icon = v
		if _charge_icon:
			_charge_icon.get_meta("icon")[0] = v
			UI.style_icon(_charge_icon)

## top | bottom | left | right: the panel edge it runs along, its rule on the other side; off: the
## shell hides it.
var edge := "top":
	set(v):
		if v == edge:
			return
		var was := vertical()
		edge = v
		if vertical() != was:
			_arrange()
		if is_inside_tree():
			_style()

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
	_arrange()


func vertical() -> bool:
	return edge == "left" or edge == "right"


## The row, or the column: each reading an icon over its text, centred, so it stays narrow.
func _arrange() -> void:
	for c in get_children():
		for n in [_clock, _outside, _phone, _charge, _charge_icon]:
			if n.get_parent():
				n.get_parent().remove_child(n)
		remove_child(c)
		c.queue_free()
	var temp := UI.icon("temp", "icon", "dim")
	var phone_icon := UI.icon("phone", "icon", "dim")
	var bars := UI.icon("bars", "icon", "dim")
	if not vertical():
		for l in [_clock, _outside, _phone, _charge]:
			l.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
		_phone.clip_text = false
		_phone.text_overrun_behavior = TextServer.OVERRUN_NO_TRIMMING
		add_child(UI.hbox([
			_clock,
			UI.hbox([temp, _outside], 0.3),
			UI.spacer(),
			UI.hbox([phone_icon, _phone], 0.3),
			bars,
			UI.hbox([_charge_icon, _charge], 0.3),
		], 1.5))
		return
	for l in [_clock, _outside, _phone, _charge]:
		l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	# A long phone name is cut short rather than widening the column.
	_phone.clip_text = true
	_phone.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	var gap := Control.new()
	gap.size_flags_vertical = Control.SIZE_EXPAND_FILL
	gap.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(UI.vbox([
		_clock,
		UI.vbox([temp, _outside], 0.2),
		gap,
		UI.vbox([phone_icon, _phone], 0.2),
		bars,
		UI.vbox([_charge_icon, _charge], 0.2),
	], 1.2))


func _ready() -> void:
	ThemeManager.changed.connect(_style)
	resized.connect(_style)
	_style()


func _style() -> void:
	UI.restyle(self)
	var b := StyleBoxFlat.new()
	b.bg_color = ThemeManager.c.bg
	b.border_color = ThemeManager.c.line
	var g: float = ThemeManager.px.gap
	if vertical():
		b.border_width_right = 2 if edge == "left" else 0
		b.border_width_left = 2 if edge == "right" else 0
		b.content_margin_left = g
		b.content_margin_right = g
		b.content_margin_top = g * 2
		b.content_margin_bottom = g * 2
	else:
		b.border_width_bottom = 2 if edge == "top" else 0
		b.border_width_top = 2 if edge == "bottom" else 0
		b.content_margin_left = g * 2
		b.content_margin_right = g * 2
	if ThemeManager.floating():
		# The surface shader fills it, over the map.
		b.bg_color = Color.WHITE
		b.set_border_width_all(0)
	elif ThemeManager.is_scene():
		b.bg_color = Color(0, 0, 0, 0)
		b.set_border_width_all(0)
	add_theme_stylebox_override("panel", b)
	# The column is as wide as its widest item, and never narrower than the row is tall.
	custom_minimum_size = Vector2(ThemeManager.px.status, 0) if vertical() else Vector2(0, ThemeManager.px.status)
	material = ThemeManager.surface_material(size)
