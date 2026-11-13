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
## Rooftops: which roofs qualify, how links are made.
const ROOF_Y := Vector2(30.0, 260.0)       # roof heights considered (m)
const ROOF_HALF := Vector2(7.0, 30.0)      # roof half sizes considered (m)
const STEEP := 0.4                         # steepest ramp (rise / run)
const NARROW_W := 4.4
const LIP := 0.32                          # parapet lip (BuildingMesher.PARAPET) + a hair
const WEDGE_L := 2.6                       # wedge from the roof up to a link's end
const JUMP_GAP := Vector2(5.0, 19.0)       # clear gap a jump spans (m)
const JUMP_DROP := 9.0                     # most a jump lands below its takeoff
const GAP := 7.0                           # open gap in a jump road
const GAP_LIP := Vector2(5.5, 0.9)         # each lip: length, rise
const GAP_MIN_LINK := 40.0
const KICK_L := 6.5
const KICK_H := 1.8
const KICK_W := 6.0
## KO: off every surface and this far under the level you were on (or the
## lowest surface you're near), or off for too long.
const KO_FALL := 5.0
const KO_OFF_T := 3.0
signal crashed_down(car: Car, at: Vector3)

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
var _roof_props: Array = []    # positions of roof plant on the battle roofs
var _roofs_cleared := false


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


