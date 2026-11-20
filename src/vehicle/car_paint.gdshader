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

uniform float flake = 1.0;       // metallic flake sparkle (0 = solid colour)

varying float v_y;
varying vec3 v_p;

void vertex() {
	v_y = VERTEX.y;  // body-local height above the ground
	v_p = VERTEX;
}

float hash3(vec3 p) {
	p = fract(p * vec3(443.897, 441.423, 437.195));
	p += dot(p, p.yzx + 19.19);
	return fract((p.x + p.y) * p.z);
}

void fragment() {
	vec3 base = mix(base_color, vec3(0.08, 0.07, 0.06), dirt * 0.45);
	vec3 nw = normalize((INV_VIEW_MATRIX * vec4(NORMAL, 0.0)).xyz);
	// Cheap occlusion: sills and lower doors darker, under-surfaces darker
	// still. Grounds the car on the road and sharpens the shoulder line.
	float ao = mix(0.62, 1.0, smoothstep(0.12, 0.75, v_y)) * mix(0.55, 1.0, smoothstep(-0.7, 0.25, nw.y));
	// Metallic "flop": the colour deepens and saturates away from the
	// highlight (face-on bright, edges rich and dark) - real paint, not
	// plastic, which keeps one flat tone all round.
	float facing = clamp(dot(NORMAL, VIEW), 0.0, 1.0);
	vec3 deep = base * base * 1.15;
	base = mix(deep, base, mix(1.0, smoothstep(0.05, 0.85, facing), metallic * 1.4));
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
	float sd = max(dot(r, normalize(sun_dir)), 0.0);
	float glint = pow(sd, 220.0) * 3.2 + pow(sd, 24.0) * 0.12;   // crisp coat glint + soft base-coat sheen
	// Flakes: tiny sparkles in the base coat near the sun's reflection, faded
	// out with distance (no shimmer far away).
	float dist = length(VERTEX);
	float fl = step(0.985, hash3(floor(v_p * 520.0))) * pow(sd, 40.0) * smoothstep(6.0, 2.5, dist);
	glint += fl * flake * metallic * 0.7;
	float fres = pow(1.0 - clamp(dot(NORMAL, VIEW), 0.0, 1.0), 4.0);
	// (2026-11-20: 0.75 at grazing + a 6x glint washed bodies out milky
	// grey under overcast skies and bloomed in the sun.)
	float k = mix(0.05, 0.5, fres) * gloss * (1.0 - dirt * 0.85);
	vec3 em = env * k + vec3(glint) * gloss * (1.0 - dirt);
	EMISSION = min(em, vec3(2.4)) * (1.0 - night * 0.85);
}
