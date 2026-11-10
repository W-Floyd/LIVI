class_name EvScene
extends Node3D
## The "Electric vehicle" page's 3D scene: the range road in perspective with the car on it
## and the charger's pin, under a fixed camera. Lit length, markers and the pin follow the data
## (`set_state`), eased unless motion is reduced. The 2D layer reads positions back with
## `screen()`; the page mirrors for a right-hand drive by reflecting the world across the
## camera's vertical plane, so the scene is the screen's mirror image.
##
## Units: one per metre of the car at 2x, `UPK` per km of range. The camera was fitted to the
## stock screen's road: the edges, the far end and the 50 km markers.

signal moved

static var UPK := 0.146
static var HALF_W := 4.55
## The road narrows with distance beyond what the lens does, to the stock screen's far end: by
## ROAD_TAPER of its width at ROAD_TAPER_KM.
static var ROAD_TAPER := 0.5
static var ROAD_TAPER_KM := 253.0
const CAR_Z := 1.2
const CAR_X := 1.6
const CAR_SCALE := 1.9
const CAR_FRONT := CAR_X + EvCar.LENGTH / 2.0 * CAR_SCALE
## A charger closer than this ahead of the nose is drawn this far ahead: it is the same place
## at this scale, and it would sit inside the car.
const PIN_MIN_AHEAD := 0.9
const ROAD_MAX_KM := 520.0
## Fitted to the stock screen by overlaying its render in the live page (scripts/live.sh): the camera looks at the car from its
## left and a little behind. CAM_YAW is from the side view (90 is straight along the road), with a
## mid-length lens (little warping of the car). The car sits at CAR_NDC on the screen, in
## half-heights from the center, by shifting the frustum.
const NEAR := 0.5
const CAR_AIM := Vector3(CAR_X, 0.6, CAR_Z)
static var CAM_YAW := 22.7
static var CAM_PITCH := 19.9
static var CAM_DIST := 54.3
static var CAM_FOV := 16.3
static var CAR_NDC := Vector2(-1.779, -0.337)
const TICK_KM := 50.0
## Under this the end of the lit road turns to the warning color, over its last WARN_KM.
const LOW_RANGE_KM := 50.0
const WARN_KM := 25.0
const EASE_S := 0.6

var km_on := 0.0:
	set(v):
		km_on = v
		_push()
var km_off := 0.0:
	set(v):
		km_off = v
		_push()
## The charger's distance in km; negative for none.
var stop_km := -1.0:
	set(v):
		stop_km = v
		_push()
## The charge, 0 to 1.
var charge := 0.0:
	set(v):
		charge = v
		_push()
## Where the charger's pin stands: past what the range reaches, it is the warning color.
var stop_unreachable := false

var _camera: Camera3D
var _rig: Node3D
var _road: MeshInstance3D
var _road_mat := ShaderMaterial.new()
var _car: EvCar
var _pin: Node3D
var _pin_body := StandardMaterial3D.new()
var _pin_base := Color.WHITE
var _plug: Sprite3D
var _beam: MeshInstance3D
var _beam_mat := ShaderMaterial.new()
var _blob: MeshInstance3D
var _key: DirectionalLight3D
var _fill: DirectionalLight3D
var _under: OmniLight3D
var _env: WorldEnvironment
var _tween: Tween
var _msaa_before := -1
var _lift := Vector2.ZERO


