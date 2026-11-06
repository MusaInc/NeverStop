shader_type spatial;
render_mode diffuse_burley, specular_disabled;
// Hills and mountains round the bay (Hinterland): sand at the waterline,
// meadow and forest on the foothills, rock on steep or high ground, snow on
// the highest western peaks. World-space noise breaks up every band; the
// scene fog does the aerial perspective.

global uniform float night;
global uniform float wetness;

varying vec3 v_world;
varying vec3 v_wn;

float h21(vec2 p) { return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453); }
float vnoise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	return mix(mix(h21(i), h21(i + vec2(1, 0)), f.x), mix(h21(i + vec2(0, 1)), h21(i + vec2(1, 1)), f.x), f.y);
}
float fbm(vec2 p) { return vnoise(p) * 0.5 + vnoise(p * 2.1) * 0.3 + vnoise(p * 4.3) * 0.2; }

void vertex() {
	v_world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	v_wn = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
}

void fragment() {
	float y = v_world.y;
	vec2 p = v_world.xz;
	float slope = 1.0 - clamp(v_wn.y, 0.0, 1.0);          // 0 flat … 1 vertical
	float n = fbm(p * 0.006);
	float n2 = fbm(p * 0.03);
	vec3 sand = vec3(0.72, 0.66, 0.52);
	vec3 meadow = mix(vec3(0.33, 0.42, 0.2), vec3(0.42, 0.46, 0.24), n2);
	vec3 forest = mix(vec3(0.12, 0.2, 0.11), vec3(0.17, 0.25, 0.13), n2);
	vec3 rock = mix(vec3(0.38, 0.37, 0.36), vec3(0.5, 0.47, 0.43), n2);
	vec3 snow = vec3(0.92, 0.94, 0.97);
	// Forest on the middle slopes, patchy; meadow lower and on flats.
	float forest_k = smoothstep(0.35, 0.6, n + 0.25 * smoothstep(20.0, 200.0, y)) * (1.0 - smoothstep(380.0, 560.0, y + n * 120.0));
	vec3 c = mix(meadow, forest, forest_k);
	c = mix(sand, c, smoothstep(1.5, 9.0, y + n2 * 4.0));
	float rocky = smoothstep(0.42, 0.62, slope + n * 0.15) + smoothstep(480.0, 720.0, y + n * 160.0);
	c = mix(c, rock, clamp(rocky, 0.0, 1.0));
	float snowy = smoothstep(780.0, 900.0, y + n * 140.0) * (1.0 - smoothstep(0.55, 0.75, slope));
	c = mix(c, snow, snowy);
	// Wet sand darkens at the waterline.
	c *= 1.0 - 0.25 * (1.0 - smoothstep(-1.0, 2.5, y));
	// Ground detail the 45 m mesh can't carry: forest canopy as dark/light
	// clumps, rock strata, and small-scale relief in the normal so light
	// rakes across the slopes instead of shading one smooth sheet.
	float canopy = vnoise(p * 0.11) * 0.6 + vnoise(p * 0.31) * 0.4;
	c *= mix(1.0, 0.72 + 0.5 * canopy, forest_k * (1.0 - clamp(rocky, 0.0, 1.0)));
	c *= mix(1.0, 0.85 + 0.25 * vnoise(vec2(p.x * 0.004, y * 0.25)), clamp(rocky, 0.0, 1.0) * (1.0 - snowy));
	float e = 3.0;
	float s0 = fbm(p * 0.045);
	float gx = fbm((p + vec2(e, 0.0)) * 0.045) - s0;
	float gz = fbm((p + vec2(0.0, e)) * 0.045) - s0;
	float amp = 6.0 * (0.4 + 0.6 * clamp(rocky + forest_k * 0.6, 0.0, 1.0));
	vec3 wn = normalize(v_wn - vec3(gx, 0.0, gz) * amp);
	NORMAL = normalize((VIEW_MATRIX * vec4(wn, 0.0)).xyz);
	ALBEDO = c;
	ROUGHNESS = mix(0.95, 0.6, snowy);
}
