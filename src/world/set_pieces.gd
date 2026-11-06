class_name SetPieces
extends RefCounted
## Hand-designed set pieces that give each district its own way to play,
## placed where the open-air swinging used to be thin (tools/anchor_audit.gd):
##  * Docks: container yards to run and leap across, and a cargo ship moored
##    in a basin under the quay crane (deck, bridge, funnel, derricks).
##  * Waterfront: an observation wheel by the river – a ring of anchors.
##  * Old Town (east): a football ground whose four floodlight pylons are the
##    tallest anchors for blocks around, and a Victorian gasholder frame (a
##    ring of lattice columns and girders to swing through).
##  * Midtown: an elevated railway along an avenue, with a parked train.
##  * Business district: gateway blocks spanning the avenues high up.
##  * A lighthouse on a pier at the dock entrance (the river's south end).
## Everything is built as a "kit" (see CityLayout._kit*): boxes, beams and
## convex prisms that BuildingMesher draws and CityWorld turns into the same
## collision – what you see is exactly what you hit. Each piece has its own
## random stream, so adding one never reshuffles the city.

const STADIUM_AT := Vector2(843, 219)
const GASHOLDER_AT := Vector2(800, -555)
const WHEEL_AT := Vector2(135, 219)
const YARDS_AT := [Vector2(135, 505), Vector2(135, 300)]
const SHIP_AT := Vector2(240, 423)
const LIGHTHOUSE_AT := Vector2(8, 560)

const RED := Color(0.72, 0.12, 0.1)
const WHITE := Color(0.9, 0.9, 0.87)
const STEEL := Color(0.22, 0.23, 0.25)
const IRON_GREEN := Color(0.2, 0.33, 0.28)
const CONTAINER_COLORS := [Color(0.72, 0.18, 0.12), Color(0.12, 0.32, 0.55), Color(0.85, 0.6, 0.12),
	Color(0.2, 0.45, 0.3), Color(0.82, 0.82, 0.8), Color(0.45, 0.22, 0.4), Color(0.9, 0.4, 0.12)]

var L: CityLayout


func _init(layout: CityLayout) -> void:
	L = layout


## Where each set piece stands (axis-aligned, world): the road network keeps
## its cuts clear of these, and the block holding one is terraced for it.
func rects() -> Dictionary:
	if _rects.is_empty():
		_rects = {
			"stadium": Rect2(STADIUM_AT - Vector2(75, 65), Vector2(150, 130)),
			"gasholder": Rect2(GASHOLDER_AT - Vector2(46, 41), Vector2(92, 82)),
			"wheel": Rect2(WHEEL_AT - Vector2(40, 40), Vector2(80, 80)),
			"yard": Rect2(YARDS_AT[0] - Vector2(40, 40), Vector2(80, 80)),
			"yard2": Rect2(YARDS_AT[1] - Vector2(40, 39), Vector2(80, 78)),
		}
	return _rects


var _rects := {}


func build(piece: String, rect: Rect2) -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = hash(piece) ^ hash(Vector2i(rect.get_center()))
	match piece:
		"stadium":
			_stadium(rect, rng)
		"gasholder":
			_gasholder(rect, rng)
		"wheel":
			_wheel(rect, rng)
		"yard", "yard2":
			_container_yard(rect, rng)


# ------------------------------------------------------------- stadium
## The Heights Ground: a modern bowl on its own plaza. Two tiers of stepped
## stands round a rounded-rectangle (superellipse) plan, alternating club
## red and white sections with darker gangways, a concourse between the
## tiers, a back wall, and a continuous ring roof held by four cable-stayed
## masts (80 m) at the diagonals – floodlight banks on their heads and a
## lamp band round the roof's inner edge. The masts, the stays and the roof
## rim are anchors (the east's tallest), the roof ring is walkable. Forecourt:
## a big screen on a pylon and ticket kiosks.
const STAND_SECTORS := 32
const BOWL_INNER := Vector2(42.0, 30.0)   # half-sizes of the pitch-side edge
const BOWL_DEPTH := 26.0
const SUPER_N := 4.0


