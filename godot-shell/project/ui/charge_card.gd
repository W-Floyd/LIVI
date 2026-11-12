class_name ChargeCard
extends Card
## While a cable is plugged in (`chargePlugged`) or the car charges (`charging`, or power
## flowing; not `chargerReady`, the on-board charger's ready, which is set with no plug in too):
## a block read at a glance, three lines: the state, power and charger ("Charging · 7.2 kW AC"),
## the time to the limit ("1 h 25 min to 90 %") and when that is ("Done at 20:30"). The AC and
## DC limits and estimates are the charging settings'.

## Scheduled charging modes that hold a plugged-in car until the off-peak window.
const WAITING_MODES := ["prioritize_off_peak", "off_peak_only"]

var _icon: TextureRect
var _title: Label
var _value: Label
var _unit: Label
## "Done at 00:29", or when a waiting charge starts.
var _when: Label
var _t := {}
## The line under the number, while there is room for it (`fit`).
var keep_lines := true
## For a page short of room: the number in the body face, whose line is shorter.
var stacked := false:
	set(v):
		stacked = v
		if _value:
			_value.set_meta("look", ["strong" if v else "display", "title", "text"])
			UI.style_label(_value)
var _fit_h := -1.0


func _build() -> void:
	name = "ChargeCard"
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_icon = UI.icon("bolt", "icon", "accent")
	_title = UI.label("", "strong", "body")
	_title.name = "Title"
	var head := UI.hbox([_icon, _title], 0.5)
	head.name = "Head"
	_value = UI.label("", "display", "title")
	_value.name = "ToFull"
	_unit = UI.label("", "body", "body", "dim")
	_unit.name = "ToFullUnit"
	var big := UI.hbox([_value, _unit], 0.4)
	big.name = "Big"
	_when = UI.label("", "body", "caption", "text")
	_when.name = "When"
	var box := UI.vbox([head, big, _when], 0)
	box.name = "Box"
	add_child(box)


func _style() -> void:
	# Tighter top and bottom than a card's: it shares the room above the road with the scene.
	var box := get_theme_stylebox("panel")
	if box:
		box = box.duplicate()
		box.content_margin_top = ThemeManager.px.gap * 0.1
		box.content_margin_bottom = ThemeManager.px.gap * 0.1
		add_theme_stylebox_override("panel", box)
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


func _fill() -> void:
	if _title == null or not visible:
		return
	var st := state(_t)
	var on := st == "charging"
	var title: String = {charging = "Charging", complete = "Charged", waiting = "Waiting for off-peak",
		plugged = "Plugged in, not charging" if _t.get("charging") == false else "Plugged in"}[st]
	var kw = _t.get("chargingPowerKw")
	var type = _t.get("chargeType")
	var how := []
	if on and (kw is float or kw is int) and kw > 0.0:
		how.append("%s kW" % ("%.1f" % float(kw)).trim_suffix(".0"))
	if on and type in ["ac", "dc"]:
		how.append(str(type).to_upper())
	_title.text = title + (" · " + " ".join(how) if not how.is_empty() else "")
	_icon.get_meta("icon")[0] = {charging = "bolt", complete = "check", waiting = "clock", plugged = "plug"}[st]
	_icon.get_meta("icon")[2] = "accent" if on or st == "complete" else "text"
	UI.style_icon(_icon)
	# Taken as the time to the charge limit, as stock shows it beside the limit; unverified (the
	# one charge seen went to 100 %).
	var full = _t.get("chargeTimeToFullMin")
	var limit = _limit(_t)
	var big: Control = _value.get_parent()
	# The car's time to full reads 0 once it stops.
	big.visible = on and full != null and float(full) > 0.0
	if big.visible:
		_value.text = Units.duration_text(float(full))
		_unit.text = "to %d %%" % roundi(float(limit)) if limit != null else "to full"
	var off_peak = _t.get("offPeak")
	_when.text = ""
	if big.visible:
		_when.text = "Done at %s" % clock_after(float(full))
	elif st == "waiting" and off_peak is Dictionary and off_peak.get("startHour") != null:
		var m = off_peak.get("startMinute")
		_when.text = "Starts at %02d:%02d" % [int(off_peak.startHour), int(m) if m != null else 0]
	_when.visible = keep_lines and _when.text != ""


## Drops the line under the number when the card would be taller than `h`.
func fit(h: float) -> void:
	if h == _fit_h:
		return
	_fit_h = h
	keep_lines = true
	_fill()
	if get_combined_minimum_size().y > h:
		keep_lines = false
		_fill()
