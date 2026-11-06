class_name RailNetwork
extends RefCounted
## The city's railway: the City Loop, one closed line right through the
## middle of the city and across the strait, as data the trains run on plus
## its viaduct, stations and the rail bridge (set-piece kits, drawn and
## collided like everything else).
##
## The route, in the direction the trains run (one way round, single track,
## several trains spaced along it – a metro loop, never a dead end):
##   * north up the Central Spine, through midtown and the business district,
##     on median piers over the boulevard;
##   * west round the inner ring and down Dock Road to Valley Road;
##   * west along Valley Road and over the strait on its own bridge – a steel
##     through-arch, trains only – to Westbank, where it turns round on a
##     loop at the quay (Westbank station) and comes back over the bridge;
##   * east along Valley Road (the two directions side by side) and back
##     onto the Spine.
## Buildings in the way are left out of the city (_clear_corridor), so the
## line has a clear run wherever it leaves a street.
##
## A line: {name, pts: PackedVector3Array (rail top on the centreline, every
## STEP m), loop: bool, oneway: bool, trains: int, tracks: [offset m, ...]
## (+ = left of travel), stations: [s m, ...], cars: int}

const STEP := 2.0
const RAIL_H := 0.2                  # rail top above the deck
const DECK := 16.0                   # deck above the street
const WATER_DECK := 22.0             # deck over the strait (ships pass under)
const HALF := 2.8                    # deck half-width (one track)
## Where the line runs both ways side by side (Valley Road, the bridge),
## each direction's centreline is this far off the middle.
const PAIR := 3.6
const BRIDGE_Z := 370.0
const ARCH_X := [-360.0, -90.0]      # the arch span's springings
const ARCH_RISE := 54.0              # crown above the deck
const ARCH_SIDE := 8.6               # ribs either side of the middle
## The turning loop on Westbank's quay (generate_mainland keeps it clear).
const TERMINUS := Rect2(-640.0, 304.0, 200.0, 140.0)
const LOOP_C := Vector2(-580.0, 370.0)
const LOOP_R := 46.0
## Stations by where they are (each placed on the straightest run nearby).
const STATIONS := [Vector2(527.0, -300.0), Vector2(568.0, -105.0), Vector2(634.0, 175.0), Vector2(376.0, 215.0),
	Vector2(-626.0, 372.0), Vector2(520.0, 385.0)]
const CONCRETE := Color(0.62, 0.61, 0.58)
const CONCRETE_DK := Color(0.45, 0.45, 0.44)
const RAIL_STEEL := Color(0.3, 0.3, 0.31)
const ARCH_WHITE := Color(0.88, 0.88, 0.86)
const CANOPY := Color(0.18, 0.22, 0.24)
const PLATFORM := Color(0.7, 0.69, 0.66)
const STATION_LEN := 78.0            # four cars (72 m) and a little
## Platform edge from the track centre: half the car (1.5 m) + a 10 cm gap.
const PLATFORM_GAP := 1.6

var lines: Array = []
var L: CityLayout


func _init(layout: CityLayout) -> void:
	L = layout


