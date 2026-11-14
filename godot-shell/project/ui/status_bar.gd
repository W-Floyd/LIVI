class_name StatusBar
extends PanelContainer
## Clock, outside temperature, phone and charge. Information only, but for home's slot toggle
## (SourceToggle), which the shell lays over `source_slot` in place of the phone's name. A row along the top or bottom edge, or a column along the left or right one
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
## Too narrow for everything (riding home's cards): the outside temperature goes, after the slot
## toggle's words.
var narrow := false:
	set(v):
		narrow = v
		if _temp_item and not vertical():
			_temp_item.visible = not v

## In a row, the clock and the outside temperature at the right end, the rest at the left: riding
## cards that sit left of the picture, so the clock stays at the picture's edge.
var start_right := false:
	set(v):
		if v == start_right:
			return
		start_right = v
		if not vertical():
			_arrange()
			if is_inside_tree():
				_style()

## The room the slot toggle takes in place of the phone's name; zero: the name.
var source_size := Vector2.ZERO:
	set(v):
		if v == source_size:
			return
		source_size = v
		_show_source()
## Where the shell lays the slot toggle.
var source_slot: Control
## The slot moved or resized.
signal source_moved
var charge := "":
	set(v):
		charge = v
		if _charge: _charge.text = v

## Off while the page shows the charge itself (home's battery card).
var charge_shown := true:
	set(v):
		charge_shown = v
		if _charge: _charge.get_parent().visible = v

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
var _phone_item: Control
var _temp_item: Control
## The phone's signal: on the slot toggle's phone side while it shows in a row.
var _bars: Control
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
	_bars = bars
	if not vertical():
		for l in [_clock, _outside, _phone, _charge]:
			l.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
		_phone.clip_text = false
		_phone.text_overrun_behavior = TextServer.OVERRUN_NO_TRIMMING
		_phone_item = UI.hbox([phone_icon, _phone], 0.3)
		_temp_item = UI.hbox([temp, _outside], 0.3)
		# The clock at the start end, outermost; the rest at the far end.
		var time := UI.hbox([_temp_item, _clock] if start_right else [_clock, _temp_item], 1.0)
		var rest := UI.hbox([_phone_item, _slot(), bars, UI.hbox([_charge_icon, _charge], 0.3)], 1.5)
		add_child(UI.hbox([rest, UI.spacer(), time] if start_right else [time, UI.spacer(), rest], 1.5))
		_charge.get_parent().visible = charge_shown
		_temp_item.visible = not narrow
		_show_source()
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
		_temp_vbox(temp),
		gap,
		_phone_vbox(phone_icon),
		_slot(),
		bars,
		UI.vbox([_charge_icon, _charge], 0.2),
	], 1.2))
	_charge.get_parent().visible = charge_shown
	_show_source()


func _temp_vbox(icon: Control) -> Control:
	_temp_item = UI.vbox([icon, _outside], 0.2)
	return _temp_item


func _phone_vbox(icon: Control) -> Control:
	_phone_item = UI.vbox([icon, _phone], 0.2)
	return _phone_item


func _slot() -> Control:
	source_slot = Control.new()
	source_slot.name = "SourceSlot"
	source_slot.mouse_filter = Control.MOUSE_FILTER_IGNORE
	source_slot.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	source_slot.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	source_slot.item_rect_changed.connect(func(): source_moved.emit())
	return source_slot


func _show_source() -> void:
	if source_slot == null:
		return
	var on := source_size != Vector2.ZERO
	source_slot.visible = on
	source_slot.custom_minimum_size = source_size
	_phone_item.visible = not on
	_bars.visible = not on or vertical()


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
