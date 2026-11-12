class_name EvLive
extends Control
## The "Electric vehicle" page drawn live: a 3D range scene (EvScene) behind the shell's own
## components, with the charge, the range and the charger's distance read from the core and
## labelled where the scene puts them. Works in every theme; when the active pack has an
## `ev_main` screen it supplies the title bar, the strings, the type and the rectangles of the
## title and the tap targets, which the stock UI sets.
##
## The tap targets emit `tile_pressed` and open the EV settings (EvSettings) at their section.

signal tile_pressed(id: String)
## The bar's back button.
signal back_pressed


## The car's range were the climate off; `rangeKm` is the range as it runs.
const RANGE_OFF_PATH := "/telemetry/rangeClimateOffKm"
const TILES := ["next_departure", "scheduled", "v2l"]
## The EV settings' section each tap target opens.
const SETTINGS_SECTIONS := {settings = "charging", next_departure = "schedule", scheduled = "schedule", v2l = "power"}

## English defaults; a pack's screen overrides them where it has the string.
const STRINGS := {
	title = "Electric vehicle", battery = "Battery", on = "Climate on", off = "Climate off", km = "km", m = "m",
	charger = "Charger", next_departure = "Next departure", scheduled = "Scheduled charging",
	v2l = "Electricity use (V2L)", unknown = "–", not_available = "Not available", none_set = "None set",
	today = "Today", tomorrow = "Tomorrow", state_on = "On", state_off = "Off",
	v2x = "V2X", v2l_badge = "V2L",
}
## The pack screen's view for each string, tile and label.
const VIEWS := {
	title = "layout_main_title", battery = "ev_mainview_battery_text", on = "mainview_text_range_climateon",
	off = "mainview_text_range_climateoff", km = "mainview_text_climateon_range_unit",
	next_departure = "mainview_nextDeparture_text", scheduled = "mainview_text_scheduled_charging_climate_text",
	v2l = "mainview_discharging_text",
}
const TILE_VIEWS := {
	next_departure = {box = "mainview_nextDeparture_layout_widget", icon = "mainview_nextDeparture_icon",
		title = "mainview_nextDeparture_text"},
	scheduled = {box = "mainview_scheduled_charging_climate_layout_widget", icon = "mainview_scheduled_charging_icon",
		title = "mainview_text_scheduled_charging_climate_text"},
	v2l = {box = "mainview_v2x_discharging_layout_widget", icon = "mainview_discharging_icon",
		title = "mainview_discharging_text"},
}
const DISPLAY_VIEWS := {battery_value = "mainview_text_battery_percentage_value",
	charger_value = "mainview_text_nearyby_station_range_value", on_value = "mainview_text_climateon_range_value"}
const SETTINGS_VIEW := "mainview_settings_layout_widget"
## Numerals stop growing with the text scale past this: they are already the largest type on
## the page, and the blocks they sit in must fit between the title and the tap targets.
const NUMERAL_SCALE_MAX := 1.2
## Gap from an anchor to its label, in the theme's gaps.
const LABEL_GAP := 1.2
## The picture rises with the control row once it is taller than this many touch targets.
const ROW_LIFT_FROM := 1.9

## How much of the top the shell's own status bar covers; none when the pack draws its own.
var top_inset := 0.0
## The title bar's back button; the shell turns it off while its nav rail is docked.
var back_button := true:
	set(v):
		back_button = v
		if _bar:
			_bar.back_shown = v

var _scene: EvScene
var _spec := {}
var _views := {}
var _title: Label
var _bar: TitleBar
## The controls and labels hidden so the scene shows whole (the bar's eye button).
var ui_hidden := false
var _battery := {}
var _charger := {}
var _on := {}
var _off := {}
var _tiles := {}
var _settings: EvTile
## What is open, the charge port, the 12 V battery, the climate and battery heater; and while
## plugged in, charging.
var _car_status: CarStatus
var _charge_card: ChargeCard
## The EV settings, over the page: the gear opens them, the schedule's tiles at the schedule.
var _ev_settings: EvSettings
var _bound := false
## A look changed while the page was not showing.
var _restyle_due := false
var _row_top := 0.0
var _numeral_base := {}   # label -> its font size before any fitting
var _range_base := {}   # the ranges' other numerals and units -> their font sizes, likewise
var _leader := []   # [the road end, the nearest point of its label]
var _show_on := false
var _show_off := false
var _show_charger := false
## The tap targets' live texts as last set, so a bind rebuilds them only when they change.
var _tile_live := {}


func _init() -> void:
	name = "EvLive"
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	clip_contents = true


func _ready() -> void:
	_scene = EvScene.new()
	_scene.name = "Scene"
	add_child(_scene)
	_scene.moved.connect(_place)
	_bar = TitleBar.new()
	_bar.back_pressed.connect(func(): back_pressed.emit())
	_bar.hide_toggled.connect(set_ui_hidden)
	_bar.back_shown = back_button
	add_child(_bar)
	_title = UI.label("", "strong", "title")
	_title.name = "Title"
	_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_title.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	add_child(_title)
	_battery = _block("Battery", [[_label("battery_name", "body", "caption", "text")],
		[_label("battery_value", "display", "display", "text"), _label("battery_unit", "body", "title", "dim")]])
	for r in _battery.rows:
		(r as HBoxContainer).alignment = BoxContainer.ALIGNMENT_CENTER
	_charger = _block("ChargerLabel", [[_icon("heading", "text"), _label("charger_value", "display", "title", "text"),
		_label("charger_unit", "body", "title", "dim"), _label("charger_name", "body", "body", "dim")]])
	_on = _block("RangeOn", [[_icon("warn", "warn"), _icon("fan"), _label("on_name", "body", "caption", "accent")],
		[_label("on_value", "display", "display", "accent"), _label("on_unit", "body", "title", "accent")]])
	_off = _block("RangeOff", [[_icon("fan", "text"), _label("off_name", "body", "caption", "text")],
		[_label("off_value", "display", "title", "text"), _label("off_unit", "body", "caption", "text")]])
	_car_status = CarStatus.new()
	add_child(_car_status)
	_charge_card = ChargeCard.new()
	add_child(_charge_card)
	for id in TILES:
		var t := EvTile.new()
		t.name = id
		t.id = id
		t.activated.connect(func(i): tile_pressed.emit(i))
		add_child(t)
		_tiles[id] = t
	_settings = EvTile.new()
	_settings.name = "Settings"
	_settings.id = "settings"
	_settings.activated.connect(func(i): tile_pressed.emit(i))
	add_child(_settings)
	for t in _tiles.values() + [_settings]:
		(t as EvTile).activated.connect(_open_settings)
	_ev_settings = EvSettings.new()
	add_child(_ev_settings)
	ThemeManager.changed.connect(_restyle)
	Core.welcome.connect(func(_v): _bind())
	Core.changed.connect(_on_core_changed)
	resized.connect(_layout)
	_restyle()


