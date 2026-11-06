class_name CityRoads
extends RefCounted
## The island's road network: not a grid.
##
##   * The island outline is organic (noisy rounded coast; the west side is the
##     straight quay along the strait, where the bridge lands, with a wide
##     promenade for the waterfront viaduct and the bridge anchorage).
##   * A coastal ring road runs inside the esplanade.
##   * Boulevards: hand-placed control points smoothed into curves – the Grand
##     Diagonal from the bridge up to the cathedral, the Central Spine, Valley
##     Road along the railway, Heights Road, the Old Town Crescent and the
##     Inner Ring round the business district. Roundabouts where they cross.
##   * Every region between them is carved into blocks by recursive street
##     cuts, each district with its own character: a slightly skewed grid in
##     the CBD, a differently angled one in midtown, long quay-aligned blocks
##     in the docks, winding lanes and small irregular blocks in the Old Town.
##     Cuts end at the streets they meet (T-junctions) and never cross a
##     reserved footprint (landmarks, set pieces).
##
## Output (all 2-D, x/z metres):
##   coast       PackedVector2Array  island outline (sea wall), counter-clockwise
##   roads       Array of {pts, w, kind: "ring"|"major"|"minor", name, id}
##   roundabouts Array of {c: Vector2, r: float (centre-line radius), w: float}
##   blocks      Array of {poly, district, kind: "block"|"plaza"|"green"}
##   field       baked road field (see bake_field)

const ESPLANADE := 18.0
const WEST_PROMENADE := 40.0   # the strait quay: viaduct, bridge anchorage, jetty
const RING_W := 22.0
const MAJOR_W := 26.0
const ROUNDABOUT_R := 24.0
const SAMPLE := 6.0           # m between smoothed curve points
const MIN_LOT := 22.0

## Per-district street character: base angle (deg), angle jitter (deg),
## target block area (m²), street width, bend (0 = straight cuts).
const STYLE := {
	"cbd": {"angle": 8.0, "jitter": 2.0, "area": 7000.0, "w": 16.0, "bend": 0.0},
	"midtown": {"angle": -14.0, "jitter": 5.0, "area": 7600.0, "w": 16.0, "bend": 0.03},
	"waterfront": {"angle": 0.0, "jitter": 4.0, "area": 6400.0, "w": 16.0, "bend": 0.02},
	"docks": {"angle": 0.0, "jitter": 0.0, "area": 9500.0, "w": 18.0, "bend": 0.0},
	"georgian": {"angle": 28.0, "jitter": 18.0, "area": 4600.0, "w": 13.0, "bend": 0.07},
	"suburb": {"angle": 12.0, "jitter": 14.0, "area": 5200.0, "w": 13.0, "bend": 0.06},
}

var seed := 1207
var district_of: Callable    # (x, z) -> String
var bounds := Rect2(30.0, -656.0, 1000.0, 1271.0)
var reserved: Array = []     # PackedVector2Array footprints cuts must not cross
var coast := PackedVector2Array()
var roads: Array = []
var roundabouts: Array = []
var blocks: Array = []
var by_name := {}            # name -> road dict
## Another land (the mainland): its own boulevards (name -> control points)
## instead of the island's, and no inner ring when inner_radius is 0.
var custom_majors := {}
var inner_radius := 245.0
## Set by mirror_x(): the straight quay is then the east edge.
var mirrored := false
## Coast landforms: "island" (the city) or "westbank" (the mainland: rounder,
## deeper bays and capes, so it doesn't read as a rectangle).
var landform := "island"


