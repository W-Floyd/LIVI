class_name TitleBar
extends Control
## The page's top bar under the status bar: a back button (none beside a docked rail), the page's
## title (the page's own label, centered in it) and a button that hides or shows the page's
## controls so the scene shows whole. A pack with the stock bar supplies its background, shadow and back button images; any
## other theme gets the same bar in its own colors, shapes and icons.

signal back_pressed
signal hide_toggled(hidden: bool)

const PACK_BG := "HKMC_TAppEV3/co_bg_title_bar"
const PACK_BACK := "SystemUI/co_btn_back_1920_%s"

var _back: Button
var _hide: Button
## Off where a docked nav rail is the way home.
var back_shown := true:
	set(v):
		back_shown = v
		_back.visible = v
var ui_hidden := false:
	set(v):
		ui_hidden = v
		if _hide:
			_hide.set_pressed_no_signal(v)
			_icons()


func _init() -> void:
	name = "TitleBar"
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_back = _button("Back")
	_back.pressed.connect(func(): back_pressed.emit())
	_hide = _button("HideUI")
	_hide.toggle_mode = true
	_hide.toggled.connect(func(on): ui_hidden = on; hide_toggled.emit(on))


func _ready() -> void:
	ThemeManager.changed.connect(_style)
	resized.connect(_place)
	_style()


func _button(button_name: String) -> Button:
	var b := Button.new()
	b.name = button_name
	b.focus_mode = Control.FOCUS_NONE
	b.expand_icon = true
	b.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
	b.vertical_icon_alignment = VERTICAL_ALIGNMENT_CENTER
	add_child(b)
	return b


func _style() -> void:
	var pack := ThemeManager.pack
	var stock := pack != null and ThemeManager.material == "solid" and pack.has_image(PACK_BACK % "nor")
	for b in [_back, _hide]:
		(b as Button).add_theme_stylebox_override("normal", _box(b, "normal"))
		(b as Button).add_theme_stylebox_override("hover", _box(b, "normal"))
		(b as Button).add_theme_stylebox_override("pressed", _box(b, "pressed"))
		(b as Button).add_theme_stylebox_override("hover_pressed", _box(b, "pressed"))
	_back.set_meta("stock", stock)
	_icons()
	_place()
	queue_redraw()


## The stock back button's image where there is one, else the theme's flat button.
func _box(b: Button, state: String) -> StyleBox:
	var pack := ThemeManager.pack
	if b == _back and pack != null and ThemeManager.material == "solid":
		var key := PACK_BACK % ("push" if state == "pressed" else "nor")
		if pack.has_image(key):
			return pack.box(key, ThemeManager.appearance)
	var f := StyleBoxFlat.new()
	f.bg_color = ThemeManager.c.accent if state == "pressed" and b == _hide else ThemeManager.c.surface2 if state == "pressed" else Color(0, 0, 0, 0)
	f.set_corner_radius_all(roundi(ThemeManager.px.radius))
	f.anti_aliasing = true
	return f


func _icons() -> void:
	var s: float = ThemeManager.px.icon * 1.3
	_back.icon = Icons.texture("back", s)
	_hide.icon = Icons.texture("eye_off" if ui_hidden else "eye", s)
	var stock: bool = _back.get_meta("stock", false)
	for b in [_back, _hide]:
		var on_accent: bool = b == _hide and ui_hidden
		var tint: Color = ThemeManager.c.on_accent if on_accent else ThemeManager.c.text
		for k in ["icon_normal_color", "icon_hover_color", "icon_pressed_color", "icon_hover_pressed_color", "icon_focus_color"]:
			(b as Button).add_theme_color_override(k, tint)
		(b as Button).set_meta("tint", tint)
	# The stock back image carries its own arrow.
	if stock:
		_back.icon = null


## The bar's height: the touch target and a little, so the buttons are at least that.
static func bar_height() -> float:
	return maxf(ThemeManager.px.touch * 1.15, ThemeManager.px.status)


func _place() -> void:
	if _back == null:
		return
	var s := minf(size.y, bar_height())
	# The page's own edge margin, as the controls under the bar.
	var margin: float = ThemeManager.px.gap * 1.5
	var side := Vector2(maxf(s, ThemeManager.px.touch), maxf(s, ThemeManager.px.touch))
	var y := (size.y - side.y) / 2.0
	var rhd := ThemeManager.hand == "rhd"
	_back.size = side
	_hide.size = side
	# The back button is on the driver's side's far edge, the hide button on the other.
	_back.position = Vector2(size.x - margin - side.x if rhd else margin, y)
	_hide.position = Vector2(margin if rhd else size.x - margin - side.x, y)


func _draw() -> void:
	# A pack's page draws the stock bar's background and shadow itself (EvLive._draw).
	var pack := ThemeManager.pack
	if pack != null and ThemeManager.material == "solid" and pack.has_image(PACK_BG):
		return
	if ThemeManager.is_scene() or ThemeManager.floating():
		return
	draw_rect(Rect2(Vector2.ZERO, size), ThemeManager.c.bg)
	draw_rect(Rect2(0, size.y - 2, size.x, 2), ThemeManager.c.line)


## The back button's rect in the bar; empty while it is off.
func back_rect() -> Rect2:
	return Rect2(_back.position, _back.size) if back_shown else Rect2()
