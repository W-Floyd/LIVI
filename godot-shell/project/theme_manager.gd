extends Node
## Resolves the theme, the rule table, the panel's density and the driver's choices into what
## every component reads: colors (`c`), sizes in panel pixels (`px`), fonts, and a Godot Theme.
## Emits `changed` after any change; components restyle themselves then.

signal changed

## The G5W's center panel. Sizes in a theme are physical; this turns them into pixels.
const PANEL := {w = 1920, h = 720, diag_in = 12.3}
## Cap height over font size for the faces in use.
const CAP_RATIO := 0.7

var theme_name := "instrument"
var appearance := "day"        # day | night
var appearance_mode := "auto"  # auto | day | night: auto follows the core's mainUiNightMode
var hand := "lhd"              # lhd | rhd
var near := "projection"       # what sits nearer the driver: projection | panel
var text_scale := 1.0
var material := "solid"        # solid | frosted | glass: surfaces floating over the map
var reduced_motion := false    # no animated transitions or camera moves
var car := "auto"             # auto | procedural: the EV page's car, a model when one is installed
var quality := "normal"        # normal | low: what the 3D pages may spend (PLAN.md, "Quality profiles")
var home_phone := true         # whether home shows the phone's picture beside its cards
var home_split := 0.0          # the phone's share of home's width, snapped (Shell._snaps); 0: a half
var status_position := "top"   # top | bottom | left | right: the panel edge the status bar runs along; off: none
var volume_style := "card"    # card | glow: the volume overlay, a card with the level, or a line along the bottom
var ev_page := "auto"          # auto | image | live: which "Electric vehicle" page `ev` opens
var app_scale := 0             # launched apps' scale in percent; 0: the panel's (Launcher.auto_scale)
var app_scales := {}           # app id -> percent, over apps.yaml's `scale` and app_scale

## The driver's choices that `save_look` keeps; `look_file` is where ("" keeps nothing: tests).
const SAVED := ["theme_name", "appearance_mode", "hand", "near", "text_scale", "material", "reduced_motion", "quality", "ev_page", "volume_style", "home_phone", "home_split", "status_position", "app_scale", "app_scales"]
var look_file := ""
## The resolved look for apps the shell hosts, rewritten on every change (`write_tokens`); "" writes
## none. Beside `look_file`.
var tokens_file := ""
var _tokens_written := ""

## Godot's button states as the state maps of a pack's selectors name them.
const BUTTON_STATES := {
	normal = {}, hover = {hovered = true}, pressed = {pressed = true, checked = true},
	hover_pressed = {hovered = true, pressed = true, checked = true}, disabled = {enabled = false}}

const SURFACE_SHADER := preload("res://ui/surface.gdshader")

## Where vendor packs live, one folder per pack, next to the built-in `res://themes/`.
var packs_dir := default_packs_dir()
var pack: ThemePack            # the theme's pack; null for a built-in theme

var rules: Dictionary
var spec: Dictionary
var c: Dictionary              # color token -> Color
var series: Array[Color] = []
var px: Dictionary             # size token -> panel pixels
var fonts: Dictionary          # display | body | strong -> Font
var godot_theme := Theme.new()
var px_per_mm: float

var _font_files := {}
var _fonts_dir := "res://fonts"


func _ready() -> void:
	rules = _yaml("res://rules.yaml")
	var diag := sqrt(PANEL.w * PANEL.w + PANEL.h * PANEL.h)
	px_per_mm = PANEL.w / (PANEL.diag_in * 25.4 * PANEL.w / diag)
	apply()


## Changes any of the look's settings, and re-resolves once. `appearance_mode` also sets the
## appearance: its own, or the core's night mode for auto.
func set_look(look: Dictionary) -> void:
	for k in look:
		# JSON has only floats.
		set(k, float(look[k]) if k in ["text_scale", "home_split"] else int(look[k]) if k == "app_scale" else look[k])
	if look.has("appearance_mode"):
		var n = Core.get_value("/config/mainUiNightMode") if appearance_mode == "auto" else null
		if appearance_mode != "auto":
			appearance = appearance_mode
		elif n != null:
			appearance = "night" if n else "day"
	apply()


## `$XDG_CONFIG_HOME/livi-shell/look.json`, else under `~/.config`.
static func default_look_file() -> String:
	var d := OS.get_environment("XDG_CONFIG_HOME")
	if d == "":
		d = OS.get_environment("HOME").path_join(".config")
	return d.path_join("livi-shell/look.json")


