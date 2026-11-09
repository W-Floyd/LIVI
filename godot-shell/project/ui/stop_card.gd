class_name StopCard
extends Card
## The route's next charger, from the core's navigation.chargingStop. Arrival below the
## warning level shows in the warning color and says so in words.

const LOW_ARRIVAL_PCT := 20

var stop := {}:
	set(v):
		stop = v
		_fill()

var _title: Label
var _facts: Array[Label] = []


func _build() -> void:
	_title = UI.label("", "strong", "body")
	_title.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var grid := UI.hbox([], 1.0)
	for name in ["Distance", "Arrive", "Charge"]:
		var v := UI.label("–", "display", "body")
		_facts.append(v)
		var cell := UI.vbox([UI.label(name, "body", "caption", "dim"), v], 0)
		cell.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		grid.add_child(cell)
	add_child(UI.vbox([UI.hbox([UI.icon("bolt", "icon", "accent"), _title], 0.6), grid], 0.6))


func _style() -> void:
	_fill()


func has_content() -> bool:
	return stop.get("powerW", 0) > 0


func _fill() -> void:
	if _title == null:
		return
	var kw := int(stop.get("powerW", 0) / 1000)
	_title.text = "Charger · %d kW" % kw if kw > 0 else "No charging stop"
	var km = stop.get("distanceM")
	_facts[0].text = "%d km" % roundi(km / 1000.0) if km != null else "–"
	var pct = stop.get("arrivalPct")
	_facts[1].text = "%d %%" % roundi(pct) if pct != null else "–"
	var low: bool = pct != null and pct < LOW_ARRIVAL_PCT
	_facts[1].add_theme_color_override("font_color", ThemeManager.c.warn if low else ThemeManager.c.text)
	var s = stop.get("chargeS")
	_facts[2].text = "%d min" % roundi(s / 60.0) if s != null else "–"
