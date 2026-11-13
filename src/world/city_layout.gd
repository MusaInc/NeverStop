class_name CityLayout
extends RefCounted
## Deterministic city plan (pure data – no nodes). An island city: the road
## network (CityRoads) is organic – boulevards, roundabouts, district street
## patterns – and every block lays its buildings out in its own frame, turned
## to face its main street (b["rot"], b["pivot"]; see bxf). Loosely Liverpool: a river
## to the west, a waterfront of three domed/clock-towered landmarks, a dense
## glass business district peaking around a radio beacon, brick docks with
## basins and cranes to the north, low Georgian terraces to the east under a
## huge sandstone cathedral, and a metro loop on viaducts through the middle.
## Heights are shaped for swinging: tall clusters, wide avenues as launch gaps,
## low-rise districts as technical terrain.
## Compact (~0.94 x 1.24 km) so every street is worth swinging down: a
## supertall core, construction sites with tower cranes, quay cranes over the
## dock basins, rooftop billboards as low anchors, and a red suspension bridge
## over the river. Structures that aren't buildings (cranes, bridge) are
## collision boxes ("structure" kind) plus `structures` specs for the mesher
## and `anchor_lines` the web targeting can snap to.

const CHUNK := 200.0
const MIN_X := 70.0
const MAX_X := 1010.0
const MIN_Z := -640.0
const MAX_Z := 600.0
const RIVER_EDGE := 30.0
const FAR_SHORE := -440.0
const CBD_CENTER := Vector2(560.0, -170.0)
const CBD_RADIUS := 330.0
const BRIDGE_Z := -17.0
## The city is an island: sea all round except the strait (the old river) to
## the mainland in the west, which the suspension bridge crosses. Past the
## outermost streets an esplanade runs to the sea wall (cliffs on the east,
## where the land is high).
const ESPLANADE := 18.0
const SEA_REACH := 4000.0
const BRIDGE_DECK := 24.0
const BRIDGE_TOWERS := [-80.0, -340.0]
const BRIDGE_TOWER_TOP := 132.0
## The mainland (Westbank) is generated like the island but mirrored, so its
## straight quay faces the strait: plan coordinates x' = MIRROR - x.
const MIRROR := FAR_SHORE + RIVER_EDGE
const MAINLAND_PLAN := Rect2(30.0, -500.0, 690.0, 980.0)   # (mirrored plan space)
## Where the bridge's approach viaduct comes down onto Westbank Hill.
const APPROACH_END := -800.0

enum Style { STONE, BRICK, GLASS, WAREHOUSE, MODERN, SANDSTONE, DARK_GLASS, DECO }

const STYLE_COLORS := {
	Style.STONE: [Color(0.80, 0.77, 0.70), Color(0.74, 0.72, 0.68), Color(0.86, 0.82, 0.74), Color(0.82, 0.72, 0.55),
		Color(0.68, 0.69, 0.68)],
	Style.BRICK: [Color(0.56, 0.28, 0.21), Color(0.63, 0.35, 0.25), Color(0.47, 0.3, 0.25), Color(0.7, 0.5, 0.38),
		Color(0.72, 0.62, 0.42), Color(0.32, 0.3, 0.32), Color(0.66, 0.3, 0.18)],
	Style.GLASS: [Color(0.36, 0.44, 0.5), Color(0.55, 0.62, 0.66), Color(0.3, 0.38, 0.36), Color(0.42, 0.36, 0.28),
		Color(0.33, 0.45, 0.42), Color(0.28, 0.36, 0.52)],
	Style.WAREHOUSE: [Color(0.5, 0.25, 0.18), Color(0.44, 0.24, 0.2), Color(0.58, 0.46, 0.32)],
	Style.MODERN: [Color(0.88, 0.88, 0.86), Color(0.36, 0.38, 0.42), Color(0.78, 0.72, 0.62), Color(0.75, 0.45, 0.32),
		Color(0.24, 0.25, 0.27), Color(0.72, 0.8, 0.74), Color(0.94, 0.93, 0.9)],
	# Painted render on the terraces: pastel streets give Old Town its colour.
	Style.SANDSTONE: [Color(0.66, 0.42, 0.33), Color(0.72, 0.5, 0.38), Color(0.86, 0.66, 0.64), Color(0.9, 0.82, 0.58),
		Color(0.66, 0.74, 0.62), Color(0.66, 0.76, 0.84), Color(0.92, 0.9, 0.84)],
	Style.DARK_GLASS: [Color(0.18, 0.2, 0.23), Color(0.25, 0.27, 0.3), Color(0.2, 0.17, 0.14)],
	Style.DECO: [Color(0.87, 0.81, 0.69), Color(0.8, 0.74, 0.64), Color(0.55, 0.7, 0.62), Color(0.86, 0.62, 0.52)],
}

var seed := 1207
var rng := RandomNumberGenerator.new()
var buildings: Array = []      # Dictionary specs (see _building); "rot"/"pivot" = the lot's frame (see bxf)
## Blocks: {poly (world), holes, district, kind ("block"|"plaza"|"park"|"piece"|"basin"|"esplanade"),
## rot, pivot (the frame lots and buildings are laid out in), level (terrace level or NAN), basin (Rect2)}
var blocks: Array = []
var water: Array = []          # Rect2 water surfaces (basins, the strait, the sea)
var basins: Array = []         # Rect2 dock basins (also in water)
var greens: Array = []         # Rect2 grass on terraced blocks (the stadium pitch)
var props: Array = []          # [kind:String, Transform3D]
var lanes: Array = []          # [from:Vector3, to:Vector3] traffic lane segments
var landmarks: Array = []      # [scene:String, Transform3D]
var spawn := Vector3(330, 0, -60)
var island := Rect2()          # bounding box of the coast
var coast := PackedVector2Array()  # the island outline (sea wall), from CityRoads
var sea: Array = []            # Rect2 (also in `water`); the island is cut out by is_water
var reserved: Array = []       # Rect2 footprints owned by landmarks and set pieces (world, axis-aligned)
var structures: Array = []     # Dictionary specs for BuildingMesher.add_structure (cranes, bridge)
var bridge_ramp := PackedVector3Array()  # island approach, deck centreline
## The Diagonal Expressway (island only; null on the mainland or if it
## couldn't be laid out) and the street-layer collision of its deck.
var expressway: Expressway
## Harbour Point on the south coast (island only; null if not laid out).
var harbour: HarbourPoint
var street_obbs: Array = []    # [Transform3D, size]: oriented boxes that collide as street
var public_furniture: Array = []  # authored public spaces, merged with street furniture
var public_gardens: Array[Vector3] = []
var anchor_lines: Array = []   # [from:Vector3, to:Vector3] web anchors on thin structures (jibs, cables)
## Set-piece collision that isn't an axis-aligned box: [Transform3D, size]
## oriented boxes (beams) and convex hulls (PackedVector3Array).
var kit_obbs: Array = []
var kit_hulls: Array = []
var pieces: SetPieces
## The railway the trains run on (and the City Loop's viaduct, stations and bridge).
var rail: RailNetwork
## The five homes (Apartments.place, after everything else is laid out).

var roads: CityRoads
## The ground (see CityTerrain): the landform on a regular grid.
var terrain := CityTerrain.new()
## True for the mainland's layout (see generate_mainland).
var is_mainland := false
## The mainland's layout, on the island's (CityWorld sets it): is_water and
## ground_y answer for both lands.
var mainland: CityLayout
var _plant_candidates: Array = []  # rooftop cooling towers, placed last (_place_plant)
var _sites: Array = []         # [Rect2 (local), district, rot, pivot] construction lots, built after the blocks
var _block_grid := {}          # Vector2i (BLOCK_CELL cells) -> block indices
const BLOCK_CELL := 40.0
const BOUNDS := Rect2(30.0, -656.0, 1000.0, 1271.0)


func generate(p_seed := 1207) -> CityLayout:
	seed = p_seed
	rng.seed = seed
	pieces = SetPieces.new(self)
	var ls := _snap()
	_landmarks()
	var keep_out: Array = []
	for r in reserved:
		keep_out.append(_rect_poly((r as Rect2).grow(5.0)))
	for r in pieces.rects().values():
		keep_out.append(_rect_poly((r as Rect2).grow(5.0)))
	keep_out.append(_rect_poly(Rect2(CBD_CENTER.x - 40 - 22, CBD_CENTER.y + 60 - 22, 44, 44)))  # beacon plaza
	keep_out.append(_rect_poly(Rect2(SetPieces.SHIP_AT - Vector2(50, 32), Vector2(100, 64))))  # the ship's basin
	roads = CityRoads.new().generate(seed, district, BOUNDS, keep_out)
	roads.bake_field(1.25)
	coast = roads.coast
	island = _bbox(coast)
	terrain.build(island.grow(80.0))
	_lift_on_slope(ls)
	_bridge()
	var ex := Expressway.new(self)
	if ex.plan():
		expressway = ex
		ex.build()
	_blocks()
	_construction()
	# Westbank first: the City Loop crosses the strait and turns round on its
	# quay (its ground, its buildings kept clear of the turning loop).
	mainland = CityLayout.new().generate_mainland(p_seed)
	rail = RailNetwork.new(self)
	rail.build_city_loop()
	_skybridges()  # (after the line: it may have cleared a tower from its path)
	pieces.lighthouse()
	CoastLife.new(self).build()  # North Beach and the Marina
	var hp := HarbourPoint.new(self)
	if hp.plan():
		harbour = hp
		hp.build()
	_traffic()
	_sea()
	CityInfrastructure.public_spaces(self)
	_place_plant()

	# Last: plazas and parks on both shores, clear of the City Loop.
	var rail_lines: Array = []
	for ln in rail.lines:
		rail_lines.append(ln["pts"])
	CityInfrastructure.open_ground(self, rail_lines)
	if mainland != null:
		CityInfrastructure.open_ground(mainland, rail_lines)
	return self


## Rooftop cooling towers, appended after every other prop (so a density
## setting keeps the same streetlights, trees and roof kit as before), each
## clear of the props already on its roof.
func _place_plant() -> void:
	var near := {}
	for p in props:
		var o: Vector3 = p[1].origin
		var k := Vector2i(floori(o.x / 8.0), floori(o.z / 8.0))
		if not near.has(k):
			near[k] = []
		near[k].append(o)
	for cand in _plant_candidates:
		# (In the building's frame when chosen: turn and lift it with the
		# building, which may have been rotated onto its lot and terraced.)
		var b: Dictionary = cand[0]
		var lp: Vector2 = cand[1]
		var X := CityLayout.bxf(b)
		var c: Vector3 = X * Vector3(lp.x, 0.0, lp.y)
		c.y = BuildingMesher.roof_y(b)
		var xf := Transform3D(X.basis * Basis(Vector3.UP, float(cand[2])), c)
		var clear := true
		var k0 := Vector2i(floori(c.x / 8.0), floori(c.z / 8.0))
		for dx in range(-1, 2):
			for dz in range(-1, 2):
				for o: Vector3 in near.get(k0 + Vector2i(dx, dz), []):
					if absf(o.y - c.y) < 3.0 and Vector2(o.x - c.x, o.z - c.z).length() < 3.6:
						clear = false
		if clear:
			props.append(["cooling_tower", xf])
	_plant_candidates.clear()


## Westbank, the mainland across the strait: the same city machinery (organic
## streets, blocks, buildings, street props, traffic) on a smaller, lower,
## leafier plan – a strip of waterfront towers facing the island, a small
## high street round a centre, and terraced suburbs up the hill behind. The
## bridge's approach lands on the hill at APPROACH_END; the strip under it is
## kept clear (a plaza).
func generate_mainland(p_seed := 1207) -> CityLayout:
	is_mainland = true
	seed = p_seed * 3 + 11
	rng.seed = seed
	pieces = SetPieces.new(self)
	rail = RailNetwork.new(self)
	var under := Rect2(APPROACH_END, BRIDGE_Z - 13.0, FAR_SHORE - 62.0 - APPROACH_END, 26.0)
	reserved.append(under)
	reserved.append(RailNetwork.TERMINUS)  # the City Loop's turning loop on the quay
	roads = CityRoads.new()
	roads.inner_radius = 0.0
	roads.landform = "westbank"
	var px := func(x: float) -> float: return MIRROR - x  # world x <-> plan x
	var N := MAINLAND_PLAN.position.y - 60.0
	var S := MAINLAND_PLAN.end.y + 60.0
	var E := MAINLAND_PLAN.end.x + 60.0
	var W := MAINLAND_PLAN.position.x - 40.0
	var land := float(px.call(APPROACH_END))
	roads.custom_majors = {
		# Westway: from where the approach lands, west over the hill.
		"westway": [Vector2(land - 6.0, BRIDGE_Z), Vector2(land + 70.0, BRIDGE_Z + 6.0), Vector2(land + 170.0, 20.0),
			Vector2(land + 260.0, 34.0), Vector2(E, 40.0)],
		# Parkway: north coast to south coast behind the waterfront.
		"parkway": [Vector2(470.0, N), Vector2(450.0, -260.0), Vector2(470.0, -20.0), Vector2(440.0, 180.0),
			Vector2(480.0, S)],
		# Shore Road and Harbour Road curve in from the quay.
		"shore": [Vector2(W, -300.0), Vector2(160.0, -330.0), Vector2(300.0, -420.0), Vector2(400.0, N)],
		"harbour": [Vector2(W, 250.0), Vector2(170.0, 235.0), Vector2(320.0, 300.0), Vector2(430.0, S)],
	}
	var term := RailNetwork.TERMINUS
	var keep: Array = [_rect_poly(Rect2(float(px.call(under.end.x)), under.position.y, under.size.x, under.size.y)),
		_rect_poly(Rect2(float(px.call(term.end.x)), term.position.y, term.size.x, term.size.y))]
	roads.generate(seed, func(x: float, z: float) -> String: return district(MIRROR - x, z), MAINLAND_PLAN, keep)
	roads.mirror_x(MIRROR)
	# The strip under the approach viaduct and the railway's turning loop:
	# cut out of the blocks they cross and kept as open plazas.
	for cut in [_rect_poly(under), _rect_poly(term)]:
		var kept: Array = []
		for b in roads.blocks:
			for q in Geometry2D.clip_polygons(b["poly"], cut):
				if not Geometry2D.is_polygon_clockwise(q) and CityRoads._area(q) > 60.0:
					kept.append({"poly": q, "district": b["district"], "kind": b["kind"]})
			for q in Geometry2D.intersect_polygons(b["poly"], cut):
				if not Geometry2D.is_polygon_clockwise(q) and CityRoads._area(q) > 30.0:
					kept.append({"poly": q, "district": b["district"], "kind": "plaza"})
		roads.blocks = kept
	roads.bake_field(1.25)
	coast = roads.coast
	island = _bbox(coast)
	terrain.build(island.grow(80.0))
	# Lamps along the approach viaduct.
	var lx := FAR_SHORE - 20.0
	while lx > APPROACH_END + 10.0:
		for sz: float in [-1.0, 1.0]:
			props.append(["streetlight", Transform3D(Basis(Vector3.UP, 0.0 if sz > 0.0 else PI),
				Vector3(lx, approach_y(lx), BRIDGE_Z + sz * 8.6))])
		lx -= 36.0
	_blocks()
	_construction()
	_skybridges()
	_traffic()
	CityInfrastructure.public_spaces(self)
	_place_plant()
	return self


