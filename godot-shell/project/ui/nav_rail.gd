class_name NavRail
extends PanelContainer
## A column docked on the driver's side, full height, that jumps between pages: home, the
## electric vehicle page, the media page, the app launcher, the phone's window, and the phone's
## picture alone on the panel, where the rail hides (the page has its own way back). The shell
## lays every other page out beside it (`Shell.rail_width`). Not part of any theme's layout; on
## until the shell has its real navigation, unless LIVI_SHELL_NAV=0.
##
## The items' order is the look's (`ThemeManager.rail_order`, also set from Settings, Look). A
## press held still for LIFT_MS lifts an item, the finger drags it and the others make room, and
## the release drops it there; a press that moves first, or a drag off the rail, does nothing.

signal selected(page: String)
## The order, or which items show, changed.
signal items_changed

const ITEMS := [["home", "Home", "home"], ["ev", "EV", "bolt"], ["media", "Media", "note"], ["apps", "Apps", "grid"], ["projection", "Phone", "phone"], ["settings", "Settings", "gear"]]
## Why an item the rail hides itself is off it.
const HIDDEN_WHY := {projection = "Shows while a phone is connected"}
const LIFT_MS := 400
const LIFT_SCALE := 1.1

var _buttons := {}
var _items: Control
## Item ids, top first (`ordered`).
var _order: Array = []
## Each shown item's y in `_items`, and the first one's.
var _at := {}
var _top := 0.0
var _sep := 0.0
## The item the open page is.
var _key := "home"
var _shadow: Panel
## A press on an item: which, where, held how long; `_spent` once it moved before lifting or its
## drag was called off, and does nothing more.
var _down := ""
var _down_at := Vector2.ZERO
var _held := 0.0
var _spent := false
## The item lifted, the order it would drop into, and the finger's offset into it.
var _lifted := ""
var _drop: Array = []
var _grab := 0.0
## The press lifted: the tap its release makes on the button is not one.
var _swallow := false
## The status bar runs as a column beside it (`Shell.status_beside_rail`): one band, whose rule
## is the column's, against the page.
var joined := false:
	set(v):
		if v != joined:
			joined = v
			if is_inside_tree():
				_style()
var _shell: Control


func _init() -> void:
	name = "NavRail"
	# Laid out here, not by a container, so items can move while one is dragged.
	_items = Control.new()
	_items.name = "Items"
	_items.mouse_filter = Control.MOUSE_FILTER_PASS
	_items.resized.connect(_layout.bind(true))
	add_child(_items)
	_shadow = Panel.new()
	_shadow.name = "Shadow"
	_shadow.visible = false
	_shadow.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_items.add_child(_shadow)
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
		b.pressed.connect(_tapped.bind(item[0]))
		_items.add_child(b)
		_buttons[item[0]] = b
	(_buttons.home as Button).set_pressed_no_signal(true)


func _ready() -> void:
	add_to_group("nav_rail")
	ThemeManager.changed.connect(_style)
	ThemeManager.changed.connect(_join)
	ThemeManager.rail_order_changed.connect(_reorder)
	set_process(false)
	_style()


## `saved` made whole: unknown and repeated ids dropped, missing ones after it in ITEMS' order.
static func ordered(saved: Array) -> Array:
	var out := []
	for id in saved:
		if _item(str(id)).size() > 0 and not out.has(str(id)):
			out.append(str(id))
	for item in ITEMS:
		if not out.has(item[0]):
			out.append(item[0])
	return out


## `[id, label, icon]`; [] for no such item.
static func _item(id: String) -> Array:
	for item in ITEMS:
		if item[0] == id:
			return item
	return []


## Item ids, top first.
func order() -> Array:
	return _order.duplicate()


func item_shown(id: String) -> bool:
	return _buttons.has(id) and (_buttons[id] as Button).visible


## Docks a rail beside `shell`, as its sibling; a tap opens the page with `open` (default
## `shell.open_page`).
static func wanted() -> bool:
	return OS.get_environment("LIVI_SHELL_NAV") != "0"


