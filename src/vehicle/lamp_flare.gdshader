shader_type spatial;
// Lamp glows for one car in one draw call: every lamp is a quad whose four
// vertices all sit at the lamp's centre (VERTEX), with the corner offset in
// UV2, the colour/strength in COLOR and the way the lamp points in NORMAL.
// Billboarded here; only shows in the dark (global `night`), and fades
// when seen from behind the lamp. No CPU cost per frame.
render_mode unshaded, blend_add, cull_disabled, depth_draw_never, shadows_disabled, skip_vertex_transform;

uniform float size = 1.0;
global uniform float night;

varying float v_face;
varying vec4 v_col;

void vertex() {
	vec3 c = (MODELVIEW_MATRIX * vec4(VERTEX, 1.0)).xyz;
	vec3 dir = normalize((MODELVIEW_MATRIX * vec4(NORMAL, 0.0)).xyz);
	vec3 to_cam = normalize(-c);
	v_face = smoothstep(-0.05, 0.55, dot(dir, to_cam));
	v_col = COLOR;
	// Pulled toward the camera so the lamp housing doesn't clip it.
	VERTEX = c + to_cam * 0.35 + vec3(UV2 * size, 0.0);
	NORMAL = vec3(0.0, 0.0, 1.0);
}

void fragment() {
	vec2 d = UV - vec2(0.5);
	float r = length(d) * 2.0;
	float core = pow(clamp(1.0 - r, 0.0, 1.0), 6.0) * 1.6;
	float halo = pow(clamp(1.0 - r, 0.0, 1.0), 2.4) * 0.3;
	// A faint horizontal streak (anamorphic) on the bright lamps.
	float streak = exp(-abs(d.y) * 70.0) * clamp(1.0 - abs(d.x) * 2.0, 0.0, 1.0) * 0.45 * step(0.75, v_col.a);
	ALBEDO = v_col.rgb * (core + halo + streak) * v_col.a * night * v_face;
}
