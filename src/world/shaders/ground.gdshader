// Streets, pavements, lawns. COLOR.rgb tint; UV = world XZ metres on the
// flat surfaces (kerb faces keep their own UVs).
// With the road field (CityRoads.bake_field: per texel the nearest road's
// signed offset, half width (negative = boulevard), distance along it and the
// distance to the nearest other road's kerb) the asphalt gets its lane paint
// (following curves), zebra crossings and stop lines at every junction
// mouth, tyre wear, gutters, drains, manholes and patch repairs; pavements
// get a kerb edge, flagstones by the road and larger paving / brick in the
// courtyards behind; lawns get mowing stripes and a gravel path round the
// edge. All of it is maths on one 2-D lookup – no extra geometry.
shader_type spatial;
render_mode cull_back, diffuse_burley;

uniform sampler2D road_field : filter_linear, repeat_disable;
uniform vec4 road_rect = vec4(0.0, 0.0, 1.0, 1.0);  // x, z origin, x, z size (m)
uniform bool has_streets = false;
global uniform float wetness;
global uniform float rain;

varying float v_up;
varying float v_dist;
varying vec3 v_world;

float hash12(vec2 p) {
	vec3 p3 = fract(vec3(p.xyx) * 0.1031);
	p3 += dot(p3, p3.yzx + 33.33);
	return fract((p3.x + p3.y) * p3.z);
}

float vnoise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash12(i), hash12(i + vec2(1, 0)), f.x), mix(hash12(i + vec2(0, 1)), hash12(i + vec2(1, 1)), f.x), f.y);
}

// 1 inside a band of half-width h around 0, antialiased by aa.
float band(float d, float h, float aa) {
	return 1.0 - smoothstep(h - aa, h + aa, abs(d));
}

