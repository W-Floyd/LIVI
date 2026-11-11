class_name PackScreen
extends Control
## A page built from a vendor pack's screen: every view at its rectangle in panel pixels,
## with the pack's images and its text in the pack's fonts. Dedicated rather than made of the
## shell's components; what the shell has data for is bound to the core, the rest stays at the
## pack's static values.

var screen_name := "ev_main"

var _nodes := {}          # view id -> Control
var _static := {}         # view id -> its text as the pack has it
var _battery_key := ""    # the battery badge's image key with the step number left open


func _init() -> void:
	name = "Screen"
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE


func _ready() -> void:
	ThemeManager.changed.connect(_build)
	Core.welcome.connect(func(_v): _bind())
	Core.changed.connect(_on_core_changed)
	_build()
	var page := get_parent_control()
	if page:
		page.resized.connect(_fit)
		_fit()


## The screen is laid out for the whole panel: beside a docked rail it is scaled down to the
## page's width, its top left kept.
func _fit() -> void:
	var full := get_viewport_rect().size
	var room := get_parent_control().size
	if room.x <= 0.0 or room.y <= 0.0:
		return
	var s := minf(1.0, minf(room.x / full.x, room.y / full.y))
	if s >= 1.0:
		if scale != Vector2.ONE:
			scale = Vector2.ONE
			set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		return
	set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
	position = Vector2.ZERO
	size = full
	scale = Vector2(s, s)


func _build() -> void:
	for n in get_children():
		remove_child(n)
		n.free()
	_nodes.clear()
	_static.clear()
	var pack := ThemeManager.pack
	if pack == null or not pack.has_screen(screen_name):
		return
	var spec := pack.screen(screen_name)
	var mode := ThemeManager.appearance
	var bg := ColorRect.new()
	bg.name = "Backdrop"
	bg.color = Color.BLACK
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(bg)
	var bar: Dictionary = spec.get("status_bar", {})
	if not bar.is_empty():
		var h := roundi(float(bar.height_dp) * float(spec.get("density", 1.0)))
		var sb := _image_view(bar.image)
		sb.name = "StatusBar"
		sb.size = Vector2(size.x, h)
		_add(sb)
	for v in spec.views:
		var n := _view(v, mode)
		if n:
			_add(n)
			_nodes[v.id] = n
	_battery_key = ""
	var badge: Dictionary = _find(spec, "mainview_energyinformation_battery_image")
	if badge.get("background"):
		_battery_key = str(badge.background).rsplit("_", true, 1)[0] + "_%02d"
	_bind()


func _find(spec: Dictionary, id: String) -> Dictionary:
	for v in spec.views:
		if v.id == id:
			return v
	return {}


func _add(n: Control) -> void:
	n.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(n)


## Views that draw nothing are left out: layout containers only place others.
func _view(v: Dictionary, mode: String) -> Control:
	var r: Array = v.rect
	var rect := Rect2(r[0], r[1], r[2], r[3])
	if rect.size.x <= 0 or rect.size.y <= 0:
		return null
	var n: Control
	if v.has("text"):
		n = _text_view(v, mode)
	elif v.get("src"):
		var p: Array = v.get("padding", [0, 0, 0, 0])
		rect = Rect2(rect.position + Vector2(p[0], p[1]), rect.size - Vector2(p[0] + p[2], p[1] + p[3]))
		n = _image_view(v.src, v.get("scale_type", "fitCenter"))
	elif v.get("background") is String:
		n = _image_view(v.background)
	elif v.get("background") is Dictionary:
		var c: String = v.background.get("color", {}).get(mode, "")
		if c == "":
			return null
		var fill := ColorRect.new()
		fill.color = Color(c)
		n = fill
	else:
		return null
	n.name = v.id
	n.position = rect.position
	n.size = rect.size
	n.visible = v.get("visibility") != "invisible"
	return n


## An image at the view's rectangle: stretched or 9-patched as a background, or fitted as a
## source image.
func _image_view(key: String, fit := "") -> Control:
	var pack := ThemeManager.pack
	var mode := ThemeManager.appearance
	if fit == "":
		var p := Panel.new()
		p.add_theme_stylebox_override("panel", pack.box(key, mode) if pack.has_image(key) else StyleBoxEmpty.new())
		return p
	var t := TextureRect.new()
	t.texture = pack.texture(key, mode)
	t.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	t.stretch_mode = {
		fitXY = TextureRect.STRETCH_SCALE, center = TextureRect.STRETCH_KEEP_CENTERED,
		centerCrop = TextureRect.STRETCH_KEEP_ASPECT_COVERED,
	}.get(fit, TextureRect.STRETCH_KEEP_ASPECT_CENTERED)
	t.clip_contents = true
	return t


