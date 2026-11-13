class_name HarbourPoint
extends RefCounted
## Harbour Point: the south coast as a destination instead of a sea wall at
## the edge of the map.
##
##   * The Sea Fort: a round stone fort on its own island out in the bay, its
##     top a drivable plaza with a roundabout round a red-and-white lighthouse,
##     battlements round the rim (gaps either side of the gate), four turrets.
##   * The Harbour Leap: the bridge out to it on sea piles, two lanes, with a
##     pair of bascule towers and a high walkway over the shipping channel
##     and a humped crest between them: traffic rolls over it, anything doing
##     80+ km/h takes off. Lanes join the coastal ring, so the police follow
##     you out there.
##   * The Harbour Wheel: a giant observation wheel on its own pier beside the
##     bridge foot (SeaAndSky turns it and lights it at night).
##   * The promenade: a stone balustrade with lamps along the south sea wall,
##     open where the bridge leaves.
##
## Set-piece kits like everything else (drawn and collided from the same
## list); the bridge deck and the fort's plaza collide on the street layer
## (L.street_obbs) so the AI's whiskers don't take a ramp for a wall. Own
## random numbers: adding it never reshuffles the rest of the city.

const BASE_X := 780.0             # where on the south coast the bridge leaves
const SPAN := 235.0               # coast to fort rim (m)
const FORT_R := 44.0              # fort radius (rim)
const FORT_Y := 7.0               # plaza level
const LOOP_R := 25.0              # the roundabout round the lighthouse
const ISLAND_R := 14.0
const HALF := 6.4                 # deck half width (two 3.5 m lanes + barriers)
const LANE := 3.2
const LOW := 8.0                  # deck over the water before the hump
const HUMP := 5.5                 # crest above LOW
const HUMP_W := 21.0              # the crest's width (gaussian sigma, m)
const SEABED := -9.0
const SPEED := 13.0

const STONE := Color(0.62, 0.58, 0.5)
const STONE_DK := Color(0.44, 0.41, 0.36)
const ASPHALT := Color(0.17, 0.17, 0.18)
const STEEL := Color(0.2, 0.32, 0.38)
const PAINT := Color(0.86, 0.86, 0.8)
const RED := Color(0.72, 0.12, 0.1)
const WHITE := Color(0.93, 0.92, 0.88)
const GOLD := Color(0.95, 0.72, 0.3)

var L: CityLayout
var rng := RandomNumberGenerator.new()
var base := Vector2.ZERO          # on the sea wall
var start := Vector2.ZERO         # the lanes' start, at the ring road's kerb
var dir := Vector2.DOWN           # out to sea
var fort := Vector2.ZERO
var base_y := 0.0                 # street height at the sea wall
var axis := PackedVector2Array()  # lanes' centreline: start -> fort's roundabout
## The wheel, for SeaAndSky: centre, radius, the axle direction (x/z).
var wheel_c := Vector3.ZERO
var wheel_r := 30.0
var wheel_axis := Vector3.RIGHT


func _init(layout: CityLayout) -> void:
	L = layout
	rng.seed = layout.seed * 41 + 3


## Finds the spot on the south coast. False if the coast isn't there.
func plan() -> bool:
	if L.coast.size() < 3 or L.is_mainland:
		return false
	var smp: Array = BuildingMesher.shore_samples(L.coast)
	var best: Array = []
	for sm in smp:
		var p: Vector2 = sm[0]
		var n: Vector2 = sm[1]
		if n.y < 0.9:
			continue  # facing south only
		if best.is_empty() or absf(p.x - BASE_X) < absf((best[0] as Vector2).x - BASE_X):
			best = sm
	if best.is_empty() or absf((best[0] as Vector2).x - BASE_X) > 30.0:
		return false
	base = best[0]
	dir = Vector2(0.0, 1.0)  # straight out (the coast here runs east-west)
	base_y = L.terrain.road_y(base.x, base.y) + CityTerrain.KERB
	start = base - dir * (CityRoads.ESPLANADE + 0.5)
	fort = base + dir * (SPAN + FORT_R)
	axis = PackedVector2Array()
	var s := 0.0
	var end := start.distance_to(fort) - LOOP_R - 4.0
	while s < end:
		axis.append(start + dir * s)
		s += 3.0
	axis.append(start + dir * end)
	wheel_r = 30.0
	var side := Vector2(dir.y, -dir.x)  # east of the bridge
	var wp := base + dir * 22.0 + side * 34.0
	wheel_c = Vector3(wp.x, base_y + 1.0 + wheel_r + 3.0, wp.y)
	wheel_axis = Vector3(dir.x, 0.0, dir.y)  # the wheel faces along the coast
	return true