func _sea() -> void:
	# The strait (west, the old river) and the open sea everywhere else; the
	# island's land is cut out of it by is_water().
	water.append(Rect2(FAR_SHORE, -2500, RIVER_EDGE - FAR_SHORE, 5000))
	sea = [Rect2(RIVER_EDGE, -SEA_REACH, SEA_REACH, SEA_REACH * 2.0),
		Rect2(-SEA_REACH, -SEA_REACH, SEA_REACH + FAR_SHORE, SEA_REACH * 2.0)]  # (round the mainland too)
	water.append_array(sea)


# ------------------------------------------------------------ frames
## A building's frame: layout code works in an axis-aligned local frame per
## block; b["rot"] (radians) about b["pivot"] (x, z) turns it into the world.
## 2-D: world = pivot + (local - pivot).rotated(rot).
static func bxf(b: Dictionary) -> Transform3D:
	var rot: float = b.get("rot", 0.0)
	if rot == 0.0:
		return Transform3D.IDENTITY
	var pv: Vector2 = b["pivot"]
	var B := Basis(Vector3.UP, -rot)
	var P := Vector3(pv.x, 0.0, pv.y)
	return Transform3D(B, P - B * P)


static func to_world2(v: Vector2, rot: float, pivot: Vector2) -> Vector2:
	return pivot + (v - pivot).rotated(rot)


static func to_local2(v: Vector2, rot: float, pivot: Vector2) -> Vector2:
	return pivot + (v - pivot).rotated(-rot)


## World-space bounding box of one tier of a building.
static func tier_aabb(b: Dictionary, t: Array) -> AABB:
	var box := AABB(Vector3(t[0], t[4], t[1]), Vector3(t[2] - t[0], t[5] - t[4], t[3] - t[1]))
	if float(b.get("rot", 0.0)) == 0.0:
		return box
	return bxf(b) * box


## World position of the centre of a building's top (y = top of the top tier).
static func top_center(b: Dictionary) -> Vector3:
	var t: Array = b["tiers"][-1]
	return bxf(b) * Vector3((t[0] + t[2]) * 0.5, t[5], (t[1] + t[3]) * 0.5)


static func base_center(b: Dictionary) -> Vector2:
	var t: Array = b["tiers"][0]
	var p := bxf(b) * Vector3((t[0] + t[2]) * 0.5, 0.0, (t[1] + t[3]) * 0.5)
	return Vector2(p.x, p.z)


## True if the world point is inside any tier of b (grown by `margin`
## sideways and below, by `above` over the top; above < 0 = margin).
static func inside(b: Dictionary, p: Vector3, margin := 0.0, above := -1.0) -> bool:
	var q := p
	if float(b.get("rot", 0.0)) != 0.0:
		q = bxf(b).affine_inverse() * p
	var up := margin if above < 0.0 else above
	for t in b["tiers"]:
		if q.x > t[0] - margin and q.x < t[2] + margin and q.z > t[1] - margin and q.z < t[3] + margin \
				and q.y > t[4] - margin and q.y < t[5] + up:
			return true
	return false


## Turns what a block generated (since `snap`) in its local frame into the world.
func _to_world(snap: Array, rot: float, pivot: Vector2) -> void:
	if rot == 0.0:
		return
	var B := Basis(Vector3.UP, -rot)
	var P := Vector3(pivot.x, 0.0, pivot.y)
	var X := Transform3D(B, P - B * P)
	for i in range(snap[0], buildings.size()):
		buildings[i]["rot"] = rot
		buildings[i]["pivot"] = pivot
	for i in range(snap[1], props.size()):
		props[i][1] = X * (props[i][1] as Transform3D)
	for i in range(snap[2], structures.size()):
		var s: Dictionary = structures[i]
		if s["type"] == "tower_crane":
			var w := to_world2(Vector2(s["x"], s["z"]), rot, pivot)
			s["x"] = w.x
			s["z"] = w.y
			s["dir"] = (s["dir"] as Vector2).rotated(rot)
	for i in range(snap[3], anchor_lines.size()):
		anchor_lines[i] = [X * (anchor_lines[i][0] as Vector3), X * (anchor_lines[i][1] as Vector3)]
	for i in range(snap[4], kit_obbs.size()):
		kit_obbs[i][0] = X * (kit_obbs[i][0] as Transform3D)
	for i in range(snap[5], kit_hulls.size()):
		var hull: PackedVector3Array = kit_hulls[i]
		for k in hull.size():
			hull[k] = X * hull[k]
		kit_hulls[i] = hull
	for i in range(snap[6], landmarks.size()):
		landmarks[i][1] = X * (landmarks[i][1] as Transform3D)


# ---------------------------------------------------------------- blocks
func _blocks() -> void:
	# The esplanade round the coast: one raised pavement (a hole = the land
	# inside the ring road's outer kerb).
	var rc := roads._ring_coast()
	var hole: PackedVector2Array = Geometry2D.offset_polygon(rc, -CityRoads.ESPLANADE)[0]
	blocks.append({"poly": coast, "holes": [hole], "district": "waterfront", "kind": "esplanade", "rot": 0.0,
		"pivot": Vector2.ZERO, "level": NAN, "basin": Rect2()})
	var beacon := Vector2(CBD_CENTER.x - 40, CBD_CENTER.y + 60)
	for rb in roads.blocks:
		var poly: PackedVector2Array = rb["poly"]
		var dist: String = rb["district"]
		var c := CityRoads._centroid(poly)
		var brng := RandomNumberGenerator.new()
		brng.seed = hash(Vector2i(int(c.x), int(c.y))) ^ seed
		var blk := {"poly": poly, "holes": [], "district": dist, "kind": rb["kind"], "rot": 0.0, "pivot": c,
			"level": NAN, "basin": Rect2()}
		blocks.append(blk)
		var snap := _snap()
		if rb["kind"] == "green":
			blk["kind"] = "park"
			_park_props(poly, brng)
			_lift_on_slope(snap)
			continue
		if rb["kind"] == "plaza":
			_lift_on_slope(snap)
			continue
		if Geometry2D.is_point_in_polygon(beacon, poly):
			blk["kind"] = "park"
			_park_props(poly, brng, [Rect2(beacon - Vector2(16, 16), Vector2(32, 32))])
			_lift_on_slope(snap)
			continue
		# Set pieces (axis-aligned rects) in this block.
		var mine: Array = []
		for name in pieces.rects():
			var r: Rect2 = pieces.rects()[name]
			if Geometry2D.is_point_in_polygon(r.get_center(), poly):
				mine.append([name, r])
		var has_reserved := not mine.is_empty()
		for r in reserved:
			if Geometry2D.is_point_in_polygon((r as Rect2).get_center(), poly):
				has_reserved = true
		var is_basin := dist == "docks" and (Geometry2D.is_point_in_polygon(SetPieces.SHIP_AT, poly)
			or brng.randf() < 0.4 and c.x < 470.0)
		# The block's frame: along its longest edge (buildings face that
		# street); axis-aligned where landmarks, set pieces or basins are.
		var rot := 0.0 if has_reserved or is_basin else _frame_angle(poly)
		blk["rot"] = rot
		var lp := PackedVector2Array()
		for v in poly:
			lp.append(to_local2(v, rot, c))
		if not mine.is_empty():
			for m in mine:
				pieces.build(m[0], m[1])
			blk["kind"] = "piece"
			_fill_block(poly, dist, brng, rot, c)
			blk["level"] = terrain.poly_level(poly)
			_lift(snap, float(blk["level"]) - CityTerrain.KERB)
			continue
		if is_basin:
			var basin := _inscribed(lp).grow(-6.0)
			if basin.size.x > 30.0 and basin.size.y > 30.0:
				blk["kind"] = "basin"
				blk["basin"] = basin
				water.append(basin)
				basins.append(basin)
				_quay_cranes(basin, brng)
				pieces.ship(basin)
				blk["level"] = terrain.poly_level(poly)
				_lift(snap, float(blk["level"]) - CityTerrain.KERB)
				continue
		if dist == "georgian" and brng.randf() < 0.07 or dist == "midtown" and brng.randf() < 0.05 \
				or dist == "suburb" and brng.randf() < 0.12:
			blk["kind"] = "park"
			_park_props(poly, brng)
			_lift_on_slope(snap)
			continue
		var snap_p := _snap()
		_street_props(lp, brng)
		_to_world(snap_p, rot, c)  # (street props were laid out in the block's frame)
		_fill_block(poly, dist, brng, rot, c)
		_lift_on_slope(snap)
	_index_blocks()


## Direction (radians, in (-45°, 45°]) of the block's longest edge.
func _frame_angle(poly: PackedVector2Array) -> float:
	var best := 0.0
	var best_l := 0.0
	for i in poly.size():
		var e := poly[(i + 1) % poly.size()] - poly[i]
		if e.length() > best_l:
			best_l = e.length()
			best = e.angle()
	best = fposmod(best + PI * 0.25, PI * 0.5) - PI * 0.25
	return 0.0 if absf(best) < deg_to_rad(0.5) else best


## A large axis-aligned rectangle inside a polygon (shrunk from its bounds).
static func _inscribed(poly: PackedVector2Array) -> Rect2:
	return _fit_rect(_bbox(poly), poly)


## Shrinks r until its corners are inside poly and no poly vertex is inside it.
static func _fit_rect(r: Rect2, poly: PackedVector2Array) -> Rect2:
	var x0 := r.position.x
	var z0 := r.position.y
	var x1 := r.end.x
	var z1 := r.end.y
	for it in 60:
		if x1 - x0 < 6.0 or z1 - z0 < 6.0:
			return Rect2()
		var c := [Vector2(x0, z0), Vector2(x1, z0), Vector2(x1, z1), Vector2(x0, z1)]
		var bad := [not Geometry2D.is_point_in_polygon(c[0], poly), not Geometry2D.is_point_in_polygon(c[1], poly),
			not Geometry2D.is_point_in_polygon(c[2], poly), not Geometry2D.is_point_in_polygon(c[3], poly)]
		if not (bad[0] or bad[1] or bad[2] or bad[3]):
			var poke := false
			for v in poly:
				if v.x > x0 + 0.01 and v.x < x1 - 0.01 and v.y > z0 + 0.01 and v.y < z1 - 0.01:
					poke = true
					# Cut the rect on the side nearest the poking vertex.
					var d := [v.x - x0, x1 - v.x, v.y - z0, z1 - v.y]
					var k := 0
					for q in 4:
						if d[q] < d[k]:
							k = q
					match k:
						0: x0 = v.x
						1: x1 = v.x
						2: z0 = v.y
						3: z1 = v.y
					break
			if not poke:
				return Rect2(x0, z0, x1 - x0, z1 - z0)
			continue
		var sx := (x1 - x0) * 0.04 + 0.4
		var sz := (z1 - z0) * 0.04 + 0.4
		if bad[0] or bad[3]: x0 += sx
		if bad[1] or bad[2]: x1 -= sx
		if bad[0] or bad[1]: z0 += sz
		if bad[2] or bad[3]: z1 -= sz
	return Rect2()


static func _bbox(poly: PackedVector2Array) -> Rect2:
	var lo := Vector2(INF, INF)
	var hi := Vector2(-INF, -INF)
	for v in poly:
		lo = lo.min(v)
		hi = hi.max(v)
	return Rect2(lo, hi - lo)


static func _rect_poly(r: Rect2) -> PackedVector2Array:
	return PackedVector2Array([r.position, Vector2(r.end.x, r.position.y), r.end, Vector2(r.position.x, r.end.y)])


func _index_blocks() -> void:
	_block_grid.clear()
	for i in blocks.size():
		if blocks[i]["kind"] == "esplanade":
			continue
		var bb := _bbox(blocks[i]["poly"])
		for gx in range(floori(bb.position.x / BLOCK_CELL), floori(bb.end.x / BLOCK_CELL) + 1):
			for gz in range(floori(bb.position.y / BLOCK_CELL), floori(bb.end.y / BLOCK_CELL) + 1):
				var k := Vector2i(gx, gz)
				if not _block_grid.has(k):
					_block_grid[k] = PackedInt32Array()
				_block_grid[k].append(i)


## Index of the block (raised pavement) containing (x, z), or -1 on a road
## or off the island. The esplanade counts as a block.
func block_at(x: float, z: float) -> int:
	var p := Vector2(x, z)
	for i in _block_grid.get(Vector2i(floori(x / BLOCK_CELL), floori(z / BLOCK_CELL)), PackedInt32Array()):
		if Geometry2D.is_point_in_polygon(p, blocks[i]["poly"]):
			return i
	if not blocks.is_empty() and blocks[0]["kind"] == "esplanade" and Geometry2D.is_point_in_polygon(p, coast) \
			and not Geometry2D.is_point_in_polygon(p, blocks[0]["holes"][0]):
		return 0
	return -1


