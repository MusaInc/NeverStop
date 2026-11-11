class_name Arena
extends Node3D
## Battle arenas: ten cars, one surface high above the city, last car on it
## wins. Two of them, both built from the city layout at start-up:
##
##   SKY      ("Sky Arena") a floating disc 64 m across hovering over a
##            low-rise block on the edge of downtown, the towers all round.
##   ROOFTOPS ("Rooftop Rumble") steel decks on top of five of the tallest
##            business towers, linked by open girder bridges (ramps where the
##            towers differ in height).
##
## No rails anywhere: off the edge is out. A car whose centre drops KO_DROP
## under the lowest deck is knocked out (credit to whoever hit it last, if
## that was in the last few seconds) and falls into the streets for real.
##
## Rivals are the player's own garage cars, driven by AIDriver aimed at a
## victim (direct pursuit, rams on) with an edge sense on top: they look
## ahead along their velocity and brake / turn in rather than drive off,
## unless they're carrying a hit. On the rooftops they route deck to deck
## across the bridges.

signal knocked_out(car: Car, by: Car, place: int)
signal finished(winner: Car)

enum Kind { SKY, ROOFTOPS }

const KO_DROP := 7.0
const CREDIT_WINDOW := 4.0
const N_CARS := 10
const SKY_R := 32.0
const SKY_H := 2.4
const SKY_ALT := 72.0       # metres above the street
const BRIDGE_W := 8.0
const DECK_MARGIN := 3.5
const DECK_T := 1.2
const RAISE := 24.0          # most a rooftop deck stands above its roof

var kind := Kind.SKY
var layout: CityLayout
## Walkable pieces: {type:"disc"|"deck"|"bridge", xf:Transform3D (top-centre, deck
## frame), half:Vector2 (x/z half size; disc: radius in x), id}
var pieces: Array = []
var decks: Array = []          # indices into pieces (graph nodes)
var links: Array = []          # [deck a, deck b, bridge piece index, end on a, end on b]
var floor_y := 0.0             # lowest deck top
var centre := Vector3.ZERO
var built := false
var cars: Array = []           # every car in the battle, the player first
var alive: Array = []
var bots := {}                 # car instance id -> Bot
var kos := {}                  # car instance id -> knockouts made
var out_order: Array = []      # cars in the order they went out
var player: Car
var running := false
var time := 0.0
var countdown := 0.0		   # 3-2-1: everyone held on the brakes
const COUNTDOWN := 3.0
var rng := RandomNumberGenerator.new()
var _fallen: Array = []        # [car, seconds since KO]
var _body: StaticBody3D
var _slots: Array = []
var _touch_t := 0.0
static var _shader: Shader


func build(p_layout: CityLayout, p_kind: int) -> Arena:
	layout = p_layout
	kind = p_kind
	name = "Arena"
	_body = StaticBody3D.new()
	_body.collision_layer = 1 | (1 << 3)
	_body.collision_mask = 0
	add_child(_body)
	if kind == Kind.SKY:
		_build_sky()
	else:
		_build_rooftops()
	built = true
	return self


# ------------------------------------------------------------------ geometry

## Where the disc floats: the open spot nearest downtown whose buildings
## all stay well under it (so it reads as floating, with the towers around).
func _sky_site() -> Vector3:
	var grid := layout._building_grid()
	var best := Vector3(330, 0, -60)
	var best_s := INF
	var c0 := Vector3(CityLayout.CBD_CENTER.x, 0.0, CityLayout.CBD_CENTER.y)
	for gx in range(-14, 15):
		for gz in range(-14, 15):
			var p := c0 + Vector3(gx * 22.0, 0.0, gz * 22.0)
			if layout.is_water(p) or not layout.island.has_point(Vector2(p.x, p.z)):
				continue
			var g := layout.ground_y(p.x, p.z)
			var top := g + SKY_ALT
			var clear := true
			for k in 32:
				var a := TAU * k / 32.0
				for rr: float in [0.0, SKY_R * 0.35, SKY_R * 0.7, SKY_R, SKY_R + 8.0]:
					var q := p + Vector3(cos(a), 0.0, sin(a)) * rr
					for bd in grid.get(Vector2i(floori(q.x / 50.0), floori(q.z / 50.0)), []):
						for yy: float in [top - 22.0, top - 8.0, top + 4.0, top + 30.0]:
							if layout.inside(bd, Vector3(q.x, yy, q.z), 4.0):
								clear = false
								break
						if not clear:
							break
					if not clear:
						break
				if not clear:
					break
			if not clear:
				continue
			var s := p.distance_to(c0)
			if s < best_s:
				best_s = s
				best = Vector3(p.x, top, p.z)
	return best


