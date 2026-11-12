class_name WindowView
extends TextureRect
## Shows one Wayland window and passes it what happens over it: pointer, touch and keys, in
## the window's own surface coordinates (letterboxing included).

## The compositor's window id; -1 for none.
var window_id := -1:
	set(v):
		window_id = v
		_show()

var _pointer_inside := false
## The window is projection video: touches go to the phone through the core, as points over the
## picture (the phone's visible area) from 0 to 1, not to the window, which takes no input. It
## shows the video at its own size (`Wayland.set_native`) cut to the visible area, so on a panel
## the size of the core's projection screen it is 1:1.
var to_core := false:
	set(v):
		to_core = v
		_show()

## The window's own texture, and while `to_core` the visible area of it, which is what shows.
var _raw: Texture2D
var _crop: AtlasTexture
var _cropped_size := Vector2.ZERO
## The part of the visible area shown, from 0 to 1: this view's own place on the panel while the
## phone lays its UI out for exactly that (`/sessions/area`), so it shows 1:1; else all of it,
## letterboxed, as for a phone that does not take an area.
var _region := Rect2(0, 0, 1, 1)
## While the view is resized ahead of its window (home's divider dragged): the window's last
## picture, and the phone's last area of it, scaled to cover the view and cut rather than
## letterboxed, until the window has the view's shape again (`release_hold`).
var hold := false:
	set(v):
		if v == hold:
			return
		hold = v
		_hold_n += 1
		_releasing = false
		stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED if v else TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		if _raw and _raw.changed.is_connected(_check_hold) != v:
			if v:
				_raw.changed.connect(_check_hold)
			else:
				_raw.changed.disconnect(_check_hold)
		if not v:
			_fit_crop(true)
var _hold_n := 0
var _releasing := false
## A window that never takes the view's shape (a phone refusing the area) is letterboxed after this.
const HOLD_S := 2.0


func _init() -> void:
	expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	mouse_filter = Control.MOUSE_FILTER_STOP
	focus_mode = Control.FOCUS_ALL


func _ready() -> void:
	Core.changed.connect(func(sections): if sections.has("config") or sections.has("sessions"): _fit_crop(true))
	resized.connect(_fit_crop.bind(true))
	set_notify_transform(true)


## The part of a `stream`-sized projection frame that the phone fills for a `screen`-sized
## projection screen: the centred area of the screen's shape, as livi-media's `crop_for` computes
## it. The core maps touches over this area into the stream (`android_auto::to_stream`).
static func projection_crop(stream: Vector2, screen: Vector2) -> Rect2:
	if stream.x <= 0 or stream.y <= 0 or screen.x <= 0 or screen.y <= 0:
		return Rect2(Vector2.ZERO, stream)
	var even := func(v: float) -> float: return maxf(float(int(floor(v)) & ~1), 2.0)
	var screen_ar := screen.x / screen.y
	var c := Vector2(even.call(stream.y * screen_ar), stream.y) if screen_ar <= stream.x / stream.y \
		else Vector2(stream.x, even.call(stream.x / screen_ar))
	return Rect2(((stream - c) / 2.0).max(Vector2.ZERO), c)


func _show() -> void:
	hold = false
	if _raw and _raw.changed.is_connected(_fit_crop):
		_raw.changed.disconnect(_fit_crop)
	_raw = Wayland.texture(window_id) if window_id >= 0 else null
	if _raw == null or not to_core:
		texture = _raw
		return
	Wayland.set_native(window_id, true)
	_crop = AtlasTexture.new()
	_crop.atlas = _raw
	_raw.changed.connect(_fit_crop)
	_fit_crop(true)
	texture = _crop


## Again when the video's size changes (the phone's resolution tier), not every frame.
func _fit_crop(force := false) -> void:
	if _crop == null or _raw == null or (_raw.get_size() == _cropped_size and not force):
		return
	_cropped_size = _raw.get_size()
	var visible_area := projection_crop(_cropped_size, _projection_screen())
	var region := _shown_region()
	# Held, the phone's last area until it takes the view's.
	if not hold or region != Rect2(0, 0, 1, 1):
		_region = region
	# Whole pixels: AtlasTexture's size truncates, so 911.9999 would be a pixel short.
	var from := (visible_area.position + _region.position * visible_area.size).round()
	_crop.region = Rect2(from, (visible_area.position + _region.end * visible_area.size).round() - from)
	_check_hold()


