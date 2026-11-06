// River / dock water: two scrolling wave normals, sky-gradient reflection,
// fresnel, sun glint. No screen-space reads (cheap on mobile GPUs).
shader_type spatial;
render_mode cull_disabled, diffuse_burley, specular_schlick_ggx;

uniform vec3 deep : source_color = vec3(0.08, 0.17, 0.2);
uniform vec3 shallow : source_color = vec3(0.2, 0.32, 0.33);
global uniform vec3 sky_top;
global uniform vec3 sky_horizon;
global uniform float rain;
global uniform float night;

float hash12(vec2 p) {
	vec3 p3 = fract(vec3(p.xyx) * 0.1031);
	p3 += dot(p3, p3.yzx + 33.33);
	return fract((p3.x + p3.y) * p3.z);
}

float vnoise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash12(i), hash12(i + vec2(1, 0)), f.x), mix(hash12(i + vec2(0, 1)), hash12(i + vec2(1, 1)), f.x), f.y);
}

float waves(vec2 p) {
	float w = vnoise(p * 0.08 + vec2(TIME * 0.05, TIME * 0.03)) * 0.6 + vnoise(p * 0.31 - vec2(TIME * 0.11, -TIME * 0.07)) * 0.4;
	// Rain: a fine, fast pock-marking on top of the swell (and a choppier swell).
	w += rain * (vnoise(p * 2.4 + vec2(TIME * 1.7, -TIME * 1.3)) * 0.22 + vnoise(p * 0.5 + TIME * 0.2) * 0.15);
	return w;
}

void fragment() {
	vec3 wpos = (INV_VIEW_MATRIX * vec4(VERTEX, 1.0)).xyz;
	float e = 0.6;
	float h = waves(wpos.xz);
	vec3 nw = normalize(vec3(h - waves(wpos.xz + vec2(e, 0.0)), 0.9, h - waves(wpos.xz + vec2(0.0, e))));
	NORMAL = normalize((VIEW_MATRIX * vec4(nw, 0.0)).xyz);
	vec3 view_w = normalize((INV_VIEW_MATRIX * vec4(VIEW, 0.0)).xyz);
	float fres = pow(1.0 - clamp(dot(view_w, nw), 0.0, 1.0), 4.0);
	vec3 r = reflect(-view_w, nw);
	vec3 refl = mix(sky_horizon, sky_top, clamp(r.y * 1.4, 0.0, 1.0));
	ALBEDO = mix(mix(deep, shallow, h * 0.5), refl, 0.15 + 0.75 * fres);
	ROUGHNESS = 0.28 + 0.12 * rain;
	SPECULAR = 0.35;
}