## Deck / road height along the lanes, at (x, z).
func height_at(x: float, z: float) -> float:
	var q := Vector2(x, z)
	var d := (q - base).dot(dir)   # metres out from the sea wall
	if d <= 0.0:
		return L.terrain.road_y(x, z)
	if q.distance_to(fort) < FORT_R:
		return FORT_Y
	return deck_y(d)


## The deck's top d metres out from the sea wall: down off the esplanade to
## LOW, the hump over the channel half way, then down to the fort's plaza.
func deck_y(d: float) -> float:
	var t := clampf(d / SPAN, 0.0, 1.0)
	var y := lerpf(base_y, LOW, smoothstep(0.0, 0.25, t))
	y = lerpf(y, FORT_Y, smoothstep(0.8, 1.0, t))
	var c := SPAN * 0.5
	return y + HUMP * exp(-pow((d - c) / HUMP_W, 2.0))


## True over the bridge, the fort or the wheel's pier (not open sea for the
## boats and ships; a car down there is still in the water by height).
func covers(p: Vector2, margin := 4.0) -> bool:
	if p.distance_to(fort) < FORT_R + margin:
		return true
	var d := (p - base).dot(dir)
	var lat := absf((p - base).dot(Vector2(dir.y, -dir.x)))
	if d > -2.0 and d < SPAN + 2.0 and lat < HALF + margin:
		return true
	return Vector2(wheel_c.x, wheel_c.z).distance_to(p) < 22.0 + margin


func build() -> void:
	var k := L._kit("harbour_point")
	_bridge(k)
	_fort(k)
	_wheel_pier(k)
	_promenade(k)


