class_name CoastLife
extends RefCounted
## Life on the island's edges, so the coast isn't one long sea wall:
##
##   * North Beach: the shore apron along the north coast widens into a long,
##     shallow sand beach (BuildingMesher.shore_profile reads beach_k) with a
##     row of painted beach huts under the sea wall, steps down from the
##     esplanade, umbrellas and loungers, lifeguard towers, volleyball nets
##     and a pleasure pier out into the sea with a pavilion at its end.
##   * The Marina: pontoons in the strait off the west quay (where the old
##     waterfront viaduct stood) with yachts and motor boats in their berths,
##     gangways down from the quay, mooring piles. The yachts' masts take a
##     web – low, quick swings over the water.
##
## All of it is set-piece kits (drawn and collided from the same list) with
## its own random numbers, seeded from the layout's seed – adding it never
## reshuffles the rest of the city.

## The beach: the north coast between these x (eased in and out over FADE).
const BEACH_X := Vector2(140.0, 615.0)
const BEACH_NORTH_OF := -520.0
const BEACH_FADE := 80.0
const BEACH_W := 88.0                 # sand from the sea wall to the water's edge (m)
## The marina: berths along the west quay between these z.
const MARINA_Z := Vector2(70.0, 320.0)
const PONTOON_X := -4.0               # the main pontoon's centreline (quay at RIVER_EDGE)
const PONTOON_Y := 0.7                # pontoon deck above the water
const HUTS := [Color(0.93, 0.42, 0.38), Color(0.98, 0.83, 0.38), Color(0.45, 0.72, 0.85), Color(0.6, 0.82, 0.6),
	Color(0.96, 0.96, 0.92), Color(0.98, 0.62, 0.32), Color(0.82, 0.6, 0.85)]
const UMBRELLAS := [Color(0.92, 0.25, 0.22), Color(0.98, 0.82, 0.25), Color(0.22, 0.52, 0.86), Color(0.96, 0.96, 0.94),
	Color(0.2, 0.68, 0.55), Color(0.98, 0.55, 0.22)]
const WOOD := Color(0.55, 0.42, 0.3)
const WOOD_DK := Color(0.36, 0.27, 0.2)
const WHITE := Color(0.95, 0.95, 0.93)
const STEEL := Color(0.62, 0.64, 0.66)

var L: CityLayout
var rng := RandomNumberGenerator.new()


func _init(layout: CityLayout) -> void:
	L = layout
	rng.seed = layout.seed * 31 + 7


## 0..1: how much of a beach the shore at p (a point on the sea wall) is.
static func beach_k(p: Vector2) -> float:
	if p.y > BEACH_NORTH_OF:
		return 0.0
	return smoothstep(BEACH_X.x, BEACH_X.x + BEACH_FADE, p.x) * (1.0 - smoothstep(BEACH_X.y - BEACH_FADE, BEACH_X.y, p.x))


func build() -> void:
	_beach()
	_marina()


# --------------------------------------------------------------- the beach
## Height of the sand d metres out from the sea wall at shore sample smp.
func _sand_y(smp: Array, d: float) -> float:
	var prof := BuildingMesher.shore_profile(L, smp)
	prof.pop_back()
	for k in prof.size() - 1:
		var a: Array = prof[k]
		var b: Array = prof[k + 1]
		if d <= float(b[0]):
			return lerpf(float(a[1]), float(b[1]), clampf((d - float(a[0])) / maxf(float(b[0]) - float(a[0]), 0.01), 0.0, 1.0))
	return float(prof[-1][1])


