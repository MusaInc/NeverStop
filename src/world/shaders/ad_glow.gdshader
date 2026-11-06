// Light spill from the advertising screens after dark, faked without lights:
// COLOR.b < 0.5 = a soft halo on the facade round the screen,
// COLOR.b > 0.5 = a pool on the street (or roof) in front of it.
// Tinted by the advert on screen right now (the atlas's lowest mips are its
// average colour), so the street changes colour with the screens.
shader_type spatial;
render_mode unshaded, blend_add, depth_draw_never, cull_disabled, shadows_disabled, fog_disabled;

#include "res://src/world/shaders/ad_common.gdshaderinc"

global uniform float night;
global uniform float wetness;
uniform float halo_strength = 0.26;
uniform float pool_strength = 0.5;

varying flat float v_kind;
varying flat float v_off;
varying float v_aspect;
varying float v_phase;
varying float v_bright;
varying float v_mode;
varying float v_margin;

void vertex() {
	v_kind = mod(UV2.x, 8.0);
	v_off = floor(UV2.x / 8.0 + 0.01);
	v_aspect = UV2.y;
	v_phase = COLOR.r;
	v_bright = COLOR.g;
	v_mode = COLOR.b;
	v_margin = COLOR.a;  // halo margin / screen height
}

vec3 avg(int i) {
	vec4 r = ad_rect(i, v_aspect);
	return textureLod(atlas, r.xy + r.zw * 0.5, 6.5).rgb;
}

void fragment() {
	vec3 col = vec3(1.0, 0.86, 0.62) * 0.5;  // tickers: warm white
	if (v_kind < 1.5) {
		float t = TIME + v_phase * slot_time;
		float slot = floor(t / slot_time);
		float f = fract(t / slot_time);
		col = avg(ad_at(v_off, slot));
		float fade = fade_time / slot_time;
		if (f > 1.0 - fade) {
			col = mix(col, avg(ad_at(v_off, slot + 1.0)), (f - (1.0 - fade)) / fade);
		}
	}
	// Saturate the spill a little: averages of busy adverts go grey.
	float l = dot(col, vec3(0.299, 0.587, 0.114));
	col = mix(vec3(l), col, 1.5) + 0.08;
	float a;
	if (v_mode < 0.5) {
		// UV -0.3..1.3 round a screen at 0..1: falls off outside its edge.
		vec2 d = max(vec2(0.0) - UV, UV - vec2(1.0));
		// (Margins are min(0.3 h, 4 m): UV2-free, so the falloff is in UV
		// units of the halo's own extent – see AdScreens._screen_geo.)
		float e = length(max(d, vec2(0.0)) * vec2(v_aspect, 1.0)) / max(v_margin, 0.001);
		float inside = step(e, 0.0001);
		a = (1.0 - inside) * pow(clamp(1.0 - e, 0.0, 1.0), 2.0) * halo_strength;
	} else {
		// UV.x across, UV.y from the wall (0) outwards (1).
		float across = 1.0 - pow(abs(UV.x * 2.0 - 1.0), 2.0);
		a = across * pow(1.0 - clamp(UV.y, 0.0, 1.0), 1.6) * pool_strength * (1.0 + 0.7 * wetness);
	}
	ALBEDO = col * a * v_bright * smoothstep(0.2, 0.7, night);
}
