// Rain streaks (RainFx): each instance's origin is a fixed point in a box;
// the box scrolls down and with the wind, and wraps round the camera, so the
// same drops fall forever. Streaks face the camera about their own axis.
shader_type spatial;
render_mode unshaded, blend_mix, depth_draw_never, cull_disabled, shadows_disabled, fog_disabled;

uniform vec3 box = vec3(46.0, 30.0, 46.0);
uniform float amount = 1.0;
uniform vec3 tint = vec3(0.8, 0.85, 0.9);
const float FALL = 17.0;
const vec2 WIND = vec2(2.2, 1.1);

varying float v_fade;

void vertex() {
	vec3 cam = INV_VIEW_MATRIX[3].xyz;
	vec3 o = MODEL_MATRIX[3].xyz;  // (MultiMesh: instance transform folded into MODEL_MATRIX)
	vec3 drift = vec3(WIND.x, -FALL, WIND.y) * TIME;
	vec3 p = mod(o + drift - cam + box * 0.5, box) - box * 0.5 + cam;
	// Thin out with amount: drops past the share simply vanish.
	float keep = step(fract(o.x * 12.9898 + o.z * 78.233), amount);
	vec3 fall_dir = normalize(vec3(WIND.x, -FALL, WIND.y));
	vec3 to_cam = normalize(cam - p);
	vec3 side = normalize(cross(fall_dir, to_cam));
	vec3 wv = p + side * VERTEX.x - fall_dir * VERTEX.y * (0.6 + 0.6 * amount);
	float d = length(cam - p);
	v_fade = keep * smoothstep(1.2, 3.5, d) * (1.0 - smoothstep(box.x * 0.3, box.x * 0.5, d));
	POSITION = PROJECTION_MATRIX * VIEW_MATRIX * vec4(wv, 1.0);
}

void fragment() {
	ALBEDO = tint;
	float edge = 1.0 - abs(UV.x - 0.5) * 2.0;
	ALPHA = v_fade * edge * (0.12 + 0.2 * amount) * (1.0 - UV.y * 0.6);
}