func _beach() -> void:
	var smp: Array = BuildingMesher.shore_samples(L.coast)
	var on: Array = []  # the samples well inside the beach
	for sm in smp:
		if beach_k(sm[0]) > 0.95:
			on.append(sm)
	if on.size() < 10:
		return
	var k := L._kit("beach")
	var huts := 0
	var last_s := -INF
	var pier_s: float = (float(on[0][2]) + float(on[-1][2])) * 0.5
	var pier_done := false
	for i in on.size():
		var sm: Array = on[i]
		var p: Vector2 = sm[0]
		var n: Vector2 = sm[1]
		var s: float = sm[2]
		var t := Vector2(-n.y, n.x)  # along the coast
		var top := L.terrain.road_y(p.x, p.y) + CityTerrain.KERB
		# The pier, half way along.
		if not pier_done and s >= pier_s:
			pier_done = true
			_pier(k, sm, top)
			last_s = s
			continue
		if s - last_s < 7.5:
			continue
		last_s = s
		var block := int(s / 60.0)
		# Steps down from the esplanade every 60 m.
		if posmod(int(s / 7.5), 8) == 0:
			_steps(k, p, n, t, top, _sand_y(sm, 6.0))
			continue
		# A row of beach huts under the wall (in runs, with gaps).
		if block % 3 != 2:
			_hut(k, p + n * 4.6, n, t, _sand_y(sm, 4.6), HUTS[huts % HUTS.size()])
			huts += 1
		# Out on the sand: umbrellas with loungers; a lifeguard tower every
		# ~180 m; a volleyball net now and then.
		var d := rng.randf_range(24.0, 48.0)
		var q := p + n * d + t * rng.randf_range(-2.0, 2.0)
		var y := _sand_y(sm, d)
		if posmod(int(s / 7.5), 24) == 12:
			_lifeguard(k, p + n * 34.0, n, t, _sand_y(sm, 34.0))
		elif posmod(int(s / 7.5), 17) == 5:
			_net(k, q, t, y)
		elif rng.randf() < 0.8:
			_umbrella(k, q, n, t, y, UMBRELLAS[rng.randi() % UMBRELLAS.size()])
		if rng.randf() < 0.45:
			var d2 := rng.randf_range(54.0, 64.0)
			_umbrella(k, p + n * d2 + t * 3.5, n, t, _sand_y(sm, d2), UMBRELLAS[rng.randi() % UMBRELLAS.size()])


func _steps(k: Dictionary, p: Vector2, n: Vector2, t: Vector2, top: float, sand: float) -> void:
	var rise := top - sand
	if rise < 0.6:
		return
	var steps := ceili(rise / 0.3)
	var h := rise / steps
	for i in steps:
		var y1 := top - h * i
		var a := p + n * (0.3 + i * 0.45)
		var b := a + n * 0.45
		# (A flight 3 m wide, each step a solid block down to the sand.)
		var pts := PackedVector2Array([a - t * 1.5, a + t * 1.5, b + t * 1.5, b - t * 1.5])
		L._kprism(k, pts, sand - 0.4, y1 - h, Color(0.72, 0.68, 0.6))


func _hut(k: Dictionary, c: Vector2, n: Vector2, t: Vector2, y: float, col: Color) -> void:
	var w := 2.6
	var dp := 2.8
	var fp := PackedVector2Array([c - t * w * 0.5 - n * dp * 0.5, c + t * w * 0.5 - n * dp * 0.5,
		c + t * w * 0.5 + n * dp * 0.5, c - t * w * 0.5 + n * dp * 0.5])
	L._kprism(k, fp, y - 0.3, y + 2.3, col)
	# Door, and an overhanging white roof in two steps.
	var front := c + n * (dp * 0.5 + 0.03)
	L._kbeam(k, Vector3(front.x, y + 0.05, front.y), Vector3(front.x, y + 1.95, front.y), 1.0, 0.06, col.darkened(0.3), false)
	var eave := PackedVector2Array([c - t * (w * 0.5 + 0.3) - n * (dp * 0.5 + 0.3), c + t * (w * 0.5 + 0.3) - n * (dp * 0.5 + 0.3),
		c + t * (w * 0.5 + 0.3) + n * (dp * 0.5 + 0.5), c - t * (w * 0.5 + 0.3) + n * (dp * 0.5 + 0.5)])
	L._kprism(k, eave, y + 2.3, y + 2.5, WHITE)
	var crest := PackedVector2Array([c - t * w * 0.3 - n * dp * 0.45, c + t * w * 0.3 - n * dp * 0.45,
		c + t * w * 0.3 + n * dp * 0.6, c - t * w * 0.3 + n * dp * 0.6])
	L._kprism(k, crest, y + 2.5, y + 2.85, WHITE.darkened(0.05))