## The shell keeps the page between visits: it comes back as a new one would, its labels shown,
## the data as it is now (not eased from the last visit) and the look as it is now.
func _notification(what: int) -> void:
	if what == NOTIFICATION_POST_ENTER_TREE and _title != null:
		var restyled := _restyle_due
		if restyled:
			_restyle()
		if ui_hidden:
			set_ui_hidden(false)
		elif not restyled:
			_layout()
			_bind()
	elif what == NOTIFICATION_EXIT_TREE:
		_bound = false
		if _ev_settings:
			_ev_settings.close()


func _open_settings(id: String) -> void:
	_ev_settings.open(SETTINGS_SECTIONS.get(id, "charging"))


## Hides or shows the page's labels and tap targets, leaving the scene and the bar.
func set_ui_hidden(v: bool) -> void:
	ui_hidden = v
	_bar.ui_hidden = v
	if v:
		_apply_hidden()
		return
	for t in _tiles.values():
		(t as Control).visible = true
	_settings.visible = true
	_bind()
	_layout()
	queue_redraw()


func _apply_hidden() -> void:
	for b in [_battery, _charger, _on, _off]:
		(b.box as Control).visible = false
	for t in _tiles.values():
		(t as Control).visible = false
	_settings.visible = false
	_car_status.visible = false
	_charge_card.visible = false
	queue_redraw()


func _process(_delta: float) -> void:
	if ui_hidden:
		_apply_hidden()


## A column of rows of controls laid over the scene: they follow it, so they take no input.
func _block(block_name: String, rows: Array) -> Dictionary:
	# Not a VBoxContainer: a range's label may turn its rows side by side (`_compact`).
	var box := BoxContainer.new()
	box.vertical = true
	box.name = block_name
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.set_meta("gap", 0.0)
	var parts := []
	for r in rows:
		var h := UI.hbox(r, 0.5)
		h.name = "Row%d" % parts.size()
		h.alignment = BoxContainer.ALIGNMENT_BEGIN
		box.add_child(h)
		parts.append(h)
	add_child(box)
	return {box = box, rows = parts}


func _label(label_name: String, font: String, size: String, color: String) -> Label:
	var l := UI.label("", font, size, color)
	l.name = label_name
	return l


func _icon(icon_name: String, color := "accent") -> TextureRect:
	var t := UI.icon(icon_name, "icon", color)
	t.name = icon_name
	return t


func _l(block: Dictionary, label_name: String) -> Label:
	return (block.box as Control).find_child(label_name, true, false)


# ---- the pack's screen ----

## The active pack's `ev_main` screen when it has what the live page lays out from: the title
## and the tap targets. Empty otherwise, and the page then derives its layout from the theme.
static func pack_layout() -> Dictionary:
	var pack := ThemeManager.pack
	if pack == null or not pack.has_screen("ev_main"):
		return {}
	var spec := pack.screen("ev_main")
	var have := {}
	for v in spec.get("views", []):
		have[v.id] = true
	var need := [VIEWS.title, SETTINGS_VIEW]
	for t in TILE_VIEWS.values():
		need.append(t.box)
	for id in need:
		if not have.has(id):
			return {}
	return spec


func _view(id: String) -> Dictionary:
	return _views.get(id, {})


func _str(key: String) -> String:
	var v := _view(VIEWS.get(key, ""))
	return str(v.text.string) if v.has("text") else str(STRINGS[key])


## A pack text view's size in px and color, for a label that takes the pack's type.
func _look(id: String) -> Dictionary:
	var v := _view(id)
	if not v.has("text"):
		return {}
	var t: Dictionary = v.text
	var col: Dictionary = t.get("color", {})
	var look := {size = ceili(float(t.size_px) - 0.5)}
	if col.get(ThemeManager.appearance):
		look.color = Color(col[ThemeManager.appearance])
	return look


func _rect(id: String) -> Rect2:
	var v := _view(id)
	if not v.has("rect"):
		return Rect2()
	var r: Array = v.rect
	var k := _fit_scale()
	return Rect2(Vector2(r[0], r[1]) * k, Vector2(r[2], r[3]) * k)


## The pack's panel-sized layout scaled into this page (narrower beside a docked rail), as the
## scene is (`EvScene.view_rect`).
func _fit_scale() -> float:
	var vp := get_viewport_rect().size
	if size.x <= 0.0 or size.y <= 0.0:
		return 1.0
	return minf(1.0, minf(size.x / vp.x, size.y / vp.y))


# ---- theme ----