## Height of what you'd stand on at (x, z): a block's pavement or the road.
## (Basins are water: their quay ring is the block level.)
func ground_y(x: float, z: float) -> float:
	if mainland != null and x < FAR_SHORE:
		return mainland.ground_y(x, z)
	var i := block_at(x, z)
	if i >= 0:
		var lv: float = blocks[i]["level"]
		return lv if not is_nan(lv) else terrain.road_y(x, z) + CityTerrain.KERB
	return terrain.road_y(x, z)


func _reserved(r: Rect2) -> bool:
	for q in reserved:
		if r.grow(4.0).intersects(q):
			return true
	for q in pieces.rects().values():
		if r.grow(3.0).intersects(q):
			return true
	return false


func _park_props(poly: PackedVector2Array, brng: RandomNumberGenerator, avoid: Array = []) -> void:
	var bb := _bbox(poly)
	var n := int(CityRoads._area(poly) / 420.0)
	for i in n:
		var p := Vector2(brng.randf_range(bb.position.x + 5, bb.end.x - 5), brng.randf_range(bb.position.y + 5, bb.end.y - 5))
		var s := brng.randf_range(0.8, 1.35)
		var yaw := brng.randf_range(0, TAU)
		if not Geometry2D.is_point_in_polygon(p, Geometry2D.offset_polygon(poly, -4.0)[0] if poly.size() > 2 else poly):
			continue
		var blocked := false
		for r in avoid:
			if (r as Rect2).has_point(p):
				blocked = true
		if not blocked:
			props.append(["tree", Transform3D(Basis(Vector3.UP, yaw).scaled(Vector3.ONE * s), Vector3(p.x, 0.15, p.y))])


## Streetlights along the block's edges (local frame), facing the road.
func _street_props(lp: PackedVector2Array, brng: RandomNumberGenerator) -> void:
	var inner := Geometry2D.offset_polygon(lp, -1.2)
	if inner.is_empty():
		return
	var ring: PackedVector2Array = CityRoads._simplify(_closed(inner[0]), 1.5)
	ring.remove_at(ring.size() - 1)
	var trees := brng.randf() < 0.5
	for i in ring.size():
		var a := ring[i]
		var b := ring[(i + 1) % ring.size()]
		var L := a.distance_to(b)
		if L < 14.0:
			continue
		var d := (b - a) / L
		var out := Vector2(d.y, -d.x)  # (ccw ring: right of travel is outside)
		var yaw := atan2(-out.x, -out.y) + PI * 0.5
		var t := 8.0
		while t < L - 6.0:
			var p := a + d * t
			props.append(["streetlight", Transform3D(Basis(Vector3.UP, yaw), Vector3(p.x, 0.15, p.y))])
			if trees and t + 16.0 < L - 6.0:
				var q := a + d * (t + 16.0) - out * 0.8
				props.append(["tree", Transform3D(Basis().scaled(Vector3.ONE * 0.7), Vector3(q.x, 0.15, q.y))])
			t += 32.0


## Lot sizes per district: [frontage min, max, depth min, max] (m).
const LOTS := {
	"cbd": [20.0, 34.0, 24.0, 38.0],
	"midtown": [18.0, 32.0, 22.0, 34.0],
	"waterfront": [18.0, 30.0, 20.0, 30.0],
	"docks": [20.0, 36.0, 20.0, 32.0],
	"georgian": [13.0, 22.0, 16.0, 24.0],
	"suburb": [12.0, 20.0, 14.0, 22.0],
}


## Buildings round a block (world polygon): lots along every street
## frontage, each turned to face its own street, then a tower in the
## courtyard if there's room. Each lot is built in its own frame.
func _fill_block(poly: PackedVector2Array, dist: String, brng: RandomNumberGenerator, rot: float, pivot: Vector2) -> void:
	var ins := Geometry2D.offset_polygon(poly, -3.5)
	if ins.is_empty():
		return
	var inner: PackedVector2Array = CityRoads._simplify(_closed(ins[0]), 1.2)
	inner.remove_at(inner.size() - 1)
	var size: Array = LOTS.get(dist, LOTS["midtown"])
	var placed: Array = []
	var lots: Array = []   # [local Rect2, rot, pivot]
	for i in inner.size():
		var a := inner[i]
		var b := inner[(i + 1) % inner.size()]
		var L := a.distance_to(b)
		if L < 12.0:
			continue
		var d := (b - a) / L
		var n := Vector2(-d.y, d.x)
		var side := 1.0
		if not Geometry2D.is_point_in_polygon((a + b) * 0.5 + n * 1.0, inner):
			n = -n
			side = -1.0
		var t := 0.0
		while t < L - 9.0:
			var w := minf(brng.randf_range(size[0], size[1]), L - t)
			var depth := brng.randf_range(size[2], size[3])
			var ok := false
			for attempt in 3:
				var q := PackedVector2Array([a + d * t, a + d * (t + w), a + d * (t + w) + n * depth, a + d * t + n * depth])
				if _quad_fits(q, inner, placed):
					placed.append(q)
					var pv := a + d * t
					var r := Rect2(pv.x, pv.y, w, depth) if side > 0.0 else Rect2(pv.x, pv.y - depth, w, depth)
					lots.append([r, d.angle(), pv])
					ok = true
					break
				depth *= 0.72
				if depth < 9.0:
					break
			t += w if ok else 4.0
	# A courtyard tower: the biggest square that still fits in the middle.
	var c := CityRoads._centroid(inner)
	var side2 := 46.0
	while side2 >= 16.0:
		var q := PackedVector2Array()
		for k in 4:
			q.append(c + Vector2(cos(rot + PI * 0.25 + k * PI * 0.5), sin(rot + PI * 0.25 + k * PI * 0.5)) * side2 * 0.7071)
		if _quad_fits(q, inner, placed):
			placed.append(q)
			var pv2 := q[2]  # (the corner whose local frame has the square at +x, +y)
			var best := q[0]
			for v in q:
				var lv := to_local2(v, rot, c)
				if lv.x < to_local2(best, rot, c).x - 0.01 or (absf(lv.x - to_local2(best, rot, c).x) < 0.01 and lv.y < to_local2(best, rot, c).y):
					best = v
			pv2 = best
			lots.append([Rect2(pv2.x, pv2.y, side2, side2), rot, pv2])
			break
		side2 -= 6.0
	# Construction sites (cbd/midtown): the biggest lot gets a half-built
	# frame and a tower crane instead of a building.
	var site := -1
	if dist in ["cbd", "midtown"] and _sites.size() < 9 and brng.randf() < 0.17:
		var best_a := 0.0
		for li in lots.size():
			var r0: Rect2 = lots[li][0]
			if r0.get_area() > best_a and minf(r0.size.x, r0.size.y) > 24.0:
				best_a = r0.get_area()
				site = li
		if site >= 0:
			_sites.append([lots[site][0], dist, lots[site][1], lots[site][2]])
	for li in lots.size():
		if li == site:
			continue
		var r: Rect2 = (lots[li][0] as Rect2).grow(-0.8)
		var snap := _snap()
		var lrot: float = lots[li][1]
		var lpv: Vector2 = lots[li][2]
		if rot == 0.0 and _reserved(r) and absf(lrot) < 0.001:
			continue
		_make_building(r, dist, brng)
		_to_world(snap, lrot, lpv)


## The quad (world) is inside `inner` and clear of every placed quad.
func _quad_fits(q: PackedVector2Array, inner: PackedVector2Array, placed: Array) -> bool:
	for v in q:
		if not Geometry2D.is_point_in_polygon(v, inner):
			return false
	for v in inner:
		if Geometry2D.is_point_in_polygon(v, q):
			return false
	var shrunk: PackedVector2Array = Geometry2D.offset_polygon(q, -0.6)[0] if not Geometry2D.offset_polygon(q, -0.6).is_empty() else q
	for p in placed:
		if not Geometry2D.intersect_polygons(shrunk, p).is_empty():
			return false
	for r in reserved:
		if not Geometry2D.intersect_polygons(q, _rect_poly((r as Rect2).grow(2.0))).is_empty():
			return false
	for r in pieces.rects().values():
		if not Geometry2D.intersect_polygons(q, _rect_poly((r as Rect2).grow(2.0))).is_empty():
			return false
	return true


static func _closed(p: PackedVector2Array) -> PackedVector2Array:
	var q := p.duplicate()
	q.append(p[0])
	return q


## Lifts what was added to the layout since `snap` (see _snap) by dy metres:
## buildings, props, structures (their y0), anchors, set-piece collision and
## landmark models (terraced blocks: set pieces, basins).

## Lifts what a sloping block's generation added since `snap` (already in
## the world): each building stands level on its own lot at the lot's highest
## corner (its base course shows down the slope: b["foot"]); whatever stands
## on or in a building (roof props, huts, spires, signs) rises with that
## building; the rest (street lights, trees) stands on the ground where it is.
func _lift_on_slope(snap: Array) -> void:
	var feet: Array = []  # [building, local footprint Rect2, dy]
	for i in range(snap[0], buildings.size()):
		var b: Dictionary = buildings[i]
		if not b["kind"] in ["normal", "landmark"]:
			continue
		var t: Array = b["tiers"][0]
		var fp := Rect2(t[0], t[1], t[2] - t[0], t[3] - t[1])
		var inside_other := false
		for f in feet:
			if float((f[0] as Dictionary).get("rot", 0.0)) == float(b.get("rot", 0.0)) \
					and (f[1] as Rect2).grow(0.05).encloses(fp):
				inside_other = true  # stands on an earlier building (towers on podiums)
		if inside_other:
			continue
		var hi := -INF
		var lo := INF
		var X := bxf(b)
		for cn: Vector2 in [fp.position, fp.end, Vector2(fp.end.x, fp.position.y), Vector2(fp.position.x, fp.end.y)]:
			var w := X * Vector3(cn.x, 0.0, cn.y)
			var y := terrain.road_y(w.x, w.z)
			hi = maxf(hi, y)
			lo = minf(lo, y)
		feet.append([b, fp, hi])
		b["foot"] = lo
	var dy_at := func(x: float, z: float, rot: float, pivot: Vector2) -> float:
		for f in feet:
			var fb: Dictionary = f[0]
			var q := Vector2(x, z)
			if float(fb.get("rot", 0.0)) != 0.0:
				q = to_local2(q, fb["rot"], fb["pivot"])
			if (f[1] as Rect2).grow(0.05).has_point(q):
				return f[2]
		return terrain.road_y(x, z)
	for i in range(snap[0], buildings.size()):
		var b: Dictionary = buildings[i]
		var t: Array = b["tiers"][0]
		var at: Vector2 = b.get("lift_at", Vector2((t[0] + t[2]) * 0.5, (t[1] + t[3]) * 0.5))
		var w := bxf(b) * Vector3(at.x, 0.0, at.y)
		var dy: float = dy_at.call(w.x, w.z, 0.0, Vector2.ZERO)
		for tt in b["tiers"]:
			tt[4] += dy
			tt[5] += dy
		if b.has("roof"):
			b["roof"] += dy
		if b.has("foot"):
			b["foot"] = minf(b["foot"], dy)
		b["base"] = float(b.get("base", 0.0)) + dy
	for i in range(snap[1], props.size()):
		var xf: Transform3D = props[i][1]
		props[i][1] = xf.translated(Vector3(0, dy_at.call(xf.origin.x, xf.origin.z, 0.0, Vector2.ZERO), 0))
	for i in range(snap[3], anchor_lines.size()):
		var m: Vector3 = (anchor_lines[i][0] + anchor_lines[i][1]) * 0.5
		var up := Vector3(0, dy_at.call(m.x, m.z, 0.0, Vector2.ZERO), 0)
		anchor_lines[i] = [anchor_lines[i][0] + up, anchor_lines[i][1] + up]
	for i in range(snap[6], landmarks.size()):
		var o: Vector3 = (landmarks[i][1] as Transform3D).origin
		landmarks[i][1] = (landmarks[i][1] as Transform3D).translated(Vector3(0, dy_at.call(o.x, o.z, 0.0, Vector2.ZERO), 0))


func _snap() -> Array:
	return [buildings.size(), props.size(), structures.size(), anchor_lines.size(), kit_obbs.size(),
		kit_hulls.size(), landmarks.size()]


## Half-built towers on the construction lots picked while filling blocks:
## concrete core, open floor slabs, and a tower crane whose jib clears the
## neighbours (it's placed to swing from: the jib reaches out over a street).
func _construction() -> void:
	for entry in _sites:
		var snap := _snap()
		var rot: float = entry[2]
		var pivot: Vector2 = entry[3]
		_site(entry)
		_to_world(snap, rot, pivot)
		# Rigid (the crane's collision must stay with the crane), on the lot's
		# highest corner; the frame's foot reaches down the slope.
		var lot: Rect2 = entry[0]
		var hi := -INF
		var lo := INF
		for c: Vector2 in [lot.position, lot.end, Vector2(lot.end.x, lot.position.y), Vector2(lot.position.x, lot.end.y)]:
			var w := to_world2(c, rot, pivot)
			hi = maxf(hi, terrain.road_y(w.x, w.y))
			lo = minf(lo, terrain.road_y(w.x, w.y))
		_lift(snap, hi)
		for i in range(snap[0], buildings.size()):
			buildings[i]["foot"] = lo