## Point on the bowl's ring `d` metres out from the pitch edge, at angle t.
static func _bowl(c: Vector2, t: float, d: float) -> Vector2:
	var e := 2.0 / SUPER_N
	var cx := cos(t)
	var sz := sin(t)
	var x := signf(cx) * pow(absf(cx), e)
	var z := signf(sz) * pow(absf(sz), e)
	return c + Vector2(x * (BOWL_INNER.x + d), z * (BOWL_INNER.y + d))


func _stadium(r: Rect2, rng: RandomNumberGenerator) -> void:
	var k := L._kit("stadium")
	var c := r.get_center()
	var pitch := Rect2(c - Vector2(36, 23.5), Vector2(72, 47))
	# Stands: [d0, d1, top] radial bands, lower tier, concourse, upper tier.
	var bands := [[0.0, 3.0, 1.2], [3.0, 6.0, 3.4], [6.0, 9.0, 5.6], [9.0, 12.0, 7.8], [12.0, 14.5, 9.0],
		[14.5, 17.5, 13.0], [17.5, 20.5, 16.0], [20.5, 23.5, 19.0], [23.5, 25.5, 22.0], [25.5, BOWL_DEPTH, 27.0]]
	var n := STAND_SECTORS
	for i in n:
		var t0 := TAU * i / n
		var t1 := TAU * (i + 1) / n
		var gangway := i % 4 == 0
		for bi in bands.size():
			var bd: Array = bands[bi]
			var col: Color
			if bi == 4:
				col = Color(0.55, 0.55, 0.57)                          # concourse
			elif bi == bands.size() - 1:
				col = WHITE.darkened(0.12)                             # back wall
			elif gangway:
				col = Color(0.3, 0.3, 0.32)
			else:
				col = (RED if (i / 4 + bi) % 2 == 0 else WHITE).darkened(0.06 * (bi % 2))
			var q := PackedVector2Array([_bowl(c, t0, bd[0]), _bowl(c, t1, bd[0]), _bowl(c, t1, bd[1]), _bowl(c, t0, bd[1])])
			L._kprism(k, q, 0.0, bd[2], col)
		# Ring roof: a slab from over the upper tier to past the back wall,
		# its inner edge lit.
		var roof := PackedVector2Array([_bowl(c, t0, 9.0), _bowl(c, t1, 9.0), _bowl(c, t1, BOWL_DEPTH + 2.5),
			_bowl(c, t0, BOWL_DEPTH + 2.5)])
		L._kprism(k, roof, 30.0, 31.0, WHITE)
		var lamp := PackedVector2Array([_bowl(c, t0, 9.0), _bowl(c, t1, 9.0), _bowl(c, t1, 10.2), _bowl(c, t0, 10.2)])
		L._kprism(k, lamp, 29.3, 30.0, Color(0.98, 0.96, 0.85))
		var ea := _bowl(c, t0, 9.0)
		var eb := _bowl(c, t1, 9.0)
		L._anchor(Vector3(ea.x, 29.6, ea.y), Vector3(eb.x, 29.6, eb.y))       # roof rim
		# Outside: red fins on every sector, a glazed concourse band.
		var fp := _bowl(c, t0, BOWL_DEPTH + 0.35)
		var fo := (fp - c).normalized() * 0.35
		L._kbeam(k, Vector3(fp.x + fo.x, 1.5, fp.y + fo.y), Vector3(fp.x + fo.x, 27.5, fp.y + fo.y), 0.7, 0.7,
			RED.darkened(0.1), false)
		var ga := _bowl(c, t0, BOWL_DEPTH + 0.15)
		var gb := _bowl(c, t1, BOWL_DEPTH + 0.15)
		L._kbeam(k, Vector3(ga.x, 10.5, ga.y), Vector3(gb.x, 10.5, gb.y), 0.3, 2.4, Color(0.16, 0.22, 0.27), false)
		# Roof columns behind the back wall every other sector.
		if i % 2 == 0:
			var cp := _bowl(c, t0, BOWL_DEPTH + 1.2)
			L._kbeam(k, Vector3(cp.x, 0.0, cp.y), Vector3(cp.x, 30.0, cp.y), 0.8, 0.8, STEEL.lightened(0.3))
	# Four cable-stayed masts at the diagonals, floodlights on their heads.
	for di in 4:
		var t := PI * 0.25 + PI * 0.5 * di
		var base := _bowl(c, t, BOWL_DEPTH + 9.0)
		var top := Vector3(base.x, 80.0, base.y)
		L._kbeam(k, Vector3(base.x, 0.0, base.y), top, 2.4, 2.4, Color(0.9, 0.9, 0.88))
		L._ksolid(k, base.x - 2.6, base.y - 2.6, base.x + 2.6, base.y + 2.6, 0.0, 1.2, Color(0.6, 0.59, 0.56))
		for o: float in [-0.35, 0.0, 0.35]:
			var rp := _bowl(c, t + o, BOWL_DEPTH + 1.0)
			var to := Vector3(rp.x, 31.0, rp.y)
			L._kbeam(k, top + Vector3.DOWN * 3.0, to, 0.22, 0.22, STEEL.lightened(0.35), false)
			L._anchor(top + Vector3.DOWN * 3.0 + (to - top) * 0.3, top + Vector3.DOWN * 3.0 + (to - top) * 0.7)
		var to_pitch := (c - base).normalized()
		var side := Vector2(-to_pitch.y, to_pitch.x)
		var hc := top + Vector3(to_pitch.x, 0.0, to_pitch.y) * 2.0 + Vector3.DOWN * 1.5
		var hs := Vector3(side.x, 0.0, side.y) * 5.5
		L._kbeam(k, hc - hs, hc + hs, 1.0, 4.0, Color(0.95, 0.95, 0.88))  # lamp bank
		L._kbeam(k, hc - hs + Vector3.UP * 2.4, hc + hs + Vector3.UP * 2.4, 0.5, 0.5, STEEL)
		L._anchor(hc - hs + Vector3.DOWN * 2.2, hc + hs + Vector3.DOWN * 2.2)
	# Goals.
	for e: float in [-1.0, 1.0]:
		var gx := c.x + e * (pitch.size.x * 0.5 - 1.0)
		for s2: float in [-1.0, 1.0]:
			L._kbeam(k, Vector3(gx, 0.15, c.y + s2 * 3.7), Vector3(gx, 2.6, c.y + s2 * 3.7), 0.14, 0.14, WHITE, false)
		L._kbeam(k, Vector3(gx, 2.6, c.y - 3.8), Vector3(gx, 2.6, c.y + 3.8), 0.14, 0.14, WHITE, false)
	# Forecourt: a big screen on a pylon at the south-west corner of the
	# plaza, ticket kiosks by the gates.
	var sc := Vector2(r.position.x + 9.0, r.end.y - 9.0)
	L._kbeam(k, Vector3(sc.x, 0.0, sc.y), Vector3(sc.x, 14.0, sc.y), 1.2, 1.2, STEEL)
	var face := (c - sc).normalized()
	var fs := Vector3(-face.y, 0.0, face.x) * 5.0
	var sp := Vector3(sc.x, 17.0, sc.y)
	L._kbeam(k, sp - fs, sp + fs, 0.6, 6.0, Color(0.08, 0.08, 0.1))
	L._kbeam(k, sp - fs * 0.92 + Vector3(face.x, 0, face.y) * 0.32, sp + fs * 0.92 + Vector3(face.x, 0, face.y) * 0.32,
		0.05, 5.2, RED.lightened(0.15), false)
	L._anchor(sp - fs + Vector3.UP * 3.0, sp + fs + Vector3.UP * 3.0)
	for g in 4:
		var gt := PI * 0.5 * g
		var kp := _bowl(c, gt, BOWL_DEPTH + 6.0)
		var kd := (kp - c).normalized()
		var ks := Vector2(-kd.y, kd.x)
		for s3: float in [-1.0, 1.0]:
			var kc := kp + ks * s3 * 7.0
			L._ksolid(k, kc.x - 1.6, kc.y - 1.6, kc.x + 1.6, kc.y + 1.6, 0.0, 2.8, Color(0.75, 0.16, 0.12))
			L._ksolid(k, kc.x - 1.9, kc.y - 1.9, kc.x + 1.9, kc.y + 1.9, 2.8, 3.1, WHITE)
	L.greens.append(pitch)  # the grass pitch (the forecourt is paved)
	L.reserved.append(r)


