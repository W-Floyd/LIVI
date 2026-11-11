class_name ProjectionView
extends Control
## Where Android Auto or CarPlay shows, or a hosted app. Until a window is there it is just the
## theme's projection color.

var window: WindowView


func _init() -> void:
	clip_contents = true
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	window = WindowView.new()
	window.name = "Window"
	window.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(window)


func _ready() -> void:
	ThemeManager.changed.connect(_style)
	resized.connect(queue_redraw)
	_style()


func _style() -> void:
	UI.restyle(self)
	queue_redraw()


func _draw() -> void:
	var c := ThemeManager.c
	draw_rect(Rect2(Vector2.ZERO, size), c.proj)


## `projection`: the window is the phone's video, whose input goes to the phone through the core.
func show_window(id: int, projection := false) -> void:
	window.window_id = id
	window.to_core = projection
	_style()