## Rooftop Rumble on the city's own roofs: a cluster of 5-7 existing towers
## of different heights near downtown, their roofs (exactly as the city
## draws and collides them) the battle floors, joined by added links:
##   ramp    steep concrete climbs between roofs of very different heights
##   road    long elevated roads (asphalt, lane line) over the streets
##   narrow  thin girder crossings, one car wide
##   bridge  ordinary steel bridges
##   jump    a kicker on one roof's edge and nothing else: clear the gap
##           (one way, from the higher roof or level)
## No rails anywhere: over the edge is out.
func _build_rooftops() -> void:
	var grid := layout._building_grid()
	var cands: Array = []   # [b, centre2, roof xf (top centre), half, roof y]
	var cbd := CityLayout.CBD_CENTER
	for b in layout.buildings:
		if b["kind"] != "normal" or BuildingMesher.shaped(b):
			continue
		var c2: Vector2 = layout.base_center(b)
		if c2.distance_to(cbd) > 430.0:
			continue
		var t: Array = b["tiers"][-1]
		# (Deco and stone towers over 70 m wear crowns: piers and finials on the roof edge.)
		if int(b["style"]) in [CityLayout.Style.DECO, CityLayout.Style.STONE] and float(t[5]) > 70.0:
			continue
		var roof := BuildingMesher.roof_y(b)
		if roof < ROOF_Y.x or roof > ROOF_Y.y:
			continue
		var half := Vector2((float(t[2]) - float(t[0])) * 0.5, (float(t[3]) - float(t[1])) * 0.5)
		if minf(half.x, half.y) < ROOF_HALF.x or maxf(half.x, half.y) > ROOF_HALF.y:
			continue
		var X := CityLayout.bxf(b)
		var lc := Vector3((float(t[0]) + float(t[2])) * 0.5, 0.0, (float(t[1]) + float(t[3])) * 0.5)
		var w := X * lc
		var rxf := Transform3D(X.basis.orthonormalized(), Vector3(w.x, roof, w.z))
		# Open sky over the roof (no taller neighbour or spire leaning over it)
		# and next to no roof plant in the way.
		if not _box_clear(grid, rxf, half - Vector2(0.8, 0.8), 0.6, 10.0, [b]):
			continue
		cands.append([b, Vector2(w.x, w.z), rxf, half, roof])
	# Pairs: which can be bridged (and how steep), which can be jumped.
	var memo := {}
	var link_of := func(i: int, j: int) -> Dictionary:
		var key := Vector2i(mini(i, j), maxi(i, j))
		if memo.has(key):
			return memo[key]
		var r := {}
		var A: Array = cands[key.x]
		var B: Array = cands[key.y]
		var d := (A[1] as Vector2).distance_to(B[1])
		if d < 135.0:
			var ends := _link_ends(A, B)
			var pa: Vector3 = ends[0]
			var pb: Vector3 = ends[1]
			var flat := Vector2(pb.x - pa.x, pb.z - pa.z).length()
			var dy := absf(pb.y - pa.y)
			if flat > 6.0 and flat < 90.0 and dy / flat <= STEEP and _span_clear(grid, pa, pb, A[0], B[0], 8.0):
				r["bridge"] = [pa, pb, flat, dy / flat]
			var gap := flat - 3.0
			if gap > JUMP_GAP.x and gap < JUMP_GAP.y and dy <= JUMP_DROP \
					and _span_clear(grid, pa + Vector3.UP * 2.0, pb + Vector3.UP * 2.0, A[0], B[0], 4.0):
				r["jump"] = [pa, pb, gap]
		memo[key] = r
		return r
	# Grow a cluster from each seed: always the tower that connects to the
	# most chosen ones, favouring a height the cluster doesn't have yet.
	var best: Array = []
	var best_score := -INF
	var ranked: Array = []
	var seeds := range(cands.size())
	for si in seeds:
		var chosen: Array = [si]
		while chosen.size() < 7:
			var pick := -1
			var pick_s := -INF
			for ci in cands.size():
				if ci in chosen:
					continue
				var links_to := 0
				var near_h := INF
				for hi in chosen:
					var lk: Dictionary = link_of.call(ci, hi)
					if lk.has("bridge"):
						links_to += 1
					near_h = minf(near_h, absf(float(cands[ci][4]) - float(cands[hi][4])))
				if links_to == 0:
					continue
				var s := links_to * 4.0 + minf(near_h, 18.0) * 0.35 \
					- (cands[ci][1] as Vector2).distance_to(cands[si][1]) * 0.02
				if s > pick_s:
					pick_s = s
					pick = ci
			if pick < 0:
				break
			chosen.append(pick)
		var ys: Array = chosen.map(func(c): return float(cands[c][4]))
		var n_links := 0
		var n_jumps := 0
		for a in chosen.size():
			for b2 in range(a + 1, chosen.size()):
				var lk: Dictionary = link_of.call(chosen[a], chosen[b2])
				n_links += 1 if lk.has("bridge") else 0
				n_jumps += 1 if lk.has("jump") else 0
		var room := 0.0
		for c in chosen:
			room += minf((cands[c][3] as Vector2).x, (cands[c][3] as Vector2).y)
		var score := chosen.size() * 12.0 + minf(ys.max() - ys.min(), 45.0) * 0.5 + minf(n_links, chosen.size() + 3) * 3.0 \
			+ minf(n_jumps, 2) * 6.0 + room * 0.9
		ranked.append([score, chosen])
		if score > best_score:
			best_score = score
			best = chosen
	if best.is_empty():
		push_warning("Arena: no rooftop cluster found")
		return
	if OS.get_environment("ARENA_DEBUG") != "":
		for a in best.size():
			for b2 in range(a + 1, best.size()):
				var A2: Array = cands[best[a]]
				var B2: Array = cands[best[b2]]
				var e2 := _link_ends(A2, B2)
				var fl := Vector2((e2[1] as Vector3).x - (e2[0] as Vector3).x, (e2[1] as Vector3).z - (e2[0] as Vector3).z).length()
				print("pair %d-%d flat %.0f dy %.0f clear %s link %s" % [a, b2, fl, absf(A2[4] - B2[4]),
					_span_clear(grid, e2[0], e2[1], A2[0], B2[0], 8.0), str(link_of.call(best[a], best[b2]).keys())])
	# Links for a cluster: a spanning set first (every roof reachable by
	# road), then extra loops, never two links crossing at about the same
	# height, never two leaving a roof from the same spot. Then keep the
	# largest group the links actually join. Returns [roofs, links].
	var place := func(cluster: Array) -> Array:
		var all_pairs: Array = []
		for a in cluster.size():
			for b2 in range(a + 1, cluster.size()):
				var lk: Dictionary = link_of.call(cluster[a], cluster[b2])
				if lk.has("bridge"):
					all_pairs.append([cluster[a], cluster[b2], lk["bridge"]])
		all_pairs.sort_custom(func(x, y): return float(x[2][2]) < float(y[2][2]))   # shortest first
		var used: Array = []    # [a, b, pa, pb]
		var comp := {}
		for ci in cluster:
			comp[ci] = ci
		var find := func(x):
			while comp[x] != x:
				x = comp[x]
			return x
		for pass_i in 2:
			for pr in all_pairs:
				if used.size() >= cluster.size() + 2:
					break
				var a: int = pr[0]
				var b2: int = pr[1]
				if used.any(func(u): return (u[0] == a and u[1] == b2) or (u[0] == b2 and u[1] == a)):
					continue
				var joins: bool = find.call(a) != find.call(b2)
				if pass_i == 0 and not joins:
					continue
				var pa: Vector3 = pr[2][0]
				var pb: Vector3 = pr[2][1]
				if not _link_fits(used, pa, pb):
					continue
				used.append([a, b2, pa, pb])
				comp[find.call(a)] = find.call(b2)
		var groups := {}
		for ci in cluster:
			var r0 = find.call(ci)
			if not groups.has(r0):
				groups[r0] = []
			groups[r0].append(ci)
		var main: Array = []
		for gk in groups:
			if (groups[gk] as Array).size() > main.size():
				main = groups[gk]
		return [main, used.filter(func(u): return u[0] in main and u[1] in main)]
	# The best of the top clusters once linked.
	ranked.sort_custom(func(x, y): return x[0] > y[0])
	var used: Array = []
	best_score = -INF
	var seen := {}
	for rk in ranked.slice(0, 16):
		var key := str((rk[1] as Array).duplicate().map(func(v): return v))
		var sorted_c: Array = (rk[1] as Array).duplicate()
		sorted_c.sort()
		key = str(sorted_c)
		if seen.has(key):
			continue
		seen[key] = true
		var res: Array = place.call(rk[1])
		var roofs: Array = res[0]
		var ys2: Array = roofs.map(func(c): return float(cands[c][4]))
		var room2 := 0.0
		for c in roofs:
			room2 += minf((cands[c][3] as Vector2).x, (cands[c][3] as Vector2).y)
		var sc := roofs.size() * 12.0 + (res[1] as Array).size() * 4.0 + minf(ys2.max() - ys2.min(), 45.0) * 0.5 + room2 * 0.9
		if roofs.size() >= 2 and sc > best_score:
			best_score = sc
			best = roofs
			used = res[1]
	# Roofs.
	var idx := {}
	floor_y = INF
	for ci in best:
		var cd: Array = cands[ci]
		idx[ci] = pieces.size()   # (links name decks by piece index, as route() expects)
		decks.append(pieces.size())
		pieces.append({"type": "deck", "xf": cd[2], "half": cd[3], "b": cd[0], "roof": true})
		floor_y = minf(floor_y, cd[4])
		_roof_edge_lights(cd[2], cd[3])
	var n_narrow := 0
	# The two longest, flattest roads get a gap in the middle to jump.
	var gaps: Array = used.filter(func(u):
		var f := Vector2((u[3] as Vector3).x - (u[2] as Vector3).x, (u[3] as Vector3).z - (u[2] as Vector3).z).length()
		return f >= GAP_MIN_LINK and absf((u[3] as Vector3).y - (u[2] as Vector3).y) / f <= 0.15)
	gaps.sort_custom(func(x, y): return (x[2] as Vector3).distance_to(x[3]) > (y[2] as Vector3).distance_to(y[3]))
	gaps = gaps.slice(0, 2)
	for u in used:
		var pa: Vector3 = u[2]
		var pb: Vector3 = u[3]
		var flat := Vector2(pb.x - pa.x, pb.z - pa.z).length()
		var slope := absf(pb.y - pa.y) / flat
		var style := "bridge"
		var w := BRIDGE_W
		if slope > 0.24:
			style = "ramp"
			w = 7.0
		elif flat > 36.0:
			style = "road"
			w = 9.0
		elif flat > 16.0 and slope < 0.1 and n_narrow < 2:
			style = "narrow"
			w = NARROW_W
			n_narrow += 1
		if u in gaps:
			style = "gap"
			w = 8.0
		var bi := pieces.size()
		var li := links.size()
		if style == "gap":
			_gap_geometry(pa, pb, w, li)
		else:
			_link_geometry(pa, pb, w, style)
			pieces[bi]["link"] = li
		links.append([idx[u[0]], idx[u[1]], bi, pa, pb, style, false])
	# Jumps: up to two, from the higher roof, where there's no link already
	# and the kicker's run-up is clear of the other links' ends.
	var n_jump := 0
	for a in best.size():
		for b2 in range(best.size()):
			if a == b2 or n_jump >= 2:
				continue
			var A: int = best[a]
			var B: int = best[b2]
			if float(cands[A][4]) + 0.3 < float(cands[B][4]):
				continue   # take off from the higher roof (or level)
			if used.any(func(u): return (u[0] == A and u[1] == B) or (u[0] == B and u[1] == A)):
				continue
			if links.any(func(l): return l[5] == "jump" and ((l[0] == idx[A] and l[1] == idx[B]) or (l[0] == idx[B] and l[1] == idx[A]))):
				continue
			var lk: Dictionary = link_of.call(A, B)
			if not lk.has("jump"):
				continue
			var ends := _link_ends(cands[A], cands[B])
			var pa: Vector3 = ends[0]
			var pb: Vector3 = ends[1]
			var dir := Vector3(pb.x - pa.x, 0.0, pb.z - pa.z).normalized()
			# Run-up: as long as the roof allows (at least 9 m before the kicker).
			var run := KICK_L + 9.0
			while run < KICK_L + 26.0 and _piece_has(idx[A], pa - dir * (run + 1.5), 2.0):
				run += 1.5
			if not _piece_has(idx[A], pa - dir * run, 2.0):
				continue   # no run-up on that roof
			if not _link_fits(used, pa, pb, 9.0):
				continue
			_kicker(pa, dir)
			links.append([idx[A], idx[B], -1, pa - dir * run, pb + dir * 4.0, "jump", true])
			used.append([A, B, pa, pb])
			n_jump += 1
	# Roof plant on the battle roofs (hidden while a battle runs).
	for ci in best:
		var rxf: Transform3D = cands[ci][2]
		var half: Vector2 = cands[ci][3]
		var inv := rxf.affine_inverse()
		for p in layout.props:
			var o: Vector3 = (p[1] as Transform3D).origin
			if absf(o.x - rxf.origin.x) > 45.0 or absf(o.z - rxf.origin.z) > 45.0:
				continue
			var lp := inv * o
			if absf(lp.y) < 4.0 and absf(lp.x) < half.x + 1.0 and absf(lp.z) < half.y + 1.0:
				_roof_props.append(o)
	var sum := Vector3.ZERO
	for di in decks:
		sum += (pieces[di]["xf"] as Transform3D).origin
	centre = sum / maxf(decks.size(), 1)
	var hs: Array = best.map(func(c): return snappedf(float(cands[c][4]), 1.0))
	var kinds: Array = links.map(func(l): return l[5])
	print("Arena rooftops: %d roofs (heights %s), links %s, floor %.0f m" % [decks.size(), str(hs), str(kinds), floor_y])