## Ends `hold` once the window's picture has the view's shape, or after HOLD_S.
func release_hold() -> void:
	if not hold or _releasing:
		return
	_releasing = true
	var n := _hold_n
	get_tree().create_timer(HOLD_S).timeout.connect(func(): if n == _hold_n: hold = false)
	_check_hold()


func _check_hold() -> void:
	if not _releasing or texture == null or size.x <= 0.0:
		return
	var t := texture.get_size()
	if t.x > 0.0 and absf(t.y * size.x / t.x - size.y) <= 1.0:
		hold = false


## The core's projection screen size, which its crop and touch mapping use; else the panel's.
func _projection_screen() -> Vector2:
	var w = Core.get_value("/config/projectionWidth")
	var h = Core.get_value("/config/projectionHeight")
	if w != null and h != null and w > 0 and h > 0:
		return Vector2(w, h)
	return get_viewport_rect().size


## `r`, a rectangle of the panel, in the projection screen's pixels: what the core's
## `projectionArea` takes.
func to_screen(r: Rect2) -> Rect2i:
	var s := _projection_screen() / get_viewport_rect().size
	var from := (r.position * s).round()
	return Rect2i(Vector2i(from), Vector2i((r.end * s).round() - from))


func _shown_region() -> Rect2:
	var all := Rect2(0, 0, 1, 1)
	var a = Core.get_value("/sessions/area")
	if not to_core or not a is Dictionary or not is_inside_tree():
		return all
	var mine := to_screen(get_global_rect())
	var took := Rect2i(int(a.x), int(a.y), int(a.width), int(a.height))
	if mine != took:
		return all
	var screen := _projection_screen()
	return Rect2(Vector2(mine.position) / screen, Vector2(mine.size) / screen).intersection(all)


## Where the picture is drawn in the view: the texture fitted and centred.
func picture_rect() -> Rect2:
	if texture == null:
		return Rect2(Vector2.ZERO, size)
	var tex := texture.get_size()
	var s: float = max(size.x / tex.x, size.y / tex.y) if stretch_mode == STRETCH_KEEP_ASPECT_COVERED else min(size.x / tex.x, size.y / tex.y)
	return Rect2((size - tex * s) / 2.0, tex * s)


## Where `local` falls on the window's surface, or null outside the picture.
func to_surface(local: Vector2) -> Variant:
	if texture == null:
		return null
	var r := picture_rect()
	var tex := texture.get_size()
	var p := (local - r.position) * tex / r.size
	if p.x < 0 or p.y < 0 or p.x >= tex.x or p.y >= tex.y:
		return null
	return p


func _gui_input(event: InputEvent) -> void:
	if window_id < 0:
		return
	if to_core:
		_core_input(event)
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


## Touches when they reach the view; else the mouse, as one finger (a mouse in the VM, or touch
## that only arrives as Godot's emulated mouse).
var _touch_seen := false


func _core_input(event: InputEvent) -> void:
	if event is InputEventScreenTouch:
		_touch_seen = true
		_to_core(event.index, event.position, "cancel" if event.canceled else "down" if event.pressed else "up")
	elif event is InputEventScreenDrag:
		_touch_seen = true
		_to_core(event.index, event.position, "move")
	elif _touch_seen:
		return
	elif event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		_to_core(0, event.position, "down" if event.pressed else "up")
	elif event is InputEventMouseMotion and event.button_mask & MOUSE_BUTTON_MASK_LEFT:
		_to_core(0, event.position, "move")
	else:
		return
	accept_event()


## The point goes over the whole visible area, as the core maps it into the stream.
func _to_core(index: int, at: Vector2, phase: String) -> void:
	var r := picture_rect()
	var p: Vector2 = _region.position + ((at - r.position) / r.size).clamp(Vector2.ZERO, Vector2.ONE) * _region.size
	var err: String = Core.input({kind = "pointer", screen = "main", points = [{id = index, x = p.x, y = p.y, phase = phase}]})
	if err != "":
		push_warning("projection touch: %s" % err)


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


## Keyboard focus to the window, as a tap on it gives.
func focus_app() -> void:
	if window_id >= 0:
		_focus()


func _notification(what: int) -> void:
	match what:
		NOTIFICATION_TRANSFORM_CHANGED:
			_fit_crop(true)
		NOTIFICATION_MOUSE_EXIT:
			if _pointer_inside:
				_pointer_inside = false
				Wayland.pointer_motion(-1, 0, 0)
		NOTIFICATION_FOCUS_EXIT:
			Wayland.keyboard_focus(-1)
