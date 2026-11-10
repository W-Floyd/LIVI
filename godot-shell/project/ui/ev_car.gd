class_name EvCar
extends Node3D
## A stylised electric crossover built from meshes, no outside model: a translucent shell
## lofted from a side profile, over a battery block that fills with the charge, four wheels, a
## dark floor plate and the headlamps. 4.7 units long, nose toward +x, standing on y = 0.

const LENGTH := 4.7
const HALF_W := 0.93
const SECTIONS := 72
const AROUND := 32
## Side profile of the roof line: x, height. Eased between the keys, so it reads as one curve.
const ROOF := [[-2.35, 0.7], [-2.15, 1.05], [-1.55, 1.55], [-0.55, 1.88], [0.15, 1.78], [0.95, 1.2], [1.9, 0.92], [2.35, 0.62]]
const WHEEL_X := 1.4
const WHEEL_Z := 0.74
const WHEEL_R := 0.42
const BATTERY := Vector3(2.9, 0.15, 1.5)
const BATTERY_Y := 0.31

var _shell: MeshInstance3D
var _battery: MeshInstance3D
var _glass := ShaderMaterial.new()
var _cell := ShaderMaterial.new()
var _tire := StandardMaterial3D.new()
var _rim := StandardMaterial3D.new()
var _plate := StandardMaterial3D.new()
var _lamp := StandardMaterial3D.new()


func _init() -> void:
	_glass.shader = preload("ev_glass.gdshader")
	_cell.shader = preload("ev_battery.gdshader")
	_cell.set_shader_parameter("x_min", -BATTERY.x / 2.0)
	_cell.set_shader_parameter("x_len", BATTERY.x)
	_tire.albedo_color = Color(0.05, 0.05, 0.06)
	_tire.roughness = 0.85
	_rim.metallic = 0.9
	_rim.roughness = 0.28
	_plate.albedo_color = Color(0.08, 0.09, 0.1)
	_plate.metallic = 0.6
	_plate.roughness = 0.5
	_lamp.emission_enabled = true
	_lamp.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_shell = MeshInstance3D.new()
	_shell.name = "Shell"
	var model := load_model(ThemeManager.car)
	_shell.mesh = model if model else _body()
	_shell.material_override = _glass
	_shell.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	# After the road and the contact shadow, which it is seen over.
	_glass.render_priority = 1
	add_child(_shell)
	_battery = _box("Battery", BATTERY, Vector3(0.1, BATTERY_Y, 0), _cell)
	if not model:
		_box("Floor", Vector3(3.5, 0.05, 1.62), Vector3(0.05, 0.2, 0), _plate)
	for sx in [-1, 1]:
		for sz in [-1, 1]:
			_wheel(Vector3(sx * WHEEL_X, WHEEL_R, sz * WHEEL_Z))
	for sz in [-1, 1]:
		if model:
			break
		_box("Lamp", Vector3(0.05, 0.05, 0.42), Vector3(2.0, 0.7, sz * 0.5), _lamp)


## `car.mesh` (tools/car-mesh) from `$LIVI_SHELL_CAR` or the user's data folder, as a mesh with
## smooth normals; null when `choice` is "procedural" or there is no such file.
static func load_model(choice: String) -> ArrayMesh:
	if choice == "procedural":
		return null
	var path := OS.get_environment("LIVI_SHELL_CAR")
	if path == "":
		path = OS.get_environment("HOME").path_join(".local/share/livi-shell/car.mesh")
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null or f.get_buffer(4).get_string_from_ascii() != "LCAR":
		return null
	var nv := f.get_32()
	var ni := f.get_32()
	var verts := f.get_buffer(nv * 12).to_float32_array()
	var idx := f.get_buffer(ni * 4).to_int32_array()
	if verts.size() != nv * 3 or idx.size() != ni:
		return null
	var pts := PackedVector3Array()
	pts.resize(nv)
	for i in nv:
		pts[i] = Vector3(verts[i * 3], verts[i * 3 + 1], verts[i * 3 + 2])
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	st.set_smooth_group(0)
	for i in range(0, ni, 3):
		# The shell is seen from outside; Godot's front faces are clockwise.
		for k in [0, 2, 1]:
			st.add_vertex(pts[idx[i + k]])
	st.generate_normals()
	return st.commit()


## The charge as 0..1; negative when unknown (an empty block).
func set_charge(fraction: float) -> void:
	_cell.set_shader_parameter("fill", clampf(fraction, 0.0, 1.0))


