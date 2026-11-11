class_name DriveCover
extends Control
## The parked-only cover: over a hosted app's window (`window_id`) or a keyboard (`typing`)
## while the car is driven and Drive locks it. It takes every touch while it shows; the app keeps
## running under it. Where Settings → Look → Driving lets a passenger unlock, a button asks for
## it and a second step confirms, each drive.

## A typing cover offers a way out: the keyboard's own keys are under it.
signal dismissed

var typing := false
var window_id := -1:
	set(v):
		window_id = v
		_update()

var _confirming := false
var _box: VBoxContainer
var _icon: TextureRect
var _title: Label
var _detail: Label
var _buttons: HBoxContainer
var _unlock: Button
var _cancel: Button
var _close: Button


func _init() -> void:
	name = "DriveCover"
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	visible = false
	_icon = UI.icon("lock", "status", "dim")
	_icon.name = "Lock"
	_title = UI.label("", "strong", "title")
	_title.name = "Title"
	_detail = UI.label("", "body", "body", "dim")
	_detail.name = "Detail"
	for l in [_title, _detail]:
		l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_cancel = _button("Cancel", "Cancel")
	_cancel.pressed.connect(func(): _confirming = false; _update())
	_close = _button("Close", "Close")
	_close.pressed.connect(func(): dismissed.emit())
	_unlock = _button("Unlock", "")
	_unlock.pressed.connect(_on_unlock)
	_buttons = UI.hbox([_close, _cancel, _unlock], 1.0)
	_buttons.name = "Buttons"
	_buttons.alignment = BoxContainer.ALIGNMENT_CENTER
	_box = UI.vbox([_icon, _title, _detail, _buttons], 0.8)
	_box.name = "Box"
	_box.alignment = BoxContainer.ALIGNMENT_CENTER
	add_child(_box)


func _button(button_name: String, text: String) -> Button:
	var b := Button.new()
	b.name = button_name
	b.text = text
	b.focus_mode = Control.FOCUS_NONE
	return b


func _ready() -> void:
	Drive.changed.connect(_update)
	ThemeManager.changed.connect(_style)
	resized.connect(_place)
	_style()


func _style() -> void:
	theme = ThemeManager.godot_theme
	UI.restyle(self)
	for b in [_unlock, _cancel, _close]:
		b.custom_minimum_size = Vector2(ThemeManager.px.touch * 2.6, ThemeManager.px.touch)
	var accent := StyleBoxFlat.new()
	accent.bg_color = ThemeManager.c.accent
	accent.set_corner_radius_all(roundi(ThemeManager.px.radius))
	accent.content_margin_left = ThemeManager.px.gap * 1.5
	accent.content_margin_right = ThemeManager.px.gap * 1.5
	accent.anti_aliasing = true
	for s in ["normal", "hover", "pressed", "hover_pressed"]:
		_unlock.add_theme_stylebox_override(s, accent)
	for k in ["font_color", "font_hover_color", "font_pressed_color", "font_hover_pressed_color"]:
		_unlock.add_theme_color_override(k, ThemeManager.c.on_accent)
	_update()


## Whether it shows now.
func covers() -> bool:
	return Drive.locked() if typing else Drive.covers_window(window_id)


func _update() -> void:
	if _title == null:
		return
	var on := covers()
	if not on:
		_confirming = false
	visible = on
	if not on:
		return
	# Nor keys: a hardware keyboard's would still reach the window.
	var focus: Control = get_viewport().gui_get_focus_owner() if is_inside_tree() else null
	if focus and focus != self and get_parent().is_ancestor_of(focus):
		focus.release_focus()
	if typing:
		_title.text = "Typing is available when parked"
	else:
		_title.text = "Available when parked"
	if _confirming:
		_detail.text = "Only a passenger should use the screen while the car moves. It stays unlocked until the car parks."
	elif typing:
		_detail.text = "The keyboard is off while the car moves."
	else:
		var app: String = Drive.app_of(window_id)
		var n: String = Drive.launcher.app(app).get("name", "") if is_instance_valid(Drive.launcher) and app != "" else ""
		_detail.text = "%s keeps running and is back when the car parks." % (n if n != "" else "The app")
	_unlock.visible = Drive.can_unlock()
	_unlock.text = "Unlock" if _confirming else "A passenger is using it"
	_cancel.visible = _confirming
	_close.visible = typing and not _confirming
	_place()
	queue_redraw()


func _on_unlock() -> void:
	if not _confirming:
		_confirming = true
		_update()
		return
	_confirming = false
	Drive.unlock_for_passenger()


func _place() -> void:
	var g: float = ThemeManager.px.gap
	var w := minf(size.x - g * 4.0, 900.0)
	for l in [_title, _detail]:
		l.custom_minimum_size.x = w
	_box.size = Vector2(w, 0)
	_box.size = _box.get_combined_minimum_size()
	_box.position = ((size - _box.size) / 2.0).round()


func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), ThemeManager.c.bg)
