// Pedestrians walked entirely on the GPU (like traffic.gdshader): each
// MultiMesh instance starts at one end of a pavement segment facing along it;
// INSTANCE_CUSTOM = (speed m/s, phase m, segment length m, unused). The body
// slides along local -Z and wraps, with a walk cycle in the vertex shader:
// legs (|x| < 0.2, below the hips) and arms (|x| > 0.2) swing in opposition,
// knees fold on the back swing, and the body bobs twice per stride.
// Variety: skin, trousers and hair are picked per walker from palettes (the
// "shirt" surface takes the instance colour). Near the hero (global
// player_pos, set by Player) walkers sidestep out of the way and turn to look.
shader_type spatial;
render_mode cull_back, diffuse_burley;

global uniform vec3 player_pos;
// Pavements follow the road surface (+ kerb, in the instance origin).
global uniform sampler2D ground_height : filter_linear, repeat_disable;
global uniform vec4 ground_rect;
uniform vec3 tint : source_color = vec3(1.0);
uniform bool use_instance_color = false;
uniform int part = 0;  // 0 other, 1 skin, 2 trousers, 3 hair
uniform float roughness = 0.8;

varying vec3 v_col;

vec3 srgb(vec3 c) {
	return pow(c, vec3(2.2));
}

vec3 pick(float s) {
	if (part == 1) {
		return srgb(s < 0.2 ? vec3(0.95, 0.78, 0.65) : (s < 0.4 ? vec3(0.85, 0.64, 0.5)
			: (s < 0.6 ? vec3(0.68, 0.48, 0.34) : (s < 0.8 ? vec3(0.5, 0.34, 0.24) : vec3(0.33, 0.22, 0.16)))));
	} else if (part == 2) {
		return srgb(s < 0.22 ? vec3(0.16, 0.18, 0.26) : (s < 0.4 ? vec3(0.1, 0.1, 0.11)
			: (s < 0.58 ? vec3(0.28, 0.36, 0.5) : (s < 0.72 ? vec3(0.62, 0.56, 0.44)
			: (s < 0.86 ? vec3(0.34, 0.33, 0.33) : vec3(0.36, 0.24, 0.17))))));
	} else if (part == 3) {
		return srgb(s < 0.3 ? vec3(0.07, 0.06, 0.05) : (s < 0.55 ? vec3(0.24, 0.15, 0.09)
			: (s < 0.72 ? vec3(0.42, 0.28, 0.16) : (s < 0.86 ? vec3(0.78, 0.64, 0.38) : vec3(0.62, 0.6, 0.58)))));
	}
	return tint;
}

void vertex() {
	float spd = INSTANCE_CUSTOM.x;
	float len = INSTANCE_CUSTOM.z;
	float d = mod(INSTANCE_CUSTOM.y + TIME * spd, len);
	float seed = fract(INSTANCE_CUSTOM.y * 0.618 + spd * 3.7);
	v_col = use_instance_color ? COLOR.rgb : pick(fract(seed * (part == 2 ? 7.13 : (part == 3 ? 13.7 : 1.0))));

	// Reaction to the hero: how close (ground level only), which side, where.
	vec3 wp = (MODEL_MATRIX * vec4(0.0, 0.0, -d, 1.0)).xyz;
	float gy = texture(ground_height, (wp.xz - ground_rect.xy) / ground_rect.zw).g;
	wp.y += gy;
	vec3 rel = (inverse(MODEL_MATRIX) * vec4(player_pos, 1.0)).xyz - vec3(0.0, 0.0, -d);
	float k = (1.0 - smoothstep(2.0, 7.0, length((player_pos - wp).xz)))
		* (1.0 - smoothstep(2.5, 6.0, abs(player_pos.y - wp.y)));

	float ph = d / 0.72 * 3.14159;  // one step per 0.72 m
	float sw = sin(ph);
	float side = sign(VERTEX.x);
	if (abs(VERTEX.x) < 0.2 && VERTEX.y < 0.86) {
		float kk = (0.86 - VERTEX.y);
		VERTEX.z += sw * side * kk * 0.5;
		VERTEX.y += max(0.0, sw * side) * kk * 0.12;  // swinging foot lifts
		VERTEX.z += max(0.0, -sw * side) * max(0.0, 0.45 - VERTEX.y) * 0.5;  // knee folds on the back swing
	} else if (abs(VERTEX.x) > 0.2 && VERTEX.y < 1.45) {
		VERTEX.z -= sw * side * (1.45 - VERTEX.y) * 0.42;
	}
	VERTEX.y += abs(cos(ph)) * 0.03;

	if (k > 0.001) {
		// Turn towards the hero (head more than the body), and step aside.
		float a = atan(rel.x, -rel.z);
		float turn = a * k * (VERTEX.y > 1.5 ? 0.75 : 0.35);
		float cs = cos(turn);
		float sn = sin(turn);
		VERTEX.xz = vec2(VERTEX.x * cs - VERTEX.z * sn, VERTEX.x * sn + VERTEX.z * cs);  // forward (-Z) turns toward +x for a > 0
		VERTEX.x -= (rel.x >= 0.0 ? 1.0 : -1.0) * k * 1.1;
	}
	// Fade in/out at the segment ends so the wrap isn't a pop.
	float s = smoothstep(0.0, 1.5, d) * smoothstep(len, len - 1.5, d);
	VERTEX *= s;
	VERTEX.z -= d;
	VERTEX.y += gy / length(MODEL_MATRIX[1].xyz);  // (instances are scaled)
}

void fragment() {
	ALBEDO = v_col;
	ROUGHNESS = roughness;
}