func _restyle() -> void:
	if not is_inside_tree():
		_restyle_due = true
		return
	_restyle_due = false
	_spec = pack_layout()
	_views.clear()
	for v in _spec.get("views", []):
		_views[v.id] = v
	UI.restyle(self)
	# Its own restyle may come after this one: lay out with its new size.
	_charge_card._restyle()
	_title.text = _str("title")
	_title.visible = true
	_override(_title, "layout_main_title")
	_l(_battery, "battery_name").text = _str("battery")
	_l(_battery, "battery_unit").text = "%"
	# The pack's size only: its white is for the stock car, and this one is clear in daylight.
	_override(_l(_battery, "battery_name"), "ev_mainview_battery_text", false)
	_override(_l(_battery, "battery_value"), "mainview_text_battery_percentage_value", false)
	_override(_l(_battery, "battery_unit"), "mainview_text_battery_percentage_unit", false)
	# The charge sits over the car's lines: a halo of the page's ground keeps it readable.
	for n in ["battery_name", "battery_value", "battery_unit"]:
		_halo(_l(_battery, n), n == "battery_value")
	_l(_battery, "battery_unit").add_theme_color_override("font_color", ThemeManager.c.text)
	_override(_l(_charger, "charger_value"), "mainview_text_nearyby_station_range_value")
	_override(_l(_charger, "charger_unit"), "mainview_text_nearyby_station_range_unit")
	_override(_l(_charger, "charger_name"), "mainview_text_nearyby_station_location")
	_l(_on, "on_name").text = _str("on")
	_override(_l(_on, "on_name"), "mainview_text_range_climateon")
	_override(_l(_on, "on_value"), "mainview_text_climateon_range_value")
	_override(_l(_on, "on_unit"), "mainview_text_climateon_range_unit")
	# A halo of the page's ground keeps the ranges readable over the scene.
	for n in ["on_name", "on_value", "on_unit"]:
		_halo(_l(_on, n), n == "on_value")
	for n in ["off_name", "off_value", "off_unit"]:
		_halo(_l(_off, n), n == "off_value")
	_l(_off, "off_name").text = _str("off")
	_override(_l(_off, "off_name"), "mainview_text_range_climateoff")
	_override(_l(_off, "off_value"), "mainview_text_climateoff_range_value")
	_override(_l(_off, "off_unit"), "mainview_text_climateoff_range_unit")
	for b in [_on, _off, _charger, _battery]:
		(b.box as Control).visible = false
	_numeral_base.clear()
	var numeral_px := ThemeManager.font_size("display")
	if ThemeManager.text_scale > NUMERAL_SCALE_MAX:
		numeral_px = roundi(numeral_px * NUMERAL_SCALE_MAX / ThemeManager.text_scale)
	for pair in [[_battery, "battery_value"], [_charger, "charger_value"], [_on, "on_value"]]:
		var l := _l(pair[0], pair[1])
		if _look(DISPLAY_VIEWS[pair[1]]).is_empty():
			l.add_theme_font_size_override("font_size", numeral_px)
		_numeral_base[l] = l.get_theme_font_size("font_size")
	_range_base.clear()
	for l in [_l(_on, "on_unit"), _l(_off, "off_value"), _l(_off, "off_unit")]:
		_range_base[l] = l.get_theme_font_size("font_size")
	_set_tiles()
	_layout()
	_bind()
	queue_redraw()


func _halo(l: Label, big: bool) -> void:
	var halo: Color = ThemeManager.c.bg
	halo.a = 0.85
	l.add_theme_color_override("font_outline_color", halo)
	l.add_theme_constant_override("outline_size", roundi(ThemeManager.px.gap * (0.7 if big else 0.45)))


## `c`, or the text colour where `c` is under 4.5:1 on the page's ground (docs/car-ux.md).
static func readable(c: Color) -> Color:
	return c if contrast(c, ThemeManager.c.bg) >= 4.5 else ThemeManager.c.text


## The WCAG contrast ratio of two colours.
static func contrast(a: Color, b: Color) -> float:
	var la := a.srgb_to_linear().get_luminance()
	var lb := b.srgb_to_linear().get_luminance()
	return (maxf(la, lb) + 0.05) / (minf(la, lb) + 0.05)


## Takes a pack view's size and color for a label, when the pack has the view.
func _override(l: Label, id: String, color := true) -> void:
	var look := _look(id)
	if look.has("size"):
		l.add_theme_font_size_override("font_size", look.size)
	if color and look.has("color"):
		l.add_theme_color_override("font_color", look.color)


func _icon_content(view_id: String, fallback: String) -> Dictionary:
	var v := _view(view_id)
	var pack := ThemeManager.pack
	var key := str(v.get("background", ""))
	if key != "" and pack != null and pack.has_image(key):
		var tex := pack.texture(key, ThemeManager.appearance)
		return {texture = tex, size = Vector2(tex.get_size()) if tex else _rect(view_id).size, tint = false}
	return {name = fallback}


## `live`, the car's state, wins over the pack's text and `fallback_text`.
func _item(view_id: String, text_id: String, fallback_icon: String, fallback_text: String, live := "") -> Array:
	var out := []
	if view_id != "":
		var ic := _icon_content(view_id, fallback_icon)
		if ic.has("texture"):
			out.append({texture = ic.texture, size = _rect(view_id).size, tint = false})
		elif fallback_icon != "":
			out.append({icon = fallback_icon})
	var v := _view(text_id)
	out.append({text = live if live != "" else str(v.text.string) if v.has("text") else fallback_text})
	return out


func _set_tiles() -> void:
	var tel = Core.get_value("/telemetry")
	_tile_live = tile_texts(tel if tel is Dictionary else {}, Clock.local())
	var skin := ThemeManager.pack != null and not _spec.is_empty()
	var items := {
		next_departure = _item("", "mainview_nextDeparture_value_soff", "", STRINGS.not_available, _tile_live.departure),
		scheduled = _item("mainview_schedule_charging_icon", "mainview_text_scheduled_charging_mode_status", "plug", STRINGS.unknown, _tile_live.charging)
			+ _item("mainview_schedule_climate_icon", "mainview_text_scheduled_climate_mode_status", "fan", STRINGS.unknown, _tile_live.climate),
		v2l = _badges(),
	}
	# The shell's own tiles say it in words: a plug and a fan beside "Off" read as nothing.
	if not skin:
		var words := [] if _tile_live.charging == "" and _tile_live.climate == "" else \
			["Charge %s" % (_tile_live.charging.to_lower() if _tile_live.charging != "" else STRINGS.unknown),
			"Climate %s" % (_tile_live.climate.to_lower() if _tile_live.climate != "" else STRINGS.unknown)]
		items.scheduled = [{text = " · ".join(words) if not words.is_empty() else STRINGS.not_available}]
		items.v2l = [{text = _tile_live.v2l}] if _tile_live.v2l != "" else []
	var icons := {next_departure = "plug", scheduled = "clock", v2l = "v2l"}
	for id in TILES:
		var t: EvTile = _tiles[id]
		var spec: Dictionary = TILE_VIEWS[id]
		var look := {}
		if skin:
			look = {title = _look(spec.title), item = _look("mainview_nextDeparture_value_soff")}
		t.skin_key = str(_view(spec.box).get("background", "")) if skin else ""
		t.set_content({title = _str(id), icon = _icon_content(spec.icon, icons[id]) if skin else {name = icons[id]},
			items = items[id], look = look})
	_settings.skin_key = str(_view(SETTINGS_VIEW).get("background", "")) if skin else ""
	_settings.set_content({title = "", items = [], icon = {} if _settings.skin_key != "" else {name = "gear"}})