## One construction site (frame, core, crane), built at street level 0 in
## the block's local frame.
func _site(entry: Array) -> void:
	var lot: Rect2 = (entry[0] as Rect2).grow(-1.2)
	var dist: String = entry[1]
	_site_frame = [entry[2], entry[3], buildings.size()]
	var brng := RandomNumberGenerator.new()
	brng.seed = hash(Vector2i(int(lot.position.x), int(lot.position.y))) ^ seed
	var c := lot.get_center()
	var h := clampf(_height_for(dist, c, brng) * brng.randf_range(0.4, 0.6), 34.0, 120.0)
	var f := lot.grow(-4.0)
	var floors: Array = []
	var y := 4.2
	while y <= h:
		floors.append([f.position.x, f.position.y, f.end.x, f.end.y, y - 0.45, y])
		y += 4.2
	var top: float = floors[-1][5]
	var fb := _building(floors, Style.MODERN, Color(0.66, 0.65, 0.62), "frame")
	_add(fb)
	_add(_building([[c.x - 4.5, c.y - 4.5, c.x + 4.5, c.y + 4.5, 0.0, top + 6.0]], Style.MODERN,
		Color(0.62, 0.61, 0.58), "plain"))
	props.append(["ac_unit", Transform3D(Basis(), Vector3(c.x + 6.0, top, c.y + 6.0))])
	_tower_crane(lot, top, brng)


var _site_frame: Array = [0.0, Vector2.ZERO, 0]


## Tallest building/structure top whose footprint touches the strip a→b
## (width w), both in the current construction site's local frame.
func _max_height_along(a: Vector2, b: Vector2, w: float) -> float:
	var rot: float = _site_frame[0]
	var pv: Vector2 = _site_frame[1]
	var wa := to_world2(a, rot, pv)
	var wb := to_world2(b, rot, pv)
	var r := Rect2(wa, Vector2.ZERO).expand(wb).grow(w * 0.5)
	var best := 0.0
	for i in mini(int(_site_frame[2]), buildings.size()):
		var bd: Dictionary = buildings[i]
		for t in bd["tiers"]:
			var bx := tier_aabb(bd, t)
			if Rect2(bx.position.x, bx.position.z, bx.size.x, bx.size.z).intersects(r):
				best = maxf(best, t[5] - float(bd.get("base", 0.0)))
	return best


## Sky bridges between tall neighbours (any orientation): a glass tube from
## one tower's core to the other's at 40–60% of the lower one's height,
## clear of every other building. In the CBD a few are four-storey "sky
## lobbies" (gateways) high over the boulevards.
func _skybridges() -> void:
	var tall: Array = []
	for b in buildings:
		if b["kind"] != "normal":
			continue
		var c := base_center(b)
		var top := float(b["tiers"][-1][5]) - float(b.get("base", 0.0))
		if top > 80.0 and district(c.x, c.y) in ["cbd", "midtown"]:
			tall.append([b, c, top])
	var grid := _building_grid()
	var made := 0
	var lobbies := 0
	var used := {}
	for i in tall.size():
		for j in range(i + 1, tall.size()):
			if made >= 22:
				return
			var A: Array = tall[i]
			var Bt: Array = tall[j]
			if used.has(i) or used.has(j):
				continue
			var d: float = (A[1] as Vector2).distance_to(Bt[1])
			if d < 26.0 or d > 62.0:
				continue
			var lobby := lobbies < 6 and district(A[1].x, A[1].y) == "cbd" and minf(A[2], Bt[2]) > 120.0
			var base := maxf(float(A[0].get("base", 0.0)), float(Bt[0].get("base", 0.0)))
			var y := base + minf(A[2], Bt[2]) * (0.42 if lobby else rng.randf_range(0.4, 0.6))
			var hh := 15.0 if lobby else 5.0
			# Both ends must be inside their towers over the whole height.
			var wa := _tier_width_at(A[0], y, hh)
			var wb := _tier_width_at(Bt[0], y, hh)
			var width := minf(minf(wa, wb) * 0.6, 22.0 if lobby else 7.0)
			if width < 5.0:
				continue
			var a2: Vector2 = A[1]
			var b2: Vector2 = Bt[1]
			if not _span_clear(grid, a2, b2, y, hh, width, [A[0], Bt[0]]):
				continue
			var mid := (a2 + b2) * 0.5
			var rot := (b2 - a2).angle()
			var bd := _building([[mid.x - d * 0.5, mid.y - width * 0.5, mid.x + d * 0.5, mid.y + width * 0.5, y, y + hh]],
				Style.DARK_GLASS, Color(0.2, 0.24, 0.28), "bridge")
			bd["rot"] = rot
			bd["pivot"] = mid
			_add(bd)
			used[i] = true
			used[j] = true
			made += 1
			if lobby:
				lobbies += 1


## Smallest horizontal size of the tier of b spanning [y, y + h] (0 if none).
static func _tier_width_at(b: Dictionary, y: float, h: float) -> float:
	for t in b["tiers"]:
		if y >= float(t[4]) and y + h <= float(t[5]):
			return minf(float(t[2]) - float(t[0]), float(t[3]) - float(t[1]))
	return 0.0


func _building_grid() -> Dictionary:
	var g := {}
	for b in buildings:
		if not b["kind"] in ["normal", "landmark", "plain", "frame", "bridge", "spire"]:
			continue
		for t in b["tiers"]:
			var bx := tier_aabb(b, t)
			for gx in range(floori(bx.position.x / 50.0), floori(bx.end.x / 50.0) + 1):
				for gz in range(floori(bx.position.z / 50.0), floori(bx.end.z / 50.0) + 1):
					var k := Vector2i(gx, gz)
					if not g.has(k):
						g[k] = []
					if (g[k] as Array).is_empty() or not is_same(g[k][-1], b):
						g[k].append(b)
	return g


## The box from a to b (heights y..y+h, width w) passes through nothing but
## the two towers it joins.
func _span_clear(grid: Dictionary, a: Vector2, b: Vector2, y: float, h: float, w: float, own: Array) -> bool:
	var dir := (b - a).normalized()
	var side := Vector2(-dir.y, dir.x)
	var n := int(a.distance_to(b) / 2.0) + 1
	for i in n + 1:
		var p := a.lerp(b, float(i) / n)
		for s: float in [-0.5, 0.0, 0.5]:
			for yy: float in [y + 0.5, y + h * 0.5, y + h - 0.5]:
				var q := p + side * w * s
				var P := Vector3(q.x, yy, q.y)
				for bd in grid.get(Vector2i(floori(q.x / 50.0), floori(q.y / 50.0)), []):
					if is_same(bd, own[0]) or is_same(bd, own[1]):
						continue
					if inside(bd, P, 1.0):
						return false
	return true


# --------------------------------------------------------------- traffic
## Two lanes on every road (one each way, 3.2 m off the centre line), four
## on the boulevards; simplified into straight segments for the GPU traffic.
## Traffic lights where side streets meet the road they end on.
func _traffic() -> void:
	for r in roads.roads:
		var pts := CityRoads._simplify(r["pts"], 0.8)
		if pts.size() < 2:
			continue
		var offs := [3.2] if r["kind"] == "minor" else [3.2, 7.0]
		if float(r["w"]) < 14.0:
			offs = [2.6]
		for o in offs:
			for sgn: float in [1.0, -1.0]:
				var line := _offset_line(pts, o * sgn)
				if sgn < 0.0:
					line.reverse()
				for i in line.size() - 1:
					lanes.append([Vector3(line[i].x, 0.0, line[i].y), Vector3(line[i + 1].x, 0.0, line[i + 1].y)])
	for r in roads.roads:
		if r["kind"] != "minor":
			continue
		var pts: PackedVector2Array = r["pts"]
		var hw: float = float(r["w"]) * 0.5
		for e in 2:
			var end := pts[0] if e == 0 else pts[-1]
			var inner := pts[1] if e == 0 else pts[-2]
			var dir := (end - inner).normalized()  # travelling towards the junction
			var right := Vector2(-dir.y, dir.x)
			var p := end - dir * 2.0 + right * (hw + 1.0)
			var yaw := atan2(dir.x, dir.y)
			var at := Vector3(p.x, 0.0, p.y)
			at.y = ground_y(p.x, p.y)
			if block_at(p.x, p.y) >= 0 and blocks[block_at(p.x, p.y)]["kind"] in ["block", "plaza"]:
				props.append(["traffic_light", Transform3D(Basis(Vector3.UP, yaw), at)])


## A polyline shifted sideways by `o` (+ = right of travel), mitred.
static func _offset_line(pts: PackedVector2Array, o: float) -> PackedVector2Array:
	var out := PackedVector2Array()
	for i in pts.size():
		var a := pts[maxi(i - 1, 0)]
		var b := pts[mini(i + 1, pts.size() - 1)]
		var d := (b - a).normalized()
		var n := Vector2(-d.y, d.x)
		out.append(pts[i] + n * o)
	return out


static func _subtract(r: Rect2, hole: Rect2) -> Array:
	if not r.intersects(hole):
		return [r]
	var out: Array = []
	var h := r.intersection(hole)
	if h.position.y > r.position.y:
		out.append(Rect2(r.position.x, r.position.y, r.size.x, h.position.y - r.position.y))
	if h.end.y < r.end.y:
		out.append(Rect2(r.position.x, h.end.y, r.size.x, r.end.y - h.end.y))
	if h.position.x > r.position.x:
		out.append(Rect2(r.position.x, h.position.y, h.position.x - r.position.x, h.size.y))
	if h.end.x < r.end.x:
		out.append(Rect2(h.end.x, h.position.y, r.end.x - h.end.x, h.size.y))
	return out


static func chunk_of(p: Vector2) -> Vector2i:
	return Vector2i(floori(p.x / CHUNK), floori(p.y / CHUNK))


func buildings_by_chunk() -> Dictionary:
	var out := {}
	for b in buildings:
		var k := chunk_of(base_center(b))
		if not out.has(k):
			out[k] = []
		out[k].append(b)
	return out


func props_by_chunk() -> Dictionary:
	var out := {}
	for p in props:
		var o: Vector3 = p[1].origin
		var k := chunk_of(Vector2(o.x, o.z))
		if not out.has(k):
			out[k] = []
		out[k].append(p)
	return out


func is_water(p: Vector3) -> bool:
	var q := Vector2(p.x, p.z)
	for w in basins:
		if (w as Rect2).has_point(q):
			return true
	if is_mainland:
		return not Geometry2D.is_point_in_polygon(q, coast)
	if p.x < RIVER_EDGE:
		if p.x > FAR_SHORE:
			return true
		return mainland != null and mainland.is_water(p)
	return not Geometry2D.is_point_in_polygon(q, coast)


## Sea a boat can sail on: water, and not under Harbour Point's bridge,
## fort or wheel pier.
func is_open_water(p: Vector3) -> bool:
	if harbour and harbour.covers(Vector2(p.x, p.z), 8.0):
		return false
	return is_water(p)


func is_park(p: Vector2) -> bool:
	var i := block_at(p.x, p.y)
	return i >= 0 and blocks[i]["kind"] == "park"


func mean_height_near(p: Vector2, radius: float) -> float:
	var total := 0.0
	var n := 0
	for b in buildings:
		if b["kind"] != "normal":
			continue
		if base_center(b).distance_to(p) < radius:
			total += b["tiers"][-1][5]
			n += 1
	return total / n if n > 0 else 0.0


func tallest_near(p: Vector2, radius: float) -> float:
	var best := 0.0
	for b in buildings:
		if base_center(b).distance_to(p) < radius:
			best = maxf(best, b["tiers"][-1][5])
	return best


# ------------------------------------------------- buildings, kit, structures
func district(x: float, z: float) -> String:
	if is_mainland:
		if FAR_SHORE - x < 190.0 and absf(z) < 380.0:
			return "waterfront"
		if Vector2(x, z).distance_to(Vector2(-930.0, -60.0)) < 170.0:
			return "midtown"
		return "suburb"
	if x < 250.0 and z > -330.0 and z < 260.0:
		return "waterfront"
	if z >= 260.0 and x < 560.0:
		return "docks"
	if x > 780.0 or z < -540.0 or z > 520.0:
		return "georgian"
	var d := Vector2(x, z).distance_to(CBD_CENTER)
	if d < CBD_RADIUS:
		return "cbd"
	return "midtown"


# ------------------------------------------------------------- landmarks


func _landmarks() -> void:
	# Clock building: stone block, two clock towers crowned with domes + birds.
	_add(_building([[92, -112, 162, -40, 0, 50]], Style.SANDSTONE, Color(0.76, 0.74, 0.7), "landmark"))
	for tx: float in [94.0, 144.0]:
		_add(_building([[tx, -84, tx + 16, -68, 50, 64]], Style.SANDSTONE, Color(0.76, 0.74, 0.7), "landmark"))
		landmarks.append(["clock_crown", Transform3D(Basis(), Vector3(tx + 8, 64, -76))])
		_add(_building([[tx + 2, -82, tx + 14, -70, 64, 92]], Style.SANDSTONE, Color(0.76, 0.74, 0.7), "invisible"))
	# Shipping-line office: heavy palazzo block.
	_add(_building([[92, 6, 162, 78, 0, 38]], Style.STONE, Color(0.82, 0.8, 0.74), "landmark"))
	# Port authority: domed block with corner cupolas.
	_add(_building([[92, 100, 162, 164, 0, 34]], Style.STONE, Color(0.8, 0.78, 0.72), "landmark"))
	landmarks.append(["harbour_dome", Transform3D(Basis(), Vector3(127, 34, 132))])
	_add(_building([[115, 119, 139, 145, 34, 56]], Style.STONE, Color(0.8, 0.78, 0.72), "invisible"))
	# Dark glass wedges by the old dock entrance.
	_add(_building([[96, -214, 128, -176, 0, 30]], Style.DARK_GLASS, Color(0.15, 0.16, 0.18), "landmark"))
	_add(_building([[134, -220, 160, -180, 0, 26]], Style.DARK_GLASS, Color(0.15, 0.16, 0.18), "landmark"))
	# Radio beacon in the business district.
	landmarks.append(["beacon", Transform3D(Basis(), Vector3(CBD_CENTER.x - 40, 0, CBD_CENTER.y + 60))])
	var bx := CBD_CENTER.x - 40
	var bz := CBD_CENTER.y + 60
	_add(_building([[bx - 6, bz - 6, bx + 6, bz + 6, 0, 115]], Style.MODERN, Color(0.82, 0.8, 0.76), "invisible"))
	_add(_building([[bx - 11, bz - 11, bx + 11, bz + 11, 115, 127]], Style.MODERN, Color(0.82, 0.8, 0.76), "invisible"))
	# Sandstone cathedral on the eastern ridge.
	var cx := 900.0
	var cz := -390.0
	var sand := Color(0.64, 0.4, 0.31)
	_add(_building([[cx - 90, cz - 24, cx + 90, cz + 24, 0, 44]], Style.SANDSTONE, sand, "landmark"))
	_add(_building([[cx - 22, cz - 60, cx + 22, cz + 60, 0, 40]], Style.SANDSTONE, sand, "landmark"))
	_add(_building([[cx - 17, cz - 17, cx + 17, cz + 17, 44, 82]], Style.SANDSTONE, sand, "landmark"))
	landmarks.append(["cathedral_top", Transform3D(Basis(), Vector3(cx, 82, cz))])
	_add(_building([[cx - 17, cz - 17, cx + 17, cz + 17, 82, 103]], Style.SANDSTONE, sand, "invisible"))