func _umbrella(k: Dictionary, c: Vector2, n: Vector2, t: Vector2, y: float, col: Color) -> void:
	L._kbeam(k, Vector3(c.x, y - 0.3, c.y), Vector3(c.x, y + 2.3, c.y), 0.07, 0.07, WHITE, false)
	var ring := PackedVector2Array()
	for i in 8:
		var a := TAU * (i + 0.5) / 8.0
		ring.append(c + Vector2(cos(a), sin(a)) * 1.35)
	L._kprism(k, ring, y + 2.2, y + 2.34, col)
	var cap := PackedVector2Array()
	for i in 8:
		var a := TAU * (i + 0.5) / 8.0
		cap.append(c + Vector2(cos(a), sin(a)) * 0.7)
	L._kprism(k, cap, y + 2.34, y + 2.5, col.lightened(0.15))
	# Two loungers in its shade, foot to the sea.
	for sg: float in [-1.0, 1.0]:
		var l0 := c + t * sg * 0.75 - n * 0.6
		var l1 := l0 + n * 1.9
		L._kbeam(k, Vector3(l0.x, y + 0.3, l0.y), Vector3(l1.x, y + 0.3, l1.y), 0.65, 0.12, WHITE, false)
		var back := l0 + n * 0.1
		L._kbeam(k, Vector3(back.x, y + 0.3, back.y), Vector3((back - n * 0.45).x, y + 0.75, (back - n * 0.45).y), 0.65,
			0.08, WHITE.darkened(0.08), false)


func _lifeguard(k: Dictionary, c: Vector2, n: Vector2, t: Vector2, y: float) -> void:
	var red := Color(0.86, 0.2, 0.16)
	for a: float in [-1.0, 1.0]:
		for b: float in [-1.0, 1.0]:
			var q := c + t * a * 1.3 + n * b * 1.3
			L._kbeam(k, Vector3(q.x, y - 0.4, q.y), Vector3(q.x, y + 3.0, q.y), 0.2, 0.2, WHITE)
	var hut := PackedVector2Array([c - t * 1.6 - n * 1.6, c + t * 1.6 - n * 1.6, c + t * 1.6 + n * 1.6, c - t * 1.6 + n * 1.6])
	L._kprism(k, hut, y + 3.0, y + 3.25, WOOD)  # deck
	var cab := PackedVector2Array([c - t * 1.2 - n * 1.2, c + t * 1.2 - n * 1.2, c + t * 1.2 + n * 0.6, c - t * 1.2 + n * 0.6])
	L._kprism(k, cab, y + 3.25, y + 5.3, red)
	var roof := PackedVector2Array([c - t * 1.7 - n * 1.7, c + t * 1.7 - n * 1.7, c + t * 1.7 + n * 1.7, c - t * 1.7 + n * 1.7])
	L._kprism(k, roof, y + 5.3, y + 5.55, WHITE)
	L._kbeam(k, Vector3(c.x, y + 5.55, c.y), Vector3(c.x, y + 8.0, c.y), 0.06, 0.06, STEEL, false)  # flag pole
	var f := c + t * 0.5
	L._kbeam(k, Vector3(c.x, y + 7.6, c.y), Vector3(f.x, y + 7.6, f.y), 0.02, 0.4, Color(0.98, 0.85, 0.2), false)
	# Ramp up the landward side.
	var r0 := c - n * 6.0
	var r1 := c - n * 1.6
	L._kbeam(k, Vector3(r0.x, y, r0.y), Vector3(r1.x, y + 3.1, r1.y), 0.9, 0.12, WOOD)


func _net(k: Dictionary, c: Vector2, t: Vector2, y: float) -> void:
	var a := c - t * 4.5
	var b := c + t * 4.5
	for q: Vector2 in [a, b]:
		L._kbeam(k, Vector3(q.x, y - 0.3, q.y), Vector3(q.x, y + 2.5, q.y), 0.1, 0.1, WHITE)
	L._kbeam(k, Vector3(a.x, y + 2.15, a.y), Vector3(b.x, y + 2.15, b.y), 0.02, 0.8, Color(0.15, 0.15, 0.17), false)
	L._kbeam(k, Vector3(a.x, y + 2.55, a.y), Vector3(b.x, y + 2.55, b.y), 0.05, 0.06, WHITE, false)