## What the car says for the tap targets: the next departure, scheduled charging and the climate
## at departure; "" where it has not said.
static func tile_texts(t: Dictionary, now_local: float) -> Dictionary:
	var mode = t.get("scheduledChargingMode")
	var climate = t.get("scheduledClimate")
	return {
		departure = next_departure(t, now_local),
		charging = STRINGS.state_off if mode == "off" else STRINGS.state_on if mode in ChargeCard.WAITING_MODES else "",
		climate = STRINGS.state_on if climate == true else STRINGS.state_off if climate == false else "",
		v2l = "Limit %d %%" % roundi(float(t.v2lDischargeLimitPct)) if t.get("v2lDischargeLimitPct") is float or t.get("v2lDischargeLimitPct") is int else "",
	}


## The next time an enabled departure timer comes round, "Today 07:30", "Tomorrow 07:30" or
## "Wed 07:30"; "None set" when the car reports both and neither is on; "" while it has not said.
## A timer on with no days goes once, at its next time.
static func next_departure(t: Dictionary, now_local: float) -> String:
	var now := Time.get_datetime_dict_from_unix_time(int(now_local))
	var mins: int = now.hour * 60 + now.minute
	var today: int = (int(now.weekday) + 6) % 7   # Monday 0, as the car's days
	var best := -1
	var text := ""
	var known := 0
	for k in ["departure1", "departure2"]:
		var d := EvSettings._departure(t.get(k))
		if d.is_empty() or d.on == null:
			continue
		known += 1
		if d.on != true or d.hour == null or d.minute == null:
			continue
		var days: Array = d.days
		var any_day := days.has(true)
		for i in 8:
			var day := (today + i) % 7
			var wait: int = i * 1440 + d.hour * 60 + d.minute - mins
			if wait <= 0 or (any_day and days[day] != true):
				continue
			if best < 0 or wait < best:
				best = wait
				var at := "%02d:%02d" % [d.hour, d.minute]
				text = "%s %s" % [STRINGS.today if i == 0 else STRINGS.tomorrow if i == 1 else EvSettings.DAYS[day], at]
			break
	if text != "":
		return text
	return STRINGS.none_set if known == 2 else ""


func _badges() -> Array:
	var out := []
	for pair in [["mainview_discharge_v2g_label", STRINGS.v2x], ["mainview_discharge_v2l_label", STRINGS.v2l_badge]]:
		var v := _view(pair[0])
		var pack := ThemeManager.pack
		var key := str(v.get("background", ""))
		if key != "" and pack != null and pack.has_image(key):
			out.append({texture = pack.texture(key, ThemeManager.appearance), size = _rect(pair[0]).size, tint = false})
		else:
			out.append({text = pair[1]})
	return out


# ---- data ----

## The sections `_bind` reads. A phone session changes the others (track, route) many times a
## second, and each bind is a layout pass: one per frame, only for these.
const BOUND := ["telemetry", "navigation", "config"]
var _bind_queued := false


func _on_core_changed(sections: PackedStringArray) -> void:
	if _bind_queued:
		return
	for s in sections:
		if s in BOUND:
			_bind_queued = true
			_bind_now.call_deferred()
			return


func _bind_now() -> void:
	_bind_queued = false
	_bind()


func _bind() -> void:
	if _scene == null or _title == null or not is_inside_tree():
		return
	var soc = Core.get_value("/telemetry/fuelPct")
	var km = Core.get_value("/telemetry/rangeKm")
	var off = Core.get_value(RANGE_OFF_PATH)
	var stop = Core.get_value("/navigation/chargingStop")
	# As stock: the climate-on range only while the blower runs, else the climate-off one alone.
	# Lacking that, the car's range alone, under no climate name.
	var blower := CarStatus.blower_running()
	var shown = km if blower or off == null else off
	var range_name := ""
	if blower:
		range_name = _str("on")
	elif off != null:
		range_name = _str("off")
	var on_km := float(shown) if shown != null else 0.0
	var off_km := float(off) if blower and off != null else on_km
	var stop_km := -1.0
	var stop_name := ""
	if stop is Dictionary:
		var d = stop.get("distanceM")
		if d != null:
			stop_km = float(d) / 1000.0
		stop_name = str(stop.get("name", ""))
	_scene.set_state(on_km, off_km, stop_km, float(soc) / 100.0 if soc != null else 0.0, _bound)
	_bound = true
	(_battery.box as Control).visible = true
	_l(_battery, "battery_value").text = "–" if soc == null else str(roundi(float(soc)))
	_show_on = shown != null
	_show_off = blower and off != null
	_l(_on, "on_value").text = str(Units.range_value(on_km))
	_l(_off, "off_value").text = str(Units.range_value(off_km))
	# The pack's unit string is km.
	var unit := _str("km") if not Units.imperial() else Units.range_unit()
	_l(_on, "on_unit").text = unit
	_l(_off, "off_unit").text = unit
	var low := on_km <= EvScene.LOW_RANGE_KM
	_l(_on, "on_name").text = range_name
	_l(_on, "on_name").visible = range_name != ""
	# Low range says so in an icon as well as the warning color; the fan stays, so the name
	# reads as the climate's.
	var warn_icon: TextureRect = (_on.box as Control).find_child("warn", true, false)
	warn_icon.visible = low
	var on_icon: TextureRect = (_on.box as Control).find_child("fan", true, false)
	on_icon.get_meta("icon")[2] = "warn" if low else "accent"
	on_icon.visible = range_name != ""
	UI.style_icon(on_icon)
	# The text keeps to a readable colour; the warning is the icon's and the road's.
	for n in ["on_value", "on_unit", "on_name"]:
		var l := _l(_on, n)
		var look := _look({on_value = "mainview_text_climateon_range_value", on_unit = "mainview_text_climateon_range_unit",
			on_name = "mainview_text_range_climateon"}[n])
		l.add_theme_color_override("font_color", ThemeManager.c.text if low else look.get("color", readable(ThemeManager.c.accent)))
	var t = Core.get_value("/telemetry")
	_car_status.side = -1.0 if ThemeManager.hand == "rhd" else 1.0
	_car_status.show_for(t if t is Dictionary else {})
	# While charging, the block over the car says what "Battery" would.
	_l(_battery, "battery_name").visible = not _charge_card.show_for(t if t is Dictionary else {})
	if tile_texts(t if t is Dictionary else {}, Clock.local()) != _tile_live:
		_set_tiles()
		_layout()
	_show_charger = stop_km >= 0.0
	if _show_charger:
		var d := Units.distance(stop_km)
		_l(_charger, "charger_value").text = d[0]
		_l(_charger, "charger_unit").text = _str("km") if d[1] == "km" else d[1]
		var nm := _l(_charger, "charger_name")
		nm.text = stop_name
		nm.visible = stop_name != ""
	_place()
	if ui_hidden:
		_apply_hidden()