func _build_sky() -> void:
	var at := _sky_site()
	centre = at
	floor_y = at.y
	var xf := Transform3D(Basis(), at)
	pieces.append({"type": "disc", "xf": xf, "half": Vector2(SKY_R, SKY_R)})
	decks.append(0)
	# Collision: one cylinder, top flush with `at`.
	var cs := CollisionShape3D.new()
	var cyl := CylinderShape3D.new()
	cyl.radius = SKY_R
	cyl.height = SKY_H
	cs.shape = cyl
	cs.position = at - Vector3.UP * SKY_H * 0.5
	_body.add_child(cs)
	# Top: a disc with the arena markings (shader), then the hull under it.
	var top := MeshInstance3D.new()
	var tm := CylinderMesh.new()
	tm.top_radius = SKY_R
	tm.bottom_radius = SKY_R
	tm.height = SKY_H
	tm.radial_segments = 48
	tm.rings = 1
	top.mesh = tm
	top.material_override = _deck_mat(0, Vector2(SKY_R, SKY_R))
	top.position = at - Vector3.UP * SKY_H * 0.5
	add_child(top)
	var hull := MeshInstance3D.new()
	var hm := CylinderMesh.new()
	hm.top_radius = SKY_R - 0.4
	hm.bottom_radius = SKY_R * 0.3
	hm.height = 13.0
	hm.radial_segments = 24
	hm.rings = 1
	hull.mesh = hm
	hull.material_override = _metal(Color(0.16, 0.17, 0.19))
	hull.position = at - Vector3.UP * (SKY_H + 6.5)
	add_child(hull)
	# Glowing rim and thrusters (emissive only: no lights, cheap on phones).
	var rim := MeshInstance3D.new()
	var rm := TorusMesh.new()
	rm.inner_radius = SKY_R - 0.35
	rm.outer_radius = SKY_R + 0.25
	rm.rings = 64
	rm.ring_segments = 6
	rim.mesh = rm
	rim.material_override = _glow(Color(1.0, 0.62, 0.12), 2.5)
	rim.position = at - Vector3.UP * 0.9
	rim.name = "Rim"
	add_child(rim)
	for k in 6:
		var a := TAU * k / 6.0 + 0.3
		var pod := MeshInstance3D.new()
		var pm := CylinderMesh.new()
		pm.top_radius = 2.4
		pm.bottom_radius = 1.6
		pm.height = 3.0
		pm.radial_segments = 12
		pod.mesh = pm
		pod.material_override = _metal(Color(0.24, 0.25, 0.28))
		pod.position = at + Vector3(cos(a) * SKY_R * 0.62, -SKY_H - 4.0, sin(a) * SKY_R * 0.62)
		add_child(pod)
		var jet := MeshInstance3D.new()
		var jm := CylinderMesh.new()
		jm.top_radius = 1.4
		jm.bottom_radius = 0.2
		jm.height = 5.0
		jm.radial_segments = 12
		jet.mesh = jm
		jet.material_override = _glow(Color(0.35, 0.75, 1.0), 3.0, true)
		jet.position = pod.position - Vector3.UP * 4.0
		add_child(jet)
	var core := MeshInstance3D.new()
	var co := SphereMesh.new()
	co.radius = 3.5
	co.height = 5.0
	core.mesh = co
	core.material_override = _glow(Color(0.35, 0.75, 1.0), 4.0)
	core.position = at - Vector3.UP * (SKY_H + 13.0)
	add_child(core)


## Five tall towers close together, decked over and bridged.
func _build_rooftops() -> void:
	var grid := layout._building_grid()
	var cands: Array = []   # [b, centre2, deck xf, half, deck_y]
	var cbd := CityLayout.CBD_CENTER
	for b in layout.buildings:
		if b["kind"] != "normal":
			continue
		var c2: Vector2 = layout.base_center(b)
		if c2.distance_to(cbd) > 300.0:
			continue
		var roof := BuildingMesher.roof_y(b)
		if roof < 170.0:
			continue
		var t: Array = b["tiers"][-1]
		var X := CityLayout.bxf(b)
		var lc := Vector3((float(t[0]) + float(t[2])) * 0.5, 0.0, (float(t[1]) + float(t[3])) * 0.5)
		var half := Vector2(maxf((float(t[2]) - float(t[0])) * 0.5 + DECK_MARGIN, 13.0),
			maxf((float(t[3]) - float(t[1])) * 0.5 + DECK_MARGIN, 13.0))
		if half.x > 22.0 or half.y > 22.0:
			continue  # a deck wider than its roof: a car off the edge must drop past the roof
		var lo := roof + 3.5
		var w := X * lc
		var dxf := Transform3D(X.basis.orthonormalized(), Vector3(w.x, lo, w.z))
		# Nothing else (a spire, a taller neighbour, a crown) in the deck's
		# space, at any height it might be raised to.
		if not _box_clear(grid, dxf, half, 0.5, RAISE + 8.0, [b]):
			continue
		cands.append([b, Vector2(w.x, w.z), dxf, half, lo])
	# Grow the best cluster: from each seed, keep adding the nearest tower a
	# clear bridge reaches from one already chosen. Decks may stand up to
	# RAISE m over their roof on a steel frame, so neighbours of different
	# heights still meet with a gentle ramp.
	var best: Array = []
	var best_links: Array = []
	var best_ys := {}
	for si in cands.size():
		var ys := {si: float(cands[si][4]) + RAISE * 0.5}
		var chosen: Array = [si]
		var lk: Array = []
		while chosen.size() < 5:
			var pick := -1
			var pick_d := INF
			var pick_from := -1
			var pick_y := 0.0
			for ci in cands.size():
				if ci in chosen:
					continue
				for hi in chosen:
					var d: float = (cands[ci][1] as Vector2).distance_to(cands[hi][1])
					if d < 30.0 or d > 82.0 or d >= pick_d:
						continue
					var y := clampf(float(ys[hi]), float(cands[ci][4]), float(cands[ci][4]) + RAISE)
					if _bridge_ok(grid, _at_y(cands[hi], ys[hi]), _at_y(cands[ci], y)):
						pick = ci
						pick_d = d
						pick_from = hi
						pick_y = y
			if pick < 0:
				break
			chosen.append(pick)
			ys[pick] = pick_y
			lk.append([pick_from, pick])
		# Most decks (up to five), then the highest: the top of the business district.
		var better := chosen.size() > best.size()
		if chosen.size() == best.size() and not best.is_empty():
			better = _mean_y(ys, chosen) > _mean_y(best_ys, best)
		if better:
			best = chosen
			best_links = lk
			best_ys = ys
	for ci in best:
		cands[ci] = _at_y(cands[ci], best_ys[ci])
	# One extra link where a pair close enough is clear (loops = escape routes).
	for i in best.size():
		for j in range(i + 1, best.size()):
			var a: int = best[i]
			var b2: int = best[j]
			var have := false
			for l in best_links:
				if (l[0] == a and l[1] == b2) or (l[0] == b2 and l[1] == a):
					have = true
			if have or best_links.size() >= best.size() + 1:
				continue
			var d2: float = (cands[a][1] as Vector2).distance_to(cands[b2][1])
			if d2 < 82.0 and d2 > 30.0 and _bridge_ok(grid, cands[a], cands[b2]):
				best_links.append([a, b2])
	var idx := {}
	floor_y = INF
	for ci in best:
		var cd: Array = cands[ci]
		idx[ci] = pieces.size()
		decks.append(pieces.size())
		pieces.append({"type": "deck", "xf": cd[2], "half": cd[3]})
		floor_y = minf(floor_y, cd[4])
		_deck_geometry(cd[2], cd[3], cd[4] - BuildingMesher.roof_y(cd[0]))
	for l in best_links:
		var A: Array = cands[l[0]]
		var B: Array = cands[l[1]]
		var ends := _bridge_ends(A, B)
		var bi := pieces.size()
		_bridge_geometry(ends[0], ends[1])
		links.append([idx[l[0]], idx[l[1]], bi, ends[0], ends[1]])
	var sum := Vector3.ZERO
	for di in decks:
		sum += (pieces[di]["xf"] as Transform3D).origin
	centre = sum / maxf(decks.size(), 1)
	print("Arena rooftops: %d decks, %d bridges, floor %.0f m" % [decks.size(), links.size(), floor_y])


