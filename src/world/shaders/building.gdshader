// Facade shader for all procedural buildings. Geometry is plain massing; this
// draws windows, mullions, floor bands, shopfronts and roof gravel from
// world-metre UVs, so detail costs no vertices (mobile-friendly).
//   COLOR.rgb  base tint            COLOR.a  surface kind (see KIND_*)
//   UV         (metres along wall, metres above street)
//   UV2        x: window style 0..7 (+0..1 across a wall face)
//              y: per-building random 0..1 (+ face width in ¼ m steps)
shader_type spatial;
render_mode cull_back, diffuse_burley, specular_schlick_ggx;

// Sky colours (linear) and the sun, set by Atmosphere every frame as the day
// turns; `night` 0..1 lights the windows, `wetness` 0..1 darkens and glosses.
global uniform vec3 sky_top;
global uniform vec3 sky_horizon;
global uniform vec3 sun_dir;
global uniform float night;
global uniform float wetness;
uniform vec3 interior_warm : source_color = vec3(1.0, 0.78, 0.48);
uniform float lit_fraction = 0.025;
uniform float lit_strength = 0.35;
uniform float detail_fade_start = 250.0;
uniform float detail_fade_end = 700.0;
// Street graffiti (tools/graffiti/make_atlas.py): 8 x 4 cells of 256 px,
// GRAFFITI_N pieces in reading order, each centred in its cell.
uniform sampler2D graffiti_atlas : source_color, filter_linear_mipmap, repeat_disable;
uniform bool has_graffiti = false;
const float GRAFFITI_N = 27.0;

const float KIND_WALL = 0.0;
const float KIND_TRIM = 1.0;
const float KIND_ROOF = 2.0;
const float KIND_GLASS = 3.0;
const float KIND_SIGN = 4.0;
const float KIND_STONE = 6.0;  // BuildingMesher.KIND_STONE

varying flat float v_kind;
varying vec3 v_world_normal;
varying float v_dist;
varying vec3 v_wpos;

float hash12(vec2 p) {
	vec3 p3 = fract(vec3(p.xyx) * 0.1031);
	p3 += dot(p3, p3.yzx + 33.33);
	return fract((p3.x + p3.y) * p3.z);
}

// Smooth value noise (weathering patterns; detail range only).
float vnoise_b(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash12(i), hash12(i + vec2(1, 0)), f.x), mix(hash12(i + vec2(0, 1)), hash12(i + vec2(1, 1)), f.x), f.y);
}

// Which quarter a point is in (mirrors CityLayout.district on the island;
// everything west of the strait is Westbank): 0 cbd, 1 midtown,
// 2 waterfront, 3 docks, 4 old town (georgian), 5 Westbank.
float quarter(vec2 p) {
	if (p.x < 30.0) return 5.0;
	if (p.x < 250.0 && p.y > -330.0 && p.y < 260.0) return 2.0;
	if (p.y >= 260.0 && p.x < 560.0) return 3.0;
	if (p.x > 780.0 || p.y < -540.0 || p.y > 520.0) return 4.0;
	if (distance(p, vec2(560.0, -170.0)) < 330.0) return 0.0;
	return 1.0;
}

// How worn a building is, 0 (new, kept up) .. 1 (old, neglected): set by
// its quarter (the financial core is new and maintained, the docks and
// Westbank's older streets the most worn), varied per building, and some
// buildings recently renovated whatever the area.
float building_age(vec2 p, float seed) {
	float q = quarter(p);
	float a = q == 0.0 ? 0.1 : (q == 1.0 ? 0.35 : (q == 2.0 ? 0.3 : (q == 3.0 ? 0.85 : (q == 4.0 ? 0.6 : 0.65))));
	// Softer at the CBD's edge: older stock creeps in towards midtown.
	a = mix(a, 0.35, q == 0.0 ? smoothstep(240.0, 330.0, distance(p, vec2(560.0, -170.0))) : 0.0);
	a = clamp(a + (fract(seed * 17.31 + 0.13) - 0.5) * 0.45, 0.0, 1.0);
	return fract(seed * 3.91 + 0.7) < 0.22 ? a * 0.3 : a;
}

void vertex() {
	v_kind = floor(COLOR.a * 8.0 + 0.5);
	v_world_normal = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
	v_wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	v_dist = length((MODELVIEW_MATRIX * vec4(VERTEX, 1.0)).xyz);
}

// Returns window mask (1 = glass) and cell id, for a style.
// style: 0 stone office, 1 brick flats, 2 glass curtain, 3 warehouse,
//        4 modern grid, 5 sandstone, 6 dark glass, 7 deco bands
void window_layout(float style, float seed, vec2 uv, out float glass, out vec2 cell, out float frame, out vec2 wpos,
		out vec2 whalf, out vec2 csize) {
	vec2 size = vec2(3.0, 3.6);
	vec2 win = vec2(0.55, 0.6);
	if (style == 1.0) { size = vec2(3.2, 3.0); win = vec2(0.42, 0.55); }
	else if (style == 2.0) { size = vec2(1.6, 3.8); win = vec2(0.92, 0.78); }
	else if (style == 3.0) { size = vec2(4.0, 4.4); win = vec2(0.42, 0.5); }
	else if (style == 4.0) { size = vec2(2.6, 3.6); win = vec2(0.7, 0.62); }
	else if (style == 5.0) { size = vec2(3.6, 4.2); win = vec2(0.4, 0.56); }
	else if (style == 6.0) { size = vec2(1.5, 3.7); win = vec2(0.94, 0.9); }
	else if (style == 7.0) { size = vec2(2.2, 3.6); win = vec2(0.5, 0.7); }
	// Each building its own rhythm (constant per building, from its seed):
	// bay width, storey height and window proportions, plus a few distinct
	// patterns, so two towers of one style never share a facade.
	float h1 = fract(seed * 7.13 + 0.17);
	float h2 = fract(seed * 13.71 + 0.43);
	float h3 = fract(seed * 23.37 + 0.61);
	float h4 = fract(seed * 41.93 + 0.29);
	bool curtain = style == 2.0 || style == 6.0;
	if (curtain) {
		size.x *= mix(0.9, 2.1, h1);               // mullion spacing
		size.y *= mix(0.94, 1.1, h2);
		win.y = mix(win.y, 0.62, step(0.55, h3));  // deeper spandrels on some
	} else {
		size.x *= mix(0.82, 1.32, h1);
		size.y *= mix(0.94, 1.1, h2);
		win *= vec2(mix(0.82, 1.16, h3), mix(0.9, 1.12, h2));
		if (style == 4.0 && h4 < 0.4) {
			win = vec2(0.97, mix(0.42, 0.55, h3));  // ribbon windows
		} else if ((style == 0.0 || style == 7.0 || style == 5.0) && h4 < 0.35) {
			win = vec2(mix(0.3, 0.38, h3), 0.78);   // tall narrow windows
		} else if (style == 1.0 && h4 < 0.3) {
			size.x *= 1.45;                          // wide sash pairs
			win.x = 0.6;
		}
	}
	win = min(win, vec2(0.97));
	cell = floor(uv / size);
	vec2 f = fract(uv / size) - 0.5;
	vec2 edge = abs(f) - win * 0.5;
	float aa = fwidth(uv.x / size.x) * 1.5 + 0.001;
	glass = 1.0 - smoothstep(-aa, aa, max(edge.x, edge.y));
	wpos = f * size;
	whalf = win * size * 0.5;
	frame = 1.0 - smoothstep(-aa * 2.0, aa, max(edge.x, edge.y) + 0.04);
	csize = size;
}