# ---- layout ----

func _layout() -> void:
	# Away, or coming back with the children not yet in the tree (sized there, the title bar
	# would not place its buttons): the visit lays out once they are.
	if _title == null or not _bar.is_inside_tree():
		return
	_ev_settings.offset_top = top_inset
	var px := ThemeManager.px
	var gap: float = px.gap
	var w := size.x
	var h := size.y
	var rects := {}
	if not _spec.is_empty():
		var bar := _rect("_View_3")
		_bar.position = bar.position if bar.size != Vector2.ZERO else Vector2(0, top_inset)
		_bar.size = bar.size if bar.size != Vector2.ZERO else Vector2(w, TitleBar.bar_height())
		_title.position = _rect("layout_main_title").position
		_title.size = _rect("layout_main_title").size
		var tiles: Array[Rect2] = []
		for id in TILES:
			tiles.append(_rect(TILE_VIEWS[id].box))
		var gear := _rect(SETTINGS_VIEW)
		var span := Rect2(tiles[0].position, Vector2.ZERO).expand(tiles[2].end)
		var shift := 0.0
		# Panels move to the driver's side and the reading order stays: the gear to the other
		# edge, the row as a block against it.
		if ThemeManager.hand == "rhd":
			gear.position.x = w - gear.end.x
			shift = w - span.end.x - span.position.x
		for i in TILES.size():
			rects[TILES[i]] = Rect2(tiles[i].position + Vector2(shift, 0), tiles[i].size)
		rects.settings = gear
		_row_top = tiles[0].position.y
		_scene.lift(0.0)
	else:
		var margin := gap * 1.5
		var bar_h := TitleBar.bar_height()
		_bar.position = Vector2(0, top_inset)
		_bar.size = Vector2(w, bar_h)
		var title_h: float = ThemeManager.font_size("title") * 1.25
		_title.position = Vector2(0, top_inset + (bar_h - title_h) / 2.0)
		_title.size = Vector2(w, title_h)
		var row_h: float = ThemeManager.px.touch * 1.3
		var gap_x := maxf(gap * 1.2, ThemeManager.px.touch_gap)
		var rhd := ThemeManager.hand == "rhd"
		var each := 0.0
		# The gear is as tall as the row is wide, and the row's height depends on how much the
		# titles wrap at the width left: iterate until they agree.
		for _i in 4:
			var x0 := margin + (row_h + gap_x if rhd else 0.0)
			var x1 := w - margin - (0.0 if rhd else row_h + gap_x)
			each = (x1 - x0 - gap_x * 2.0) / 3.0
			var need: float = ThemeManager.px.touch * 1.3
			for t in _tiles.values():
				need = maxf(need, (t as EvTile).fit(each))
			var settled := absf(need - row_h) < 0.5
			row_h = need
			if settled:
				break
		_row_top = h - margin - row_h
		_scene.lift(maxf(0.0, row_h - ThemeManager.px.touch * ROW_LIFT_FROM) * 0.6)
		var x0 := margin + (row_h + gap_x if rhd else 0.0)
		for i in TILES.size():
			rects[TILES[i]] = Rect2(x0 + i * (each + gap_x), _row_top, each, row_h)
		rects.settings = Rect2(margin if rhd else w - margin - row_h, _row_top, row_h, row_h)
	for id in rects:
		var t: EvTile = _settings if id == "settings" else _tiles[id]
		var r: Rect2 = rects[id]
		t.position = r.position
		t.size = r.size
	_place()