## A candidate deck moved to height y.
func _at_y(c: Array, y: float) -> Array:
	var xf: Transform3D = c[2]
	xf.origin.y = y
	return [c[0], c[1], xf, c[3], y]


func _mean_y(ys: Dictionary, set: Array) -> float:
	var s := 0.0
	for i in set:
		s += float(ys[i])
	return s / maxf(set.size(), 1)


## Space above a deck (half extents, from y0 to y1 over its top) is empty.
func _box_clear(grid: Dictionary, xf: Transform3D, half: Vector2, y0: float, y1: float, own: Array) -> bool:
	for ix in 5:
		for iz in 5:
			var lp := Vector3(lerpf(-half.x, half.x, ix / 4.0), 0.0, lerpf(-half.y, half.y, iz / 4.0))
			var p := xf * lp
			for bd in grid.get(Vector2i(floori(p.x / 50.0), floori(p.z / 50.0)), []):
				if own.any(func(o): return is_same(o, bd)):
					continue
				if _central_spire(bd, xf, half):
					continue  # a mast through the middle of the deck: a pillar to fight round
				for yy in [y0, (y0 + y1) * 0.5, y1]:
					if layout.inside(bd, Vector3(p.x, xf.origin.y + yy, p.z), 0.5):
						return false
	return true


## A thin spire standing in the middle of a deck (well clear of its edges).
func _central_spire(bd: Dictionary, xf: Transform3D, half: Vector2) -> bool:
	if bd["kind"] != "spire":
		return false
	var t: Array = bd["tiers"][0]
	if maxf(float(t[2]) - float(t[0]), float(t[3]) - float(t[1])) > 9.0:
		return false
	var c: Vector2 = CityLayout.base_center(bd)
	var lp := xf.affine_inverse() * Vector3(c.x, xf.origin.y, c.y)
	return absf(lp.x) < half.x - 8.0 and absf(lp.z) < half.y - 8.0


## Where a bridge from deck A to deck B leaves each deck (1.5 m inside it).
func _bridge_ends(A: Array, B: Array) -> Array:
	var pa := _edge_point(A[2], A[3], (B[2] as Transform3D).origin)
	var pb := _edge_point(B[2], B[3], (A[2] as Transform3D).origin)
	return [pa, pb]


func _edge_point(xf: Transform3D, half: Vector2, toward: Vector3) -> Vector3:
	var d := toward - xf.origin
	d.y = 0.0
	d = d.normalized()
	var ld := xf.basis.inverse() * d
	var tx := half.x / maxf(absf(ld.x), 0.001)
	var tz := half.y / maxf(absf(ld.z), 0.001)
	var t := minf(tx, tz) - 1.5
	return xf.origin + d * t


func _bridge_ok(grid: Dictionary, A: Array, B: Array) -> bool:
	var ends := _bridge_ends(A, B)
	var pa: Vector3 = ends[0]
	var pb: Vector3 = ends[1]
	var flat := Vector2(pb.x - pa.x, pb.z - pa.z).length()
	if flat < 4.0 or absf(pb.y - pa.y) / flat > 0.2:
		return false
	# The open span (between the two decks) must be clear of every building.
	var dir := (pb - pa).normalized()
	var side := Vector3(-dir.z, 0.0, dir.x).normalized()
	var n := int(flat / 2.0) + 1
	for i in n + 1:
		var p := pa.lerp(pb, float(i) / n)
		for s: float in [-0.5, 0.0, 0.5]:
			var q := p + side * BRIDGE_W * s
			for bd in grid.get(Vector2i(floori(q.x / 50.0), floori(q.z / 50.0)), []):
				if is_same(bd, A[0]) or is_same(bd, B[0]):
					continue
				for yy: float in [-1.5, 1.0, 5.0]:
					if layout.inside(bd, Vector3(q.x, q.y + yy, q.z), 0.5):
						return false
	return true