func generate(p_seed: int, p_district: Callable, p_bounds: Rect2, p_reserved: Array = []) -> CityRoads:
	seed = p_seed
	district_of = p_district
	bounds = p_bounds
	reserved = p_reserved
	_coast()
	var inner := _ring()
	var majors := _majors()
	_roundabouts(majors)
	# Regions: the land inside the ring road minus every boulevard and roundabout.
	var regions: Array = [inner]
	for m in majors:
		if m.get("loop", false):
			# A closed boulevard: keep what's inside it as well as outside.
			var lp: PackedVector2Array = m["pts"].slice(0, m["pts"].size() - 1)
			var outer: PackedVector2Array = Geometry2D.offset_polygon(lp, m["w"] * 0.5)[0]
			var hole: PackedVector2Array = Geometry2D.offset_polygon(lp, -m["w"] * 0.5)[0]
			var next: Array = _clip_all(regions, outer)
			for r in regions:
				for q in Geometry2D.intersect_polygons(r, hole):
					if not Geometry2D.is_polygon_clockwise(q):
						next.append(q)
			regions = next
		else:
			regions = _clip_all(regions, _buffer(m["pts"], m["w"] * 0.5))
	for rb in roundabouts:
		regions = _clip_all(regions, _circle(rb["c"], float(rb["r"]) + float(rb["w"]) * 0.5, 28))
	for rb in roundabouts:
		blocks.append({"poly": _circle(rb["c"], float(rb["r"]) - float(rb["w"]) * 0.5, 20), "district": _dist(rb["c"]),
			"kind": "green"})
	for r in regions:
		_split(r, 0)
	for i in roads.size():
		roads[i]["id"] = i
		if roads[i].has("name"):
			by_name[roads[i]["name"]] = roads[i]
	return self


# ------------------------------------------------------------------ coast
func _coast() -> void:
	# A rounded, noisy outline inside `bounds`; the west edge stays straight
	# (the strait quay). The path runs north edge west→east, round the NE
	# corner, down the east edge, round the SE corner, south edge east→west.
	var b := bounds
	var wb := landform == "westbank"
	var R := 150.0 if not wb else minf(b.size.x, b.size.y) * 0.44
	var amp := 8.0 if not wb else 16.0
	var noise := func(s: float) -> float:
		return (_vn(s / 160.0 + 3.0) - 0.5) * 2.0 * 0.7 + (_vn(s / 55.0 + 11.0) - 0.5) * 2.0 * 0.3
	var path: Array = [Vector2(b.position.x, b.position.y)]
	_arc(path, Vector2(b.end.x - R, b.position.y + R), R, -PI * 0.5, 0.0)
	_arc(path, Vector2(b.end.x - R, b.end.y - R), R, 0.0, PI * 0.5)
	path.append(Vector2(b.position.x, b.end.y))
	var s := 0.0
	var pts := PackedVector2Array()
	for i in path.size() - 1:
		var a: Vector2 = path[i]
		var c: Vector2 = path[i + 1]
		var L := a.distance_to(c)
		var k := maxi(1, ceili(L / 12.0))
		var t := (c - a).normalized()
		var out := Vector2(t.y, -t.x)
		for j in k:
			var p := a.lerp(c, float(j) / k)
			var taper := smoothstep(b.position.x, b.position.x + 160.0, p.x)
			# Broad landforms, with small erosion detail instead of a noisy rectangle.
			# Normalised coordinates also fit the smaller mirrored Westbank.
			var u := (p.x - b.position.x) / b.size.x
			var v := (p.y - b.position.y) / b.size.y
			var north_bay := -64.0 * exp(-pow((u - 0.48) / 0.19, 2.0)) * pow(1.0 - v, 6.0)
			var east_bay := -72.0 * exp(-pow((v - 0.66) / 0.16, 2.0)) * pow(u, 8.0)
			var headland := 38.0 * exp(-pow((v - 0.26) / 0.19, 2.0)) * pow(u, 8.0)
			var shore := north_bay + east_bay + headland
			if wb:
				# Westbank: a deep bay on the far coast, a cove and a cape on
				# the north, a long inlet in the south and a southern point.
				shore = -175.0 * exp(-pow((v - 0.36) / 0.12, 2.0)) * pow(u, 5.0) \
					+ 70.0 * exp(-pow((v - 0.72) / 0.1, 2.0)) * pow(u, 5.0) \
					- 95.0 * exp(-pow((u - 0.34) / 0.1, 2.0)) * pow(1.0 - v, 7.0) \
					+ 45.0 * exp(-pow((u - 0.72) / 0.08, 2.0)) * pow(1.0 - v, 7.0) \
					- 120.0 * exp(-pow((u - 0.58) / 0.07, 2.0)) * pow(v, 7.0) \
					+ 40.0 * exp(-pow((u - 0.25) / 0.08, 2.0)) * pow(v, 7.0)
			pts.append(p + out * (shore + float(noise.call(s + L * j / k)) * amp) * taper)
		s += L
	pts.append(path[-1])
	coast = pts
	if Geometry2D.is_polygon_clockwise(coast):
		coast.reverse()