## Roof plant and other props by 8 m cell (to keep battle roofs clear).
## Hides (or brings back) the roof plant on the battle roofs: the roofs are
## the arena floor while a battle runs (props never collide with cars, so
## this is only what's drawn).
func clear_roofs(world: CityWorld, clear: bool) -> void:
	if world == null or _roof_props.is_empty() or _roofs_cleared == clear:
		return
	_roofs_cleared = clear
	var keys := {}
	for o: Vector3 in _roof_props:
		var k := CityWorld.item_key(o)
		if clear:
			world.broken[k] = true
		else:
			world.broken.erase(k)
		keys[Vector2i(floori(o.x / CityWorld.CHUNK), floori(o.z / CityWorld.CHUNK))] = true
	for key in keys:
		world.refresh_props(key)


func _roof_prop_index() -> Dictionary:
	var out := {}
	for p in layout.props:
		var o: Vector3 = (p[1] as Transform3D).origin
		if o.y < 20.0:
			continue
		var k := Vector2i(floori(o.x / 8.0), floori(o.z / 8.0))
		if not out.has(k):
			out[k] = []
		out[k].append(o)
	return out


func _roof_clutter(index: Dictionary, xf: Transform3D, half: Vector2) -> int:
	var n := 0
	var inv := xf.affine_inverse()
	var r := maxf(half.x, half.y) + 2.0
	var c := xf.origin
	for gx in range(floori((c.x - r) / 8.0), floori((c.x + r) / 8.0) + 1):
		for gz in range(floori((c.z - r) / 8.0), floori((c.z + r) / 8.0) + 1):
			for o: Vector3 in index.get(Vector2i(gx, gz), []):
				var lp := inv * o
				if absf(lp.y) < 3.0 and absf(lp.x) < half.x + 0.5 and absf(lp.z) < half.y + 0.5:
					n += 1
	return n