# ------------------------------------------------------------ the City Loop
func build_city_loop() -> void:
	var ctrl := _route()
	if ctrl.size() < 16:
		push_warning("City Loop: route not found")
		return
	var sm := _resample_closed(ctrl, 30.0)
	for it in 4:
		sm = _chaikin_closed(sm)
	var flat := _resample_closed(sm, STEP)
	var n := flat.size()
	var g := PackedFloat32Array()
	g.resize(n)
	var ys := PackedFloat32Array()
	ys.resize(n)
	for i in n:
		var q := flat[i]
		g[i] = ground(q.x, q.y)
		ys[i] = WATER_DECK if _over_water(q) else g[i] + DECK
	for pass_i in 3:
		ys = _ease_closed(ys, 40)
	for i in n:
		ys[i] = maxf(ys[i], (WATER_DECK - 1.0) if _over_water(flat[i]) else g[i] + DECK - 1.5)
	ys = _ease_closed(ys, 10)
	var pts := PackedVector3Array()
	for i in n:
		pts.append(Vector3(flat[i].x, ys[i] + RAIL_H, flat[i].y))
	var stations: Array = []
	for at: Vector2 in STATIONS:
		var best := 0
		for i in n:
			if flat[i].distance_squared_to(at) < flat[best].distance_squared_to(at):
				best = i
		stations.append(_straightest(pts, best * STEP, 40.0))
	stations.sort()
	var line := {"name": "city", "pts": pts, "loop": true, "oneway": true, "trains": 3, "tracks": [0.0],
		"stations": stations, "cars": 4}
	lines.append(line)
	_clear_corridor(pts)
	L.kit_solid_only = true  # solid, but webs go to the towers either side
	_viaduct(pts)
	for s: float in stations:
		_station(line, s)
	L.kit_solid_only = false
	_strait_bridge(pts)


## Street level under (x, z): the island's, Westbank's past the strait, the
## sea in between.
func ground(x: float, z: float) -> float:
	if x < CityLayout.FAR_SHORE + 2.0 and L.mainland:
		return L.mainland.terrain.road_y(x, z)
	if x < CityLayout.RIVER_EDGE:
		return 0.0
	return L.terrain.road_y(x, z)


static func _over_water(q: Vector2) -> bool:
	return q.x < CityLayout.RIVER_EDGE + 4.0 and q.x > CityLayout.FAR_SHORE - 4.0


## The control polyline, in travel order (see the header).
func _route() -> PackedVector2Array:
	var out := PackedVector2Array()
	var spine: Dictionary = L.roads.by_name.get("spine", {})
	var inner: Dictionary = L.roads.by_name.get("inner", {})
	var valley: Dictionary = L.roads.by_name.get("valley", {})
	if spine.is_empty() or inner.is_empty() or valley.is_empty():
		return out
	# 1. North up the Spine, from Valley Road to the inner ring's north roundabout.
	var sp: PackedVector2Array = spine["pts"]
	for i in range(sp.size() - 1, -1, -1):
		if sp[i].y < 340.0 and sp[i].y > -318.0:
			out.append(sp[i])
	# 2. West and south round the inner ring to its south-west roundabout.
	var ip: PackedVector2Array = inner["pts"]
	var i0 := _nearest(ip, Vector2(468.0, -348.0))
	var i1 := _nearest(ip, Vector2(304.0, -105.0))
	var k := i0
	while k != i1:
		out.append(ip[k])
		k = (k - 1 + ip.size()) % ip.size() if _ring_dir(ip, i0, i1) < 0 else (k + 1) % ip.size()
	# 3. Down Dock Road (the street from that roundabout to Valley Road).
	var dock := _road_between(Vector2(310.0, -30.0), Vector2(419.0, 370.0))
	for q in dock:
		if q.y > -40.0 and q.y < 305.0:
			out.append(q)
	# 4. West along Valley Road (the north side), over the strait.
	var vp: PackedVector2Array = valley["pts"]
	for i in range(vp.size() - 1, -1, -1):
		if vp[i].x < 368.0 and vp[i].x > 70.0:
			out.append(vp[i] + _north(vp, i) * PAIR)
	var x := 40.0
	while x > CityLayout.FAR_SHORE - 30.0:
		out.append(Vector2(x, BRIDGE_Z - PAIR))
		x -= 30.0
	# 5. Round the turning loop on Westbank's quay.
	out.append(Vector2(-505.0, BRIDGE_Z - PAIR - 2.0))
	var phi := -40.0
	while phi > -320.0:
		out.append(LOOP_C + Vector2(cos(deg_to_rad(phi)), sin(deg_to_rad(phi))) * LOOP_R)
		phi -= 12.0
	out.append(Vector2(-505.0, BRIDGE_Z + PAIR + 2.0))
	# 6. Back over the bridge (south side) and east along Valley Road.
	x = CityLayout.FAR_SHORE - 30.0
	while x < 40.0:
		out.append(Vector2(x, BRIDGE_Z + PAIR))
		x += 30.0
	for i in vp.size():
		if vp[i].x > 70.0 and vp[i].x < 600.0:
			out.append(vp[i] - _north(vp, i) * PAIR)
	return out


