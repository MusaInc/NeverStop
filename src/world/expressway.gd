class_name Expressway
extends RefCounted
## The Diagonal Expressway: an elevated dual carriageway (one fast lane each
## way, a central barrier) on median pillars over the Grand Diagonal.
##
##   * West end: a ramp up out of the first roundabout after the bridge
##     landing (the on/off ramps of a roundabout interchange).
##   * It flies over every roundabout after that (the Spine / City Loop
##     roundabout and the cathedral one: grade-separated junctions, pillars
##     on the roundabout islands), passing under the City Loop's viaduct.
##   * East end: down a ramp after the last roundabout, then on at street
##     level to the coastal ring road.
##
## Underneath, the Diagonal keeps one local lane each way at street level
## (Traffic drops its inner lanes in the corridor; the express lanes are the
## inner lanes, lifted), so every side street and roundabout still connects.
##
## Data: `line` (the centreline, every STEP m), `h` the deck top. Geometry is
## a set-piece kit (BuildingMesher draws it like the bridge approach); the
## driving surface collides on the street layer (`L.street_obbs`) so the AI's
## wall whiskers don't see a climbing ramp as a wall; barriers and pillars
## collide as walls.

const STEP := 3.0
const LIFT := 7.4          # deck top above the street
const RAMP := 96.0         # ramp length (m)
const HALF := 5.6          # deck half width
const LANE := 3.2          # lane centre offset (the Diagonal's inner lanes)
const WALL_BELOW := 4.6    # under this lift the ramp is a solid embankment (walls both sides)
const SPEED := 16.0        # m/s free flow for traffic

const CONCRETE := Color(0.6, 0.59, 0.56)
const CONCRETE_DK := Color(0.42, 0.42, 0.41)
const ASPHALT := Color(0.17, 0.17, 0.18)
const PAINT := Color(0.86, 0.86, 0.8)
const AMBER := Color(0.85, 0.66, 0.22)

var L: CityLayout
var line := PackedVector2Array()
var g := PackedFloat32Array()      # street height under each sample
var h := PackedFloat32Array()      # deck top
var roundabouts: Array = []        # the ones it flies over / starts at (centres)
var _grid := {}                    # Vector2i(16 m cell) -> PackedInt32Array sample indices
const CELL := 16.0


func _init(layout: CityLayout) -> void:
	L = layout


## Lays out the centreline and height profile. False if the city has no
## Diagonal (the mainland) or it doesn't have the roundabouts expected.
func plan() -> bool:
	var R := L.roads
	if not R.by_name.has("diagonal"):
		return false
	var d: PackedVector2Array = R.by_name["diagonal"]["pts"]
	var flat := RailNetwork._resample_open(d, STEP)
	var n := flat.size()
	# Roundabouts on the Diagonal, in order along it (east of the bridge landing).
	var on_road: Array = []   # [index, rb]
	for rb in R.roundabouts:
		var c: Vector2 = rb["c"]
		if c.x < 150.0:
			continue
		var bi := -1
		var bd := 6.0
		for i in n:
			var dd := flat[i].distance_to(c)
			if dd < bd:
				bd = dd
				bi = i
		if bi >= 0:
			on_road.append([bi, rb])
	if on_road.size() < 2:
		return false
	on_road.sort_custom(func(a, b): return a[0] < b[0])
	var first: Dictionary = on_road[0][1]
	var last: Dictionary = on_road[-1][1]
	var disc := func(rb: Dictionary) -> float: return float(rb["r"]) + float(rb["w"]) * 0.5 + 0.5
	var i_a := int(on_road[0][0]) + int(ceil(float(disc.call(first)) / STEP))
	# East end: where the Diagonal reaches the coastal ring's kerb.
	var ring_kerb := PackedVector2Array()
	if R.by_name.has("ring"):
		var rp: PackedVector2Array = R.by_name["ring"]["pts"]
		var inner := Geometry2D.offset_polygon(rp.slice(0, rp.size() - 1), -float(R.by_name["ring"]["w"]) * 0.5)
		if not inner.is_empty():
			ring_kerb = inner[0]
	var i_b := n - 1
	for i in range(int(on_road[-1][0]), n):
		if not ring_kerb.is_empty() and not Geometry2D.is_point_in_polygon(flat[i], ring_kerb):
			i_b = i - 1
			break
	if i_b - i_a < int((RAMP * 2.0 + 120.0) / STEP):
		return false
	line = flat.slice(i_a, i_b + 1)
	for o in on_road:
		roundabouts.append((o[1] as Dictionary)["c"])
	var m := line.size()
	g.resize(m)
	h.resize(m)
	for i in m:
		g[i] = L.terrain.road_y(line[i].x, line[i].y)
	# Deck: the street smoothed over ~±45 m, lifted, never closer than
	# LIFT - 0.4 to the street right under it.
	var base := g.duplicate()
	for pass_i in 3:
		base = _ease(base, 15)
	var top := PackedFloat32Array()
	top.resize(m)
	for i in m:
		top[i] = maxf(base[i] + LIFT, g[i] + LIFT - 0.4)
	top = _ease(top, 6)
	# Up out of the first roundabout; down after the last, then level.
	var s_down := (int(on_road[-1][0]) - i_a) * STEP + float(disc.call(last)) + 18.0
	for i in m:
		var s := i * STEP
		var up := smoothstep(0.0, RAMP, s)
		var down := 1.0 - smoothstep(s_down, s_down + RAMP, s)
		var u := up * down
		h[i] = lerpf(g[i], maxf(top[i], g[i]), u) if u > 0.0 else g[i]
	for i in m:
		var k := Vector2i(floori(line[i].x / CELL), floori(line[i].y / CELL))
		if not _grid.has(k):
			_grid[k] = PackedInt32Array()
		_grid[k].append(i)
	return true


