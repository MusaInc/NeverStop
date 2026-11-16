shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never, shadows_disabled;
void fragment() {
	float bands = pow(0.5 + 0.5 * sin(UV.y * 100.0 - TIME * 2.5 + sin(UV.x * 160.0)), 8.0);
	float streak = pow(0.5 + 0.5 * sin(UV.x * 400.0 + TIME * 0.3), 24.0);
	ALBEDO = mix(vec3(0.18, 0.12, 0.65), vec3(0.3, 0.85, 1.0), bands);
	EMISSION = ALBEDO * (0.4 + bands);
	ALPHA = (0.12 + bands * 0.22 + streak * 0.08) * (1.0 - smoothstep(0.6, 1.0, UV.y));
}