static func _nearest(p: PackedVector2Array, at: Vector2) -> int:
	var best := 0
	for i in p.size():
		if p[i].distance_squared_to(at) < p[best].distance_squared_to(at):
			best = i
	return best


## -1 if the short way from i0 to i1 round a closed polyline is backwards.
static func _ring_dir(p: PackedVector2Array, i0: int, i1: int) -> int:
	var fwd := posmod(i1 - i0, p.size())
	return 1 if fwd <= p.size() / 2 else -1


## North-pointing normal of a west→east road at sample i.
static func _north(p: PackedVector2Array, i: int) -> Vector2:
	var a := p[maxi(i - 1, 0)]
	var b := p[mini(i + 1, p.size() - 1)]
	var e := (b - a).normalized()
	return Vector2(e.y, -e.x)


## The street running from near `a` to near `b` (either way round).
func _road_between(a: Vector2, b: Vector2) -> PackedVector2Array:
	for r in L.roads.roads:
		var p: PackedVector2Array = r["pts"]
		if p.size() < 2:
			continue
		if p[0].distance_to(a) < 30.0 and p[-1].distance_to(b) < 30.0:
			return p
		if p[-1].distance_to(a) < 30.0 and p[0].distance_to(b) < 30.0:
			var rev := p.duplicate()
			rev.reverse()
			return rev
	# (No such street: a straight run.)
	return PackedVector2Array([a, a.lerp(b, 0.33), a.lerp(b, 0.66), b])


## Buildings in the line's way (any part of them under or through the deck)
## are left out of the city, with whatever stood on their roofs.
func _clear_corridor(pts: PackedVector3Array) -> void:
	var grid := L._building_grid()
	var gone := {}
	var keep_kinds := ["landmark", "structure", "invisible", "bridge"]
	for i in range(0, pts.size(), 2):
		var p := pts[i]
		if _over_water(Vector2(p.x, p.z)):
			continue
		for b in grid.get(Vector2i(floori(p.x / 50.0), floori(p.z / 50.0)), []):
			if gone.has(b) or b["kind"] in keep_kinds:
				continue
			var q := CityLayout.bxf(b).affine_inverse() * p if float(b.get("rot", 0.0)) != 0.0 else p
			for t in b["tiers"]:
				if q.x > t[0] - HALF - 2.0 and q.x < t[2] + HALF + 2.0 and q.z > t[1] - HALF - 2.0 \
						and q.z < t[3] + HALF + 2.0 and t[4] < p.y + 6.0:
					gone[b] = true
					break
	if gone.is_empty():
		return
	L.buildings = L.buildings.filter(func(b): return not gone.has(b))
	L.props = L.props.filter(func(pr):
		var o: Vector3 = (pr[1] as Transform3D).origin
		for b in gone:
			if CityLayout.inside(b, o, 1.0, 8.0):
				return false
		return true)
	L._plant_candidates = L._plant_candidates.filter(func(c): return not gone.has(c[0]))
	print("City Loop: %d buildings cleared from its path" % gone.size())