func _bridge(k: Dictionary) -> void:
	var side3 := Vector3(dir.y, 0.0, -dir.x)
	var fwd3 := Vector3(dir.x, 0.0, dir.y)
	var b0 := Vector3(base.x, 0.0, base.y)
	var step := 5.0
	var d := 0.0
	var n := 0
	while d < SPAN + 3.0:
		var d2 := minf(d + step, SPAN + 3.0)   # (on into the fort's gate)
		var a := b0 + fwd3 * d + Vector3.UP * deck_y(d)
		var b := b0 + fwd3 * d2 + Vector3.UP * deck_y(d2)
		var ext := (b - a).normalized() * 0.04
		var sa := a - ext + Vector3.DOWN * 0.6
		var sb := b + ext + Vector3.DOWN * 0.6
		L._kbeam(k, sa, sb, HALF * 2.0, 1.2, ASPHALT, false)
		L.street_obbs.append([Transform3D(BuildingMesher.beam_basis(sa, sb), (sa + sb) * 0.5),
			Vector3(HALF * 2.0, 1.2, sa.distance_to(sb))])
		for sg: float in [-1.0, 1.0]:
			# Steel fascia, parapet (wall), edge line.
			L._kbeam(k, a + side3 * sg * (HALF - 0.1) + Vector3.DOWN * 0.9, b + side3 * sg * (HALF - 0.1) + Vector3.DOWN * 0.9,
				0.25, 1.6, STEEL, false)
			L._kbeam(k, a + side3 * sg * (HALF - 0.2) + Vector3.UP * 0.5, b + side3 * sg * (HALF - 0.2) + Vector3.UP * 0.5,
				0.4, 1.0, STONE)
			L._kbeam(k, a + side3 * sg * (HALF - 0.8) + Vector3.UP * 0.015, b + side3 * sg * (HALF - 0.8) + Vector3.UP * 0.015,
				0.15, 0.03, PAINT, false)
		# Centre: dashed white.
		if n % 2 == 0:
			L._kbeam(k, a + Vector3.UP * 0.015, a.lerp(b, 0.6) + Vector3.UP * 0.015, 0.15, 0.03, PAINT, false)
		# Piles every 30 m out over the water (pairs, a cap beam).
		if n % 6 == 3:
			for sg: float in [-1.0, 1.0]:
				var px := a + side3 * sg * (HALF - 1.6)
				L._kbeam(k, Vector3(px.x, SEABED, px.z), Vector3(px.x, a.y - 1.2, px.z), 1.6, 1.6, STONE_DK)
			L._kbeam(k, a - side3 * HALF + Vector3.DOWN * 1.5, a + side3 * HALF + Vector3.DOWN * 1.5, 1.4, 0.8, STONE_DK)
		# Lamps on the parapets every 25 m.
		if n % 5 == 2:
			var yaw := atan2(fwd3.x, fwd3.z)
			for sg: float in [-1.0, 1.0]:
				L.props.append(["streetlight", Transform3D(Basis(Vector3.UP, yaw + (PI if sg > 0 else 0.0)),
					a + side3 * sg * (HALF - 0.2) + Vector3.UP * 1.0)])
		d = d2
		n += 1
	# The bascule towers either side of the crest, and the high walkway.
	var c := SPAN * 0.5
	for dd: float in [c - 26.0, c + 26.0]:
		var at := b0 + fwd3 * dd
		var ty := deck_y(dd)
		for sg: float in [-1.0, 1.0]:
			var tc := at + side3 * sg * (HALF + 3.2)
			var foot := PackedVector2Array()
			for i in 8:
				var an := TAU * i / 8.0 + PI / 8.0
				foot.append(Vector2(tc.x, tc.z) + Vector2(cos(an), sin(an)) * 3.3)
			L._kprism(k, foot, SEABED, ty + 26.0, STONE)
			# Pinnacle and a gold finial.
			var top := PackedVector2Array()
			for i in 8:
				var an2 := TAU * i / 8.0 + PI / 8.0
				top.append(Vector2(tc.x, tc.z) + Vector2(cos(an2), sin(an2)) * 2.2)
			L._kprism(k, top, ty + 26.0, ty + 31.0, STEEL)
			L._kbeam(k, tc + Vector3.UP * (ty + 31.0), tc + Vector3.UP * (ty + 33.5), 0.5, 0.5, GOLD, false)
			# Gothic-ish window slots (dark), visual.
			for wy: float in [8.0, 14.0, 20.0]:
				L._kbeam(k, tc + Vector3.UP * (ty + wy) - side3 * sg * 0.05 + fwd3 * 3.31,
					tc + Vector3.UP * (ty + wy + 3.0) - side3 * sg * 0.05 + fwd3 * 3.31, 1.0, 0.1, Color(0.12, 0.13, 0.15), false)
		# The pier under each pair (in the water).
		L._ksolid(k, at.x - HALF - 7.0, at.z - 5.0, at.x + HALF + 7.0, at.z + 5.0, SEABED, -0.5, STONE_DK)
	# High walkway between the towers (both sides of the road).
	var wy2 := deck_y(c) + 21.0
	for sg: float in [-1.0, 1.0]:
		var w0 := b0 + fwd3 * (c - 26.0) + side3 * sg * (HALF + 3.2) + Vector3.UP * wy2
		var w1 := b0 + fwd3 * (c + 26.0) + side3 * sg * (HALF + 3.2) + Vector3.UP * wy2
		L._kbeam(k, w0, w1, 3.0, 2.4, STEEL)
		L._kbeam(k, w0 + Vector3.UP * 1.6, w1 + Vector3.UP * 1.6, 3.2, 0.3, WHITE, false)
	# Suspension chains from the tower tops down to the bridge ends.
	for sg: float in [-1.0, 1.0]:
		for pair in [[c - 26.0, 22.0], [c + 26.0, SPAN - 22.0]]:
			var t0 := b0 + fwd3 * float(pair[0]) + side3 * sg * (HALF + 3.2) + Vector3.UP * (deck_y(pair[0]) + 18.0)
			var t1 := b0 + fwd3 * float(pair[1]) + side3 * sg * (HALF + 0.4) + Vector3.UP * (deck_y(pair[1]) + 1.2)
			L._kbeam(k, t0, t1, 0.5, 0.5, STEEL, false)