func _ready() -> void:
	_camera = Camera3D.new()
	_camera.name = "Camera"
	_camera.near = NEAR
	_camera.far = 700.0
	# A frustum, so the picture can be shifted without turning the camera.
	_camera.projection = Camera3D.PROJECTION_FRUSTUM
	_camera.keep_aspect = Camera3D.KEEP_HEIGHT
	add_child(_camera)
	_camera.current = true
	_rig = Node3D.new()
	_rig.name = "World"
	add_child(_rig)

	_road_mat.shader = preload("ev_road.gdshader")
	_road_mat.render_priority = -2
	_road = MeshInstance3D.new()
	_road.name = "Road"
	_road.mesh = PlaneMesh.new()
	_road.material_override = _road_mat
	_road.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_rig.add_child(_road)
	_road_mat.set_shader_parameter("tick_km", TICK_KM)

	_blob = MeshInstance3D.new()
	_blob.name = "Shadow"
	var quad := QuadMesh.new()
	quad.size = Vector2(10.0, 5.0)
	_blob.mesh = quad
	_blob.rotation_degrees.x = -90
	_blob.position = Vector3(CAR_X, 0.02, CAR_Z)
	var blob_mat := ShaderMaterial.new()
	blob_mat.shader = preload("ev_blob.gdshader")
	blob_mat.render_priority = -1
	_blob.material_override = blob_mat
	_blob.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_rig.add_child(_blob)

	_car = EvCar.new()
	_car.name = "Car"
	_car.position = Vector3(CAR_X, 0, CAR_Z)
	_car.scale = Vector3.ONE * CAR_SCALE
	_rig.add_child(_car)
	_build_pin()

	_key = DirectionalLight3D.new()
	_key.name = "Key"
	_key.rotation_degrees = Vector3(-48, -40, 0)
	add_child(_key)
	_fill = DirectionalLight3D.new()
	_fill.name = "Fill"
	_fill.rotation_degrees = Vector3(-20, 150, 0)
	add_child(_fill)
	_under = OmniLight3D.new()
	_under.name = "Under"
	_under.omni_range = 9.0
	_under.position = Vector3(CAR_X, 0.7, CAR_Z)
	_rig.add_child(_under)
	_env = WorldEnvironment.new()
	add_child(_env)
	ThemeManager.changed.connect(restyle)
	_apply_view()
	restyle()
	_push()


## Bumped when a view value below changes; a scene in the tree re-fits itself.
static var version := 0
var _version := 0


func _process(_delta: float) -> void:
	if _version != version:
		_apply_view()
		_push()


## The camera, the road's shape and what depends on `UPK`, from the view values.
func _apply_view() -> void:
	_version = version
	_camera.size = 2.0 * NEAR * tan(deg_to_rad(CAM_FOV) / 2.0)
	_camera.look_at_from_position(cam_pos(), cam_pos() + _forward() * 50.0)
	_camera.frustum_offset = _base_offset() + _lift
	var plane: PlaneMesh = _road.mesh
	var x0 := -24.0
	var x1 := ROAD_MAX_KM * UPK
	plane.size = Vector2(x1 - x0, HALF_W * 2.0 * 1.8)
	plane.center_offset = Vector3((x0 + x1) / 2.0, 0, 0)
	_road_mat.set_shader_parameter("upk", UPK)
	_road_mat.set_shader_parameter("half_w", HALF_W)
	_road_mat.set_shader_parameter("taper", ROAD_TAPER)
	_road_mat.set_shader_parameter("taper_len", ROAD_TAPER_KM * UPK)
	_mirror()
	moved.emit()


## Every view value a tool may change: key, label, range and the line of code it stands for.
static func tunables() -> Array:
	return [
		{key = "cam_yaw", label = "Yaw", min = -90.0, max = 90.0, step = 0.1, value = CAM_YAW, code = "static var CAM_YAW := %v"},
		{key = "cam_pitch", label = "Pitch", min = 0.0, max = 60.0, step = 0.1, value = CAM_PITCH, code = "static var CAM_PITCH := %v"},
		{key = "cam_fov", label = "Lens", min = 5.0, max = 80.0, step = 0.1, value = CAM_FOV, code = "static var CAM_FOV := %v"},
		{key = "cam_dist", label = "Distance", min = 5.0, max = 150.0, step = 0.1, value = CAM_DIST, code = "static var CAM_DIST := %v"},
		{key = "car_x", label = "Car x", min = -3.0, max = 3.0, step = 0.005, value = CAR_NDC.x, code = "static var CAR_NDC := Vector2(%v, CAR_Y)"},
		{key = "car_y", label = "Car y", min = -1.5, max = 1.5, step = 0.005, value = CAR_NDC.y, code = "# CAR_Y = %v"},
		{key = "upk", label = "Units per km", min = 0.05, max = 0.5, step = 0.001, value = UPK, code = "static var UPK := %v"},
		{key = "road_w", label = "Road half width", min = 1.0, max = 8.0, step = 0.05, value = HALF_W, code = "static var HALF_W := %v"},
		{key = "road_taper", label = "Road taper", min = 0.0, max = 0.95, step = 0.01, value = ROAD_TAPER, code = "static var ROAD_TAPER := %v"},
		{key = "road_taper_km", label = "Taper over km", min = 50.0, max = 520.0, step = 1.0, value = ROAD_TAPER_KM, code = "static var ROAD_TAPER_KM := %v"},
	]


