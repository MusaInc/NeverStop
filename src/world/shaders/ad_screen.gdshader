// LED advertising screens (AdScreens): one material for every screen in the
// city. Adverts come from one atlas (tools/ads); the rotation, the soft wipe
// between adverts, the slow push-in and each campaign's motion (atlas alpha
// = motion mask) are all computed here – no video, no per-screen textures.
// Motion is skipped past fx_range; screens are emissive, brighter at night.
shader_type spatial;
render_mode diffuse_burley, specular_schlick_ggx;

#include "res://src/world/shaders/ad_common.gdshaderinc"

global uniform float night;
uniform vec4 wide_fx[12];     // motion region in the cell (x, y, w, h)
uniform vec4 tall_fx[12];
uniform vec4 accent[12];      // rgb + fx kind / 8
uniform vec4 ticker_rect[2];  // atlas rect (normalised)
uniform float ticker_period[2];  // strip repeat length, as a fraction of the atlas width
uniform float ticker_speed = 110.0;  // atlas px per second
uniform float day_emission = 0.95;
uniform float night_emission = 1.45;
uniform float fx_range = 260.0;

varying flat float v_kind;
varying flat float v_off;
varying float v_aspect;
varying float v_phase;
varying float v_bright;

void vertex() {
	v_kind = mod(UV2.x, 8.0);
	v_off = floor(UV2.x / 8.0 + 0.01);
	v_aspect = UV2.y;
	v_phase = COLOR.r;
	v_bright = COLOR.g;
}

float hash(float n) {
	return fract(sin(n * 127.1) * 43758.5453);
}

vec3 fx_color(int kind, vec2 q, vec3 acc, vec3 base, float seed) {
	float t = TIME;
	if (kind == 0) {  // light sweep across the product
		float band = (q.x + q.y * 0.45) - (fract(t * 0.22 + seed) * 2.4 - 0.7);
		float b = exp(-band * band * 90.0);
		return base * 0.7 * b + vec3(0.12) * b;
	} else if (kind == 1) {  // equaliser
		float n = 28.0;
		float bar = floor(q.x * n);
		float f = fract(q.x * n);
		float h = 0.18 + 0.62 * abs(sin(t * (1.6 + hash(bar + seed) * 2.4) + hash(bar) * 6.0));
		float on = step(1.0 - q.y, h) * step(0.18, f) * step(f, 0.82);
		return acc * on * 0.55;
	} else if (kind == 2) {  // speed streaks
		float row = floor(q.y * 22.0);
		float r = hash(row + seed);
		float x = fract(q.x * 0.7 + t * (0.9 + r * 1.3) + r);
		float thin = smoothstep(0.42, 0.5, fract(q.y * 22.0)) * smoothstep(0.58, 0.5, fract(q.y * 22.0));
		float s = smoothstep(0.0, 0.35, x) * smoothstep(0.6, 0.35, x) * step(0.45, r);
		return acc * s * thin * 0.9;
	} else if (kind == 3) {  // pulse rings
		float d = length(q - 0.5);
		float ring = 1.0 - smoothstep(0.0, 0.05, abs(fract(d * 2.2 - t * 0.45) - 0.5));
		return acc * ring * 0.35 * clamp(1.0 - d * 1.5, 0.0, 1.0) + acc * 0.08 * (0.5 + 0.5 * sin(t * 2.0));
	} else if (kind == 4) {  // a sweeping second hand
		vec2 c = q - 0.5;
		float a = t * TAU / 12.0;
		vec2 dir = vec2(sin(a), -cos(a));
		float along = clamp(dot(c, dir), -0.06, 0.37);
		float d = length(c - dir * along);
		float line = 1.0 - smoothstep(0.004, 0.009, d);
		return (vec3(0.92, 0.32, 0.22) - base) * line;
	} else if (kind == 6) {  // rising bubbles
		vec2 g = vec2(q.x * 9.0, q.y * 11.0 + t * 0.9);
		vec2 id = floor(g);
		vec2 f = fract(g) - 0.5;
		float h = hash(id.x * 17.0 + id.y * 3.0 + seed);
		vec2 p = vec2(h - 0.5, fract(h * 7.0) - 0.5) * 0.5;
		float r = 0.08 + 0.1 * fract(h * 13.0);
		float ring = smoothstep(r, r * 0.7, length(f - p)) * step(0.35, h);
		return vec3(1.0) * ring * 0.35;
	} else if (kind == 7) {  // a train going round the loop map
		float a = t * TAU / 16.0;
		vec2 p = vec2(0.5) + vec2(cos(a), sin(a)) * 0.39;
		float d = length(q - p);
		return vec3(1.0, 0.95, 0.85) * exp(-d * d * 2600.0) * 1.4 + acc * exp(-d * d * 300.0) * 0.4;
	}
	return vec3(0.0);
}

