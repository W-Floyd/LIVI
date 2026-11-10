// The range road: lit up to the range with climate on, paler to the range with it off, a
// warning segment at the end of the lit part, distance ticks, and a ring where the charger is.
// One strip, unshaded; positions are the strip's local x (world units, `upk` per km).
shader_type spatial;
render_mode unshaded, blend_mix, depth_draw_never, cull_disabled;

uniform float upk = 0.285;
uniform float half_w = 4.5;
uniform float km_on = 243.0;
uniform float km_off = 253.0;
uniform float km_warn = 1.0e6;
uniform float tick_km = 50.0;
uniform float stop_x = -1000.0;
uniform float glow = 0.4;
uniform vec4 c_lit : source_color = vec4(0.3, 0.4, 0.8, 0.9);
uniform vec4 c_far : source_color = vec4(0.6, 0.7, 0.95, 0.6);
uniform vec4 c_warn : source_color = vec4(1.0, 0.6, 0.1, 0.9);
uniform vec4 c_line : source_color = vec4(1.0);
uniform vec4 c_stop : source_color = vec4(1.0);

varying vec2 lp;

void vertex() {
	lp = VERTEX.xz;
}

void fragment() {
	float km = lp.x / upk;
	float v = lp.y / half_w;
	float av = abs(v);
	float aa = max(fwidth(km), 1e-3);
	float av_aa = max(fwidth(v), 1e-3);

	float s_on = 1.0 - smoothstep(km_on - aa, km_on + aa, km);
	float s_end = 1.0 - smoothstep(km_off - aa, km_off + aa, km);
	float s_body = 1.0 - smoothstep(1.0 - av_aa, 1.0 + av_aa, av);
	float s_warn = smoothstep(km_warn - aa, km_warn + aa, km);

	float t = clamp(km / max(km_on, 1.0), 0.0, 1.0);
	vec4 lit = vec4(mix(c_lit.rgb, c_far.rgb, t * 0.9), c_lit.a);
	lit = mix(lit, c_warn, s_warn);
	vec4 body = mix(c_far, lit, s_on);

	vec3 col = body.rgb;
	float a = body.a * s_body * s_end;

	// Edge lines and the centerline.
	float edge = (1.0 - smoothstep(0.012, 0.012 + 2.0 * av_aa, abs(av - 0.975))) * s_body * s_end;
	float cw = max(av_aa, 0.004);
	float center = (1.0 - smoothstep(cw, cw * 2.0, av)) * s_end;
	// Ticks: short bars across the centerline at every tick_km, none at the car.
	float d = abs(km - tick_km * round(km / tick_km)) * upk;
	float tick = (1.0 - smoothstep(0.07, 0.16, d)) * (1.0 - smoothstep(0.16, 0.22, av))
		* step(tick_km * 0.5, km) * s_end;
	// The end of the road: a bright cap.
	float cap = smoothstep(km_off - 1.4, km_off - 0.2, km) * s_end * s_body;
	col = mix(col, c_line.rgb, edge * 0.55 + center * 0.5 + tick * 0.9 + cap * 0.55);
	a = max(a, max(edge * 0.55, max(center * 0.4, tick * 0.8)));
	a = max(a, cap * 0.85);

	// The charger: a ring and a soft disc where it stands.
	float r = length(vec2(lp.x - stop_x, lp.y));
	float ring = (1.0 - smoothstep(0.06, 0.2, abs(r - 2.0))) * s_body;
	float disc = (1.0 - smoothstep(0.0, 2.0, r)) * 0.25 * s_body;
	float stop_a = max(ring * 0.9, disc);
	col = mix(col, c_stop.rgb, stop_a);
	a = max(a, stop_a * c_stop.a);

	// A halo beside the lit road, the bloom a lit strip casts on its surroundings.
	float halo = exp(-max(av - 1.0, 0.0) * 5.0) * step(1.0, av) * glow * s_on * s_end;
	col = mix(col, c_lit.rgb, step(1.0, av));
	a = max(a, halo * (1.0 - s_body));

	ALBEDO = col;
	ALPHA = clamp(a, 0.0, 1.0);
}
