shader_type spatial;
// The visible headlight beam at night: a flattened cone, additive, fading
// along its length and at its silhouette edges (so it reads as lit air, not
// a solid cone). Only the player's car has one.
render_mode unshaded, blend_add, cull_disabled, depth_draw_never, shadows_disabled;

uniform vec3 color : source_color = vec3(1.0, 0.93, 0.8);
uniform float strength = 0.11;
uniform float height = 18.0;
global uniform float night;

varying float v_t;

void vertex() {
	// CylinderMesh: narrow end (top_radius) at +height/2.
	v_t = clamp((height * 0.5 - VERTEX.y) / height, 0.0, 1.0);
}

void fragment() {
	float edge = pow(abs(dot(NORMAL, VIEW)), 1.6);
	float along = smoothstep(0.0, 0.08, v_t) * pow(1.0 - v_t, 1.8);
	ALBEDO = color * strength * night * edge * along;
}