## A band along one side of `pitch`, `d0`..`d1` metres out from it.
func _band(k: Dictionary, pitch: Rect2, side: int, d0: float, d1: float, y0: float, y1: float, col: Color) -> void:
	var x0 := pitch.position.x
	var z0 := pitch.position.y
	var x1 := pitch.end.x
	var z1 := pitch.end.y
	match side:
		0: L._ksolid(k, x0, z0 - d1, x1, z0 - d0, y0, y1, col)
		1: L._ksolid(k, x1 + d0, z0, x1 + d1, z1, y0, y1, col)
		2: L._ksolid(k, x0, z1 + d0, x1, z1 + d1, y0, y1, col)
		_: L._ksolid(k, x0 - d1, z0, x0 - d0, z1, y0, y1, col)


func _side_point(pitch: Rect2, side: int, f: float, d: float) -> Vector2:
	match side:
		0: return Vector2(lerpf(pitch.position.x, pitch.end.x, f), pitch.position.y - d)
		1: return Vector2(pitch.end.x + d, lerpf(pitch.position.y, pitch.end.y, f))
		2: return Vector2(lerpf(pitch.position.x, pitch.end.x, f), pitch.end.y + d)
		_: return Vector2(pitch.position.x - d, lerpf(pitch.position.y, pitch.end.y, f))