## The viaduct: deck, girder, parapets, rails and ballast, on a column with a
## hammerhead every ~30 m (in the street's median; none over the strait,
## where the bridge carries it). Kits of ~300 m so each culls on its own.
func _viaduct(pts: PackedVector3Array) -> void:
	var n := pts.size()
	var k := L._kit("city_0")
	var run := 0.0
	var i := 0
	var seg := 10  # samples per drawn segment (20 m on straights)
	while i < n:
		var j := mini(i + seg, n)  # (j == n closes the loop back to sample 0)
		# Shorter chords on curves, so the straight rail pieces stay on the
		# path the wheels follow (within ~12 cm).
		while j > i + 1 and _chord_dev(pts, i, j) > 0.12:
			j -= 1
		var a := pts[i]
		var b := pts[j % n]
		var d := b - a
		var side := Vector3(-d.z, 0.0, d.x).normalized()
		var ext := d.normalized() * 0.3
		var deck_a := a - Vector3.UP * RAIL_H
		var deck_b := b - Vector3.UP * RAIL_H
		var water := _over_water(Vector2(a.x, a.z)) and _over_water(Vector2(b.x, b.z))
		L._kbeam(k, deck_a - ext + Vector3.DOWN * 0.7, deck_b + ext + Vector3.DOWN * 0.7, HALF * 2.0, 1.4, CONCRETE)
		L._kbeam(k, deck_a - ext + Vector3.DOWN * 1.7, deck_b + ext + Vector3.DOWN * 1.7, 3.0, 0.8,
			RAIL_STEEL if water else CONCRETE_DK, false)
		for sgn: float in [-1.0, 1.0]:
			var o := side * sgn * (HALF - 0.2)
			L._kbeam(k, deck_a - ext + o + Vector3.UP * 0.5, deck_b + ext + o + Vector3.UP * 0.5, 0.4, 1.0, CONCRETE)
			var ro := side * sgn * 0.72 + Vector3.DOWN * 0.08
			L._kbeam(k, a + ro - ext, b + ro + ext, 0.1, 0.16, RAIL_STEEL, false)
		var so := Vector3.DOWN * (RAIL_H - 0.04)
		L._kbeam(k, a + so - ext, b + so + ext, 2.6, 0.12, Color(0.36, 0.33, 0.3), false)  # ballast bed
		if not water:
			var s0 := i * STEP
			var s1 := j * STEP
			var sp := ceilf(s0 / 30.0) * 30.0
			while sp < s1:
				var p := _at(pts, sp)
				# (No pier over the strait, nor in a junction's mouth: the span
				# carries across it.)
				var junction := p.x > CityLayout.RIVER_EDGE and L.roads.field_at(Vector2(p.x, p.z)).w < 2.0
				if not _over_water(Vector2(p.x, p.z)) and not junction:
					var dir := _at(pts, sp + 2.0) - _at(pts, sp - 2.0)
					dir.y = 0.0
					dir = dir.normalized()
					var ps := Vector3(-dir.z, 0.0, dir.x)
					var gy := ground(p.x, p.z)
					var top := p.y - RAIL_H - 2.1
					L._kbeam(k, Vector3(p.x, gy - 0.3, p.z), Vector3(p.x, top, p.z), 1.5, 1.5, CONCRETE_DK)
					L._kbeam(k, Vector3(p.x, top + 0.4, p.z) - ps * 2.6, Vector3(p.x, top + 0.4, p.z) + ps * 2.6, 1.6,
						1.0, CONCRETE)
				sp += 30.0
		run += d.length()
		if run > 300.0:
			run = 0.0
			k = L._kit("city_%d" % L.structures.size())
		i = j


