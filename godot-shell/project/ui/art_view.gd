class_name ArtView
extends Control
## A cover, cropped square and centred in the rect (or bled to a card's edges, `flush_to`), in
## rounded corners; without one, the theme's placeholder with a note. A new cover fades in over
## the old unless motion is reduced.

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
## A card this draws to the edges of, past its own rect, rounded only where it meets the card's
## corners: SIDE_LEFT, a square the card's height at its left edge (as wide as this rect reaches);
## SIDE_TOP, the card's width from its top to this rect's foot.
var flush_to: Control:
	set(v):
		if flush_to and flush_to.resized.is_connected(_shape):
			flush_to.resized.disconnect(_shape)
		flush_to = v
		if v:
			v.resized.connect(_shape)
		_shape()
var flush_side := SIDE_LEFT:
	set(v):
		flush_side = v
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
uniform vec2 origin;
uniform vec2 size;
uniform vec4 radii;  // top left, top right, bottom right, bottom left
varying vec2 local;
void vertex() { local = VERTEX; }
void fragment() {
	vec2 p = local - origin - size * 0.5;
	float r = p.x < 0.0 ? (p.y < 0.0 ? radii.x : radii.w) : (p.y < 0.0 ? radii.y : radii.z);
	vec2 q = abs(p) - (size * 0.5 - vec2(r));
	float d = length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - r;
	COLOR.a *= clamp(0.5 - d, 0.0, 1.0);
}"""
	var m := ShaderMaterial.new()
	m.shader = _shader
	material = m
	texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	resized.connect(_shape)
	# The flush rect follows this rect's place in the card.
	set_notify_transform(true)


func _notification(what: int) -> void:
	if what == NOTIFICATION_TRANSFORM_CHANGED and flush_to:
		_shape()


func _ready() -> void:
	ThemeManager.changed.connect(_shape)
	_shape()


func _shape() -> void:
	var r := radius if radius >= 0.0 else float(ThemeManager.px.radius) * 1.5
	var sq := square()
	var radii := Vector4.ONE * r
	if flush_to:
		var box := flush_to.get_theme_stylebox("panel")
		var cr: float = box.get_corner_radius(CORNER_TOP_LEFT) if box is StyleBoxFlat else ThemeManager.px.radius
		radii = Vector4(cr, 0.0, 0.0, cr) if flush_side == SIDE_LEFT else Vector4(cr, cr, 0.0, 0.0)
	radii = radii.min(Vector4.ONE * minf(sq.size.x, sq.size.y) / 2.0)
	(material as ShaderMaterial).set_shader_parameter("origin", sq.position)
	(material as ShaderMaterial).set_shader_parameter("size", sq.size)
	(material as ShaderMaterial).set_shader_parameter("radii", radii)
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


## Where it draws: the largest square centred in the rect, so a stretched rect never stretches it.
func square() -> Rect2:
	if flush_to and flush_to.is_inside_tree() and is_inside_tree():
		var card := Rect2(flush_to.get_global_rect().position - get_global_rect().position, flush_to.size)
		if flush_side == SIDE_LEFT:
			return Rect2(card.position, Vector2(minf(card.size.y, size.x - card.position.x), card.size.y))
		return Rect2(card.position, Vector2(card.size.x, size.y - card.position.y))
	var side := minf(size.x, size.y)
	return Rect2(((size - Vector2(side, side)) / 2.0).round(), Vector2(side, side))


func _draw_one(t: Texture2D, alpha: float) -> void:
	var r := square()
	if t == null:
		var ground: Color = fill if fill.a > 0.0 else ThemeManager.c.surface2.lerp(ThemeManager.c.accent, 0.15)
		ground.a *= alpha
		draw_rect(r, ground)
		var side := minf(r.size.x, r.size.y)
		if initials != "":
			var font: Font = ThemeManager.fonts.display
			var fs := roundi(side * 0.36)
			var w := font.get_string_size(initials, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
			var y := r.get_center().y + (font.get_ascent(fs) - font.get_descent(fs)) / 2.0
			draw_string(font, Vector2(r.get_center().x - w / 2.0, y), initials, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, Color(1, 1, 1, 0.92 * alpha))
			return
		var s := roundf(side * NOTE_SHARE)
		var note := Icons.texture("note", s)
		var col: Color = ThemeManager.c.accent
		col.a *= alpha
		draw_texture_rect(note, Rect2(r.get_center() - Vector2(s, s) / 2.0, Vector2(s, s)), false, col)
		return
	# Cover: the middle of the image in the rect's shape.
	var ts := t.get_size()
	var k := minf(ts.x / r.size.x, ts.y / r.size.y) if r.size.x > 0.0 and r.size.y > 0.0 else 1.0
	var src := Rect2((ts - r.size * k) / 2.0, r.size * k)
	draw_texture_rect_region(t, r, src, Color(1, 1, 1, alpha))