static func attach(shell: Control, open := Callable()) -> NavRail:
	var rail := NavRail.new()
	rail.selected.connect(open if open.is_valid() else func(page): shell.open_page(page))
	shell.page_changed.connect(rail.show_page)
	# The phone's page only while there is a phone's picture to show.
	rail.set_item_visible("projection", shell.has_phone())
	shell.phone_changed.connect(func(on): rail.set_item_visible("projection", on))
	rail.resized.connect(func(): shell.rail_width = rail.size.x)
	rail._shell = shell
	rail._join()
	shell.add_sibling(rail)
	return rail


## Marks the page that is open: `ev_live` and `ev_main` are both the EV item.
func show_page(page: String) -> void:
	visible = page != "projection"
	_join()
	# A hosted app's window ("app") was opened from Apps.
	_key = "ev" if page.begins_with("ev") else "apps" if page == "app" else page if _buttons.has(page) else ""
	_mark()


func _mark() -> void:
	# set_pressed_no_signal leaves the group's other button pressed too.
	for k in _buttons:
		(_buttons[k] as Button).set_pressed_no_signal(k == _key)


func _tapped(id: String) -> void:
	if _swallow:
		# The release toggled the button under it.
		_mark()
		return
	selected.emit(id)


func _join() -> void:
	joined = is_instance_valid(_shell) and _shell.status_beside_rail()


## Shows or hides one item (`projection` while there is no phone's picture).
func set_item_visible(page: String, on: bool) -> void:
	var b: Button = _buttons.get(page)
	if b == null or b.visible == on:
		return
	b.visible = on
	if not on and page == _lifted:
		_cancel()
	_layout(true)
	items_changed.emit()


func _reorder() -> void:
	var o := ordered(ThemeManager.rail_order)
	if o != _order:
		if _lifted != "":
			_cancel()
		_order = o
		_layout(true)
	items_changed.emit()


## Places the shown items, centred, top first; `snap` puts them there, else they move there.
func _layout(snap: bool) -> void:
	var shown := (_drop if _lifted != "" else _order).filter(func(id): return (_buttons[id] as Button).visible)
	# In whole pixels, as a VBoxContainer centres.
	var h := 0
	var w := 0.0
	for id in shown:
		var m := (_buttons[id] as Button).get_combined_minimum_size()
		h += int(m.y)
		w = maxf(w, m.x)
	h += int(_sep) * maxi(0, shown.size() - 1)
	_items.custom_minimum_size = Vector2(w, h)
	var y := (int(_items.size.y) - h) / 2
	_top = y
	_at.clear()
	for id in shown:
		var b: Button = _buttons[id]
		var bh := int(b.get_combined_minimum_size().y)
		b.size = Vector2(floorf(_items.size.x), bh)
		b.position.x = 0.0
		_at[id] = float(y)
		if id != _lifted and (snap or ThemeManager.reduced_motion):
			b.position.y = y
		y += bh + int(_sep)
	set_process(true)


func _process(delta: float) -> void:
	# Frame time, not the clock: a scenario's frames are fixed.
	_held += delta
	if _down != "" and _lifted == "" and not _spent and _held * 1000.0 >= LIFT_MS:
		_lift()
	var moving := false
	var k := 1.0 - exp(-delta * 20.0)
	for id in _at:
		var b: Button = _buttons[id]
		if id == _lifted:
			continue
		if absf(b.position.y - _at[id]) < 0.5:
			b.position.y = _at[id]
		else:
			b.position.y = lerpf(b.position.y, _at[id], k)
			moving = true
	set_process(moving or _down != "")


# _input, ahead of the buttons. On the panel a finger arrives twice, as touch and as the mouse
# Godot emulates from it: the twin of a press or release finds it already done.
func _input(e: InputEvent) -> void:
	if not is_visible_in_tree():
		return
	if (e is InputEventMouseButton and e.button_index == MOUSE_BUTTON_LEFT) or (e is InputEventScreenTouch and e.index == 0):
		if e.pressed:
			_press(e.position)
		else:
			_release()
	elif _down != "" and (e is InputEventMouseMotion or (e is InputEventScreenDrag and e.index == 0)):
		_move(e.position)