## The pleasure pier: a boardwalk on piles from the esplanade out past the
## surf, railings and lamps, and a domed pavilion at the end.
func _pier(k: Dictionary, sm: Array, top: float) -> void:
	var p: Vector2 = sm[0]
	var n: Vector2 = sm[1]
	var t := Vector2(-n.y, n.x)
	var deck := top
	var length := 150.0
	var hw := 3.5
	var a := p
	var b := p + n * length
	var A := Vector3(a.x, deck, a.y)
	var B := Vector3(b.x, deck, b.y)
	var N := Vector3(n.x, 0.0, n.y)
	var T := Vector3(t.x, 0.0, t.y)
	L._kbeam(k, A + Vector3.DOWN * 0.2, B + Vector3.DOWN * 0.2, hw * 2.0, 0.4, WOOD)
	L._kbeam(k, A + Vector3.DOWN * 0.8, B + Vector3.DOWN * 0.8, hw * 2.0 - 0.6, 0.8, WOOD_DK, false)
	for sg: float in [-1.0, 1.0]:
		var o := T * sg * (hw - 0.1)
		L._kbeam(k, A + o + Vector3.UP * 1.0, B + o + Vector3.UP * 1.0, 0.08, 0.08, WHITE, false)
		L._kbeam(k, A + o + Vector3.UP * 0.5, B + o + Vector3.UP * 0.5, 0.05, 0.05, WHITE, false)
	var d := 6.0
	while d < length:
		var q := p + n * d
		for sg: float in [-1.0, 1.0]:
			var c := q + t * sg * (hw - 0.6)
			L._kbeam(k, Vector3(c.x, -4.0, c.y), Vector3(c.x, deck - 0.4, c.y), 0.45, 0.45, WOOD_DK)
			# Railing posts, and a lamp every 18 m.
			var r := q + t * sg * (hw - 0.1)
			L._kbeam(k, Vector3(r.x, deck, r.y), Vector3(r.x, deck + 1.05, r.y), 0.1, 0.1, WHITE, false)
		if int(d) % 18 == 0:
			var lp := q + t * (hw - 0.15)
			L._kbeam(k, Vector3(lp.x, deck, lp.y), Vector3(lp.x, deck + 4.2, lp.y), 0.12, 0.12, Color(0.15, 0.3, 0.3))
			L._kbeam(k, Vector3(lp.x, deck + 4.2, lp.y) - T * 0.25, Vector3(lp.x, deck + 4.2, lp.y) + T * 0.25, 0.3, 0.3,
				Color(1.0, 0.95, 0.8), false)
		d += 6.0
	# The pavilion: a wider deck, a round hall with a dome and a spire.
	var e := p + n * (length + 9.0)
	L._kprism(k, _ngon(e, 13.0, 12), deck - 0.6, deck - 0.2, WOOD)
	for i in 12:
		var q := e + Vector2(cos(TAU * i / 12.0), sin(TAU * i / 12.0)) * 12.4
		L._kbeam(k, Vector3(q.x, -4.0, q.y), Vector3(q.x, deck - 0.6, q.y), 0.5, 0.5, WOOD_DK)
	L._kprism(k, _ngon(e, 8.0, 12), deck - 0.2, deck + 4.2, Color(0.96, 0.93, 0.86))
	L._kprism(k, _ngon(e, 8.6, 12), deck + 4.2, deck + 4.6, Color(0.2, 0.42, 0.5))
	var r := 7.6
	var y := deck + 4.6
	for band in 4:
		var r1 := r * (0.82 - band * 0.12)
		L._kprism(k, _ngon(e, r, 12), y, y + 1.2, Color(0.25, 0.5, 0.55).lightened(band * 0.06))
		y += 1.2
		r = r1
	L._kbeam(k, Vector3(e.x, y, e.y), Vector3(e.x, y + 5.0, e.y), 0.18, 0.18, Color(0.85, 0.7, 0.3))
	L._anchor(Vector3(e.x, y + 1.0, e.y), Vector3(e.x, y + 4.8, e.y))