func _arc(path: Array, c: Vector2, r: float, a0: float, a1: float) -> void:
	for i in 9:
		var a := lerpf(a0, a1, i / 8.0)
		path.append(c + Vector2(cos(a), sin(a)) * r)


## The coast with the west quay moved in by the extra promenade width (what
## the ring road follows).
func _ring_coast() -> PackedVector2Array:
	var out := PackedVector2Array()
	for p in coast:
		if mirrored:
			out.append(Vector2(p.x - (WEST_PROMENADE - ESPLANADE), p.y) if p.x > bounds.end.x - 0.5 else p)
		else:
			out.append(Vector2(p.x + WEST_PROMENADE - ESPLANADE, p.y) if p.x < bounds.position.x + 0.5 else p)
	return out


## The ring road round the coast; returns the land inside it.
func _ring() -> PackedVector2Array:
	var rc := _ring_coast()
	var line: PackedVector2Array = Geometry2D.offset_polygon(rc, -(ESPLANADE + RING_W * 0.5))[0]
	line = _ccw(line)
	line.append(line[0])
	roads.append({"pts": line, "w": RING_W, "kind": "ring", "name": "ring", "loop": true})
	return Geometry2D.offset_polygon(rc, -(ESPLANADE + RING_W))[0]


# ------------------------------------------------------------ boulevards
func _majors() -> Array:
	var b := bounds
	var E := b.end.x + 60.0
	var N := b.position.y - 60.0
	var S := b.end.y + 60.0
	var W := b.position.x - 40.0
	var defs := {
		# Grand Diagonal: bridge landing → CBD → past the cathedral to the Heights.
		"diagonal": [Vector2(W, -17), Vector2(200, -22), Vector2(390, -100), Vector2(560, -215), Vector2(710, -300),
			Vector2(850, -300), Vector2(E, -330)],
		# Central Spine, north coast to south coast, a long S.
		"spine": [Vector2(470, N), Vector2(500, -440), Vector2(540, -230), Vector2(595, 10), Vector2(650, 230),
			Vector2(625, 440), Vector2(590, S)],
		# Valley Road along the railway valley, docks to the east coast.
		"valley": [Vector2(W, 372), Vector2(250, 366), Vector2(470, 385), Vector2(700, 360), Vector2(880, 330),
			Vector2(E, 300)],
		# Heights Road: from the spine up and round to the east coast.
		"heights": [Vector2(595, 10), Vector2(720, -40), Vector2(860, -60), Vector2(E, -20)],
		# Old Town Crescent: a long curve through the north.
		"crescent": [Vector2(W, -470), Vector2(200, -500), Vector2(330, -560), Vector2(470, N)],
	}
	if not custom_majors.is_empty():
		defs = custom_majors
	var out: Array = []
	for name in defs:
		var pts := _smooth(PackedVector2Array(defs[name]))
		roads.append({"pts": pts, "w": MAJOR_W, "kind": "major", "name": name})
		out.append({"pts": pts, "w": MAJOR_W})
	if inner_radius <= 0.0:
		return out
	# Inner Ring round the business district: a closed, slightly irregular loop.
	var c := Vector2(560.0, -160.0)
	var cp := PackedVector2Array()
	for i in 10:
		var a := TAU * i / 10.0
		var r := 245.0 + (_vn(i * 0.9 + 4.0) - 0.5) * 50.0
		cp.append(c + Vector2(cos(a) * r * 1.05, sin(a) * r * 0.92))
	var loop := _smooth_closed(cp)
	roads.append({"pts": loop, "w": MAJOR_W - 4.0, "kind": "major", "name": "inner", "loop": true})
	out.append({"pts": loop, "w": MAJOR_W - 4.0, "loop": true})
	return out