// What you see through a window: the room behind it as a box (interior
// mapping). o = point on the glass in the room's frame (x across, y up, from
// the cell centre), d = view ray into the building in the same frame, room =
// (width, height, depth). Back wall with a desk/sofa line and the odd
// picture, side walls, floor and ceiling, darker with depth; lit rooms glow
// from the ceiling.
vec3 room(vec2 o, vec3 d, vec3 rsize, float rnd, float lit, vec3 lamp, float daylight) {
	vec3 lo = vec3(-rsize.x * 0.5, -rsize.y * 0.5, 0.0);
	vec3 hi = vec3(rsize.x * 0.5, rsize.y * 0.5, rsize.z);
	vec3 p0 = vec3(o, 0.0);
	vec3 inv = 1.0 / max(abs(d), vec3(1e-4)) * sign(d + 1e-6);
	vec3 tf = ((step(0.0, d) * hi + (1.0 - step(0.0, d)) * lo) - p0) * inv;
	float t = min(tf.x, min(tf.y, tf.z));
	vec3 h = p0 + d * t;
	vec3 wallc = rnd < 0.3 ? vec3(0.72, 0.7, 0.64) : (rnd < 0.55 ? vec3(0.6, 0.62, 0.63)
		: (rnd < 0.8 ? vec3(0.68, 0.6, 0.5) : vec3(0.56, 0.6, 0.66)));
	vec3 c;
	if (t == tf.z) {
		c = wallc;
		// Furniture line along the back (desks, sofas) and a picture/screen.
		float desk = step(h.y, lo.y + 0.85 + 0.3 * fract(rnd * 7.0));
		c = mix(c, vec3(0.2, 0.18, 0.17) * (0.8 + 0.6 * fract(rnd * 13.0)), desk * 0.85);
		float pic = step(abs(h.x - (fract(rnd * 3.3) - 0.5) * rsize.x * 0.5), 0.45) * step(abs(h.y - 0.25), 0.3);
		c = mix(c, vec3(0.15, 0.2, 0.28) + vec3(fract(rnd * 5.1), fract(rnd * 9.7), 0.3) * 0.3, pic * step(0.5, fract(rnd * 17.0)));
	} else if (t == tf.y) {
		c = d.y > 0.0 ? vec3(0.8, 0.79, 0.76) : (fract(rnd * 2.9) < 0.5 ? vec3(0.3, 0.22, 0.16) : vec3(0.32, 0.33, 0.35));
		if (d.y > 0.0) {
			// Ceiling light panel.
			float panel = step(abs(h.x), 0.5) * step(abs(h.z - rsize.z * 0.5), 0.6);
			c += lamp * panel * lit * 3.0;
		}
	} else {
		c = wallc * 0.78;
	}
	float depth_k = mix(1.0, 0.45, h.z / rsize.z);
	// Daylight falls off into the room; lamps light it evenly.
	vec3 light = vec3(daylight) * depth_k + lamp * lit * 0.55 * mix(1.0, 0.75, h.z / rsize.z);
	return c * light;
}

// What kind of business a painted shopfront bay is (independent of its sign
// colour): 0 café, 1 convenience, 2 boutique, 3 restaurant, 4 estate agent /
// office, 5 salon, 6 empty unit (whitewashed glass).
int shop_kind(float sid) {
	float k = fract(sid * 13.7 + 0.37);
	return k < 0.18 ? 0 : (k < 0.34 ? 1 : (k < 0.48 ? 2 : (k < 0.62 ? 3 : (k < 0.75 ? 4 : (k < 0.86 ? 5 : 6)))));
}

// Interior of a shop seen through its window (interior mapping, like room()):
// a box room plus one furniture plane (tables / desks / counters at their real
// height), dressed by kind so a street of shops reads as different businesses
// rather than rows of shelving. Shops are lit all day; empty units are not.
vec3 shop_room(vec2 o, vec3 d, vec3 rsize, float sid, vec3 lamp, float daylight) {
	vec3 lo = vec3(-rsize.x * 0.5, -rsize.y * 0.5, 0.0);
	vec3 hi = vec3(rsize.x * 0.5, rsize.y * 0.5, rsize.z);
	vec3 p0 = vec3(o, 0.0);
	vec3 inv = 1.0 / max(abs(d), vec3(1e-4)) * sign(d + 1e-6);
	vec3 tf = ((step(0.0, d) * hi + (1.0 - step(0.0, d)) * lo) - p0) * inv;
	float t = min(tf.x, min(tf.y, tf.z));
	vec3 h = p0 + d * t;
	float fy = h.y - lo.y;  // height above the shop floor
	int kind = shop_kind(sid);
	float v = fract(sid * 4.7);
	vec3 wallc = kind == 0 ? vec3(0.55, 0.42, 0.32) : (kind == 3 ? vec3(0.34, 0.2, 0.15) : (kind == 6 ? vec3(0.62, 0.6, 0.56)
		: (v < 0.5 ? vec3(0.86, 0.85, 0.82) : vec3(0.7, 0.74, 0.76))));
	vec3 c;
	if (t == tf.y) {
		if (d.y > 0.0) {
			c = vec3(0.86, 0.85, 0.83);
			if (kind == 3) {
				// Restaurant: dark ceiling, a warm pendant over each table.
				c = vec3(0.2, 0.15, 0.12);
				vec2 g = fract(h.xz / 1.8) - 0.5;
				c += lamp * (1.0 - smoothstep(0.05, 0.14, length(g))) * 5.0;
			} else if (kind != 6) {
				vec2 g = fract(h.xz / vec2(1.6, 1.8)) - 0.5;
				c += lamp * step(abs(g.x), 0.16) * step(abs(g.y), 0.16) * 4.0;
			}
		} else {
			vec2 tl = floor(h.xz / 0.6);
			c = (kind == 0 || kind == 3) ? vec3(0.36, 0.25, 0.17) * (0.9 + 0.1 * mod(floor(h.x / 0.18), 2.0))
				: (kind == 6 ? vec3(0.45, 0.44, 0.42) * (0.85 + 0.2 * hash12(floor(h.xz * 1.3) + sid))
				: mix(vec3(0.62, 0.6, 0.57), vec3(0.74, 0.72, 0.69), mod(tl.x + tl.y, 2.0)));
		}
	} else {
		float along = t == tf.z ? h.x : h.z;
		bool back = t == tf.z;
		c = wallc;
		if (kind == 0) {
			// Café: counter, dark menu board with chalk lines.
			float counter = step(fy, 1.05) * (back ? 1.0 : 0.0);
			c = mix(c, vec3(0.22, 0.14, 0.09), counter);
			float board = step(abs(fy - 2.35), 0.45) * step(abs(along), rsize.x * 0.3) * (back ? 1.0 : 0.0);
			float chalk = step(0.62, hash12(floor(vec2(along / 0.12, fy / 0.11)) + sid * 31.0)) * step(abs(fy - 2.35), 0.36);
			c = mix(c, mix(vec3(0.08, 0.09, 0.08), vec3(0.85), chalk * 0.7), board);
		} else if (kind == 1) {
			// Convenience: one side a wall of lit fridges; elsewhere low
			// shelving bays (1.2 m uprights) of chunky, muted packs, plain
			// wall above with a category band.
			if (!back && h.x > 0.0) {
				float door = abs(fract(along / 0.8) - 0.5);
				float in_f = step(0.15, fy) * step(fy, 2.0);
				vec3 fr = mix(vec3(0.8, 0.88, 0.92), vec3(0.95), step(fract(fy / 0.45), 0.08));
				fr = mix(fr, vec3(0.25), step(0.46, door));
				c = mix(c, fr * 1.3, in_f);
			} else {
				float in_rows = step(0.1, fy) * step(fy, 1.75);
				float row = floor((fy - 0.1) / 0.4);
				float shelf = step(fract((fy - 0.1) / 0.4), 0.08);
				float pk = floor(along / 0.32);
				float hr = hash12(vec2(pk, row) + sid * 57.0);
				vec3 goods = mix(vec3(0.55, 0.5, 0.45), vec3(fract(hr * 7.1), fract(hr * 3.3), fract(hr * 5.9)), 0.45);
				float tall = 0.4 * mix(0.55, 0.85, fract(hr * 11.0));
				float stocked = step(0.08, fract((fy - 0.1) / 0.4)) * step(fract((fy - 0.1) / 0.4) * 0.4, tall) * step(0.06, fract(along / 0.32)) * step(0.12, hr);
				c = mix(c, mix(vec3(0.42, 0.42, 0.44), goods, stocked), in_rows);
				c = mix(c, vec3(0.88), shelf * in_rows);
				c = mix(c, vec3(0.3), step(abs(fract(along / 1.2) - 0.5), 0.015) * in_rows);
				float band = step(abs(fy - 2.25), 0.16);
				c = mix(c, vec3(0.75, 0.2, 0.15) * (0.7 + 0.5 * fract(sid * 19.0)), band);
			}
		} else if (kind == 2) {
			// Boutique: a rail of hanging garments, framed prints above.
			float g = floor(along / 0.16);
			float hg = hash12(vec2(g, 3.0) + sid * 23.0);
			float hang = step(0.9, fy) * step(fy, 1.75 - 0.35 * fract(hg * 7.0)) * step(0.35, hg)
				* step(abs(fract(along / 2.4) - 0.5), 0.33);
			vec3 cloth = mix(vec3(0.15, 0.15, 0.17), vec3(fract(hg * 3.7), fract(hg * 8.3), fract(hg * 5.3)), 0.55 * step(0.5, fract(hg * 13.0)));
			c = mix(c, cloth, hang);
			c = mix(c, vec3(0.3, 0.3, 0.32), step(abs(fy - 1.82), 0.025) * step(abs(fract(along / 2.4) - 0.5), 0.35));
			float print_ = step(abs(fract(along / 2.4) - 0.5), 0.18) * step(abs(fy - 2.6), 0.28);
			c = mix(c, vec3(0.2, 0.25, 0.3) + vec3(fract(sid * 7.7), 0.2, fract(sid * 2.3)) * 0.4, print_);
		} else if (kind == 3) {
			// Restaurant: panelled dado, framed art, a bar along the back.
			c = mix(c, c * 0.6, step(fy, 1.0));
			c = mix(c, vec3(0.75, 0.62, 0.4), step(abs(fy - 1.0), 0.03));
			float art = step(abs(fract(along / 2.0) - 0.5), 0.2) * step(abs(fy - 1.85), 0.35);
			c = mix(c, mix(vec3(0.6, 0.45, 0.25), vec3(0.15, 0.2, 0.25) + 0.3 * fract(sid * vec3(3.1, 5.3, 7.9)), step(abs(fract(along / 2.0) - 0.5), 0.17) * step(abs(fy - 1.85), 0.31)), art);
			if (back) {
				c = mix(c, vec3(0.12, 0.08, 0.06), step(fy, 1.1));
				float bottles = step(1.5, fy) * step(fy, 2.3) * step(fract(along / 0.13), 0.5) * step(fract((fy - 1.5) / 0.4), 0.7);
				c = mix(c, vec3(0.3, 0.45, 0.3) * (0.6 + 0.8 * hash12(vec2(floor(along / 0.13), floor(fy / 0.4)))), bottles);
			}
		} else if (kind == 4) {
			// Estate agent / office: white walls, listing boards on the back
			// wall (card grid: picture over text), a dark skirting.
			if (back) {
				vec2 cg = vec2(fract(along / 0.7), fract((fy - 0.9) / 0.6));
				float card = step(0.9, fy) * step(fy, 2.7) * step(0.1, cg.x) * step(cg.x, 0.9) * step(0.08, cg.y) * step(cg.y, 0.92);
				float pic = step(0.45, cg.y);
				vec3 cc = mix(vec3(0.95), vec3(0.4, 0.55, 0.7) * (0.7 + 0.5 * hash12(floor(vec2(along / 0.7, fy / 0.6)))), pic);
				c = mix(c, cc, card);
			}
			c = mix(c, vec3(0.2), step(fy, 0.1));
		} else if (kind == 5) {
			// Salon: mirrors along the walls over a ledge, black chairs.
			float bay = abs(fract(along / 1.4) - 0.5);
			float mirror = step(bay, 0.32) * step(0.95, fy) * step(fy, 2.0);
			c = mix(c, mix(sky_horizon * 0.55, vec3(0.75, 0.78, 0.8), 0.4) * (0.85 + 0.3 * fract(fy * 0.7)), mirror);
			c = mix(c, vec3(0.15), step(abs(fy - 0.92), 0.04) * step(bay, 0.4));
			c = mix(c, vec3(0.06), step(bay, 0.14) * step(0.2, fy) * step(fy, 0.95));
		} else {
			// Empty unit: patchy plaster, a cable dangling, nothing on show.
			c *= 0.8 + 0.25 * vnoise_b(vec2(along, fy) * 1.3 + sid * 9.0);
		}
		if (!back) c *= 0.85;
	}
	// One furniture plane at table / desk height in front of the walls.
	if (kind == 0 || kind == 3 || kind == 4) {
		float ty = lo.y + (kind == 4 ? 0.74 : 0.76);
		if (d.y < -1e-4) {
			float tp = (ty - p0.y) / d.y;
			if (tp > 0.0 && tp < t) {
				vec3 q = p0 + d * tp;
				if (q.z > 0.9) {
					if (kind == 4) {
						vec2 g = vec2(fract(q.x / 2.4) - 0.5, fract((q.z - 0.9) / 2.2) - 0.5);
						if (abs(g.x) < 0.38 && abs(g.y) < 0.22) {
							c = vec3(0.42, 0.3, 0.2);
							t = tp;
						}
					} else {
						vec2 g = fract(vec2(q.x, q.z - 0.9) / 1.8) - 0.5;
						if (length(g) < (kind == 3 ? 0.42 : 0.3)) {
							c = kind == 3 ? vec3(0.92, 0.9, 0.86) : vec3(0.78, 0.76, 0.72);
							t = tp;
						}
					}
				}
			}
		}
	}
	vec3 hpos = p0 + d * t;
	float depth_k = mix(1.0, 0.7, hpos.z / rsize.z);
	float lit = kind == 6 ? 0.25 : (kind == 3 ? 0.75 : 1.0);
	return c * (vec3(daylight) * depth_k * 0.5 + lamp * 0.5 * lit);
}

