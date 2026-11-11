// The battery block: one smooth slab, lit from the rear forward up to the charge.
shader_type spatial;
render_mode specular_schlick_ggx;

uniform float fill = 0.5;
uniform float x_min = -1.45;
uniform float x_len = 2.9;
uniform vec4 c_fill : source_color = vec4(0.1, 0.8, 0.7, 1.0);
uniform vec4 c_empty : source_color = vec4(0.5, 0.55, 0.6, 1.0);
uniform float glow = 1.0;

varying vec3 lp;

void vertex() {
	lp = VERTEX;
}

void fragment() {
	float u = (lp.x - x_min) / x_len;
	float aa = max(fwidth(u), 1e-3);
	float lit = 1.0 - smoothstep(fill - aa, fill + aa, u);
	// The charge's front edge shines.
	float front = (1.0 - smoothstep(0.0, 0.05, abs(u - fill))) * step(0.001, fill);
	vec3 base = mix(c_empty.rgb, c_fill.rgb, lit);
	ALBEDO = base;
	METALLIC = 0.35;
	ROUGHNESS = mix(0.5, 0.3, lit);
	EMISSION = c_fill.rgb * glow * (lit * 0.55 + front * 0.8);
}
