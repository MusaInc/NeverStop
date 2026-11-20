// Sea, strait and dock water. Still no screen-space reads (cheap on mobile):
//  * swell: ten wave trains spread round a veering wind, wavelengths with
//    no common ratios and deep-water speeds (so they never settle into a
//    grid), each rising and falling in drifting groups; gradient-noise chop
//    up close; all fade with distance so the far sea doesn't shimmer;
//  * colour: a deep blue-green body, lighter turquoise where the light comes
//    through wave crests facing the sun, darker in the troughs;
//  * reflection: the sky gradient (sky_top / sky_horizon) by Schlick fresnel,
//    emitted so it reads at any sun angle, plus a tight sun highlight and a
//    wider glitter path that sparkles on the wave facets;
//  * whitecaps on the steepest crests when it blows (rain/storm), and a pock
//    of fine ripples in the rain;
//  * night: the body goes inky and the reflection follows the dark sky;
//  * depth (a baked seabed): light is absorbed by depth, red first, so sand
//    shelves read turquoise, rock darker, channels deep blue; the bottom –
//    sand ripples or rock – shows through with a little parallax; the swell
//    calms in the shallows and a line of surf runs in to the shore; a storm
//    stirs the water up (less clear).
shader_type spatial;
render_mode cull_disabled, diffuse_burley, specular_schlick_ggx, depth_draw_always;

uniform vec3 deep : source_color = vec3(0.03, 0.12, 0.17);
uniform vec3 shallow : source_color = vec3(0.07, 0.34, 0.38);
// The seabed (tools/bake_seabed.gd): L = depth / seabed_max, A = how rocky
// the nearest shore is. Outside seabed_rect the sea is deep.
uniform sampler2D seabed : filter_linear, repeat_disable;
uniform vec4 seabed_rect = vec4(-2400.0, -1800.0, 4800.0, 4800.0);
uniform float seabed_max = 32.0;
uniform bool has_seabed = false;
uniform float shallow_visibility = 0.78;
uniform float clear_depth_start = 0.5;
uniform float clear_depth_end = 10.0;
global uniform vec3 sky_top;
global uniform vec3 sky_horizon;
global uniform vec3 sun_dir;
global uniform float rain;
global uniform float night;

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

// Gradient noise (smooth, no value-noise blockiness), in [-1, 1]-ish.
vec2 grad2(vec2 i) {
	// (No trig: two hashes, roughly unit length – cheap on mobile.)
	return vec2(hash12(i), hash12(i + 19.19)) * 2.0 - 1.0;
}

float gnoise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	vec2 u = f * f * f * (f * (f * 6.0 - 15.0) + 10.0);
	float a = dot(grad2(i), f);
	float b = dot(grad2(i + vec2(1, 0)), f - vec2(1, 0));
	float c = dot(grad2(i + vec2(0, 1)), f - vec2(0, 1));
	float d = dot(grad2(i + vec2(1, 1)), f - vec2(1, 1));
	return mix(mix(a, b, u.x), mix(c, d, u.x), u.y) * 1.6;
}

// One wave train: height and its slope (d/dx, d/dz).
vec3 wave(vec2 p, vec2 dir, float len, float amp, float speed) {
	float k = 6.28318 / len;
	float ph = dot(dir, p) * k - TIME * speed * k;
	float s = sin(ph);
	float c = cos(ph);
	// Sharpened crests (a cheap trochoid look): narrow peaks, wide troughs.
	float h = amp * (s * 0.5 + 0.5);
	h = h * h / amp;
	float dh = amp * k * c * (s * 0.5 + 0.5);
	return vec3(h, dir * dh);
}