// Reflection of the world in glass: sky above, a hazy band of city skyline
// (with window specks, lit at night) round the horizon, the ground below.
vec3 world_reflection(vec3 r) {
	vec3 sky = mix(sky_horizon, sky_top, clamp(r.y * 1.6, 0.0, 1.0));
	float az = atan(r.x, r.z) / 6.2832 + 0.5;
	float col = floor(az * 70.0);
	float hb = hash12(vec2(col, 7.0));
	float hs = 0.02 + 0.22 * hb * hb * (0.5 + 0.5 * hash12(vec2(floor(az * 9.0), 3.0)));
	float in_city = 1.0 - smoothstep(hs - 0.004, hs + 0.004, r.y);
	vec3 bld = mix(vec3(0.2, 0.22, 0.25), sky_horizon * 0.75, 0.45 + 0.35 * clamp(r.y / max(hs, 0.01), 0.0, 1.0));
	bld *= 0.8 + 0.4 * hash12(vec2(col, 2.0));
	// Window rows in the reflected towers: soft bands, not per-pixel specks
	// (those shimmer as the camera moves).
	float rows = smoothstep(0.35, 0.5, abs(fract(r.y * 140.0) - 0.5));
	float lit_w = step(0.7, hash12(vec2(floor(az * 260.0), floor(r.y * 140.0))));
	bld *= 1.0 - 0.18 * rows;
	bld += lit_w * (1.0 - rows) * mix(sky_horizon * 0.08, vec3(1.0, 0.75, 0.45) * 1.1, night);
	vec3 ground = mix(vec3(0.16, 0.17, 0.18), sky_horizon * 0.3, 0.3);
	vec3 c = mix(sky, bld, in_city);
	return r.y < 0.0 ? mix(bld, ground, smoothstep(0.0, -0.15, r.y)) : c;
}

