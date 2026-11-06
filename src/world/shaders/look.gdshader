// Full-screen stylisation pass ("Look" in Settings). Drawn on a 2x2 quad that
// LookFilter parents to the camera; reads the opaque screen + depth buffers.
//   style 1 Comic   – ink outlines, 3-tone cel shading, halftone in shadows
//   style 2 Toon    – softer lines, posterised colour, bright and saturated
//   style 3 Painted – Kuwahara brush smoothing + light outlines
// Outlines come from relative depth jumps (silhouettes at any distance) plus
// colour edges (window grids, kerbs); both fade into the fog.
shader_type spatial;
render_mode unshaded, cull_disabled, depth_test_disabled, depth_draw_never, skip_vertex_transform, fog_disabled;

uniform sampler2D screen_tex : hint_screen_texture, filter_linear, repeat_disable;
uniform sampler2D depth_tex : hint_depth_texture, filter_nearest, repeat_disable;

uniform int style = 1;
uniform vec3 ink : source_color = vec3(0.07, 0.06, 0.12);
uniform float line_px = 1.0;          // outline half-width in pixels at 1080p
uniform float depth_edge = 0.06;      // relative depth jump that draws a line
uniform float color_edge = 0.32;      // luminance gradient that draws a line
uniform float line_far = 380.0;       // metres: lines fade out by here
uniform float bands = 3.0;            // cel tone steps
uniform float band_soft = 0.08;       // softness of a step
uniform float saturation = 1.25;
uniform float halftone = 0.5;         // dot strength in shadows (Comic)
uniform vec3 shadow_tint : source_color = vec3(0.62, 0.42, 0.78);
uniform vec3 light_tint : source_color = vec3(1.0, 0.94, 0.82);
uniform float split_tone = 0.45;
uniform float exposure = 1.0;
uniform float lift = 0.0;
uniform vec3 haze : source_color = vec3(0.98, 0.84, 0.74);
uniform float haze_near = 120.0;
uniform float haze_far = 900.0;
uniform float haze_amount = 0.4;
uniform float vignette = 0.28;
uniform float speed = 0.0;            // 0..1, drives the speed lines
uniform float speed_lines = 1.0;

void vertex() {
	POSITION = vec4(VERTEX.xy, 1.0, 1.0);
}

// Samplers are passed in: the Compatibility backend only declares the screen
// and depth buffers where fragment() uses them, not in helper functions.
float lin_depth(sampler2D dtex, vec2 uv, mat4 inv_proj) {
	float d = texture(dtex, uv).x;
#if CURRENT_RENDERER == RENDERER_COMPATIBILITY
	vec3 ndc = vec3(uv, d) * 2.0 - 1.0;
#else
	vec3 ndc = vec3(uv * 2.0 - 1.0, d);
#endif
	vec4 v = inv_proj * vec4(ndc, 1.0);
	return -v.z / v.w;
}

float luma(vec3 c) { return dot(c, vec3(0.299, 0.587, 0.114)); }

vec3 saturate_col(vec3 c, float s) {
	float l = luma(c);
	return max(mix(vec3(l), c, s), 0.0);
}

// Quantise brightness into soft steps but keep hue: the cel look.
vec3 cel(vec3 c, float n, float soft) {
	float l = max(luma(c), 1e-4);
	float x = l * n;
	float w = clamp(soft * n, 0.01, 0.5);
	float q = (floor(x) + smoothstep(0.5 - w, 0.5 + w, fract(x))) / n;
	q = mix(q, l, 0.25);  // keep a little of the real gradient so skies don't flatten
	return c * (q / l);
}

// Kuwahara: mean of the 4-quadrant with the lowest variance (radius 3).
vec3 kuwahara(sampler2D stex, vec2 uv, vec2 px) {
	vec3 m[4];
	vec3 s[4];
	for (int k = 0; k < 4; k++) { m[k] = vec3(0.0); s[k] = vec3(0.0); }
	for (int j = -3; j <= 0; j++) {
		for (int i = -3; i <= 0; i++) {
			vec3 a = texture(stex, uv + vec2(float(i), float(j)) * px).rgb;
			vec3 b = texture(stex, uv + vec2(float(-i), float(j)) * px).rgb;
			vec3 c = texture(stex, uv + vec2(float(i), float(-j)) * px).rgb;
			vec3 d = texture(stex, uv + vec2(float(-i), float(-j)) * px).rgb;
			m[0] += a; s[0] += a * a;
			m[1] += b; s[1] += b * b;
			m[2] += c; s[2] += c * c;
			m[3] += d; s[3] += d * d;
		}
	}
	vec3 best = m[0] / 16.0;
	float best_v = 1e9;
	for (int k = 0; k < 4; k++) {
		vec3 mu = m[k] / 16.0;
		vec3 var = abs(s[k] / 16.0 - mu * mu);
		float v = var.r + var.g + var.b;
		if (v < best_v) { best_v = v; best = mu; }
	}
	return best;
}