## Square lattice tower: four solid chords (collide) and cross-bracing (looks).
func _lattice_tower(k: Dictionary, base: Vector3, h: float, size: float, col: Color) -> void:
	var hs := size * 0.5
	var cs := [Vector3(-hs, 0, -hs), Vector3(hs, 0, -hs), Vector3(hs, 0, hs), Vector3(-hs, 0, hs)]
	for c in cs:
		L._kbeam(k, base + c, base + c + Vector3.UP * h, 0.5, 0.5, col)
	var n := int(h / 4.0)
	for i in n:
		var y0 := base.y + h * i / n
		var y1 := base.y + h * (i + 1) / n
		for j in 4:
			var a: Vector3 = cs[j]
			var b: Vector3 = cs[(j + 1) % 4]
			L._kbeam(k, base + a + Vector3(0, y0 - base.y, 0), base + b + Vector3(0, y1 - base.y, 0), 0.16, 0.16, col, false)
	L._ksolid(k, base.x - hs - 0.4, base.z - hs - 0.4, base.x + hs + 0.4, base.z + hs + 0.4, base.y, base.y + 0.8,
		Color(0.6, 0.59, 0.56))


# ----------------------------------------------------------- gasholder
## Victorian gasholder frame: 16 lattice columns on a ring, three ring
## girders (run along them, swing through the middle) and the gas bell
## half-raised inside – a big drum to land on.
func _gasholder(r: Rect2, rng: RandomNumberGenerator) -> void:
	var k := L._kit("gasholder")
	var c := r.get_center()
	var rad := minf(r.size.x, r.size.y) * 0.5 - 7.0
	var n := 16
	var h := 46.0
	var rings := [15.5, 31.0, 46.0]
	var pts: Array = []
	for i in n:
		var a := TAU * i / n
		pts.append(Vector3(c.x + cos(a) * rad, 0.0, c.y + sin(a) * rad))
	for i in n:
		var p: Vector3 = pts[i]
		var out := Vector3(p.x - c.x, 0, p.z - c.y).normalized()
		var tang := out.cross(Vector3.UP)
		# Column: two chords with lacing between them.
		for s: float in [-0.7, 0.7]:
			L._kbeam(k, p + tang * s, p + tang * s + Vector3.UP * h, 0.45, 0.45, IRON_GREEN)
		var m := int(h / 3.0)
		for j in m:
			var y0 := h * j / m
			var y1 := h * (j + 1) / m
			var sa := -0.7 if j % 2 == 0 else 0.7
			L._kbeam(k, p + tang * sa + Vector3.UP * y0, p - tang * sa + Vector3.UP * y1, 0.12, 0.12, IRON_GREEN, false)
		L._ksolid(k, p.x - 1.2, p.z - 1.2, p.x + 1.2, p.z + 1.2, 0.0, 1.2, Color(0.55, 0.5, 0.45))
	for y: float in rings:
		for i in n:
			var a: Vector3 = pts[i]
			var b: Vector3 = pts[(i + 1) % n]
			L._kbeam(k, a + Vector3.UP * (y - 0.6), b + Vector3.UP * (y - 0.6), 0.9, 1.2, IRON_GREEN.lightened(0.08))
			L._anchor(a + Vector3.UP * (y - 1.3), b + Vector3.UP * (y - 1.3))
		# Decorative cap on each column top.
	for p: Vector3 in pts:
		L._ksolid(k, p.x - 0.9, p.z - 0.9, p.x + 0.9, p.z + 0.9, h, h + 1.2, IRON_GREEN.darkened(0.2))
	# The gas bell: a 24-sided drum, raised to a third of the frame.
	var bell: PackedVector2Array = []
	var br := rad - 3.5
	for i in 24:
		var a := TAU * (i + 0.5) / 24.0
		bell.append(Vector2(c.x + cos(a) * br, c.y + sin(a) * br))
	L._kprism(k, bell, 0.0, 14.0 + rng.randf_range(0.0, 4.0), Color(0.42, 0.45, 0.42))
	L.reserved.append(r)