## Puts the labels where the scene puts what they label, then clear of each other: the
## charge on the car, the charger over its pin, the far range by the end of the road, and the
## near range under the road with a leader tying it on, or above it where the road ends too low
## for the label to fit under it.
func _place() -> void:
	if _scene == null or not _scene.is_inside_tree() or _title == null:
		return
	var gap: float = ThemeManager.px.gap
	var side := -1.0 if ThemeManager.hand == "rhd" else 1.0
	_scene.view_rect = get_global_rect()
	var a := _scene.anchors()
	# Panel pixels to this page's.
	for k in a:
		a[k] -= get_global_rect().position
	var w := size.x
	var edge := gap * 1.5
	var room_bottom := (_row_top if _row_top > 0.0 else size.y) - gap
	var floor_y := _title.position.y + _title.size.y
	var bounds := Rect2(edge, floor_y, w - 2.0 * edge, maxf(room_bottom - floor_y, 1.0))
	# The numerals give way when the blocks would not fit between the title and the targets.
	for l in _range_base:
		l.add_theme_font_size_override("font_size", _range_base[l])
	for b in [_on, _off]:
		_compact(b, false)
	var now := _numeral_base.duplicate()
	for _i in 3:
		for l in now:
			l.add_theme_font_size_override("font_size", now[l])
		var tallest := 0.0
		for b in [_battery, _charger, _on, _off]:
			tallest = maxf(tallest, (b.box as Control).get_combined_minimum_size().y)
		if tallest <= bounds.size.y:
			break
		for l in now:
			now[l] = maxi(8, floori(now[l] * bounds.size.y / tallest))
	for b in [_battery, _charger, _on, _off]:
		var box: Control = b.box
		box.size = box.get_combined_minimum_size()
	# The car's state goes in the title row on the car's side where it fits (beside a docked rail
	# there is no back button there), else under the title, keeping the charge on the car clear of
	# the targets; items go, least important first, until it fits.
	var placed: Array[Rect2] = []
	var bat: Control = _battery.box
	var slot := _status_slot(side, edge, gap)
	var in_row := not _bar.back_shown and _status_in(slot)
	var keep := _car_status.wanted()
	while true:
		placed.clear()
		if in_row:
			placed.append(Rect2(_car_status.position, _car_status.size))
		elif _car_status.keep(keep):
			_car_status.size = _car_status.get_combined_minimum_size()
			_car_status.position = Vector2(edge if side > 0 else w - edge - _car_status.size.x, floor_y + gap * 0.5).round()
			placed.append(Rect2(_car_status.position, _car_status.size))
		bat.position = (a.car as Vector2) - bat.size / 2.0
		if not _spec.is_empty():
			# The car does not move on a pack's screen, so the stock position holds.
			var at := Vector2(_rect("mainview_text_battery_percentage_value").position.x, _rect("ev_mainview_battery_text").position.y)
			bat.position = Vector2(at.x if side > 0 else w - at.x - bat.size.x, at.y)
		_fit_in(bat, bounds)
		for r in placed:
			if Rect2(bat.position, bat.size).intersects(r):
				bat.position.y = r.end.y + gap * 0.5
		if in_row or keep <= 0 or bat.position.y + bat.size.y <= room_bottom:
			break
		# Beside the back button before anything is dropped.
		if keep == _car_status.wanted() and _status_in(slot):
			in_row = true
			continue
		keep -= 1
	placed.append(Rect2(bat.position, bat.size))
	# The ranges and the charging block keep off the road: the car, the road and its end are the
	# page's story.
	var road: PackedVector2Array = _scene.road_polygon()
	for i in road.size():
		road[i] -= get_global_rect().position
	# Where the ranges find no room beside the charging block, it keeps its headline and number
	# only, in the shorter face.
	var base_placed := placed.duplicate()
	var off: Control = _off.box
	var on: Control = _on.box
	for squeeze in 2:
		placed = base_placed.duplicate()
		var card_ok := true
		if _charge_card.visible:
			# Over the car, under the car's state, where "Battery" was: the charge's story stays at
			# the car and the road stays clear. Else beside the charge, else any room off the road.
			_charge_card.stacked = false
			_charge_card.fit(room_bottom - floor_y - gap)
			var most := _charge_card.lines
			var cs := _charge_card.get_combined_minimum_size()
			var top := floor_y + gap
			for r in placed:
				if r.position.y < floor_y + gap * 4.0:
					top = maxf(top, r.end.y + gap * 0.5)
			var cx := bat.position.x + bat.size.x + gap * 2.0 if side > 0 else bat.position.x - gap * 2.0 - cs.x
			var spots := [Vector2(edge if side > 0 else w - edge - cs.x, top), Vector2(cx, floor_y + gap * 0.3)]
			# Short of room: the number in a face with a shorter line, then without the time it is
			# done; failing that (large text, a crowded page) off the labels if not the road, then
			# the headline alone. [shorter face, lines, off the road, reach]
			var tries := [[false, 3, true, w * 0.3], [true, 3, true, w * 0.3], [true, 2, true, INF]] if squeeze == 0 \
				else [[true, 2, true, INF], [true, 2, false, INF], [true, 1, false, INF]]
			var at = null
			for tr in tries:
				_charge_card.stacked = tr[0]
				_charge_card.lines = mini(tr[1], most)
				_charge_card._fill()
				cs = _charge_card.get_combined_minimum_size()
				at = _find_clear(cs, spots, placed, bounds, road if tr[2] else PackedVector2Array(), tr[3])
				if at != null:
					break
			card_ok = at != null
			if at == null:
				at = Vector2(clampf(spots[0].x, bounds.position.x, maxf(bounds.position.x, bounds.end.x - cs.x)),
					clampf(spots[0].y, bounds.position.y, maxf(bounds.position.y, bounds.end.y - cs.y)))
			_charge_card.size = cs
			_charge_card.position = (at as Vector2).round()
			placed.append(Rect2(_charge_card.position, _charge_card.size))
		# The charger: its block over the pin, the pin a third in from the side the road runs from.
		var ch: Control = _charger.box
		ch.visible = _show_charger
		(_charger.rows[0].get_child(0) as TextureRect).flip_h = side < 0
		ch.position = Vector2(a.pin.x - ch.size.x * (0.29 if side > 0 else 0.71), (a.pin as Vector2).y - ch.size.y)
		_fit_in(ch, bounds)
		if _show_charger:
			_clear(ch, placed, bounds)
			placed.append(Rect2(ch.position, ch.size))
		off.visible = _show_off
		on.visible = _show_on
		var off_spots := func(sz: Vector2) -> Array:
			var x: float = a.off.x + gap * LABEL_GAP * side - (sz.x if side < 0 else 0.0)
			var span := _road_span(road, x, x + sz.x)
			return [Vector2(x, maxf((a.off as Vector2).y, span.y) + gap * 0.7),
				Vector2(x, minf((a.off_far as Vector2).y, span.x) - gap - sz.y)]
		var tip := maxf(maxf(a.on.x, a.on_far.x), maxf(a.off.x, a.off_far.x)) if side > 0 \
			else minf(minf(a.on.x, a.on_far.x), minf(a.off.x, a.off_far.x))
		# Against the end it labels: just above it, past it, just under it; else the nearest room,
		# a leader tying it on.
		var on_spots := func(sz: Vector2) -> Array:
			var x: float = a.on.x + gap * LABEL_GAP * side - (sz.x if side > 0 else 0.0)
			var span := _road_span(road, x, x + sz.x)
			return [Vector2(x, minf((a.on_far as Vector2).y, span.x) - gap * 0.7 - sz.y),
				Vector2(tip + gap * LABEL_GAP * side - (0.0 if side > 0 else sz.x),
					((a.on as Vector2).y + (a.on_far as Vector2).y - sz.y) / 2.0),
				Vector2(x, maxf((a.on as Vector2).y, span.y) + gap * 0.7)]
		var ranges := []
		if _show_off:
			ranges.append([_off, off_spots])
		if _show_on:
			ranges.append([_on, on_spots])
		var before := placed.duplicate()
		# The far range first, as it was; where the near one then finds no room, the other way round;
		# where the far one still has none, it goes (the road's paler end still shows it).
		var ranges_ok := true
		for attempt in 2:
			var ok := true
			for r in ranges:
				# Alone, it may go onto the road before it covers another label.
				var fits := _place_range(r[0], r[1], placed, bounds, road, ranges.size() == 1)
				ok = ok and fits
				if not fits and attempt == 1 and r[0] == _off:
					off.visible = false
					continue
				placed.append(Rect2((r[0].box as Control).position, (r[0].box as Control).size))
			ranges_ok = ok
			if ok or ranges.size() < 2 or attempt == 1:
				break
			placed = before.duplicate()
			ranges.reverse()
			for l in _range_base:
				l.add_theme_font_size_override("font_size", _range_base[l])
			var v := _l(_on, "on_value")
			v.add_theme_font_size_override("font_size", now[v])
			for b in [_on, _off]:
				_compact(b, false)
		if (ranges_ok and card_ok) or not _charge_card.visible or squeeze == 1:
			break
		for l in _range_base:
			l.add_theme_font_size_override("font_size", _range_base[l])
		var nv := _l(_on, "on_value")
		nv.add_theme_font_size_override("font_size", now[nv])
		for b2 in [_on, _off]:
			_compact(b2, false)
	var above: bool = on.position.y + on.size.y <= (a.on_far as Vector2).y
	# The leader runs from the road end to the nearest point of the label.
	var end: Vector2 = a.on_far if above else a.on
	var r := Rect2(on.position, on.size)
	_leader = [end, Vector2(clampf(end.x, r.position.x, r.end.x), clampf(end.y, r.position.y, r.end.y))]
	# Placing shows what has data; hidden wins, in the same frame (a frame later it flickers).
	if ui_hidden:
		_apply_hidden()
	queue_redraw()