## Reflects the whole plan in the vertical line x = axis_sum / 2 (so the
## straight quay, generated in the west, faces east), keeping polygons
## counter-clockwise. Call before bake_field().
func mirror_x(axis_sum: float) -> void:
	mirrored = true
	coast = _mirror_poly(coast, axis_sum)
	for r in roads:
		var pts := PackedVector2Array()
		for q in r["pts"]:
			pts.append(Vector2(axis_sum - q.x, q.y))
		r["pts"] = pts
	for rb in roundabouts:
		rb["c"] = Vector2(axis_sum - rb["c"].x, rb["c"].y)
	for b in blocks:
		b["poly"] = _mirror_poly(b["poly"], axis_sum)
	bounds = Rect2(axis_sum - bounds.end.x, bounds.position.y, bounds.size.x, bounds.size.y)


static func _mirror_poly(p: PackedVector2Array, axis_sum: float) -> PackedVector2Array:
	var out := PackedVector2Array()
	for q in p:
		out.append(Vector2(axis_sum - q.x, q.y))
	out.reverse()
	return out


func _roundabouts(majors: Array) -> void:
	var land := Geometry2D.offset_polygon(coast, -110.0)[0]
	for i in majors.size():
		for j in range(i + 1, majors.size()):
			for p in _crossings(majors[i]["pts"], majors[j]["pts"]):
				var near := false
				for rb in roundabouts:
					if (rb["c"] as Vector2).distance_to(p) < 130.0:
						near = true
				if not near and Geometry2D.is_point_in_polygon(p, land):
					roundabouts.append({"c": p, "r": ROUNDABOUT_R, "w": MAJOR_W - 6.0})
	for rb in roundabouts:
		var ring := _circle(rb["c"], rb["r"], 28)
		ring.append(ring[0])
		roads.append({"pts": ring, "w": rb["w"], "kind": "major", "loop": true})


# ---------------------------------------------------------------- blocks
func _split(poly: PackedVector2Array, depth: int) -> void:
	var area := _area(poly)
	if area < 40.0:
		return
	var c := _centroid(poly)
	var dist := _dist(c)
	var st: Dictionary = STYLE.get(dist, STYLE["midtown"])
	var brng := RandomNumberGenerator.new()
	brng.seed = hash(Vector3i(int(c.x * 4.0), int(c.y * 4.0), depth)) ^ seed
	var target: float = st["area"] * brng.randf_range(0.75, 1.3)
	var w: float = st["w"]
	var theta := deg_to_rad(float(st["angle"]) + brng.randf_range(-1.0, 1.0) * float(st["jitter"]))
	var d := Vector2(cos(theta), sin(theta))
	var n := Vector2(-d.y, d.x)
	var ext_d := _extent(poly, d)
	var ext_n := _extent(poly, n)
	var Ld := ext_d.y - ext_d.x
	var Ln := ext_n.y - ext_n.x
	if area < target or depth > 9 or minf(Ld, Ln) < 2.0 * MIN_LOT + w and maxf(Ld, Ln) < 2.6 * MIN_LOT + w:
		_emit(poly, dist, area)
		return
	# Cut across the longer axis (a street parallel to the shorter one); try a
	# few positions (and then the other axis) to keep clear of reserved spots.
	var tries: Array = []
	for f in [brng.randf_range(0.38, 0.62), 0.3, 0.7, 0.45, 0.55]:
		tries.append([Ld >= Ln, f])
	for f in [0.5, 0.35, 0.65]:
		tries.append([Ld < Ln, f])
	for tr in tries:
		var along := d if tr[0] else n
		var across := n if tr[0] else d
		var ext_a := ext_d if tr[0] else ext_n
		var ext_c := ext_n if tr[0] else ext_d
		var pos := lerpf(ext_a.x, ext_a.y, tr[1])
		var line := PackedVector2Array()
		var span := ext_c.y - ext_c.x
		var k := 6 if float(st["bend"]) > 0.0 else 1
		for i in k + 1:
			var t := lerpf(ext_c.x - 30.0, ext_c.y + 30.0, float(i) / k)
			var bend := 0.0
			if k > 1:
				bend = (_vn(t / 60.0 + c.x * 0.01 + depth * 7.0) - 0.5) * 2.0 * float(st["bend"]) * span
			line.append(along * (pos + bend) + across * t)
		if k > 1:
			line = _smooth(line)
		var cut := _buffer(line, w * 0.5)
		if _hits_reserved(cut):
			continue
		var pieces := _clip_all([poly], cut)
		if pieces.size() < 2:
			continue
		var small := false
		for p in pieces:
			if _area(p) < 500.0:
				small = true
		if small and tr != tries[0]:
			continue
		for seg in Geometry2D.intersect_polyline_with_polygon(line, poly):
			roads.append({"pts": seg, "w": w, "kind": "minor"})
		for p in pieces:
			_split(p, depth + 1)
		return
	_emit(poly, dist, area)