## Takes the saved look from `file`, which later changes are saved to. A theme that has gone
## (a pack removed) is skipped.
func load_look(file: String) -> void:
	look_file = file
	tokens_file = file.get_base_dir().path_join("tokens.json")
	write_tokens()
	var saved = JSON.parse_string(FileAccess.get_file_as_string(file)) if FileAccess.file_exists(file) else null
	if not saved is Dictionary:
		return
	var look := {}
	for k in SAVED:
		if saved.has(k) and not (k == "theme_name" and not has_theme(str(saved[k]))):
			look[k] = saved[k]
	set_look(look)


func save_look() -> void:
	if look_file == "":
		return
	DirAccess.make_dir_recursive_absolute(look_file.get_base_dir())
	var look := {}
	for k in SAVED:
		look[k] = get(k)
	var f := FileAccess.open(look_file, FileAccess.WRITE)
	if f == null:
		push_error("look: cannot write %s" % look_file)
		return
	f.store_string(JSON.stringify(look, "  "))


## Built-in themes, then the packs installed, by name.
func theme_names() -> PackedStringArray:
	var out := PackedStringArray()
	for f in DirAccess.get_files_at("res://themes"):
		if f.ends_with(".yaml"):
			out.append(f.get_basename())
	for d in DirAccess.get_directories_at(packs_dir) if DirAccess.dir_exists_absolute(packs_dir) else PackedStringArray():
		if not out.has(d) and FileAccess.file_exists(packs_dir.path_join(d).path_join("theme.yaml")):
			out.append(d)
	return out


## `$LIVI_SHELL_THEMES`, else the user's data folder.
static func default_packs_dir() -> String:
	var d := OS.get_environment("LIVI_SHELL_THEMES")
	if d != "":
		return d
	var home := OS.get_environment("HOME")
	return home.path_join(".local/share/livi-shell/themes")


## True when a built-in theme or a pack of that name exists.
func has_theme(name: String) -> bool:
	return _spec_path(name) != ""


## Built-in themes win over a pack of the same name. "" when there is none.
func _spec_path(name: String) -> String:
	if name == "" or name.contains("/") or name.contains(".."):
		return ""
	var built_in := "res://themes/%s.yaml" % name
	if FileAccess.file_exists(built_in):
		return built_in
	var p := packs_dir.path_join(name).path_join("theme.yaml")
	return p if FileAccess.file_exists(p) else ""


func defaults() -> void:
	# Scenarios and the live tuner get a fixed look: the core's night (a fake core's default) does
	# not repaint them. A theme step with appearance_mode "auto" opts back in.
	appearance_mode = "day"
	set_look({theme_name = "instrument", appearance = "day", hand = "lhd", near = "projection", text_scale = 1.0, material = "solid", reduced_motion = false, quality = "normal", car = "procedural", ev_page = "auto", volume_style = "card", home_phone = true, home_split = 0.0, status_position = "top", app_scale = 0, app_scales = {}})


## The "Electric vehicle" page `ev` stands for: the look's choice, else the theme's own
## (`ev_page:` in theme.yaml), else the pack's image page when the pack has one, else the live one.
func ev_page_kind() -> String:
	var want := ev_page if ev_page != "auto" else str(spec.get("ev_page", "auto"))
	if want == "image" or want == "live":
		return want
	return "image" if pack != null and pack.has_screen("ev_main") else "live"


## Surfaces float over the map, which then runs full-bleed beneath them.
func floating() -> bool:
	return material != "solid" and not is_scene()


## A scene theme draws its surfaces in 3D; the 2D layer keeps only text, icons and hit areas.
func is_scene() -> bool:
	return spec.has("scene")


## The frosted or glass look for one surface of `size`; null for solid.
func surface_material(size: Vector2) -> ShaderMaterial:
	if material == "solid" or is_scene():
		return null
	var m := ShaderMaterial.new()
	m.shader = SURFACE_SHADER
	var glass := material == "glass"
	var t: Color = c.surface
	t.a = 0.42 if glass else 0.66
	m.set_shader_parameter("tint", t)
	m.set_shader_parameter("blur_px", px.gap * (2.5 if glass else 4.0))
	m.set_shader_parameter("saturation", 1.8 if glass else 1.35)
	m.set_shader_parameter("refraction_px", px.gap * 2.0 if glass else 0.0)
	m.set_shader_parameter("highlight", (0.35 if appearance == "night" else 0.55) if glass else 0.0)
	m.set_shader_parameter("brightness", 0.92 if glass else 0.96)
	m.set_shader_parameter("edge_px", px.gap * (0.7 if glass else 0.45))
	m.set_shader_parameter("edge_brightness", 1.25 if glass else 1.1)
	m.set_shader_parameter("rect_size", size)
	m.set_shader_parameter("radius_px", px.radius)
	return m


## True when the side panel goes on the left: the drive side and the "nearer" choice each flip it.
func side_left() -> bool:
	return (hand == "rhd") != (near == "panel")