# --------------------------------------------------------- wheel
## Observation wheel on a plaza by the river: a ring of 32 rim segments
## (every one an anchor), spokes to a hub on A-frame legs, 16 gondolas.
func _wheel(r: Rect2, rng: RandomNumberGenerator) -> void:
	var k := L._kit("wheel")
	var c := r.get_center()
	var rad := 32.0
	var hub := Vector3(c.x, rad + 5.0, c.y)
	var n := 32
	var rim: Array = []
	for i in n:
		var a := TAU * i / n
		rim.append(hub + Vector3(0.0, cos(a), sin(a)) * rad)
	for side: float in [-1.6, 1.6]:
		var o := Vector3(side, 0, 0)
		for i in n:
			var a: Vector3 = rim[i]
			var b: Vector3 = rim[(i + 1) % n]
			L._kbeam(k, a + o, b + o, 0.6, 0.9, WHITE)
			L._anchor(a + o * 1.5, b + o * 1.5)
		for i in range(0, n, 2):
			L._kbeam(k, hub + o * 0.5, rim[i] + o, 0.18, 0.18, WHITE.darkened(0.08), false)
	for i in range(0, n, 2):
		L._kbeam(k, rim[i] + Vector3(-1.6, 0, 0), rim[i] + Vector3(1.6, 0, 0), 0.3, 0.3, WHITE.darkened(0.1))
		# Gondola hanging under the rim point.
		var g: Vector3 = rim[i] + Vector3(0, -2.2, 0)
		var gc: Color = [Color(0.9, 0.35, 0.18), Color(0.2, 0.5, 0.75), Color(0.95, 0.75, 0.2)][(i / 2) % 3]
		L._ksolid(k, g.x - 1.6, g.z - 1.4, g.x + 1.6, g.z + 1.4, g.y - 2.4, g.y, gc)
		L._ksolid(k, g.x - 1.7, g.z - 1.5, g.x + 1.7, g.z + 1.5, g.y, g.y + 0.3, WHITE)
	L._ksolid(k, hub.x - 2.6, hub.z - 1.8, hub.x + 2.6, hub.z + 1.8, hub.y - 1.8, hub.y + 1.8, STEEL)
	# A-frame legs either side, splayed along the ring's plane.
	for side: float in [-1.0, 1.0]:
		for s: float in [-1.0, 1.0]:
			L._kbeam(k, Vector3(c.x + side * 7.0, 0.0, c.y + s * 15.0), hub + Vector3(side * 2.6, 0, 0), 1.1, 1.1, STEEL)
		L._ksolid(k, c.x + side * 7.0 - 2.0, c.y - 18.0, c.x + side * 7.0 + 2.0, c.y + 18.0, 0.0, 1.0,
			Color(0.6, 0.59, 0.56))
	# Boarding platform under the bottom of the ring.
	L._ksolid(k, c.x - 5.0, c.y - 6.0, c.x + 5.0, c.y + 6.0, 0.0, 1.6, Color(0.55, 0.55, 0.57))
	L.reserved.append(r)


