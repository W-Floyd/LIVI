class_name NavRail
extends PanelContainer
## A short menu on the left edge, over whatever page is open, that jumps between pages: home, the
## electric vehicle page, the app launcher, the phone's window, and the phone's picture alone on
## the panel, where the rail hides (the page has its own way back). Not part of any theme's
## layout; a unit turns it on with LIVI_SHELL_NAV until the shell has its real navigation.

signal selected(page: String)

const ITEMS := [["home", "Home", "home"], ["ev", "EV", "bolt"], ["apps", "Apps", "grid"], ["projection", "Phone", "phone"], ["settings", "Settings", "gear"]]

var _buttons := {}


func _init() -> void:
	name = "NavRail"
	# Centred on the left edge whatever its height: grown both ways, re-centred once styled.
	grow_vertical = Control.GROW_DIRECTION_BOTH
	var box := VBoxContainer.new()
	add_child(box)
	var group := ButtonGroup.new()
	for item in ITEMS:
		var b := Button.new()
		b.name = item[0]
		b.tooltip_text = item[1]
		b.toggle_mode = true
		b.button_group = group
		b.focus_mode = Control.FOCUS_NONE
		b.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
		b.vertical_icon_alignment = VERTICAL_ALIGNMENT_CENTER
		b.pressed.connect(func(): selected.emit(item[0]))
		box.add_child(b)
		_buttons[item[0]] = b
	(_buttons.home as Button).set_pressed_no_signal(true)


func _ready() -> void:
	ThemeManager.changed.connect(_style)
	_style()


## Marks the page that is open: `ev_live` and `ev_main` are both the EV item.
func show_page(page: String) -> void:
	visible = page != "projection"
	# A hosted app's window ("app") was opened from Apps.
	var key := "ev" if page.begins_with("ev") else "apps" if page == "app" else page if _buttons.has(page) else ""
	# set_pressed_no_signal leaves the group's other button pressed too.
	for k in _buttons:
		(_buttons[k] as Button).set_pressed_no_signal(k == key)


func _style() -> void:
	theme = ThemeManager.godot_theme
	var g: float = ThemeManager.px.gap
	# Small: it sits over the page (and over Android Auto's left edge).
	var side: float = ThemeManager.px.touch
	for item in ITEMS:
		var b: Button = _buttons[item[0]]
		b.icon = Icons.texture(item[2], ThemeManager.px.icon)
		b.custom_minimum_size = Vector2(side, side)
		# Touch leaves the last button "hovered": hover looks like rest, or two items look picked.
		b.add_theme_stylebox_override("hover", b.get_theme_stylebox("normal"))
		b.add_theme_stylebox_override("hover_pressed", b.get_theme_stylebox("pressed"))
	(get_child(0) as VBoxContainer).add_theme_constant_override("separation", roundi(g * 0.5))
	var f := StyleBoxFlat.new()
	f.bg_color = ThemeManager.c.surface
	f.bg_color.a = 0.85
	f.set_corner_radius_all(roundi(ThemeManager.px.radius))
	f.set_content_margin_all(g * 0.5)
	add_theme_stylebox_override("panel", f)
	_center.call_deferred()


func _center() -> void:
	reset_size()
	set_anchors_and_offsets_preset(Control.PRESET_CENTER_LEFT, Control.PRESET_MODE_MINSIZE)
