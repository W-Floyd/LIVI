class_name WindowView
extends TextureRect
## Shows one Wayland window and passes it what happens over it: pointer, touch and keys, in
## the window's own surface coordinates (letterboxing included).

## The compositor's window id; -1 for none.
var window_id := -1:
	set(v):
		window_id = v
		texture = Wayland.texture(v) if v >= 0 else null

var _pointer_inside := false


func _init() -> void:
	expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	mouse_filter = Control.MOUSE_FILTER_STOP
	focus_mode = Control.FOCUS_ALL


## Where `local` falls on the window's surface, or null outside the picture.
func to_surface(local: Vector2) -> Variant:
	if texture == null:
		return null
	var tex := texture.get_size()
	var s: float = min(size.x / tex.x, size.y / tex.y)
	var p := (local - (size - tex * s) / 2.0) / s
	if p.x < 0 or p.y < 0 or p.x >= tex.x or p.y >= tex.y:
		return null
	return p


func _gui_input(event: InputEvent) -> void:
	if window_id < 0:
		return
	# Touch arrives twice when Godot emulates the mouse from it; the touch is what counts.
	if event is InputEventMouse and event.device == InputEvent.DEVICE_ID_EMULATION:
		return
	if event is InputEventMouseMotion:
		_move(event.position)
	elif event is InputEventMouseButton:
		_move(event.position)
		if _pointer_inside:
			if event.pressed:
				_focus()
			Wayland.pointer_button(event.button_index, event.pressed)
	elif event is InputEventScreenTouch:
		var p = to_surface(event.position)
		if event.pressed and p != null:
			_focus()
			Wayland.touch_down(window_id, event.index, p.x, p.y)
		elif not event.pressed:
			Wayland.touch_up(event.index)
	elif event is InputEventScreenDrag:
		var p = to_surface(event.position)
		if p != null:
			Wayland.touch_motion(window_id, event.index, p.x, p.y)
	elif event is InputEventKey:
		if not Wayland.key(event.physical_keycode, event.pressed):
			return
	else:
		return
	accept_event()


func _move(local: Vector2) -> void:
	var p = to_surface(local)
	_pointer_inside = p != null
	if p == null:
		Wayland.pointer_motion(-1, 0, 0)
	else:
		Wayland.pointer_motion(window_id, p.x, p.y)


func _focus() -> void:
	grab_focus()
	Wayland.keyboard_focus(window_id)


func _notification(what: int) -> void:
	match what:
		NOTIFICATION_MOUSE_EXIT:
			if _pointer_inside:
				_pointer_inside = false
				Wayland.pointer_motion(-1, 0, 0)
		NOTIFICATION_FOCUS_EXIT:
			Wayland.keyboard_focus(-1)
