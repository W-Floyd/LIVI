// A soft cone of light, strongest at its foot: the beam over a charger.
shader_type spatial;
render_mode unshaded, blend_add, depth_draw_never, cull_disabled;

uniform vec4 color : source_color = vec4(1.0);
uniform float height = 2.4;

varying float h;

void vertex() {
	h = VERTEX.y / height + 0.5;
}

void fragment() {
	ALBEDO = color.rgb;
	ALPHA = color.a * pow(1.0 - clamp(h, 0.0, 1.0), 1.6);
}
