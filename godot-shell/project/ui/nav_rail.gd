class_name NavRail
extends PanelContainer
## A column docked on the driver's side, full height, that jumps between pages: home, the
## electric vehicle page, the media page, the app launcher, the phone's window, and the phone's
## picture alone on the panel, where the rail hides (the page has its own way back). The shell
## lays every other page out beside it (`Shell.rail_width`). Not part of any theme's layout; a
## unit turns it on with LIVI_SHELL_NAV until the shell has its real navigation.

signal selected(page: String)

const ITEMS := [["home", "Home", "home"], ["ev", "EV", "bolt"], ["media", "Media", "note"], ["apps", "Apps", "grid"], ["projection", "Phone", "phone"], ["settings", "Settings", "gear"]]

var _buttons := {}


func _init() -> void:
	name = "NavRail"
	var box := VBoxContainer.new()
	box.name = "Items"
	box.alignment = BoxContainer.ALIGNMENT_CENTER
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


## Docks a rail beside `shell`, as its sibling; a tap opens the page with `open` (default
## `shell.open_page`).
static func attach(shell: Control, open := Callable()) -> NavRail:
	var rail := NavRail.new()
	rail.selected.connect(open if open.is_valid() else func(page): shell.open_page(page))
	shell.page_changed.connect(rail.show_page)
	# The phone's page only while there is a phone's picture to show.
	rail.set_item_visible("projection", shell.has_phone())
	shell.phone_changed.connect(func(on): rail.set_item_visible("projection", on))
	rail.resized.connect(func(): shell.rail_width = rail.size.x)
	shell.add_sibling(rail)
	return rail


## Marks the page that is open: `ev_live` and `ev_main` are both the EV item.
func show_page(page: String) -> void:
	visible = page != "projection"
	# A hosted app's window ("app") was opened from Apps.
	var key := "ev" if page.begins_with("ev") else "apps" if page == "app" else page if _buttons.has(page) else ""
	# set_pressed_no_signal leaves the group's other button pressed too.
	for k in _buttons:
		(_buttons[k] as Button).set_pressed_no_signal(k == key)


## Shows or hides one item (`projection` while there is no phone's picture).
func set_item_visible(page: String, on: bool) -> void:
	var b: Button = _buttons.get(page)
	if b != null:
		b.visible = on


func _style() -> void:
	theme = ThemeManager.godot_theme
	var g: float = ThemeManager.px.gap
	var side: float = ThemeManager.px.touch
	for item in ITEMS:
		var b: Button = _buttons[item[0]]
		b.icon = Icons.texture(item[2], ThemeManager.px.icon)
		b.custom_minimum_size = Vector2(side, side)
		# Touch leaves the last button "hovered": hover looks like rest, or two items look picked.
		b.add_theme_stylebox_override("hover", b.get_theme_stylebox("normal"))
		b.add_theme_stylebox_override("hover_pressed", b.get_theme_stylebox("pressed"))
	(get_child(0) as VBoxContainer).add_theme_constant_override("separation", roundi(maxf(g * 0.5, ThemeManager.px.touch_gap)))
	var left := ThemeManager.hand != "rhd"
	# The status bar's look, its rule on the edge that meets the page.
	var f := StyleBoxFlat.new()
	f.bg_color = ThemeManager.c.bg
	f.border_color = ThemeManager.c.line
	f.border_width_right = 2 if left else 0
	f.border_width_left = 0 if left else 2
	f.set_content_margin_all(g * 0.75)
	add_theme_stylebox_override("panel", f)
	_dock.call_deferred()


## Once its minimum size has caught up with the style.
func _dock() -> void:
	var left := ThemeManager.hand != "rhd"
	set_anchors_preset(Control.PRESET_LEFT_WIDE if left else Control.PRESET_RIGHT_WIDE)
	# Whole pixels: the pages beside it lay out in whole pixels, and would overlap a fraction.
	var w := ceilf(get_combined_minimum_size().x)
	offset_top = 0.0
	offset_bottom = 0.0
	offset_left = 0.0 if left else -w
	offset_right = w if left else 0.0
