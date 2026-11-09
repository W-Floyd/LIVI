// Frosted and glass surfaces: what's behind the panel, blurred, saturated and tinted. Glass
// also bends the backdrop near the rim and catches light along the top edge. The panel's own
// StyleBox gives the shape (its alpha, rounded corners included).
//
// Plain texture taps, no screen mipmaps, so it runs on the GLES3 compatibility renderer.
shader_type canvas_item;

uniform sampler2D screen_tex : hint_screen_texture, filter_linear;
uniform vec4 tint : source_color = vec4(0.1, 0.1, 0.1, 0.6);
uniform float blur_px = 24.0;
uniform float saturation = 1.35;
// 0 for frosted; glass sets these.
uniform float refraction_px = 0.0;
uniform float highlight = 0.0;
uniform vec2 rect_size = vec2(100.0);
uniform float radius_px = 8.0;

varying vec2 local;

void vertex() {
	local = VERTEX;
}

void fragment() {
	// How far inside the rounded rect: 0 at the rim.
	vec2 half_size = rect_size * 0.5;
	vec2 q = abs(local - half_size) - (half_size - vec2(radius_px));
	float inside = -(length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - radius_px);
	float rim = 1.0 - clamp(inside / max(radius_px * 2.0, 1.0), 0.0, 1.0);

	// Glass bends the backdrop toward the center near the rim.
	vec2 toward = normalize(half_size - local + vec2(0.001));
	vec2 uv = SCREEN_UV + toward * rim * rim * refraction_px * SCREEN_PIXEL_SIZE;

	vec2 step_uv = SCREEN_PIXEL_SIZE * blur_px / 3.0;
	vec3 acc = vec3(0.0);
	float wsum = 0.0;
	for (int x = -3; x <= 3; x++) {
		for (int y = -3; y <= 3; y++) {
			float k = exp(-float(x * x + y * y) / 6.0);
			acc += texture(screen_tex, uv + vec2(float(x), float(y)) * step_uv).rgb * k;
			wsum += k;
		}
	}
	vec3 c = acc / wsum;
	float luma = dot(c, vec3(0.299, 0.587, 0.114));
	c = mix(vec3(luma), c, saturation);
	c = mix(c, tint.rgb, tint.a);

	// Glass: light along the top edge and a faint rim all round.
	float top = 1.0 - clamp(local.y / max(radius_px * 1.5, 1.0), 0.0, 1.0);
	c += highlight * (0.55 * top * smoothstep(0.0, 1.0, rim + 0.2) + 0.18 * rim * rim);

	COLOR = vec4(c, COLOR.a);
}