## Lifts what was added to the layout since `snap` (see _snap) by dy metres:
## buildings, props, structures (their y0), anchors, set-piece collision and
## landmark models. Every block's contents are generated at street level 0
## and then lifted onto the block's terrace.
func _lift(snap: Array, dy: float) -> void:
	if absf(dy) < 0.001:
		return
	for i in range(snap[0], buildings.size()):
		var b: Dictionary = buildings[i]
		for t in b["tiers"]:
			t[4] += dy
			t[5] += dy
		if b.has("roof"):
			b["roof"] += dy
		b["base"] = float(b.get("base", 0.0)) + dy
	for i in range(snap[1], props.size()):
		var xf: Transform3D = props[i][1]
		props[i][1] = xf.translated(Vector3(0, dy, 0))
	for i in range(snap[2], structures.size()):
		structures[i]["y0"] = float(structures[i].get("y0", 0.0)) + dy
	for i in range(snap[3], anchor_lines.size()):
		anchor_lines[i] = [anchor_lines[i][0] + Vector3(0, dy, 0), anchor_lines[i][1] + Vector3(0, dy, 0)]
	for i in range(snap[4], kit_obbs.size()):
		kit_obbs[i][0] = (kit_obbs[i][0] as Transform3D).translated(Vector3(0, dy, 0))
	for i in range(snap[5], kit_hulls.size()):
		var hull: PackedVector3Array = kit_hulls[i]
		for k in hull.size():
			hull[k] += Vector3(0, dy, 0)
		kit_hulls[i] = hull
	for i in range(snap[6], landmarks.size()):
		landmarks[i][1] = (landmarks[i][1] as Transform3D).translated(Vector3(0, dy, 0))


func _split(r: Rect2, out: Array, brng: RandomNumberGenerator, min_size: float, depth: int) -> void:
	var can_x := r.size.x > min_size * 2.0
	var can_z := r.size.y > min_size * 2.0
	if depth > 3 or not (can_x or can_z) or (depth >= 1 and brng.randf() < 0.22):
		out.append(r)
		return
	var along_x := can_x and (not can_z or r.size.x > r.size.y)
	var f := brng.randf_range(0.35, 0.65)
	if along_x:
		var w := r.size.x * f
		_split(Rect2(r.position, Vector2(w, r.size.y)), out, brng, min_size, depth + 1)
		_split(Rect2(r.position + Vector2(w, 0), Vector2(r.size.x - w, r.size.y)), out, brng, min_size, depth + 1)
	else:
		var h := r.size.y * f
		_split(Rect2(r.position, Vector2(r.size.x, h)), out, brng, min_size, depth + 1)
		_split(Rect2(r.position + Vector2(0, h), Vector2(r.size.x, r.size.y - h)), out, brng, min_size, depth + 1)


## Building heights per district. Every district is swingable (most roofs
## ≥ 45 m above the street, the height a good swing needs); each has its own
## skyline. CBD: supertall core near 300 m. Midtown: a real tower district.
## Waterfront: riverside towers and hotels. Docks: chunky warehouses (and
## grain silos) mixed with loft and residential towers. Old Town (georgian):
## mansion blocks with church and civic towers above them.
func _height_for(dist: String, c: Vector2, brng: RandomNumberGenerator) -> float:
	if is_mainland and dist != "suburb":
		# Westbank is lower and leafier than the island: its towers top out
		# well under the island's, so the city's skyline stays the star.
		return _height_for_island(dist, c, brng) * 0.62
	return _height_for_island(dist, c, brng)


func _height_for_island(dist: String, c: Vector2, brng: RandomNumberGenerator) -> float:
	var r := brng.randf()
	match dist:
		"cbd":
			var d := c.distance_to(CBD_CENTER)
			var peak := 90.0 + 215.0 * exp(-pow(d / 260.0, 2.0))
			if r < 0.08:
				return brng.randf_range(34.0, 52.0)  # technical low spots
			return peak * brng.randf_range(0.72, 1.22)
		"midtown":
			return brng.randf_range(62.0, 130.0) if r < 0.6 else brng.randf_range(135.0, 215.0)
		"waterfront":
			return brng.randf_range(52.0, 112.0) if r < 0.75 else brng.randf_range(120.0, 175.0)
		"docks":
			return brng.randf_range(28.0, 44.0) if r < 0.45 else brng.randf_range(62.0, 150.0)
		"suburb":
			if r < 0.7:
				return brng.randf_range(13.0, 30.0)
			return brng.randf_range(32.0, 54.0) if r < 0.95 else brng.randf_range(58.0, 86.0)
		_:
			if r < 0.45:
				return brng.randf_range(36.0, 60.0)
			return brng.randf_range(62.0, 105.0) if r < 0.88 else brng.randf_range(110.0, 155.0)


## A building's form, from its own random stream (so the plan's draws don't
## shift): "box" (plain or podium + setbacks), "offset" (setbacks stepped to
## one side), "pencil" (slender tower), "slab" (long and thin), "twin" (two
## towers on a podium joined by a sky bridge), "cantilever" (a top block
## hanging out over a recessed body), "crown" (stepped crown), "campanile"
## (a slim tower rising off one corner), "silos" (a grain-silo row).
func _form_for(dist: String, h: float, r: Rect2, frng: RandomNumberGenerator) -> String:
	var lo := minf(r.size.x, r.size.y)
	var hi := maxf(r.size.x, r.size.y)
	var opts: Array = []  # [form, weight]
	match dist:
		"cbd":
			opts = [["pencil", 0.08], ["twin", 0.1], ["cantilever", 0.1], ["crown", 0.16], ["offset", 0.2], ["tapered", 0.12]]
		"midtown":
			opts = [["pencil", 0.12], ["twin", 0.1], ["slab", 0.1], ["cantilever", 0.14], ["crown", 0.12],
				["offset", 0.18], ["tapered", 0.1]]
		"waterfront":
			opts = [["slab", 0.18], ["pencil", 0.1], ["cantilever", 0.1], ["campanile", 0.06], ["offset", 0.16],
				["tapered", 0.1]]
		"docks":
			if h < 45.0:
				opts = [["silos", 0.24]]
			else:
				opts = [["cantilever", 0.2], ["slab", 0.15], ["twin", 0.1], ["offset", 0.15]]
		_:
			opts = [["campanile", 0.2 if h < 75.0 else 0.0], ["crown", 0.1], ["twin", 0.05], ["offset", 0.2],
				["tapered", 0.08]]
	var x := frng.randf()
	for o in opts:
		x -= float(o[1])
		if x < 0.0:
			var f: String = o[0]
			match f:
				"pencil":
					return f if h > 90.0 and lo > 26.0 else "box"
				"twin":
					return f if h > 80.0 and hi > 50.0 and lo > 24.0 else "box"
				"slab":
					return f if h > 50.0 and hi > 44.0 and lo > 26.0 else "box"
				"cantilever":
					return f if h > 50.0 and lo > 24.0 else "box"
				"crown":
					return f if h > 60.0 and lo > 24.0 else "box"
				"campanile":
					return f if lo > 22.0 else "box"
				"silos":
					return f if hi > 30.0 and lo > 14.0 else "box"
				"tapered":
					return f if h > 80.0 and lo > 28.0 else "box"
			return f
	return "box"


func _style_for(dist: String, h: float, form: String, brng: RandomNumberGenerator) -> int:
	if dist == "docks" and h < 45.0:
		return Style.WAREHOUSE
	if dist in ["georgian", "suburb"] and h < 62.0:
		var g := brng.randf()
		return Style.BRICK if g < 0.6 else (Style.SANDSTONE if g < 0.8 else Style.STONE)
	if form in ["pencil", "twin", "cantilever"] and h > 70.0:
		return [Style.GLASS, Style.DARK_GLASS, Style.MODERN][brng.randi() % 3]
	if dist == "georgian" and h < 110.0:
		return [Style.STONE, Style.DECO, Style.SANDSTONE, Style.BRICK][brng.randi() % 4]
	if h > 115.0:
		# (one draw, as before: the layout's stream doesn't shift)
		var g := brng.randf()
		return Style.GLASS if g < 0.4 else (Style.DARK_GLASS if g < 0.62 else (Style.DECO if g < 0.82 else Style.MODERN))
	if h > 65.0:
		return [Style.MODERN, Style.DECO, Style.GLASS, Style.STONE][brng.randi() % 4]
	if h > 35.0:
		return [Style.STONE, Style.BRICK, Style.MODERN, Style.DECO][brng.randi() % 4]
	return [Style.BRICK, Style.STONE, Style.SANDSTONE][brng.randi() % 3]


## Silhouettes for plain towers (one tier, 45 m+): about four in five get a
## stepped top – one setback, two setbacks, or a slimmer crown block above
## the roof – so the skyline isn't a field of flat-topped boxes. Picked from
## the lot's position (its own RNG: the layout's streams are untouched); the
## main body below ~60 % of the height never changes.
func _stepped_top(tiers: Array, h: float, c: Vector2) -> void:
	# (Not the very tallest: the penthouse wants one broad top up there.)
	if tiers.size() != 1 or h < 45.0 or h > 150.0:
		return
	var t: Array = tiers[0]
	var w := minf(float(t[2]) - float(t[0]), float(t[3]) - float(t[1]))
	if w < 14.0:
		return
	var srng := RandomNumberGenerator.new()
	srng.seed = hash(Vector2i(int(c.x * 3.0), int(c.y * 3.0))) ^ 0x57e9
	var pick := srng.randf()
	var cut := func(at: float, si: float) -> void:
		var last: Array = tiers[-1]
		# (tops stay 14 m+ across: still a roof to land on and start from)
		if float(last[2]) - float(last[0]) - si * 2.0 < 14.0 or float(last[3]) - float(last[1]) - si * 2.0 < 14.0:
			return
		var top: float = last[5]
		last[5] = at
		tiers.append([float(last[0]) + si, float(last[1]) + si, float(last[2]) - si, float(last[3]) - si, at, top])
	if pick < 0.32 or (pick < 0.52 and h <= 75.0):
		cut.call(h * srng.randf_range(0.72, 0.84), srng.randf_range(2.0, 4.5))
	elif pick < 0.52 and h > 75.0:
		cut.call(h * srng.randf_range(0.6, 0.68), srng.randf_range(2.0, 3.5))
		cut.call(h * srng.randf_range(0.82, 0.9), srng.randf_range(2.0, 3.5))
	elif pick < 0.8 and w > 21.0:
		var si := srng.randf_range(3.5, minf(w * 0.22, (w - 14.0) * 0.5))
		tiers.append([float(t[0]) + si, float(t[1]) + si, float(t[2]) - si, float(t[3]) - si, h, h + srng.randf_range(6.0, 12.0)])


