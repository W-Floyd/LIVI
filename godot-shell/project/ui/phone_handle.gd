class_name PhoneHandle
extends Control
## Home's split divider, as Android's split screen: a slim pill in the gutter between the phone's
## slot and the cards, or a tab at the slot's edge while the phone is hidden. This control is only
## its touch target, laid over both sides and taking no width. It only drags: sideways past the
## slop it reports the finger's travel; a tap nudges the pill to say so.

## The finger `dx` panel pixels sideways of where it pressed.
signal dragged(dx: float)
## The drag ended.
signal released

## The pill drawn (a scene theme's slab follows it).
var pill: Pill

var _press := Vector2.INF
var _dragging := false
var _nudge: Tween
## With touch emulating the mouse, touches also arrive as mouse events: take only those.
var _mouse_only: bool = ProjectSettings.get_setting("input_devices/pointing/emulate_mouse_from_touch", true)


func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	focus_mode = Control.FOCUS_NONE
	pill = Pill.new()
	pill.name = "Pill"
	pill.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(pill)


## Lays the pill at `r` and the target around it, `touch` square at least, inside `bounds`.
func place(r: Rect2, touch: float, bounds: Rect2) -> void:
	var s := Vector2(maxf(touch, r.size.x), maxf(touch, r.size.y))
	var p := r.get_center() - s / 2.0
	p.x = clampf(p.x, bounds.position.x, maxf(bounds.position.x, bounds.end.x - s.x))
	p.y = clampf(p.y, bounds.position.y, maxf(bounds.position.y, bounds.end.y - s.y))
	global_position = p
	size = s
	pill.position = r.position - p
	pill.size = r.size


func _gui_input(event: InputEvent) -> void:
	var press: bool = event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT
	var touch: bool = event is InputEventScreenTouch and not _mouse_only
	var move: bool = (event is InputEventMouseMotion and event.button_mask & MOUSE_BUTTON_MASK_LEFT) \
		or (event is InputEventScreenDrag and not _mouse_only)
	if not (press or touch or move):
		return
	accept_event()
	var at: Vector2 = get_global_transform() * event.position
	if press or touch:
		if event.pressed:
			_press = at
			_dragging = false
			pill.lit = true
		elif _press != Vector2.INF:
			_press = Vector2.INF
			pill.lit = false
			if _dragging:
				_dragging = false
				released.emit()
			else:
				_hint()
		return
	if _press == Vector2.INF:
		return
	var d := at - _press
	if not _dragging and (absf(d.x) < ThemeManager.px.touch_gap or absf(d.x) < absf(d.y)):
		return
	_dragging = true
	dragged.emit(d.x)


## A tap: the pill sways sideways and back, it is dragged, not pressed. Still under reduced motion.
func _hint() -> void:
	if ThemeManager.reduced_motion:
		return
	if _nudge:
		_nudge.kill()
	var a: float = ThemeManager.px.touch_gap
	_nudge = create_tween().set_trans(Tween.TRANS_SINE)
	for to in [a, -a * 0.6, 0.0]:
		_nudge.tween_property(pill, "shift", to, 0.09)


func _notification(what: int) -> void:
	if what == NOTIFICATION_VISIBILITY_CHANGED:
		_press = Vector2.INF
		pill.lit = false
		if _dragging:
			_dragging = false
			released.emit()


class Pill extends Control:
	## 0 a pill in the gutter, 1 a tab against the content's edge on `edge_left` or the right.
	var tab := 0.0:
		set(v):
			if v != tab:
				tab = v
				queue_redraw()
	var edge_left := false:
		set(v):
			if v != edge_left:
				edge_left = v
				queue_redraw()
	## Held: the accent.
	var lit := false:
		set(v):
			if v != lit:
				lit = v
				queue_redraw()
	## Drawn this far sideways (the tap's hint).
	var shift := 0.0:
		set(v):
			shift = v
			queue_redraw()

	func _ready() -> void:
		ThemeManager.changed.connect(queue_redraw)

	func _draw() -> void:
		var b := StyleBoxFlat.new()
		b.bg_color = ThemeManager.c.accent if lit else ThemeManager.c.dim
		b.anti_aliasing = true
		var rad := roundi(minf(size.x, size.y) / 2.0)
		b.set_corner_radius_all(rad)
		# A tab's side on the edge is square.
		var edge := roundi(lerpf(rad, 0.0, tab))
		if edge_left:
			b.corner_radius_top_left = edge
			b.corner_radius_bottom_left = edge
		else:
			b.corner_radius_top_right = edge
			b.corner_radius_bottom_right = edge
		draw_style_box(b, Rect2(Vector2(shift, 0.0), size))