## Where a link leaves each roof: on the line between the centres, 1.2 m
## inside the edge, up on the parapet lip (a short wedge climbs to it).
func _link_ends(A: Array, B: Array) -> Array:
	var pa := _edge_point(A[2], A[3], (B[2] as Transform3D).origin, 1.2)
	var pb := _edge_point(B[2], B[3], (A[2] as Transform3D).origin, 1.2)
	return [pa + Vector3.UP * LIP, pb + Vector3.UP * LIP]


## The span between two roofs (at and just over the deck) is clear of every
## other building.
func _span_clear(grid: Dictionary, pa: Vector3, pb: Vector3, ba: Dictionary, bb: Dictionary, w: float) -> bool:
	var flat := Vector2(pb.x - pa.x, pb.z - pa.z).length()
	var dir := (pb - pa).normalized()
	var side := Vector3(-dir.z, 0.0, dir.x).normalized()
	var n := int(flat / 2.0) + 1
	for i in n + 1:
		var p := pa.lerp(pb, float(i) / n)
		for s: float in [-0.5, 0.0, 0.5]:
			var q := p + side * w * s
			for bd in grid.get(Vector2i(floori(q.x / 50.0), floori(q.z / 50.0)), []):
				if is_same(bd, ba) or is_same(bd, bb):
					continue
				for yy: float in [-1.5, 1.0, 5.0]:
					if layout.inside(bd, Vector3(q.x, q.y + yy, q.z), 0.6):
						return false
	return true


## A new link from pa to pb doesn't cross another at a similar height, nor
## start / end within `room` m of another's end.
func _link_fits(used: Array, pa: Vector3, pb: Vector3, room := 7.0) -> bool:
	var a2 := Vector2(pa.x, pa.z)
	var b2 := Vector2(pb.x, pb.z)
	for u in used:
		var qa: Vector3 = u[2]
		var qb: Vector3 = u[3]
		for e: Vector3 in [qa, qb]:
			for f: Vector3 in [pa, pb]:
				if e.distance_to(f) < room:
					return false
		var x = Geometry2D.segment_intersects_segment(a2, b2, Vector2(qa.x, qa.z), Vector2(qb.x, qb.z))
		if x != null:
			var t1 := a2.distance_to(x) / maxf(a2.distance_to(b2), 0.01)
			var t2 := Vector2(qa.x, qa.z).distance_to(x) / maxf(Vector2(qa.x, qa.z).distance_to(Vector2(qb.x, qb.z)), 0.01)
			if absf(lerpf(pa.y, pb.y, t1) - lerpf(qa.y, qb.y, t2)) < 6.0:
				return false
	return true


func _piece_has(pi: int, p: Vector3, inset: float) -> bool:
	var pc: Dictionary = pieces[pi]
	var lp := (pc["xf"] as Transform3D).affine_inverse() * p
	var half: Vector2 = pc["half"]
	return absf(lp.x) < half.x - inset and absf(lp.z) < half.y - inset


## A slab (collision + mesh) whose top runs a -> b, `w` wide.
func _slab(a: Vector3, b: Vector3, w: float, t: float, mat: Material) -> Transform3D:
	var d := b - a
	var basis := Basis.looking_at(d.normalized(), Vector3.UP)
	var mid := (a + b) * 0.5
	var cxf := Transform3D(basis, mid - basis.y * t * 0.5)
	var cs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(w, t, d.length())
	cs.shape = box
	cs.transform = cxf
	_body.add_child(cs)
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = box.size
	mi.mesh = bm
	mi.material_override = mat
	mi.transform = cxf
	add_child(mi)
	return Transform3D(basis, mid)