func _press(at: Vector2) -> void:
	if _down != "":
		return
	_swallow = false
	for id in _order:
		var b: Button = _buttons[id]
		if b.visible and b.get_global_rect().has_point(at):
			_down = id
	if _down == "":
		return
	_down_at = at
	_held = 0.0
	_spent = false
	set_process(true)


func _move(at: Vector2) -> void:
	if _lifted == "":
		# A swipe, not a hold.
		if at.distance_to(_down_at) > ThemeManager.px.touch * 0.25:
			_spent = true
		return
	if not get_global_rect().grow(ThemeManager.px.touch).has_point(at):
		_cancel()
		return
	var b: Button = _buttons[_lifted]
	b.position.y = clampf(at.y - _items.global_position.y - _grab, 0.0, _items.size.y - b.size.y)
	_shadow.position = b.position
	var others := _order.filter(func(id): return id != _lifted and (_buttons[id] as Button).visible)
	var k := clampi(floori((b.position.y + b.size.y / 2.0 - _top) / (b.size.y + _sep)), 0, others.size())
	var drop := _order.filter(func(id): return id != _lifted)
	drop.insert(drop.find(others[k]) if k < others.size() else drop.find(others[-1]) + 1 if not others.is_empty() else drop.size(), _lifted)
	if drop != _drop:
		_drop = drop
		_layout(false)


func _release() -> void:
	if _down == "":
		return
	_down = ""
	if _lifted == "":
		return
	var was := _order
	_order = _drop
	_settle()
	if _order != was:
		ThemeManager.set_rail_order(_order)


func _lift() -> void:
	_lifted = _down
	_swallow = true
	_drop = _order.duplicate()
	var b: Button = _buttons[_lifted]
	# Drops the button's own press: it would draw as picked, and its release open the page.
	b.disabled = true
	b.disabled = false
	_grab = _down_at.y - b.get_global_rect().position.y
	# Over the others, its shadow under it.
	_items.move_child(_shadow, -1)
	_items.move_child(b, -1)
	_shadow.size = b.size
	_shadow.position = b.position
	_shadow.visible = true
	_scale(b, LIFT_SCALE)


## Puts the lifted item down in its slot.
func _settle() -> void:
	var b: Button = _buttons[_lifted]
	_lifted = ""
	_drop = []
	_shadow.visible = false
	_scale(b, 1.0)
	_layout(false)


func _cancel() -> void:
	_spent = true
	_drop = _order.duplicate()
	_settle()


func _scale(b: Button, s: float) -> void:
	for c in [b, _shadow]:
		c.pivot_offset = b.size / 2.0
		if ThemeManager.reduced_motion:
			c.scale = Vector2.ONE * s
		else:
			c.create_tween().tween_property(c, "scale", Vector2.ONE * s, 0.12).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)


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
	# Square: the style's padding around the icon makes them wider than touch.
	for item in ITEMS:
		var b: Button = _buttons[item[0]]
		var w := ceilf(b.get_combined_minimum_size().x)
		b.custom_minimum_size = Vector2(w, w)
	_sep = roundi(maxf(g * 0.5, ThemeManager.px.touch_gap))
	var lift := StyleBoxFlat.new()
	lift.bg_color = ThemeManager.c.bg
	lift.set_corner_radius_all(roundi(ThemeManager.px.radius))
	lift.shadow_color = Color(0, 0, 0, 0.45)
	lift.shadow_size = roundi(g)
	lift.shadow_offset = Vector2(0, g * 0.4)
	_shadow.add_theme_stylebox_override("panel", lift)
	if _lifted == "":
		_order = ordered(ThemeManager.rail_order)
	_layout(true)
	var left := ThemeManager.hand != "rhd"
	# The status bar's look, its rule on the edge that meets the page.
	var f := StyleBoxFlat.new()
	f.bg_color = ThemeManager.c.bg
	f.border_color = ThemeManager.c.line
	f.border_width_right = 2 if left and not joined else 0
	f.border_width_left = 2 if not left and not joined else 0
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