void fragment() {
	vec3 base = COLOR.rgb;
	float style = floor(UV2.x);
	float face_t = fract(UV2.x) / 0.999;
	float face_w = floor(UV2.y) * 0.25;
	// Wall faces pack the seed beside their width (see BuildingMesher
	// _face_span); interpolation adds noise in the low bits, so snap it.
	float seed = face_w > 0.0 ? floor(fract(UV2.y) * 256.0) / 256.0 : UV2.y;
	vec2 uv = UV;
	// (Taken here, in uniform control flow: the graffiti is sampled with
	// explicit gradients from inside per-wall branches.)
	vec2 uv_dx = dFdx(uv);
	vec2 uv_dy = dFdy(uv);
	float rough = 0.85;
	float metal = 0.0;
	vec3 albedo = base;
	vec3 emit = vec3(0.0);
	float detail = 1.0 - smoothstep(detail_fade_start, detail_fade_end, v_dist);
	vec3 bend_n = vec3(0.0);  // world-space relief normal (reveals, sills), when relief > 0
	float relief = 0.0;
	float age = building_age(v_wpos.xz, seed);
	float qd = quarter(v_wpos.xz);

	if (v_kind == KIND_ROOF) {
		// Building roofs pack their half-extents in UV2.x (negative) and
		// measure UV from the roof's centre: `edge` = metres to the parapet.
		float edge = 1e4;
		if (UV2.x < -0.5) {
			float pk = floor(-UV2.x - 1.0 + 0.5);
			vec2 half_ext = vec2(mod(pk, 4096.0), floor(pk / 4096.0)) * 0.25;
			edge = min(half_ext.x - abs(uv.x), half_ext.y - abs(uv.y));
			seed = UV2.y;
		}
		bool metal_roof = seed >= 7.5;
		seed = fract(seed);
		// Roof membrane panels, softly varied (no per-pixel noise: it shimmers).
		float n = hash12(floor(uv / 4.0) + seed * 91.0);
		vec2 pf = abs(fract(uv / 4.0) - 0.5);
		float seam = step(0.47, max(pf.x, pf.y)) * detail;
		// Pale finishes were reading as white slabs in full sun: real roofs
		// sit in the mid greys.
		vec3 rb = base * mix(1.0, 0.72, smoothstep(0.36, 0.56, dot(base, vec3(0.33))));
		albedo = rb * (0.9 + 0.1 * n) * (1.0 - 0.15 * seam);
		// Weathering: broad soft patches (puddle stains, newer membrane) from
		// a smoothed 9 m lattice, and a paver walkway on some roofs.
		vec2 g = uv / 9.0 + seed * 17.0;
		vec2 gi = floor(g);
		vec2 gf = smoothstep(0.0, 1.0, fract(g));
		float blot = mix(mix(hash12(gi), hash12(gi + vec2(1, 0)), gf.x),
			mix(hash12(gi + vec2(0, 1)), hash12(gi + vec2(1, 1)), gf.x), gf.y);
		albedo *= mix(0.8, 1.08, blot);
		// Gravel aggregate, only up close (where a pixel covers a few stones).
		float near_k = 1.0 - smoothstep(0.025, 0.06, length(fwidth(uv)));
		if (near_k > 0.0) {
			float grit = hash12(floor(uv * 9.0) + seed * 7.0);
			albedo *= 1.0 + (grit - 0.5) * 0.16 * near_k;
		}
		if (fract(seed * 13.7) < 0.45) {
			float lane = abs(fract(uv.x / 23.0 + seed) - 0.5) * 23.0;
			vec2 pv = abs(fract(uv / vec2(1.0, 1.0)) - 0.5);
			albedo = mix(albedo, vec3(0.55, 0.53, 0.5) * (1.0 - 0.25 * step(0.44, max(pv.x, pv.y))), step(lane, 0.8) * detail * step(1.5, edge));
		}
		if (edge < 1e3) {
			// Dirt and standing water collect along the parapet; a lighter
			// metal flashing strip runs right at its foot; drains every ~12 m.
			albedo *= mix(0.7, 1.0, smoothstep(0.25, 2.2, edge));
			float flash = step(edge, 0.3) * detail;
			albedo = mix(albedo, vec3(0.5, 0.51, 0.52), flash * 0.7);
			vec2 dpos = abs(fract(uv / 12.0 + 0.5) - 0.5) * 12.0;
			float drain = step(edge, 0.9) * step(0.35, edge) * step(min(dpos.x, dpos.y), 0.28) * detail;
			albedo = mix(albedo, vec3(0.08, 0.08, 0.09), drain * 0.9);
			// Water stain fanning out from each drain.
			albedo *= 1.0 - 0.18 * detail * (1.0 - smoothstep(0.0, 2.2, length(vec2(min(dpos.x, dpos.y), edge - 0.6))));
		}
		rough = 0.95;
		if (metal_roof) {
			// Warehouses: ribbed metal sheeting (a rib every 0.33 m across
			// 1 m sheets, the seams darker), a little sheen, rust and dirt
			// gathering towards the eaves on older sheds, and a row of
			// translucent skylights on a sparse 12 x 18 m grid.
			float rib = abs(fract(uv.x / 0.33) - 0.5);
			float sheet = step(fract(uv.y / 6.0), 0.012) + step(fract(uv.x / 1.0), 0.02);
			vec3 tin = mix(vec3(0.58, 0.6, 0.62), base * 0.9, 0.35) * (0.92 + 0.08 * hash12(floor(uv / vec2(1.0, 6.0)) + seed));
			tin *= 1.0 - 0.18 * smoothstep(0.32, 0.5, rib) * detail;
			tin *= 1.0 - 0.15 * clamp(sheet, 0.0, 1.0) * detail;
			vec3 rust = vec3(0.42, 0.24, 0.13);
			float rusty = age * smoothstep(0.55, 0.85, vnoise_b(uv * 0.35 + seed * 9.0)) * (1.0 - smoothstep(0.0, 6.0, edge));
			tin = mix(tin, rust * (0.8 + 0.3 * vnoise_b(uv * 2.0)), rusty * 0.8);
			float sky = step(abs(fract(uv.y / 18.0) - 0.5) * 18.0, 1.0) * step(abs(fract(uv.x / 12.0) - 0.5) * 12.0, 1.5) * step(4.0, edge);
			tin = mix(tin, vec3(0.6, 0.66, 0.66), sky * 0.6);
			albedo = tin;
			rough = mix(0.42, 0.75, rusty);
			metal = 0.45 * (1.0 - rusty) * (1.0 - sky);
		}
		if (style == 3.0) {
			// Warehouses: profiled metal sheeting – ribs every 0.33 m along
			// the shorter span, 1.1 m sheets with lapped seams, a few
			// translucent roof lights, and (older buildings) rust weeping
			// from the fixings and the edges. Catches the sun a little.
			bool along_x = fract(seed * 9.7) < 0.5;
			float run = along_x ? uv.x : uv.y;
			float cross_ = along_x ? uv.y : uv.x;
			float rib = smoothstep(0.35, 0.5, abs(fract(run / 0.33) - 0.5) * 2.0);
			float sheet = hash12(vec2(floor(run / 1.1), floor(cross_ / 6.0)) + seed * 13.0);
			vec3 metal_c = mix(vec3(0.55, 0.58, 0.6), base * 1.1, 0.35) * (0.9 + 0.12 * sheet);
			albedo = metal_c * (1.0 - 0.18 * rib * detail);
			float roof_light = step(0.86, hash12(vec2(floor(run / 4.4), floor(cross_ / 7.0)) + seed)) * step(0.15, fract(cross_ / 7.0));
			albedo = mix(albedo, vec3(0.72, 0.76, 0.74), roof_light * 0.8);
			float rust = smoothstep(0.55, 0.9, vnoise_b(uv * vec2(0.3, 1.6) + seed * 7.0)) * age;
			rust = max(rust, (1.0 - smoothstep(0.0, 1.5, edge)) * age * 0.8);
			albedo = mix(albedo, vec3(0.42, 0.24, 0.13), rust * 0.6 * detail);
			rough = mix(0.45, 0.8, rust);
			metal = 0.35 * (1.0 - rust);
		}
	} else if (v_kind == KIND_TRIM) {
		albedo = base;
		rough = 0.7;
	} else if (v_kind == KIND_STONE) {
		// Dressed-stone base course: ashlar in 0.45 m courses, joints
		// staggered every other course, a little tone per block, and a
		// splash line of grime where it meets the pavement. (UV: metres.)
		float course = floor(uv.y / 0.45);
		float bx = uv.x / 1.1 + mod(course, 2.0) * 0.5;
		float block = hash12(vec2(floor(bx), course) + seed * 13.0);
		float jy = step(fract(uv.y / 0.45), 0.05);
		float jx = step(fract(bx), 0.025);
		albedo = base * (0.9 + 0.16 * block);
		albedo *= 1.0 - 0.32 * max(jx, jy) * detail;
		albedo *= mix(0.72, 1.0, smoothstep(0.3, 0.75, uv.y));
		rough = 0.9;
	} else if (v_kind == KIND_SIGN) {
		// Billboard: UV.y is metres up the panel. Frame, a bold headline bar
		// broken into "words", a thinner strapline and a contrasting stripe.
		float h = uv.y;
		vec3 ink = dot(base, vec3(0.33)) > 0.6 ? vec3(0.08, 0.1, 0.14) : vec3(0.97, 0.95, 0.9);
		float word = step(0.25, hash12(vec2(floor(uv.x / 1.7), seed * 37.0)));
		float gap = step(0.18, fract(uv.x / 1.7));
		float headline = step(2.6, h) * step(h, 4.1) * word * gap;
		float strap = step(1.3, h) * step(h, 1.8) * step(0.4, hash12(vec2(floor(uv.x / 0.9), seed * 53.0)));
		float stripe = step(0.35, h) * step(h, 0.9);
		albedo = mix(base, ink, max(headline, strap) * detail);
		albedo = mix(albedo, base * 0.35, stripe);
		// Printed vinyl in 1.5 m drops: faint seams and a slight sheen change.
		float drop = abs(fract(uv.x / 1.5) - 0.5);
		albedo *= 1.0 - 0.08 * step(0.48, drop) * detail;
		albedo *= 0.97 + 0.03 * hash12(vec2(floor(uv.x / 1.5), seed * 9.0));
		// Lit by the goosenecks on the bottom rail (one every ~4.5 m): bright
		// pools at the foot of the advert fading up the panel, night only.
		// By day it's just a printed panel in the sun.
		float lamp_u = fract(uv.x / 4.5) - 0.5;
		float pool = exp(-lamp_u * lamp_u * 9.0);
		float wash = 0.28 + 0.75 * exp(-max(h - 0.6, 0.0) / 2.6) * (0.55 + 0.45 * pool);
		emit = base * night * wash * 0.42 + base * 0.02 * (1.0 - night);
		rough = 0.55;
	} else {
		float glass;
		vec2 cell;
		float frame;
		vec2 wpos;
		vec2 whalf;
		vec2 csize;
		window_layout(style, seed, uv, glass, cell, frame, wpos, whalf, csize);
		// Ground floor: tall shopfront glazing + fascia band.
		// (Only some buildings have shops on the ground floor; the rest carry
		// their windows down. BuildingMesher.ground_shops() matches this.)
		bool shop = uv.y < 4.6 && style != 3.0 && fract(seed * 5.37 + 0.21) < 0.5;
		if (shop) {
			float bay = fract(uv.x / 6.0);
			glass = step(0.08, bay) * step(bay, 0.92) * step(0.25, uv.y) * step(uv.y, 3.6);
			cell = vec2(floor(uv.x / 6.0), -1.0);
		}
		if (v_kind == KIND_GLASS || style == 2.0 || style == 6.0) {
			// Curtain wall: mostly glass with spandrel bands and mullions.
			float spandrel = step(fract(uv.y / csize.y), 0.16);
			glass = shop ? glass : (1.0 - spandrel) * glass;
		}
		// Brick courses / stone joints at close range only.
		float tex = 1.0;
		if (style == 1.0 || style == 3.0) {
			vec2 b = uv * vec2(4.2, 13.0);
			b.x += step(1.0, mod(floor(b.y), 2.0)) * 0.5;
			vec2 bf = fract(b);
			float mortar = step(bf.x, 0.06) + step(bf.y, 0.1);
			tex = mix(1.0, 0.82 + 0.18 * hash12(floor(b) + seed), detail) * mix(1.0, 1.0 - 0.18 * clamp(mortar, 0.0, 1.0), detail);
		} else if (style == 5.0 || style == 0.0 || style == 7.0) {
			float course = step(fract(uv.y / 0.6), 0.04) * detail;
			tex = 1.0 - 0.08 * course;
		}
		// Floor bands for deco/stone styles.
		if (style == 7.0 || style == 0.0) {
			float band = step(fract(uv.y / 3.6), 0.09);
			tex *= 1.0 - 0.12 * band;
		}
		// Weathering: faint rain streaks under each window column on masonry.
		if (style != 2.0 && style != 6.0 && v_kind != KIND_GLASS) {
			float col_n = hash12(vec2(floor(uv.x / 1.5), seed * 29.0));
			tex *= 1.0 - 0.07 * col_n * detail * smoothstep(0.0, 1.0, fract(uv.y / 14.4));
		}
		vec3 wall = base * tex;

		// Glass: the world reflected (each pane a hair off true, so
		// reflections break up pane by pane like real glazing) over the room
		// behind it (interior mapping), blended by Fresnel.
		vec3 view_w = normalize((INV_VIEW_MATRIX * vec4(VIEW, 0.0)).xyz);
		vec3 n_w = normalize(v_world_normal);
		vec3 tang = normalize(cross(vec3(0.0, 1.0, 0.0), n_w));
		bool curtain = style == 2.0 || style == 6.0 || v_kind == KIND_GLASS;
		vec2 jt = vec2(hash12(cell * 1.7 + seed * 5.0), hash12(cell * 2.3 + seed * 3.0)) - 0.5;
		vec3 n_g = normalize(n_w + (tang * jt.x + vec3(0.0, 1.0, 0.0) * jt.y) * (curtain ? 0.05 : 0.02) * detail);
		vec3 r = reflect(-view_w, n_g);
		float fres = pow(1.0 - clamp(dot(view_w, n_w), 0.0, 1.0), 3.0);
		vec3 refl = detail > 0.0 ? world_reflection(r) : mix(sky_horizon, sky_top, clamp(r.y * 1.6, 0.0, 1.0));
		float rnd = hash12(cell + seed * 113.0);
		vec3 tint = style == 6.0 ? vec3(0.12, 0.16, 0.2) : (style == 2.0 ? vec3(0.2, 0.32, 0.38) : vec3(0.1, 0.11, 0.12));
		// Curtain-wall towers pick a glass colour per building (teal, bronze,
		// green, blue, champagne, silver) so the skyline isn't one blue mass;
		// reflections are seen through that coating like real glass.
		float pick = fract(seed * 7.31);
		if (style == 2.0) {
			tint = pick < 0.18 ? vec3(0.16, 0.34, 0.36) : (pick < 0.36 ? vec3(0.42, 0.28, 0.15)
				: (pick < 0.5 ? vec3(0.17, 0.33, 0.24) : (pick < 0.64 ? vec3(0.18, 0.27, 0.42)
				: (pick < 0.82 ? vec3(0.46, 0.42, 0.34) : vec3(0.36, 0.38, 0.4)))));
		} else if (style == 6.0) {
			tint = pick < 0.4 ? vec3(0.1, 0.14, 0.2) : (pick < 0.75 ? vec3(0.22, 0.15, 0.09) : vec3(0.13, 0.13, 0.12));
		}
		if (curtain) {
			float lum = dot(refl, vec3(0.3, 0.55, 0.15));
			refl = mix(refl, clamp(tint * 2.4, 0.0, 1.3) * lum * 1.6, 0.6);
		}
		// Blinds half-drawn in some windows (offices and flats, not shops).
		float blind_h = step(0.86, hash12(cell * 2.7 + seed * 17.0)) * (shop ? 0.0 : 1.0);
		float in_blind = blind_h * step(1.0 - hash12(cell + 5.1) * 0.6, fract(uv.y / csize.y) + 0.3);
		// Lit rooms: a few by day; after dusk they come on one by one (each
		// window has its own threshold) up to a per-building share, in warm
		// tungsten, cool office white or the odd blue TV glow.
		// (Offices keep plenty of lights on by day too; homes hardly any.)
		bool office = style == 0.0 || style == 2.0 || style == 4.0 || style == 6.0 || style == 7.0;
		float day_share = office ? 0.25 + 0.2 * fract(seed * 5.3) : lit_fraction;
		// At night buildings differ a lot: some nearly dark, some busy
		// (6-50 % of windows), and offices light whole floors (cleaners,
		// late shifts) – bands of light instead of an even sprinkle.
		float night_share = mix(0.06, 0.5, pow(fract(seed * 3.7), 1.4));
		float lit_share = mix(day_share, night_share, night);
		float lit = step(1.0 - lit_share, hash12(cell * 1.31 + seed * 7.0)) * (shop ? 1.0 : 0.7);
		if (office && !shop) {
			float floors_on = night * (0.04 + 0.22 * fract(seed * 9.1));
			lit = max(lit, step(1.0 - floors_on, hash12(vec2(cell.y * 1.7, seed * 31.0))) * 0.75);
		}
		float lk = hash12(cell * 3.17 + seed * 11.0);
		vec3 lamp_col = lk < 0.55 ? interior_warm : (lk < 0.88 ? vec3(0.86, 0.9, 1.0) : vec3(0.5, 0.66, 1.0));
		lamp_col = mix(office ? vec3(0.95, 0.95, 0.9) : interior_warm, lamp_col, night);
		float lit_k = mix(lit_strength, 1.3, night) * (0.45 + 0.75 * hash12(cell * 0.71 + seed));
		vec3 interior = tint * (0.75 + 0.35 * rnd);
		if (detail > 0.0) {
			vec3 d_in = -view_w;
			vec3 dl = vec3(dot(d_in, tang), d_in.y, dot(d_in, -n_w));
			vec2 o = shop ? vec2(fract(uv.x / 6.0) * 6.0 - 3.0, uv.y - 2.3) : wpos;
			vec3 rs = shop ? vec3(6.0, 4.6, 7.0) : vec3(csize.x * (curtain ? 2.0 : 1.0), csize.y, curtain ? 6.0 : 4.2);
			float daylight = dot(sky_horizon, vec3(0.3, 0.55, 0.15)) * 0.5 * (1.0 - 0.85 * night);
			vec3 rm = room(o, dl, rs, rnd, lit, lamp_col * mix(0.7, lit_k, night), daylight);
			// Seen through the glass's own tint (strongly for coated curtain walls).
			rm *= curtain ? (tint * 2.2 + 0.15) : vec3(0.85, 0.88, 0.9);
			interior = mix(interior, rm, detail);
		}
		vec3 gcol = mix(interior, refl, curtain ? 0.45 + 0.45 * fres : 0.12 + 0.6 * fres);
		// Blinds: a paler band in the glass's own colour, not a beige patch.
		gcol = mix(gcol, mix(gcol, vec3(0.78, 0.76, 0.72), 0.45) * (0.85 + 0.15 * rnd), in_blind * 0.8 * detail);
		gcol += lamp_col * lit * lit_k * 0.12 * (1.0 - detail * 0.7);
		emit = (detail > 0.0 ? interior * 0.9 * lit : lamp_col * lit * lit_k * 0.5) * glass;
		// Night walls never go black: a faint city-glow bounce everywhere and
		// warm light washing up from the street lamps over the lowest floors.
		emit += wall * (1.0 - glass) * night * (0.026 + 0.15 * exp(-uv.y / 12.0)) * vec3(1.0, 0.84, 0.66);
		// Window reveal: slightly darker frame around each opening.
		vec3 framed = mix(wall, wall * 0.72, (1.0 - glass) * frame * detail);
		bool punched = !shop && style != 2.0 && style != 6.0 && v_kind != KIND_GLASS;
		if (punched && detail > 0.0) {
			// Stone sill under each window and (brick) a lintel over it.
			vec3 stone = (style == 1.0 || style == 3.0) ? vec3(0.8, 0.76, 0.68) : base * 1.16;
			float in_x = step(abs(wpos.x), whalf.x + 0.12);
			float sill = in_x * step(-whalf.y - 0.16, wpos.y) * step(wpos.y, -whalf.y);
			float lintel = in_x * step(whalf.y, wpos.y) * step(wpos.y, whalf.y + 0.22)
				* ((style == 1.0 || style == 3.0) ? 1.0 : 0.0);
			framed = mix(framed, stone, max(sill, lintel) * detail);
			framed = mix(framed, stone * 0.55, in_x * step(-whalf.y - 0.22, wpos.y) * step(wpos.y, -whalf.y - 0.16)
				* detail * 0.6);
		}
		// Recessed glazing: the reveal casts a sun shadow across the top and
		// the sun-side edge of the glass (a deep punched window on masonry,
		// a shallow one on curtain walls), and the frame inside darkens.
		float lit_face = dot(n_w, sun_dir);
		float depth = punched ? 0.26 : 0.07;
		float reveal = 0.0;
		if (!shop) {
			if (lit_face > 0.04) {
				float top_sh = clamp(depth * max(sun_dir.y, 0.0) / lit_face, 0.0, whalf.y * 1.2);
				float lt = dot(sun_dir, tang);
				float side_sh = clamp(depth * abs(lt) / lit_face, 0.0, whalf.x * 1.2);
				float side_edge = lt > 0.0 ? wpos.x - (whalf.x - side_sh) : -(whalf.x - side_sh) - wpos.x;
				reveal = max(step(whalf.y - top_sh, wpos.y), step(0.0, side_edge));
			}
			float rim = 1.0 - smoothstep(0.0, 0.07, min(whalf.x - abs(wpos.x), whalf.y - abs(wpos.y)));
			reveal = max(reveal * 0.85, rim * 0.6);
		}
		gcol *= 1.0 - reveal * 0.55 * detail;
		// Shutters beside the windows on some homes in the old town, the
		// waterfront and Westbank (each building its own colour).
		bool residential = style == 1.0 || style == 5.0 || style == 0.0;
		if (punched && residential && (qd == 4.0 || qd == 5.0 || qd == 2.0) && fract(seed * 29.7 + 0.3) < 0.4
				&& whalf.x * 1.65 + 0.06 < csize.x * 0.5 && detail > 0.0) {
			float sx = abs(wpos.x) - whalf.x;
			float sh = step(0.03, sx) * step(sx, 0.03 + whalf.x * 0.6) * step(abs(wpos.y), whalf.y);
			float sp = fract(seed * 61.3);
			vec3 sc = sp < 0.25 ? vec3(0.13, 0.27, 0.2) : (sp < 0.5 ? vec3(0.12, 0.17, 0.3)
				: (sp < 0.7 ? vec3(0.45, 0.13, 0.12) : (sp < 0.85 ? vec3(0.08, 0.08, 0.09) : vec3(0.82, 0.8, 0.72))));
			sc *= 1.0 - 0.3 * step(fract(wpos.y / 0.07), 0.25);          // slats
			sc = mix(sc, sc * 0.7 + vec3(0.08), age * 0.5);                // sun-faded when old
			framed = mix(framed, sc, sh * detail);
		}
		albedo = mix(framed, gcol, glass);
		// Dirty glass on older buildings: a film of grime, heavier at the
		// bottom of each pane.
		float grime = age * (0.3 + 0.7 * vnoise_b(uv * vec2(1.3, 0.8) + seed * 3.0)) * (0.6 + 0.4 * smoothstep(0.0, -whalf.y, wpos.y));
		albedo = mix(albedo, albedo * 0.72 + vec3(0.07, 0.065, 0.055), glass * grime * 0.55 * detail);
		// Balconies on some flats (waterfront, midtown, Westbank): a slab,
		// railings and a handrail in front of the lower part of each window.
		if (!shop && (style == 4.0 || style == 1.0) && (qd == 2.0 || qd == 5.0 || qd == 1.0)
				&& fract(seed * 47.1 + 0.5) < 0.35 && cell.y >= 1.0 && detail > 0.0) {
			float bx = step(abs(wpos.x), whalf.x + 0.3);
			float by = wpos.y + whalf.y;
			float slab = bx * step(-0.2, by) * step(by, -0.08);
			float rail = bx * step(0.88, by) * step(by, 0.95);
			float bars = bx * step(-0.08, by) * step(by, 0.88) * step(fract(wpos.x / 0.13), 0.22);
			vec3 metal_c = fract(seed * 5.9) < 0.5 ? vec3(0.1, 0.1, 0.11) : vec3(0.85, 0.85, 0.83);
			albedo = mix(albedo, vec3(0.62, 0.61, 0.58) * (1.0 - 0.3 * age), slab * detail);
			albedo = mix(albedo, metal_c, max(rail, bars) * detail);
		}
		// A front door on buildings without shops: dark panelled door with a
		// fanlight, a stone surround and a canopy, mid-facade at street level.
		if (!shop && style != 3.0 && face_w > 7.0 && uv.y < 3.05 && detail > 0.0) {
			float dxd = abs((face_t - 0.5) * face_w);
			float surround = step(dxd, 1.05) * step(uv.y, 2.75);
			float dr = step(dxd, 0.75) * step(uv.y, 2.5);
			float fan = step(dxd, 0.7) * step(2.12, uv.y) * step(uv.y, 2.45);
			float canopy = step(dxd, 1.35) * step(2.78, uv.y) * step(uv.y, 3.0);
			float dp = fract(seed * 83.1);
			vec3 door_c = dp < 0.3 ? vec3(0.08, 0.09, 0.1) : (dp < 0.5 ? vec3(0.32, 0.08, 0.08)
				: (dp < 0.7 ? vec3(0.06, 0.16, 0.12) : (dp < 0.85 ? vec3(0.1, 0.12, 0.22) : vec3(0.36, 0.24, 0.14))));
			door_c *= 1.0 - 0.22 * step(abs(fract(dxd / 0.38) - 0.5), 0.06);   // panels
			albedo = mix(albedo, (style == 1.0 ? vec3(0.8, 0.76, 0.68) : base * 1.15) * (1.0 - 0.2 * age), surround * detail);
			albedo = mix(albedo, door_c, dr * detail);
			albedo = mix(albedo, gcol * 0.8, fan * detail);
			albedo = mix(albedo, vec3(0.1, 0.1, 0.11), canopy * detail);
			emit *= 1.0 - max(dr, surround);
		}
		// Loading bays on warehouses: roller shutters every 9 m with hazard-
		// striped guard posts.
		if (style == 3.0 && uv.y < 4.3 && detail > 0.0) {
			float bay = fract(uv.x / 9.0) * 9.0;
			float rd = step(abs(bay - 4.5), 1.8) * step(uv.y, 3.8);
			float ribs = step(fract(uv.y / 0.09), 0.3);
			float rp = fract(seed * 19.7);
			vec3 rc = rp < 0.4 ? vec3(0.55, 0.56, 0.57) : (rp < 0.7 ? vec3(0.2, 0.32, 0.5) : vec3(0.25, 0.4, 0.3));
			rc *= (1.0 - 0.18 * ribs) * (1.0 - 0.25 * age * (1.0 - smoothstep(0.0, 1.5, uv.y)));
			float post = step(abs(abs(bay - 4.5) - 2.0), 0.12) * step(uv.y, 1.1);
			vec3 haz = step(0.5, fract((uv.y + bay) / 0.3)) > 0.5 ? vec3(0.9, 0.72, 0.1) : vec3(0.06);
			albedo = mix(albedo, rc, rd);
			albedo = mix(albedo, haz, post);
			emit *= 1.0 - max(rd, post);
			rough = mix(rough, 0.6, rd);
		}
		rough = mix(0.88, 0.08, glass);
		metal = mix(0.0, 0.2, glass);
		// Real relief for the light: the inner 15 cm round a punched window is
		// its reveal (wall facing into the opening), the sill below tilts up
		// to catch the sun, the lintel tilts down – so as the sun moves round
		// (and the moon at night) each side lights or falls into shade.
		if (punched && detail > 0.0) {
			float dx = whalf.x - abs(wpos.x);
			float dy = whalf.y - abs(wpos.y);
			float band = 0.15;
			vec3 up = vec3(0.0, 1.0, 0.0);
			if (glass > 0.5 && min(dx, dy) < band) {
				vec3 into = dx < dy ? -sign(wpos.x) * tang : -sign(wpos.y) * up;
				bend_n = normalize(into * 0.92 + n_w * 0.4);
				albedo = mix(albedo, wall * 0.9, 0.85 * detail);
				rough = 0.85;
				metal = 0.0;
				relief = detail;
			} else if (abs(wpos.x) < whalf.x + 0.12 && wpos.y < -whalf.y && wpos.y > -whalf.y - 0.16) {
				bend_n = normalize(n_w * 0.55 + up * 0.85);
				relief = detail;
			} else if (abs(wpos.x) < whalf.x + 0.12 && wpos.y > whalf.y && wpos.y < whalf.y + 0.12) {
				bend_n = normalize(n_w * 0.8 - up * 0.6);
				relief = detail;
			}
		}
		if (shop) {
			// Shopfront: stall riser, central door, mullions, lit interior and
			// a signage fascia coloured per shop.
			float bay_x = fract(uv.x / 6.0) * 6.0;
			float sid = hash12(vec2(floor(uv.x / 6.0), seed * 41.0));
			vec3 sign_col = sid < 0.2 ? vec3(0.62, 0.14, 0.12) : (sid < 0.4 ? vec3(0.12, 0.3, 0.26)
				: (sid < 0.6 ? vec3(0.13, 0.18, 0.34) : (sid < 0.75 ? vec3(0.8, 0.6, 0.2) : base * 0.42)));
			float riser = step(uv.y, 0.6) * glass;
			float door = step(abs(bay_x - 3.0), 0.55) * step(uv.y, 2.5) * step(0.25, uv.y);
			float mull = step(abs(abs(bay_x - 3.0) - 1.75), 0.05) * step(uv.y, 3.6);
			float transom = step(abs(uv.y - 2.65), 0.05);
			vec3 shop_in = mix(vec3(0.05, 0.05, 0.06), interior_warm * 0.5, 0.2 + 0.35 * sid);
			if (detail > 0.0) {
				vec3 d_in = -view_w;
				vec3 dl = vec3(dot(d_in, tang), d_in.y, dot(d_in, -n_w));
				float daylight = dot(sky_horizon, vec3(0.3, 0.55, 0.15)) * 0.5 * (1.0 - 0.85 * night);
				vec3 shop_lamp = mix(vec3(1.0, 0.93, 0.8), interior_warm, 0.35 + 0.4 * fract(sid * 3.1));
				vec3 sr = shop_room(vec2(bay_x - 3.0, uv.y - 1.93), dl, vec3(5.0, 3.36, 6.0), sid, shop_lamp, daylight);
				shop_in = mix(shop_in, sr, detail);
			}
			// Dark plate glass: the shop shows through, the street reflects.
			vec3 shop_glass = mix(shop_in, refl * 0.85, 0.1 + 0.55 * fres);
			if (shop_kind(sid) == 6) {
				// Empty unit: whitewashed glass in swirls, a little see-through.
				float ww = smoothstep(0.3, 0.7, vnoise_b(vec2(uv.x * 1.6, uv.y * 2.2) + sid * 13.0));
				shop_glass = mix(shop_glass, vec3(0.86, 0.85, 0.8), (0.55 + 0.35 * ww) * detail);
			}
			albedo = mix(albedo, shop_glass, glass * (1.0 - riser));
			albedo = mix(albedo, base * 0.5, max(riser, max(mull, transom) * glass) * detail);
			// Glazed door with a dark frame and push bar.
			float door_frame = door * (1.0 - step(abs(bay_x - 3.0), 0.47) * step(uv.y, 2.42));
			albedo = mix(albedo, vec3(0.07, 0.07, 0.07), door_frame * detail);
			albedo = mix(albedo, albedo * 0.7, door * (1.0 - door_frame) * detail);
			emit += shop_in * glass * (1.0 - riser) * mix(0.18, 0.8, night) * mix(detail, 1.0, night);
			emit += interior_warm * glass * (1.0 - riser) * 0.25 * night * (1.0 - detail);
			float fascia = step(3.7, uv.y) * step(uv.y, 4.5);
			albedo = mix(albedo, sign_col, fascia);
			// Old painted fascias fade and chalk in the sun.
			albedo = mix(albedo, albedo * 0.7 + vec3(0.17, 0.16, 0.15), fascia * smoothstep(0.4, 1.0, age) * 0.7);
			// Lettering blocks on the fascia.
			float letters = step(0.35, hash12(vec2(floor(uv.x / 0.45), sid * 77.0))) * step(abs(bay_x - 3.0), 1.9)
				* step(abs(uv.y - 4.1), 0.16);
			albedo = mix(albedo, vec3(0.95, 0.92, 0.84), letters * fascia * detail * step(0.25, sid));
			// Each little shop its own front: a striped awning on some, roller
			// shutters pulled down on a few (closed for good, or not open yet –
			// more of them in the older quarters), a projecting sign on others.
			float sk = fract(sid * 13.7);
			if (sk < 0.38) {
				float aw = step(3.05, uv.y) * step(uv.y, 3.6) * step(abs(bay_x - 3.0), 2.9);
				float st = step(0.5, fract(uv.x / 0.55));
				vec3 ac = mix(sign_col * 1.2, vec3(0.92, 0.9, 0.84), st);
				ac *= 1.0 - 0.25 * smoothstep(3.6, 3.05, uv.y);   // shade under the roll
				albedo = mix(albedo, mix(ac, ac * 0.75 + vec3(0.1), age * 0.6), aw * detail);
				emit *= 1.0 - aw;
			} else if (sk < 0.38 + 0.1 + 0.15 * age) {
				float sh = step(0.25, uv.y) * step(uv.y, 3.6) * step(abs(bay_x - 3.0), 2.75);
				vec3 shc = vec3(0.5, 0.51, 0.52) * (1.0 - 0.2 * step(fract(uv.y / 0.08), 0.3)) * (1.0 - 0.2 * age);
				albedo = mix(albedo, shc, sh * detail);
				emit *= 1.0 - sh;
				rough = mix(rough, 0.6, sh);
			}
		}
		// Corners: dressed stone quoins on masonry (alternating long/short
		// blocks), and on every face a fine shaded arris so box edges read
		// crisply up close instead of melting into the next face.
		if (face_w > 0.0) {
			float dc = min(face_t, 1.0 - face_t) * face_w;
			bool masonry = style == 0.0 || style == 1.0 || style == 3.0 || style == 5.0 || style == 7.0;
			if (masonry && v_kind == KIND_WALL && !shop) {
				float course = floor(uv.y / 0.62);
				float qw = mod(course, 2.0) < 0.5 ? 0.95 : 0.55;
				float joint = step(fract(uv.y / 0.62), 0.07);
				vec3 qcol = (style == 1.0 || style == 3.0) ? vec3(0.84, 0.8, 0.72) : base * 1.18;
				float q = step(dc, qw) * detail;
				albedo = mix(albedo, qcol * (1.0 - 0.25 * joint), q);
			}
			float arris = 1.0 - smoothstep(0.0, fwidth(dc) * 1.5 + 0.02, dc);
			albedo *= 1.0 - 0.32 * arris * detail;
		}
		// Contact shading: walls darken toward the street (light blocked by
		// the canyon), so buildings sit on the ground instead of floating;
		// and a long gradient up the facade (tops catch more sky).
		albedo *= mix(vec3(0.56, 0.57, 0.6), vec3(1.0), smoothstep(0.0, 12.0, uv.y));
		albedo *= mix(0.86, 1.04, smoothstep(6.0, 80.0, uv.y));
	}
	// Weathering on solid walls (not glass, not signs): vertical rain
	// streaks washed down the facade, broad soot/damp patches, and a
	// darker band where splash-back hits the lowest metre. Value noise in
	// metres, only within the detail range (no far shimmer).
	if ((v_kind == KIND_WALL || v_kind == KIND_STONE || v_kind == KIND_TRIM) && rough > 0.5 && detail > 0.0) {
		vec2 sq = vec2(uv.x * 1.3, uv.y * 0.05) + seed * 37.0;
		float streak = vnoise_b(sq) * vnoise_b(sq * vec2(2.7, 1.4) + 9.1);
		float patches = smoothstep(0.45, 0.9, vnoise_b(uv * 0.06 + seed * 11.0));
		float splash = 1.0 - smoothstep(0.0, 1.1, uv.y);
		// (How much by the building's age: kept-up towers stay clean.)
		albedo *= 1.0 - detail * ((0.05 + 0.17 * age) * streak + (0.03 + 0.12 * age) * patches
			+ (0.05 + 0.1 * age) * splash * float(v_kind != KIND_TRIM));
		// (Base courses always: their shops are above them.)
		bool street_wall = v_kind == KIND_STONE || (v_kind == KIND_WALL && !(uv.y < 4.6 && style != 3.0 && fract(seed * 5.37 + 0.21) < 0.5));
		// Peeling render on old painted walls: patches showing the darker
		// substrate, a pale lip at the edge.
		if (street_wall && (style == 0.0 || style == 5.0 || style == 7.0 || style == 4.0) && age > 0.5) {
			float pn = vnoise_b(uv * 0.55 + seed * 3.0) + 0.3 * vnoise_b(uv * 2.2);
			float peel = smoothstep(0.98, 1.02, pn) * (age - 0.5) * 2.0;
			float lip = smoothstep(0.94, 0.98, pn) * (1.0 - smoothstep(0.98, 1.02, pn)) * (age - 0.5) * 2.0;
			albedo = mix(albedo, base * vec3(0.62, 0.55, 0.5), peel * 0.85 * detail);
			albedo = mix(albedo, albedo * 1.18, lip * detail);
		}
		// Street level on older walls: fly-posters (some torn, all faded) and
		// the odd graffiti tag. Never on the shopfronts.
		if (street_wall && uv.y < 2.6 && age > 0.35) {
			float pc = floor(uv.x / 3.4);
			float ph = hash12(vec2(pc, seed * 51.0));
			if (ph < (age - 0.35) * 1.1) {
				float lx = fract(uv.x / 3.4) * 3.4;
				float k = floor((lx - 0.6) / 0.46);
				float in_p = step(0.6, lx) * step(lx, 0.6 + 0.46 * 3.0) * step(abs(fract((lx - 0.6) / 0.46) - 0.5), 0.46)
					* step(1.05, uv.y) * step(uv.y, 1.72);
				// Mostly whole; the rest torn along a ragged diagonal (the
				// lower part ripped away, the top still pasted up).
				vec2 pq = vec2(fract((lx - 0.6) / 0.46), (uv.y - 1.05) / 0.67);
				float tear_k = hash12(vec2(k, pc));
				float line = 0.25 + 0.5 * (tear_k < 0.8 ? pq.x : 1.0 - pq.x) + 0.12 * vnoise_b(pq * 7.0 + k);
				float torn = tear_k < 0.6 ? 1.0 : step(line, pq.y);
				float pk = hash12(vec2(k, pc + seed));
				vec3 pcol = pk < 0.25 ? vec3(0.9, 0.85, 0.3) : (pk < 0.5 ? vec3(0.85, 0.35, 0.3)
					: (pk < 0.75 ? vec3(0.35, 0.55, 0.8) : vec3(0.92, 0.9, 0.85)));
				pcol *= 1.0 - 0.35 * step(abs(fract(uv.y / 0.12) - 0.5), 0.12) * step(uv.y, 1.5);   // print lines
				pcol = mix(pcol, vec3(0.75, 0.73, 0.68), age * 0.5);                                // faded
				albedo = mix(albedo, pcol, in_p * torn * detail);
			}
		}
		// Graffiti: one piece per 3.6 m slot of older street walls, of all
		// sizes – stickers and tags (0.45–0.9 m), pieces (1.1–1.8 m) and the
		// odd big wall piece (2.2–3.0 m) – sprayed onto the wall: faded by
		// sun and age, worn off in patches, the wall's grime showing through.
		// Never across a window.
		if (street_wall && has_graffiti && age > 0.3 && uv.y < 3.4) {
			float gc = floor(uv.x / 3.6) + 13.0;
			float gh = hash12(vec2(gc, seed * 23.0));
			// (The stone base course under the windows takes the most: no
			// windows to avoid, but kept below its top.)
			bool plinth = v_kind == KIND_STONE;
			if (gh < (age - 0.3) * (plinth ? 1.5 : 1.0)) {
				float lx = fract(uv.x / 3.6) * 3.6;
				float sk = fract(gh * 19.31);
				// (Base course: style = 10 + its height in quarter metres; its
				// foot is buried, its top is a kerb over the lot.)
				float ptop = (style - 10.0) * 0.25;
				// The piece as sized; failing that (it would cross a window), a
				// small tag under the ground-floor sills.
				float sz = 0.0;
				float x0 = 0.0;
				float y0 = 0.0;
				float clear = 0.0;
				for (int cand = 0; cand < 2 && clear < 0.5; cand++) {
					if (cand == 0) {
						sz = sk < 0.38 ? mix(0.45, 0.9, fract(gh * 7.7))
							: (sk < 0.84 ? mix(1.1, 1.8, fract(gh * 7.7)) : mix(2.2, 3.0, fract(gh * 7.7)));
						// Small ones at eye/hand height; big ones from near the pavement.
						y0 = sz < 1.0 ? mix(0.9, 1.6, fract(gh * 3.3)) : mix(0.3, 0.5, fract(gh * 3.3));
						if (plinth) {
							sz = min(mix(0.5, 1.3, fract(gh * 7.7)), ptop - 0.85);
							y0 = ptop - 0.2 - sz;
						}
					} else {
						sz = mix(0.5, 0.8, fract(gh * 7.7));
						y0 = 0.3;
					}
					x0 = 0.2 + (3.2 - sz) * fract(gh * 53.1);
					clear = 1.0;
					for (int k = 0; k < (plinth ? 0 : 5); k++) {
						vec2 o = k == 4 ? vec2(0.5) : vec2(float(k & 1), float(k >> 1));
						vec2 wp = vec2((gc - 13.0) * 3.6 + x0 + o.x * sz, y0 + o.y * sz);
						float gl; vec2 c1; float fr; vec2 c2; vec2 c3; vec2 c4;
						window_layout(style, seed, wp, gl, c1, fr, c2, c3, c4);
						clear *= 1.0 - step(0.5, max(gl, fr));
					}
					if (plinth) break;
				}
				vec2 q = vec2((lx - x0) / sz, 1.0 - (uv.y - y0) / sz);
				if (q.x > 0.0 && q.x < 1.0 && q.y > 0.0 && q.y < 1.0 && sz > 0.4) {
					if (clear > 0.5) {
						float id = floor(fract(gh * 97.13) * GRAFFITI_N);
						vec2 cell = vec2(mod(id, 8.0), floor(id / 8.0));
						// (A slight lean, mirrored now and then: the same piece
						// twice doesn't read as a stamp.)
						float flip = step(0.8, fract(gh * 41.7));
						vec2 qq = vec2(mix(q.x, 1.0 - q.x, flip), q.y);
						vec2 auv = (cell + qq) / vec2(8.0, 4.0);
						vec2 sc = vec2((flip > 0.5 ? -1.0 : 1.0) / (sz * 8.0), -1.0 / (sz * 4.0));
						vec4 g = textureGrad(graffiti_atlas, auv, uv_dx * sc, uv_dy * sc);
						// Worn: paint lost in patches and speckles where the
						// wall is rough, more the older the building.
						float wear = vnoise_b(uv * 3.1 + gh * 31.0) * 0.65 + vnoise_b(uv * 17.0 + gh * 5.0) * 0.35;
						float keep = smoothstep(0.08 + 0.2 * age, 0.3 + 0.2 * age, wear);
						float strength = mix(0.97, 0.8, age) * (0.85 + 0.15 * fract(gh * 13.7));
						// Faded: sun-bleached towards grey, a little of the
						// wall's colour through the thin coats.
						vec3 paint = mix(g.rgb, vec3(dot(g.rgb, vec3(0.3, 0.59, 0.11))), 0.08 + 0.17 * age);
						paint = mix(paint, base, 0.05 + 0.08 * age);
						// The wall's own shading (grime, streaks, mortar) carries on under it.
						float shade = clamp(dot(albedo, vec3(0.33)) / max(dot(base, vec3(0.33)), 0.04), 0.7, 1.1);
						albedo = mix(albedo, paint * shade, g.a * (0.5 + 0.5 * keep) * strength * detail);
					}
				}
			}
		}
		// Lit faces get a faint warm/cool drift by block of facade (repaints,
		// different batches of brick) so long walls aren't one flat colour.
		albedo *= 1.0 + (vnoise_b(uv * vec2(0.08, 0.03) + seed * 5.0) - 0.5) * 0.1 * detail;
	}
	// Rain: surfaces darken and gloss (glass is already glossy).
	if (relief > 0.0) {
		vec3 nv = normalize((VIEW_MATRIX * vec4(bend_n, 0.0)).xyz);
		NORMAL = normalize(mix(NORMAL, nv, relief));
	}
	ALBEDO = albedo * (1.0 - 0.16 * wetness);
	ROUGHNESS = mix(rough, min(rough, 0.32), wetness * 0.75);
	METALLIC = metal;
	SPECULAR = 0.5;
	EMISSION = emit;
}
