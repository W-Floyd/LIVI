class_name PackText
extends Control
## A pack view's text: at the view's rectangle, in its gravity, padding and size. Drawn rather
## than a Label because a Label grows past a rectangle shorter than its line, and the stock
## layouts have those.

var text := "":
	set(v):
		text = v
		queue_redraw()
var font: Font
var font_size := 16
var color := Color.WHITE
var h_align := HORIZONTAL_ALIGNMENT_LEFT
var v_align := VERTICAL_ALIGNMENT_TOP
var wrap := false
var ellipsis := false
var max_lines := 0
var line_spacing := 0.0   # px between lines, beyond a line's height
var padding := [0, 0, 0, 0]
var background: StyleBox
var shadow_color := Color(0, 0, 0, 0)
var shadow_offset := Vector2.ZERO
var shadow_radius := 0.0

const SHADOW_GAIN := 2.0

func _draw() -> void:
	var ci := get_canvas_item()
	if background:
		background.draw(ci, Rect2(Vector2.ZERO, size))
	var inner := Vector2(size.x - padding[0] - padding[2], size.y - padding[1] - padding[3])
	var para := TextParagraph.new()
	para.width = inner.x
	para.break_flags = TextServer.BREAK_WORD_BOUND | TextServer.BREAK_ADAPTIVE if wrap else TextServer.BREAK_NONE
	para.max_lines_visible = max_lines if wrap and max_lines > 0 else -1
	para.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS if ellipsis else TextServer.OVERRUN_NO_TRIMMING
	para.add_string(text, font, font_size)
	# Lines are placed here, not by the paragraph, so a line's position is the stock UI's:
	# a whole line height, times the multiplier, between lines.
	var lines := para.get_line_count()
	var line_h := font.get_height(font_size)
	var step := line_h + line_spacing
	var h := line_h + step * (lines - 1)
	var y := 0.0
	match v_align:
		VERTICAL_ALIGNMENT_BOTTOM:
			y = inner.y - h
		VERTICAL_ALIGNMENT_CENTER:
			y = (inner.y - h) / 2.0
	for i in lines:
		var w := para.get_line_width(i)
		var x := 0.0
		match h_align:
			HORIZONTAL_ALIGNMENT_RIGHT:
				x = inner.x - w
			HORIZONTAL_ALIGNMENT_CENTER:
				x = (inner.x - w) / 2.0
		var at := Vector2(floorf(padding[0] + x), roundf(padding[1] + y + i * step))
		if shadow_color.a > 0.0:
			_shadow(para, i, at)
		para.draw_line(ci, at, i, color)


## A soft shadow from copies of the line on a grid a pixel apart, weighted as a Gaussian of
## sigma radius / 2. Stacked translucent copies darken less than their weights add up to, so
## the weights are scaled up.
func _shadow(para: TextParagraph, line: int, at: Vector2) -> void:
	var sigma := maxf(shadow_radius / 2.0, 0.5)
	var reach := ceili(sigma * 1.6)
	var weights := PackedFloat32Array()
	var total := 0.0
	for o in range(-reach, reach + 1):
		weights.append(exp(-o * o / (2.0 * sigma * sigma)))
		total += weights[-1]
	for iy in weights.size():
		for ix in weights.size():
			var c := shadow_color
			c.a *= minf(1.0, SHADOW_GAIN * weights[ix] * weights[iy] / (total * total))
			para.draw_line(get_canvas_item(), at + shadow_offset + Vector2(ix - reach, iy - reach), line, c)
