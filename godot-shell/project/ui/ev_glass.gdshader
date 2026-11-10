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
// Vertex colors, where the mesh has them: r the baked occlusion, g the edge light's weight.
uniform bool baked = false;
uniform float crease_glow = 1.0;
uniform float occlusion = 0.4;

void fragment() {
	float f = pow(1.0 - clamp(dot(normalize(NORMAL), normalize(VIEW)), 0.0, 1.0), rim_power);
	float edge = baked ? pow(COLOR.g, 4.0) : 0.0;
	float ao = baked ? COLOR.r : 1.0;
	float a = clamp(base_alpha + f * rim_alpha + edge * 0.6 * rim_alpha, 0.0, 1.0);
	// Occluded parts go darker, not clearer: more alpha over less light.
	float dark = (1.0 - ao) * occlusion;
	ALBEDO = mix(tint.rgb, rim_color.rgb, clamp(f + edge, 0.0, 1.0)) * a * ao;
	ALPHA = clamp(a + dark, 0.0, 1.0);
	METALLIC = 0.0;
	ROUGHNESS = 0.12;
	SPECULAR = 0.9;
	EMISSION = rim_color.rgb * (f * rim_glow + edge * crease_glow * 0.9) * ao;
}
