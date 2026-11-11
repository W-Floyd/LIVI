class_name ChargeCard
extends Card
## While the car charges or its charger has a plug (`charging`, `chargerReady`): the time to full,
## and for AC and DC the car's limit, the range at it and its time estimate. A row shows only
## with what the car reports; the charge port's state is the car's (CarStatus).

const ROWS := [
	["Limit", "chargeLimitAcPct", "chargeLimitDcPct", "pct"],
	["Range", "rangeAtChargeLimitAcKm", "rangeAtChargeLimitDcKm", "km"],
	["Time", "chargeTimeAcMin", "chargeTimeDcMin", "min"],
]

var _icon: TextureRect
var _title: Label
var _value: Label
var _unit: Label
var _grid: GridContainer
var _t := {}


func _build() -> void:
	name = "ChargeCard"
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_icon = UI.icon("bolt", "icon", "accent")
	_title = UI.label("", "strong", "body")
	_title.name = "Title"
	_value = UI.label("", "display", "title")
	_value.name = "ToFull"
	_unit = UI.label("to full", "body", "caption", "dim")
	_unit.name = "ToFullUnit"
	var big := UI.hbox([_value, _unit], 0.4)
	big.name = "Big"
	var head := UI.hbox([_icon, _title, UI.spacer(), big], 0.6)
	head.name = "Head"
	_grid = GridContainer.new()
	_grid.name = "Facts"
	_grid.columns = 3
	_grid.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var box := UI.vbox([head, _grid], 0.4)
	box.name = "Box"
	add_child(box)


func _style() -> void:
	var g: float = ThemeManager.px.gap
	_grid.add_theme_constant_override("h_separation", roundi(g * 2.0))
	_grid.add_theme_constant_override("v_separation", 0)
	_fill()


## Shows for `t`, the core's telemetry; false (and hidden) when nothing is plugged in.
func show_for(t: Dictionary) -> bool:
	_t = t
	visible = t.get("charging") == true or t.get("chargerReady") == true
	_fill()
	return visible


func _text(v: Variant, unit: String) -> String:
	if v == null:
		return "–"
	match unit:
		"pct":
			return "%d %%" % roundi(float(v))
		"km":
			return Units.range_text(float(v))
	return Units.duration_text(float(v))


func _fill() -> void:
	if _title == null or not visible:
		return
	var charging: bool = _t.get("charging") == true
	_title.text = "Charging" if charging else "Plugged in"
	_icon.get_meta("icon")[0] = "bolt" if charging else "plug"
	_icon.get_meta("icon")[2] = "accent" if charging else "text"
	UI.style_icon(_icon)
	var full = _t.get("chargeTimeToFullMin")
	var big: Control = _value.get_parent()
	big.visible = charging and full != null
	if big.visible:
		_value.text = Units.duration_text(float(full))
	for c in _grid.get_children():
		_grid.remove_child(c)
		c.queue_free()
	var rows := ROWS.filter(func(r): return _t.get(r[1]) != null or _t.get(r[2]) != null)
	_grid.visible = not rows.is_empty()
	if rows.is_empty():
		return
	for h in ["", "AC", "DC"]:
		var l := UI.label(h, "body", "caption", "dim")
		l.name = "Head" + h
		l.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		_grid.add_child(l)
	for r in rows:
		var k := UI.label(r[0], "body", "caption", "dim")
		k.name = r[0]
		_grid.add_child(k)
		for i in [1, 2]:
			var v := UI.label(_text(_t.get(r[i]), r[3]), "strong", "caption")
			v.name = "%s%s" % [r[0], "AC" if i == 1 else "DC"]
			v.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
			_grid.add_child(v)
