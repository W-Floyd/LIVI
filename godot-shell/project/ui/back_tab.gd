class_name BackTab
extends Control
## The way out of the projection page, which gives the phone the whole panel: a back button in
## the top-left corner, shown for a few seconds when the page opens and again on a tap in that
## corner. While it is hidden, a tap there shows it and is not the phone's.

signal pressed

const SHOWN_S := 4.0

var _button: Button
var _timer: Timer


func _init() -> void:
	name = "BackTab"
	mouse_filter = Control.MOUSE_FILTER_STOP
	_button = Button.new()
	_button.name = "Button"
	_button.focus_mode = Control.FOCUS_NONE
	_button.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_button.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_button.pressed.connect(func(): pressed.emit())
	add_child(_button)
	_timer = Timer.new()
	_timer.one_shot = true
	_timer.timeout.connect(_button.hide)
	add_child(_timer)


func _ready() -> void:
	ThemeManager.changed.connect(_style)
	_style()


func reveal() -> void:
	_button.show()
	if is_inside_tree():
		_timer.start(SHOWN_S)


## Reached only while the button is hidden: it covers the tab when shown.
func _gui_input(event: InputEvent) -> void:
	if (event is InputEventScreenTouch or event is InputEventMouseButton) and event.pressed:
		reveal()
		accept_event()


func _style() -> void:
	theme = ThemeManager.godot_theme
	var side := maxf(ThemeManager.px.touch * 1.5, 1.0)
	position = Vector2.ZERO
	size = Vector2(side, side)
	_button.icon = Icons.texture("back", ThemeManager.px.icon * 1.2)
	var f := StyleBoxFlat.new()
	f.bg_color = ThemeManager.c.surface
	f.bg_color.a = 0.85
	f.set_corner_radius_all(roundi(ThemeManager.px.radius))
	for state in ["normal", "hover", "pressed"]:
		_button.add_theme_stylebox_override(state, f)