func _hits_reserved(poly: PackedVector2Array) -> bool:
	for r in reserved:
		if not Geometry2D.intersect_polygons(poly, r).is_empty():
			return true
	return false


func _emit(poly: PackedVector2Array, dist: String, area: float) -> void:
	# Slivers and scraps become small plazas (paved), not building plots.
	var thin := area / maxf(_perimeter(poly), 1.0)
	var kind := "block"
	if area < 900.0 or thin < 6.0:
		kind = "plaza"
	blocks.append({"poly": _ccw(poly), "district": dist, "kind": kind})


# ----------------------------------------------------------- road field
## The road field: per texel of a `cell`-metre grid over the island, the
## nearest road's signed offset from its centre line (+ = right of travel;
## stored unsigned once well off the road, so ridges between roads never
## read as asphalt), its half width (negative for boulevards/ring), the
## distance along it (mod 64 m) and the distance to the kerb of the nearest
## *other* road (< 0 inside a junction). Off the network: (100, 0, 0, 100).
## Computed in horizontal stripes on the worker pool.
var field := PackedFloat32Array()
var field_rect := Rect2()
var field_cell := 1.5
var field_w := 0
var field_h := 0
var _segs: Array = []   # [a, b, half, road id, along at a, avenue]
var _seg_grid := {}     # Vector2i (32 m cells) -> segment indices
const SEG_CELL := 32.0
const BAND := 9.0       # m past the kerb the field reaches


func bake_field(cell := 1.5) -> void:
	field_cell = cell
	field_rect = Rect2(bounds.position - Vector2(10, 10), bounds.size + Vector2(20, 20))
	field_w = ceili(field_rect.size.x / cell)
	field_h = ceili(field_rect.size.y / cell)
	_segs.clear()
	_seg_grid.clear()
	for r in roads:
		var pts := _simplify(r["pts"], 0.25)
		var hw: float = float(r["w"]) * 0.5
		var along := 0.0
		for i in pts.size() - 1:
			var a := pts[i]
			var b := pts[i + 1]
			_add_seg([a, b, hw, int(r["id"]), along, r["kind"] != "minor"])
			along += a.distance_to(b)
	_extend_ends()
	var stripes := ceili(field_h / 16.0)
	_stripe_out.clear()
	_stripe_out.resize(stripes)
	var task := WorkerThreadPool.add_group_task(_bake_stripe, stripes, -1, true)
	WorkerThreadPool.wait_for_group_task_completion(task)
	field = PackedFloat32Array()
	for st in _stripe_out:
		field.append_array(st)
	_stripe_out.clear()


func _add_seg(s: Array) -> void:
	var idx := _segs.size()
	_segs.append(s)
	var a: Vector2 = s[0]
	var b: Vector2 = s[1]
	var reach := float(s[2]) + BAND
	var lo := a.min(b) - Vector2(reach, reach)
	var hi := a.max(b) + Vector2(reach, reach)
	for gx in range(floori(lo.x / SEG_CELL), floori(hi.x / SEG_CELL) + 1):
		for gz in range(floori(lo.y / SEG_CELL), floori(hi.y / SEG_CELL) + 1):
			var k := Vector2i(gx, gz)
			if not _seg_grid.has(k):
				_seg_grid[k] = PackedInt32Array()
			_seg_grid[k].append(idx)


