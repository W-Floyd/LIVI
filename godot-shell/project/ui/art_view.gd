class_name ArtView
extends Control
## A cover, cropped to fill, in rounded corners; without one, the theme's placeholder with a
## note. A new cover fades in over the old unless motion is reduced.

const FADE_S := 0.25

## The note's share of the placeholder's shorter side.
const NOTE_SHARE := 0.5

static var _shader: Shader

var texture: Texture2D:
	set(v):
		if v == texture:
			return
		_old = texture
		texture = v
		_fade()
## Over the placeholder instead of the note (a station's initials).
var initials := "":
	set(v):
		initials = v
		queue_redraw()
## The placeholder's fill; the theme's surface2 when unset.
var fill := Color(0, 0, 0, 0):
	set(v):
		fill = v
		queue_redraw()
var radius := -1.0:
	set(v):
		radius = v
		_shape()

var _old: Texture2D
var _mix := 1.0
var _tween: Tween


func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	if _shader == null:
		_shader = Shader.new()
		# Masks everything drawn to a rounded rect of `size`, in the control's own pixels.
		_shader.code = """shader_type canvas_item;
uniform vec2 size;
uniform float radius;
varying vec2 local;
void vertex() { local = VERTEX; }
void fragment() {
	vec2 q = abs(local - size * 0.5) - (size * 0.5 - vec2(radius));
	float d = length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - radius;
	COLOR.a *= clamp(0.5 - d, 0.0, 1.0);
}"""
	var m := ShaderMaterial.new()
	m.shader = _shader
	material = m
	texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	resized.connect(_shape)


func _ready() -> void:
	ThemeManager.changed.connect(_shape)
	_shape()


func _shape() -> void:
	var r := radius if radius >= 0.0 else float(ThemeManager.px.radius) * 1.5
	(material as ShaderMaterial).set_shader_parameter("size", size)
	(material as ShaderMaterial).set_shader_parameter("radius", minf(r, minf(size.x, size.y) / 2.0))
	queue_redraw()


func _fade() -> void:
	if _tween:
		_tween.kill()
	if ThemeManager.reduced_motion or not is_visible_in_tree() or _old == texture:
		_mix = 1.0
		_old = null
		queue_redraw()
		return
	_mix = 0.0
	_tween = create_tween()
	_tween.tween_method(_set_mix, 0.0, 1.0, FADE_S)
	_tween.finished.connect(func(): _old = null; _tween = null)


func _set_mix(v: float) -> void:
	_mix = v
	queue_redraw()


func _draw() -> void:
	if _mix < 1.0:
		_draw_one(_old, 1.0)
	_draw_one(texture, _mix)


func _draw_one(t: Texture2D, alpha: float) -> void:
	var r := Rect2(Vector2.ZERO, size)
	if t == null:
		var ground: Color = fill if fill.a > 0.0 else ThemeManager.c.surface2.lerp(ThemeManager.c.accent, 0.15)
		ground.a *= alpha
		draw_rect(r, ground)
		var side := minf(size.x, size.y)
		if initials != "":
			var font: Font = ThemeManager.fonts.display
			var fs := roundi(side * 0.36)
			var w := font.get_string_size(initials, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
			var y := size.y / 2.0 + (font.get_ascent(fs) - font.get_descent(fs)) / 2.0
			draw_string(font, Vector2((size.x - w) / 2.0, y), initials, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, Color(1, 1, 1, 0.92 * alpha))
			return
		var s := roundf(side * NOTE_SHARE)
		var note := Icons.texture("note", s)
		var col: Color = ThemeManager.c.accent
		col.a *= alpha
		draw_texture_rect(note, Rect2((size - Vector2(s, s)) / 2.0, Vector2(s, s)), false, col)
		return
	# Cover: the middle of the image at the rect's aspect.
	var ts := t.get_size()
	var k := maxf(size.x / ts.x, size.y / ts.y)
	var src := Rect2((ts - size / k) / 2.0, size / k)
	draw_texture_rect_region(t, r, src, Color(1, 1, 1, alpha))
