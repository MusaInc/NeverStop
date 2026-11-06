shader_type canvas_item;
// Radial speed streaks toward the screen edges.
uniform float amount = 0.0;

float hash(float n) { return fract(sin(n) * 43758.5453); }

void fragment() {
	vec2 uv = UV - vec2(0.5, 0.52);
	uv.x *= 1.78;
	float r = length(uv);
	float a = atan(uv.y, uv.x);
	float lane = floor(a * 40.0);
	float speed = 2.2 + hash(lane) * 1.5;
	float streak = fract(r * 1.6 - TIME * speed + hash(lane + 7.0));
	float line = smoothstep(0.92, 1.0, streak) * step(0.55, hash(lane * 3.1));
	float edge = smoothstep(0.32, 0.75, r);
	COLOR = vec4(1.0, 1.0, 1.0, line * edge * amount * 0.35);
}