## A link's deck from pa to pb, with a short wedge up onto it from each
## roof (over the parapet lip), dressed by style.
func _link_geometry(pa: Vector3, pb: Vector3, w: float, style: String) -> void:
	var d := pb - pa
	var flat := Vector3(d.x, 0.0, d.z)
	var dir := flat.normalized()
	var length := d.length()
	var t := 0.9 if style != "narrow" else 0.6
	var base: Color = {"bridge": Color(0.13, 0.135, 0.15), "road": Color(0.1, 0.1, 0.11), "ramp": Color(0.36, 0.36, 0.35),
		"narrow": Color(0.16, 0.12, 0.1)}[style]
	var bxf := _slab(pa, pb, w, t, _deck_mat(2, Vector2(w * 0.5, length * 0.5), base))
	pieces.append({"type": "bridge", "xf": bxf, "half": Vector2(w * 0.5, length * 0.5), "flat": flat.length(), "style": style})
	# Wedges from the roof (inside the lip) up to each end.
	var wm := _metal(Color(0.3, 0.3, 0.32))
	_slab(pa - dir * WEDGE_L - Vector3.UP * LIP, pa + dir * 0.05, w, 0.4, wm)
	_slab(pb + dir * WEDGE_L - Vector3.UP * LIP, pb - dir * 0.05, w, 0.4, wm)
	var basis := bxf.basis
	var mid := bxf.origin
	match style:
		"bridge", "narrow":
			var steel := _metal(Color(0.55, 0.16, 0.1) if style == "bridge" else Color(0.2, 0.24, 0.3))
			for s in [-1.0, 1.0]:
				_box_mesh(Vector3(0.5, 1.6, length), Transform3D(basis, mid + basis.x * s * (w * 0.5 - 0.35) - basis.y * (t + 0.8)), steel)
			var n := int(length / 5.0)
			for i in n:
				var z := -length * 0.5 + (i + 0.5) * length / n
				_box_mesh(Vector3(w - 0.8, 0.3, 0.3), Transform3D(basis, mid + basis.z * z - basis.y * (t + 1.3)), steel)
		"road":
			# Box girder under it, and lamp posts along both edges.
			var conc := _metal(Color(0.5, 0.5, 0.48))
			conc.metallic = 0.0
			conc.roughness = 0.9
			_box_mesh(Vector3(w * 0.6, 1.8, length), Transform3D(basis, mid - basis.y * (t + 0.9)), conc)
			var lamp := _glow(Color(1.0, 0.85, 0.55), 2.0)
			var post := _metal(Color(0.25, 0.26, 0.28))
			var n2 := maxi(1, int(length / 18.0))
			for i in n2:
				var z := -length * 0.5 + (i + 0.5) * length / n2
				for s in [-1.0, 1.0]:
					var at: Vector3 = mid + basis.z * z + basis.x * s * (w * 0.5 + 0.25)
					_box_mesh(Vector3(0.18, 4.0, 0.18), Transform3D(Basis(), at + Vector3.UP * 2.0), post)
					_box_mesh(Vector3(0.5, 0.18, 0.9), Transform3D(Basis(), at + Vector3.UP * 4.0), lamp)
		"ramp":
			# A deep concrete spine with ribs: it reads as a climb.
			var conc2 := _metal(Color(0.46, 0.46, 0.44))
			conc2.metallic = 0.0
			conc2.roughness = 0.9
			_box_mesh(Vector3(w * 0.7, 2.4, length), Transform3D(basis, mid - basis.y * (t + 1.2)), conc2)
			var n3 := int(length / 6.0)
			for i in n3:
				var z := -length * 0.5 + (i + 0.5) * length / n3
				_box_mesh(Vector3(w, 0.5, 0.5), Transform3D(basis, mid + basis.z * z - basis.y * (t + 0.25)), conc2)
	var glow := _glow(Color(1.0, 0.62, 0.12), 2.2)
	for s in [-1.0, 1.0]:
		_box_mesh(Vector3(0.18, 0.16, length), Transform3D(basis, mid + basis.x * s * (w * 0.5 + 0.05) - basis.y * 0.3), glow)