# ------------------------------------------------------ container yard
## Stacks of shipping containers (1–4 high) in bays with aisles: a low,
## blocky playground for running, vaulting and short swings.
func _container_yard(r: Rect2, rng: RandomNumberGenerator) -> void:
	var k := L._kit("yard")
	var inner := r.grow(-5.0)
	var cl := 12.2
	var cw := 2.44
	var ch := 2.6
	var x := inner.position.x
	while x + cl <= inner.end.x:
		var z := inner.position.y
		var bay := 0
		while z + cw <= inner.end.y:
			var stack := rng.randi_range(0, 4)
			if bay == 0 or rng.randf() < 0.2:
				stack = maxi(stack, 1)
			for s in stack:
				var col: Color = CONTAINER_COLORS[rng.randi() % CONTAINER_COLORS.size()]
				_container(k, x, z, x + cl, z + cw, s * ch, col)
			z += cw + 0.1
			bay += 1
			if bay == 5:
				bay = 0
				z += 4.0  # aisle
		x += cl + 3.5
	# A straddle carrier parked over one row.
	var sx := inner.position.x + cl * 0.5 + rng.randi_range(0, 2) * (cl + 3.5)
	var sz := inner.position.y + 1.2
	for e: float in [-1.0, 1.0]:
		for f: float in [-1.0, 1.0]:
			L._kbeam(k, Vector3(sx + e * 5.0, 0.0, sz + f * 2.2), Vector3(sx + e * 5.0, 12.5, sz + f * 2.2), 0.6, 0.6,
				Color(0.92, 0.68, 0.12))
	L._ksolid(k, sx - 5.6, sz - 2.8, sx + 5.6, sz + 2.8, 12.5, 14.0, Color(0.92, 0.68, 0.12))
	L.reserved.append(r)


## One container: the box, plus darker corner posts (looks only).
func _container(k: Dictionary, x0: float, z0: float, x1: float, z1: float, y0: float, col: Color) -> void:
	L._ksolid(k, x0, z0, x1, z1, y0 + 0.15, y0 + 2.6 + 0.15, col)
	var dark := col.darkened(0.35)
	for p: Vector2 in [Vector2(x0, z0), Vector2(x1, z0), Vector2(x1, z1), Vector2(x0, z1)]:
		var q := Vector2(p.x + (0.12 if p.x == x0 else -0.12), p.y + (0.12 if p.y == z0 else -0.12))
		L._kbeam(k, Vector3(q.x, y0 + 0.15, q.y), Vector3(q.x, y0 + 2.75, q.y), 0.26, 0.26, dark, false)
	for f: float in [0.25, 0.5, 0.75]:
		var cx := lerpf(x0, x1, f)
		L._kbeam(k, Vector3(cx, y0 + 0.3, z0 - 0.01), Vector3(cx, y0 + 2.6, z0 - 0.01), 0.1, 0.04, dark, false)
		L._kbeam(k, Vector3(cx, y0 + 0.3, z1 + 0.01), Vector3(cx, y0 + 2.6, z1 + 0.01), 0.1, 0.04, dark, false)