func _make_building(r: Rect2, dist: String, brng: RandomNumberGenerator) -> void:
	var c := r.get_center()
	var h := _height_for(dist, c, brng)
	var frng := RandomNumberGenerator.new()
	frng.seed = hash(Vector2i(int(c.x * 8.0), int(c.y * 8.0))) ^ (seed * 7 + 3)
	var form := _form_for(dist, h, r, frng)
	if form == "silos":
		_silos(r, frng)
		return
	if form == "pencil":
		var side := clampf(minf(r.size.x, r.size.y) * 0.62, 17.0, 24.0)
		var px := frng.randf_range(r.position.x, r.end.x - side)
		var pz := frng.randf_range(r.position.y, r.end.y - side)
		r = Rect2(px, pz, side, side)
		h = minf(h * frng.randf_range(1.1, 1.25), 330.0)
	elif form == "slab":
		var thin := frng.randf_range(15.0, 19.0)
		if r.size.x > r.size.y:
			r = Rect2(r.position.x, r.get_center().y - thin * 0.5, r.size.x, thin)
		else:
			r = Rect2(r.get_center().x - thin * 0.5, r.position.y, thin, r.size.y)
	var style := _style_for(dist, h, form, brng)
	var cols: Array = STYLE_COLORS[style]
	var col: Color = cols[brng.randi() % cols.size()]
	col = col.lightened(brng.randf_range(-0.06, 0.06))
	var tiers: Array = []
	var x0 := r.position.x
	var z0 := r.position.y
	var x1 := r.end.x
	var z1 := r.end.y
	var extra: Array = []      # more buildings standing on this one (twin towers, campanile)
	var blocked: Array = []    # roof areas they take (no roof furniture there)
	if form == "twin":
		var pod := frng.randf_range(14.0, 24.0)
		tiers.append([x0, z0, x1, z1, 0.0, pod])
		var along_x := r.size.x >= r.size.y
		var L := (r.size.x if along_x else r.size.y) * 0.38
		var ins := 2.5
		var h2 := h * frng.randf_range(0.74, 0.92)
		var towers: Array = []
		if along_x:
			towers = [[x0 + ins, z0 + ins, x0 + ins + L, z1 - ins], [x1 - ins - L, z0 + ins, x1 - ins, z1 - ins]]
		else:
			towers = [[x0 + ins, z0 + ins, x1 - ins, z0 + ins + L], [x0 + ins, z1 - ins - L, x1 - ins, z1 - ins]]
		for k in 2:
			var tw: Array = towers[k]
			var th: float = h if k == 0 else h2
			var tt: Array = [[tw[0], tw[1], tw[2], tw[3], pod, th]]
			if frng.randf() < 0.5 and minf(tw[2] - tw[0], tw[3] - tw[1]) > 16.0:
				var si := frng.randf_range(2.5, 4.0)
				tt[0][5] = th - frng.randf_range(10.0, 18.0)
				tt.append([tw[0] + si, tw[1] + si, tw[2] - si, tw[3] - si, tt[0][5], th])
			var tb := _building(tt, style, col, "normal")
			tb["seed"] = frng.randf()
			extra.append(tb)
			blocked.append(Rect2(tw[0] - 2.0, tw[1] - 2.0, tw[2] - tw[0] + 4.0, tw[3] - tw[1] + 4.0))
		# Sky bridge between the towers, two thirds of the way up the lower one.
		var by := pod + (h2 - pod) * frng.randf_range(0.55, 0.75)
		var a: Array = towers[0]
		var b2: Array = towers[1]
		if along_x:
			var zc := (z0 + z1) * 0.5
			extra.append(_building([[a[2] - 1.0, zc - 3.5, b2[0] + 1.0, zc + 3.5, by, by + 5.0]], Style.DARK_GLASS,
				Color(0.22, 0.26, 0.3), "bridge"))
		else:
			var xc := (x0 + x1) * 0.5
			extra.append(_building([[xc - 3.5, a[3] - 1.0, xc + 3.5, b2[1] + 1.0, by, by + 5.0]], Style.DARK_GLASS,
				Color(0.22, 0.26, 0.3), "bridge"))
	elif form == "cantilever":
		# A recessed body with the top block hanging out over it on one or
		# two sides (a covered gap to swing under, a strong silhouette).
		var top_h := frng.randf_range(14.0, 26.0)
		var body := [x0, z0, x1, z1]
		var sides := [0, 1, 2, 3]
		for k in range(3, 0, -1):  # (seeded shuffle: Array.shuffle() uses the global RNG)
			var j := frng.randi_range(0, k)
			var tmp: int = sides[k]
			sides[k] = sides[j]
			sides[j] = tmp
		for k in 1 + int(frng.randf() < 0.5):
			var o := frng.randf_range(3.5, 6.5)
			match sides[k]:
				0: body[0] += o
				1: body[1] += o
				2: body[2] -= o
				3: body[3] -= o
		var y_top := maxf(h - top_h, 24.0)
		tiers.append([body[0], body[1], body[2], body[3], 0.0, y_top])
		tiers.append([x0, z0, x1, z1, y_top, h])
	elif form == "tapered":
		# A ziggurat: the tower narrows in 5–8 bands all the way up (a
		# skyline silhouette, and every band's ledge is a place to land).
		var n := frng.randi_range(5, 8)
		var band := h / n
		var si := clampf(minf(r.size.x, r.size.y) * 0.3 / n, 1.2, 3.2)
		var y := 0.0
		for k in n:
			tiers.append([x0, z0, x1, z1, y, h if k == n - 1 else y + band])
			y += band
			x0 += si
			z0 += si
			x1 -= si
			z1 -= si
	elif h > 70.0 and min(r.size.x, r.size.y) > 30.0 and (form == "offset" or brng.randf() < 0.7):
		# Podium + slimmer tower, then setbacks (stepped to one side for "offset").
		var dx := 0.0
		var dz := 0.0
		if form == "offset":
			dx = -1.0 if frng.randf() < 0.5 else 1.0
			dz = -1.0 if frng.randf() < 0.5 else 1.0
		var pod := brng.randf_range(12.0, 22.0)
		tiers.append([x0, z0, x1, z1, 0.0, pod])
		var inset := brng.randf_range(3.0, minf(r.size.x, r.size.y) * 0.22)
		x0 += inset * (1.0 + dx); z0 += inset * (1.0 + dz); x1 -= inset * (1.0 - dx); z1 -= inset * (1.0 - dz)
		var y := pod
		var steps := 1 + int(h > 110.0) + int(brng.randf() < 0.4)
		for s_ in steps:
			var top := y + (h - y) * (0.62 if s_ < steps - 1 else 1.0)
			if s_ == steps - 1:
				top = h
			tiers.append([x0, z0, x1, z1, y, top])
			y = top
			var si := brng.randf_range(2.5, 5.0)
			if x1 - x0 - si * 2.0 < 10.0 or z1 - z0 - si * 2.0 < 10.0:
				break
			x0 += si * (1.0 + dx); z0 += si * (1.0 + dz); x1 -= si * (1.0 - dx); z1 -= si * (1.0 - dz)
		if tiers[-1][5] < h:
			tiers[-1][5] = h
	else:
		tiers.append([x0, z0, x1, z1, 0.0, h])
		if form != "crown" and form != "campanile" and h > 40.0 and brng.randf() < 0.35 \
				and min(r.size.x, r.size.y) > 22.0:
			var si := brng.randf_range(3.0, 6.0)
			var top := h + brng.randf_range(6.0, 14.0)
			tiers.append([x0 + si, z0 + si, x1 - si, z1 - si, h, top])
	if form == "crown":
		# Replace the last tier's top with 3–5 stepped setbacks (deco crown).
		var last: Array = tiers[-1]
		var n := frng.randi_range(3, 5)
		var step_h := frng.randf_range(3.5, 5.5)
		var bottom: float = float(last[5]) - step_h * n
		if bottom > float(last[4]) + 8.0:
			last[5] = bottom
			var t := last.duplicate()
			for k in n:
				var si := frng.randf_range(1.8, 3.0)
				if float(t[2]) - float(t[0]) - si * 2.0 < 6.0 or float(t[3]) - float(t[1]) - si * 2.0 < 6.0:
					break
				t = [float(t[0]) + si, float(t[1]) + si, float(t[2]) - si, float(t[3]) - si, float(t[5]),
					float(t[5]) + step_h]
				tiers.append(t)
	if form == "campanile":
		# A slim bell/clock tower rising off one corner of the roof.
		var side := frng.randf_range(9.0, 12.0)
		var cx := x0 if frng.randf() < 0.5 else x1 - side
		var cz := z0 if frng.randf() < 0.5 else z1 - side
		var top: float = tiers[-1][5]
		var th := maxf(top + frng.randf_range(28.0, 48.0), frng.randf_range(78.0, 105.0))
		var tt: Array = [[cx, cz, cx + side, cz + side, top, th - 7.0],
			[cx + 1.6, cz + 1.6, cx + side - 1.6, cz + side - 1.6, th - 7.0, th]]
		var tb := _building(tt, Style.SANDSTONE if style == Style.BRICK else style, col.lightened(0.05), "normal")
		tb["seed"] = frng.randf()
		extra.append(tb)
		blocked.append(Rect2(cx - 3.0, cz - 3.0, side + 6.0, side + 6.0))
		# A slim spire on top: the highest anchor in its neighbourhood.
		var sp := 1.2
		var mx := cx + side * 0.5
		var mz := cz + side * 0.5
		extra.append(_building([[mx - sp, mz - sp, mx + sp, mz + sp, th + 0.5, th + frng.randf_range(9.0, 16.0)]],
			style, col.lightened(0.15), "spire"))
	var box_tiers := tiers.duplicate(true)
	_stepped_top(tiers, h, c)
	var b := _building(tiers, style, col, "normal")
	b["seed"] = brng.randf()
	var shape := _shape_for(form, style, h, tiers, c)
	if not shape.is_empty():
		b["shape"] = shape
	if not blocked.is_empty():
		b["roof_blocked"] = true  # (no rooftop spawns: towers stand on it)
	_add(b)
	for e in extra:
		_add(e)
	# Roof kit on a shaped plan keeps to the square in its middle (nothing
	# hangs over a cut or rounded corner).
	var dress := tiers if shape.is_empty() else _shape_inset(tiers, shape)
	if tiers.size() == box_tiers.size() and shape.is_empty():
		_roof_furniture(b, tiers, style, h, col, brng, blocked)
	else:
		# A stepped top: dress the real roof, but advance the layout's random
		# streams exactly as the plain box would have (a dry run, thrown
		# away), so every building after this one stays where it was.
		var b_state := brng.state
		var r_state := rng.state
		var sizes := [props.size(), buildings.size(), _plant_candidates.size(), reserved.size()]
		var dry := b.duplicate()
		dry["tiers"] = box_tiers
		_roof_furniture(dry, box_tiers, style, h, col, brng, blocked)
		props.resize(sizes[0])
		buildings.resize(sizes[1])
		_plant_candidates.resize(sizes[2])
		reserved.resize(sizes[3])
		var b_after := brng.state
		var r_after := rng.state
		var real := RandomNumberGenerator.new()
		real.state = b_state
		rng.state = r_state
		_roof_furniture(b, dress, style, h, col, real, blocked)
		brng.state = b_after
		rng.state = r_after
	for e in extra:
		if e["kind"] == "normal" and form == "twin":
			_roof_furniture(e, e["tiers"], style, float(e["tiers"][-1][5]), col, frng, [])


## Share of each shape's weight actually used (about half the towers end up
## shaped: more and the expert bot runs out of corner anchors).
const SHAPE_SHARE := 0.55

## Plan shapes, so the city isn't a field of rectangles: chamfered corners
## (octagonal towers), rounded corners, round drums / stadium plans, a
## flatiron prow, L and stepped plans (notched corners), bullnose fronts.
## Glass towers lean to curves, masonry to chamfered corner blocks and
## notches. Own position-hashed RNG: the layout's streams are untouched.
## Returns {} (a plain box) or {"c": [[kind, size], ×4], "segs": n}.
func _shape_for(form: String, style: int, h: float, tiers: Array, c: Vector2) -> Dictionary:
	if form in ["silos", "campanile", "twin"] or style == Style.WAREHOUSE or h < 20.0:
		return {}
	if OS.has_environment("NO_SHAPES"):
		return {}
	if c.distance_to(AdScreens.DISTRICT) < AdScreens.DISTRICT_R + 25.0:
		return {}  # Lumen Circus: flat facades carry the screens
	var t: Array = tiers[0]
	var w := float(t[2]) - float(t[0])
	var d := float(t[3]) - float(t[1])
	var short := minf(w, d)
	var top: Array = tiers[-1]
	if short < 16.0 or minf(float(top[2]) - float(top[0]), float(top[3]) - float(top[1])) < 14.0:
		return {}
	var r := RandomNumberGenerator.new()
	r.seed = hash(Vector2i(int(c.x * 5.0), int(c.y * 5.0))) ^ 0x3a9d
	var glassy := style in [Style.GLASS, Style.DARK_GLASS, Style.MODERN]
	var opts: Array
	if glassy:
		opts = [["drum", 0.2 if maxf(w, d) / short < 1.7 and h > 45.0 else 0.0], ["rounded", 0.24], ["chamfer", 0.16],
			["prow", 0.1], ["bullnose", 0.1], ["notch", 0.08]]
	elif style == Style.DECO:
		opts = [["chamfer", 0.3], ["rounded", 0.14], ["notch", 0.16], ["prow", 0.12], ["bullnose", 0.1]]
	else:
		opts = [["chamfer", 0.26], ["notch", 0.2], ["prow", 0.1], ["rounded", 0.08], ["bullnose", 0.06]]
	var x := r.randf()
	var pick := ""
	for o in opts:
		x -= float(o[1]) * SHAPE_SHARE
		if x < 0.0:
			pick = o[0]
			break
	if pick == "":
		return {}
	var cs := [[0, 0.0], [0, 0.0], [0, 0.0], [0, 0.0]]
	var k0 := r.randi() % 4
	match pick:
		"chamfer":
			var f := r.randf_range(0.16, 0.28)
			for k in 4:
				cs[k] = [BuildingMesher.SHAPE_CHAMFER, f]
		"rounded":
			var f := r.randf_range(0.2, 0.34)
			for k in 4:
				cs[k] = [BuildingMesher.SHAPE_ROUND, f]
		"drum":
			for k in 4:
				cs[k] = [BuildingMesher.SHAPE_ROUND, 0.5]
		"prow":
			cs[k0] = [BuildingMesher.SHAPE_CHAMFER, r.randf_range(0.42, 0.6)]
			if r.randf() < 0.5:
				cs[(k0 + 2) % 4] = [BuildingMesher.SHAPE_CHAMFER, 0.12]
		"bullnose":
			cs[k0] = [BuildingMesher.SHAPE_ROUND, 0.5]
			cs[(k0 + 1) % 4] = [BuildingMesher.SHAPE_ROUND, 0.5]
		"notch":
			cs[k0] = [BuildingMesher.SHAPE_NOTCH, r.randf_range(0.3, 0.42)]
			if r.randf() < 0.4:
				cs[(k0 + 2) % 4] = [BuildingMesher.SHAPE_NOTCH, r.randf_range(0.25, 0.35)]
	var segs := 0
	for q in cs:
		if int(q[0]) == BuildingMesher.SHAPE_ROUND:
			segs += BuildingMesher.ARC_SEGS
	# Notches must leave a roof on every tier (upper tiers are smaller).
	if pick == "notch":
		for tt in tiers:
			var s2 := minf(float(tt[2]) - float(tt[0]), float(tt[3]) - float(tt[1]))
			if s2 * (1.0 - 0.42) < 9.0:
				return {}
	return {"c": cs, "segs": segs, "kind": pick}


## How far in from a shaped tier's bounding rect its clear square starts.
static func shape_margin(shape: Dictionary, t: Array) -> float:
	var short := minf(float(t[2]) - float(t[0]), float(t[3]) - float(t[1]))
	var m := 0.0
	for q in shape["c"]:
		var k := 0.3 if int(q[0]) == BuildingMesher.SHAPE_ROUND else 0.55
		if int(q[1] * 100.0) >= 50 and int(q[0]) == BuildingMesher.SHAPE_ROUND:
			k = 0.3  # (a drum: the square inside a circle is ~0.29 of the diameter in)
		m = maxf(m, float(q[1]) * short * k)
	return minf(m, short * 0.3)


