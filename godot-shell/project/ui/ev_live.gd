class_name EvLive
extends Control
## The "Electric vehicle" page drawn live: a 3D range scene (EvScene) behind the shell's own
## components, with the charge, the range and the charger's distance read from the core and
## labelled where the scene puts them. Works in every theme; when the active pack has an
## `ev_main` screen it supplies the title bar, the strings, the type and the rectangles of the
## title and the tap targets, which the stock UI sets.
##
## Nothing in the core backs the tap targets yet, so they only emit `tile_pressed`.

signal tile_pressed(id: String)

## The range with climate off has no field in the telemetry yet. Until it does: this much over
## the range with climate on, about what the EV6 shows.
const RANGE_OFF_FALLBACK := 0.12
const RANGE_OFF_PATH := "/telemetry/rangeClimateOffKm"
const TILES := ["next_departure", "scheduled", "v2l"]

## English defaults; a pack's screen overrides them where it has the string.
const STRINGS := {
	title = "Electric vehicle", battery = "Battery", on = "On", off = "Off", km = "km", m = "m",
	charger = "Charger", next_departure = "Next departure", scheduled = "Scheduled charging",
	v2l = "Electricity use (V2L)", unknown = "–", not_available = "Not available",
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

var _scene: EvScene
var _spec := {}
var _views := {}
var _title: Label
var _battery := {}
var _charger := {}
var _on := {}
var _off := {}
var _tiles := {}
var _settings: EvTile
var _bound := false
var _row_top := 0.0
var _numeral_base := {}   # label -> its font size before any fitting
var _leader := []   # [the road end, the nearest point of its label]
var _show_on := false
var _show_charger := false


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
	_on = _block("RangeOn", [[_icon("fan"), _label("on_name", "body", "caption", "accent")],
		[_label("on_value", "display", "display", "accent"), _label("on_unit", "body", "title", "accent")]])
	_off = _block("RangeOff", [[_icon("fan", "text"), _label("off_name", "body", "caption", "text")],
		[_label("off_value", "display", "title", "text"), _label("off_unit", "body", "caption", "text")]])
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
	ThemeManager.changed.connect(_restyle)
	Core.welcome.connect(func(_v): _bind())
	Core.changed.connect(func(_s): _bind())
	resized.connect(_layout)
	_restyle()


## A column of rows of controls laid over the scene: they follow it, so they take no input.
func _block(block_name: String, rows: Array) -> Dictionary:
	var box := VBoxContainer.new()
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
	return Rect2(r[0], r[1], r[2], r[3])


# ---- theme ----

func _restyle() -> void:
	_spec = pack_layout()
	_views.clear()
	for v in _spec.get("views", []):
		_views[v.id] = v
	UI.restyle(self)
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
	var halo: Color = ThemeManager.c.bg
	halo.a = 0.85
	for n in ["battery_name", "battery_value", "battery_unit"]:
		var l := _l(_battery, n)
		l.add_theme_color_override("font_outline_color", halo)
		l.add_theme_constant_override("outline_size", roundi(ThemeManager.px.gap * (0.7 if n == "battery_value" else 0.45)))
	_l(_battery, "battery_unit").add_theme_color_override("font_color", ThemeManager.c.text)
	_override(_l(_charger, "charger_value"), "mainview_text_nearyby_station_range_value")
	_override(_l(_charger, "charger_unit"), "mainview_text_nearyby_station_range_unit")
	_override(_l(_charger, "charger_name"), "mainview_text_nearyby_station_location")
	_l(_on, "on_name").text = _str("on")
	_override(_l(_on, "on_name"), "mainview_text_range_climateon")
	_override(_l(_on, "on_value"), "mainview_text_climateon_range_value")
	_override(_l(_on, "on_unit"), "mainview_text_climateon_range_unit")
	_l(_on, "on_unit").text = _str("km")
	_l(_off, "off_name").text = _str("off")
	_override(_l(_off, "off_name"), "mainview_text_range_climateoff")
	_override(_l(_off, "off_value"), "mainview_text_climateoff_range_value")
	_override(_l(_off, "off_unit"), "mainview_text_climateoff_range_unit")
	_l(_off, "off_unit").text = _str("km")
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
	_set_tiles()
	_layout()
	_bind()
	queue_redraw()


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


func _item(view_id: String, text_id: String, fallback_icon: String, fallback_text: String) -> Array:
	var out := []
	if view_id != "":
		var ic := _icon_content(view_id, fallback_icon)
		if ic.has("texture"):
			out.append({texture = ic.texture, size = _rect(view_id).size, tint = false})
		elif fallback_icon != "":
			out.append({icon = fallback_icon})
	var v := _view(text_id)
	out.append({text = str(v.text.string) if v.has("text") else fallback_text})
	return out


func _set_tiles() -> void:
	var items := {
		next_departure = _item("", "mainview_nextDeparture_value_soff", "", STRINGS.not_available),
		scheduled = _item("mainview_schedule_charging_icon", "mainview_text_scheduled_charging_mode_status", "plug", STRINGS.unknown)
			+ _item("mainview_schedule_climate_icon", "mainview_text_scheduled_climate_mode_status", "fan", STRINGS.unknown),
		v2l = _badges(),
	}
	var icons := {next_departure = "plug", scheduled = "clock", v2l = "v2l"}
	var skin := ThemeManager.pack != null and not _spec.is_empty()
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

func _bind() -> void:
	if _scene == null or _title == null:
		return
	var soc = Core.get_value("/telemetry/fuelPct")
	var km = Core.get_value("/telemetry/rangeKm")
	var off = Core.get_value(RANGE_OFF_PATH)
	var stop = Core.get_value("/navigation/chargingStop")
	var on_km := float(km) if km != null else 0.0
	var off_km := float(off) if off != null else on_km * (1.0 + RANGE_OFF_FALLBACK)
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
	_show_on = km != null
	_l(_on, "on_value").text = str(roundi(on_km))
	_l(_off, "off_value").text = str(roundi(off_km))
	var low := on_km <= EvScene.LOW_RANGE_KM
	_l(_on, "on_name").text = _str("on")
	# Low range says so in an icon as well as the warning color.
	var on_icon: TextureRect = (_on.box as Control).find_child("fan", true, false)
	on_icon.get_meta("icon")[0] = "warn" if low else "fan"
	on_icon.get_meta("icon")[2] = "warn" if low else "accent"
	UI.style_icon(on_icon)
	var warn: Color = ThemeManager.c.warn
	for n in ["on_value", "on_unit", "on_name"]:
		var l := _l(_on, n)
		if low:
			l.add_theme_color_override("font_color", warn)
		else:
			l.remove_theme_color_override("font_color")
			_override(l, {on_value = "mainview_text_climateon_range_value", on_unit = "mainview_text_climateon_range_unit",
				on_name = "mainview_text_range_climateon"}[n])
	_show_charger = stop_km >= 0.0
	if _show_charger:
		var m := stop_km * 1000.0
		var far := m >= 1000.0
		_l(_charger, "charger_value").text = ("%.1f" % stop_km).trim_suffix(".0") if far else str(roundi(m))
		_l(_charger, "charger_unit").text = _str("km") if far else STRINGS.m
		var nm := _l(_charger, "charger_name")
		nm.text = stop_name
		nm.visible = stop_name != ""
	_place()


# ---- layout ----

func _layout() -> void:
	if _title == null:
		return
	var px := ThemeManager.px
	var gap: float = px.gap
	var w := size.x
	var h := size.y
	var rects := {}
	if not _spec.is_empty():
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
		var title_h: float = ThemeManager.font_size("title") * 1.25
		_title.position = Vector2(0, top_inset + gap * 0.4)
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
	var a := _scene.anchors()
	var w := size.x
	var edge := gap * 1.5
	var room_bottom := (_row_top if _row_top > 0.0 else size.y) - gap
	var floor_y := _title.position.y + _title.size.y
	var bounds := Rect2(edge, floor_y, w - 2.0 * edge, maxf(room_bottom - floor_y, 1.0))
	# The numerals give way when the blocks would not fit between the title and the targets.
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
	var bat: Control = _battery.box
	bat.position = (a.car as Vector2) - bat.size / 2.0
	if not _spec.is_empty():
		# The car does not move on a pack's screen, so the stock position holds.
		var at := Vector2(_rect("mainview_text_battery_percentage_value").position.x, _rect("ev_mainview_battery_text").position.y)
		bat.position = Vector2(at.x if side > 0 else w - at.x - bat.size.x, at.y)
	_fit_in(bat, bounds)
	var placed: Array[Rect2] = [Rect2(bat.position, bat.size)]
	# The charger: its block over the pin, the pin a third in from the side the road runs from.
	var ch: Control = _charger.box
	ch.visible = _show_charger
	(_charger.rows[0].get_child(0) as TextureRect).flip_h = side < 0
	ch.position = Vector2(a.pin.x - ch.size.x * (0.29 if side > 0 else 0.71), (a.pin as Vector2).y - ch.size.y)
	_fit_in(ch, bounds)
	if _show_charger:
		_clear(ch, placed, bounds)
		placed.append(Rect2(ch.position, ch.size))
	var off: Control = _off.box
	off.visible = _show_on
	var off_y: float = (a.off as Vector2).y + gap * 0.7
	if off_y + off.size.y > room_bottom:
		off_y = (a.off_far as Vector2).y - gap - off.size.y
	off.position = Vector2(a.off.x + gap * LABEL_GAP * side - (off.size.x if side < 0 else 0.0), off_y)
	_fit_in(off, bounds)
	if _show_on:
		_clear(off, placed, bounds)
		placed.append(Rect2(off.position, off.size))
	var on: Control = _on.box
	on.visible = _show_on
	var on_y: float = (a.on as Vector2).y + gap * 6.5
	var above: bool = on_y + on.size.y > room_bottom
	if above:
		on_y = (a.on_far as Vector2).y - gap * 1.5 - on.size.y
	on.position = Vector2(a.on.x + gap * LABEL_GAP * side - (on.size.x if side > 0 else 0.0), on_y)
	_fit_in(on, bounds)
	if _show_on:
		_clear(on, placed, bounds)
	# The leader runs from the road end to the nearest point of the label.
	var end: Vector2 = a.on_far if above else a.on
	var r := Rect2(on.position, on.size)
	_leader = [end, Vector2(clampf(end.x, r.position.x, r.end.x), clampf(end.y, r.position.y, r.end.y))]
	queue_redraw()


## Keeps a label inside `bounds` as far as it can: it may be too big for them, then it stays at
## their top left.
func _fit_in(box: Control, bounds: Rect2) -> void:
	box.position = Vector2(
		clampf(box.position.x, bounds.position.x, maxf(bounds.position.x, bounds.end.x - box.size.x)),
		clampf(box.position.y, bounds.position.y, maxf(bounds.position.y, bounds.end.y - box.size.y)))


## Moves a label off the ones already placed: beside, above or below the first it meets, to the
## first spot inside `bounds` that is clear of them all, else the nearest along the row. Left
## where it is when none is.
func _clear(box: Control, placed: Array[Rect2], bounds: Rect2) -> void:
	var pad: float = ThemeManager.px.gap
	var r := Rect2(box.position, box.size)
	if not placed.any(func(o: Rect2) -> bool: return r.grow(pad * 0.5).intersects(o)):
		return
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
			var h := roundi(float(bar.height_dp) * float(_spec.get("density", 1.0)))
			pack.box(bar.image, mode).draw(get_canvas_item(), Rect2(0, 0, size.x, h))
		for id in ["_View_3", "_View_4", "mainview_bottom_layout_widget"]:
			var key := str(_view(id).get("background", ""))
			if key != "" and pack.has_image(key):
				pack.box(key, mode).draw(get_canvas_item(), _rect(id))
	if _show_on and not _leader.is_empty():
		var p: Vector2 = _leader[0]
		var c: Color = ThemeManager.c.warn if _scene.km_on <= EvScene.LOW_RANGE_KM else ThemeManager.c.accent
		var to: Vector2 = _leader[1]
		if p.distance_to(to) > 8.0:
			draw_line(p, to, c, 2.0, true)
		draw_circle(p, 5.0, c)