func _fort(k: Dictionary) -> void:
	var f3 := Vector3(fort.x, 0.0, fort.y)
	var ring := PackedVector2Array()
	var nseg := 28
	for i in nseg:
		var a := TAU * i / nseg
		ring.append(fort + Vector2(cos(a), sin(a)) * FORT_R)
	# The island body (walls from the sea bed), a drawn prism; its top
	# collides as street (an oriented box per wedge would do; one flat box
	# under the plaza is enough: the walls round it are the kit's).
	L._kprism(k, ring, SEABED, FORT_Y - 0.4, STONE)
	# (Two squares at 45 degrees: an octagon that reaches the rim all round.)
	for rot: float in [0.0, PI * 0.25]:
		L.street_obbs.append([Transform3D(Basis(Vector3.UP, rot), Vector3(fort.x, FORT_Y - 0.6, fort.y)),
			Vector3(FORT_R * 1.9, 1.2, FORT_R * 1.9)])
	# Plaza: paving disc with a darker road ring.
	var plaza := PackedVector2Array()
	for i in nseg:
		var a := TAU * i / nseg
		plaza.append(fort + Vector2(cos(a), sin(a)) * (FORT_R - 0.6))
	L._kprism(k, plaza, FORT_Y - 0.4, FORT_Y, Color(0.66, 0.63, 0.58))
	var road := PackedVector2Array()
	for i in nseg:
		var a := TAU * i / nseg
		road.append(fort + Vector2(cos(a), sin(a)) * (LOOP_R + 5.0))
	L._kprism(k, road, FORT_Y - 0.38, FORT_Y + 0.01, ASPHALT)
	# Battlements round the rim (walls), open 30 degrees either side of the gate.
	var gate := atan2(-dir.y, -dir.x)
	for i in nseg:
		var a0 := TAU * i / nseg
		var a1 := TAU * (i + 1) / nseg
		var mid := (a0 + a1) * 0.5
		if absf(angle_difference(mid, gate)) < deg_to_rad(16.0):
			continue
		var p0 := fort + Vector2(cos(a0), sin(a0)) * (FORT_R - 0.6)
		var p1 := fort + Vector2(cos(a1), sin(a1)) * (FORT_R - 0.6)
		L._kbeam(k, Vector3(p0.x, FORT_Y + 0.6, p0.y), Vector3(p1.x, FORT_Y + 0.6, p1.y), 1.2, 1.2, STONE_DK)
		var pm := (p0 + p1) * 0.5
		L._kbeam(k, Vector3(pm.x, FORT_Y + 1.2, pm.y), Vector3(pm.x, FORT_Y + 2.1, pm.y), 1.4, 1.4, STONE_DK, false)
	# Four turrets on the rim, off the gate's line.
	for j in 4:
		var a := gate + PI * 0.25 + PI * 0.5 * j
		var tc := fort + Vector2(cos(a), sin(a)) * (FORT_R - 1.0)
		var tp := PackedVector2Array()
		for i in 10:
			var an := TAU * i / 10.0
			tp.append(tc + Vector2(cos(an), sin(an)) * 4.2)
		L._kprism(k, tp, FORT_Y - 1.0, FORT_Y + 8.0, STONE)
		var cap := PackedVector2Array()
		for i in 10:
			var an := TAU * i / 10.0
			cap.append(tc + Vector2(cos(an), sin(an)) * 4.8)
		L._kprism(k, cap, FORT_Y + 8.0, FORT_Y + 9.0, STONE_DK)
	# The lighthouse on the roundabout's island: red and white bands, a
	# gallery, the lantern (gold, glows at night through the lamp props).
	var isl := PackedVector2Array()
	for i in 20:
		var an := TAU * i / 20.0
		isl.append(fort + Vector2(cos(an), sin(an)) * ISLAND_R)
	L._kprism(k, isl, FORT_Y - 0.3, FORT_Y + 0.25, Color(0.36, 0.5, 0.3))
	var y := FORT_Y
	for band in 7:
		var r0 := lerpf(6.0, 3.6, band / 7.0)
		var pts := PackedVector2Array()
		for i in 14:
			var an := TAU * i / 14.0
			pts.append(fort + Vector2(cos(an), sin(an)) * r0)
		L._kprism(k, pts, y, y + 5.0, RED if band % 2 == 0 else WHITE)
		y += 5.0
	var gal := PackedVector2Array()
	for i in 14:
		var an := TAU * i / 14.0
		gal.append(fort + Vector2(cos(an), sin(an)) * 4.8)
	L._kprism(k, gal, y, y + 0.6, Color(0.2, 0.2, 0.22))
	var lan := PackedVector2Array()
	for i in 14:
		var an := TAU * i / 14.0
		lan.append(fort + Vector2(cos(an), sin(an)) * 2.6)
	L._kprism(k, lan, y + 0.6, y + 4.0, GOLD)
	L._kprism(k, lan, y + 4.0, y + 5.4, RED)
	beacon = Vector3(fort.x, y + 2.3, fort.y)
	# Lamps round the plaza.
	for j in 8:
		var a := TAU * j / 8.0 + 0.2
		var lp := fort + Vector2(cos(a), sin(a)) * (FORT_R - 3.0)
		L.props.append(["streetlight", Transform3D(Basis(Vector3.UP, -a - PI * 0.5), Vector3(lp.x, FORT_Y, lp.y))])
	# A gateway arch over the entrance (high enough for a truck in the air).
	var gp := fort - dir * (FORT_R - 1.0)
	var gs := Vector3(dir.y, 0.0, -dir.x)
	var g3 := Vector3(gp.x, FORT_Y, gp.y)
	for sg: float in [-1.0, 1.0]:
		L._kbeam(k, g3 + gs * sg * (HALF + 2.0), g3 + gs * sg * (HALF + 2.0) + Vector3.UP * 11.0, 3.0, 3.0, STONE)
	L._kbeam(k, g3 - gs * (HALF + 3.5) + Vector3.UP * 11.5, g3 + gs * (HALF + 3.5) + Vector3.UP * 11.5, 3.0, 2.0, STONE_DK)


