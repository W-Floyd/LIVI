class_name SceneSkin
extends Node3D
## A scene theme's 3D layer: a lit dash with a slab behind each surface the 2D layer lays
## out. The camera is orthographic with one world unit per panel pixel, so a slab covers
## exactly its control's rectangle; the controls keep all input, text and layout.

const DEPTH := 18.0
## Close behind the slabs, so their shadows stay tight to them.
const DASH_Z := -12.0

## The controls whose surfaces this skin draws.
var surfaces: Array[Control] = []

var _camera: Camera3D
var _env: WorldEnvironment
var _light: DirectionalLight3D
var _dash: MeshInstance3D
var _slabs := {}           # Control -> MeshInstance3D
var _slab_mat: StandardMaterial3D
var _matte_mat: StandardMaterial3D
var _accent_mat: StandardMaterial3D


func _ready() -> void:
	_camera = Camera3D.new()
	_camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	_camera.keep_aspect = Camera3D.KEEP_HEIGHT
	_camera.near = 1.0
	_camera.far = 4000.0
	add_child(_camera)
	_light = DirectionalLight3D.new()
	_light.shadow_enabled = true
	_light.shadow_blur = 3.0
	_light.shadow_opacity = 0.7
	# From above and a little left, raking across the faces so the grain catches it; slabs
	# cast a short shadow down-right.
	_light.rotation_degrees = Vector3(-24, -18, 0)
	add_child(_light)
	_env = WorldEnvironment.new()
	add_child(_env)
	_dash = MeshInstance3D.new()
	_dash.mesh = QuadMesh.new()
	add_child(_dash)
	ThemeManager.changed.connect(_style)
	_style()


func _style() -> void:
	if not ThemeManager.is_scene():
		return
	var s: Dictionary = ThemeManager.spec.scene[ThemeManager.appearance]
	var e := Environment.new()
	e.background_mode = Environment.BG_COLOR
	e.background_color = Color(s.dash)
	# A sky only for reflections: metal needs something to reflect.
	var sky := Sky.new()
	var sm := ProceduralSkyMaterial.new()
	sm.sky_top_color = Color(s.ambient).lightened(0.3)
	sm.sky_horizon_color = Color(s.ambient)
	sm.ground_bottom_color = Color(s.dash)
	sm.ground_horizon_color = Color(s.ambient).darkened(0.4)
	sky.sky_material = sm
	e.sky = sky
	e.reflected_light_source = Environment.REFLECTION_SOURCE_SKY
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color(s.ambient)
	e.ambient_light_energy = s.ambient_energy
	e.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	_env.environment = e
	_light.light_color = Color(s.key_light)
	_light.light_energy = s.key_energy

	var dash := StandardMaterial3D.new()
	dash.albedo_color = Color(s.dash)
	dash.roughness = 0.78
	dash.normal_enabled = true
	dash.normal_texture = _grain(FastNoiseLite.TYPE_CELLULAR, 0.09, 3.0)
	dash.uv1_scale = Vector3(12, 4.5, 1)
	_dash.material_override = dash

	_slab_mat = StandardMaterial3D.new()
	_slab_mat.albedo_color = Color(s.slab)
	_slab_mat.metallic = s.slab_metallic
	_slab_mat.roughness = s.slab_roughness
	_slab_mat.normal_enabled = true
	# Brushed: noise stretched along x, so the grain runs in lines.
	_slab_mat.normal_texture = _grain(FastNoiseLite.TYPE_SIMPLEX, 0.5, 2.5)
	_slab_mat.normal_scale = 1.6
	_slab_mat.uv1_scale = Vector3(0.5, 30, 1)
	_matte_mat = _slab_mat.duplicate()
	_matte_mat.metallic = 0.25
	_matte_mat.roughness = 0.85
	_accent_mat = StandardMaterial3D.new()
	_accent_mat.albedo_color = ThemeManager.c.accent
	_accent_mat.metallic = 0.4
	_accent_mat.roughness = 0.3
	_accent_mat.emission_enabled = true
	_accent_mat.emission = ThemeManager.c.accent
	_accent_mat.emission_energy_multiplier = 0.35
	for slab in _slabs.values():
		slab.queue_free()
	_slabs.clear()


func _grain(kind: int, frequency: float, strength: float) -> NoiseTexture2D:
	var n := FastNoiseLite.new()
	n.noise_type = kind
	n.frequency = frequency
	var t := NoiseTexture2D.new()
	t.width = 512
	t.height = 512
	t.seamless = true
	t.as_normal_map = true
	t.bump_strength = strength
	t.noise = n
	return t


## Follows the 2D layout every frame: cheap, and a slab never lags its control.
func _process(_delta: float) -> void:
	var view := get_viewport().get_visible_rect().size
	_camera.size = view.y
	_camera.position = Vector3(view.x / 2.0, -view.y / 2.0, 1000)
	_dash.position = Vector3(view.x / 2.0, -view.y / 2.0, DASH_Z)
	(_dash.mesh as QuadMesh).size = view
	for ctl in surfaces:
		var slab: MeshInstance3D = _slabs.get(ctl)
		if slab == null:
			slab = MeshInstance3D.new()
			slab.mesh = BoxMesh.new()
			add_child(slab)
			_slabs[ctl] = slab
		slab.visible = ctl.is_visible_in_tree()
		if not slab.visible:
			continue
		var r := ctl.get_global_rect()
		(slab.mesh as BoxMesh).size = Vector3(r.size.x, r.size.y, DEPTH)
		slab.position = Vector3(r.get_center().x, -r.get_center().y, 0)
		var lit := ctl is BaseButton and (ctl as BaseButton).button_pressed
		# The status bar is a long strip: a mirror finish catches a hotspot across its text.
		slab.material_override = _accent_mat if lit else (_matte_mat if ctl is StatusBar else _slab_mat)
