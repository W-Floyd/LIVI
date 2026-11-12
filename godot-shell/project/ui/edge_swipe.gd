class_name EdgeSwipe
extends Node
## Home by a swipe in from one panel edge (`ThemeManager.home_swipe`), over every page and
## hosted window: the way out of an app or projection that shows nothing to tap. Draws nothing.
## A press in the edge zone is held back from everything else until it is a swipe (dropped, and
## the rest of the finger with it) or not (passed on as it came: a tap there arrives on release).
## Presses elsewhere pass at once.

## The finger travelled far enough inward, and more inward than along the edge.
signal home

## A finger resting in the zone this long is a press of its own, not a swipe.
const HOLD_S := 0.25

## Whether a swipe would go anywhere: off on home itself, so its edge taps are never held.
var armed := false

enum { IDLE, HELD, PASS, SWALLOW }
var _state := IDLE
var _held: Array[InputEvent] = []
var _from := Vector2.ZERO
var _at := Vector2.ZERO
## Frame time, as tests run frames unthrottled.
var _held_s := 0.0
## The touch being followed; -1 for the mouse alone, or the emulated mouse ahead of its touch.
var _touch := -1
var _replaying := false


func _ready() -> void:
	set_process(false)


## The panel edge's inward direction, or zero for none.
static func inward(edge: String) -> Vector2:
	return {left = Vector2.RIGHT, right = Vector2.LEFT, top = Vector2.DOWN, bottom = Vector2.UP}.get(edge, Vector2.ZERO)


## Whether `at` is in `edge`'s zone of a panel of `size`.
static func in_zone(edge: String, at: Vector2, size: Vector2) -> bool:
	var w: float = ThemeManager.px.touch_gap
	match edge:
		"left": return at.x < w
		"right": return at.x >= size.x - w
		"top": return at.y < w
		"bottom": return at.y >= size.y - w
	return false


func _input(e: InputEvent) -> void:
	if _replaying or not (e is InputEventMouse or e is InputEventScreenTouch or e is InputEventScreenDrag):
		return
	if _state == IDLE:
		var press: bool = (e is InputEventScreenTouch and e.pressed) or (e is InputEventMouseButton and e.button_index == MOUSE_BUTTON_LEFT and e.pressed)
		if not press or not armed or not in_zone(ThemeManager.home_swipe, e.position, get_viewport().get_visible_rect().size):
			return
		_state = HELD
		_from = e.position
		_at = _from
		_held_s = 0.0
		_touch = e.index if e is InputEventScreenTouch else -1
		set_process(true)
	get_viewport().set_input_as_handled()
	if _state == SWALLOW:
		if _ends(e):
			_state = IDLE
		return
	_held.append(e)
	if _state != HELD:
		return
	if e is InputEventScreenTouch:
		if e.pressed and _touch < 0:
			_touch = e.index
		elif e.pressed and e.index != _touch:
			_pass()
	if _ends(e):
		_pass()
	elif (e is InputEventScreenDrag and e.index == _touch) or (e is InputEventMouseMotion and _touch < 0 and e.button_mask & MOUSE_BUTTON_MASK_LEFT):
		_at = e.position
		_judge()


## Whether `e` lifts the finger followed.
func _ends(e: InputEvent) -> bool:
	if e is InputEventScreenTouch:
		return not e.pressed and e.index == _touch
	return e is InputEventMouseButton and e.button_index == MOUSE_BUTTON_LEFT and not e.pressed and _touch < 0


func _judge() -> void:
	var n := inward(ThemeManager.home_swipe)
	var d := _at - _from
	var into := d.dot(n)
	var along := absf(d.dot(n.orthogonal()))
	if into >= ThemeManager.px.touch * 1.5 and into >= along:
		_held.clear()
		_state = SWALLOW
		set_process(false)
		home.emit()
	elif d.length() > ThemeManager.px.touch * 0.25 and into < along:
		_pass()


## Not a swipe: what was held goes on, in order, after this frame's input.
func _pass() -> void:
	_state = PASS


func _process(delta: float) -> void:
	_held_s += delta
	if _state == HELD and _held_s >= HOLD_S and _at.distance_to(_from) <= ThemeManager.px.touch * 0.25:
		_state = PASS
	if _state != PASS:
		return
	_replaying = true
	for e in _held:
		get_viewport().push_input(e, true)
	_replaying = false
	_held.clear()
	_state = IDLE
	set_process(false)
