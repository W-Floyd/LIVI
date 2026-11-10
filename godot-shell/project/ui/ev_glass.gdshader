// The car's translucent shell: a faint tint, light where it faces the sky, and a bright rim
// where it turns away, over whatever is inside. Premultiplied, so a highlight stays a
// highlight however clear the glass.
shader_type spatial;
render_mode blend_premul_alpha, depth_draw_never, cull_back, specular_schlick_ggx;

uniform vec4 tint : source_color = vec4(0.7, 0.8, 0.9, 1.0);
uniform vec4 rim_color : source_color = vec4(0.8, 0.9, 1.0, 1.0);
uniform float base_alpha = 0.16;
uniform float rim_alpha = 0.55;
uniform float rim_power = 2.6;
uniform float rim_glow = 0.5;

void fragment() {
	float f = pow(1.0 - clamp(dot(normalize(NORMAL), normalize(VIEW)), 0.0, 1.0), rim_power);
	float a = clamp(base_alpha + f * rim_alpha, 0.0, 1.0);
	ALBEDO = mix(tint.rgb, rim_color.rgb, f) * a;
	ALPHA = a;
	METALLIC = 0.0;
	ROUGHNESS = 0.12;
	SPECULAR = 0.9;
	EMISSION = rim_color.rgb * f * rim_glow;
}
