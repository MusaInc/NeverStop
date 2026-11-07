shader_type spatial;
// Billboarded soft particles for VehicleFx pools: the instance transform's
// basis is a uniform scale, the shader faces it to the camera. Colour and
// alpha come from the instance colour. Additive for sparks/fire.
//
// Smoke must never hide the road: every puff fades out as it nears the
// camera and as it grows to fill a big part of the screen, so a drift or a
// smoking engine reads as smoke around the car, not a grey screen.
render_mode unshaded, cull_disabled, depth_draw_never, blend_mix;

uniform bool additive = false;
uniform float alpha = 1.0;
uniform float near_fade_start = 1.2;   // m: fully gone this close
uniform float near_fade_end = 8.0;     // m: fully visible from here
uniform float max_cover = 0.9;         // puff size / distance where it has faded out
global uniform float night;

varying float v_fade;
varying float v_seed;
varying float v_shade;

void vertex() {
	vec3 pos = MODEL_MATRIX[3].xyz;
	float s = length(MODEL_MATRIX[0].xyz);
	v_seed = fract(float(INSTANCE_ID) * 0.61803);
	// Each puff turns slowly on its own so the lobes don't line up.
	float a = v_seed * 6.2832 + TIME * (v_seed - 0.5) * 0.8;
	vec2 q = VERTEX.xy;
	v_shade = q.y + 0.5;  // 0 bottom .. 1 top, before rotation
	VERTEX.xy = vec2(q.x * cos(a) - q.y * sin(a), q.x * sin(a) + q.y * cos(a));
	MODELVIEW_MATRIX = VIEW_MATRIX * mat4(INV_VIEW_MATRIX[0] * s, INV_VIEW_MATRIX[1] * s, INV_VIEW_MATRIX[2] * s, vec4(pos, 1.0));
	MODELVIEW_NORMAL_MATRIX = mat3(MODELVIEW_MATRIX);
	float dist = length((VIEW_MATRIX * vec4(pos, 1.0)).xyz);
	if (additive) {
		v_fade = 1.0;
	} else {
		float near = smoothstep(near_fade_start, near_fade_end, dist - s * 0.35);
		float cover = 1.0 - smoothstep(max_cover * 0.4, max_cover, s / max(dist, 0.01));
		v_fade = near * cover;
	}
}

void fragment() {
	vec2 d = UV - vec2(0.5);
	float r = length(d) * 2.0;
	float soft;
	vec3 c = COLOR.rgb;
	if (additive) {
		soft = pow(clamp(1.0 - r, 0.0, 1.0), 2.0);
	} else {
		// A lumpy, billowy edge rather than a perfect disc.
		float ang = atan(d.y, d.x);
		float lump = 0.09 * sin(ang * 3.0 + v_seed * 17.0) + 0.06 * sin(ang * 5.0 - v_seed * 29.0);
		soft = smoothstep(1.0, 0.1, r + lump);
		// Denser in the middle, a little lighter on top: reads as volume.
		soft *= 0.75 + 0.25 * smoothstep(0.9, 0.0, r);
		c *= mix(0.86, 1.06, clamp(v_shade, 0.0, 1.0));
		// Smoke takes the scene's light: darker at night.
		c *= mix(1.0, 0.25, night);
	}
	ALBEDO = c * (additive ? 3.0 : 1.0);
	ALPHA = clamp(COLOR.a * soft * alpha * v_fade, 0.0, 1.0);
}
