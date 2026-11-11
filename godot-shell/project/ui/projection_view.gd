class_name ProjectionView
extends Control
## Where Android Auto or CarPlay shows, or a hosted app. Until a window is there it draws a
## stand-in map in the theme's projection color, labelled as a stand-in.

var window: WindowView
var _tag: Label


func _init() -> void:
	clip_contents = true
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	window = WindowView.new()
	window.name = "Window"
	window.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(window)
	_tag = UI.label("Android Auto · stand-in", "body", "caption", "dim")
	add_child(_tag)


func _ready() -> void:
	ThemeManager.changed.connect(_style)
	resized.connect(queue_redraw)
	_style()


func _style() -> void:
	UI.restyle(self)
	_tag.position = Vector2(ThemeManager.px.gap * 2, size.y - _tag.get_minimum_size().y - ThemeManager.px.gap * 2)
	_tag.visible = window.window_id < 0
	queue_redraw()


func _draw() -> void:
	var c := ThemeManager.c
	draw_rect(Rect2(Vector2.ZERO, size), c.proj)
	if window.window_id >= 0:
		return
	var night: bool = ThemeManager.appearance == "night"
	var proj: Color = c.proj
	var minor: Color = proj.lightened(0.06) if night else proj.darkened(0.04)
	var road: Color = proj.lightened(0.16) if night else Color.WHITE
	var w := size.x
	var h := size.y
	for i in 6:
		var y := h * (0.12 + i * 0.17)
		draw_line(Vector2(0, y), Vector2(w, y + h * 0.04), minor, 12.0, true)
		var x := w * (0.1 + i * 0.17)
		draw_line(Vector2(x, 0), Vector2(x - w * 0.03, h), minor, 12.0, true)
	var main := PackedVector2Array()
	var route := PackedVector2Array()
	for i in 41:
		var t := i / 40.0
		main.append(Vector2(w * t, h * (0.45 - 0.2 * sin(t * PI * 1.3))))
		route.append(Vector2(w * (0.1 + 0.7 * t), h * (0.95 - 0.75 * t + 0.08 * sin(t * PI * 2))))
	draw_polyline(main, road, 26.0, true)
	draw_polyline(route, Color("#4c8dff"), 16.0, true)
	draw_circle(route[0], 18.0, Color("#4c8dff"))
	draw_circle(route[route.size() - 1], 14.0, c.accent)
	_tag.position.y = h - _tag.get_minimum_size().y - ThemeManager.px.gap * 2


## `projection`: the window is the phone's video, whose input goes to the phone through the core.
func show_window(id: int, projection := false) -> void:
	window.window_id = id
	window.to_core = projection
	_style()
