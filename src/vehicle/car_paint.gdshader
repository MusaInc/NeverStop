shader_type spatial;
// Car paint: a lit base coat plus a cheap fake clear-coat reflection of the
// actual sky (the Atmosphere's sky_top / sky_horizon globals) with a crisp
// horizon line and a dark "street" below it. Gives bodies the glossy,
// shaped look of real paint on every renderer (incl. the web build), with
// no reflection probes. Dirt/scorch from damage dulls it.
render_mode blend_mix, cull_back;

uniform vec3 base_color : source_color = vec3(0.7);
uniform float metallic = 0.45;
uniform float roughness = 0.3;
uniform float gloss = 1.0;       // 0 matte .. 1 full clear coat
uniform float dirt = 0.0;        // 0 clean .. 1 wrecked
global uniform vec3 sky_top;
global uniform vec3 sky_horizon;
global uniform vec3 sun_dir;
global uniform float night;

varying float v_y;

void vertex() {
	v_y = VERTEX.y;  // body-local height above the ground
}

void fragment() {
	vec3 base = mix(base_color, vec3(0.08, 0.07, 0.06), dirt * 0.45);
	vec3 nw = normalize((INV_VIEW_MATRIX * vec4(NORMAL, 0.0)).xyz);
	// Cheap occlusion: sills and lower doors darker, under-surfaces darker
	// still. Grounds the car on the road and sharpens the shoulder line.
	float ao = mix(0.62, 1.0, smoothstep(0.12, 0.75, v_y)) * mix(0.55, 1.0, smoothstep(-0.7, 0.25, nw.y));
	ALBEDO = base * ao;
	METALLIC = metallic * (1.0 - dirt * 0.6);
	ROUGHNESS = mix(roughness, 0.8, dirt);
	SPECULAR = 0.5;
	vec3 n = normalize((INV_VIEW_MATRIX * vec4(NORMAL, 0.0)).xyz);
	vec3 v = normalize((INV_VIEW_MATRIX * vec4(VIEW, 0.0)).xyz);
	vec3 r = reflect(-v, n);
	// Sky above the horizon, a soft dark street/building band below.
	vec3 sky = mix(sky_horizon, sky_top, smoothstep(0.02, 0.55, r.y));
	vec3 ground = mix(vec3(0.05, 0.05, 0.055), sky_horizon * 0.22, smoothstep(-0.6, -0.02, r.y));
	vec3 env = mix(ground, sky, smoothstep(-0.015, 0.025, r.y));
	// Sun glint on the coat.
	float glint = pow(max(dot(r, normalize(sun_dir)), 0.0), 220.0) * 6.0;
	float fres = pow(1.0 - clamp(dot(NORMAL, VIEW), 0.0, 1.0), 4.0);
	float k = mix(0.07, 0.75, fres) * gloss * (1.0 - dirt * 0.85);
	EMISSION = (env * k + vec3(glint) * gloss * (1.0 - dirt)) * (1.0 - night * 0.85);
}
