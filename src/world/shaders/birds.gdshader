// A flock circling on the GPU. Each instance's transform origin is its
// circle's centre; INSTANCE_CUSTOM = (radius m, angular speed rad/s,
// phase rad, bob m). The bird faces along its path and banks inward; wings
// (|x| > 0.06) flap.
shader_type spatial;
render_mode cull_disabled, diffuse_burley;

uniform vec3 tint : source_color = vec3(0.32, 0.32, 0.35);

void vertex() {
	float r = INSTANCE_CUSTOM.x;
	float a = INSTANCE_CUSTOM.z + TIME * INSTANCE_CUSTOM.y;
	vec3 v = VERTEX;
	float flap = sin(TIME * 11.0 + INSTANCE_CUSTOM.z * 7.0);
	if (abs(v.x) > 0.06) {
		v.y += flap * (abs(v.x) - 0.06) * 0.9;
	}
	// Bank toward the centre, then face along the circle.
	float bank = 0.35 * sign(INSTANCE_CUSTOM.y);
	v = vec3(v.x * cos(bank) - v.y * sin(bank), v.x * sin(bank) + v.y * cos(bank), v.z);
	float heading = -a - sign(INSTANCE_CUSTOM.y) * 1.5708;
	v = vec3(v.x * cos(heading) + v.z * sin(heading), v.y, -v.x * sin(heading) + v.z * cos(heading));
	v += vec3(cos(a) * r, sin(a * 2.3 + INSTANCE_CUSTOM.z) * INSTANCE_CUSTOM.w, sin(a) * r);
	VERTEX = v;
}

void fragment() {
	ALBEDO = tint;
	ROUGHNESS = 0.9;
}