func _deck_geometry(xf: Transform3D, half: Vector2, stilt: float) -> void:
	var size := Vector3(half.x * 2.0, DECK_T, half.y * 2.0)
	var cxf := Transform3D(xf.basis, xf.origin - Vector3.UP * DECK_T * 0.5)
	var cs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = size
	cs.shape = box
	cs.transform = cxf
	_body.add_child(cs)
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = size
	mi.mesh = bm
	mi.material_override = _deck_mat(1, half)
	mi.transform = cxf
	add_child(mi)
	# Steel frame down to the roof: four legs and cross beams (inset, so a
	# car going over the edge clears it).
	var legs := Vector2(half.x - DECK_MARGIN - 1.0, half.y - DECK_MARGIN - 1.0)
	var steel := _metal(Color(0.2, 0.21, 0.23))
	for sx in [-1.0, 1.0]:
		for sz in [-1.0, 1.0]:
			var leg := MeshInstance3D.new()
			var lm := BoxMesh.new()
			lm.size = Vector3(0.7, stilt + 1.0, 0.7)
			leg.mesh = lm
			leg.material_override = steel
			leg.transform = Transform3D(xf.basis, xf * Vector3(sx * legs.x, -(stilt + 1.0) * 0.5, sz * legs.y))
			add_child(leg)
	# Ring beams every 6 m down a tall frame.
	var yb := -6.0
	while yb > -stilt + 1.0:
		for e in 4:
			var horiz := e < 2
			var s := 1.0 if e % 2 == 0 else -1.0
			var beam := MeshInstance3D.new()
			var bmm := BoxMesh.new()
			bmm.size = Vector3(legs.x * 2.0, 0.45, 0.45) if horiz else Vector3(0.45, 0.45, legs.y * 2.0)
			beam.mesh = bmm
			beam.material_override = steel
			var lp := Vector3(0.0, yb, s * legs.y) if horiz else Vector3(s * legs.x, yb, 0.0)
			beam.transform = Transform3D(xf.basis, xf * lp)
			add_child(beam)
		yb -= 6.0
	var under := MeshInstance3D.new()
	var um := BoxMesh.new()
	um.size = Vector3(half.x * 2.0 - 1.0, 0.6, half.y * 2.0 - 1.0)
	under.mesh = um
	under.material_override = steel
	under.transform = Transform3D(xf.basis, xf.origin - Vector3.UP * (DECK_T + 0.3))
	add_child(under)
	# Edge lights.
	var glow := _glow(Color(1.0, 0.62, 0.12), 2.2)
	for e in 4:
		var horiz := e < 2
		var s := 1.0 if e % 2 == 0 else -1.0
		var strip := MeshInstance3D.new()
		var sm := BoxMesh.new()
		sm.size = Vector3(half.x * 2.0 + 0.2, 0.18, 0.2) if horiz else Vector3(0.2, 0.18, half.y * 2.0 + 0.2)
		strip.mesh = sm
		strip.material_override = glow
		var lp := Vector3(0.0, -0.35, s * (half.y + 0.05)) if horiz else Vector3(s * (half.x + 0.05), -0.35, 0.0)
		strip.transform = Transform3D(xf.basis, xf * lp)
		add_child(strip)


func _bridge_geometry(pa: Vector3, pb: Vector3) -> void:
	var d := pb - pa
	var flat := Vector3(d.x, 0.0, d.z)
	var length := d.length()
	var basis := Basis.looking_at(d.normalized(), Vector3.UP)
	# Bridge: local -Z along the span; top surface through pa..pb.
	var mid := (pa + pb) * 0.5
	var bxf := Transform3D(basis, mid)
	pieces.append({"type": "bridge", "xf": bxf, "half": Vector2(BRIDGE_W * 0.5, length * 0.5), "flat": flat.length()})
	var t := 0.8
	var cxf := Transform3D(basis, mid - basis.y * t * 0.5)
	var cs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(BRIDGE_W, t, length)
	cs.shape = box
	cs.transform = cxf
	_body.add_child(cs)
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = Vector3(BRIDGE_W, t, length)
	mi.mesh = bm
	mi.material_override = _deck_mat(2, Vector2(BRIDGE_W * 0.5, length * 0.5))
	mi.transform = cxf
	add_child(mi)
	# Girders under each edge, a truss of diagonals between them.
	var steel := _metal(Color(0.55, 0.16, 0.1))
	for s in [-1.0, 1.0]:
		var g := MeshInstance3D.new()
		var gm := BoxMesh.new()
		gm.size = Vector3(0.5, 1.6, length)
		g.mesh = gm
		g.material_override = steel
		g.transform = Transform3D(basis, mid + basis.x * s * (BRIDGE_W * 0.5 - 0.35) - basis.y * (t + 0.8))
		add_child(g)
	var n := int(length / 5.0)
	for i in n:
		var z := -length * 0.5 + (i + 0.5) * length / n
		var cb := MeshInstance3D.new()
		var cm := BoxMesh.new()
		cm.size = Vector3(BRIDGE_W - 0.8, 0.3, 0.3)
		cb.mesh = cm
		cb.material_override = steel
		cb.transform = Transform3D(basis, mid + basis.z * z - basis.y * (t + 1.3))
		add_child(cb)
	var glow := _glow(Color(1.0, 0.62, 0.12), 2.2)
	for s in [-1.0, 1.0]:
		var strip := MeshInstance3D.new()
		var sm := BoxMesh.new()
		sm.size = Vector3(0.18, 0.16, length)
		strip.mesh = sm
		strip.material_override = glow
		strip.transform = Transform3D(basis, mid + basis.x * s * (BRIDGE_W * 0.5 + 0.05) - basis.y * 0.3)
		add_child(strip)