## Street ends stop at the kerb of the road they meet; carried on square
## across that road's carriageway, the junction box is a rectangle (not a
## round cap, which bent the crossings into half-circles). Returns
## [end point, direction, length] per open road end, for traffic too.
var road_ends: Array = []   # [road index, end (0 start / 1 end), point, outward dir, extension m]


func _extend_ends() -> void:
	road_ends.clear()
	var base := _segs.size()
	for ri in roads.size():
		var r: Dictionary = roads[ri]
		if r.get("loop", false):
			continue
		var pts: PackedVector2Array = r["pts"]
		if pts.size() < 2:
			continue
		var hw: float = float(r["w"]) * 0.5
		for e in 2:
			var p := pts[0] if e == 0 else pts[-1]
			var q := pts[1] if e == 0 else pts[-2]
			var d := (p - q).normalized()
			# Walk out until off every other road's carriageway (max 40 m).
			var ext := 0.0
			var x := 0.5
			while x <= 40.0:
				if not _on_other(p + d * x, int(r["id"]), base):
					break
				ext = x
				x += 0.5
			# Pulled back until both far corners are on the road too (meeting
			# a curve or at an angle, a corner would poke onto the plot beyond).
			var sd := Vector2(-d.y, d.x) * hw
			while ext > 0.5 and not (_on_other(p + d * ext + sd, int(r["id"]), base)
					and _on_other(p + d * ext - sd, int(r["id"]), base)):
				ext -= 0.5
			road_ends.append([ri, e, p, d, ext])
			if ext > 0.5:
				var along := -ext if e == 0 else length_of(pts)
				var a := p + d * ext if e == 0 else p
				var b := p if e == 0 else p + d * ext
				# (Square at its far end too: open past the far kerb.)
				_add_seg([a, b, hw, int(r["id"]), along, r["kind"] != "minor", -1 if e == 0 else 1])


func _on_other(p: Vector2, rid: int, n: int) -> bool:
	for idx in _seg_grid.get(Vector2i(floori(p.x / SEG_CELL), floori(p.y / SEG_CELL)), PackedInt32Array()):
		if idx >= n:
			continue
		var s: Array = _segs[idx]
		if int(s[3]) == rid:
			continue
		var a: Vector2 = s[0]
		var b: Vector2 = s[1]
		if Geometry2D.get_closest_point_to_segment(p, a, b).distance_to(p) < float(s[2]):
			return true
	return false


var _stripe_out: Array = []
var _stripe_lock := Mutex.new()


func _bake_stripe(si: int) -> void:
	var out := PackedFloat32Array()
	var j1 := mini(field_h, si * 16 + 16)
	out.resize((j1 - si * 16) * field_w * 4)
	var k := 0
	for j in range(si * 16, j1):
		var z := field_rect.position.y + (j + 0.5) * field_cell
		for i in field_w:
			var v := _sample(Vector2(field_rect.position.x + (i + 0.5) * field_cell, z))
			out[k] = v.x
			out[k + 1] = v.y
			out[k + 2] = v.z
			out[k + 3] = v.w
			k += 4
	_stripe_lock.lock()
	_stripe_out[si] = out
	_stripe_lock.unlock()


