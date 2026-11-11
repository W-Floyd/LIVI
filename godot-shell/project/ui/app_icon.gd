class_name AppIcon
extends Control
## An app's icon fitted to the control: its PNG or SVG, else a monogram on an accent tile.

var path := "":
	set(v):
		path = v
		_tex = null
		queue_redraw()
var label := "":
	set(v):
		label = v
		queue_redraw()

var _tex: Texture2D
var _tex_px := 0

## Path@px -> texture (or null for an icon that does not load), for the shell's life.
static var _cache := {}


func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	resized.connect(queue_redraw)


static func load_icon(file: String, px: int) -> Texture2D:
	var key := "%s@%d" % [file, px]
	if _cache.has(key):
		return _cache[key]
	var img := Image.new()
	var err := ERR_FILE_UNRECOGNIZED
	if file.ends_with(".svg"):
		var svg := FileAccess.get_file_as_string(file)
		err = img.load_svg_from_string(svg)
		if err == OK and img.get_width() > 0:
			err = img.load_svg_from_string(svg, px / float(maxi(img.get_width(), img.get_height())))
	elif file.ends_with(".png"):
		err = img.load_png_from_buffer(FileAccess.get_file_as_bytes(file))
	var tex: Texture2D = null
	if err == OK and not img.is_empty():
		var s := px / float(maxi(img.get_width(), img.get_height()))
		if s < 1.0:
			img.resize(maxi(1, roundi(img.get_width() * s)), maxi(1, roundi(img.get_height() * s)), Image.INTERPOLATE_LANCZOS)
		tex = ImageTexture.create_from_image(img)
	_cache[key] = tex
	return tex


func _draw() -> void:
	var side := minf(size.x, size.y)
	if side <= 0:
		return
	var r := Rect2((size - Vector2(side, side)) / 2.0, Vector2(side, side))
	if path != "" and (_tex == null or _tex_px != int(side)):
		_tex = load_icon(path, int(side))
		_tex_px = int(side)
	if _tex:
		var ts := _tex.get_size()
		var s := minf(side / ts.x, side / ts.y)
		draw_texture_rect(_tex, Rect2(r.get_center() - ts * s / 2.0, ts * s), false)
		return
	var box := StyleBoxFlat.new()
	box.bg_color = ThemeManager.c.accent
	box.set_corner_radius_all(roundi(maxf(ThemeManager.px.radius, side * 0.18)))
	box.anti_aliasing = true
	draw_style_box(box, r)
	var letter := label.strip_edges().left(1).to_upper()
	if letter == "":
		return
	var font: Font = ThemeManager.fonts.strong
	var fs := roundi(side * 0.5)
	var w := font.get_string_size(letter, HORIZONTAL_ALIGNMENT_LEFT, -1, fs)
	var base := r.get_center() + Vector2(-w.x / 2.0, (font.get_ascent(fs) - font.get_descent(fs)) / 2.0)
	draw_string(font, base, letter, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, ThemeManager.c.on_accent)