## A station: a platform each side of the track, canopies on columns, a
## stair/lift tower down to the street on the outside of the curve, name
## boards.
func _station(line: Dictionary, s0: float) -> void:
	var pts: PackedVector3Array = line["pts"]
	var k := L._kit("station")
	var a := _at(pts, s0 - STATION_LEN * 0.5)
	var b := _at(pts, s0 + STATION_LEN * 0.5)
	var d := (b - a)
	d.y = 0.0
	d = d.normalized()
	var side := Vector3(-d.z, 0.0, d.x)
	var c := _at(pts, s0)
	for sgn: float in [-1.0, 1.0]:
		var off := side * sgn * (PLATFORM_GAP + 1.75)
		var pa := a + off
		var pb := b + off
		# Platform at car-floor height, its edge along the track.
		L._kbeam(k, pa + Vector3.DOWN * 0.1, pb + Vector3.DOWN * 0.1, 3.5, 2.2, PLATFORM)
		L._kbeam(k, pa + side * sgn * -1.72 + Vector3.UP * 0.96, pb + side * sgn * -1.72 + Vector3.UP * 0.96,
			0.06, 0.04, Color(0.95, 0.8, 0.15), false)  # yellow safety line
		# Canopy: columns down the outer edge, a roof sloping to the track.
		var t := 4.0
		while t < STATION_LEN - 2.0:
			var q := pa.lerp(pb, t / STATION_LEN) + side * sgn * 1.3
			L._kbeam(k, q + Vector3.UP * 1.0, q + Vector3.UP * 4.6, 0.25, 0.25, CANOPY)
			t += 10.0
		var ra := pa + side * sgn * 0.2 + Vector3.UP * 4.75
		var rb := pb + side * sgn * 0.2 + Vector3.UP * 4.75
		L._kbeam(k, ra, rb, 4.4, 0.18, CANOPY)
		L._kbeam(k, ra + side * sgn * -2.15 + Vector3.DOWN * 0.25, rb + side * sgn * -2.15 + Vector3.DOWN * 0.25,
			0.12, 0.5, Color(0.72, 0.09, 0.08), false)  # crimson fascia
		# Back wall with a glass screen, and a name board in the middle.
		L._kbeam(k, pa + side * sgn * 1.7 + Vector3.UP * 1.6, pb + side * sgn * 1.7 + Vector3.UP * 1.6, 0.12, 1.2,
			Color(0.3, 0.38, 0.42), false)
		var m := (pa + pb) * 0.5 + side * sgn * 1.55 + Vector3.UP * 3.3
		L._kbeam(k, m - d * 2.4, m + d * 2.4, 0.1, 0.7, Color(0.08, 0.16, 0.36), false)
	# Switchback stairs down to a clear bit of pavement, a walkway across to
	# the platform (CityInfrastructure).
	if c.x > CityLayout.RIVER_EDGE:
		CityInfrastructure.station_access(L, k, c, d, side)
	else:
		# (Westbank's quay plaza: a stair tower on the outside of the loop.)
		var bend := _at(pts, s0 + 30.0) + _at(pts, s0 - 30.0) - c * 2.0
		var out := -side if Vector3(bend.x, 0.0, bend.z).dot(side) > 0.0 else side
		var tw := c + out * 9.0
		var gy := ground(tw.x, tw.z)
		L._kbeam(k, Vector3(tw.x, gy, tw.z), Vector3(tw.x, c.y + 5.0, tw.z), 4.0, 4.0, Color(0.36, 0.38, 0.4))
		L._kbeam(k, Vector3(tw.x, c.y + 5.0, tw.z), Vector3(tw.x, c.y + 5.3, tw.z), 4.6, 4.6, CANOPY)


