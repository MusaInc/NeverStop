class_name CityTerrain
extends RefCounted
## The city's ground: designed geography, not noise.
##
##   * The river, the waterfront and the docks stay at quay level (0 m): the
##     river wall, the basins, the ship and the bridge landing need it.
##   * The land rises east from the waterfront towards the Heights, a ridge
##     in the north-east crowned by the cathedral (~+30 m).
##   * The business district stands on a raised plateau (~+13 m).
##   * A broad valley runs east from the docks along the railway (z ≈ 369):
##     the elevated line crosses it on its viaduct over the valley floor.
##
## The landform is sampled on a regular 8 m grid (GRID) and the ground is
## its bilinear interpolation: roads, pavements and lots all follow it.
## Beyond the grid the surface carries on level from the edge (clamped),
## which keeps the far shore continuous.
##
## Blocks: pavements follow the ground (+ kerb); each building stands level
## on its lot at the lot's highest corner, with a stone base course down the
## slope. Set pieces and basins stand on level terraces (poly_level).

const KERB := 0.15
## Design elevations (m).
const RISE := 24.0          # waterfront → east
const HEIGHTS := 36.0       # the north-east ridge on top of that
const PLATEAU := 22.0       # business district plateau
const RAIL_Z := 369.0       # valley axis (the elevated railway)

var xs := PackedFloat32Array()   # junction lines (x street centres), ascending
var zs := PackedFloat32Array()   # (z street centres)
var h := PackedFloat32Array()    # junction heights, index i * zs.size() + j
## Road decks carrying a north-south street over lower ground:
## [{"x": centre, "half": half width, "za": z, "zb": z, "ya": y, "yb": y}]
## (traffic on that street rides the deck; cross streets pass under it).
var decks: Array = []


const GRID := 8.0   # m: height grid spacing (the landform is smooth; roads follow it)


## Samples the landform on a regular GRID-metre lattice over `area` (the
## island plus a margin). Beyond it road_y continues level (clamped).
func build(area: Rect2) -> void:
	xs.clear()
	zs.clear()
	var x := area.position.x
	while x <= area.end.x + GRID:
		xs.append(x)
		x += GRID
	var z := area.position.y
	while z <= area.end.y + GRID:
		zs.append(z)
		z += GRID
	h.resize(xs.size() * zs.size())
	for i in xs.size():
		for j in zs.size():
			h[i * zs.size() + j] = snappedf(design(xs[i], zs[j]), 0.01)


## The designed landform, sampled at junctions only (see build()).
static func design(x: float, z: float) -> float:
	if x < CityLayout.FAR_SHORE:
		return mainland_design(x, z)
	var y := RISE * smoothstep(210.0, 860.0, x)
	# The Heights: the cathedral's ridge, north-east.
	var dx := (x - 900.0) / 260.0
	var dz := (z + 390.0) / 300.0
	y += HEIGHTS * exp(-(dx * dx + dz * dz))
	# Business district plateau: lifted level, eased out at its rim.
	var c := 1.0 - smoothstep(170.0, 360.0, Vector2(x, z).distance_to(CityLayout.CBD_CENTER))
	y = lerpf(y, PLATEAU, c)
	# Rail valley: the docks' low ground running east under the viaduct.
	y *= smoothstep(95.0, 380.0, absf(z - RAIL_Z))
	# Docks and waterfront: quay level.
	var dock := (1.0 - smoothstep(470.0, 600.0, x)) * smoothstep(180.0, 265.0, z)
	y *= 1.0 - dock
	return maxf(y, 0.0)


## The mainland across the strait: a quay at sea level rising westward onto
## Westbank Hill (where the bridge's approach viaduct comes down), with a
## gentler knoll in the south-west.
const MAINLAND_RISE := 22.0


static func mainland_design(x: float, z: float) -> float:
	var y := MAINLAND_RISE * smoothstep(CityLayout.FAR_SHORE - 40.0, CityLayout.FAR_SHORE - 330.0, x)
	var dx := (x + 980.0) / 220.0
	var dz := (z - 260.0) / 200.0
	y += 12.0 * exp(-(dx * dx + dz * dz))
	return y


func _node(i: int, j: int) -> float:
	return h[i * zs.size() + j]


## Index of the grid interval containing v (clamped), and the 0..1 position in it.
static func _cell(lines: PackedFloat32Array, v: float) -> Vector2:
	var n := lines.size()
	if v <= lines[0]:
		return Vector2(0, 0.0)
	if v >= lines[n - 1]:
		return Vector2(n - 2, 1.0)
	var lo := 0
	var hi := n - 1
	while hi - lo > 1:
		var mid := (lo + hi) >> 1
		if lines[mid] <= v:
			lo = mid
		else:
			hi = mid
	return Vector2(lo, (v - lines[lo]) / (lines[lo + 1] - lines[lo]))


