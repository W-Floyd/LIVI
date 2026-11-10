// A soft contact shadow, instead of a shadow map.
shader_type spatial;
render_mode unshaded, blend_mix, depth_draw_never, cull_disabled;

uniform float strength = 0.5;

void fragment() {
	float d = length(UV - vec2(0.5)) * 2.0;
	ALBEDO = vec3(0.0);
	ALPHA = strength * (1.0 - smoothstep(0.25, 1.0, d));
}
