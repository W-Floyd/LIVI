class_name CarStatus
extends VBoxContainer
## The car's body and power at a glance on the EV page: what is open (the car from above with
## the open parts lit, and in words) and the 12 V battery's charge; under them the climate, while
## its blower runs as the range's name has it, and the battery heater while it draws. Each shows
## once the car reports it. Rows hug the side `side` names.

## The 12 V battery's charge under which it reads in the warning color.
const AUX_LOW_PCT := 30
const PARTS := [
	["doorDriverOpen", "Driver's door"], ["doorPassengerOpen", "Passenger's door"],
	["doorRearLeftOpen", "Rear left door"], ["doorRearRightOpen", "Rear right door"],
	["hoodOpen", "Hood"], ["trunkOpen", "Trunk"], ["chargePortOpen", "Charge port"],
]

## 1 from the left, -1 from the right.
var side := 1.0
var _doors: DoorsMark
var _open: Label
var _body: HBoxContainer
var _aux: HBoxContainer
var _climate: HBoxContainer
var _heater: HBoxContainer
var _rows: Array[HBoxContainer] = []
## The items with something to show, most important first.
var _wanted: Array = []
## What is open in words, and as a count for a short row.
var _said := ["", ""]


func _init() -> void:
	name = "CarStatus"
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_meta("gap", 0.3)
	for i in 2:
		var r := UI.hbox([], 1.5)
		r.name = "Row%d" % i
		add_child(r)
		_rows.append(r)
	_doors = DoorsMark.new()
	_open = UI.label("", "body", "caption", "warn")
	_open.name = "Open"
	_body = UI.hbox([_doors, _open], 0.5)
	_body.name = "Body"
	_rows[0].add_child(_body)
	_aux = _chip(_rows[0], "Aux", "battery")
	_climate = _chip(_rows[1], "Climate", "fan")
	_heater = _chip(_rows[1], "Heater", "therm")
	for c in [_body, _aux, _climate, _heater]:
		c.alignment = BoxContainer.ALIGNMENT_CENTER
		c.visible = false


func _chip(row: HBoxContainer, chip_name: String, icon_name: String) -> HBoxContainer:
	var l := UI.label("", "body", "caption", "text")
	l.name = "Label"
	var c := UI.hbox([UI.icon(icon_name, "icon", "dim"), l], 0.4)
	c.name = chip_name
	row.add_child(c)
	return c


func _set_chip(c: HBoxContainer, text: String, color := "text") -> void:
	c.visible = text != ""
	var l: Label = c.get_node("Label")
	l.text = text
	l.get_meta("look")[2] = color
	UI.style_label(l)
	var icon: TextureRect = c.get_child(0)
	icon.get_meta("icon")[2] = "dim" if color == "text" else color
	UI.style_icon(icon)


## Fills from `t`, the core's telemetry; false when there is nothing to show.
func show_for(t: Dictionary) -> bool:
	var open := []
	var warn := false
	var parts := {}
	for p in PARTS:
		var on: bool = t.get(p[0]) == true
		parts[p[0]] = on
		if on:
			open.append(p[1])
			warn = warn or p[0] != "chargePortOpen"
	_body.visible = not open.is_empty()
	_doors.parts = parts
	_doors.queue_redraw()
	# A short line while driving too: past two parts the picture says which.
	var said := ""
	if open.size() > 2:
		said = "%d open" % open.size()
	elif not open.is_empty():
		said = ("%s open" % " and ".join(open)).to_lower()
		said = said.substr(0, 1).to_upper() + said.substr(1)
	_said = [said, "" if open.is_empty() else "%d open" % open.size()]
	_open.text = said
	_open.get_meta("look")[2] = "warn" if warn else "text"
	UI.style_label(_open)
	var aux = t.get("auxBatteryPct")
	_set_chip(_aux, "" if aux == null else "12 V %d %%" % roundi(float(aux)), "warn" if aux != null and float(aux) < AUX_LOW_PCT else "text")
	var w = t.get("climatePowerW")
	var drawing: bool = w != null and float(w) > 0.0
	# Its draw only: the range's name already says the climate is on.
	_set_chip(_climate, "" if not (drawing and EvLive.blower_running()) else "Climate %s" % Units.power_text(float(w)))
	var hw = t.get("batteryHeaterW")
	_set_chip(_heater, "" if hw == null or float(hw) <= 0.0 else "Battery heater %s" % Units.power_text(float(hw)))
	_wanted = [_body, _aux, _heater, _climate].filter(func(c): return c.visible)
	return keep(_wanted.size())