## The lighthouse lamp (SeaAndSky sweeps a glow from it at night).
var beacon := Vector3.ZERO


func _wheel_pier(k: Dictionary) -> void:
	var wp := Vector2(wheel_c.x, wheel_c.z)
	var top := base_y + 1.0
	var hx := 16.5   # along the coast (the wheel's legs spread this way)
	var hz := 8.0
	# A stone pier with a dark plinth band at the waterline, paving on top,
	# a balustrade round it and lamps at the corners.
	L._ksolid(k, wp.x - hx, wp.y - hz, wp.x + hx, wp.y + hz, SEABED, top, STONE)
	L._ksolid(k, wp.x - hx - 0.3, wp.y - hz - 0.3, wp.x + hx + 0.3, wp.y + hz + 0.3, -3.0, 0.6, STONE_DK, false)
	L._ksolid(k, wp.x - hx - 0.4, wp.y - hz - 0.4, wp.x + hx + 0.4, wp.y + hz + 0.4, top - 0.5, top, WHITE, false)
	var corners := [Vector2(-hx, -hz), Vector2(hx, -hz), Vector2(hx, hz), Vector2(-hx, hz)]
	for i in 4:
		var c0: Vector2 = wp + corners[i]
		var c1: Vector2 = wp + corners[(i + 1) % 4]
		if i == 0:
			# (North side: the walkway lands in its middle.)
			var mid := (c0 + c1) * 0.5
			for seg in [[c0, mid - Vector2(4.0, 0.0)], [mid + Vector2(4.0, 0.0), c1]]:
				var s0: Vector2 = seg[0]
				var s1: Vector2 = seg[1]
				L._kbeam(k, Vector3(s0.x, top + 0.5, s0.y), Vector3(s1.x, top + 0.5, s1.y), 0.4, 1.0, STONE)
		else:
			L._kbeam(k, Vector3(c0.x, top + 0.5, c0.y), Vector3(c1.x, top + 0.5, c1.y), 0.4, 1.0, STONE)
		L.props.append(["streetlight", Transform3D(Basis(Vector3.UP, PI * 0.25 + PI * 0.5 * i), Vector3(c0.x, top, c0.y) + Vector3((wp - c0).normalized().x, 0, (wp - c0).normalized().y) * 1.2)])
	# A-frame legs either side of the wheel (along its axle), and the hub.
	var ax := Vector3(wheel_axis.x, 0.0, wheel_axis.z).normalized()
	var along := Vector3(ax.z, 0.0, -ax.x)
	for sg: float in [-1.0, 1.0]:
		var foot := wheel_c + ax * sg * 5.0
		foot.y = top
		for lg: float in [-1.0, 1.0]:
			L._kbeam(k, foot + along * lg * 13.0, wheel_c + ax * sg * 4.0, 1.4, 1.4, WHITE)
	L._kbeam(k, wheel_c - ax * 5.0, wheel_c + ax * 5.0, 2.2, 2.2, STEEL, false)
	# The walkway from the esplanade onto the pier.
	var b3 := Vector3(wp.x, base_y, base.y)
	L._kbeam(k, b3 + Vector3.UP * 0.3, Vector3(wp.x, top + 0.3, wp.y - hz), 7.0, 0.6, STONE, true)
	for sg: float in [-1.0, 1.0]:
		L._kbeam(k, b3 + Vector3(sg * 3.4, 1.0, 0.0), Vector3(wp.x + sg * 3.4, top + 1.0, wp.y - hz), 0.3, 0.9, WHITE)