static func _ease(v: PackedFloat32Array, r: int) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	out.resize(v.size())
	for i in v.size():
		var acc := 0.0
		var wsum := 0.0
		for j in range(maxi(0, i - r), mini(v.size(), i + r + 1)):
			acc += v[j]
			wsum += 1.0
		out[i] = acc / wsum
	return out


## Nearest point on the centreline: [s (m), distance, height there] or [] if
## nowhere near (beyond `reach` m).
func project(x: float, z: float, reach := 14.0) -> Array:
	if line.is_empty():
		return []
	var p := Vector2(x, z)
	var k0 := Vector2i(floori(x / CELL), floori(z / CELL))
	var best := []
	var bd := reach
	for dx in range(-1, 2):
		for dz in range(-1, 2):
			for i: int in _grid.get(k0 + Vector2i(dx, dz), PackedInt32Array()):
				for j in [i - 1, i]:
					if j < 0 or j + 1 >= line.size():
						continue
					var a := line[j]
					var b := line[j + 1]
					var q := Geometry2D.get_closest_point_to_segment(p, a, b)
					var dd := q.distance_to(p)
					if dd < bd:
						bd = dd
						var t := q.distance_to(a) / maxf(a.distance_to(b), 1e-4)
						best = [(j + t) * STEP, dd, lerpf(h[j], h[j + 1], t)]
	return best


## Deck top at (x, z) (for the express lanes' heights).
func height_at(x: float, z: float) -> float:
	var pr := project(x, z, 30.0)
	return float(pr[2]) if not pr.is_empty() else L.terrain.road_y(x, z)


## Lift of the deck above the street at (x, z), 0 off the deck.
func lift_at(x: float, z: float, margin := 0.0) -> float:
	var pr := project(x, z, HALF + margin)
	if pr.is_empty():
		return 0.0
	return float(pr[2]) - L.terrain.road_y(x, z)


## True over the deck's footprint (plus margin).
func covers(x: float, z: float, margin := 0.0) -> bool:
	return not project(x, z, HALF + margin).is_empty()