## Shows only the `n` most important items it has (what is open, the 12 V battery, the heater,
## the climate), for a page with no room for them all; false when that is none.
func keep(n: int, terse := false) -> bool:
	_open.text = _said[1 if terse else 0]
	for i in _wanted.size():
		_wanted[i].visible = i < n
	for r in _rows:
		r.visible = r.get_children().any(func(c): return c.visible)
		r.alignment = BoxContainer.ALIGNMENT_BEGIN if side > 0 else BoxContainer.ALIGNMENT_END
	visible = _rows.any(func(r): return r.visible)
	return visible


func wanted() -> int:
	return _wanted.size()


## The car from above, front up, the driver's door on the driver's side: open doors swing out,
## an open hood or trunk is filled, in the warning color; an open charge port (rear right, as
## the EV6's) is a dot in the accent.
class DoorsMark:
	extends Control
	var parts := {}

	func _init() -> void:
		name = "Doors"
		mouse_filter = Control.MOUSE_FILTER_IGNORE

	func _ready() -> void:
		ThemeManager.changed.connect(_size)
		_size()

	func _size() -> void:
		custom_minimum_size = Vector2(ThemeManager.px.icon * 1.2, ThemeManager.px.icon * 1.5)
		queue_redraw()

	func _draw() -> void:
		var c := ThemeManager.c
		var w := size.x
		var h := size.y
		var line := maxf(1.5, h * 0.05)
		var body := Rect2(w * 0.28, h * 0.04, w * 0.44, h * 0.92)
		var r := roundi(body.size.x * 0.4)
		# Wheels, then the body over them, the glass as two lines across.
		var wheel := Vector2(w * 0.09, h * 0.14)
		for y in [0.17, 0.7]:
			for x in [body.position.x - wheel.x * 0.6, body.end.x - wheel.x * 0.4]:
				draw_rect(Rect2(Vector2(x, body.position.y + body.size.y * y), wheel), c.dim)
		var box := StyleBoxFlat.new()
		box.bg_color = c.bg
		box.border_color = c.dim
		box.set_border_width_all(roundi(line))
		box.set_corner_radius_all(r)
		box.anti_aliasing = true
		draw_style_box(box, body)
		for y in [0.3, 0.74]:
			var at: float = body.position.y + body.size.y * y
			draw_line(Vector2(body.position.x + line, at), Vector2(body.end.x - line, at), c.dim, line, true)
		var fill := StyleBoxFlat.new()
		fill.bg_color = c.warn
		fill.anti_aliasing = true
		if parts.get("hoodOpen", false):
			fill.corner_radius_top_left = r
			fill.corner_radius_top_right = r
			draw_style_box(fill, Rect2(body.position, Vector2(body.size.x, body.size.y * 0.24)))
		if parts.get("trunkOpen", false):
			fill.corner_radius_top_left = 0
			fill.corner_radius_top_right = 0
			fill.corner_radius_bottom_left = r
			fill.corner_radius_bottom_right = r
			draw_style_box(fill, Rect2(body.position + Vector2(0, body.size.y * 0.8), Vector2(body.size.x, body.size.y * 0.2)))
		var driver_left := ThemeManager.hand != "rhd"
		var door := body.size.y * 0.22
		for d in [["doorDriverOpen", driver_left, 0.31], ["doorPassengerOpen", not driver_left, 0.31],
				["doorRearLeftOpen", true, 0.53], ["doorRearRightOpen", false, 0.53]]:
			if parts.get(d[0], false):
				var x: float = body.position.x if d[1] else body.end.x
				var y: float = body.position.y + body.size.y * d[2]
				var out := -1.0 if d[1] else 1.0
				draw_line(Vector2(x, y), Vector2(x + out * door * 0.55, y + door * 0.85), c.warn, line * 1.5, true)
		if parts.get("chargePortOpen", false):
			draw_circle(Vector2(body.end.x, body.position.y + body.size.y * 0.8), line * 1.7, c.accent, true, -1.0, true)