static func tune(key: String, v: float) -> bool:
	match key:
		"cam_yaw": CAM_YAW = v
		"cam_pitch": CAM_PITCH = v
		"cam_fov": CAM_FOV = v
		"cam_dist": CAM_DIST = v
		"car_x": CAR_NDC.x = v
		"car_y": CAR_NDC.y = v
		"upk": UPK = v
		"road_w": HALF_W = v
		"road_taper": ROAD_TAPER = v
		"road_taper_km": ROAD_TAPER_KM = v
		_: return false
	version += 1
	return true


func _exit_tree() -> void:
	if _msaa_before >= 0 and get_viewport():
		get_viewport().msaa_3d = _msaa_before as Viewport.MSAA


static func cam_pos() -> Vector3:
	return CAR_AIM - _forward() * CAM_DIST


## The frustum shift that puts the car (on the optical axis) at CAR_NDC.
static func _base_offset() -> Vector2:
	return -CAR_NDC * tan(deg_to_rad(CAM_FOV) / 2.0) * NEAR


static func _forward() -> Vector3:
	var yaw := deg_to_rad(CAM_YAW)
	var pitch := deg_to_rad(CAM_PITCH)
	return Vector3(sin(yaw) * cos(pitch), -sin(pitch), -cos(yaw) * cos(pitch))


func _build_pin() -> void:
	_pin = Node3D.new()
	_pin.name = "Charger"
	_rig.add_child(_pin)
	_pin_body.metallic = 0.25
	_pin_body.roughness = 0.35
	var head := MeshInstance3D.new()
	var ball := SphereMesh.new()
	ball.radius = 0.7
	ball.height = 1.4
	ball.radial_segments = 24
	ball.rings = 12
	head.mesh = ball
	head.position.y = 2.25
	var tip := MeshInstance3D.new()
	var cone := CylinderMesh.new()
	cone.top_radius = 0.7
	cone.bottom_radius = 0.0
	cone.height = 1.5
	cone.radial_segments = 24
	cone.rings = 1
	tip.mesh = cone
	tip.position.y = 1.2
	for m in [head, tip]:
		m.material_override = _pin_body
		m.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		_pin.add_child(m)
	_plug = Sprite3D.new()
	_plug.name = "Plug"
	_plug.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_plug.shaded = false
	_plug.no_depth_test = true
	_plug.render_priority = 3
	_plug.position = Vector3(0, 2.25, 0)
	_pin.add_child(_plug)
	_beam = MeshInstance3D.new()
	_beam.name = "Beam"
	var b := CylinderMesh.new()
	b.top_radius = 0.45
	b.bottom_radius = 2.0
	b.height = 2.4
	b.radial_segments = 20
	b.rings = 1
	b.cap_top = false
	b.cap_bottom = false
	_beam.mesh = b
	_beam.position.y = 1.2
	_beam_mat.shader = preload("ev_beam.gdshader")
	_beam_mat.render_priority = 2
	_beam_mat.set_shader_parameter("height", 2.4)
	_beam.material_override = _beam_mat
	_beam.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_pin.add_child(_beam)