void vertex() {
	v_up = NORMAL.y;
	v_dist = length((MODELVIEW_MATRIX * vec4(VERTEX, 1.0)).xyz);
	v_world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	vec3 c = COLOR.rgb;
	vec2 p = UV;
	float n = vnoise(p * 0.35) * 0.6 + vnoise(p * 2.1) * 0.4;
	float near = 1.0 - smoothstep(70.0, 240.0, v_dist);  // fine detail fades out (no shimmer)
	float aa = max(fwidth(p.x) + fwidth(p.y), 0.004) * 0.6;
	vec3 albedo = c * (0.88 + 0.2 * n);
	float rough = 0.92;
	bool flat_top = v_up > 0.5;
	bool asphalt = c.r < 0.3 && c.g < 0.3;
	bool grass = c.g > c.r + 0.08;
	bool pave = c.r > 0.5 && c.g > 0.5 && c.r < 0.85;

	bool shore = abs(COLOR.a * 8.0 - 5.0) < 0.3;  // BuildingMesher.KIND_SHORE

	if (shore) {
		// Rock round the cliffs (strata, big blotches, lichen on the flats) or
		// sand on the beaches; everything darkens and shines where it's wet.
		if (c.r < 0.6) {
			// Bedding planes: crisp horizontal layers of different tone, gently warped.
			float yb = v_world.y + 3.0 * vnoise(p * 0.04);
			float layer = hash12(vec2(floor(yb / 1.7), 3.0));
			float edge = band(fract(yb / 1.7) - 0.5, 0.47, 0.03);
			float big = vnoise(p * 0.07);
			vec3 warm = vec3(0.3, 0.26, 0.22);
			albedo = mix(c, warm, big) * (0.62 + 0.55 * layer) * (0.75 + 0.25 * edge)
				* (0.88 + 0.18 * vnoise(p * 1.3 + v_world.y));
			albedo *= 0.8 + 0.25 * smoothstep(0.2, 0.9, v_up);  // steep faces darker, ledges lighter
			albedo = mix(albedo, vec3(0.32, 0.37, 0.24), smoothstep(0.8, 0.97, v_up) * 0.45 * vnoise(p * 0.25));
		} else {
			albedo = c * (0.93 + 0.08 * vnoise(p * 0.45) + 0.04 * vnoise(p * 3.1));
			rough = 0.97;
		}
		float wet = 1.0 - smoothstep(-1.4, 0.5, v_world.y);
		albedo *= 1.0 - 0.38 * wet;
		rough = mix(rough, 0.35, wet);
	} else if (c.r > 0.85) {
		albedo = c * (0.9 + 0.1 * n);  // old painted geometry (prototype world)
	} else if (has_streets && flat_top) {
		vec4 rf = texture(road_field, (p - road_rect.xy) / road_rect.zw);
		float hw = abs(rf.y);
		float a = abs(rf.x);
		bool on = a < hw;
		float other = rf.w;                     // metres from the nearest other road's kerb (< 0: junction)
		// Metres from the nearest kerb line (negative on the road).
		float kerb = min(a - hw, other);
		if (asphalt) {
			// Aged tarmac: neutral grey (not blue), with a broad tone drift
			// (resurfaced stretches, sun-bleached runs) and fine aggregate
			// mottling up close, so shaded streets still read as a surface.
			float drift = vnoise(p * 0.022 + 31.0) * 0.6 + vnoise(p * 0.09) * 0.4;
			float grain = vnoise(p * 3.1) * near;
			albedo = c * vec3(0.66, 0.66, 0.67) * (0.84 + 0.3 * drift) * (0.94 + 0.12 * grain);
			// Large-scale tone drift + patch repairs (sharp-edged, slightly off-tone).
			vec2 pc = floor(p / vec2(5.0, 3.0));
			float patch = step(0.86, hash12(pc + 17.0));
			albedo *= 1.0 + (hash12(pc) - 0.5) * 0.12 * patch * near;
			if (on && other > 0.0) {
				float across = rf.x;
				float avenue = rf.y < 0.0 ? 1.0 : 0.0;
				float along = rf.z;                 // metres along the road (mod 64)
				float from_j = other;               // metres past the junction mouth
				// Tyre tracks: two polished bands per 3.5 m lane.
				float lane_d = abs(fract(a / 3.5) - 0.5) * 3.5;
				float tracks = band(lane_d - 0.85, 0.28, 0.25) * step(0.9, hw - a) * near;
				albedo *= 1.0 - 0.07 * tracks;
				rough -= 0.12 * tracks;
				// Gutter: grimy last 0.5 m along the kerb, drain grates every 16 m.
				float gutter = smoothstep(hw - 0.7, hw - 0.3, a);
				albedo *= 1.0 - 0.22 * gutter;
				float grate = band(fract(along / 16.0 + 0.5) * 16.0 - 8.0, 0.45, aa) * band(a - (hw - 0.45), 0.25, aa);
				albedo = mix(albedo, vec3(0.06), grate * near);
				// Manholes in the lanes now and then.
				float cell = floor(along / 32.0);
				float mh_on = step(0.55, hash12(vec2(cell, hw + sign(across))));
				vec2 mh = vec2(fract(along / 32.0) * 32.0 - 16.0, a - min(1.9, hw * 0.5));
				float ring = length(mh);
				albedo *= 1.0 - 0.25 * band(ring, 0.38, aa) * mh_on * near;
				albedo *= 1.0 - 0.35 * band(ring - 0.38, 0.04, aa) * mh_on * near;
				// Paint: centre line (double yellow on boulevards, dashed white on
				// streets), zebra crossings and stop lines at every junction mouth.
				vec3 white = vec3(0.9, 0.9, 0.86);
				vec3 yellow = vec3(0.92, 0.76, 0.25);
				float wear = 0.82 + 0.18 * vnoise(p * 1.7);
				float centre = avenue > 0.5
					? band(a - 0.22, 0.07, aa) * step(4.6, from_j)
					: band(across, 0.07, aa) * step(5.0, from_j) * step(fract(along / 8.0), 0.375);
				albedo = mix(albedo, (avenue > 0.5 ? yellow : white) * wear, centre);
				// Boulevards: dashed lane dividers between the two lanes each way.
				float divider = avenue * step(10.0, hw) * band(a - 5.1, 0.07, aa) * step(5.0, from_j)
					* step(fract(along / 9.0), 0.33);
				albedo = mix(albedo, white * wear, divider);
				float zebra_u = fract((across + hw - 1.5) / 1.2);
				float zebra = band(zebra_u - 0.5, 0.25, aa / 1.2) * step(from_j, 4.0) * step(1.0, from_j)
					* step(a, hw - 1.0);
				float stop = band(from_j - 4.8, 0.22, aa) * step(0.3, a) * step(a, hw - 0.3);
				albedo = mix(albedo, white * wear, max(zebra, stop));
				rough = mix(rough, 0.7, max(centre, max(zebra, stop)));
			} else if (on) {
				albedo *= 1.03;  // junctions: a touch lighter, worn smooth
			}
		} else if (pave) {
			c *= vec3(0.8, 0.83, 0.88);
			if (kerb < 0.32) {
				// Kerb stones: lighter granite with joints.
				float j = step(0.94, fract((p.x + p.y) / 0.9));
				albedo = c * 1.12 * (1.0 - 0.15 * j * near);
			} else if (kerb < 3.3) {
				// Pavement flagstones by the road, each a slightly different tone.
				vec2 f = fract(p / 1.2);
				vec2 id = floor(p / 1.2);
				float joint = max(band(f.x, 0.03, aa / 1.2), band(f.y, 0.03, aa / 1.2));
				joint = max(joint, max(band(f.x - 1.0, 0.03, aa / 1.2), band(f.y - 1.0, 0.03, aa / 1.2)));
				albedo = c * (0.93 + 0.1 * hash12(id)) * (1.0 - 0.14 * joint * near);
				albedo *= 1.0 - 0.08 * step(0.97, hash12(id + 3.0)) * near;  // the odd stained slab
			} else {
				// Courtyards, forecourts and gaps behind the pavement: big
				// concrete slabs or warm brick paving, by area.
				float zone = vnoise(p / 45.0);
				vec3 brick = vec3(0.5, 0.41, 0.37);
				vec2 b = p * vec2(4.0, 8.0);
				b.x += step(1.0, mod(floor(b.y), 2.0)) * 0.5;
				vec2 bf = fract(b);
				float mortar = max(step(bf.x, 0.08), step(bf.y, 0.12)) * near;
				vec3 bricks = brick * (0.9 + 0.12 * hash12(floor(b))) * (1.0 - 0.18 * mortar);
				vec2 sf = fract(p / 3.0);
				float seam = max(band(sf.x, 0.02, aa / 3.0), band(sf.y, 0.02, aa / 3.0));
				vec3 slabs = c * 0.9 * (0.94 + 0.1 * hash12(floor(p / 3.0))) * (1.0 - 0.12 * seam * near);
				albedo = mix(slabs, bricks, smoothstep(0.6, 0.68, zone));
			}
		} else if (grass) {
			// Lawn: mowing stripes, soft colour drift, a gravel path round the edge.
			float stripe = step(0.5, fract(p.x / 6.0));
			albedo = c * (0.9 + 0.16 * vnoise(p * 0.18)) * (1.0 + 0.06 * (stripe - 0.5) * near);
			float path = band(kerb - 4.8, 1.0, aa);
			albedo = mix(albedo, vec3(0.62, 0.56, 0.45) * (0.92 + 0.12 * n), path);
		}
	} else if (pave && flat_top) {
		vec2 f = fract(p / 1.8);
		albedo *= 1.0 - 0.1 * (step(f.x, 0.03) + step(f.y, 0.03));
	}
	if (!shore && v_up < 0.3 && COLOR.a < 0.06) {
		// Retaining walls (BuildingMesher._skirt, KIND_WALL; UV = metres along,
		// world y): coursed dressed stone instead of a flat grey slab – 0.6 m
		// courses of 1.2 m blocks, alternate courses half offset, recessed
		// joints, a little tone per block and faint rain streaks running down.
		float yy = v_world.y;
		float row = floor(yy / 0.6);
		float bx = p.x / 1.2 + 0.5 * mod(row, 2.0);
		vec2 blk = vec2(floor(bx), row);
		float tone = hash12(blk + 7.0);
		float jx = abs(fract(bx) - 0.5) * 1.2;          // m from the block's centre (along)
		float jy = abs(fract(yy / 0.6) - 0.5) * 0.6;    // (up)
		float joint = max(band(jx - 0.6, 0.025, aa), band(jy - 0.3, 0.022, aa)) * near;
		albedo = c * (0.9 + 0.16 * tone) * (0.93 + 0.1 * vnoise(vec2(p.x, yy) * 1.7));
		albedo *= 1.0 - 0.3 * joint;
		float streak = smoothstep(0.55, 0.9, vnoise(vec2(p.x * 1.8, yy * 0.08))) * 0.12;
		albedo *= 1.0 - streak;
		rough = 0.88;
	}
	if (wetness > 0.001 && flat_top) {
		// Wet streets: everything darkens and gets a sheen; puddles collect in
		// the dips of a low-frequency noise (and fill as the rain goes on),
		// mirror-smooth and – while it's raining – rippled.
		float pud = smoothstep(0.62 - 0.22 * wetness, 0.7 - 0.22 * wetness, vnoise(p * 0.11) * 0.7 + vnoise(p * 0.43) * 0.3);
		pud *= wetness * (asphalt ? 1.0 : 0.6);
		albedo *= 1.0 - 0.3 * wetness - 0.25 * pud;
		rough = mix(rough, 0.3, wetness * 0.8);
		rough = mix(rough, 0.03 + 0.12 * rain * vnoise(p * 6.0 + TIME * 3.0), pud);
	}
	ALBEDO = albedo;
	ROUGHNESS = rough;
	SPECULAR = 0.25 + 0.55 * wetness;  // (dry tarmac and stone barely mirror the sky)
}