## Height of the road surface (and of the ground everywhere a block isn't).
func road_y(x: float, z: float) -> float:
	if h.is_empty():
		return 0.0
	var cx := _cell(xs, x)
	var cz := _cell(zs, z)
	var i := int(cx.x)
	var j := int(cz.x)
	var a := lerpf(_node(i, j), _node(i + 1, j), cx.y)
	var b := lerpf(_node(i, j + 1), _node(i + 1, j + 1), cx.y)
	return lerpf(a, b, cz.y)


## Terrace level of a block (its pavement top): the highest street corner plus
## the kerb, so every street round it is at or below the pavement.
func poly_level(poly: PackedVector2Array) -> float:
	var m := -INF
	for p in poly:
		m = maxf(m, road_y(p.x, p.y))
	var c := Vector2.ZERO
	for p in poly:
		c += p
	c /= maxf(poly.size(), 1)
	return maxf(m, road_y(c.x, c.y)) + KERB


func block_level(r: Rect2) -> float:
	var m := -INF
	for p in [r.position, Vector2(r.end.x, r.position.y), r.end, Vector2(r.position.x, r.end.y)]:
		m = maxf(m, road_y(p.x, p.y))
	# Bilinear surfaces peak at a corner or along an edge's ends; check the
	# edge midpoints too (they can't exceed the corners, but be safe).
	for p in [Vector2(r.get_center().x, r.position.y), Vector2(r.get_center().x, r.end.y),
			Vector2(r.position.x, r.get_center().y), Vector2(r.end.x, r.get_center().y)]:
		m = maxf(m, road_y(p.x, p.y))
	return m + KERB


## Sample positions along [a, b] that include every junction line in between
## and are at most `step` apart, so a mesh through them follows road_y().
func splits(a: float, b: float, lines: PackedFloat32Array, step: float) -> PackedFloat32Array:
	var cuts := PackedFloat32Array([a])
	for l in lines:
		if l > a + 0.01 and l < b - 0.01:
			cuts.append(l)
	cuts.append(b)
	var out := PackedFloat32Array()
	for k in cuts.size() - 1:
		var u0 := cuts[k]
		var u1 := cuts[k + 1]
		var n := maxi(1, ceili((u1 - u0) / step))
		for m in n:
			out.append(lerpf(u0, u1, float(m) / n))
	out.append(b)
	return out


## Deck height where (x, z) is on a road deck, else NAN.
func deck_y(x: float, z: float) -> float:
	for d in decks:
		if absf(x - float(d["x"])) <= float(d["half"]) and z >= float(d["za"]) and z <= float(d["zb"]):
			return lerpf(d["ya"], d["yb"], (z - float(d["za"])) / (float(d["zb"]) - float(d["za"])))
	return NAN


## Bakes the road surface into an RG texture (texel centres on a `cell` m
## grid) for the traffic / pedestrian shaders: R = what north-south traffic
## drives on (decks included), G = the ground (east-west traffic, walkers).
## Sampled with clamping, it continues level beyond the grid like road_y().
func bake(rect: Rect2, cell: float) -> ImageTexture:
	var w := int(ceil(rect.size.x / cell)) + 1
	var hh := int(ceil(rect.size.y / cell)) + 1
	# Grid cell and fraction per texel column / row, found once.
	var cxs: Array[Vector2] = []
	for px in w:
		cxs.append(_cell(xs, rect.position.x + px * cell))
	var data := PackedFloat32Array()
	data.resize(w * hh * 2)
	var nz := zs.size()
	for pz in hh:
		var z := rect.position.y + pz * cell
		var cz := _cell(zs, z)
		var j := int(cz.x)
		for px in w:
			var cx: Vector2 = cxs[px]
			var i := int(cx.x)
			var a := lerpf(h[i * nz + j], h[(i + 1) * nz + j], cx.y)
			var b := lerpf(h[i * nz + j + 1], h[(i + 1) * nz + j + 1], cx.y)
			var g := lerpf(a, b, cz.y)
			var k := (pz * w + px) * 2
			data[k] = g
			data[k + 1] = g
	for d in decks:
		# North-south traffic drives on the deck (R).
		for pz in hh:
			var z := rect.position.y + pz * cell
			if z < float(d["za"]) or z > float(d["zb"]):
				continue
			var y := lerpf(d["ya"], d["yb"], (z - float(d["za"])) / (float(d["zb"]) - float(d["za"])))
			for px in w:
				if absf(rect.position.x + px * cell - float(d["x"])) <= float(d["half"]):
					data[(pz * w + px) * 2] = y
	var img := Image.create_from_data(w, hh, false, Image.FORMAT_RGF, data.to_byte_array())
	return ImageTexture.create_from_image(img)
