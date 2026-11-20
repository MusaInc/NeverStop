// Natural coastal rock, shared by every shore: the city cliffs and armour
// (ground.gdshader), Skyport's and the landforms' rock bands and the sea
// floor (island_ground.gdshader). Same look everywhere, so a headland's rock
// runs on into the city's cliff without a seam.
//
// Projected along the face: steep surfaces use (metres along the coast,
// height), flat ones world x/z – the old world-x/z pattern smeared into
// vertical stripes down every cliff and read as camouflage blotches.
// Jointed blocks (two cell sizes, taller than wide on faces: columnar
// joints), dark fractures between them, each block its own tone, ledges
// lit and tufted with thrift/grass, a black-green wet band and pale salt
// just above the water. Fine detail fades with the pixel footprint `fp`.

float rk_hash(vec2 p) {
	vec3 p3 = fract(vec3(p.xyx) * 0.1031);
	p3 += dot(p3, p3.yzx + 33.33);
	return fract((p3.x + p3.y) * p3.z);
}

float rk_noise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	return mix(mix(rk_hash(i), rk_hash(i + vec2(1, 0)), f.x), mix(rk_hash(i + vec2(0, 1)), rk_hash(i + vec2(1, 1)), f.x), f.y);
}

// Cells: x = distance to the nearest cell edge (F2 - F1), y = that cell's hash.
vec2 rk_cells(vec2 q) {
	vec2 ci = floor(q);
	float d1 = 9.0;
	float d2 = 9.0;
	float h = 0.0;
	for (int k = 0; k < 9; k++) {
		vec2 o = ci + vec2(float(k % 3) - 1.0, float(k / 3) - 1.0);
		vec2 c = o + 0.15 + 0.7 * vec2(rk_hash(o), rk_hash(o + 5.3));
		float d = length(q - c);
		if (d < d1) { d2 = d1; d1 = d; h = rk_hash(o + 11.0); }
		else if (d < d2) { d2 = d; }
	}
	return vec2(d2 - d1, h);
}

// base: the rock's own colour (linear); wp: world position; wn: world normal.
vec3 rock_look(vec3 base, vec3 wp, vec3 wn, float fp, float near, inout float rough) {
	float up = clamp(wn.y, -1.0, 1.0);
	float steep = 1.0 - smoothstep(0.55, 0.85, up);
	vec2 hz = normalize(wn.xz + vec2(1e-4));
	float along = dot(wp.xz, vec2(-hz.y, hz.x));
	// Face coordinates (columnar: blocks taller than wide) or plan.
	vec2 q = mix(wp.xz, vec2(along, wp.y * 0.62), steep);
	float det = 1.0 - smoothstep(0.35, 1.6, fp);
	float det2 = 1.0 - smoothstep(0.12, 0.6, fp);
	vec2 big = rk_cells(q / 3.4 + vec2(0.0, 17.0));
	vec2 small = rk_cells(q / 1.15 + vec2(31.0, 4.0));
	float crack = (1.0 - smoothstep(0.0, 0.11 + fp * 0.08, big.x)) * det;
	float crack2 = (1.0 - smoothstep(0.0, 0.08 + fp * 0.1, small.x)) * det2 * 0.6;
	// Broad tone: warm and cool stone, stained streaks down the faces.
	float macro = rk_noise(wp.xz * 0.025 + vec2(3.0, 1.0)) * 0.6 + rk_noise(wp.xz * 0.09) * 0.4;
	vec3 albedo = base * mix(vec3(0.92, 0.95, 1.02), vec3(1.12, 1.02, 0.9), macro);
	albedo *= 0.8 + 0.42 * mix(0.5, big.y, det) + 0.14 * (small.y - 0.5) * det2;
	float streak = rk_noise(vec2(along * 0.45, wp.y * 0.04)) * steep;
	albedo *= 1.0 - 0.18 * smoothstep(0.55, 0.8, streak);
	// Flat shelves and armour read as heaped boulders, not crazy paving:
	// each cell domed (shadowed into its gaps), thin cracks only on faces,
	// some stones warmer, darker gravel and weed in the gaps.
	float flatk = 1.0 - steep;
	float dome = smoothstep(0.0, 0.42, big.x) * 0.7 + smoothstep(0.0, 0.3, small.x) * 0.3;
	albedo *= mix(1.0, 0.5 + 0.56 * dome, flatk * det);
	albedo *= mix(vec3(1.0), vec3(1.1, 1.0, 0.86), step(0.72, big.y) * flatk);
	crack *= mix(1.0, 0.3, flatk);
	crack2 *= mix(1.0, 0.4, flatk);
	albedo *= 1.0 - 0.55 * crack - 0.3 * crack2;
	// Ledges catch the light; the undersides of overhangs are dark.
	albedo *= mix(0.72, 1.08, smoothstep(-0.2, 0.9, up));
	// Pale lichen on the dry upper faces (soft-edged, never a hard patch).
	float dry = smoothstep(0.4, 3.4, wp.y);   // (the sea is at -1.6)
	float lich = smoothstep(0.55, 0.85, rk_noise(q * 0.7 + 9.0)) * dry * 0.35 * det;
	albedo = mix(albedo, vec3(0.62, 0.62, 0.52) * base.r / max(base.r, 0.05) * 0.9, lich);
	// Tufts of grass/thrift on ledges and the cliff top.
	float ledge = smoothstep(0.62, 0.9, up) * smoothstep(0.0, 2.0, wp.y);
	float tuft = ledge * smoothstep(0.4, 0.62, rk_noise(wp.xz * 0.55 + 2.0) * 0.7 + rk_noise(wp.xz * 2.3) * 0.3);
	albedo = mix(albedo, vec3(0.13, 0.19, 0.07) * (0.8 + 0.4 * rk_noise(wp.xz * 1.7)), tuft * 0.85);
	// Salt crust above the splash zone, then black-green wet weed.
	float salt = smoothstep(-1.3, -0.7, wp.y) * (1.0 - smoothstep(-0.2, 1.0, wp.y + 0.6 * rk_noise(q * 0.8)));
	albedo = mix(albedo, vec3(0.6, 0.6, 0.56) * 0.75, salt * 0.25);
	float wet = 1.0 - smoothstep(-1.9, -0.9, wp.y + 0.3 * rk_noise(q * 1.3));
	albedo = mix(albedo, albedo * 0.45 + vec3(0.01, 0.025, 0.012), wet);
	rough = mix(0.88, 0.42, wet);
	return albedo;
}