## An elevated road with a gap in the middle: two halves, each ending in a
## chevroned lip that rises toward the gap (the take-off going one way, the
## landing ramp coming the other), warning posts either side.
func _gap_geometry(pa: Vector3, pb: Vector3, w: float, li: int) -> void:
	var d := pb - pa
	var mid := (pa + pb) * 0.5
	var u := d.normalized()
	var e1 := mid - u * GAP * 0.5
	var e2 := mid + u * GAP * 0.5
	var m1 := e1 - u * GAP_LIP.x
	var m2 := e2 + u * GAP_LIP.x
	var base := Color(0.1, 0.1, 0.11)
	for half_i in 2:
		var a := pa if half_i == 0 else pb
		var m := m1 if half_i == 0 else m2
		var e := e1 if half_i == 0 else e2
		var length := a.distance_to(m)
		var xf := _slab(a, m, w, 0.9, _deck_mat(2, Vector2(w * 0.5, length * 0.5), base))
		var whole := _slab_xf(a, e)
		pieces.append({"type": "bridge", "xf": whole, "half": Vector2(w * 0.5, a.distance_to(e) * 0.5), "style": "gap",
			"link": li, "flat": Vector2(e.x - a.x, e.z - a.z).length()})
		var conc := _metal(Color(0.5, 0.5, 0.48))
		conc.metallic = 0.0
		conc.roughness = 0.9
		_box_mesh(Vector3(w * 0.6, 1.8, length), Transform3D(xf.basis, xf.origin - xf.basis.y * 1.8), conc)
		# The lip.
		var lip := e + Vector3.UP * GAP_LIP.y
		_slab(m - Vector3.UP * 0.02, lip, w, 1.2, _deck_mat(3, Vector2(w * 0.5, GAP_LIP.x * 0.5), Color(0.95, 0.6, 0.06)))
		var side := Vector3(-u.z, 0.0, u.x).normalized()
		for s in [-1.0, 1.0]:
			_box_mesh(Vector3(0.25, 2.2, 0.25), Transform3D(Basis(), lip + side * s * (w * 0.5 + 0.2) + Vector3.UP * 1.1),
				_glow(Color(1.0, 0.2, 0.1), 2.5))
		_box_mesh(Vector3(w, 0.15, 0.25), Transform3D(Basis.looking_at(Vector3(u.x, 0.0, u.z).normalized(), Vector3.UP),
			lip + Vector3.UP * 0.05), _glow(Color(1.0, 0.62, 0.12), 3.0))
	var glow := _glow(Color(1.0, 0.62, 0.12), 2.2)
	for half_i in 2:
		var a2 := pa if half_i == 0 else pb
		var e3 := e1 if half_i == 0 else e2
		var bx := _slab_xf(a2, e3)
		var ln := a2.distance_to(e3)
		for s in [-1.0, 1.0]:
			_box_mesh(Vector3(0.18, 0.16, ln), Transform3D(bx.basis, bx.origin + bx.basis.x * s * (w * 0.5 + 0.05) - bx.basis.y * 0.3), glow)
	# Wedges from the roofs onto the road.
	var dir := Vector3(d.x, 0.0, d.z).normalized()
	var wm := _metal(Color(0.3, 0.3, 0.32))
	_slab(pa - dir * WEDGE_L - Vector3.UP * LIP, pa + dir * 0.05, w, 0.4, wm)
	_slab(pb + dir * WEDGE_L - Vector3.UP * LIP, pb - dir * 0.05, w, 0.4, wm)


func _slab_xf(a: Vector3, b: Vector3) -> Transform3D:
	return Transform3D(Basis.looking_at((b - a).normalized(), Vector3.UP), (a + b) * 0.5)


## A jump: a chevroned kicker ending on the roof's edge, facing `dir`.
func _kicker(edge: Vector3, dir: Vector3) -> void:
	var a := edge - dir * KICK_L - Vector3.UP * LIP
	var b := edge + Vector3.UP * KICK_H
	var m := _deck_mat(3, Vector2(KICK_W * 0.5, KICK_L * 0.5), Color(0.95, 0.6, 0.06))
	_slab(a, b, KICK_W, 1.2, m)
	# A glowing lip on the takeoff edge.
	var side := Vector3(-dir.z, 0.0, dir.x)
	_box_mesh(Vector3(KICK_W, 0.15, 0.25), Transform3D(Basis.looking_at(dir, Vector3.UP), b + Vector3.UP * 0.05),
		_glow(Color(1.0, 0.62, 0.12), 3.0))
	for s in [-1.0, 1.0]:
		_box_mesh(Vector3(0.2, 1.4, 0.2), Transform3D(Basis(), b + side * s * (KICK_W * 0.5) + Vector3.UP * 0.7),
			_glow(Color(1.0, 0.2, 0.1), 2.5))


## Amber glow strips just above the parapet round a battle roof, so the drop
## reads at speed (the building itself is untouched).
func _roof_edge_lights(xf: Transform3D, half: Vector2) -> void:
	var glow := _glow(Color(1.0, 0.62, 0.12), 2.0)
	for e in 4:
		var horiz := e < 2
		var s := 1.0 if e % 2 == 0 else -1.0
		var size := Vector3(half.x * 2.0, 0.08, 0.12) if horiz else Vector3(0.12, 0.08, half.y * 2.0)
		var lp := Vector3(0.0, LIP + 0.05, s * (half.y + 0.02)) if horiz else Vector3(s * (half.x + 0.02), LIP + 0.05, 0.0)
		_box_mesh(size, Transform3D(xf.basis, xf * lp), glow)


func _box_mesh(size: Vector3, xf: Transform3D, mat: Material) -> void:
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = size
	mi.mesh = bm
	mi.material_override = mat
	mi.transform = xf
	add_child(mi)


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


func _edge_point(xf: Transform3D, half: Vector2, toward: Vector3, inset := 1.5) -> Vector3:
	var d := toward - xf.origin
	d.y = 0.0
	d = d.normalized()
	var ld := xf.basis.inverse() * d
	var tx := half.x / maxf(absf(ld.x), 0.001)
	var tz := half.y / maxf(absf(ld.z), 0.001)
	var t := minf(tx, tz) - inset
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