vec3 ad_color(int i, vec2 uv, float f, float aspect, float dist) {
	vec2 c = ad_cover(uv, aspect);
	// Slow push-in over the slot (a little life on the stills).
	c = vec2(0.5) + (c - vec2(0.5)) * (1.0 - 0.035 * f);
	c = clamp(c, vec2(0.003), vec2(0.997));
	vec4 r = ad_rect(i, aspect);
	vec4 tx = texture(atlas, r.xy + c * r.zw);
	vec3 col = tx.rgb;
	float m = 1.0 - tx.a;
	if (m > 0.02 && dist < fx_range) {
		vec4 fr = aspect >= 1.0 ? wide_fx[i] : tall_fx[i];
		vec2 q = (c - fr.xy) / max(fr.zw, vec2(0.001));
		int kind = int(accent[i].a * 8.0 + 0.5);
		col += m * fx_color(kind, q, accent[i].rgb, col, float(i) * 0.37) * (1.0 - smoothstep(fx_range * 0.7, fx_range, dist));
	}
	return col;
}

void fragment() {
	float kind = v_kind;
	if (kind > 3.5) {  // steelwork
		ALBEDO = vec3(0.16, 0.165, 0.17);
		METALLIC = 0.6;
		ROUGHNESS = 0.55;
	} else if (kind < 0.5) {  // bezel / casing
		ALBEDO = vec3(0.035, 0.037, 0.04);
		METALLIC = 0.3;
		ROUGHNESS = 0.4;
	} else {
		float dist = length(VERTEX);
		vec3 col;
		if (kind > 1.5) {
			int k = int(kind - 1.5);
			vec4 r = ticker_rect[k];
			float per = ticker_period[k];
			// Strip px across this screen: its height is the strip's 96 px.
			float px = UV.x * v_aspect * r.w * 2880.0 / 3072.0 + (TIME + v_phase * 50.0) * ticker_speed / 3072.0;
			float x = mod(px, per);
			col = texture(atlas, vec2(r.x + x, r.y + clamp(UV.y, 0.01, 0.99) * r.w)).rgb;
		} else {
			float t = TIME + v_phase * slot_time;
			float slot = floor(t / slot_time);
			float f = fract(t / slot_time);
			int a = ad_at(v_off, slot);
			col = ad_color(a, UV, f, v_aspect, dist);
			float fade = fade_time / slot_time;
			if (f > 1.0 - fade) {
				// Soft diagonal wipe into the next advert.
				float k = (f - (1.0 - fade)) / fade;
				float edge = k * 1.5 - (UV.x * 0.35 + (1.0 - UV.y) * 0.15);
				float w = smoothstep(0.0, 0.25, edge);
				if (w > 0.0) {
					col = mix(col, ad_color(ad_at(v_off, slot + 1.0), UV, 0.0, v_aspect, dist), w);
				}
			}
		}
		float gain = mix(day_emission, night_emission, night) * v_bright;
		ALBEDO = col * 0.06;
		EMISSION = col * gain;
		ROUGHNESS = 0.22;
		SPECULAR = 0.35;
	}
}
