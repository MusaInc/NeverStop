// Shared lawn/verge shading (ground.gdshader, island_ground.gdshader).
// p = world xz in metres, c = the surface's base green (linear), near = 1 up
// close → 0 far (fine detail fades so it never shimmers), aa = pixel size in
// metres. Broad lush ↔ dry drift, clover and straw patches, streaky blades
// and the odd daisy/buttercup up close.

float gr_hash(vec2 p) {
	vec3 p3 = fract(vec3(p.xyx) * 0.1031);
	p3 += dot(p3, p3.yzx + 33.33);
	return fract((p3.x + p3.y) * p3.z);
}

float gr_noise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	return mix(mix(gr_hash(i), gr_hash(i + vec2(1.0, 0.0)), f.x), mix(gr_hash(i + vec2(0.0, 1.0)), gr_hash(i + vec2(1.0, 1.0)), f.x), f.y);
}

vec3 grass_shade(vec3 c, vec2 p, float near, float aa) {
	float lum = dot(c, vec3(0.3, 0.55, 0.15));
	vec3 lush = c * vec3(0.82, 1.0, 0.78);
	vec3 dry = vec3(lum * 1.25, lum * 1.12, lum * 0.55);
	// Broad drift (tens of metres): wetter hollows and drier rises.
	float broad = gr_noise(p / 38.0) * 0.65 + gr_noise(p / 13.0) * 0.35;
	vec3 g = mix(lush, mix(c, dry, 0.35), smoothstep(0.35, 0.8, broad));
	// Straw patches where it's thin and sun-baked.
	float straw = smoothstep(0.66, 0.8, gr_noise(p / 9.0 + 31.0));
	g = mix(g, dry * vec3(1.05, 0.98, 0.9), straw * 0.55);
	// Clover / moss: darker, bluer green clumps.
	float clover = smoothstep(0.62, 0.75, gr_noise(p / 2.6 + 7.0));
	g = mix(g, c * vec3(0.62, 0.78, 0.66), clover * 0.5);
	// Mid tuft variation (≈ 0.7 m), always on, gentle.
	g *= 0.9 + 0.2 * gr_noise(p * 1.4);
	// Blades up close: short streaks (stretched cells, a little skewed),
	// faded out as soon as a cell gets near pixel size.
	float bl = smoothstep(0.08, 0.02, aa) * near;
	if (bl > 0.0) {
		vec2 q = vec2(p.x * 9.0 + p.y * 2.0, p.y * 3.0 - p.x * 0.6);
		float b1 = gr_hash(floor(q));
		float b2 = gr_hash(floor(q * vec2(1.7, 1.3) + 5.0));
		g *= mix(1.0, 0.78 + 0.34 * b1 * b2 + 0.12 * b1, bl);
		// Flowers: a few white daisies / yellow buttercups per square metre.
		vec2 fc = floor(p * 4.0);
		float fh = gr_hash(fc + 91.0);
		vec2 fo = fract(p * 4.0) - 0.5 - (vec2(gr_hash(fc + 3.0), gr_hash(fc + 9.0)) - 0.5) * 0.5;
		float dot_ = (1.0 - smoothstep(0.07, 0.12, length(fo))) * step(0.985, fh) * (1.0 - straw);
		g = mix(g, fh > 0.993 ? vec3(0.9, 0.78, 0.15) : vec3(0.88, 0.88, 0.84), dot_ * bl);
	}
	return g;
}