## The tiers with the top one shrunk to the clear square inside its shape.
func _shape_inset(tiers: Array, shape: Dictionary) -> Array:
	var out := tiers.duplicate(true)
	var t: Array = out[-1]
	var m := shape_margin(shape, t)
	t[0] = float(t[0]) + m
	t[1] = float(t[1]) + m
	t[2] = float(t[2]) - m
	t[3] = float(t[3]) - m
	return out


## Grain silos (docks): a row of tall concrete bins under a headhouse.
func _silos(r: Rect2, frng: RandomNumberGenerator) -> void:
	var along_x := r.size.x >= r.size.y
	var L := r.size.x if along_x else r.size.y
	var D := minf(r.size.x if not along_x else r.size.y, 13.0)
	var n := clampi(int(L / (D + 0.8)), 2, 6)
	var w := (L - 0.8 * (n - 1)) / n
	var h := frng.randf_range(46.0, 62.0)
	var concrete := Color(0.72, 0.7, 0.65).lightened(frng.randf_range(-0.08, 0.04))
	var c := r.get_center()
	for i in n:
		var a := (r.position.x if along_x else r.position.y) + i * (w + 0.8)
		var t: Array = [a, c.y - D * 0.5, a + w, c.y + D * 0.5, -6.0, h] if along_x \
			else [c.x - D * 0.5, a, c.x + D * 0.5, a + w, -6.0, h]  # (footed below the street: slopes)
		var bin := _building([t], Style.MODERN, concrete, "plain")
		bin["lift_at"] = c
		_add(bin)
	# Headhouse over the bins (solid, flat roof you can land on), a gallery
	# on its long side.
	var hh := frng.randf_range(7.0, 11.0)
	var hl := L * frng.randf_range(0.35, 0.6)
	var h0 := (r.position.x if along_x else r.position.y) + frng.randf_range(0.0, L - hl)
	var ht: Array = [h0, c.y - D * 0.5 - 0.5, h0 + hl, c.y + D * 0.5 + 0.5, h, h + hh] if along_x \
		else [c.x - D * 0.5 - 0.5, h0, c.x + D * 0.5 + 0.5, h0 + hl, h, h + hh]
	var head := _building([ht], Style.WAREHOUSE, Color(0.5, 0.27, 0.2), "plain")
	head["lift_at"] = c
	_add(head)
	# Conveyor gallery from the headhouse down the length of the row.
	var gt: Array = [r.position.x, c.y - 1.6, r.end.x, c.y + 1.6, h, h + 3.0] if along_x \
		else [c.x - 1.6, r.position.y, c.x + 1.6, r.end.y, h, h + 3.0]
	var gal := _building([gt], Style.MODERN, Color(0.45, 0.46, 0.47), "plain")
	gal["lift_at"] = c
	_add(gal)


func _roof_furniture(b: Dictionary, tiers: Array, style: int, h: float, col: Color, brng: RandomNumberGenerator,
		blocked: Array) -> void:
	var free := func(x: float, z: float) -> bool:
		for q in blocked:
			if (q as Rect2).has_point(Vector2(x, z)):
				return false
		return true
	var top_t: Array = tiers[-1]
	var rx: float = (top_t[0] + top_t[2]) * 0.5
	var rz: float = (top_t[1] + top_t[3]) * 0.5
	var ry: float = BuildingMesher.roof_y(b)  # the drawn roof (over the cornice), not the wall top
	var tw: float = top_t[2] - top_t[0]
	var td: float = top_t[3] - top_t[1]
	# Stair / lift housing tucked into a corner (solid: you land on it). Own
	# random stream, so adding it didn't reshuffle the rest of the city.
	var hrng := RandomNumberGenerator.new()
	hrng.seed = hash(Vector3i(int(rx * 10.0), int(rz * 10.0), int(top_t[5]))) ^ seed
	if tw > 15.0 and td > 15.0 and hrng.randf() < 0.65:
		var sx := 1.0 if hrng.randf() < 0.5 else -1.0
		var sz := 1.0 if hrng.randf() < 0.5 else -1.0
		var hx := rx + sx * (tw * 0.5 - 3.6)
		var hz := rz + sz * (td * 0.5 - 4.0)
		if free.call(hx, hz):
			var yaw := 0.0 if sz < 0.0 else PI  # door faces into the roof
			props.append(["roof_hut", Transform3D(Basis(Vector3.UP, yaw), Vector3(hx, ry, hz))])
			buildings.append({"tiers": [[hx - 1.7, hz - 2.1, hx + 1.7, hz + 2.1, ry, ry + 3.1]], "style": Style.MODERN,
				"color": Color.WHITE, "kind": "structure", "seed": 0.0})
	# Mechanical plant on office towers: a row of cooling towers off to one
	# side of the roof (own random stream: nothing else reshuffles; solid for
	# people only, see CityWorld.HUMAN_LAYER).
	var prng := RandomNumberGenerator.new()
	prng.seed = hash(Vector3i(int(rx * 7.0), int(rz * 7.0), int(top_t[5] * 3.0))) ^ (seed * 5 + 1)
	if style in [Style.GLASS, Style.DARK_GLASS, Style.MODERN, Style.DECO, Style.STONE] and h > 50.0 \
			and tw > 18.0 and td > 18.0 and prng.randf() < 0.75:
		var along_x := tw >= td
		var n_ct := 2 + int(maxf(tw, td) > 30.0)
		var side := 1.0 if prng.randf() < 0.5 else -1.0
		var ox := rx + (0.0 if along_x else side * (tw * 0.5 - 4.5))
		var oz := rz + (side * (td * 0.5 - 4.0) if along_x else 0.0)
		for k in n_ct:
			var off := (float(k) - (n_ct - 1) * 0.5) * 4.4
			var cx := ox + (off if along_x else 0.0)
			var cz := oz + (0.0 if along_x else off)
			if free.call(cx, cz) and Vector2(cx, cz).distance_to(Vector2(rx, rz)) > 3.0:
				# (Placed at the end of generate(): appending mid-list would
				# shift which props a density setting keeps.)
				_plant_candidates.append([b, Vector2(cx, cz), 0.0 if along_x else PI * 0.5])
	if (style == Style.BRICK or style == Style.STONE or style == Style.SANDSTONE) and h < 80.0 and brng.randf() < 0.55:
		var wx := rx + brng.randf_range(-tw, tw) * 0.25
		var wz := rz + brng.randf_range(-td, td) * 0.25
		if free.call(wx, wz):
			props.append(["water_tower", Transform3D(Basis(Vector3.UP, brng.randf_range(0, TAU)), Vector3(wx, ry, wz))])
	if h > 235.0 and tw > 16.0 and td > 16.0:
		# Supertall crown: a slim spire, the highest anchor in the city.
		var sp := brng.randf_range(2.5, 3.5)
		_add(_building([[rx - sp, rz - sp, rx + sp, rz + sp, ry, ry + brng.randf_range(28.0, 48.0)]], style,
			col.lightened(0.15), "spire"))
	elif h > 100.0 and brng.randf() < 0.55 and free.call(rx, rz):
		props.append(["antenna", Transform3D(Basis(), Vector3(rx, ry, rz))])
	if h > 14.0 and h < 75.0 and tiers.size() == 1 and minf(tw, td) > 16.0 and blocked.is_empty() \
			and brng.randf() < 0.16:
		_billboard(tiers[0], ry, brng)
	for i in brng.randi_range(0, 3):
		if tw > 10.0 and td > 10.0:
			var ax := rx + brng.randf_range(-tw, tw) * 0.32
			var az := rz + brng.randf_range(-td, td) * 0.32
			if free.call(ax, az):
				props.append(["ac_unit", Transform3D(Basis(Vector3.UP, (brng.randi() % 2) * PI * 0.5),
					Vector3(ax, ry, az))])


func _building(tiers: Array, style: int, col: Color, kind: String) -> Dictionary:
	return {"tiers": tiers, "style": style, "color": col, "kind": kind, "seed": rng.randf()}


func _add(b: Dictionary) -> void:
	buildings.append(b)
	if b["kind"] == "landmark" or b["kind"] == "invisible":
		var t: Array = b["tiers"][0]
		reserved.append(Rect2(t[0], t[1], t[2] - t[0], t[3] - t[1]))


# ------------------------------------------------------------ structures


## Collision-only box (the visuals come from `structures` specs).
func _box(x0: float, z0: float, x1: float, z1: float, y0: float, y1: float) -> void:
	buildings.append({"tiers": [[minf(x0, x1), minf(z0, z1), maxf(x0, x1), maxf(z0, z1), y0, y1]],
		"style": Style.MODERN, "color": Color.WHITE, "kind": "structure", "seed": 0.0})


func _anchor(a: Vector3, b: Vector3) -> void:
	anchor_lines.append([a, b])


# ------------------------------------------------------------- set-piece kit


## A kit: one structure spec the mesher draws ("solids", "beams", "prisms")
## whose collision is made from the very same list.
## While set, kit beams collide but take no web (world layer only, like the
## street): the City Loop viaduct right over a boulevard would otherwise be
## every street launch's anchor (a short, low swing).
var kit_solid_only := false
var kit_obbs_solid: Array = []


func _kit(name: String) -> Dictionary:
	var k := {"type": "kit", "name": name, "solids": [], "beams": [], "prisms": []}
	structures.append(k)
	return k


func _ksolid(k: Dictionary, x0: float, z0: float, x1: float, z1: float, y0: float, y1: float, col: Color,
		collide := true) -> void:
	k["solids"].append([minf(x0, x1), minf(z0, z1), maxf(x0, x1), maxf(z0, z1), y0, y1, col])
	if collide:
		_box(x0, z0, x1, z1, y0, y1)


## Beam of cross-section w×h from a to b (BuildingMesher.beam's frame).
func _kbeam(k: Dictionary, a: Vector3, b: Vector3, w: float, h: float, col: Color, collide := true) -> void:
	k["beams"].append([a, b, w, h, col])
	if collide and a.distance_to(b) > 0.01:
		var ob := [Transform3D(BuildingMesher.beam_basis(a, b), (a + b) * 0.5), Vector3(w, h, a.distance_to(b))]
		(kit_obbs_solid if kit_solid_only else kit_obbs).append(ob)


## Vertical prism over a convex polygon (x, z) from y0 to y1.
func _kprism(k: Dictionary, pts: PackedVector2Array, y0: float, y1: float, col: Color) -> void:
	k["prisms"].append([pts, y0, y1, col])
	var hull := PackedVector3Array()
	for p in pts:
		hull.append(Vector3(p.x, y0, p.y))
		hull.append(Vector3(p.x, y1, p.y))
	kit_hulls.append(hull)


## Container cranes on the west quay of a dock basin, booms out over the water.
func _quay_cranes(basin: Rect2, brng: RandomNumberGenerator) -> void:
	var n := 2 if basin.size.y > 72.0 else 1
	var reach := minf(46.0, basin.size.x - 6.0)
	for i in n:
		var qx := basin.position.x
		var z := basin.position.y + basin.size.y * (i + 1.0) / (n + 1.0) + brng.randf_range(-4.0, 4.0)
		var top := 34.0
		for lx: float in [qx - 3.0, qx + 13.0]:
			for lz: float in [z - 6.0, z + 6.0]:
				_box(lx - 0.8, lz - 0.8, lx + 0.8, lz + 0.8, -2.0, top)
		for lz: float in [z - 6.0, z + 6.0]:
			_box(qx - 3.8, lz - 0.9, qx + 13.8, lz + 0.9, top - 4.0, top)
		_box(qx - 11.2, z - 2.0, qx + reach + 0.2, z + 2.0, top - 0.2, top + 3.0)
		_box(qx + 3.5, z - 1.0, qx + 5.5, z + 1.0, top + 3.0, top + 22.0)
		for lz: float in [z - 6.0, z + 6.0]:
			_box(qx - 3.8, lz - 0.9, qx + 13.8, lz + 0.9, 7.0, 8.4)  # lower portal beams
		for lx: float in [qx - 3.0, qx + 13.0]:  # diagonal leg braces (BuildingMesher._quay_crane)
			for e: Array in [[Vector3(lx, 4.0, z - 6.0), Vector3(lx, top - 4.0, z + 6.0)],
					[Vector3(lx, 4.0, z + 6.0), Vector3(lx, top - 4.0, z - 6.0)]]:
				kit_obbs.append([Transform3D(BuildingMesher.beam_basis(e[0], e[1]), (e[0] + e[1]) * 0.5),
					Vector3(0.4, 0.4, (e[0] as Vector3).distance_to(e[1]))])
		_box(qx - 11.0, z - 2.6, qx - 3.0, z + 2.6, top + 3.0, top + 7.0)  # machinery house
		var tx := qx + reach * 0.6
		_box(tx - 1.5, z - 2.0, tx + 1.5, z + 2.0, top - 1.0, top)  # trolley
		_box(tx - 6.0, z - 1.3, tx + 6.0, z + 1.3, 11.4, 14.0)  # container on the spreader
		_anchor(Vector3(qx + 4.0, top - 0.3, z), Vector3(qx + reach - 1.0, top - 0.3, z))
		structures.append({"type": "quay_crane", "x": qx, "z": z, "top": top, "reach": reach,
			"color": [Color(0.16, 0.36, 0.58), Color(0.78, 0.2, 0.14), Color(0.92, 0.68, 0.12)][brng.randi() % 3]})