# -------------------------------------------------------------- the marina
func _marina() -> void:
	var k := L._kit("marina")
	var z0 := MARINA_Z.x
	var z1 := MARINA_Z.y
	var X := PONTOON_X
	var y := PONTOON_Y
	var quay_x := CityLayout.RIVER_EDGE
	# The main pontoon along the quay, on floats, with a kerb rail.
	L._ksolid(k, X - 1.6, z0, X + 1.6, z1, y - 0.5, y, Color(0.6, 0.55, 0.48))
	L._ksolid(k, X - 1.5, z0, X + 1.5, z1, y - 1.1, y - 0.5, Color(0.22, 0.24, 0.26), false)
	# Gangways down from the quay every ~90 m.
	var gz := z0 + 20.0
	while gz < z1:
		var top := L.terrain.road_y(quay_x + 4.0, gz) + CityTerrain.KERB
		L._kbeam(k, Vector3(quay_x + 1.0, top, gz), Vector3(X + 1.6, y, gz), 1.6, 0.15, STEEL)
		for sg: float in [-1.0, 1.0]:
			L._kbeam(k, Vector3(quay_x + 1.0, top + 1.0, gz + sg * 0.8), Vector3(X + 1.6, y + 1.0, gz + sg * 0.8), 0.05, 0.05,
				STEEL, false)
		gz += 90.0
	# Fingers out to the west (berths between them) and back toward the quay.
	var z := z0 + 6.0
	var i := 0
	while z < z1 - 6.0:
		for side: float in [-1.0, 1.0]:
			var fx0 := X - 1.6 if side < 0.0 else X + 1.6
			var fx1 := fx0 + side * 13.0
			L._ksolid(k, minf(fx0, fx1), z - 0.7, maxf(fx0, fx1), z + 0.7, y - 0.4, y - 0.05, Color(0.62, 0.56, 0.48))
			# A mooring pile at the finger's end.
			L._kbeam(k, Vector3(fx1, -3.0, z), Vector3(fx1, y + 2.4, z), 0.45, 0.45, WOOD_DK)
			# A boat in the berth beside it (most berths are taken).
			if rng.randf() < 0.82 and z + 7.0 < z1:
				var bc := Vector2((fx0 + fx1) * 0.5 + side * 0.5, z + 6.5)
				if side < 0.0 and rng.randf() < 0.6:
					_yacht(k, bc, side, rng.randf_range(10.0, 13.0))
				else:
					_motorboat(k, bc, side, rng.randf_range(7.5, 10.0))
		z += 13.0
		i += 1
	# A harbour master's hut at the north end, and a breakwater line of piles.
	L._kprism(k, PackedVector2Array([Vector2(X - 3.0, z0 - 7.0), Vector2(X + 3.0, z0 - 7.0), Vector2(X + 3.0, z0),
		Vector2(X - 3.0, z0)]), y - 0.5, y, Color(0.6, 0.55, 0.48))
	L._kprism(k, PackedVector2Array([Vector2(X - 2.2, z0 - 6.0), Vector2(X + 2.2, z0 - 6.0), Vector2(X + 2.2, z0 - 1.0),
		Vector2(X - 2.2, z0 - 1.0)]), y, y + 2.8, Color(0.92, 0.9, 0.84))
	L._kprism(k, PackedVector2Array([Vector2(X - 2.7, z0 - 6.5), Vector2(X + 2.7, z0 - 6.5), Vector2(X + 2.7, z0 - 0.5),
		Vector2(X - 2.7, z0 - 0.5)]), y + 2.8, y + 3.1, Color(0.18, 0.32, 0.45))
	var bz := z0
	while bz <= z1:
		L._kbeam(k, Vector3(X - 24.0, -3.0, bz), Vector3(X - 24.0, 2.6, bz), 0.6, 0.6, WOOD_DK)
		bz += 12.5