## A stone balustrade along the south sea wall with lamps, open at the
## bridge and in front of the wheel's walkway.
func _promenade(k: Dictionary) -> void:
	var smp: Array = BuildingMesher.shore_samples(L.coast)
	var prev: Variant = null
	var since_lamp := 0.0
	for sm in smp:
		var p: Vector2 = sm[0]
		var n: Vector2 = sm[1]
		if n.y < 0.7 or p.x < BASE_X - 190.0 or p.x > BASE_X + 210.0:
			prev = null
			continue
		var gap := absf(p.x - base.x) < HALF + 2.0 or absf(p.x - wheel_c.x) < 5.0
		var y := L.terrain.road_y(p.x, p.y) + CityTerrain.KERB
		var q := p - n * 0.6
		var cur := Vector3(q.x, y, q.y)
		if prev != null and not gap:
			var pv: Vector3 = prev
			if pv.distance_to(cur) < 9.0:
				L._kbeam(k, pv + Vector3.UP * 0.45, cur + Vector3.UP * 0.45, 0.5, 0.9, STONE)
				L._kbeam(k, pv + Vector3.UP * 0.95, cur + Vector3.UP * 0.95, 0.7, 0.12, WHITE, false)
				since_lamp += pv.distance_to(cur)
				if since_lamp > 28.0:
					since_lamp = 0.0
					L.props.append(["streetlight", Transform3D(Basis(Vector3.UP, atan2(n.x, n.y) + PI), cur + Vector3.UP * 0.2 - Vector3(n.x, 0, n.y) * 0.8)])
		prev = null if gap else cur
