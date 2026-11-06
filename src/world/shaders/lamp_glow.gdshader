// Street-lamp light after dark, faked without real lights (mobile budget):
// mode 0 = a soft pool on the ground under the lamp head (flat quad),
// mode 1 = a halo round the lamp head (camera-facing quad, bigger in rain/fog).
shader_type spatial;
render_mode unshaded, blend_add, depth_draw_never, cull_disabled, shadows_disabled;

global uniform float night;
global uniform float wetness;
global uniform float rain;
uniform int mode = 0;
uniform vec3 glow : source_color = vec3(1.0, 0.72, 0.42);

void vertex() {
	if (mode == 1) {
		// Billboard about the instance origin.
		vec3 c = (MODEL_MATRIX * vec4(0.0, 0.0, 0.0, 1.0)).xyz;
		vec3 right = INV_VIEW_MATRIX[0].xyz;
		vec3 up = INV_VIEW_MATRIX[1].xyz;
		float s = 1.0 + 0.8 * rain;
		vec3 wv = c + (right * VERTEX.x + up * VERTEX.y) * s;
		POSITION = PROJECTION_MATRIX * VIEW_MATRIX * vec4(wv, 1.0);
	} else {
		// (Writing POSITION anywhere means every path must.)
		POSITION = PROJECTION_MATRIX * MODELVIEW_MATRIX * vec4(VERTEX, 1.0);
	}
}

void fragment() {
	float r = length(UV - 0.5) * 2.0;
	float a;
	if (mode == 0) {
		a = pow(clamp(1.0 - r, 0.0, 1.0), 2.2) * 0.42;
		a *= 1.0 + 0.6 * wetness;  // wet streets throw more of it back
	} else {
		a = pow(clamp(1.0 - r, 0.0, 1.0), 3.0) * (0.9 + 0.5 * rain);
	}
	ALBEDO = glow * a * smoothstep(0.25, 0.7, night);
}
