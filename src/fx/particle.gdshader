shader_type spatial;
// Billboarded soft particles for VehicleFx pools: the instance transform's
// basis is a uniform scale, the shader faces it to the camera. Colour and
// alpha come from the instance colour. Additive for sparks/fire.
render_mode unshaded, cull_disabled, depth_draw_never, blend_mix;

uniform bool additive = false;
uniform float alpha = 1.0;
global uniform float night;

void vertex() {
	vec3 pos = MODEL_MATRIX[3].xyz;
	float s = length(MODEL_MATRIX[0].xyz);
	MODELVIEW_MATRIX = VIEW_MATRIX * mat4(INV_VIEW_MATRIX[0] * s, INV_VIEW_MATRIX[1] * s, INV_VIEW_MATRIX[2] * s, vec4(pos, 1.0));
	MODELVIEW_NORMAL_MATRIX = mat3(MODELVIEW_MATRIX);
}

void fragment() {
	vec2 d = UV - vec2(0.5);
	float r = length(d) * 2.0;
	float soft = additive ? pow(clamp(1.0 - r, 0.0, 1.0), 2.0) : smoothstep(1.0, 0.2, r);
	vec3 c = COLOR.rgb;
	if (!additive) {
		// Smoke takes the scene's light: darker at night.
		c *= mix(1.0, 0.25, night);
	}
	ALBEDO = c * (additive ? 3.0 : 1.0);
	ALPHA = clamp(COLOR.a * soft * alpha, 0.0, 1.0);
}