# ------------------------------------------------------------------ materials

func _deck_mat(shape: int, half: Vector2) -> Material:
	if _shader == null:
		_shader = Shader.new()
		_shader.code = DECK_SHADER
	var m := ShaderMaterial.new()
	m.shader = _shader
	m.set_shader_parameter("shape", shape)
	m.set_shader_parameter("half_size", half)
	return m


func _metal(c: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = c
	m.metallic = 0.6
	m.roughness = 0.45
	return m


func _glow(c: Color, e: float, fade := false) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.albedo_color = c * e if not fade else Color(c.r * e, c.g * e, c.b * e, 0.55)
	if fade:
		m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		m.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
		m.cull_mode = BaseMaterial3D.CULL_DISABLED
	return m


## Arena surface: dark grippy deck, a hazard band round the edge (the drop),
## faint panel seams, and the centre ring. shape 0 disc / 1 deck / 2 bridge.
const DECK_SHADER := """
shader_type spatial;
render_mode cull_back;
uniform int shape = 0;
uniform vec2 half_size = vec2(30.0);
varying vec3 lp;
varying vec3 ln;
void vertex() { lp = VERTEX; ln = NORMAL; }
float hash(vec2 p) { return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453); }
void fragment() {
	vec3 base = vec3(0.13, 0.135, 0.15);
	if (ln.y < 0.5) {
		ALBEDO = vec3(0.17, 0.18, 0.2);
		METALLIC = 0.5;
		ROUGHNESS = 0.5;
	} else {
		vec2 p = lp.xz;
		float n = hash(floor(p * 3.0)) * 0.03;
		vec3 col = base + n;
		float edge;
		float along;
		if (shape == 0) {
			edge = half_size.x - length(p);
			along = atan(p.y, p.x) * half_size.x;
		} else if (shape == 1) {
			vec2 e = half_size - abs(p);
			edge = min(e.x, e.y);
			along = (e.x < e.y) ? p.y : p.x;
		} else {
			edge = half_size.x - abs(p.x);
			along = p.y;
		}
		// Panel seams.
		vec2 g = abs(fract(p / 4.0) - 0.5);
		col *= 1.0 - 0.18 * step(0.48, max(g.x, g.y));
		// Hazard band: amber / black chevrons along the edge.
		if (edge < 1.6) {
			float s = step(0.5, fract((along + edge) / 2.2));
			col = mix(vec3(0.02), vec3(0.95, 0.6, 0.06), s);
		} else if (edge < 2.0) {
			col = vec3(0.85);
		}
		// Centre ring (disc / decks).
		if (shape != 2) {
			float r = length(p);
			float ring = min(half_size.x, half_size.y) * 0.32;
			if (abs(r - ring) < 0.35) col = vec3(0.85, 0.12, 0.1);
			if (r < 1.2) col = vec3(0.85);
		} else if (abs(p.x) < 0.15 && fract(p.y / 4.0) < 0.5) {
			col = vec3(0.8);
		}
		ALBEDO = col;
		ROUGHNESS = 0.82;
	}
}
"""


# ------------------------------------------------------------------ queries

## Index of the piece under p (within `slack` m of its top), or -1.
func piece_at(p: Vector3, inset := 0.0, slack := 3.0) -> int:
	for i in pieces.size():
		var pc: Dictionary = pieces[i]
		var xf: Transform3D = pc["xf"]
		var half: Vector2 = pc["half"]
		var lp := xf.affine_inverse() * p
		if lp.y < -slack or lp.y > slack + 2.0:
			continue
		if pc["type"] == "disc":
			if Vector2(lp.x, lp.z).length() < half.x - inset:
				return i
		elif absf(lp.x) < half.x - inset and absf(lp.z) < half.y - inset:
			return i
	return -1


func on_surface(p: Vector3, inset := 0.0) -> bool:
	return piece_at(p, inset) >= 0


## Metres of deck ahead of p along dir before the drop (up to max_d).
func edge_dist(p: Vector3, dir: Vector3, max_d := 45.0) -> float:
	dir.y = 0.0
	dir = dir.normalized()
	var d := 1.5
	while d < max_d:
		var q := p + dir * d
		if piece_at(q, 0.8, 5.0) < 0:
			return d
		d += 1.5
	return max_d


## Deck a car is on or nearest (graph node index into `decks`).
func deck_of(p: Vector3) -> int:
	var pi := piece_at(p)
	if pi >= 0 and decks.has(pi):
		return decks.find(pi)
	var best := 0
	var bd := INF
	for k in decks.size():
		var o := (pieces[decks[k]]["xf"] as Transform3D).origin
		var d := Vector2(p.x - o.x, p.z - o.z).length() + absf(p.y - o.y) * 0.5
		if d < bd:
			bd = d
			best = k
	return best


## First bridge to take from deck a toward deck b: [entry, exit] points, or [] if same deck / no route.
func route(a: int, b: int) -> Array:
	if a == b:
		return []
	var prev := {a: -1}
	var q := [a]
	while not q.is_empty():
		var c: int = q.pop_front()
		if c == b:
			break
		for l in links:
			var di := decks.find(l[0])
			var dj := decks.find(l[1])
			for pair in [[di, dj], [dj, di]]:
				if pair[0] == c and not prev.has(pair[1]):
					prev[pair[1]] = c
					q.append(pair[1])
	if not prev.has(b):
		return []
	var step := b
	while prev[step] != a:
		step = prev[step]
	for l in links:
		var di := decks.find(l[0])
		var dj := decks.find(l[1])
		if di == a and dj == step:
			return [l[3], l[4]]
		if dj == a and di == step:
			return [l[4], l[3]]
	return []


## Start grid: ten slots spread over the arena, facing inward.
func slots() -> Array:
	var out: Array = []
	if kind == Kind.SKY:
		for i in N_CARS:
			var a := TAU * i / N_CARS + PI * 0.5
			var p := centre + Vector3(cos(a), 0.0, sin(a)) * SKY_R * 0.62 + Vector3.UP * 0.6
			out.append(Transform3D(Basis.looking_at((centre - p) * Vector3(1, 0, 1), Vector3.UP), p))
		return out
	if not _slots.is_empty():
		return _slots
	# Rooftops: open spots on each deck (clear of masts and roof plant, well
	# apart), dealt round the decks in turn.
	var grid := layout._building_grid()
	var free: Array = []
	for k in decks.size():
		var pc: Dictionary = pieces[decks[k]]
		var xf: Transform3D = pc["xf"]
		var half: Vector2 = pc["half"]
		var spots: Array = []
		for ix in 5:
			for iz in 5:
				var lp := Vector3(lerpf(-half.x + 4.5, half.x - 4.5, ix / 4.0), 0.6, lerpf(-half.y + 4.5, half.y - 4.5, iz / 4.0))
				var p := xf * lp
				var ok := true
				for bd in grid.get(Vector2i(floori(p.x / 50.0), floori(p.z / 50.0)), []):
					if layout.inside(bd, p + Vector3.UP * 0.8, 3.2):
						ok = false
						break
				if ok:
					spots.append(p)
		spots.sort_custom(func(a, b): return a.distance_to(xf.origin) > b.distance_to(xf.origin))
		free.append(spots)
	var k2 := 0
	var guard := 0
	while out.size() < N_CARS and guard < 400:
		guard += 1
		var spots: Array = free[k2 % free.size()]
		var dk: Transform3D = pieces[decks[k2 % free.size()]]["xf"]
		k2 += 1
		for si in spots.size():
			var p: Vector3 = spots[si]
			if out.any(func(x): return (x as Transform3D).origin.distance_to(p) < 7.5):
				continue
			spots.remove_at(si)
			var look := dk.origin - p
			look.y = 0.0
			if look.length() < 0.5:
				look = -dk.basis.z
			out.append(Transform3D(Basis.looking_at(look.normalized(), Vector3.UP), p))
			break
	_slots = out
	return out


# ------------------------------------------------------------------ the battle

func begin(p_player: Car, rivals: Array, seed := -1, player_bot := false) -> void:
	if seed >= 0:
		rng.seed = seed
	else:
		rng.randomize()
	player = p_player
	cars = [player] + rivals
	alive = cars.duplicate()
	kos.clear()
	out_order.clear()
	bots.clear()
	_fallen.clear()
	time = 0.0
	countdown = COUNTDOWN
	running = true
	var sl := slots()
	for i in cars.size():
		var c: Car = cars[i]
		c.place(sl[i % sl.size()])
		kos[c.get_instance_id()] = 0
		if c == player:
			if not player.impact.is_connected(_on_player_impact):
				player.impact.connect(_on_player_impact)
		if c != player or player_bot:
			var b := Bot.new(c, self)
			b.aggression = rng.randf_range(0.7, 1.0)
			b.reaction = rng.randf_range(0.3, 0.7)
			b.idle = i * 0.08  # a slightly staggered start
			bots[c.get_instance_id()] = b
			if c != player:
				c.impact.connect(_on_bot_impact.bind(c))


## Parked: brakes on (under the 0.5 that means reverse) and the handbrake.
static func _hold(c: Car) -> void:
	c.throttle = 0.0
	c.brake = 0.45
	c.handbrake = true
	c.steer = 0.0


func stop() -> void:
	running = false


func rivals_alive() -> int:
	return alive.size() - (1 if player in alive else 0)


func place_of(c: Car) -> int:
	var i := out_order.find(c)
	return N_CARS - i if i >= 0 else 1


func knockouts(c: Car) -> int:
	return int(kos.get(c.get_instance_id(), 0))


## Puts a car the right way up where it is (or on the nearest deck).
func right_car(c: Car) -> void:
	var p := c.global_position
	if not on_surface(p, 1.0):
		var k := deck_of(p)
		p = (pieces[decks[k]]["xf"] as Transform3D).origin
	var f := -c.global_basis.z
	f.y = 0.0
	if f.length() < 0.1:
		f = Vector3.FORWARD
	c.place(Transform3D(Basis.looking_at(f.normalized(), Vector3.UP), Vector3(p.x, _top_y(p) + 0.8, p.z)))


func _top_y(p: Vector3) -> float:
	var i := piece_at(p, 0.0, 6.0)
	if i < 0:
		return floor_y
	var xf: Transform3D = pieces[i]["xf"]
	var lp := xf.affine_inverse() * p
	lp.y = 0.0
	return (xf * lp).y


func _physics_process(dt: float) -> void:
	# (Keeps going after the player is out: the others fight on behind the results.)
	if cars.is_empty():
		return
	if countdown > 0.0:
		countdown -= dt
		for c: Car in cars:
			_hold(c)
		return
	time += dt
	# Who's touching whom (a slow bulldozing push never fires an impact).
	_touch_t -= dt
	if _touch_t <= 0.0:
		_touch_t = 0.1
		for c: Car in alive:
			if not is_instance_valid(c):
				continue
			for o in c.get_colliding_bodies():
				if o is Car and o != c and (o as Car) in cars:
					c.last_hit_by = o
					c.set_meta("hit_t", time)
	var space := get_world_3d().direct_space_state
	for i in range(alive.size() - 1, -1, -1):
		var c: Car = alive[i]
		if not is_instance_valid(c):
			alive.remove_at(i)
			continue
		# Out: well under the lowest deck, or off every deck and bridge for
		# a moment and below the floor (dropped onto a roof under a deck).
		var cp := c.global_position
		var off := piece_at(cp, 0.0, 4.0) < 0
		var ot: float = c.get_meta("off_t", 0.0)
		ot = ot + dt if off else 0.0
		c.set_meta("off_t", ot)
		if cp.y < floor_y - KO_DROP or (off and ot > 1.2 and cp.y < floor_y - 1.0):
			_knock_out(c)
			continue
		var b: Bot = bots.get(c.get_instance_id())
		if b:
			b.update(dt, space)
	for f in _fallen:
		f[1] += dt
	if alive.size() <= 1 and running:
		running = false
		finished.emit(alive[0] if alive.size() == 1 else null)


func _knock_out(c: Car) -> void:
	alive.erase(c)
	out_order.append(c)
	var by: Car = null
	if c.last_hit_by and is_instance_valid(c.last_hit_by) and c.last_hit_by != c \
			and c.last_hit_by in cars and time - float(c.get_meta("hit_t", -99.0)) < CREDIT_WINDOW:
		by = c.last_hit_by
		kos[by.get_instance_id()] = int(kos.get(by.get_instance_id(), 0)) + 1
	bots.erase(c.get_instance_id())
	if c != player:
		c.throttle = 0.0
		c.steer = 0.0
		_fallen.append([c, 0.0])
	knocked_out.emit(c, by, alive.size() + 1)


## Rivals hit like the player does: a car driven into another at speed
## shoves it (so the bots can push each other, and you, over the edge).
func _on_bot_impact(strength: float, _at: Vector3, _n: Vector3, other: Object, me: Car) -> void:
	if cars.is_empty() or not (other is Car):
		return
	var oc := other as Car
	me.set_meta("hit_t", time)
	var pv := me.vel_before()
	var to := oc.global_position - me.global_position
	to.y = 0.0
	if to.length() < 0.1:
		return
	to = to.normalized()
	var closing := pv.dot(to) - oc.vel_before().dot(to)
	if closing < 5.0 or strength < 3.0:
		return
	oc.last_hit_by = me
	oc.set_meta("hit_t", time)
	var weight := clampf(me.mass / maxf(oc.mass, 1.0), 0.6, 1.6) * float(me.spec.get("ram", 1.0))
	var k := clampf((closing - 5.0) / 22.0, 0.0, 1.0)
	oc.linear_velocity += to * closing * (0.2 + 0.18 * k) * weight + Vector3.UP * (0.8 + 2.0 * k)
	oc.angular_velocity += Vector3(0.0, signf(pv.cross(to).y + 0.001) * (0.6 + 1.6 * k) * weight, 0.0)


func _on_player_impact(_s: float, _at: Vector3, _n: Vector3, other: Object) -> void:
	if running and other is Car:
		player.set_meta("hit_t", time)


func cleanup() -> void:
	running = false
	if player and is_instance_valid(player) and player.impact.is_connected(_on_player_impact):
		player.impact.disconnect(_on_player_impact)
	for c in cars:
		if is_instance_valid(c) and c != player:
			c.queue_free()
	cars.clear()
	alive.clear()
	bots.clear()
	_fallen.clear()


## Rival cars that fell more than a few seconds ago: gone (they've landed in
## the streets by then, the camera never goes back for them).
func _process(_dt: float) -> void:
	for i in range(_fallen.size() - 1, -1, -1):
		var f: Array = _fallen[i]
		var c: Car = f[0]
		if not is_instance_valid(c):
			_fallen.remove_at(i)
		elif f[1] > 9.0 or c.global_position.y < floor_y - 400.0:
			cars.erase(c)
			c.queue_free()
			_fallen.remove_at(i)


## A rival's brain: who to hit, how to get there, and not driving off.
class Bot:
	var car: Car
	var arena: Arena
	var drv: AIDriver
	var target: Car
	var aggression := 0.85
	var reaction := 0.5
	var idle := 0.0
	var _think := 0.0
	var _upside := 0.0
	var _wp_exit := Vector3.INF     # mid-bridge: where we're heading
	var _charge := 0.0              # committed to a hit (edge sense off)
	var _room := 45.0  # deck left ahead (m)
	var _room_t := 0.0

	func _init(c: Car, a: Arena) -> void:
		car = c
		arena = a
		drv = AIDriver.new(c)
		drv.ram = true
		drv.avoid = false
		drv.skill = 0.92

	func update(dt: float, space: PhysicsDirectSpaceState3D) -> void:
		if idle > 0.0:
			idle -= dt
			Arena._hold(car)
			return
		# Upside down / on its side: put it back after a moment (the player gets the same).
		if car.upside_time > 1.6:
			_upside += dt
			if _upside > 0.4:
				arena.right_car(car)
				_upside = 0.0
		_think -= dt
		if _think <= 0.0 or target == null or not (target in arena.alive):
			_think = reaction + randf() * 0.6
			_pick_target()
		if target == null:
			Arena._hold(car)
			return
		var pos := car.global_position
		var tp := target.global_position
		var aim := tp
		var vel := target.linear_velocity
		# Rooftops: get onto the target's deck by the bridges.
		if arena.kind == Kind.ROOFTOPS:
			var here := arena.piece_at(pos)
			var on_bridge: bool = here >= 0 and arena.pieces[here]["type"] == "bridge"
			var my_deck := arena.deck_of(pos)
			var their := arena.deck_of(tp)
			if on_bridge and _wp_exit != Vector3.INF:
				aim = _wp_exit
				vel = Vector3.ZERO
			elif my_deck != their:
				var r := arena.route(my_deck, their)
				if not r.is_empty():
					var entry: Vector3 = r[0]
					var exit: Vector3 = r[1]
					var axis := (exit - entry)
					axis.y = 0.0
					axis = axis.normalized()
					# Line up on the bridge before committing to it.
					var approach := entry - axis * 6.0
					var lat := (pos - entry) - axis * (pos - entry).dot(axis)
					lat.y = 0.0
					if lat.length() < 2.5 and (pos - entry).dot(axis) > -9.0:
						aim = exit + axis * 4.0
						_wp_exit = exit + axis * 4.0
					else:
						aim = approach
						_wp_exit = Vector3.INF
					vel = Vector3.ZERO
			else:
				_wp_exit = Vector3.INF
		drv.direct_target = aim
		drv.direct_vel = vel
		# Only as fast as the deck ahead lets us stop (the bold ones cut it fine).
		_room_t -= dt
		if _room_t <= 0.0:
			_room_t = 0.1
			var hv := car.linear_velocity
			hv.y = 0.0
			var hd := hv if hv.length() > 3.0 else -car.global_basis.z
			_room = arena.edge_dist(pos, hd)
		var decel := 5.5 + 3.5 * aggression
		var v_room := sqrt(2.0 * decel * maxf(0.0, _room - 3.0))
		var base := (25.0 if arena.kind == Kind.SKY else 20.0) * (0.8 + 0.2 * aggression)
		drv.speed_cap = clampf(v_room, 5.0, base)
		drv.update(dt, space)
		# Charging: close and lined up on the target, keep the foot down.
		var to := tp - pos
		to.y = 0.0
		var fwd := -car.global_basis.z
		fwd.y = 0.0
		var lined := to.length() < 14.0 and fwd.normalized().dot(to.normalized()) > 0.8 and aim == tp \
			and to.length() < _room + 3.0 * aggression
		_charge = 0.6 if lined else maxf(0.0, _charge - dt)
		if _charge > 0.0:
			car.throttle = 1.0
			car.brake = 0.0
		_edge_sense()

	## Look ahead along the velocity: if that point is off the arena, brake
	## and steer for the middle (unless mid-charge on a target near us).
	func _edge_sense() -> void:
		var pos := car.global_position
		var v := car.linear_velocity
		v.y = 0.0
		var sp := v.length()
		var look := 2.5 + sp * (0.55 + 0.25 * (1.0 - aggression))
		var dir := v.normalized() if sp > 1.0 else -car.global_basis.z
		dir.y = 0.0
		var ahead := pos + dir.normalized() * look
		var nose := pos - car.global_basis.z * 3.5
		var safe_ahead := arena.on_surface(ahead, 1.0)
		var safe_nose := arena.on_surface(nose, 0.6)
		if safe_ahead and safe_nose:
			return
		if _charge > 0.0 and target and target.global_position.distance_to(pos) < 7.0 and safe_nose and sp < 14.0:
			return
		# Toward the middle of whatever we're on.
		var pi := arena.piece_at(pos, 0.0, 4.0)
		var mid: Vector3 = (arena.pieces[pi]["xf"] as Transform3D).origin if pi >= 0 else arena.centre
		if pi >= 0 and arena.pieces[pi]["type"] == "bridge":
			# On a bridge the middle is the centre line, ahead.
			var bx: Transform3D = arena.pieces[pi]["xf"]
			var along := -bx.basis.z
			mid = bx.origin + along * (pos - bx.origin).dot(along) + along * signf(along.dot(dir) + 0.001) * 8.0
		var to := mid - pos
		to.y = 0.0
		var fwd := -car.global_basis.z
		fwd.y = 0.0
		var ang := fwd.normalized().signed_angle_to(to.normalized(), Vector3.UP)
		var going_fwd := car.forward_speed > 0.0
		if not safe_nose and car.forward_speed > -1.0:
			# Nose over the edge: back off it, steering to swing the nose in.
			car.throttle = 0.0
			car.brake = 1.0
			car.steer = clampf(ang * 1.5, -1.0, 1.0)
			car.handbrake = false
			return
		car.steer = clampf(-ang * 1.6, -1.0, 1.0)
		if going_fwd and absf(ang) > 0.5 and sp > 6.0:
			car.throttle = 0.0
			car.brake = clampf(sp / 18.0, 0.3, 1.0)
		else:
			car.throttle = 0.5
			car.brake = 0.0

	func _pick_target() -> void:
		var pos := car.global_position
		var best: Car = null
		var bs := INF
		for c: Car in arena.alive:
			if c == car or not is_instance_valid(c):
				continue
			var d := c.global_position.distance_to(pos)
			# Everybody likes hitting the player a bit more; a car near an
			# edge is a juicier target.
			if c == arena.player:
				d *= 0.85
			if not arena.on_surface(c.global_position, 6.0):
				d *= 0.7
			# Spread out: a car already being hunted by two others is less appealing.
			var hunters := 0
			for b: Bot in arena.bots.values():
				if b != self and b.target == c:
					hunters += 1
			d *= 1.0 + 0.4 * maxf(0.0, hunters - 1.0)
			d += randf() * 10.0
			if d < bs:
				bs = d
				best = c
		target = best