func apply() -> void:
	var path := _spec_path(theme_name)
	spec = _yaml(path) if path != "" else {}
	if spec.is_empty():
		push_error("theme %s not found" % theme_name)
		return
	if path.begins_with("res://"):
		pack = null
		_fonts_dir = "res://fonts"
	else:
		var dir := path.get_base_dir()
		if pack == null or pack.dir != dir:
			pack = ThemePack.new(dir, spec)
		_fonts_dir = dir.path_join("fonts")
	c.clear()
	var pal: Dictionary = spec.colors[appearance]
	for k in pal:
		c[k] = Color(pal[k])
	series.clear()
	for s in spec.series[appearance]:
		series.append(Color(s))

	var shape: Dictionary = spec.shape
	var s := text_scale
	var cap_mm: float = 2.0 * rules.view_mm * tan(deg_to_rad(rules.char_arcmin / 60.0) / 2.0)
	var min_font := cap_mm * px_per_mm / CAP_RATIO
	px = {
		caption = min_font * s,
		body = min_font * 1.15 * s,
		title = min_font * 1.4 * s,
		display = min_font * float(shape.display_ratio) * s,
		touch = rules.touch_mm * px_per_mm,
		touch_gap = rules.touch_gap_mm * px_per_mm,
		gap = shape.gap_mm * px_per_mm,
		radius = shape.radius_mm * px_per_mm,
		icon = max(min_font * 1.1 * s, 4.0 * px_per_mm),
		status = max(min_font * 1.7 * s, 7.0 * px_per_mm),
		side = 680.0,
		min_font = min_font,
	}
	for role in ["display", "body", "strong"]:
		fonts[role] = _font(spec.fonts[role])
	_build_theme()
	write_tokens()
	changed.emit()


## The contract with hosted apps (godot-maps reads it), so they need not know theme files:
## `version`; the look's `theme_name`, `appearance` (day | night, resolved), `hand`, `near`,
## `text_scale`, `material`, `reduced_motion`, `quality`; `colors` (token -> "#rrggbb[aa]"),
## `series`, `px` (size token -> panel pixels), and `fonts` (display | body | strong ->
## {weight, path}: path only when the font is a file on disk).
func write_tokens() -> void:
	if tokens_file == "" or spec.is_empty():
		return
	var colors := {}
	for k in c:
		colors[k] = "#" + c[k].to_html(c[k].a < 1.0)
	var font_files := {}
	for role in ["display", "body", "strong"]:
		var font: Dictionary = spec.fonts[role]
		var path := _fonts_dir.path_join(font.file)
		if path.begins_with("res://"):
			path = ProjectSettings.globalize_path(path)
		var entry := {}
		if font.has("weight"):
			entry.weight = int(font.weight)
		if FileAccess.file_exists(path):
			entry.path = path
		font_files[role] = entry
	var sizes := {}
	for k in px:
		sizes[k] = snappedf(px[k], 0.01)
	var tokens := {version = 1, theme_name = theme_name, appearance = appearance, hand = hand, near = near,
		text_scale = text_scale, material = material, reduced_motion = reduced_motion, quality = quality,
		colors = colors, series = series.map(func(s: Color) -> String: return "#" + s.to_html(false)),
		px = sizes, fonts = font_files}
	var text := JSON.stringify(tokens, "  ")
	if text == _tokens_written:
		return
	DirAccess.make_dir_recursive_absolute(tokens_file.get_base_dir())
	# Through a rename: an app polling it never reads half a file.
	var tmp := tokens_file + ".tmp"
	var f := FileAccess.open(tmp, FileAccess.WRITE)
	if f == null:
		push_error("look: cannot write %s" % tmp)
		return
	f.store_string(text)
	f.close()
	DirAccess.rename_absolute(tmp, tokens_file)
	_tokens_written = text


func font_size(role: String) -> int:
	return roundi(px[role])


func _build_theme() -> void:
	var t := Theme.new()
	t.default_font = fonts.body
	t.default_font_size = font_size("body")
	t.set_color("font_color", "Label", c.text)
	for state in ["normal", "hover", "pressed", "disabled", "focus", "hover_pressed"]:
		t.set_stylebox(state, "Button", _box(c.surface2, c.line))
	t.set_stylebox("pressed", "Button", _box(c.accent, c.accent))
	t.set_stylebox("hover_pressed", "Button", _box(c.accent, c.accent))
	t.set_stylebox("focus", "Button", StyleBoxEmpty.new())
	# A pack's image states replace the drawn boxes; the focus ring stays empty.
	for state in ["normal", "hover", "pressed", "hover_pressed", "disabled"]:
		var skinned := skin("button", BUTTON_STATES[state], px.gap * 1.2, 0.0)
		if skinned:
			t.set_stylebox(state, "Button", skinned)
	for k in ["font_color", "font_hover_color", "font_focus_color"]:
		t.set_color(k, "Button", c.text)
	for k in ["font_pressed_color", "font_hover_pressed_color"]:
		t.set_color(k, "Button", c.on_accent)
	for k in ["icon_normal_color", "icon_hover_color", "icon_focus_color"]:
		t.set_color(k, "Button", c.text)
	for k in ["icon_pressed_color", "icon_hover_pressed_color"]:
		t.set_color(k, "Button", c.on_accent)
	t.set_font("font", "Button", fonts.strong)
	t.set_font_size("font_size", "Button", font_size("body"))
	t.set_constant("h_separation", "Button", roundi(px.gap))
	godot_theme = t