func _deck_mat(shape: int, half: Vector2, base := Color(0.13, 0.135, 0.15)) -> Material:
	if _shader == null:
		_shader = Shader.new()
		_shader.code = DECK_SHADER
	var m := ShaderMaterial.new()
	m.shader = _shader
	m.set_shader_parameter("shape", shape)
	m.set_shader_parameter("half_size", half)
	m.set_shader_parameter("base", Vector3(base.r, base.g, base.b))
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
uniform vec3 base = vec3(0.13, 0.135, 0.15);
varying vec3 lp;
varying vec3 ln;
void vertex() { lp = VERTEX; ln = NORMAL; }
float hash(vec2 p) { return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453); }
void fragment() {
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
		// Hazard band: amber / black chevrons along the edge (thinner on
		// narrow links).
		float band = min(1.6, half_size.x * 0.22);
		if (edge < band) {
			float s = step(0.5, fract((along + edge) / 2.2));
			col = mix(vec3(0.02), vec3(0.95, 0.6, 0.06), s);
		} else if (edge < band + 0.4) {
			col = vec3(0.85);
		}
		if (shape == 3) {
			// Kicker: big chevrons pointing up the ramp.
			float c = step(0.5, fract((p.y + abs(p.x) * 0.8) / 2.0));
			col = mix(vec3(0.03), base, c);
		} else if (shape != 2) {
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


## First link to take from deck a toward deck b: [entry, exit, style], or []
## if same deck / no route. Jumps are one way (from the higher roof) and
## count a little longer than a bridge (they can go wrong).
func route(a: int, b: int) -> Array:
	if a == b:
		return []
	var dist := {a: 0.0}
	var prev := {}
	var open := [a]
	while not open.is_empty():
		open.sort_custom(func(x, y): return dist[x] < dist[y])
		var c: int = open.pop_front()
		if c == b:
			break
		for li in links.size():
			var l: Array = links[li]
			var di := decks.find(l[0])
			var dj := decks.find(l[1])
			var oneway: bool = l.size() > 6 and l[6]
			var cost := 1.4 if (l.size() > 5 and l[5] == "jump") else 1.0
			for pair in ([[di, dj]] if oneway else [[di, dj], [dj, di]]):
				if pair[0] != c:
					continue
				var nd: float = dist[c] + cost
				if nd < float(dist.get(pair[1], INF)):
					dist[pair[1]] = nd
					prev[pair[1]] = [c, li, pair[0] == di]
					if not (pair[1] in open):
						open.append(pair[1])
	if not prev.has(b):
		return []
	var step := b
	while (prev[step] as Array)[0] != a:
		step = (prev[step] as Array)[0]
	var pv: Array = prev[step]
	var l2: Array = links[pv[1]]
	var style: String = l2[5] if l2.size() > 5 else "bridge"
	return [l2[3], l2[4], style] if pv[2] else [l2[4], l2[3], style]


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
					if pc.has("b") and is_same(bd, pc["b"]):
						continue   # (the roof we're standing on)
					if layout.inside(bd, p + Vector3.UP * 0.8, 3.2):
						ok = false
						break
				# Really open, flat roof there (roof huts and plant boxes belong
				# to the building itself, so ask the physics).
				if ok and is_inside_tree():
					ok = _slot_open(p, xf)
				# Clear of link ends and kickers on this roof.
				for l in links:
					for e: Vector3 in [l[3], l[4]]:
						if Vector2(e.x - p.x, e.z - p.z).length() < 7.0 and absf(e.y - p.y) < 4.0:
							ok = false
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
		var cp := c.global_position
		var pi_on := piece_at(cp, 0.0, 4.0)
		var off := pi_on < 0
		var ot: float = c.get_meta("off_t", 0.0)
		ot = ot + dt if off else 0.0
		c.set_meta("off_t", ot)
		if kind == Kind.ROOFTOPS:
			# Out: off every roof and link and KO_FALL under the level it was on
			# (or under the lowest surface close by: a jump to a lower roof is
			# fine), or off them for KO_OFF_T s (on a ledge or a setback roof).
			if not off:
				c.set_meta("level", _top_y(cp))
				c.set_meta("edge_at", cp)
			var ref: float = c.get_meta("level", floor_y)
			if off:
				ref = minf(ref, _lowest_near(cp, 12.0))
			if cp.y < floor_y - KO_DROP or (off and (cp.y < ref - KO_FALL or ot > KO_OFF_T)):
				_knock_out(c)
				continue
		elif cp.y < floor_y - KO_DROP or (off and ot > 1.2 and cp.y < floor_y - 1.0):
			# Out: well under the deck, or off it for a moment and below it.
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


## A car fits at p: flat surface right under it at the deck's height, and
## nothing solid in a car-sized box over it.
func _slot_open(p: Vector3, xf: Transform3D) -> bool:
	var space := get_world_3d().direct_space_state
	var rq := PhysicsRayQueryParameters3D.create(p + Vector3.UP * 3.0, p - Vector3.UP * 3.0, Car.RAY_MASK)
	var hit := space.intersect_ray(rq)
	if hit.is_empty() or absf((hit["position"] as Vector3).y - xf.origin.y) > 0.25 or (hit["normal"] as Vector3).y < 0.97:
		return false
	var sq := PhysicsShapeQueryParameters3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(3.0, 1.6, 6.0)
	sq.shape = box
	sq.transform = Transform3D(xf.basis, Vector3(p.x, xf.origin.y + 1.1, p.z))
	sq.collision_mask = 1 | (1 << 7)
	return space.intersect_shape(sq, 1).is_empty()


## Lowest surface top within r m (horizontally) of p, or INF.
func _lowest_near(p: Vector3, r: float) -> float:
	var lo := INF
	for pc in pieces:
		var xf: Transform3D = pc["xf"]
		var half: Vector2 = pc["half"]
		var lp := xf.affine_inverse() * Vector3(p.x, xf.origin.y, p.z)
		if absf(lp.x) < half.x + r and absf(lp.z) < half.y + r:
			var q := xf * Vector3(clampf(lp.x, -half.x, half.x), 0.0, clampf(lp.z, -half.y, half.y))
			lo = minf(lo, q.y)
	return lo


func _knock_out(c: Car) -> void:
	alive.erase(c)
	out_order.append(c)
	var by: Car = null
	if c.last_hit_by and is_instance_valid(c.last_hit_by) and c.last_hit_by != c \
			and c.last_hit_by in cars and time - float(c.get_meta("hit_t", -99.0)) < CREDIT_WINDOW:
		by = c.last_hit_by
		kos[by.get_instance_id()] = int(kos.get(by.get_instance_id(), 0)) + 1
	if OS.get_environment("ARENA_DEBUG") != "":
		var e: Vector3 = c.get_meta("edge_at", c.global_position)
		var pi := piece_at(e, 0.0, 4.0)
		print("KO %s t=%.1f by %s at %s piece %d %s" % [c.name, time, by.name if by else "-", e.snapped(Vector3.ONE),
			pi, pieces[pi].get("style", pieces[pi]["type"]) if pi >= 0 else "?"])
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
		elif f.size() < 3 and f[1] > 0.6 and kind == Kind.ROOFTOPS and c.linear_velocity.y > -3.0 \
				and c.global_position.y < floor_y - KO_FALL - 4.0:
			# It hit something far below (the street, a lower roof): a crash.
			f.append(true)
			crashed_down.emit(c, c.global_position)


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
	var _jump_t := 0.0              # committed to a jump: flat out, no edge sense
	var _jump_to := Vector3.INF
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
		if arena.kind == Kind.ROOFTOPS and _jump_t > 0.0:
			# Mid-jump: straight at the landing, foot down, until we're down on it.
			_jump_t -= dt
			var landed := _jump_t < 2.2 and car.wheels_on_ground > 0 and arena.piece_at(pos) >= 0 \
				and Vector2(pos.x - _jump_to.x, pos.z - _jump_to.z).length() < 14.0
			if landed or _jump_t <= 0.0:
				_jump_t = 0.0
			else:
				drv.direct_target = _jump_to
				drv.direct_vel = Vector3.ZERO
				drv.speed_cap = 60.0
				drv.update(dt, space)
				car.throttle = 1.0
				car.brake = 0.0
				car.handbrake = false
				return
		if arena.kind == Kind.ROOFTOPS:
			var here := arena.piece_at(pos)
			var on_bridge: bool = here >= 0 and arena.pieces[here]["type"] == "bridge"
			if on_bridge and _wp_exit == Vector3.INF and arena.pieces[here].get("style", "") == "gap":
				# On a jump road with no plan (knocked onto it): go for the
				# end we're facing, flat out over the gap.
				var lk: Array = arena.links[int(arena.pieces[here]["link"])]
				var f3 := -car.global_basis.z
				var to_b := (lk[4] as Vector3) - pos
				var end: Vector3 = lk[4] if f3.dot(to_b) > 0.0 else lk[3]
				var ax := end - pos
				ax.y = 0.0
				_jump_t = 2.5 + ax.length() / 12.0
				_jump_to = end + ax.normalized() * 6.0
				_wp_exit = _jump_to
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
					var style: String = r[2] if r.size() > 2 else "bridge"
					var axis := (exit - entry)
					axis.y = 0.0
					axis = axis.normalized()
					# Line up on the link before committing to it (a long, straight
					# run-up for a jump; tight for a narrow crossing).
					var jumpy := style == "jump" or style == "gap"
					var back := 4.0 if style == "jump" else (14.0 if style == "gap" else (10.0 if style == "narrow" else 6.0))
					var tol := 1.3 if jumpy else (0.9 if style == "narrow" else 2.5)
					var approach := entry - axis * back
					var along := (pos - entry).dot(axis)
					var lat := (pos - entry) - axis * along
					lat.y = 0.0
					var fwd2 := -car.global_basis.z
					fwd2.y = 0.0
					var facing := fwd2.normalized().dot(axis) > (0.95 if jumpy else 0.7)
					if lat.length() < tol and along > -(back + 3.0) and facing:
						aim = exit + axis * 4.0
						_wp_exit = exit + axis * 4.0
						if jumpy:
							_jump_t = 3.2 if style == "jump" else 2.5 + Vector2(exit.x - entry.x, exit.z - entry.z).length() / 12.0
							_jump_to = exit + axis * 6.0
					else:
						aim = approach if along < -back * 0.5 or lat.length() > tol * 2.0 else entry
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