# ------------------------------------------------------------ ship
## Cargo ship moored in a dock basin, bow to the east: hull, deck
## containers (a gap left under the quay crane's hanging load), a stern
## bridge with wings and funnel, and two derricks whose booms are anchors.
func ship(basin: Rect2) -> void:
	if not basin.grow(8.0).has_point(SHIP_AT):
		return
	var rng := RandomNumberGenerator.new()
	rng.seed = hash("ship")
	var k := L._kit("ship")
	var c := basin.get_center()
	var length := basin.size.x - 12.0
	var beam := 14.0
	var x0 := c.x - length * 0.5 + 2.0
	var x1 := c.x + length * 0.5
	var bow := x1 - 12.0
	var deck := 6.5
	var hull := PackedVector2Array([Vector2(x0, c.y - beam * 0.5), Vector2(bow, c.y - beam * 0.5), Vector2(x1, c.y),
		Vector2(bow, c.y + beam * 0.5), Vector2(x0, c.y + beam * 0.5)])
	L._kprism(k, hull, -3.5, deck, Color(0.16, 0.2, 0.26))
	var band := PackedVector2Array([Vector2(x0 - 0.05, c.y - beam * 0.5 - 0.05), Vector2(bow, c.y - beam * 0.5 - 0.05),
		Vector2(x1 + 0.08, c.y), Vector2(bow, c.y + beam * 0.5 + 0.05), Vector2(x0 - 0.05, c.y + beam * 0.5 + 0.05)])
	L._kprism(k, band, -1.7, -0.9, Color(0.62, 0.12, 0.1))  # red boot-top at the waterline
	# Bridge house aft.
	L._ksolid(k, x0 + 1.0, c.y - 6.0, x0 + 12.0, c.y + 6.0, deck, deck + 9.0, WHITE)
	L._ksolid(k, x0 + 7.0, c.y - 7.5, x0 + 12.0, c.y + 7.5, deck + 9.0, deck + 12.0, WHITE)  # wheelhouse + wings
	L._ksolid(k, x0 + 7.4, c.y - 7.0, x0 + 11.6, c.y + 7.0, deck + 9.8, deck + 11.2, Color(0.15, 0.2, 0.25), false)
	L._ksolid(k, x0 + 2.0, c.y - 1.8, x0 + 5.6, c.y + 1.8, deck + 9.0, deck + 16.0, Color(0.12, 0.12, 0.13))  # funnel
	L._ksolid(k, x0 + 1.9, c.y - 1.9, x0 + 5.7, c.y + 1.9, deck + 13.0, deck + 14.2, RED, false)
	# Containers on deck, in rows across the ship; clear under the quay crane's load.
	var keep_out := []
	for s in L.structures:
		if s["type"] == "quay_crane" and absf(float(s["z"]) - c.y) < beam:
			var tx: float = float(s["x"]) + float(s["reach"]) * 0.6
			keep_out.append(Vector2(tx - 8.0, tx + 8.0))
	var x := x0 + 14.0
	while x + 6.1 < bow - 1.0:
		var blocked := false
		for ko in keep_out:
			if x + 6.1 > ko.x and x < ko.y:
				blocked = true
		if not blocked:
			var z := c.y - 6.1
			while z + 2.44 <= c.y + 6.1:
				var tiers := rng.randi_range(1, 3)
				for t in tiers:
					_container(k, x, z, x + 6.1, z + 2.44, deck + t * 2.6 - 0.15, CONTAINER_COLORS[rng.randi() % CONTAINER_COLORS.size()])
				z += 2.44 + 0.05
		x += 6.1 + 0.6
	# Derricks: masts with booms angled out over the quay side.
	for mx: float in [x0 + 20.0, bow - 6.0]:
		var foot := Vector3(mx, deck, c.y)
		var top := foot + Vector3.UP * 18.0
		L._kbeam(k, foot, top, 0.8, 0.8, Color(0.85, 0.65, 0.15))
		var tip := foot + Vector3(-4.0, 13.0, -11.0)
		L._kbeam(k, foot + Vector3.UP * 2.0, tip, 0.5, 0.5, Color(0.85, 0.65, 0.15))
		L._kbeam(k, top, tip, 0.08, 0.08, STEEL, false)
		L._anchor(foot + Vector3.UP * 2.0 + (tip - foot - Vector3.UP * 2.0) * 0.3, tip)
	# Bow mast with a light.
	L._kbeam(k, Vector3(bow + 2.0, deck, c.y), Vector3(bow + 2.0, deck + 8.0, c.y), 0.3, 0.3, WHITE)