## A button or control surface: fill, a hairline in the theme's border style, its radius.
func _box(fill: Color, border: Color) -> StyleBoxFlat:
	var b := StyleBoxFlat.new()
	b.bg_color = fill
	b.set_corner_radius_all(roundi(px.radius))
	b.set_border_width_all(2)
	b.border_color = border
	b.content_margin_left = px.gap * 1.2
	b.content_margin_right = px.gap * 1.2
	b.content_margin_top = 0
	b.content_margin_bottom = 0
	b.anti_aliasing = true
	return b


## An image skin for `role` (a key in the theme's `skins`) in the state a Godot control is
## in, as a StyleBoxTexture whose content margins are at least `min_x` and `min_y`, so the
## component's own padding stands. Null when the theme has no skin for it, or when surfaces
## are frosted or drawn in 3D, which a bitmap cannot be.
func skin(role: String, state := {}, min_x := 0.0, min_y := 0.0) -> StyleBoxTexture:
	if pack == null or material != "solid" or is_scene():
		return null
	var key = spec.get("skins", {}).get(role)
	var b := pack.box(str(key), appearance, state) if key else null
	if b:
		for side in [SIDE_LEFT, SIDE_RIGHT]:
			b.set_content_margin(side, maxf(b.get_content_margin(side), min_x))
		for side in [SIDE_TOP, SIDE_BOTTOM]:
			b.set_content_margin(side, maxf(b.get_content_margin(side), min_y))
	return b


## The card style a theme asks for: flat (hairline), soft (shadow) or edge (accent edge). Over
## the map (frosted, glass) it is only the shape the surface shader fills; in a scene theme the
## 3D skin draws the surface and the box is empty.
func card_box() -> StyleBox:
	var sk := skin("card", {}, px.gap * 1.2, px.gap * 1.2)
	if sk:
		return sk
	var b := StyleBoxFlat.new()
	b.bg_color = c.surface
	b.set_corner_radius_all(roundi(px.radius))
	b.set_content_margin_all(px.gap * 1.2)
	b.anti_aliasing = true
	if is_scene():
		b.bg_color = Color(0, 0, 0, 0)
		return b
	if material != "solid":
		b.bg_color = Color.WHITE
		return b
	match spec.shape.cards:
		"flat":
			b.set_border_width_all(2)
			b.border_color = c.line
		"soft":
			b.shadow_color = Color(0, 0, 0, 0.35 if appearance == "night" else 0.08)
			b.shadow_size = roundi(px.gap * 1.5)
			b.shadow_offset = Vector2(0, px.gap * 0.4)
		"edge":
			b.border_width_left = roundi(px.gap * 0.6)
			b.border_color = c.accent
			b.content_margin_left = px.gap * 1.2 + b.border_width_left
	b.anti_aliasing = true
	return b


func _font(f: Dictionary) -> Font:
	var path := _fonts_dir.path_join(f.file)
	if not _font_files.has(path):
		var ff := FontFile.new()
		ff.load_dynamic_font(path)
		# A pack's fonts are hinted as the stock UI renders them, which is also what its
		# references show; a built-in theme keeps Godot's default.
		var hint: String = f.get("hinting", "normal" if pack else "")
		if hint != "":
			ff.hinting = {none = TextServer.HINTING_NONE, light = TextServer.HINTING_LIGHT, normal = TextServer.HINTING_NORMAL}[hint]
		_font_files[path] = ff
	var v := FontVariation.new()
	v.base_font = _font_files[path]
	if f.has("weight"):
		var ts := TextServerManager.get_primary_interface()
		v.variation_opentype = {ts.name_to_tag("wght"): int(f.weight)}
	return v


func _yaml(path: String) -> Dictionary:
	var text := FileAccess.get_file_as_string(path)
	var d = Yaml.parse(text)
	if d is Dictionary:
		return d
	push_error("%s: %s" % [path, d if d is String else "not a map"])
	return {}
