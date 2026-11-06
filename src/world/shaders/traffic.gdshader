// Cars driven entirely on the GPU: each MultiMesh instance sits at the start
// of a lane segment facing along it; INSTANCE_CUSTOM = (speed m/s, phase m,
// segment length m, unused). The car slides along local -Z and wraps.
// One material per car surface: paint takes the instance colour, others keep
// their own tint; lamps emit.
shader_type spatial;
render_mode cull_back, diffuse_burley;

// Road surface height (CityWorld bakes CityTerrain.road_y): moving cars ride
// the terrain vertex by vertex, so they pitch with the street's grade.
global uniform sampler2D ground_height : filter_linear, repeat_disable;
global uniform vec4 ground_rect;
global uniform float night;
global uniform float wetness;
uniform vec3 tint : source_color = vec3(1.0);
uniform bool use_instance_color = false;
uniform float emission = 0.0;
uniform float roughness = 0.4;

void vertex() {
	float spd = INSTANCE_CUSTOM.x;
	float len = INSTANCE_CUSTOM.z;
	float d = mod(INSTANCE_CUSTOM.y + TIME * spd, len);
	// Shrink over the first/last metres so wrapping at the segment ends isn't a pop.
	float s = smoothstep(0.0, 4.0, d) * smoothstep(len, len - 4.0, d);
	VERTEX *= s;
	VERTEX.z -= d;
	if (spd > 0.0) {  // parked cars are placed on the ground by the CPU
		vec3 w = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
		vec2 hh = texture(ground_height, (w.xz - ground_rect.xy) / ground_rect.zw).rg;
		// North-south traffic rides road decks (R); east-west passes under (G).
		VERTEX.y += abs(MODEL_MATRIX[2].z) > 0.7 ? hh.r : hh.g;
	}
}

void fragment() {
	vec3 c = use_instance_color ? COLOR.rgb : tint;
	ALBEDO = c;
	ROUGHNESS = mix(roughness, roughness * 0.5, wetness);
	METALLIC = use_instance_color ? 0.35 : 0.0;
	EMISSION = tint * emission * (1.0 + 3.5 * night);  // headlights and tail lights after dark
}
