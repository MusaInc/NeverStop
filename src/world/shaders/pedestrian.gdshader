// Pedestrians walked entirely on the GPU (like traffic.gdshader): each
// MultiMesh instance starts at one end of a pavement segment facing along it;
// INSTANCE_CUSTOM = (speed m/s, phase m, segment length m, lift slope m/m: the
// pavement's rise over the road surface changes along terraced blocks). The body
// slides along local -Z and wraps; the walk cycle poses the limbs
// (person_pose.gdshaderinc). Speed 0 = standing (chatting, window shopping).
// Colours per walker: the top takes the instance colour, skin / legs / hair
// / accessories come from palettes by a per-walker seed. Near the hero
// (global player_pos, set by Player) walkers sidestep and turn to look.
shader_type spatial;
render_mode cull_back, diffuse_burley;

#include "res://src/world/shaders/person_pose.gdshaderinc"

global uniform vec3 player_pos;
uniform float crowd_radius = 0.0;  // m round the hero handed to the CPU crowd (0: none)
// Pavements follow the road surface (+ kerb, in the instance origin).
global uniform sampler2D ground_height : filter_linear, repeat_disable;
global uniform vec4 ground_rect;

varying vec3 v_col;
varying float v_rough;

vec3 srgb(vec3 c) {
	return pow(c, vec3(2.2));
}

vec3 pick(int part, float s, vec3 top) {
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
	} else if (part == 4) {
		return top;
	} else if (part == 6) {
		return srgb(s < 0.25 ? vec3(0.45, 0.28, 0.16) : (s < 0.5 ? vec3(0.12, 0.12, 0.14)
			: (s < 0.7 ? vec3(0.62, 0.15, 0.18) : (s < 0.85 ? vec3(0.85, 0.75, 0.55) : vec3(0.2, 0.32, 0.55)))));
	} else if (part == 0) {
		return srgb(s < 0.5 ? vec3(0.09, 0.09, 0.1) : (s < 0.75 ? vec3(0.9, 0.9, 0.88) : vec3(0.35, 0.22, 0.13)));
	}
	return srgb(vec3(0.07, 0.06, 0.06));  // eyes, tights
}

void vertex() {
	float spd = INSTANCE_CUSTOM.x;
	float len = INSTANCE_CUSTOM.z;
	float d = mod(INSTANCE_CUSTOM.y + TIME * spd, len);
	float seed = fract(INSTANCE_CUSTOM.y * 0.618 + spd * 3.7 + len * 0.137);
	int part = person_part(UV);
	int limb = person_limb(UV);
	v_col = pick(part, fract(seed * (part == 2 ? 7.13 : (part == 3 ? 13.7 : (part == 6 ? 5.31 : (part == 0 ? 3.9 : 1.0))))), COLOR.rgb);
	v_rough = part == 5 ? 0.3 : (part == 0 ? 0.45 : 0.8);

	// Reaction to the hero: how close (ground level only), which side, where.
	vec3 wp = (MODEL_MATRIX * vec4(0.0, 0.0, -d, 1.0)).xyz;
	float gy = texture(ground_height, (wp.xz - ground_rect.xy) / ground_rect.zw).g;
	wp.y += gy;
	vec3 rel = (inverse(MODEL_MATRIX) * vec4(player_pos, 1.0)).xyz - vec3(0.0, 0.0, -d);
	float k = (1.0 - smoothstep(2.0, 7.0, length((player_pos - wp).xz)))
		* (1.0 - smoothstep(2.5, 6.0, abs(player_pos.y - wp.y)));

	float walking = step(0.05, spd);
	float ph = walking > 0.5 ? d / 0.72 * 3.14159 : 0.0;
	vec3 v = VERTEX;
	vec3 n = NORMAL;
	// Standing people shift their weight and glance about now and then.
	float idle_look = (1.0 - walking) * sin(TIME * 0.4 + seed * 40.0) * 0.5 * step(0.4, sin(TIME * 0.13 + seed * 9.0));
	float a = atan(rel.x, -rel.z);
	person_pose(v, n, limb, ph, walking, 0.0, idle_look + (limb == 5 ? a * k * 0.6 : 0.0));
	if (k > 0.001) {
		// Turn towards the hero, and step aside.
		float turn = a * k * 0.35;
		float cs = cos(turn);
		float sn = sin(turn);
		v.xz = vec2(v.x * cs - v.z * sn, v.x * sn + v.z * cs);
		n.xz = vec2(n.x * cs - n.z * sn, n.x * sn + n.z * cs);
		v.x -= (rel.x >= 0.0 ? 1.0 : -1.0) * k * 1.1 * walking;
	}
	// Fade in/out at the segment ends so the wrap isn't a pop.
	// Only far off (a few pixels) or off screen: near and in view a walker
	// shrinking away was plainly visible.
	vec4 clip = PROJECTION_MATRIX * VIEW_MATRIX * vec4(wp + vec3(0.0, 1.0, 0.0), 1.0);
	float onscreen = (clip.w > 0.0 && abs(clip.x / clip.w) < 1.2 && abs(clip.y / clip.w) < 1.2) ? 1.0 : 0.0;
	float far_k = smoothstep(110.0, 140.0, length(CAMERA_POSITION_WORLD - wp));
	float endk = smoothstep(0.0, 1.5, d) * smoothstep(len, len - 1.5, d);
	float s = walking > 0.5 ? mix(1.0, endk, max(1.0 - onscreen, far_k)) : 1.0;
	// Near the hero the CPU crowd (City Empire's Crowd) takes over the
	// pavements: these walkers only carry the streets beyond it.
	// (A hard cut, out where people are specks: no shrinking.)
	s *= step(crowd_radius, length((player_pos - wp).xz));
	v *= s;
	v.z -= d;
	v.y += (gy + INSTANCE_CUSTOM.w * d) / length(MODEL_MATRIX[1].xyz);  // (instances are scaled)
	VERTEX = v;
	NORMAL = n;
}

void fragment() {
	ALBEDO = v_col;
	ROUGHNESS = v_rough;
}
