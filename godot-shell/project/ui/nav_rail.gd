class_name NavRail
extends PanelContainer
## A short menu on the left edge, over whatever page is open, that jumps between pages: home, the
## electric vehicle page, and the phone's window. Not part of any theme's layout; a unit turns
## it on with LIVI_SHELL_NAV until the shell has its real navigation.

signal selected(page: String)

const ITEMS := [["home", "Home", "home"], ["ev", "EV", "bolt"], ["app", "Phone", "phone"]]

var _buttons := {}


func _init() -> void:
	name = "NavRail"
	set_anchors_and_offsets_preset(Control.PRESET_CENTER_LEFT, Control.PRESET_MODE_MINSIZE)
	var box := VBoxContainer.new()
	add_child(box)
	var group := ButtonGroup.new()
	for item in ITEMS:
		var b := Button.new()
		b.name = item[0]
		b.text = item[1]
		b.toggle_mode = true
		b.button_group = group
		b.focus_mode = Control.FOCUS_NONE
		b.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
		b.vertical_icon_alignment = VERTICAL_ALIGNMENT_TOP
		b.pressed.connect(func(): selected.emit(item[0]))
		box.add_child(b)
		_buttons[item[0]] = b
	(_buttons.home as Button).set_pressed_no_signal(true)


func _ready() -> void:
	ThemeManager.changed.connect(_style)
	_style()


## Marks the page that is open: `ev_live` and `ev_main` are both the EV item.
func show_page(page: String) -> void:
	var key := "ev" if page.begins_with("ev") else page if _buttons.has(page) else ""
	if key != "":
		(_buttons[key] as Button).set_pressed_no_signal(true)


func _style() -> void:
	theme = ThemeManager.godot_theme
	var g: float = ThemeManager.px.gap
	var side := maxf(ThemeManager.px.touch * 1.5, 1.0)
	for item in ITEMS:
		var b: Button = _buttons[item[0]]
		b.icon = Icons.texture(item[2], ThemeManager.px.icon * 1.2)
		b.custom_minimum_size = Vector2(side, side)
	(get_child(0) as VBoxContainer).add_theme_constant_override("separation", roundi(g * 0.5))
	var f := StyleBoxFlat.new()
	f.bg_color = ThemeManager.c.surface
	f.bg_color.a = 0.85
	f.set_corner_radius_all(roundi(ThemeManager.px.radius))
	f.set_content_margin_all(g * 0.5)
	add_theme_stylebox_override("panel", f)