## A sailing yacht moored stern-to the pontoon, bow out (side = -1: west).
func _yacht(k: Dictionary, c: Vector2, side: float, length: float) -> void:
	var hull_col: Color = [WHITE, Color(0.12, 0.2, 0.36), WHITE, Color(0.85, 0.82, 0.74)][rng.randi() % 4]
	var bm := length * 0.3
	var hull := _hull(c, side, length, bm)
	L._kprism(k, hull, -0.5, 1.0, hull_col)
	L._kprism(k, _hull(c, side, length * 0.94, bm * 0.92), 1.0, 1.08, Color(0.72, 0.6, 0.45))  # teak deck
	# Cabin top, aft of the mast.
	var cab := _hull(c - Vector2(side * length * 0.08, 0.0), side, length * 0.42, bm * 0.6)
	L._kprism(k, cab, 1.08, 1.7, WHITE)
	# Mast, boom, a furled sail and its cover.
	var m := c + Vector2(side * length * 0.12, 0.0)
	var mh := length * 1.25
	L._kbeam(k, Vector3(m.x, 1.08, m.y), Vector3(m.x, mh, m.y), 0.16, 0.16, STEEL)
	var boom := m - Vector2(side * length * 0.38, 0.0)
	L._kbeam(k, Vector3(m.x, 2.6, m.y), Vector3(boom.x, 2.6, boom.y), 0.14, 0.14, STEEL, false)
	L._kbeam(k, Vector3(m.x, 2.85, m.y), Vector3(boom.x + side * 0.4, 2.85, boom.y), 0.32, 0.36,
		[Color(0.2, 0.3, 0.55), Color(0.55, 0.15, 0.15), Color(0.25, 0.45, 0.4)][rng.randi() % 3], false)
	# Forestay and backstay.
	var bow := c + Vector2(side * length * 0.5, 0.0)
	var stern := c - Vector2(side * length * 0.48, 0.0)
	L._kbeam(k, Vector3(m.x, mh, m.y), Vector3(bow.x, 1.1, bow.y), 0.03, 0.03, STEEL, false)
	L._kbeam(k, Vector3(m.x, mh, m.y), Vector3(stern.x, 1.1, stern.y), 0.03, 0.03, STEEL, false)
	L._anchor(Vector3(m.x, mh * 0.6, m.y), Vector3(m.x, mh - 0.3, m.y))


func _motorboat(k: Dictionary, c: Vector2, side: float, length: float) -> void:
	var bm := length * 0.34
	L._kprism(k, _hull(c, side, length, bm), -0.4, 0.9, WHITE)
	L._kbeam(k, Vector3(c.x - side * length * 0.45, 0.55, c.y + bm * 0.5), Vector3(c.x + side * length * 0.4, 0.55,
		c.y + bm * 0.5), 0.04, 0.16, [Color(0.15, 0.35, 0.6), Color(0.7, 0.15, 0.12), Color(0.1, 0.1, 0.12)][rng.randi() % 3],
		false)
	var cab := _hull(c + Vector2(side * length * 0.02, 0.0), side, length * 0.4, bm * 0.7)
	L._kprism(k, cab, 0.9, 1.9, Color(0.18, 0.22, 0.26))
	L._kprism(k, _hull(c - Vector2(side * length * 0.03, 0.0), side, length * 0.44, bm * 0.76), 1.9, 2.0, WHITE)


## A hull's plan (convex): square stern, a pointed bow toward `side`.
static func _hull(c: Vector2, side: float, length: float, beam: float) -> PackedVector2Array:
	var f := Vector2(side, 0.0)
	var r := Vector2(0.0, 1.0)
	var h := length * 0.5
	var w := beam * 0.5
	return PackedVector2Array([c - f * h - r * w * 0.8, c + f * h * 0.25 - r * w, c + f * h * 0.75 - r * w * 0.6,
		c + f * h, c + f * h * 0.75 + r * w * 0.6, c + f * h * 0.25 + r * w, c - f * h + r * w * 0.8])


static func _ngon(c: Vector2, r: float, n: int) -> PackedVector2Array:
	var out := PackedVector2Array()
	for i in n:
		var a := TAU * (i + 0.5) / n
		out.append(c + Vector2(cos(a), sin(a)) * r)
	return out