# ------------------------------------------------------- the strait bridge
## The line's own bridge over the strait (the road has the suspension
## bridge): both directions side by side on one deck, concrete piers in the
## water, and over the shipping channel a white steel through-arch – two
## ribs either side of the trains, hangers down to the deck, wind bracing
## overhead. The ribs take a web (anchor lines): a high, long swing over
## the water.
func _strait_bridge(pts: PackedVector3Array) -> void:
	var k := L._kit("rail_bridge")
	# Deck level on the bridge (the line's own height there).
	var dy := 0.0
	var cnt := 0
	for p in pts:
		if p.x < -60.0 and p.x > CityLayout.FAR_SHORE + 40.0 and absf(p.z - BRIDGE_Z) < 10.0:
			dy += p.y - RAIL_H
			cnt += 1
	if cnt == 0:
		return
	dy /= cnt
	var zc := BRIDGE_Z
	var w := PAIR + HALF  # half-width of the double deck
	# Edge girders the length of the bridge (a deep steel fascia each side).
	for sz: float in [-1.0, 1.0]:
		L._kbeam(k, Vector3(CityLayout.FAR_SHORE - 6.0, dy - 1.2, zc + sz * (w + 0.3)),
			Vector3(CityLayout.RIVER_EDGE + 6.0, dy - 1.2, zc + sz * (w + 0.3)), 0.6, 2.6, ARCH_WHITE.darkened(0.15))
	# Piers: a pair of columns under the two tracks, a cap beam across.
	var piers: Array = [CityLayout.FAR_SHORE + 25.0, ARCH_X[0], ARCH_X[1], -45.0, 0.0]
	for x: float in piers:
		var heavy := x in ARCH_X
		for sz: float in [-1.0, 1.0]:
			var cw := 4.4 if heavy else 2.6
			L._kbeam(k, Vector3(x, -8.0, zc + sz * PAIR), Vector3(x, dy - 2.6, zc + sz * PAIR), cw, cw, CONCRETE_DK)
		L._kbeam(k, Vector3(x, dy - 2.4, zc - w - 1.2), Vector3(x, dy - 2.4, zc + w + 1.2), 3.0 if heavy else 2.0, 1.6,
			CONCRETE)
		if heavy:
			# The arch's springing block: a cutwater base in the water, and
			# a leg up to each rib's foot.
			L._kbeam(k, Vector3(x, -6.0, zc - ARCH_SIDE - 2.0), Vector3(x, 3.0, zc + ARCH_SIDE + 2.0), 9.0, 9.0,
				CONCRETE_DK)
			for sz: float in [-1.0, 1.0]:
				L._kbeam(k, Vector3(x, 2.0, zc + sz * ARCH_SIDE), Vector3(x, dy - 5.0, zc + sz * ARCH_SIDE), 3.2, 3.2,
					CONCRETE)
	# The arch ribs: a parabola from below the deck at the springings up
	# over the trains, each a chain of box-section beams.
	var x0: float = ARCH_X[0]
	var x1: float = ARCH_X[1]
	var segs := 18
	var rib := func(u: float) -> float:
		var v := u * 2.0 - 1.0
		return dy - 6.0 + (ARCH_RISE + 6.0) * (1.0 - v * v)
	for sz: float in [-1.0, 1.0]:
		var z := zc + sz * ARCH_SIDE
		for i in segs:
			var u0 := float(i) / segs
			var u1 := float(i + 1) / segs
			var a := Vector3(lerpf(x0, x1, u0), rib.call(u0), z)
			var b := Vector3(lerpf(x0, x1, u1), rib.call(u1), z)
			var ext := (b - a).normalized() * 0.6
			L._kbeam(k, a - ext, b + ext, 1.4, 2.2, ARCH_WHITE)
			if a.y > dy + 6.0 and b.y > dy + 6.0:
				L._anchor(a + Vector3.DOWN * 1.2, b + Vector3.DOWN * 1.2)
		# Hangers every 15 m, from the rib down to the deck's edge girder.
		var hx := x0 + 15.0
		while hx < x1 - 10.0:
			var hy: float = rib.call((hx - x0) / (x1 - x0))
			if hy > dy + 3.0:
				L._kbeam(k, Vector3(hx, dy - 0.2, z), Vector3(hx, hy - 1.0, z), 0.22, 0.22, ARCH_WHITE.darkened(0.1),
					false)
			hx += 15.0
	# Wind bracing between the ribs, high over the trains.
	for i in range(2, segs - 1, 2):
		var u := float(i) / segs
		var x := lerpf(x0, x1, u)
		var y: float = rib.call(u)
		if y < dy + 12.0:
			continue
		L._kbeam(k, Vector3(x, y, zc - ARCH_SIDE), Vector3(x, y, zc + ARCH_SIDE), 0.8, 1.0, ARCH_WHITE)
		if i + 2 < segs:
			var xn := lerpf(x0, x1, float(i + 2) / segs)
			var yn: float = rib.call(float(i + 2) / segs)
			L._kbeam(k, Vector3(x, y, zc - ARCH_SIDE), Vector3(xn, yn, zc + ARCH_SIDE), 0.5, 0.5, ARCH_WHITE, false)