## Colors and light from the theme, and what the quality profile allows: `low` drops the fill
## and under-car lights, the sky's reflections and multisampling.
func restyle() -> void:
	if _env == null:
		return
	var c: Dictionary = ThemeManager.c
	var day := ThemeManager.appearance == "day"
	var low := ThemeManager.quality == "low"
	var accent: Color = c.accent
	var lit: Color = c.get("road", accent.darkened(0.15) if not day else accent.lightened(0.12))
	# A theme that names its road gets it as given; otherwise it is accent light over the page.
	lit.a = 1.0 if c.has("road") else (0.92 if not day else 0.85)
	var far: Color = c.get("road_far", lit.lerp(c.bg if day else Color.WHITE, 0.55))
	if not c.has("road_far"):
		far.a = 0.9
	_road_mat.set_shader_parameter("c_lit", lit)
	_road_mat.set_shader_parameter("c_far", far)
	_road_mat.set_shader_parameter("c_warn", c.warn)
	_road_mat.set_shader_parameter("c_line", Color.WHITE)
	_road_mat.set_shader_parameter("c_stop", Color(1, 1, 1, 0.85))
	_road_mat.set_shader_parameter("glow", 0.12 if day else 0.5)
	var glass: Color = Color.WHITE if day else (c.text as Color).lerp(c.bg, 0.25)
	var rim: Color = (c.dim as Color) if day else (c.text as Color).lerp(accent, 0.2)
	_car.style(glass, rim, accent, (c.text as Color).lerp(c.bg, 0.45 if not day else 0.1), day, low)
	_pin_base = Color(0.97, 0.98, 1.0) if day else (c.text as Color).lerp(c.bg, 0.4)
	_pin_body.emission_enabled = true
	_pin_body.emission_energy_multiplier = 0.15
	_plug.texture = Icons.texture("plug", 128)
	_plug.pixel_size = 0.72 / 128.0
	_plug.modulate = c.bg if not day else (c.text as Color).darkened(0.2)
	_beam_mat.set_shader_parameter("color", Color(1, 1, 1, 0.22 if not day else 0.16))
	(_blob.material_override as ShaderMaterial).set_shader_parameter("strength", 0.55 if not day else 0.28)

	var e := Environment.new()
	e.background_mode = Environment.BG_COLOR
	e.background_color = c.bg
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = (c.text as Color).lerp(c.bg, 0.7 if not day else 0.2)
	e.ambient_light_energy = 0.55 if not day else 0.9
	if low:
		e.reflected_light_source = Environment.REFLECTION_SOURCE_DISABLED
	else:
		var sky := Sky.new()
		var sm := ProceduralSkyMaterial.new()
		sm.sky_top_color = (c.text as Color).lerp(c.bg, 0.55) if not day else Color(0.8, 0.88, 0.97)
		sm.sky_horizon_color = (c.text as Color).lerp(c.bg, 0.75) if not day else Color(0.95, 0.97, 1.0)
		sm.ground_horizon_color = sm.sky_horizon_color
		sm.ground_bottom_color = c.bg
		sky.sky_material = sm
		sky.radiance_size = Sky.RADIANCE_SIZE_64
		e.sky = sky
		e.reflected_light_source = Environment.REFLECTION_SOURCE_SKY
	_env.environment = e
	_key.light_color = Color(1.0, 0.97, 0.92) if day else Color(0.8, 0.88, 1.0)
	_key.light_energy = 1.1 if day else 1.0
	_fill.visible = not low
	_fill.light_color = accent.lerp(Color.WHITE, 0.5)
	_fill.light_energy = 0.35
	_under.visible = not low
	_under.light_color = accent
	_under.light_energy = 0.0 if day else 1.2
	var vp := get_viewport()
	if vp:
		if _msaa_before < 0:
			_msaa_before = vp.msaa_3d
		vp.msaa_3d = Viewport.MSAA_DISABLED if low else Viewport.MSAA_2X
	_mirror()
	_push()


## Reflects the world across the camera's vertical plane for a right-hand drive.
func _mirror() -> void:
	if _rig == null:
		return
	if ThemeManager.hand != "rhd":
		_rig.transform = Transform3D.IDENTITY
		return
	# Mirror about the vertical plane through the camera and the screen's center line, which the
	# frustum shift has moved off the optical axis.
	var r := _camera.global_transform.basis.x - _forward() * (_base_offset().x / NEAR)
	r = r.normalized()
	var b := Basis(
		Vector3(1.0 - 2.0 * r.x * r.x, -2.0 * r.x * r.y, -2.0 * r.x * r.z),
		Vector3(-2.0 * r.y * r.x, 1.0 - 2.0 * r.y * r.y, -2.0 * r.y * r.z),
		Vector3(-2.0 * r.z * r.x, -2.0 * r.z * r.y, 1.0 - 2.0 * r.z * r.z))
	_rig.transform = Transform3D(b, 2.0 * cam_pos().dot(r) * r)