## The kit (drawn by the mesher), wall collision (kit_obbs) and the deck's
## street-layer collision (L.street_obbs). Lamps go in as props.
func build() -> void:
	if line.size() < 2:
		return
	var k := L._kit("expressway")
	var m := line.size()
	var stride := 2   # 6 m segments
	var since_pillar := 99.0
	var seg := 0
	var i := 0
	while i < m - 1:
		var j := mini(i + stride, m - 1)
		var a3 := Vector3(line[i].x, h[i], line[i].y)
		var b3 := Vector3(line[j].x, h[j], line[j].y)
		var lift := maxf(h[i] - g[i], h[j] - g[j])
		var lift_lo := minf(h[i] - g[i], h[j] - g[j])
		var d := b3 - a3
		var dir := Vector3(d.x, 0.0, d.z).normalized()
		var side := Vector3(-dir.z, 0.0, dir.x)
		var ext := d.normalized() * 0.05
		if lift > 0.12:
			# Slab: drawn, and collides as street.
			var sa := a3 - ext + Vector3.DOWN * 0.6
			var sb := b3 + ext + Vector3.DOWN * 0.6
			L._kbeam(k, sa, sb, HALF * 2.0, 1.2, ASPHALT, false)
			L.street_obbs.append([Transform3D(BuildingMesher.beam_basis(sa, sb), (sa + sb) * 0.5),
				Vector3(HALF * 2.0, 1.2, sa.distance_to(sb))])
			# Fascia under the edges (concrete), visual only.
			for sg: float in [-1.0, 1.0]:
				var fo := side * sg * (HALF - 0.15)
				L._kbeam(k, a3 + fo + Vector3.DOWN * 0.75, b3 + fo + Vector3.DOWN * 0.75, 0.3, 1.5, CONCRETE, false)
			if lift > 0.35:
				# Edge barriers and the central barrier (walls).
				for sg: float in [-1.0, 1.0]:
					var bo := side * sg * (HALF - 0.2)
					L._kbeam(k, a3 + bo + Vector3.UP * 0.5, b3 + bo + Vector3.UP * 0.5, 0.4, 1.0, CONCRETE)
				L._kbeam(k, a3 + Vector3.UP * 0.42, b3 + Vector3.UP * 0.42, 0.55, 0.84, CONCRETE)
			# Paint: edge lines, and a yellow line along the central barrier.
			for sg: float in [-1.0, 1.0]:
				var e := side * sg * (HALF - 0.75) + Vector3.UP * 0.015
				L._kbeam(k, a3 + e, b3 + e, 0.15, 0.03, PAINT, false)
				var c := side * sg * 0.62 + Vector3.UP * 0.015
				L._kbeam(k, a3 + c, b3 + c, 0.12, 0.03, AMBER, false)
			# The ramp's low end: solid walls down to the street (no driving
			# under it, no falling in from the side).
			if lift_lo < WALL_BELOW:
				for sg: float in [-1.0, 1.0]:
					var wo := side * sg * (HALF - 0.25)
					var ga := g[i] - 0.3
					var gb := g[j] - 0.3
					var ta := h[i] - 1.2
					var tb := h[j] - 1.2
					if maxf(ta - ga, tb - gb) > 0.2:
						var hh := maxf((ta - ga + tb - gb) * 0.5, 0.2)
						var ya := (ga + ta) * 0.5
						var yb := (gb + tb) * 0.5
						L._kbeam(k, Vector3(a3.x, ya, a3.z) + wo, Vector3(b3.x, yb, b3.z) + wo, 0.5, hh, CONCRETE_DK)
			# Pillars every ~24 m once it's up, never in a junction (except on
			# a roundabout's island).
			since_pillar += a3.distance_to(b3)
			if lift_lo > WALL_BELOW - 0.5 and since_pillar >= 24.0:
				var p := a3
				var ok := L.roads.field_at(Vector2(p.x, p.z)).w > 2.0
				for c2: Vector2 in roundabouts:
					var dc := c2.distance_to(Vector2(p.x, p.z))
					if dc < 12.0:
						ok = true
					elif dc < 38.0:
						ok = false
				if ok:
					since_pillar = 0.0
					var gy := g[i]
					var topy := h[i] - 1.2
					L._kbeam(k, Vector3(p.x, gy - 0.3, p.z), Vector3(p.x, topy - 0.6, p.z), 1.8, 1.4, CONCRETE_DK)
					L._kbeam(k, Vector3(p.x, topy - 0.4, p.z) - side * (HALF - 0.6),
						Vector3(p.x, topy - 0.4, p.z) + side * (HALF - 0.6), 1.6, 0.8, CONCRETE)
					L._ksolid(k, p.x - 1.6, p.z - 1.6, p.x + 1.6, p.z + 1.6, gy - 0.6, gy + 0.15, CONCRETE_DK)
			# Lamps on the central barrier, up on the deck.
			if seg % 7 == 3 and lift > 2.0:
				var yaw := atan2(dir.x, dir.z)
				var lp := a3 + Vector3.UP * 0.84
				# (A lamp at yaw faces its arm to +side, as on the bridge approach.)
				L.props.append(["streetlight", Transform3D(Basis(Vector3.UP, yaw), lp)])
				L.props.append(["streetlight", Transform3D(Basis(Vector3.UP, yaw + PI), lp)])
		seg += 1
		i = j