## (offset, ±half width, along mod 64, other road's kerb distance) at p.
func _sample(p: Vector2) -> Vector4:
	var best := INF
	var best_s: Array = []
	var best_off := 0.0
	var best_t := 0.0
	var kerbs := {}   # road id -> nearest |off| - hw
	var cell: PackedInt32Array = _seg_grid.get(Vector2i(floori(p.x / SEG_CELL), floori(p.y / SEG_CELL)), PackedInt32Array())
	for idx in cell:
		var s: Array = _segs[idx]
		var a: Vector2 = s[0]
		var b: Vector2 = s[1]
		var ab := b - a
		var L2 := ab.length_squared()
		var t_raw := (p - a).dot(ab) / L2 if L2 > 1e-6 else 0.0
		if s.size() > 6 and (int(s[6]) == 1 and t_raw > 1.0 or int(s[6]) == -1 and t_raw < 0.0):
			continue  # past a junction extension's square end
		var t := clampf(t_raw, 0.0, 1.0)
		var q := a + ab * t
		var dist := p.distance_to(q)
		var kd := dist - float(s[2])
		var rid: int = s[3]
		if kd < float(kerbs.get(rid, INF)):
			kerbs[rid] = kd
		if kd < best:
			best = kd
			best_s = s
			var side := ab.x * (p.y - a.y) - ab.y * (p.x - a.x)
			best_off = dist * (1.0 if side >= 0.0 else -1.0)
			best_t = float(s[4]) + sqrt(L2) * t
	if best_s.is_empty():
		return Vector4(100.0, 0.0, 0.0, 100.0)
	var other := 100.0
	for rid in kerbs:
		if rid != int(best_s[3]):
			other = minf(other, kerbs[rid])
	var hw: float = best_s[2]
	var off := best_off if absf(best_off) < hw + 3.0 else absf(best_off)
	return Vector4(off, -hw if best_s[5] else hw, fmod(best_t, 64.0), other)


## CPU lookup (nearest texel): Vector4 as stored.
func field_at(p: Vector2) -> Vector4:
	var i := clampi(int((p.x - field_rect.position.x) / field_cell), 0, field_w - 1)
	var j := clampi(int((p.y - field_rect.position.y) / field_cell), 0, field_h - 1)
	var k := (j * field_w + i) * 4
	return Vector4(field[k], field[k + 1], field[k + 2], field[k + 3])


## True on a carriageway (between the kerbs of some road).
func on_road(p: Vector2) -> bool:
	if field.is_empty():
		return false
	var f := field_at(p)
	return absf(f.x) < absf(f.y)


func field_texture() -> ImageTexture:
	var img := Image.create_from_data(field_w, field_h, false, Image.FORMAT_RGBAF, field.to_byte_array())
	img.convert(Image.FORMAT_RGBAH)
	return ImageTexture.create_from_image(img)


# ------------------------------------------------------------ queries
## Points every `step` m along a named road (from `from_t` to `to_t` metres).
func along(name: String, step: float, from_t := 0.0, to_t := INF) -> Array:
	var r: Dictionary = by_name.get(name, {})
	if r.is_empty():
		return []
	var pts: PackedVector2Array = r["pts"]
	var out: Array = []
	var acc := 0.0
	var next := from_t
	for i in pts.size() - 1:
		var L := pts[i].distance_to(pts[i + 1])
		while next <= acc + L and next <= to_t:
			out.append(pts[i].lerp(pts[i + 1], (next - acc) / maxf(L, 0.001)))
			next += step
		acc += L
	return out


static func length_of(pts: PackedVector2Array) -> float:
	var s := 0.0
	for i in pts.size() - 1:
		s += pts[i].distance_to(pts[i + 1])
	return s


# --------------------------------------------------------------- helpers
func _dist(p: Vector2) -> String:
	return district_of.call(p.x, p.y) if district_of.is_valid() else "midtown"


static func _vn(x: float) -> float:
	var i := floorf(x)
	var f := x - i
	f = f * f * (3.0 - 2.0 * f)
	return lerpf(absf(fmod(sin(i * 127.1) * 43758.5453, 1.0)), absf(fmod(sin((i + 1.0) * 127.1) * 43758.5453, 1.0)), f)


static func _ccw(p: PackedVector2Array) -> PackedVector2Array:
	if Geometry2D.is_polygon_clockwise(p):
		var q := p.duplicate()
		q.reverse()
		return q
	return p


## Catmull-Rom through the control points, resampled every SAMPLE metres.
static func _smooth(cp: PackedVector2Array) -> PackedVector2Array:
	var out := PackedVector2Array()
	if cp.size() < 3:
		return cp
	for i in cp.size() - 1:
		_cr(out, cp[maxi(i - 1, 0)], cp[i], cp[i + 1], cp[mini(i + 2, cp.size() - 1)])
	out.append(cp[-1])
	return out


