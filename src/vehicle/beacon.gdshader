shader_type spatial;
// Police light bar: red (x < 0) and blue (x > 0) halves alternate in quick
// double flashes. Pure GPU – no per-frame CPU work per car.
render_mode cull_back;

uniform float on = 0.0;
uniform float phase = 0.0;
varying float side;

void vertex() {
	side = VERTEX.x;
}

void fragment() {
	bool red = side < 0.0;
	vec3 base = red ? vec3(0.75, 0.04, 0.03) : vec3(0.05, 0.12, 0.85);
	float t = fract(TIME * 1.3 + phase);
	// Double flash per half-cycle: red in the first half, blue in the second.
	float local = red ? t : fract(t + 0.5);
	float f = (local < 0.5) ? step(0.0, sin(local * 6.2831 * 4.0)) : 0.0;
	ALBEDO = base * (0.35 + 0.65 * f * on);
	ROUGHNESS = 0.2;
	EMISSION = base * 7.0 * f * on + base * 0.15;
}