## The title row's room on the car's side: from the page's edge, or past the back button, to the
## title's text. Empty on a pack's screen, which has its own bar.
func _status_slot(side: float, edge: float, gap: float) -> Rect2:
	if not _spec.is_empty():
		return Rect2()
	var font: Font = _title.get_theme_font("font")
	var text_w := font.get_string_size(_title.text, HORIZONTAL_ALIGNMENT_LEFT, -1, _title.get_theme_font_size("font_size")).x
	var text := Rect2(_title.position.x + (_title.size.x - text_w) / 2.0, _bar.position.y, text_w, _bar.size.y)
	var back := _bar.back_rect()
	back.position += _bar.position
	var row := Rect2(_bar.position, _bar.size)
	if side > 0:
		var x0 := back.end.x + gap if back.has_area() else edge
		return Rect2(x0, row.position.y, text.position.x - gap * 2.0 - x0, row.size.y)
	var x1 := back.position.x - gap if back.has_area() else row.end.x - edge
	return Rect2(text.end.x + gap * 2.0, row.position.y, x1 - text.end.x - gap * 2.0, row.size.y)


## Puts the car's state in `slot`, centred in its height on the car's side, with as many items as
## fit; false (all items kept for elsewhere) when none does.
func _status_in(slot: Rect2) -> bool:
	if slot.size.x <= 0.0:
		return false
	var side := -1.0 if ThemeManager.hand == "rhd" else 1.0
	for k in range(_car_status.wanted(), 0, -1):
		# What is open as a count before the next item goes: the picture says which.
		for terse in [false, true]:
			_car_status.keep(k, terse)
			var m := _car_status.get_combined_minimum_size()
			if m.x <= slot.size.x and m.y <= slot.size.y:
				_car_status.size = m
				var x := slot.position.x if side > 0 else slot.end.x - m.x
				_car_status.position = Vector2(x, slot.position.y + (slot.size.y - m.y) / 2.0).round()
				return true
	_car_status.keep(_car_status.wanted())
	return false


## The road's top and bottom (x, y) between `x0` and `x1`; (INF, -INF) where it is not.
static func _road_span(road: PackedVector2Array, x0: float, x1: float) -> Vector2:
	var strip := PackedVector2Array([Vector2(x0, -1e5), Vector2(x1, -1e5), Vector2(x1, 1e5), Vector2(x0, 1e5)])
	var span := Vector2(INF, -INF)
	for part in Geometry2D.intersect_polygons(strip, road):
		for p in part:
			span = Vector2(minf(span.x, p.y), maxf(span.y, p.y))
	return span


static func _over_road(r: Rect2, road: PackedVector2Array) -> bool:
	var box := PackedVector2Array([r.position, Vector2(r.end.x, r.position.y), r.end, Vector2(r.position.x, r.end.y)])
	return road.size() >= 3 and not Geometry2D.intersect_polygons(box, road).is_empty()


## Inside `bounds`, off the road and clear of the labels placed.
func _free(r: Rect2, placed: Array[Rect2], bounds: Rect2, road: PackedVector2Array) -> bool:
	var g := r.grow(ThemeManager.px.gap * 0.5)
	return bounds.encloses(r) and not placed.any(func(o: Rect2) -> bool: return g.intersects(o)) \
		and not _over_road(g, road)


## The first of `spots` where a label `size` big is free, else the free spot nearest the first
## within `reach`; null when there is none.
func _find_clear(size: Vector2, spots: Array, placed: Array[Rect2], bounds: Rect2,
		road: PackedVector2Array, reach := INF) -> Variant:
	for p in spots:
		if is_finite(p.y) and _free(Rect2(p, size), placed, bounds, road):
			return p
	if reach <= 0.0:
		return null
	var want: Vector2 = spots[0]
	var step: float = ThemeManager.px.gap * 1.5
	var best := Vector2.INF
	var limit := reach * reach
	var y := bounds.position.y
	while y + size.y <= bounds.end.y:
		var x := bounds.position.x
		while x + size.x <= bounds.end.x:
			var p := Vector2(x, y)
			var d := p.distance_squared_to(want)
			if d <= limit and d < best.distance_squared_to(want) and _free(Rect2(p, size), placed, bounds, road):
				best = p
			x += step
		y += step
	return best if best.is_finite() else null