static func _smooth_closed(cp: PackedVector2Array) -> PackedVector2Array:
	var out := PackedVector2Array()
	var n := cp.size()
	for i in n:
		_cr(out, cp[(i - 1 + n) % n], cp[i], cp[(i + 1) % n], cp[(i + 2) % n])
	out.append(out[0])
	return out


static func _cr(out: PackedVector2Array, p0: Vector2, p1: Vector2, p2: Vector2, p3: Vector2) -> void:
	var k := maxi(1, ceili(p1.distance_to(p2) / SAMPLE))
	for j in k:
		var t := float(j) / k
		var t2 := t * t
		var t3 := t2 * t
		out.append(0.5 * ((2.0 * p1) + (-p0 + p2) * t + (2.0 * p0 - 5.0 * p1 + 4.0 * p2 - p3) * t2
			+ (-p0 + 3.0 * p1 - 3.0 * p2 + p3) * t3))


## Ramer–Douglas–Peucker.
static func _simplify(pts: PackedVector2Array, tol: float) -> PackedVector2Array:
	if pts.size() < 3:
		return pts
	var keep := PackedByteArray()
	keep.resize(pts.size())
	keep.fill(0)
	keep[0] = 1
	keep[pts.size() - 1] = 1
	var stack: Array = [[0, pts.size() - 1]]
	while not stack.is_empty():
		var se: Array = stack.pop_back()
		var a: int = se[0]
		var b: int = se[1]
		var dmax := 0.0
		var im := -1
		for i in range(a + 1, b):
			var q := Geometry2D.get_closest_point_to_segment(pts[i], pts[a], pts[b])
			var dd := q.distance_to(pts[i])
			if dd > dmax:
				dmax = dd
				im = i
		if dmax > tol and im > 0:
			keep[im] = 1
			stack.append([a, im])
			stack.append([im, b])
	var out := PackedVector2Array()
	for i in pts.size():
		if keep[i] == 1:
			out.append(pts[i])
	return out


static func _buffer(line: PackedVector2Array, half: float) -> PackedVector2Array:
	var r := Geometry2D.offset_polyline(line, half, Geometry2D.JOIN_ROUND, Geometry2D.END_SQUARE)
	return r[0] if r.size() > 0 else PackedVector2Array()


## Every polygon in `polys` minus `hole`, dropping hole outlines.
static func _clip_all(polys: Array, hole: PackedVector2Array) -> Array:
	var out: Array = []
	for p in polys:
		for q in Geometry2D.clip_polygons(p, hole):
			if not Geometry2D.is_polygon_clockwise(q):
				out.append(q)
	return out


static func _circle(c: Vector2, r: float, n: int) -> PackedVector2Array:
	var out := PackedVector2Array()
	for i in n:
		var a := TAU * i / n
		out.append(c + Vector2(cos(a), sin(a)) * r)
	return out


static func _crossings(a: PackedVector2Array, b: PackedVector2Array) -> Array:
	var out: Array = []
	for i in a.size() - 1:
		for j in b.size() - 1:
			var p: Variant = Geometry2D.segment_intersects_segment(a[i], a[i + 1], b[j], b[j + 1])
			if p != null:
				out.append(p)
	return out


static func _area(p: PackedVector2Array) -> float:
	var s := 0.0
	for i in p.size():
		var a := p[i]
		var b := p[(i + 1) % p.size()]
		s += a.x * b.y - b.x * a.y
	return absf(s) * 0.5


static func _perimeter(p: PackedVector2Array) -> float:
	var s := 0.0
	for i in p.size():
		s += p[i].distance_to(p[(i + 1) % p.size()])
	return s


static func _centroid(p: PackedVector2Array) -> Vector2:
	var c := Vector2.ZERO
	for v in p:
		c += v
	return c / maxf(p.size(), 1)


static func _extent(p: PackedVector2Array, axis: Vector2) -> Vector2:
	var lo := INF
	var hi := -INF
	for v in p:
		var t := v.dot(axis)
		lo = minf(lo, t)
		hi = maxf(hi, t)
	return Vector2(lo, hi)