## The range with climate on and off, the charger's distance and the charge, all in
## kilometres and 0 to 1; a negative `charger` for none. Eased from where they are unless
## `animate` is false or motion is reduced.
func set_state(on: float, off: float, charger: float, soc: float, animate := true) -> void:
	if _tween:
		_tween.kill()
		_tween = null
	var want := {km_on = on, km_off = maxf(off, on), stop_km = charger, charge = soc}
	if not animate or ThemeManager.reduced_motion or not is_inside_tree():
		for k in want:
			set(k, want[k])
		return
	# A charger appearing or going is not eased: there is nothing to move from or to.
	if (stop_km < 0.0) != (charger < 0.0):
		stop_km = charger
	_tween = create_tween().set_parallel().set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	for k in want:
		_tween.tween_property(self, NodePath(k), want[k], EASE_S)


## Where the pin stands, in the world's units along the road.
func pin_x() -> float:
	var x := maxf(stop_km * UPK, CAR_FRONT + PIN_MIN_AHEAD)
	return minf(x, maxf(km_off * UPK, CAR_FRONT + PIN_MIN_AHEAD))


func _push() -> void:
	if _road == null:
		return
	var low_range := km_on <= LOW_RANGE_KM
	_road_mat.set_shader_parameter("km_on", km_on)
	_road_mat.set_shader_parameter("km_off", km_off)
	_road_mat.set_shader_parameter("km_warn", maxf(km_on - WARN_KM, 0.0) if low_range else 1.0e6)
	var show_pin := stop_km >= 0.0
	_pin.visible = show_pin
	stop_unreachable = show_pin and stop_km > km_off
	var x := pin_x()
	_pin.position.x = x
	_road_mat.set_shader_parameter("stop_x", x if show_pin else -1000.0)
	var c: Dictionary = ThemeManager.c
	var pin_color: Color = c.warn if stop_unreachable else _pin_base
	_road_mat.set_shader_parameter("c_stop", Color(pin_color.r, pin_color.g, pin_color.b, 0.9) if stop_unreachable else Color(1, 1, 1, 0.85))
	_pin_body.albedo_color = pin_color
	_pin_body.emission = pin_color
	_car.set_charge(charge)
	moved.emit()


## Moves the picture up by `px` panel pixels, to keep it clear of a taller control row.
func lift(px: float) -> void:
	_lift = Vector2(0.0, -px / get_viewport().get_visible_rect().size.y * _camera.size)
	_camera.frustum_offset = _base_offset() + _lift
	moved.emit()


## A point of the world, as a panel pixel.
func screen(world: Vector3) -> Vector2:
	return _camera.unproject_position(_rig.to_global(world))


## Anchors for the 2D layer, as panel pixels: where the lit road ends and where the far end
## is, on the near edge and on the far edge (`*_far`), the pin's head, and a spot on the car's
## flank for the charge.
## The road's half width at `x` along it.
static func road_half(x: float) -> float:
	return HALF_W * (1.0 - ROAD_TAPER * clampf(x / (ROAD_TAPER_KM * UPK), 0.0, 1.0))


func anchors() -> Dictionary:
	return {
		on = screen(Vector3(km_on * UPK, 0, road_half(km_on * UPK))),
		off = screen(Vector3(km_off * UPK, 0, road_half(km_off * UPK))),
		on_far = screen(Vector3(km_on * UPK, 0, -road_half(km_on * UPK))),
		off_far = screen(Vector3(km_off * UPK, 0, -road_half(km_off * UPK))),
		pin = screen(Vector3(pin_x(), 3.0, 0)),
		car = screen(Vector3(CAR_X - 0.9, 3.0, CAR_Z)),
	}
