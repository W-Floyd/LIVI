class_name ChargeCard
extends Card
## While a cable is plugged in (`chargePlugged`) or the car charges (`charging`, or power
## flowing; not `chargerReady`, the on-board charger's ready, which is set with no plug in too):
## what the charge is doing, the time to full and when that is, the power, AC or DC and the
## limit it charges to; and for AC and DC the car's limit, the range at it and its time
## estimate. A row shows only with what the car reports; the charge port's state is the car's
## (CarStatus).

const NOW := ["Power", "Type", "Target", "When"]
## Scheduled charging modes that hold a plugged-in car until the off-peak window.
const WAITING_MODES := ["prioritize_off_peak", "off_peak_only"]

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
## Power, AC or DC, the limit, and when it is full or starts: caption labels, each only when known.
var _now: HBoxContainer
var _t := {}
## The table's rows at most, for a page short of room (`fit`).
var max_rows := ROWS.size()
## The power, type, limit and time line, while there is room for it (`fit`).
var keep_now := true
var _fit_h := -1.0


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
	_now = UI.hbox([], 1.2)
	_now.name = "Now"
	for n in NOW:
		var l := UI.label("", "body", "caption", "dim")
		l.name = n
		_now.add_child(l)
	_grid = GridContainer.new()
	_grid.name = "Facts"
	_grid.columns = 3
	_grid.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var box := UI.vbox([head, _now, _grid], 0.4)
	box.name = "Box"
	add_child(box)


func _style() -> void:
	var g: float = ThemeManager.px.gap
	_grid.add_theme_constant_override("h_separation", roundi(g * 2.0))
	_grid.add_theme_constant_override("v_separation", 0)
	_fit_h = -1.0
	_fill()


## Shows for `t`, the core's telemetry; false (and hidden) when nothing is plugged in.
func show_for(t: Dictionary) -> bool:
	_t = t
	_fit_h = -1.0
	visible = charging(t) or t.get("chargePlugged") == true
	_fill()
	return visible


## True while the car charges: it says so, or takes power (a DC charge may not set `charging`).
static func charging(t: Dictionary) -> bool:
	var kw = t.get("chargingPowerKw")
	return t.get("charging") == true or ((kw is float or kw is int) and kw > 0.0)


## What a plugged-in car's charge is doing: `charging`; `complete` at its limit; `waiting` for
## off-peak hours under a scheduled charging mode; else `plugged`. The last three are inferred
## from the charge, the limit and the mode: the car does not say why it is not charging.
static func state(t: Dictionary) -> String:
	if charging(t):
		return "charging"
	var soc = t.get("fuelPct")
	var limit = _limit(t)
	if soc != null and limit != null and float(soc) >= float(limit) - 0.5:
		return "complete"
	if t.get("scheduledChargingMode") in WAITING_MODES:
		return "waiting"
	return "plugged"


## The limit for the charger in use: DC's on DC, else AC's.
static func _limit(t: Dictionary) -> Variant:
	return t.get("chargeLimitDcPct") if t.get("chargeType") == "dc" else t.get("chargeLimitAcPct")


## "06:45" for `minutes` from now, in local time.
static func clock_after(minutes: float) -> String:
	var d := Time.get_datetime_dict_from_unix_time(int(Clock.local() + roundf(minutes) * 60.0))
	return "%02d:%02d" % [d.hour, d.minute]


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
	var st := state(_t)
	var on := st == "charging"
	_title.text = {charging = "Charging", complete = "Charged", waiting = "Waiting for off-peak",
		plugged = "Plugged in, not charging" if _t.get("charging") == false else "Plugged in"}[st]
	_icon.get_meta("icon")[0] = {charging = "bolt", complete = "check", waiting = "clock", plugged = "plug"}[st]
	_icon.get_meta("icon")[2] = "accent" if on or st == "complete" else "text"
	UI.style_icon(_icon)
	var full = _t.get("chargeTimeToFullMin")
	var big: Control = _value.get_parent()
	# The car's time to full reads 0 once it stops.
	big.visible = on and full != null and float(full) > 0.0
	if big.visible:
		_value.text = Units.duration_text(float(full))
	var kw = _t.get("chargingPowerKw")
	var type = _t.get("chargeType")
	var limit = _limit(_t)
	var off_peak = _t.get("offPeak")
	var now := {
		Power = "%s kW" % ("%.1f" % float(kw)).trim_suffix(".0") if on and kw != null else "",
		Type = str(type).to_upper() if on and type in ["ac", "dc"] else "",
		Target = "to %d %%" % roundi(float(limit)) if limit != null and st != "complete" else "",
		When = "",
	}
	if big.visible:
		now.When = "full at %s" % clock_after(float(full))
	elif st == "waiting" and off_peak is Dictionary and off_peak.get("startHour") != null:
		var m = off_peak.get("startMinute")
		now.When = "starts %02d:%02d" % [int(off_peak.startHour), int(m) if m != null else 0]
	for n in NOW:
		var l: Label = _now.get_node(n)
		l.text = now[n]
		l.visible = l.text != ""
	_now.visible = keep_now and NOW.any(func(n): return now[n] != "")
	for c in _grid.get_children():
		_grid.remove_child(c)
		c.queue_free()
	var rows := ROWS.filter(func(r): return _t.get(r[1]) != null or _t.get(r[2]) != null).slice(0, max_rows)
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


## Drops table rows, the last first, then the line under the title, until the card is at most
## `h` tall or has nothing left to drop.
func fit(h: float) -> void:
	if h == _fit_h:
		return
	_fit_h = h
	max_rows = ROWS.size()
	keep_now = true
	_fill()
	while get_combined_minimum_size().y > h and max_rows > 0:
		max_rows -= 1
		_fill()
	if get_combined_minimum_size().y > h:
		keep_now = false
		_fill()
