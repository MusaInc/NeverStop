shader_type spatial;
// Car glass: dark tint (you can just make out the cabin) with the same
// fake sky reflection as the paint, strong at grazing angles.
render_mode blend_mix, cull_back;

uniform vec3 tint : source_color = vec3(0.035, 0.045, 0.06);
global uniform vec3 sky_top;
global uniform vec3 sky_horizon;
global uniform vec3 sun_dir;
global uniform float night;

void fragment() {
	ALBEDO = tint;
	METALLIC = 0.2;
	ROUGHNESS = 0.08;
	SPECULAR = 0.8;
	vec3 n = normalize((INV_VIEW_MATRIX * vec4(NORMAL, 0.0)).xyz);
	vec3 v = normalize((INV_VIEW_MATRIX * vec4(VIEW, 0.0)).xyz);
	vec3 r = reflect(-v, n);
	vec3 sky = mix(sky_horizon, sky_top, smoothstep(0.02, 0.6, r.y));
	vec3 ground = vec3(0.03, 0.03, 0.035);
	vec3 env = mix(ground, sky, smoothstep(-0.02, 0.04, r.y));
	float fres = pow(1.0 - clamp(dot(NORMAL, VIEW), 0.0, 1.0), 3.0);
	float glint = pow(max(dot(r, normalize(sun_dir)), 0.0), 300.0) * 8.0;
	EMISSION = (env * mix(0.12, 0.85, fres) + vec3(glint)) * (1.0 - night * 0.8);
}