## Colors and light for the theme: `glass` the shell's tint, `rim` its edge, `accent` the
## battery and lamps, `empty` the uncharged cells; `day` is for a pale daytime shell.
func style(glass: Color, rim: Color, accent: Color, empty: Color, day: bool, low: bool) -> void:
	_glass.set_shader_parameter("tint", glass)
	_glass.set_shader_parameter("rim_color", rim)
	_glass.set_shader_parameter("base_alpha", 0.34 if day else 0.24)
	_glass.set_shader_parameter("rim_alpha", 0.6 if day else 0.7)
	_glass.set_shader_parameter("rim_glow", 0.0 if day else 0.9)
	_cell.set_shader_parameter("c_fill", accent)
	_cell.set_shader_parameter("c_empty", empty)
	_cell.set_shader_parameter("glow", 0.8 if day else 1.1)
	_rim.albedo_color = Color(0.8, 0.82, 0.85) if day else Color(0.62, 0.66, 0.72)
	_lamp.albedo_color = Color(1, 1, 1)
	_lamp.emission = accent.lerp(Color.WHITE, 0.6)
	_lamp.emission_energy_multiplier = 1.4
	_glass.set_shader_parameter("rim_power", 2.2 if low else 2.6)


func _box(node_name: String, size: Vector3, at: Vector3, mat: Material) -> MeshInstance3D:
	var m := MeshInstance3D.new()
	m.name = node_name
	var b := BoxMesh.new()
	b.size = size
	m.mesh = b
	m.position = at
	m.material_override = mat
	m.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(m)
	return m


func _wheel(at: Vector3) -> void:
	var w := Node3D.new()
	w.name = "Wheel"
	w.position = at
	# Cylinders stand on y; the axle goes along z.
	w.rotation_degrees.x = 90
	var tire := CylinderMesh.new()
	tire.top_radius = WHEEL_R
	tire.bottom_radius = WHEEL_R
	tire.height = 0.26
	tire.radial_segments = 24
	tire.rings = 1
	var rim := CylinderMesh.new()
	rim.top_radius = 0.24
	rim.bottom_radius = 0.24
	rim.height = 0.28
	rim.radial_segments = 20
	rim.rings = 1
	for pair in [[tire, _tire], [rim, _rim]]:
		var m := MeshInstance3D.new()
		m.mesh = pair[0]
		m.material_override = pair[1]
		m.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		w.add_child(m)
	add_child(w)


static func _roof(x: float) -> float:
	for i in ROOF.size() - 1:
		var a: Array = ROOF[i]
		var b: Array = ROOF[i + 1]
		if x <= b[0]:
			var t := clampf((x - a[0]) / (b[0] - a[0]), 0.0, 1.0)
			return lerpf(a[1], b[1], t * t * (3.0 - 2.0 * t))
	return ROOF[-1][1]


## The shell: a rounded section swept along the profile, closing to a point at the nose and tail.
static func _body() -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var rows: Array[PackedVector3Array] = []
	for i in SECTIONS:
		# Closer sections at the ends, where the surface turns fastest.
		var x := -LENGTH / 2.0 * cos(PI * i / (SECTIONS - 1))
		var top := _roof(x)
		var bottom := 0.26 + 0.12 * pow(absf(x) / (LENGTH / 2.0), 4.0)
		var round_off := clampf((absf(x) - 1.85) / 0.5, 0.0, 1.0)
		var w := HALF_W * sqrt(maxf(0.0, 1.0 - round_off * round_off))
		var row := PackedVector3Array()
		for j in AROUND:
			var a := TAU * j / AROUND
			var c := cos(a)
			var s := sin(a)
			var sx := signf(c) * pow(absf(c), 2.0 / 2.6)
			var sy := signf(s) * pow(absf(s), 2.0 / 2.6)
			# The cabin narrows toward the roof.
			var z := w * sx * (1.0 - 0.3 * pow(maxf(sy, 0.0), 1.5))
			row.append(Vector3(x, (top + bottom) / 2.0 + (top - bottom) / 2.0 * sy, z))
		rows.append(row)
	for i in SECTIONS - 1:
		for j in AROUND:
			var k := (j + 1) % AROUND
			var p00 := rows[i][j]
			var p01 := rows[i][k]
			var p10 := rows[i + 1][j]
			var p11 := rows[i + 1][k]
			_tri(st, p00, p10, p11)
			_tri(st, p00, p11, p01)
	st.generate_normals()
	return st.commit()


## Wound so the face looks outward, away from the car's axis.
static func _tri(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3) -> void:
	var n := (b - a).cross(c - a)
	if n.length_squared() < 1e-12:
		return
	var center := (a + b + c) / 3.0
	var out := center - Vector3(clampf(center.x, -1.5, 1.5), 0.85, 0.0)
	if n.dot(out) < 0.0:
		var t := b
		b = c
		c = t
	st.add_vertex(a)
	st.add_vertex(b)
	st.add_vertex(c)
