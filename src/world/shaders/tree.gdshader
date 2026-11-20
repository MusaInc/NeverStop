shader_type spatial;
// TreeKit trees. Vertex colour = species colour (alpha 1 foliage, 0 bark);
// INSTANCE_CUSTOM.rgb = this tree's leaf tint. Foliage sways a little with
// height, breaks into leaf clusters up close (world-space cells, faded with
// distance so it never shimmers far off) and lets light through (backlight).
render_mode cull_back;

varying vec3 v_wpos;
varying vec3 v_tint;
varying float v_leaf;
varying float v_dist;

float hash13(vec3 p) {
	p = fract(p * 0.1031);
	p += dot(p, p.zyx + 31.32);
	return fract((p.x + p.y) * p.z);
}

void vertex() {
	v_leaf = COLOR.a;
	v_tint = INSTANCE_CUSTOM.rgb;
	vec3 w = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	if (COLOR.a > 0.5) {
		float h = max(VERTEX.y - 2.0, 0.0);
		float ph = MODEL_MATRIX[3].x * 0.21 + MODEL_MATRIX[3].z * 0.17;
		VERTEX.x += sin(TIME * 1.3 + ph + w.y * 0.4) * 0.025 * h;
		VERTEX.z += cos(TIME * 1.07 + ph * 1.3) * 0.02 * h;
	}
	v_wpos = w;
	v_dist = length((MODELVIEW_MATRIX * vec4(VERTEX, 1.0)).xyz);
}

void fragment() {
	vec3 c = COLOR.rgb;
	if (v_leaf > 0.5) {
		c *= v_tint;
		// Leaf clusters: two scales of cells, stronger up close.
		float near = 1.0 - smoothstep(25.0, 90.0, v_dist);
		float n1 = hash13(floor(v_wpos * 2.6));
		float n2 = hash13(floor(v_wpos * 6.5) + 17.0);
		c *= mix(1.0, 0.72 + 0.45 * n1, 0.8 * near) * mix(1.0, 0.85 + 0.3 * n2, 0.6 * near);
		ROUGHNESS = 0.82;
		BACKLIGHT = c * 0.45;
		SPECULAR = 0.25;
	} else {
		// Bark: vertical fissures.
		float f = hash13(floor(vec3(v_wpos.x * 9.0, v_wpos.y * 1.4, v_wpos.z * 9.0)));
		c *= 0.85 + 0.25 * f;
		ROUGHNESS = 0.95;
		SPECULAR = 0.2;
	}
	ALBEDO = c;
}
