class_name DragScroll
extends Control
## A vertical list that a finger drags, with no scrollbar to aim for. A press that moves past the
## slop, mostly up or down, scrolls instead of tapping: `dragged` stays true until the next press,
## so the rows' handlers can drop the release that ends it. A flick coasts unless motion is reduced.

const FRICTION := 0.04   # speed left after a second of coasting

## The rows go here.
var list: VBoxContainer
var dragged := false
var offset := 0.0:
	set(v):
		offset = clampf(v, 0.0, max_offset())
		if list:
			list.position.y = -offset

var _press := Vector2.INF
var _last := Vector2.ZERO
var _last_ms := 0
var _speed := 0.0
## With touch emulating the mouse, touches also arrive as mouse events: take only those.
var _mouse_only: bool = ProjectSettings.get_setting("input_devices/pointing/emulate_mouse_from_touch", true)


func _init() -> void:
	clip_contents = true
	mouse_filter = Control.MOUSE_FILTER_PASS
	list = VBoxContainer.new()
	list.name = "List"
	list.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(list)
	resized.connect(_fit)
	list.minimum_size_changed.connect(_fit)


func max_offset() -> float:
	return maxf(0.0, list.size.y - size.y) if list else 0.0


func _fit() -> void:
	list.size = Vector2(size.x, list.get_combined_minimum_size().y)
	list.position.x = 0
	offset = offset


## Brings a row fully into view.
func reveal(c: Control) -> void:
	var top := c.get_global_rect().position.y - list.get_global_rect().position.y
	if top < offset:
		offset = top
	elif top + c.size.y > offset + size.y:
		offset = top + c.size.y - size.y


func _process(delta: float) -> void:
	if _press != Vector2.INF or absf(_speed) < 5.0:
		return
	offset += _speed * delta
	_speed *= pow(FRICTION, delta)
	if offset <= 0.0 or offset >= max_offset():
		_speed = 0.0


# _input, ahead of the rows: once a press is a drag, the rows must not see it move.
func _input(event: InputEvent) -> void:
	if not is_visible_in_tree():
		return
	var press: bool = event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT
	var touch: bool = event is InputEventScreenTouch and not _mouse_only
	if press or touch:
		if event.pressed:
			_press = event.position if get_global_rect().has_point(event.position) else Vector2.INF
			_last = event.position
			_last_ms = Time.get_ticks_msec()
			dragged = false
			_speed = 0.0
		else:
			_press = Vector2.INF
			if not dragged or ThemeManager.reduced_motion:
				_speed = 0.0
		return
	if event is InputEventMouseButton and event.pressed and get_global_rect().has_point(event.position):
		var wheel := {MOUSE_BUTTON_WHEEL_UP: -1.0, MOUSE_BUTTON_WHEEL_DOWN: 1.0}
		if wheel.has(event.button_index):
			offset += wheel[event.button_index] * ThemeManager.px.touch
			get_viewport().set_input_as_handled()
		return
	var move: bool = (event is InputEventMouseMotion and event.button_mask & MOUSE_BUTTON_MASK_LEFT) \
		or (event is InputEventScreenDrag and not _mouse_only)
	if not move or _press == Vector2.INF:
		return
	var p: Vector2 = event.position
	if not dragged:
		var d := p - _press
		if absf(d.y) < ThemeManager.px.touch_gap or absf(d.y) < absf(d.x):
			return
		dragged = true
		_last = p
	var now := Time.get_ticks_msec()
	var dy := p.y - _last.y
	offset -= dy
	_speed = -dy * 1000.0 / maxf(1.0, now - _last_ms)
	_last = p
	_last_ms = now
	get_viewport().set_input_as_handled()