func _text_view(v: Dictionary, mode: String) -> PackText:
	var t: Dictionary = v.text
	var l := PackText.new()
	l.text = str(t.string)
	_static[v.id] = l.text
	l.font = ThemeManager.fonts.strong if t.font == "bold" else ThemeManager.fonts.body
	l.font_size = ceili(float(t.size_px) - 0.5)
	var col: Dictionary = t.get("color", {})
	l.color = Color(col[mode]) if col.get(mode) else (Color.WHITE if mode == "night" else Color.BLACK)
	var g: Array = t.get("gravity", [])
	# The importer's reading of the flags, which the reference follows: right, else centered.
	l.h_align = HORIZONTAL_ALIGNMENT_RIGHT if "right" in g \
		else HORIZONTAL_ALIGNMENT_CENTER if "center_horizontal" in g else HORIZONTAL_ALIGNMENT_LEFT
	l.v_align = VERTICAL_ALIGNMENT_BOTTOM if "bottom" in g \
		else VERTICAL_ALIGNMENT_CENTER if "center_vertical" in g else VERTICAL_ALIGNMENT_TOP
	l.max_lines = int(t.get("max_lines", 0))
	var one: bool = t.get("single_line", false) or l.max_lines == 1
	l.ellipsis = one or l.max_lines > 1
	l.wrap = not one
	if t.has("line_mult"):
		l.line_spacing = (float(t.line_mult) - 1.0) * l.font.get_height(l.font_size)
	var sh: Dictionary = t.get("shadow", {})
	if sh.get("color", {}).get(mode):
		l.shadow_color = Color(sh.color[mode])
		l.shadow_offset = Vector2(sh.dx, sh.dy)
		l.shadow_radius = float(sh.radius)
	l.padding = v.get("padding", [0, 0, 0, 0])
	if v.get("background") is String and ThemeManager.pack.has_image(v.background):
		l.background = ThemeManager.pack.box(v.background, mode)
	return l


## Battery, range and the next charger come from the core; a value the core lacks stays as
## the pack has it.
## One bind a frame, and only for what it reads: a phone session changes the track and the route
## many times a second.
var _bind_queued := false


func _on_core_changed(sections: PackedStringArray) -> void:
	if _bind_queued:
		return
	for s in sections:
		if s == "telemetry" or s == "navigation" or s == "config":
			_bind_queued = true
			_bind_now.call_deferred()
			return


func _bind_now() -> void:
	_bind_queued = false
	_bind()


func _bind() -> void:
	if _nodes.is_empty():
		return
	for id in _static:
		_set_text(id, _static[id])
	var soc = Core.get_value("/telemetry/fuelPct")
	if soc != null:
		_set_text("mainview_text_battery_percentage_value", str(roundi(soc)))
		var badge = _nodes.get("mainview_energyinformation_battery_image")
		var key := _battery_key % clampi(roundi(soc / 5.0), 0, 20) if _battery_key != "" else ""
		if badge and ThemeManager.pack.has_image(key):
			(badge as Panel).add_theme_stylebox_override("panel", ThemeManager.pack.box(key, ThemeManager.appearance))
	var km = Core.get_value("/telemetry/rangeKm")
	if km != null:
		_set_text("mainview_text_climateon_range_value", str(Units.range_value(km)))
		if Units.imperial():
			_set_text("mainview_text_climateon_range_unit", Units.range_unit())
	var stop = Core.get_value("/navigation/chargingStop")
	if stop is Dictionary:
		var m = stop.get("distanceM")
		if m != null:
			var d := Units.distance(m / 1000.0)
			_set_text("mainview_text_nearyby_station_range_value", d[0])
			_set_text("mainview_text_nearyby_station_range_unit", d[1])
		if stop.get("name"):
			_set_text("mainview_text_nearyby_station_location", str(stop.name))


func _set_text(id: String, text: String) -> void:
	var l = _nodes.get(id)
	if l is PackText:
		l.text = text