## Point `t` metres along a polyline (clamped).
static func _at(path: PackedVector2Array, t: float) -> Vector2:
	var acc := 0.0
	for i in path.size() - 1:
		var L2 := path[i].distance_to(path[i + 1])
		if t <= acc + L2:
			return path[i].lerp(path[i + 1], clampf((t - acc) / maxf(L2, 0.001), 0.0, 1.0))
		acc += L2
	return path[-1]


# ---------------------------------------------------------- lighthouse
## Lighthouse on a stone pier in the river at the dock entrance: a tapering
## white-and-red tower, a gallery to land on (its rim is an anchor ring)
## and the lantern. A jetty runs back to the promenade.
func lighthouse() -> void:
	var k := L._kit("lighthouse")
	var c := LIGHTHOUSE_AT
	L._kprism(k, _ngon(c, 9.0, 12), -4.0, 2.2, Color(0.5, 0.47, 0.42))
	L._ksolid(k, c.x + 6.0, c.y - 2.2, CityLayout.RIVER_EDGE, c.y + 2.2, 0.6, 1.4, Color(0.42, 0.36, 0.3))  # jetty
	var y := 2.2
	var r := 5.2
	for band in 8:
		var y1 := y + 5.5
		var r1 := r - 0.3
		var col := WHITE if band % 2 == 0 else RED
		L._kprism(k, _ngon(c, (r + r1) * 0.5, 12), y, y1, col)
		y = y1
		r = r1
	L._kprism(k, _ngon(c, r + 2.2, 12), y, y + 0.6, Color(0.2, 0.22, 0.24))  # gallery floor
	var ring := _ngon(c, r + 2.0, 12)
	for i in ring.size():
		var a: Vector2 = ring[i]
		var b: Vector2 = ring[(i + 1) % ring.size()]
		L._kbeam(k, Vector3(a.x, y + 1.6, a.y), Vector3(b.x, y + 1.6, b.y), 0.08, 0.08, STEEL, false)  # railing
		L._anchor(Vector3(a.x, y - 0.2, a.y), Vector3(b.x, y - 0.2, b.y))
	L._kprism(k, _ngon(c, r - 0.8, 12), y + 0.6, y + 4.6, Color(0.95, 0.9, 0.6))  # lantern
	L._kprism(k, _ngon(c, r - 0.4, 12), y + 4.6, y + 5.4, RED.darkened(0.2))
	L._kprism(k, _ngon(c, 1.2, 8), y + 5.4, y + 7.4, RED.darkened(0.3))


static func _ngon(c: Vector2, r: float, n: int) -> PackedVector2Array:
	var out := PackedVector2Array()
	for i in n:
		var a := TAU * (i + 0.5) / n
		out.append(c + Vector2(cos(a), sin(a)) * r)
	return out