## Puts a range's label where `spots` (its size to candidate positions) finds room, or near the
## first; where none has, its rows go side by side, then its number gives way, to 60 %; then
## anywhere free; then, with `onto_road`, anywhere clear of the labels; else it is left at the first spot, inside
## `bounds`.
func _place_range(block: Dictionary, spots: Callable, placed: Array[Rect2], bounds: Rect2,
		road: PackedVector2Array, onto_road := false) -> bool:
	var box: Control = block.box
	var nums: Array[Label] = []
	for n in box.find_children("*_value", "Label", true, false) + box.find_children("*_unit", "Label", true, false):
		nums.append(n)
	var base := nums.map(func(l: Label) -> int: return l.get_theme_font_size("font_size"))
	var first := Vector2.ZERO
	var levels := [[false, 1.0], [true, 1.0], [false, 0.9], [true, 0.9], [true, 0.8], [true, 0.7], [true, 0.6]]
	var set_level := func(k: int) -> void:
		_compact(block, levels[k][0])
		for i in nums.size():
			nums[i].add_theme_font_size_override("font_size", maxi(8, roundi(base[i] * levels[k][1])))
		box.size = box.get_combined_minimum_size()
	set_level.call(0)
	first = spots.call(box.size)[0]
	# Each of its own spots at every size, in their order; then the room near the first; then
	# anywhere.
	for j in spots.call(box.size).size():
		for k in levels.size():
			set_level.call(k)
			var p: Vector2 = spots.call(box.size)[j]
			if is_finite(p.y) and _free(Rect2(p, box.size), placed, bounds, road):
				box.position = p
				return true
	for reach in [size.x * 0.2, INF]:
		for k in levels.size():
			if reach == INF and k < levels.size() - 1:
				continue
			set_level.call(k)
			var at = _find_clear(box.size, spots.call(box.size), placed, bounds, road, reach)
			if at != null:
				box.position = at
				return true
	# Large text on a crowded page: clear of the other labels, on the road with its halo.
	var over = _find_clear(box.size, spots.call(box.size), placed, bounds, PackedVector2Array()) if onto_road else null
	if over != null:
		box.position = over
		return true
	_compact(block, false)
	for i in nums.size():
		nums[i].add_theme_font_size_override("font_size", base[i])
	box.size = box.get_combined_minimum_size()
	box.position = Vector2(clampf(first.x, bounds.position.x, maxf(bounds.position.x, bounds.end.x - box.size.x)),
		clampf(first.y, bounds.position.y, maxf(bounds.position.y, bounds.end.y - box.size.y)))
	return false


## A label's rows one under the other, or side by side (`on`), the name centred on the number.
func _compact(block: Dictionary, on: bool) -> void:
	var box: BoxContainer = block.box
	box.vertical = not on
	box.add_theme_constant_override("separation", roundi(ThemeManager.px.gap * 0.5) if on else 0)
	(block.rows[0] as Control).size_flags_vertical = Control.SIZE_SHRINK_CENTER if on else Control.SIZE_FILL


## Keeps a label inside `bounds` as far as it can: it may be too big for them, then it stays at
## their top left.
func _fit_in(box: Control, bounds: Rect2) -> void:
	box.position = Vector2(
		clampf(box.position.x, bounds.position.x, maxf(bounds.position.x, bounds.end.x - box.size.x)),
		clampf(box.position.y, bounds.position.y, maxf(bounds.position.y, bounds.end.y - box.size.y)))


## Moves a label off the ones already placed: to the nearest spot beside, above or below one of
## them, or along the row, that is inside `bounds` and clear of them all. Left where it is when
## none is.
func _clear(box: Control, placed: Array[Rect2], bounds: Rect2) -> void:
	var pad: float = ThemeManager.px.gap
	var r := Rect2(box.position, box.size)
	if not placed.any(func(o: Rect2) -> bool: return r.grow(pad * 0.5).intersects(o)):
		return
	# Taller than the room (large text), it stays where it is up and down but may still move
	# along: otherwise no spot encloses it and it sits on the other.
	bounds = bounds.merge(Rect2(bounds.position.x, r.position.y, bounds.size.x, r.size.y))
	var tries: Array[Vector2] = []
	for o in placed:
		tries.append(Vector2(o.end.x + pad, r.position.y))
		tries.append(Vector2(o.position.x - pad - r.size.x, r.position.y))
		tries.append(Vector2(r.position.x, o.position.y - pad - r.size.y))
		tries.append(Vector2(r.position.x, o.end.y + pad))
	# Failing those, any clear spot along the row, nearest first.
	var step := pad * 3.0
	var x := bounds.position.x
	var scan: Array[Vector2] = []
	while x + r.size.x <= bounds.end.x:
		scan.append(Vector2(x, r.position.y))
		x += step
	scan.sort_custom(func(p: Vector2, q: Vector2) -> bool: return absf(p.x - r.position.x) < absf(q.x - r.position.x))
	tries.append_array(scan)
	# The nearest first, so a label stays by what it labels (the near range beside the far one,
	# not over past the charger).
	tries.sort_custom(func(p: Vector2, q: Vector2) -> bool: return p.distance_to(r.position) < q.distance_to(r.position))
	for p in tries:
		var c := Rect2(p, r.size)
		if bounds.encloses(c) and not placed.any(func(o: Rect2) -> bool: return c.grow(pad * 0.5).intersects(o)):
			box.position = p
			return


func _draw() -> void:
	var pack := ThemeManager.pack
	var mode := ThemeManager.appearance
	if not _spec.is_empty() and pack != null:
		# The stock title bar and the bar the tap targets sit on, over the scene.
		var bar: Dictionary = _spec.get("status_bar", {})
		if not bar.is_empty() and pack.has_image(bar.image):
			var h := roundi(float(bar.height_dp) * float(_spec.get("density", 1.0)) * _fit_scale())
			pack.box(bar.image, mode).draw(get_canvas_item(), Rect2(0, 0, size.x, h))
		for id in ["_View_3", "_View_4", "mainview_bottom_layout_widget"]:
			if ui_hidden and id == "mainview_bottom_layout_widget":
				continue
			var key := str(_view(id).get("background", ""))
			if key != "" and pack.has_image(key):
				pack.box(key, mode).draw(get_canvas_item(), _rect(id))
	if _show_on and not _leader.is_empty() and not ui_hidden:
		var p: Vector2 = _leader[0]
		var c: Color = ThemeManager.c.warn if _scene.km_on <= EvScene.LOW_RANGE_KM else ThemeManager.c.accent
		var to: Vector2 = _leader[1]
		if p.distance_to(to) > 8.0:
			draw_line(p, to, c, 2.0, true)
		draw_circle(p, 5.0, c)