void fragment() {
	vec2 uv = SCREEN_UV;
	vec2 res = VIEWPORT_SIZE;
	vec2 px = 1.0 / res;
	vec3 col = texture(screen_tex, uv).rgb;
	if (style == 3) {
		col = kuwahara(screen_tex, uv, px * max(res.y / 720.0, 1.0));
	}

	// ---- outlines
	float dc = lin_depth(depth_tex, uv, INV_PROJECTION_MATRIX);
	// Near things get heavier lines (inked foreground, light background).
	float w = line_px * mix(2.0, 1.0, smoothstep(4.0, 40.0, dc));
	vec2 o = px * w * max(res.y / 1080.0, 0.75);
	float dl = lin_depth(depth_tex, uv - vec2(o.x, 0.0), INV_PROJECTION_MATRIX);
	float dr = lin_depth(depth_tex, uv + vec2(o.x, 0.0), INV_PROJECTION_MATRIX);
	float du = lin_depth(depth_tex, uv - vec2(0.0, o.y), INV_PROJECTION_MATRIX);
	float dd = lin_depth(depth_tex, uv + vec2(0.0, o.y), INV_PROJECTION_MATRIX);
	// Second difference: flat walls seen at a grazing angle change depth
	// linearly (no line), real creases and silhouettes don't.
	float lap = abs(dl + dr - 2.0 * dc) + abs(du + dd - 2.0 * dc);
	float near_d = min(dc, min(min(dl, dr), min(du, dd)));
	float e_depth = smoothstep(depth_edge, depth_edge * 2.0, lap / max(near_d, 0.5));

	vec3 cl = texture(screen_tex, uv - vec2(o.x, 0.0)).rgb;
	vec3 cr = texture(screen_tex, uv + vec2(o.x, 0.0)).rgb;
	vec3 cu = texture(screen_tex, uv - vec2(0.0, o.y)).rgb;
	vec3 cd = texture(screen_tex, uv + vec2(0.0, o.y)).rgb;
	float g = length(vec2(sqrt(luma(cr)) - sqrt(luma(cl)), sqrt(luma(cd)) - sqrt(luma(cu))));
	float e_col = smoothstep(color_edge, color_edge * 1.8, g / max(sqrt(luma(col)) + 0.25, 0.25));

	float fade = 1.0 - smoothstep(line_far * 0.35, line_far, near_d);
	float colour_lines = style == 2 ? 0.45 : (style == 3 ? 0.3 : 0.75);
	float edge = clamp(max(e_depth, e_col * colour_lines * (1.0 - smoothstep(30.0, line_far * 0.6, near_d))), 0.0, 1.0) * fade;

	// ---- tone (the screen buffer is linear HDR before tonemapping: stylise in
	// a gamma-encoded space so bands/thresholds match what the eye sees)
	vec3 c = saturate_col(pow(max(col, 0.0), vec3(1.0 / 2.2)), saturation);
	if (style == 1 || style == 2) {
		c = cel(c, bands, band_soft);
	}
	c = c * exposure + lift;
	float l = luma(c);
	// Split tone: cool violet shadows, warm highlights (comic print feel).
	vec3 tint = mix(shadow_tint, light_tint, smoothstep(0.1, 0.65, l));
	c = mix(c, c * tint * 1.15, split_tone);
	if (style == 1 && halftone > 0.0) {
		vec2 fc = FRAGCOORD.xy / max(res.y / 720.0, 1.0);
		mat2 rot = mat2(vec2(0.7071, 0.7071), vec2(-0.7071, 0.7071));
		vec2 cell = fract(rot * fc / 4.0) - 0.5;
		float dark = 1.0 - smoothstep(0.12, 0.45, l);
		float dot_r = 0.5 * sqrt(dark);
		float dots = 1.0 - smoothstep(dot_r - 0.08, dot_r + 0.08, length(cell));
		c = mix(c, c * 0.55 + ink * 0.2, dots * halftone * dark);
	}
	c = mix(c, ink, edge * (style == 2 ? 0.8 : 0.92));
	// Layered distance haze toward a warm pastel (background reads as painted
	// cards, the foreground pops). The sky itself is left alone.
	float far_t = smoothstep(haze_near, haze_far, dc) * step(dc, 4000.0);
	c = mix(c, haze, far_t * haze_amount);

	if (style == 8) { c = pow(max(col, 0.0), vec3(1.0 / 2.2)); }  // debug: passthrough
	if (style == 9) { c = vec3(e_depth, e_col, fract(dc / 50.0)); }  // debug: edges
	vec2 q = uv - 0.5;
	// Speed lines: thin radial streaks reaching in from the frame edge.
	if (speed > 0.01 && speed_lines > 0.0) {
		vec2 a = q * vec2(res.x / res.y, 1.0);
		float ang = atan(a.y, a.x);
		float r = length(a);
		float slice = floor(ang * 70.0);
		float h = fract(sin(slice * 12.9898 + floor(TIME * 9.0) * 4.1) * 43758.5453);
		float thin = 1.0 - smoothstep(0.1, 0.45, abs(fract(ang * 70.0) - 0.5));
		float reach = mix(0.95, 0.42, speed * h);
		float streak = step(1.0 - 0.45 * speed, h) * thin * smoothstep(reach, reach + 0.25, r);
		c = mix(c, vec3(1.0, 0.98, 0.94), streak * 0.55 * speed_lines);
	}
	c *= 1.0 - vignette * smoothstep(0.25, 0.85, dot(q, q) * 2.2);
	ALBEDO = pow(max(c, 0.0), vec3(2.2));
}
