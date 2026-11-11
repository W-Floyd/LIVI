class_name SeekBar
extends Control
## The track's progress, a touch high: a press or drag anywhere on it moves the knob, and the
## release seeks. Without `seekable` it only shows the progress.

signal seeked(fraction: float)
## While a finger moves the knob, for the time it would seek to.
signal dragged(fraction: float)

var fraction := 0.0:
	set(v):
		if v != fraction:
			fraction = v
			queue_redraw()
var seekable := true:
	set(v):
		seekable = v
		mouse_filter = Control.MOUSE_FILTER_STOP if v else Control.MOUSE_FILTER_IGNORE
		if not v:
			_drag = -1.0
		queue_redraw()

var _drag := -1.0
## Its height, of a touch target: a thin bar on home's media card.
var height_share := 1.0:
	set(v):
		height_share = v
		update_minimum_size()


func _ready() -> void:
	ThemeManager.changed.connect(queue_redraw)


## Where the knob shows: under the finger while it moves.
func shown() -> float:
	return _drag if _drag >= 0.0 else fraction


func dragging() -> bool:
	return _drag >= 0.0


func _get_minimum_size() -> Vector2:
	return Vector2(0, roundf(ThemeManager.px.touch * height_share))


func _gui_input(event: InputEvent) -> void:
	if not seekable:
		return
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			_move(event.position.x)
		elif _drag >= 0.0:
			var f := _drag
			_drag = -1.0
			fraction = f
			seeked.emit(f)
			queue_redraw()
		accept_event()
	elif event is InputEventMouseMotion and _drag >= 0.0:
		_move(event.position.x)
		accept_event()


func _move(x: float) -> void:
	var k := _knob()
	_drag = clampf((x - k) / maxf(1.0, size.x - k * 2.0), 0.0, 1.0)
	dragged.emit(_drag)
	queue_redraw()


func _knob() -> float:
	return ThemeManager.px.touch * 0.2


func _draw() -> void:
	var k := _knob()
	var h := maxf(4.0, roundf(ThemeManager.px.gap * 0.6))
	var y := size.y / 2.0
	var w := size.x - k * 2.0
	var x := k + w * shown()
	draw_style_box(_pill(ThemeManager.c.surface2, h), Rect2(k, y - h / 2.0, w, h))
	if x - k >= 1.0:
		draw_style_box(_pill(ThemeManager.c.accent, h), Rect2(k, y - h / 2.0, maxf(h, x - k), h))
	if seekable:
		draw_circle(Vector2(x, y), k * (1.25 if _drag >= 0.0 else 1.0), ThemeManager.c.accent)


func _pill(c: Color, h: float) -> StyleBoxFlat:
	var b := StyleBoxFlat.new()
	b.bg_color = c
	b.set_corner_radius_all(roundi(h / 2.0))
	b.anti_aliasing = true
	return b