void vertex() {
	v_world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	// Warp the plane a little and vary the swell's strength in broad
	// patches, so the wave trains never read as a regular grid.
	vec2 p0 = v_world.xz;
	// (Two scales: 60 m bends and 250 m meanders, so no crest runs straight.)
	vec2 p = p0 + vec2(gnoise(p0 * 0.004 + 3.1), gnoise(p0 * 0.004 + 41.7)) * 28.0
		+ vec2(vnoise(p0 * 0.018), vnoise(p0 * 0.018 + 17.3)) * 9.0;
	float patchy = 0.55 + 0.9 * vnoise(p0 * 0.009 + TIME * 0.01);
	float dist = length(v_world - CAMERA_POSITION_WORLD);
	float near = 1.0 - smoothstep(60.0, 420.0, dist);
	float mid = 1.0 - smoothstep(250.0, 1600.0, dist);
	// Helicopter height: from up high the regular wave trains add up into
	// bands and a diamond lattice; there the sea is shaped by a noise field
	// (wind patches, slicks, swell groups) instead.
	float alt = smoothstep(35.0, 260.0, CAMERA_POSITION_WORLD.y - v_world.y);
	float blow = clamp(rain, 0.0, 1.0);
	float depth = seabed_max;
	float rocky = 1.0;
	if (has_seabed) {
		vec2 suv = (p0 - seabed_rect.xy) / seabed_rect.zw;
		if (suv.x > 0.0 && suv.y > 0.0 && suv.x < 1.0 && suv.y < 1.0) {
			vec4 sb = texture(seabed, suv);
			// (Fade to open sea over the bake's last 3%: no rectangle edge.)
			float edge = smoothstep(0.0, 0.03, min(min(suv.x, 1.0 - suv.x), min(suv.y, 1.0 - suv.y)));
			depth = mix(seabed_max, max(sb.r * seabed_max, 0.25), edge);
			rocky = mix(1.0, sb.a, edge);
		}
	}
	// Shallow water: the swell shortens and calms (and it can't be taller
	// than the water is deep).
	float calm = mix(0.2, 1.0, smoothstep(0.8, 9.0, depth));
	float sw = (1.0 + 0.8 * blow) * patchy * calm;
	// The swell: ten trains spread round a slowly veering wind (golden-angle
	// spread, so no two line up), wavelengths 41 m → 2 m in steps of ×0.74
	// (no common ratios: the trains never fall into a grid), each moving at
	// its own deep-water speed (√(gL/2π) – slower in the shallows), and each
	// rising and falling in slow-drifting groups. A train fades out once a
	// pixel covers a good part of its wavelength (no moiré from altitude).
	float fp = length(fwidth(p0)) + 0.001;
	float wind = 0.62 + 0.25 * sin(TIME * 0.011) + 0.35 * (gnoise(p0 * 0.0007) );
	vec3 w = vec3(0.0);
	float amp_sum = 0.0;
	float L = 41.0;
	for (int i = 0; i < 10; i++) {
		float fi = float(i);
		float ang = wind + (fract(fi * 0.618034) - 0.5) * mix(1.6, 2.4, fi / 9.0);
		vec2 dir = vec2(cos(ang), sin(ang));
		float c = sqrt(9.81 * L / 6.28318);
		c = min(c, sqrt(9.81 * max(depth, 0.4)));            // (shallow water slows it)
		// (Groups are 150 m+ across: the cheap value noise is smooth enough.)
		float group = 0.45 + 0.9 * vnoise(p0 * (0.004 + 0.0013 * fi) + dir * TIME * 0.02 + fi * 7.3);
		float a = L * 0.021 * sw * group * (i < 3 ? 1.0 : 0.85);
		float fade = 1.0 - smoothstep(L * 0.05, L * 0.2, fp);
		if (i >= 7) {
			fade *= near;
		}
		w += wave(p, dir, L, a, c) * fade;
		amp_sum += a * fade;
		L *= 0.74;
	}
	// Normalise the crest height for colour and foam (≈ the old 0–1.1 range).
	w.x *= 1.1 / max(amp_sum, 0.01) * min(amp_sum, 1.2);
	// Chop up close (smooth gradient noise, two octaves drifting with the
	// wind) and rain pock-marks.
	vec2 wd = vec2(cos(wind), sin(wind));
	float e = 0.3;
	vec2 q = p * 0.5 + wd * TIME * 0.35;
	vec2 q3 = p * 1.3 + vec2(-wd.y, wd.x) * TIME * 0.22 + 31.0;
	float c0 = gnoise(q) + 0.5 * gnoise(q3);
	vec2 chop = vec2(gnoise(q + vec2(e, 0.0)) + 0.5 * gnoise(q3 + vec2(e, 0.0)) - c0,
		gnoise(q + vec2(0.0, e)) + 0.5 * gnoise(q3 + vec2(0.0, e)) - c0) / e * 0.09 * (1.0 + 0.8 * blow);
	vec2 q2 = p * 2.3 - vec2(TIME * 1.4, -TIME * 1.1);
	float r0 = vnoise(q2);
	vec2 pock = vec2(vnoise(q2 + vec2(0.3, 0.0)) - r0, vnoise(q2 + vec2(0.0, 0.3)) - r0) * 0.5 * blow;
	// (Far off the swell's slopes fade more: seen from height the trains
	// interfere into a regular ripple grid.)
	vec2 slope = w.yz * mix(0.12, 1.0, mid * mid) * mix(1.0, 0.3, alt) + (chop + pock) * near * (1.0 - smoothstep(0.15, 0.6, fp));
	// (Over the shallows the surface is glassier still: no swell grid over
	// a bright sandy floor.)
	slope *= mix(0.35, 1.0, smoothstep(1.0, 10.0, depth));
	// (At grazing angles a pixel spans metres along the view: the slopes
	// alias into streaks along the horizon – soften them there.)
	float graze = normalize(CAMERA_POSITION_WORLD - v_world).y;
	slope *= mix(0.4, 1.0, smoothstep(0.04, 0.3, graze));
	// (Far off only the longest trains survive their fade and cross into a
	// diamond lattice: calm them there and let broad wind patches – cat's
	// paws and slicks – shape the reflection instead.)
	float farw = max(smoothstep(180.0, 800.0, dist), alt);
	slope *= mix(1.0, 0.5, farw);
	// Multi-scale noise slopes (90 m, 31 m, 11 m), each octave rotated and
	// drifting downwind, the finest dropped once a pixel spans it: no period,
	// no direction, cheap (gradient noise, finite differences).
	vec2 nsl = vec2(0.0);
	float oct_s = 0.011;
	float oct_a = 0.075;
	mat2 rot = mat2(vec2(0.8, 0.6), vec2(-0.6, 0.8));
	vec2 pn = p0;
	for (int o = 0; o < 3; o++) {
		vec2 qn = pn * oct_s + wd * TIME * (0.05 + 0.04 * float(o));
		float e0 = 0.35;
		float n0 = gnoise(qn);
		vec2 gn = vec2(gnoise(qn + vec2(e0, 0.0)) - n0, gnoise(qn + vec2(0.0, e0)) - n0) / e0;
		nsl += rot * gn * oct_a * (1.0 - smoothstep(0.12, 0.45, fp * oct_s * 2.0));
		pn = rot * pn + 13.7;
		oct_s *= 2.85;
		oct_a *= 0.62;
	}
	slope += nsl * farw * (1.0 + blow) * calm;
	vec3 nw = normalize(vec3(-slope.x, 1.0, -slope.y));
	NORMAL = normalize((VIEW_MATRIX * vec4(nw, 0.0)).xyz);

	vec3 view_w = normalize(CAMERA_POSITION_WORLD - v_world);
	float ndv = clamp(dot(view_w, nw), 0.0, 1.0);
	float fres = 0.02 + 0.98 * pow(1.0 - ndv, 5.0);
	fres = mix(fres, 0.85, smoothstep(900.0, 3500.0, dist) * 0.6);  // far sea: mostly sky
	vec3 r = reflect(-view_w, nw);
	r.y = abs(r.y);
	vec3 sky = mix(sky_horizon, sky_top, pow(clamp(r.y, 0.0, 1.0), 0.6));

	// Body: crests the light shines through go turquoise, troughs deep.
	float crest = clamp(w.x / (1.1 * (1.0 + 0.8 * blow)), 0.0, 1.0);
	// (The crest tint banded the whole sea turquoise from the air: keep it
	// for close-up waves; further off/up the tint follows broad, irregular
	// patches – wind-roughened lanes and calm slicks – at three scales.)
	float broad = gnoise(p0 * 0.0023 + 5.3) * 0.5 + gnoise(p0 * 0.0071 - 2.9) * 0.3 + gnoise(p0 * 0.019 + 8.1) * 0.2;
	float tintk = mix(crest, 0.42 + 0.3 * broad, max(farw, 1.0 - near));
	float through = clamp(dot(normalize(vec3(sun_dir.x, 0.0, sun_dir.z)), -view_w) * 0.5 + 0.5, 0.0, 1.0);
	// Water colour by depth - sandy shallows, muted turquoise, blue-green,
	// deep blue - one continuous ramp. The depth it reads is varied at low
	// frequency (so the shallow band's width wanders with the coast instead
	// of drawing an even outline) and rock shores fall away faster (a narrow,
	// darker fringe; sand shelves a wider, paler one).
	float dvar = depth * (1.0 + 0.32 * gnoise(p0 * 0.0045 + 1.7) + 0.12 * gnoise(p0 * 0.017 - 4.2)) * mix(1.0, 1.75, rocky);
	vec3 ramp = mix(vec3(0.2, 0.32, 0.29), vec3(0.08, 0.25, 0.27), smoothstep(0.4, 3.0, dvar));
	ramp = mix(ramp, vec3(0.045, 0.17, 0.205), smoothstep(2.5, 8.0, dvar));
	ramp = mix(ramp, deep, smoothstep(6.0, 18.0, dvar));
	vec3 body = mix(ramp, mix(deep, shallow, 0.55), tintk * mix(0.3 + 0.35 * through, 0.3, farw) * 0.5 * (1.0 - night * 0.8));
	body *= mix(1.0, 0.25, night);
	body *= mix(vec3(1.0), vec3(0.75, 0.82, 0.85), blow);  // grey under a storm sky

	// Sun: a tight highlight and a wider glitter path on the facets.
	float sd = max(dot(r, sun_dir), 0.0);
	float day = clamp(sun_dir.y * 4.0, 0.0, 1.0) * (1.0 - night) * (1.0 - 0.85 * blow);
	float glint = pow(sd, 900.0) * 30.0 * (1.0 - 0.95 * alt) + pow(sd, 90.0) * 1.6 * (0.4 + 0.6 * clamp(gnoise(p * 1.7 + TIME * 0.8) * 0.5 + 0.5, 0.0, 1.0)) * near;
	// From the air the tight facet highlight broke into hard white blobs
	// (read as foam slabs): there it's a soft glitter path instead.
	glint += pow(sd, 24.0) * 0.35 * alt;
	vec3 sun_col = mix(vec3(1.0, 0.72, 0.45), vec3(1.0, 0.96, 0.88), clamp(sun_dir.y * 2.5, 0.0, 1.0));

	// Whitecaps on the steepest crests when it blows (and a few on a calm day).
	// (Broken into short patches along each crest – one long sine crest
	// made a straight pale stripe across the water, two or three of them
	// parallel off every quay on a calm day.)
	float foam = smoothstep(0.84, 0.97, crest) * smoothstep(0.6, 0.85, vnoise(p * 0.9 + TIME * 0.3))
		* smoothstep(0.55, 0.8, vnoise(p * 0.23 - TIME * 0.11)) * smoothstep(0.4, 0.8, vnoise(p0 * 0.02))
		* (0.015 + 0.985 * blow) * mid * near;
	// Surf: lines along the depth contours running in to the shore over the
	// sand shelves (rocks get a ragged wash), broken up along their length;
	// higher seas, bigger surf.
	float surf_zone = smoothstep(2.2, 0.5, depth);
	float lines = sin(depth * 7.5 + TIME * 2.2 + vnoise(p0 * 0.08) * 3.0) * 0.5 + 0.5;
	float surf = surf_zone * smoothstep(0.62, 0.92, lines) * smoothstep(0.3, 0.7, vnoise(p0 * 0.12 + vec2(TIME * 0.15, 0.0)))
		* mix(0.75, 1.0, rocky) * (0.65 + 0.6 * blow) * mid;
	// (From the air the surf lines alias into white blobs a pixel wide:
	// once a pixel spans the lines, a soft even wash along the shore.)
	float surf_far = smoothstep(0.35, 1.4, fp);
	surf = mix(surf, surf_zone * smoothstep(0.6, 2.0, depth) * 0.22 * mix(0.75, 1.0, rocky), surf_far);
	foam = max(foam, surf);

	// The seabed seen through the water. Absorption per metre (red first),
	// over a path that lengthens at grazing angles; a storm stirs it up.
	// (Absorption: red first but not so hard that a metre of water over pale
	// sand glows cyan.)
	vec3 kd = vec3(0.34, 0.16, 0.14) * (1.0 + 1.6 * blow);
	float path = depth * (1.0 + 1.0 / max(ndv, 0.25));
	vec3 tr = exp(-kd * path);
	// (Parallax: the bottom sits below the surface, offset along the view.)
	vec2 bp = p0 - view_w.xz / max(view_w.y, 0.25) * depth * 0.55;
	float ripple = sin(dot(bp, vec2(0.83, 0.55)) * 2.6 + vnoise(bp * 0.35) * 4.0) * 0.5 + 0.5;
	vec3 sand_c = mix(vec3(0.74, 0.7, 0.57), vec3(0.5, 0.52, 0.44), smoothstep(0.5, 5.0, depth))
		* (0.86 + 0.14 * ripple) * (0.9 + 0.2 * vnoise(bp * 0.05));
	float stones = vnoise(bp * 0.45) * 0.6 + vnoise(bp * 1.7) * 0.4;
	vec3 rock_c = mix(vec3(0.16, 0.17, 0.14), vec3(0.34, 0.33, 0.27), stones) * (0.8 + 0.4 * vnoise(bp * 0.06 + 3.0));
	vec3 floor_c = mix(sand_c, rock_c, smoothstep(0.25, 0.75, rocky));
	// Caustics flicker on a shallow sunlit floor.
	float caus = pow(vnoise(bp * 0.9 + vec2(TIME * 0.4, TIME * 0.25)) * vnoise(bp * 1.3 - vec2(TIME * 0.3, 0.0)), 2.0) * 2.4;
	floor_c *= 1.0 + caus * day * exp(-depth * 0.35) * (1.0 - blow);
	floor_c *= mix(1.0, 0.12, night) * mix(1.0, 0.7, blow);
	// Far off the bottom's detail aliases: fade it to its mean.
	float fdet = 1.0 - smoothstep(0.12, 0.9, fp);
	floor_c = mix(mix(vec3(0.72, 0.69, 0.56), vec3(0.3, 0.3, 0.26), smoothstep(0.25, 0.75, rocky)) * mix(1.0, 0.12, night), floor_c, fdet);
	vec3 water_c = body;
	body = floor_c * tr + body * (vec3(1.0) - tr);

	// See-through shallows: where the baked seabed says it's shallow there
	// is real floor geometry under the surface (SeabedMesh, the beaches and
	// rock armour), so the water thins out and shows it – opaque again by
	// ~6 m, wherever the surface reflects (grazing views, fresnel), on foam
	// and glints, in a storm, at night and far off (where the painted floor
	// takes over). Its colour there is the turquoise tint the light picks
	// up through a metre or two of water, not the painted floor.
	float see = has_seabed
                ? 1.0 - smoothstep(clear_depth_start, clear_depth_end, depth)
                : 0.0;
	see *= (1.0 - fres) * (1.0 - foam) * (1.0 - clamp(glint * day, 0.0, 1.0));
	see *= (1.0 - 0.75 * blow) * (1.0 - 0.6 * night) * (1.0 - smoothstep(900.0, 1800.0, dist));
	// (Muted: the old shallow x (1, 1.8, 1.62) glowed cyan round every island.)
	vec3 tint = mix(vec3(0.17, 0.33, 0.31), water_c, smoothstep(1.0, 7.0, depth));
	body = mix(body, tint, see);
	ALPHA = 1.0 - see * shallow_visibility;

	ALBEDO = mix(body * (1.0 - fres), vec3(0.9), foam);
	EMISSION = (sky * fres * (1.0 - foam) * mix(1.0, 0.6, night) + sun_col * glint * day) * (1.0 - foam * 0.7);
	// (Caustics dance on the real floor too: a faint dapple in the surface.)
	EMISSION += vec3(0.9, 1.0, 0.95) * caus * day * see * exp(-depth * 0.45) * 0.06 * (1.0 - blow);
	ROUGHNESS = mix(0.06, 0.6, foam) + 0.08 * blow;
	SPECULAR = 0.25;
}