# ------------------------------------------------------------------- helpers
static func _chord_dev(pts: PackedVector3Array, i: int, j: int) -> float:
	var n := pts.size()
	var a := Vector2(pts[i].x, pts[i].z)
	var b := Vector2(pts[j % n].x, pts[j % n].z)
	var worst := 0.0
	for k in range(i + 1, j):
		var q := Vector2(pts[k].x, pts[k].z)
		worst = maxf(worst, Geometry2D.get_closest_point_to_segment(q, a, b).distance_to(q))
	return worst


## Point s metres along a line's samples (wraps for loops, clamps otherwise).
static func _at(pts: PackedVector3Array, s: float, loop := true) -> Vector3:
	var n := pts.size()
	var f := fposmod(s / STEP, float(n)) if loop else clampf(s / STEP, 0.0, float(n - 1))
	var i := int(f)
	return pts[i].lerp(pts[(i + 1) % n] if loop else pts[mini(i + 1, n - 1)], f - i)


static func _resample_closed(p: PackedVector2Array, step: float) -> PackedVector2Array:
	var loop := p.duplicate()
	loop.append(p[0])
	var out := _resample_open(loop, step)
	out.remove_at(out.size() - 1)
	return out


static func _resample_open(p: PackedVector2Array, step: float) -> PackedVector2Array:
	var out := PackedVector2Array([p[0]])
	var total := CityRoads.length_of(p)
	var n := maxi(1, roundi(total / step))
	var st := total / n
	var acc := 0.0
	var i := 0
	for k in range(1, n + 1):
		var target := k * st
		while i < p.size() - 2 and acc + p[i].distance_to(p[i + 1]) < target:
			acc += p[i].distance_to(p[i + 1])
			i += 1
		var seg := p[i].distance_to(p[i + 1])
		out.append(p[i].lerp(p[i + 1], clampf((target - acc) / maxf(seg, 0.001), 0.0, 1.0)))
	return out


static func _chaikin_closed(p: PackedVector2Array) -> PackedVector2Array:
	var out := PackedVector2Array()
	var n := p.size()
	for i in n:
		var a := p[i]
		var b := p[(i + 1) % n]
		out.append(a.lerp(b, 0.25))
		out.append(a.lerp(b, 0.75))
	return out


static func _ease_closed(y: PackedFloat32Array, r: int) -> PackedFloat32Array:
	var n := y.size()
	var out := PackedFloat32Array()
	out.resize(n)
	var acc := 0.0
	for k in range(-r, r + 1):
		acc += y[(k + n) % n]
	for i in n:
		out[i] = acc / (2 * r + 1)
		acc += y[(i + r + 1) % n] - y[(i - r + n) % n]
	return out


## The s within ±reach of s0 where the line is straightest (stations want a
## straight run).
static func _straightest(pts: PackedVector3Array, s0: float, reach: float) -> float:
	var best := s0
	var best_c := INF
	var s := s0 - reach
	while s <= s0 + reach:
		var c := 0.0
		for o: float in [-30.0, 0.0, 30.0]:
			var d0 := _at(pts, s + o) - _at(pts, s + o - 4.0)
			var d1 := _at(pts, s + o + 4.0) - _at(pts, s + o)
			c += Vector2(d0.x, d0.z).normalized().angle_to(Vector2(d1.x, d1.z).normalized()) ** 2
		if c < best_c:
			best_c = c
			best = s
		s += 8.0
	return fposmod(best, pts.size() * STEP)
