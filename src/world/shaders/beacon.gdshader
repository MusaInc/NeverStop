shader_type spatial;
// Job beacons: a soft column of light standing on a rooftop, readable from
// across the city (fades up its height, brighter at the base, slow pulse,
// a band rising up it). Additive, unshaded, no depth write: costs only the
// pixels it covers. UV.y runs 0 at the top to 1 at the base (CylinderMesh).
render_mode unshaded, blend_add, depth_draw_never, cull_disabled, shadows_disabled, fog_disabled;

uniform vec3 tint : source_color = vec3(0.36, 0.95, 0.82);
uniform float strength = 1.0;
uniform float pulse_rate = 1.4;

global uniform float night;

void fragment() {
	float h = 1.0 - UV.y;                  // 0 base … 1 top
	float fall = pow(1.0 - h, 2.2);        // dense near the roof
	// Edge-on fade so the column has soft sides instead of a hard outline.
	float rim = abs(dot(normalize(NORMAL), normalize(VIEW)));
	float side = smoothstep(0.0, 0.65, rim);
	float band = smoothstep(0.035, 0.0, abs(fract(h * 3.0 - TIME * 0.22) - 0.5) - 0.44);
	float pulse = 0.82 + 0.18 * sin(TIME * pulse_rate * 6.2832);
	// Distance boost: far beacons stay legible against the skyline.
	float d = length(VERTEX);
	float farb = mix(1.0, 3.2, smoothstep(60.0, 650.0, d));
	// Near fade: standing on a landing pad (or in a drone's beam) must not
	// wash the whole screen.
	float near_k = smoothstep(3.0, 14.0, d);
	float a = (0.12 + 0.7 * fall + 0.25 * band) * side * pulse * farb * near_k * strength;
	a *= mix(0.75, 1.25, night);
	ALBEDO = tint * a;
}