## A rooftop billboard on one roof edge: a low, grappleable panel on legs.
func _billboard(t: Array, roof: float, brng: RandomNumberGenerator) -> void:
	var side := brng.randi() % 4
	var along_x := side < 2
	var len := minf((t[2] - t[0]) if along_x else (t[3] - t[1]), 18.0) - 4.0
	var cx: float = (t[0] + t[2]) * 0.5
	var cz: float = (t[1] + t[3]) * 0.5
	var y0: float = roof + 2.6
	var y1 := y0 + brng.randf_range(5.5, 7.5)
	var r: Array
	match side:
		0: r = [cx - len * 0.5, t[1] + 1.0, cx + len * 0.5, t[1] + 1.6]
		1: r = [cx - len * 0.5, t[3] - 1.6, cx + len * 0.5, t[3] - 1.0]
		2: r = [t[0] + 1.0, cz - len * 0.5, t[0] + 1.6, cz + len * 0.5]
		_: r = [t[2] - 1.6, cz - len * 0.5, t[2] - 1.0, cz + len * 0.5]
	var cols := [Color(0.95, 0.75, 0.15), Color(0.85, 0.2, 0.18), Color(0.15, 0.6, 0.62), Color(0.95, 0.95, 0.92),
		Color(0.25, 0.32, 0.75), Color(0.9, 0.45, 0.6)]
	var b := _building([[r[0], r[1], r[2], r[3], y0, y1]], Style.MODERN, cols[brng.randi() % cols.size()], "sign")
	b["roof"] = roof
	b["seed"] = brng.randf()
	b["face"] = [Vector2(0, -1), Vector2(0, 1), Vector2(-1, 0), Vector2(1, 0)][side]  # outward (the advert side)
	_add(b)


func _tower_crane(lot: Rect2, site_top: float, brng: RandomNumberGenerator) -> void:
	var jib := 52.0
	var counter := 16.0
	var best := {}
	var best_obst := INF
	var corners := [lot.position + Vector2(2.5, 2.5), Vector2(lot.end.x - 2.5, lot.position.y + 2.5),
		lot.end - Vector2(2.5, 2.5), Vector2(lot.position.x + 2.5, lot.end.y - 2.5)]
	for m in corners:
		for d in [Vector2(1, 0), Vector2(-1, 0), Vector2(0, 1), Vector2(0, -1)]:
			# Jib pointing out of the lot (over the street), not back over the frame.
			if (m + d * 10.0).distance_to(lot.get_center()) < m.distance_to(lot.get_center()):
				continue
			var obst := _max_height_along(m - d * counter, m + d * jib, 4.0)
			obst += brng.randf() * 4.0
			if obst < best_obst:
				best_obst = obst
				best = {"m": m, "d": d}
	if best.is_empty():
		return
	var mh := maxf(best_obst + 12.0, site_top + 30.0)
	if mh > 235.0:
		return
	var m: Vector2 = best["m"]
	var d: Vector2 = best["d"]
	var tip := m + d * jib
	var back := m - d * counter
	_box(m.x - 3.0, m.y - 3.0, m.x + 3.0, m.y + 3.0, 0.0, 1.2)  # concrete base
	_box(m.x - 1.6, m.y - 1.6, m.x + 1.6, m.y + 1.6, 1.2, mh)  # lattice mast (chords included)
	_box(m.x - 1.8, m.y - 1.8, m.x + 1.8, m.y + 1.8, mh, mh + 1.2)  # slewing unit
	var side := Vector2(-d.y, d.x)
	# Collide with the three longitudinal chords, not an invisible cuboid
	# spanning the triangular girder. Thin diagonal braces remain decorative.
	for span in [[tip, 1.0, 2.2], [back, 1.5, 1.8]]:
		for chord: Vector2 in [Vector2(-float(span[1]), 0), Vector2(float(span[1]), 0), Vector2(0, float(span[2]))]:
			var a := m + side * chord.x
			var b: Vector2 = span[0] + side * chord.x
			var extent := side.abs() * 0.2
			_box(minf(a.x, b.x) - extent.x, minf(a.y, b.y) - extent.y,
				maxf(a.x, b.x) + extent.x, maxf(a.y, b.y) + extent.y, mh + 1.0 + chord.y, mh + 1.4 + chord.y)
	var weight := back + d * 2.0
	_box(minf(weight.x, back.x) - 1.8 * absf(side.x) - 0.1, minf(weight.y, back.y) - 1.8 * absf(side.y) - 0.1,
		maxf(weight.x, back.x) + 1.8 * absf(side.x) + 0.1, maxf(weight.y, back.y) + 1.8 * absf(side.y) + 0.1, mh - 2.6, mh + 1.2)
	_box(m.x - 1.0, m.y - 1.0, m.x + 1.0, m.y + 1.0, mh + 3.4, mh + 13.0)
	_anchor(Vector3(m.x + d.x * 4.0, mh + 0.9, m.y + d.y * 4.0), Vector3(tip.x, mh + 0.9, tip.y))
	_anchor(Vector3(m.x - d.x * 3.0, mh + 0.9, m.y - d.y * 3.0), Vector3(back.x + d.x * 4.0, mh + 0.9, back.y + d.y * 4.0))
	var trolley := brng.randf_range(0.35, 0.85)
	var hook := brng.randf_range(0.25, 0.6)
	# Trolley, hook block and its load of beams (BuildingMesher._tower_crane).
	var tr := m + d * jib * trolley
	_box(tr.x - 0.8, tr.y - 0.8, tr.x + 0.8, tr.y + 0.8, mh + 0.7, mh + 1.2)
	var hook_y := lerpf(8.0, mh - 6.0, hook)
	_box(tr.x - 0.5, tr.y - 0.5, tr.x + 0.5, tr.y + 0.5, hook_y + 0.4, hook_y + 1.4)
	var load_a := tr - d * 3.2 - side * 0.7
	var load_b := tr + d * 3.2 + side * 0.7
	_box(load_a.x, load_a.y, load_b.x, load_b.y, hook_y - 0.75, hook_y - 0.25)
	structures.append({"type": "tower_crane", "x": m.x, "z": m.y, "h": mh, "dir": d, "jib": jib, "counter": counter,
		"trolley": trolley, "hook": hook})


## Suspension bridge from the waterfront to the far shore: two red towers,
## sagging main cables (anchor lines) and a deck to land on.
func _bridge() -> void:
	var zc := BRIDGE_Z
	var deck := BRIDGE_DECK
	var top := BRIDGE_TOWER_TOP
	var x_east := 56.0
	var x_west := FAR_SHORE + 14.0
	# The deck runs on over the west anchorage to meet the approach viaduct
	# (which starts at x_west - 16), and a little past the east landing.
	_box(x_west - 16.5, zc - 10.0, x_east + 2.0, zc + 10.0, deck - 2.0, deck)
	for sz: float in [-1.0, 1.0]:
		_box(x_west - 16.5, zc + sz * 10.0, x_east, zc + sz * 8.8, deck - 2.4, deck + 0.4)  # side girders
	for tx: float in BRIDGE_TOWERS:
		for sz: float in [-1.0, 1.0]:
			_box(tx - 3.0, zc + sz * 15.0, tx + 3.0, zc + sz * 9.5, -2.0, top)
		for sz: float in [-1.0, 1.0]:
			_box(tx - 3.5, zc + sz * 15.5, tx + 3.5, zc + sz * 9.0, top, top + 2.5)  # tower caps
		_box(tx - 5.0, zc - 18.0, tx + 5.0, zc + 18.0, -3.0, 1.0)  # footing in the river
		for yy in [[deck - 6.0, deck - 2.0], [88.0, 92.0], [top - 6.0, top - 2.0]]:
			_box(tx - 2.5, zc - 9.5, tx + 2.5, zc + 9.5, yy[0], yy[1])
			_anchor(Vector3(tx, yy[0] - 0.1, zc - 9.0), Vector3(tx, yy[0] - 0.1, zc + 9.0))
	# Cable anchor housings flank a genuinely open roadway.
	for sz: float in [-1.0, 1.0]:
		_add(_building([[x_east - 2.0, minf(zc + sz * 10.5, zc + sz * 15.0), x_east + 14.0,
			maxf(zc + sz * 10.5, zc + sz * 15.0), -2.0, deck + 6.0]], Style.STONE,
			Color(0.5, 0.47, 0.42), "plain"))
	CityInfrastructure.bridge_landing(self)
	# West anchorage: the roadway runs over it onto the approach viaduct; the
	# cables go down into stone housings either side.
	_add(_building([[x_west - 16.0, zc - 10.5, x_west + 2.0, zc + 10.5, -2.0, deck - 2.0]], Style.STONE,
		Color(0.62, 0.58, 0.52), "plain"))
	for sz: float in [-1.0, 1.0]:
		_add(_building([[x_west - 16.0, minf(zc + sz * 10.5, zc + sz * 15.0), x_west + 2.0,
			maxf(zc + sz * 10.5, zc + sz * 15.0), -2.0, deck + 3.5]], Style.STONE, Color(0.62, 0.58, 0.52), "plain"))
	_bridge_approach(x_west - 16.0, zc, deck)
	# Lamps along both sides of the deck (lit at night like the streets').
	var lx := x_east - 12.0
	while lx > x_west:
		for sz: float in [-1.0, 1.0]:
			props.append(["streetlight", Transform3D(Basis(Vector3.UP, 0.0 if sz > 0.0 else PI),
				Vector3(lx, deck, zc + sz * 8.6))])
		lx -= 36.0
	var cables: Array = []
	for sz: float in [-1.0, 1.0]:
		var pts := PackedVector3Array()
		var z := zc + sz * 12.25
		var ta: float = BRIDGE_TOWERS[0]
		var tb: float = BRIDGE_TOWERS[1]
		var sag := deck + 5.0
		# East side span: anchorage → tower A (slight sag).
		for i in 6:
			var u := i / 6.0
			pts.append(Vector3(lerpf(x_east + 4.0, ta, u), lerpf(deck + 5.0, top - 1.0, u) - sin(u * PI) * 5.0, z))
		for i in 15:
			var u := i / 14.0
			var x := lerpf(ta, tb, u)
			var k := (u - 0.5) * 2.0
			pts.append(Vector3(x, sag + (top - 1.0 - sag) * k * k, z))
		for i in range(1, 7):
			var u := i / 6.0
			pts.append(Vector3(lerpf(tb, x_west - 8.0, u), lerpf(top - 1.0, deck + 3.0, u) - sin(u * PI) * 5.0, z))
		cables.append(pts)
		for i in pts.size() - 1:
			if pts[i].y > deck + 9.0 or pts[i + 1].y > deck + 9.0:
				_anchor(pts[i] + Vector3.DOWN * 0.6, pts[i + 1] + Vector3.DOWN * 0.6)
	structures.append({"type": "bridge", "z": zc, "deck": deck, "top": top, "towers": BRIDGE_TOWERS,
		"x_east": x_east, "x_west": x_west, "cables": cables})


# ------------------------------------------------------- elevated & bridges
## Road height on the bridge's approach (west anchorage → Westbank Hill).
static func approach_y(x: float) -> float:
	var x0 := FAR_SHORE - 2.0
	var y1 := CityTerrain.mainland_design(APPROACH_END, BRIDGE_Z) + CityTerrain.KERB
	var t := clampf((x0 - x) / (x0 - APPROACH_END), 0.0, 1.0)
	return lerpf(BRIDGE_DECK, y1, t * t * (3.0 - 2.0 * t))


## The bridge's approach viaduct on the mainland: from the west anchorage
## (x0, at deck height) gently down onto Westbank Hill at APPROACH_END, on
## twin columns every 40 m, with parapets and lane markings.
func _bridge_approach(x0: float, zc: float, deck: float) -> void:
	var k := _kit("bridge_approach")
	var x1 := APPROACH_END
	var yf := func(x: float) -> float: return approach_y(x)
	var conc := Color(0.6, 0.59, 0.56)
	var n := ceili((x0 - x1) / 18.0)
	for i in n:
		var xa := lerpf(x0, x1, float(i) / n)
		var xb := lerpf(x0, x1, float(i + 1) / n)
		var A := Vector3(xa + 0.2, float(yf.call(xa)), zc)
		var B := Vector3(xb - 0.2, float(yf.call(xb)), zc)
		_kbeam(k, A + Vector3.DOWN * 0.8, B + Vector3.DOWN * 0.8, 20.0, 1.6, Color(0.23, 0.24, 0.26))
		_kbeam(k, A + Vector3.DOWN * 2.0, B + Vector3.DOWN * 2.0, 12.0, 1.2, conc, false)
		for sz: float in [-1.0, 1.0]:
			var o := Vector3(0.0, 0.0, sz * 9.8)
			_kbeam(k, A + o + Vector3.UP * 0.55, B + o + Vector3.UP * 0.55, 0.4, 1.1, conc)
			_anchor(A + o * 1.03 + Vector3.DOWN * 1.4, B + o * 1.03 + Vector3.DOWN * 1.4)
			# Lane lines (painted, no collision): edge lines and lane dashes.
			_kbeam(k, A + Vector3(0, 0.01, sz * 7.6), B + Vector3(0, 0.01, sz * 7.6), 0.15, 0.02, Color(0.9, 0.9, 0.86),
				false)
			if i % 2 == 0:
				_kbeam(k, A + Vector3(0, 0.01, sz * 3.8), A.lerp(B, 0.4) + Vector3(0, 0.01, sz * 3.8), 0.15, 0.02,
					Color(0.9, 0.9, 0.86), false)
		_kbeam(k, A + Vector3(0, 0.01, 0.0), B + Vector3(0, 0.01, 0.0), 0.3, 0.02, Color(0.92, 0.78, 0.25), false)
	var x := x0 - 30.0
	while x > x1 + 30.0:
		var y := float(yf.call(x)) - 2.6
		var g := CityTerrain.mainland_design(x, zc) - 0.5
		if y - g > 2.0:
			for sz: float in [-1.0, 1.0]:
				_kbeam(k, Vector3(x, g, zc + sz * 5.5), Vector3(x, y, zc + sz * 5.5), 1.8, 1.8, conc)
			_kbeam(k, Vector3(x, y + 0.3, zc - 8.0), Vector3(x, y + 0.3, zc + 8.0), 1.6, 1.2, conc)
		x -= 40.0




