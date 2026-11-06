class_name Traffic
extends Node3D
## Moving traffic on a lane graph built from the road network.
##
##   * Lanes: every road each way (two lanes each way on boulevards and the
##     ring), resampled every STEP m on the road surface. Boulevards stop at
##     the ring road's kerb and at roundabouts (one-way rings of two lanes),
##     so nothing drives out to sea or across a roundabout's island.
##   * Connectors: short curved lanes through every junction – from a
##     street's end into each lane it meets, and from a through lane into
##     each street leaving it. Dead ends turn round.
##   * Cars: constant speed per lane (so nobody overtakes inside a lane),
##     a smooth stop at a street's end until the road it joins has a gap,
##     queues behind a stopped car, pulling away again in turn. Turning off
##     mid-lane only into a gap.
##
## Motion is evaluated on the GPU (traffic.gdshader, on_path): each car is
## (lane, s0, t0, v, stop) and only changes at events (a junction, a stop, a
## restart), so the CPU does almost nothing per frame: run due events, and a
## few times a second pick which cars are drawn (near / far LOD, roughly in
## view).

const STEP := 3.0          # m between lane samples (traffic.gdshader STEP)
const TEX_W := 1024        # lane texture width (traffic.gdshader TEX_W)
const EASE := 12.0         # m: half the stopping / pulling-away distance (traffic_path.gdshader EASE)
const MIN_EASE := 3.5      # m: the hardest braking (when a car ahead stops short)
const GAP := 7.6           # m centre to centre in a queue
const LOOK := 16.0         # m before a street's end where a car picks its way on
const TURN_P := 0.28       # chance of turning off at a side street
const JOIN_R := 24.0       # m: how far a lane end looks for lanes to join
const NO_STOP := 1.0e9
const PATH_SHADER := preload("res://src/world/shaders/traffic_path.gdshader")
const LANE_V := {"ring": 13.0, "major": 12.0, "minor": 9.0, "roundabout": 8.0}
const SPACING := 72.0      # m of lane per car at density 1

enum { EV_NONE, EV_EXIT, EV_DECIDE, EV_END, EV_JOIN, EV_LOOP, EV_FOLLOW }

var layout: CityLayout
var density := 1.0
var near_range := 260.0
var far_range := 520.0

# Lanes (parallel arrays). Connector lanes have l_next >= 0.
var l_base := PackedInt32Array()      # texel index of the first point
var l_n := PackedInt32Array()         # points (loops repeat the first at the end)
var l_len := PackedFloat32Array()
var l_loop := PackedByteArray()
var l_v := PackedFloat32Array()
var l_next := PackedInt32Array()      # connectors: the lane they join
var l_snext := PackedFloat32Array()   # ... and where on it
var l_piece := PackedInt32Array()     # road piece (lanes of one piece don't connect)
var l_exits: Array = []               # [[s, connector], ...] by s
var l_ends: Array = []                # connectors from an open lane's end
var l_feeds: Array = []               # connectors that join this lane
var l_cars: Array = []                # car ids on the lane, rear to front (by s)
var pts := PackedVector3Array()       # every lane's points, texel order

# Cars (parallel arrays).
var c_lane := PackedInt32Array()
var c_s0 := PackedFloat32Array()
var c_t0 := PackedFloat32Array()
var c_v := PackedFloat32Array()
var c_stop := PackedFloat32Array()
var c_ease := PackedFloat32Array()   # m the car takes to stop (EASE, less when it must brake hard)
var c_ev := PackedFloat32Array()
var c_ek := PackedInt32Array()
var c_xi := PackedInt32Array()        # next exit index on the lane
var c_book := PackedInt32Array()      # connector booked at the lane's end
var c_wait := PackedFloat32Array()    # when it started waiting at a street's end
var c_kind := PackedInt32Array()
var c_col: Array[Color] = []
var c_slot := PackedInt32Array()      # instance index in its group, -1 = not drawn
var c_grp := PackedInt32Array()

var now := 0.0
var _rng := RandomNumberGenerator.new()
var _tex: ImageTexture
var _groups: Array = []      # per kind: [near MultiMesh, far MultiMesh]
var _drawn: Array = []       # per group index (kind * 2 + far): car ids
var _cull_t := 0.0


func setup(p_layout: CityLayout, meshes: Array, far_meshes: Array, p_density: float) -> void:
	layout = p_layout
	density = p_density
	_rng.seed = layout.seed ^ 0x7aff1c
	build_network()
	_spawn_cars(meshes)
	_make_groups(meshes, far_meshes)


# ------------------------------------------------------------- the network
func build_network() -> void:
	var R := layout.roads
	var ring_kerb := PackedVector2Array()
	if R.by_name.has("ring"):
		var rp: PackedVector2Array = R.by_name["ring"]["pts"]
		var poly := rp.slice(0, rp.size() - 1)
		var inner := Geometry2D.offset_polygon(poly, -float(R.by_name["ring"]["w"]) * 0.5)
		if not inner.is_empty():
			ring_kerb = inner[0]
	var discs: Array = []
	for rb in R.roundabouts:
		discs.append(CityRoads._circle(rb["c"], float(rb["r"]) + float(rb["w"]) * 0.5 + 0.5, 32))
	var piece := 0
	for r in R.roads:
		var line: PackedVector2Array = r["pts"]
		if line.size() < 2:
			continue
		var is_rb: bool = r.get("loop", false) and not r.has("name")
		if is_rb:
			continue  # roundabouts below
		var kind: String = r["kind"]
		var loop: bool = r.get("loop", false)
		var pieces: Array = [line]
		if kind != "ring" and not ring_kerb.is_empty() and not loop:
			pieces = Geometry2D.intersect_polyline_with_polygon(line, ring_kerb)
		if kind != "minor" and kind != "ring":
			var cut := false
			for d in discs:
				var next: Array = []
				for pc in pieces:
					var parts := Geometry2D.clip_polyline_with_polygon(_rotate_loop(pc, d) if loop and not cut else pc, d)
					if parts.size() != 1 or (parts[0] as PackedVector2Array).size() != (pc as PackedVector2Array).size():
						cut = true
					next.append_array(parts)
				pieces = next
			if cut:
				loop = false
		var offs := [3.2] if kind == "minor" else [3.2, 7.0]
		if float(r["w"]) < 14.0:
			offs = [2.6]
		for pc: PackedVector2Array in pieces:
			if not layout.is_mainland and r.get("name", "") == "diagonal" and pc[0].x < 150.0:
				continue  # replaced by the continuous bridge lane below
			if CityRoads.length_of(pc) < 12.0:
				continue
			var base_line := pc
			if loop and base_line[0].distance_to(base_line[-1]) < 0.1:
				base_line = base_line.slice(0, base_line.size() - 1)
			for o in offs:
				for sgn: float in [1.0, -1.0]:
					var ln := CityLayout._offset_line(base_line, o * sgn)
					if sgn < 0.0:
						ln.reverse()
					_add_lane(ln, loop, LANE_V.get(kind, 10.0), piece)
			piece += 1
	# Continuous roadway: Westbank, suspension span, island ramp, Grand Diagonal junction.
	if not layout.is_mainland and not layout.bridge_ramp.is_empty():
		var axis := PackedVector2Array()
		for i in range(layout.bridge_ramp.size() - 1, -1, -1):
			var p: Vector3 = layout.bridge_ramp[i]
			axis.append(Vector2(p.x, p.z))
		var x := 50.0
		while x > CityLayout.APPROACH_END + 4.0:
			axis.append(Vector2(x, CityLayout.BRIDGE_Z))
			x -= 6.0
		axis.append(Vector2(CityLayout.APPROACH_END + 4.0, CityLayout.BRIDGE_Z))
		for o: float in [3.2, 7.0]:
			for sgn: float in [1.0, -1.0]:
				var ln := CityLayout._offset_line(axis, o * sgn)
				if sgn < 0.0:
					ln.reverse()
				_add_lane(ln, false, 14.0, piece, [], func(xp: float, _z: float) -> float:
					return CityInfrastructure.bridge_height(layout, xp))
		piece += 1
	# Roundabouts: two lanes, one way (anticlockwise seen from above, north up).
	for rb in R.roundabouts:
		for dr: float in [-3.2, 3.2]:
			var c: Vector2 = rb["c"]
			var rr := float(rb["r"]) + dr
			var ring := PackedVector2Array()
			var n := maxi(16, int(TAU * rr / 4.0))
			for i in n:
				var a := -TAU * i / n   # (x east, z south: decreasing angle = anticlockwise on the map)
				ring.append(c + Vector2(cos(a), sin(a)) * rr)
			_add_lane(ring, true, LANE_V["roundabout"], piece)
		piece += 1
	_connect()
	_bake_texture()


## A loop's points rotated to start inside `disc`, so clipping it doesn't
## split the piece that crosses the seam.
static func _rotate_loop(pc: PackedVector2Array, disc: PackedVector2Array) -> PackedVector2Array:
	var open := pc.slice(0, pc.size() - 1) if pc[0].distance_to(pc[-1]) < 0.1 else pc
	for i in open.size():
		if Geometry2D.is_point_in_polygon(open[i], disc):
			var out := open.slice(i)
			out.append_array(open.slice(0, i + 1))
			return out
	return pc


func _add_lane(line2: PackedVector2Array, loop: bool, v: float, piece: int, conn_y := [], height := Callable()) -> int:
	# Resample every STEP m on the road surface.
	var src := line2.duplicate()
	if loop:
		src.append(src[0])
	var total := CityRoads.length_of(src)
	var n := maxi(2, int(round(total / STEP)) + 1)
	var res := PackedVector3Array()
	var seg := 0
	var acc := 0.0
	for k in n:
		var target := total * k / (n - 1)
		while seg < src.size() - 2 and acc + src[seg].distance_to(src[seg + 1]) < target:
			acc += src[seg].distance_to(src[seg + 1])
			seg += 1
		var sl := maxf(src[seg].distance_to(src[seg + 1]), 1e-4)
		var q := src[seg].lerp(src[seg + 1], clampf((target - acc) / sl, 0.0, 1.0))
		var ry: float = height.call(q.x, q.y) if height.is_valid() else layout.terrain.road_y(q.x, q.y)
		res.append(Vector3(q.x, ry + 0.02, q.y))
	if loop:
		res[n - 1] = res[0]
	var id := l_base.size()
	l_base.append(-1)
	l_n.append(n)
	# (Exact spacing: the shader maps s / STEP to a point index.)
	l_len.append(STEP * (n - 1))
	l_loop.append(1 if loop else 0)
	l_v.append(v)
	l_next.append(-1)
	l_snext.append(0.0)
	l_piece.append(piece)
	l_exits.append([])
	l_ends.append([])
	l_feeds.append([])
	l_cars.append([])
	_lane_pts.append(res)
	return id


var _lane_pts: Array = []    # per lane: PackedVector3Array (before baking)


func lane_point(lane: int, s: float) -> Vector3:
	var lp: PackedVector3Array = _lane_pts[lane]
	var n := lp.size()
	var f := s / STEP
	if l_loop[lane]:
		f = fposmod(f, float(n - 1))
	else:
		f = clampf(f, 0.0, n - 1.001)
	var i := int(f)
	return lp[i].lerp(lp[i + 1], f - i)


func lane_dir(lane: int, s: float) -> Vector3:
	var a := lane_point(lane, s - 1.5)
	var b := lane_point(lane, s + 1.5)
	var d := b - a
	d.y = 0.0
	return d.normalized() if d.length_squared() > 1e-6 else Vector3.FORWARD


## Lane segments by 32 m cell (for junction lookups while building).
var _seg_grid := {}


## Nearest point of each lane passing within JOIN_R of p: lane -> [distance, s].
func _near(p: Vector3) -> Dictionary:
	var out := {}
	var p2 := Vector2(p.x, p.z)
	var elevated := p.y - layout.terrain.road_y(p.x, p.z) > 3.0
	var k := Vector2i(floori(p.x / 32.0), floori(p.z / 32.0))
	for dx in range(-1, 2):
		for dz in range(-1, 2):
			for code in _seg_grid.get(k + Vector2i(dx, dz), PackedInt64Array()):
				var li := int(code >> 13)
				var i := int(code & 8191)
				var lp: PackedVector3Array = _lane_pts[li]
				var a := Vector2(lp[i].x, lp[i].z)
				var b := Vector2(lp[i + 1].x, lp[i + 1].z)
				var q := Geometry2D.get_closest_point_to_segment(p2, a, b)
				var d := q.distance_to(p2)
				if elevated != (lp[i].y - layout.terrain.road_y(lp[i].x, lp[i].z) > 3.0):
					continue  # one is up on the bridge deck, the other on the ground
				if d < JOIN_R and d < float(out.get(li, [INF])[0]):
					out[li] = [d, (i + q.distance_to(a) / maxf(a.distance_to(b), 1e-4)) * STEP]
	return out


func _connect() -> void:
	var base_count := l_base.size()
	_seg_grid.clear()
	for li in base_count:
		var lp: PackedVector3Array = _lane_pts[li]
		for i in lp.size() - 1:
			var m := (lp[i] + lp[i + 1]) * 0.5
			var k := Vector2i(floori(m.x / 32.0), floori(m.z / 32.0))
			if not _seg_grid.has(k):
				_seg_grid[k] = PackedInt64Array()
			_seg_grid[k].append((li << 13) | i)
	for li in base_count:
		if l_loop[li]:
			continue
		var lp: PackedVector3Array = _lane_pts[li]
		# The end: into every lane it meets (not back the way it came).
		var E := lp[-1]
		var dE := lane_dir(li, l_len[li] - 1.5)
		var nb := _near(E)
		for m in nb:
			if l_piece[m] == l_piece[li]:
				continue
			var nr: Array = nb[m]
			var s_join := float(nr[1]) + maxf(6.0, float(nr[0]) * 0.6)
			if not l_loop[m] and s_join > l_len[m] - 14.0:
				continue
			var P := lane_point(m, s_join)
			var dM := lane_dir(m, s_join)
			if dM.dot(dE) < -0.3 or (P - E).dot(dE) < 0.5:
				continue
			var c := _connector(E, dE, P, dM, li, m, s_join)
			if c >= 0:
				l_ends[li].append(c)
		# The start: an exit from every lane passing by.
		var S := lp[0]
		var dS := lane_dir(li, 1.5)
		nb = _near(S)
		for m in nb:
			if l_piece[m] == l_piece[li]:
				continue
			var nr: Array = nb[m]
			var s_exit := float(nr[1]) - maxf(6.0, float(nr[0]) * 0.6)
			if l_loop[m]:
				s_exit = fposmod(s_exit, l_len[m])
			elif s_exit < 4.0 or s_exit > l_len[m] - LOOK - 2.0:
				continue  # (near its end: the end's connectors cover it)
			var P := lane_point(m, s_exit)
			var dM := lane_dir(m, s_exit)
			if dM.dot(dS) < -0.3 or (S - P).dot(dM) < 0.5:
				continue
			var c := _connector(P, dM, S + dS * 4.0, dS, m, li, 4.0)
			if c >= 0:
				l_exits[m].append([s_exit, c])
	# Dead ends: turn round into the nearest lane of the same piece going back.
	for li in base_count:
		if l_loop[li] or not (l_ends[li] as Array).is_empty():
			continue
		var E: Vector3 = (_lane_pts[li] as PackedVector3Array)[-1]
		var dE := lane_dir(li, l_len[li] - 1.5)
		var best := -1
		var bd := 30.0
		for m in base_count:
			if m == li or l_piece[m] != l_piece[li] or l_loop[m]:
				continue
			var d := E.distance_to((_lane_pts[m] as PackedVector3Array)[0])
			if d < bd and lane_dir(m, 1.5).dot(dE) < -0.5:
				bd = d
				best = m
		if best >= 0:
			var P := lane_point(best, 3.0)
			var c := _connector(E, dE, P, lane_dir(best, 3.0), li, best, 3.0, 6.0)
			if c < 0:
				# (A U-turn may clip a corner: allow it.)
				c = _connector(E, dE, P, lane_dir(best, 3.0), li, best, 3.0, 6.0, false)
			l_ends[li].append(c)
	for li in base_count:
		(l_exits[li] as Array).sort_custom(func(a, b): return a[0] < b[0])
	_seg_grid.clear()


## A curved connector lane from (A, dA) to (B, dB) joining lane `to` at s_to.
func _connector(A: Vector3, dA: Vector3, B: Vector3, dB: Vector3, from: int, to: int, s_to: float, handle := -1.0,
		check := true) -> int:
	var d := A.distance_to(B)
	var h := handle if handle > 0.0 else d * 0.45
	var c1 := A + dA * h
	var c2 := B - dB * h
	var line := PackedVector2Array()
	var n := maxi(4, int(d / 1.5))
	for i in n + 1:
		var t := float(i) / n
		var u := 1.0 - t
		var p := A * u * u * u + c1 * 3.0 * u * u * t + c2 * 3.0 * u * t * t + B * t * t * t
		line.append(Vector2(p.x, p.z))
	# Never across a block (a lane end that happens to be near a parallel street).
	for i in range(1, line.size() - 1 if check else 1):
		var bi := layout.block_at(line[i].x, line[i].y)
		if bi >= 0 and layout.blocks[bi]["kind"] in ["block", "plaza", "green", "park"]:
			return -1
	# Heights: ease between the two ends (a connector up on the bridge deck
	# stays on the deck instead of dropping to the terrain under it).
	var on_level := absf(A.y - layout.terrain.road_y(A.x, A.z)) > 1.0 or absf(B.y - layout.terrain.road_y(B.x, B.z)) > 1.0
	var hf := Callable()
	if on_level:
		var a2 := Vector2(A.x, A.z)
		var span := maxf(a2.distance_to(Vector2(B.x, B.z)), 0.01)
		hf = func(x: float, z: float) -> float:
			return lerpf(A.y, B.y, clampf(a2.distance_to(Vector2(x, z)) / span, 0.0, 1.0)) - 0.02
	var id := _add_lane(line, false, minf(l_v[from], l_v[to]) * 0.8, -1, [], hf)
	l_next[id] = to
	l_snext[id] = s_to
	l_feeds[to].append(id)
	return id


func _bake_texture() -> void:
	pts = PackedVector3Array()
	for li in l_base.size():
		pts.append(Vector3(l_n[li], float(l_loop[li]), 0.0))  # header
		l_base[li] = pts.size()
		pts.append_array(_lane_pts[li])
	var rows := maxi(1, ceili(float(pts.size()) / TEX_W))
	var data := PackedFloat32Array()
	data.resize(TEX_W * rows * 4)
	for i in pts.size():
		data[i * 4] = pts[i].x
		data[i * 4 + 1] = pts[i].y
		data[i * 4 + 2] = pts[i].z
	var img := Image.create_from_data(TEX_W, rows, false, Image.FORMAT_RGBAF, data.to_byte_array())
	_tex = ImageTexture.create_from_image(img)


func lane_count() -> int:
	return l_base.size()


func total_lane_length() -> float:
	var t := 0.0
	for li in l_base.size():
		if l_next[li] < 0:
			t += l_len[li]
	return t


# ------------------------------------------------------------------- cars
func _spawn_cars(meshes: Array) -> void:
	if density <= 0.0:
		return
	var kinds: Array = []
	for k in meshes.size():
		if meshes[k] != null:
			kinds.append(k)
	if kinds.is_empty():
		return
	for li in l_base.size():
		if l_next[li] >= 0:
			continue
		var L: float = l_len[li]
		var n := int(L / SPACING * density + _rng.randf())
		if not l_loop[li]:
			n = mini(n, int((L - LOOK) / 16.0))
		var ss: Array = []
		for i in n:
			ss.append((float(i) + _rng.randf_range(0.1, 0.7)) * (L - (0.0 if l_loop[li] else LOOK)) / maxf(n, 1))
		for s in ss:
			var id := c_lane.size()
			c_lane.append(li)
			c_s0.append(s)
			c_t0.append(0.0)
			c_v.append(l_v[li])
			c_stop.append(NO_STOP)
			c_ease.append(EASE)
			c_ev.append(0.0)
			c_ek.append(EV_NONE)
			c_xi.append(0)
			c_book.append(-1)
			c_wait.append(-1.0)
			var k: int = kinds[0]
			var r := _rng.randf()
			var acc := 0.0
			for kk in kinds:
				acc += float(CityWorld.CAR_KINDS[kk][1])
				if r <= acc:
					k = kk
					break
			c_kind.append(k)
			var col: Color = CityWorld.CAR_COLORS[_rng.randi() % CityWorld.CAR_COLORS.size()]
			c_col.append(CityWorld.TAXI_YELLOW if CityWorld.CAR_KINDS[k][0] == "car_taxi" else col)
			c_slot.append(-1)
			c_grp.append(-1)
			(l_cars[li] as Array).append(id)
			var ex: Array = l_exits[li]
			var xi := 0
			while xi < ex.size() and float(ex[xi][0]) <= s:
				xi += 1
			c_xi[id] = xi
	for id in c_lane.size():
		_schedule(id)


func car_count() -> int:
	return c_lane.size()


## Distance along the lane at time t (the shader's path_s).
func car_s(id: int, t: float) -> float:
	var s := _s_lin(id, t)
	var stop := c_stop[id]
	var e := c_ease[id]
	var u := s - (stop - e)
	if u > 0.0:
		s = stop - e + u - u * u / (4.0 * e) if u < 2.0 * e else stop
	return s


func _s_lin(id: int, t: float) -> float:
	var dt := maxf(t - c_t0[id], 0.0)
	var v := c_v[id]
	if v >= 0.0:
		return c_s0[id] + v * dt
	var x := -v * dt
	return c_s0[id] + (x * x / (4.0 * EASE) if x <= 2.0 * EASE else x - EASE)


## When the un-eased distance reaches s.
func _t_lin(id: int, s: float) -> float:
	var d := s - c_s0[id]
	if d <= 0.0:
		return c_t0[id]
	var v := c_v[id]
	if v > 0.0:
		return c_t0[id] + d / v
	if v == 0.0:
		return INF
	var x := sqrt(4.0 * EASE * d) if d <= EASE else d + EASE
	return c_t0[id] + x / -v


func car_position(id: int) -> Vector3:
	return lane_point(c_lane[id], car_s(id, now))


func _at_rest(id: int) -> bool:
	return c_stop[id] < NO_STOP and _s_lin(id, now) >= c_stop[id] + c_ease[id] - 0.01


## Speed along the lane now.
func car_speed(id: int) -> float:
	return (car_s(id, now + 0.02) - car_s(id, now - 0.02)) / 0.04 if now > 0.02 else maxf(c_v[id], 0.0)


## Carry on from where the car is, at its current speed, up to the lane's
## speed (pulling away smoothly when slower), towards `stop`. (A stop can't
## be nearer than the car's braking distance.)
func _rebase(id: int, _from_rest := false, stop := NO_STOP) -> void:
	var s := car_s(id, now)
	var v := l_v[c_lane[id]]
	var vc := clampf(car_speed(id), 0.0, v)
	if vc >= v - 0.05:
		c_s0[id] = s
		c_t0[id] = now
		c_v[id] = v
	else:
		# On the pulling-away curve at the point where its speed is vc.
		var x := 2.0 * EASE * vc / v
		c_s0[id] = s - x * x / (4.0 * EASE)
		c_t0[id] = now - x / v
		c_v[id] = -v
	if stop < NO_STOP:
		# Braking starts `ease` before the stop (in un-eased distance): the
		# full EASE when there's room, harder when there isn't.
		var lin_now := _s_lin(id, now)
		c_stop[id] = maxf(stop, lin_now + MIN_EASE)
		c_ease[id] = clampf(c_stop[id] - lin_now, MIN_EASE, EASE)
	else:
		c_stop[id] = NO_STOP
		c_ease[id] = EASE
	_dirty(id)


func _leader(id: int) -> int:
	var cs: Array = l_cars[c_lane[id]]
	var i := cs.find(id)
	return cs[i + 1] if i >= 0 and i + 1 < cs.size() else -1


func _follower(id: int) -> int:
	var cs: Array = l_cars[c_lane[id]]
	var i := cs.find(id)
	return cs[i - 1] if i > 0 else -1


## Next event from the car's current motion.
func _schedule(id: int) -> void:
	var li := c_lane[id]
	var s := car_s(id, now)
	if l_next[li] >= 0:
		c_ek[id] = EV_JOIN
		c_ev[id] = _t_lin(id, l_len[li])
		return
	var ex: Array = l_exits[li]
	var xi := c_xi[id]
	if xi < ex.size():
		c_ek[id] = EV_EXIT
		c_ev[id] = _t_lin(id, float(ex[xi][0]))
		return
	if l_loop[li]:
		c_ek[id] = EV_LOOP
		c_ev[id] = _t_lin(id, l_len[li])
		return
	if c_book[id] >= 0:
		c_ek[id] = EV_END
		c_ev[id] = _t_lin(id, l_len[li])
		return
	c_ek[id] = EV_DECIDE
	c_ev[id] = maxf(now, _t_lin(id, l_len[li] - LOOK)) if s < l_len[li] - LOOK else now


func _process(dt: float) -> void:
	now += dt
	RenderingServer.global_shader_parameter_set(&"traffic_time", now)
	for id in c_lane.size():
		if c_ev[id] <= now:
			_event(id)
	_cull_t -= dt
	if _cull_t <= 0.0:
		_cull_t = 0.2
		_cull()


func _event(id: int) -> void:
	var li := c_lane[id]
	match c_ek[id]:
		EV_JOIN:
			var to := l_next[li]
			_move_to(id, to, l_snext[li], false)
		EV_LOOP:
			c_s0[id] -= l_len[li]
			c_xi[id] = 0
			_dirty(id)
			_schedule(id)
		EV_EXIT:
			var ex: Array = l_exits[li][c_xi[id]]
			c_xi[id] += 1
			var s := car_s(id, now)
			if c_stop[id] >= NO_STOP and absf(s - float(ex[0])) < 1.5 and _rng.randf() < TURN_P \
					and _free(ex[1], now):
				_move_to(id, ex[1], 0.0, false)
			else:
				_schedule(id)
		EV_DECIDE:
			_decide(id)
		EV_END:
			if car_s(id, now) < l_len[li] - 0.6:
				c_ev[id] = now + 0.1  # (still easing in)
				return
			_move_to(id, c_book[id], 0.0, _at_rest(id))
		EV_FOLLOW:
			_follow(id)
		_:
			c_ev[id] = INF


## At a street's end: pick a way on with a gap, else stop at the line and
## look again shortly.
func _decide(id: int) -> void:
	var li := c_lane[id]
	var lead := _leader(id)
	if lead >= 0:
		if c_stop[lead] < NO_STOP:
			# Not first in the queue: wait behind.
			_queue_behind(id, lead)
			return
		# The car ahead is turning off: brake for the line meanwhile.
		if c_stop[id] >= NO_STOP:
			_rebase(id, false, l_len[li])
			var f0 := _follower(id)
			if f0 >= 0:
				_queue_behind(f0, id)
		c_ek[id] = EV_DECIDE
		c_ev[id] = now + 0.2
		return
	var ends: Array = (l_ends[li] as Array).duplicate()
	if ends.is_empty():
		c_ev[id] = INF
		return
	_shuffle(ends)
	var waited := c_wait[id] >= 0.0 and now - c_wait[id] > 9.0
	var pick := -1
	# When it would reach the line going on now, and how fast.
	var saved := [c_s0[id], c_t0[id], c_v[id], c_stop[id], c_ease[id]]
	if c_stop[id] < NO_STOP:
		_rebase(id)
	var t_line := maxf(now, _t_lin(id, l_len[li]))
	var v_in := clampf((car_s(id, t_line) - car_s(id, t_line - 0.05)) / 0.05, 0.0, l_v[li])
	for c in ends:
		if _free(c, t_line, v_in):
			pick = c
			break
	if pick < 0 or saved[3] >= NO_STOP:
		c_s0[id] = saved[0]
		c_t0[id] = saved[1]
		c_v[id] = saved[2]
		c_stop[id] = saved[3]
		c_ease[id] = saved[4]
		_dirty(id)
	if pick < 0 and waited:
		# Waited long enough: take any gap that's merely tight.
		for c in ends:
			if _free(c, t_line, v_in, true):
				pick = c
				break
	if pick < 0:
		# Stop at the line (or keep waiting there).
		if c_stop[id] >= NO_STOP:
			_rebase(id, false, l_len[li])
			c_wait[id] = now
			var f := _follower(id)
			if f >= 0:
				_queue_behind(f, id)
		elif _at_rest(id) and car_s(id, now) < l_len[li] - 1.5:
			# Parked short of the line (it was queued behind a car that has
			# since turned off): creep up to the line instead of sitting there.
			_rebase(id, true, l_len[li])
			var f2 := _follower(id)
			if f2 >= 0:
				c_ek[f2] = EV_FOLLOW
				c_ev[f2] = now + 0.7
		if c_wait[id] < 0.0:
			c_wait[id] = now
		c_ek[id] = EV_DECIDE
		c_ev[id] = now + 0.4
		return
	c_book[id] = pick
	c_wait[id] = -1.0
	_reserve(pick, t_line)
	if saved[3] < NO_STOP:
		var f := _follower(id)
		if f >= 0:
			c_ek[f] = EV_FOLLOW
			c_ev[f] = now + 0.7
	_schedule(id)


func _shuffle(a: Array) -> void:
	for i in range(a.size() - 1, 0, -1):
		var j := _rng.randi_range(0, i)
		var t = a[i]
		a[i] = a[j]
		a[j] = t


## Close up behind a stopped (or stopping) leader.
func _queue_behind(id: int, lead: int) -> void:
	if c_stop[lead] >= NO_STOP:
		_schedule(id)
		return
	var target := c_stop[lead] - GAP
	if c_stop[id] > target + 0.01 or c_stop[id] >= NO_STOP:
		_rebase(id, _at_rest(id), target)
		var f := _follower(id)
		if f >= 0:
			_queue_behind(f, id)
	c_ek[id] = EV_FOLLOW
	c_ev[id] = INF


## The car ahead moved off: once at rest, pull away (keeping behind it).
func _follow(id: int) -> void:
	var lead := _leader(id)
	var lead_slow := lead >= 0 and (c_stop[lead] < NO_STOP or c_v[lead] < 0.0)
	if c_stop[id] < NO_STOP and not _at_rest(id) and lead_slow:
		# Still braking behind a car that's only pulling away: stop, then go.
		c_ek[id] = EV_FOLLOW
		c_ev[id] = _t_lin(id, c_stop[id] + c_ease[id])
		return
	var stop := NO_STOP
	if lead >= 0 and c_stop[lead] < NO_STOP:
		stop = c_stop[lead] - GAP
		if stop <= car_s(id, now) + 2.0:
			c_ek[id] = EV_FOLLOW
			c_ev[id] = INF
			return
	_rebase(id, false, stop)
	var f := _follower(id)
	if f >= 0 and c_stop[f] < NO_STOP:
		c_ek[f] = EV_FOLLOW
		c_ev[f] = now + 0.7
	_schedule(id)


## Onto lane `to` at s (from a connector, or into one).
func _move_to(id: int, to: int, s: float, from_rest: bool) -> void:
	var old := c_lane[id]
	var f := _follower(id)
	(l_cars[old] as Array).erase(id)
	var vc := 0.0 if from_rest else car_speed(id)
	c_lane[id] = to
	c_s0[id] = s
	c_t0[id] = now
	c_v[id] = l_v[to]
	c_stop[id] = NO_STOP
	c_ease[id] = EASE
	if vc < l_v[to] - 0.05:
		# Pull away from the speed it had.
		var x := 2.0 * EASE * vc / l_v[to]
		c_s0[id] = s - x * x / (4.0 * EASE)
		c_t0[id] = now - x / l_v[to]
		c_v[id] = -l_v[to]
	c_book[id] = -1
	c_wait[id] = -1.0
	# Into the lane's car order by s.
	var cs: Array = l_cars[to]
	var at := cs.size()
	for i in cs.size():
		if car_s(cs[i], now) > s:
			at = i
			break
	cs.insert(at, id)
	var ex: Array = l_exits[to]
	var xi := 0
	while xi < ex.size() and float(ex[xi][0]) <= s + 0.5:
		xi += 1
	c_xi[id] = xi
	# Behind a queue already there.
	var lead := _leader(id)
	if lead >= 0 and c_stop[lead] < NO_STOP:
		_queue_behind(id, lead)
	else:
		_schedule(id)
	if f >= 0 and c_ek[f] == EV_FOLLOW:
		c_ev[f] = minf(c_ev[f], now + 0.7)
	_dirty(id)


## No car on (or about to join) the connector's target near where it joins,
## and the connector itself clear.
func _free(conn: int, t: float, v_in := -1.0, tight := false) -> bool:
	if not (l_cars[conn] as Array).is_empty():
		var last: int = (l_cars[conn] as Array)[0]
		if car_s(last, now) < 10.0:
			return false
	var to := l_next[conn]
	var s_to := l_snext[conn]
	var vc := l_v[conn]
	var lc := l_len[conn]
	var arrive := t + lc / maxf(vc, 1.0)
	if v_in >= 0.0 and v_in < vc:
		# From (near) rest: slower through the connector, slower onto the lane.
		var a := vc * vc / (2.0 * EASE)
		var v_end := minf(vc, sqrt(v_in * v_in + 2.0 * a * lc))
		arrive = t + (v_end - v_in) / a + maxf(lc - (v_end * v_end - v_in * v_in) / (2.0 * a), 0.0) / vc
		vc = v_end
	# A car behind on the lane closes the distance while this one gets up to speed.
	var lost := EASE * pow(1.0 - clampf(vc / l_v[to], 0.0, 1.0), 2.0) * 1.3
	var L := l_len[to]
	for k in l_cars[to]:
		var ds := car_s(k, arrive) - s_to
		if l_loop[to]:
			ds = wrapf(ds, -L * 0.5, L * 0.5)
		if (ds > -7.0 and ds < 7.0) if tight else (ds > -16.0 - lost and ds < 12.0):
			return false
	if tight:
		return true
	# Cars on other connectors into this lane, and cars that have booked one:
	# where they'll be on the lane when this one joins.
	var vt := l_v[to]
	var clash := func(s_k: float, t_k: float) -> bool:
		var ds := s_k + (arrive - t_k) * vt * (0.8 if arrive > t_k else 1.0) - s_to
		if l_loop[to]:
			ds = wrapf(ds, -L * 0.5, L * 0.5)
		return ds > -20.0 - lost and ds < 16.0
	for c2 in l_feeds[to]:
		if c2 == conn:
			continue
		for k in l_cars[c2]:
			if clash.call(l_snext[c2], _t_lin(k, l_len[c2])):
				return false
	var res: Array = _res.get(to, [])
	for i in range(res.size() - 1, -1, -1):
		var r: Array = res[i]
		if float(r[1]) < now - 3.0:
			res.remove_at(i)
		elif clash.call(float(r[0]), float(r[1])):
			return false
	return true


var _res := {}   # lane -> [[s, arrival time], ...] booked joins


func _reserve(conn: int, t: float) -> void:
	var to := l_next[conn]
	if not _res.has(to):
		_res[to] = []
	_res[to].append([l_snext[conn], t + l_len[conn] / maxf(l_v[conn], 1.0)])


# --------------------------------------------------------------- drawing
func _make_groups(meshes: Array, far_meshes: Array) -> void:
	for k in meshes.size():
		var pair: Array = []
		for far in [false, true]:
			var src: Mesh = far_meshes[k] if far else meshes[k]
			if src == null:
				pair.append(null)
				continue
			var m: Mesh = src.duplicate()
			for i in m.get_surface_count():
				var old := m.surface_get_material(i) as ShaderMaterial
				if old:
					var sm := ShaderMaterial.new()
					sm.shader = PATH_SHADER
					for p in ["tint", "use_instance_color", "emission", "roughness"]:
						sm.set_shader_parameter(p, old.get_shader_parameter(p))
					sm.set_shader_parameter("lane_tex", _tex)
					m.surface_set_material(i, sm)
			var mm := MultiMesh.new()
			mm.transform_format = MultiMesh.TRANSFORM_3D
			mm.use_colors = true
			mm.use_custom_data = true
			mm.mesh = m
			mm.instance_count = 0
			var mmi := MultiMeshInstance3D.new()
			mmi.name = "Cars_%s%s" % [CityWorld.CAR_KINDS[k][0], "_far" if far else ""]
			mmi.multimesh = mm
			mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			add_child(mmi)
			pair.append(mm)
		_groups.append(pair)
		_drawn.append([])
		_drawn.append([])


## Which cars are drawn (and at which LOD): in range and roughly in view.
func _cull() -> void:
	if _groups.is_empty():
		return
	var cam := get_viewport().get_camera_3d() if is_inside_tree() else null
	var cp := cam.global_position if cam else Vector3.ZERO
	var fw := -cam.global_basis.z if cam else Vector3.FORWARD
	var cos_lim := -1.0
	if cam:
		var vs := get_viewport().get_visible_rect().size
		var aspect := vs.x / maxf(vs.y, 1.0)
		var half := atan(tan(deg_to_rad(cam.fov) * 0.5) * sqrt(1.0 + aspect * aspect))
		cos_lim = cos(minf(half + deg_to_rad(18.0), PI * 0.5 - 0.01))
	var lists: Array = []
	for g in _groups.size() * 2:
		lists.append([])
	var nr2 := near_range * near_range
	var fr2 := far_range * far_range
	for id in c_lane.size():
		var p := car_position(id)
		var d := p - cp
		var d2 := d.length_squared()
		var g := -1
		if d2 < fr2:
			var dist := sqrt(d2)
			if dist < 35.0 or d.dot(fw) > dist * cos_lim:
				g = c_kind[id] * 2 + (0 if d2 < nr2 else 1)
		if g >= 0:
			c_grp[id] = g
			c_slot[id] = (lists[g] as Array).size()
			lists[g].append(id)
		else:
			c_grp[id] = -1
			c_slot[id] = -1
	var box := AABB(cp - Vector3(far_range, far_range, far_range), Vector3.ONE * far_range * 2.0)
	for g in lists.size():
		var mm: MultiMesh = _groups[g / 2][g % 2]
		if mm == null:
			continue
		var ids: Array = lists[g]
		var buf := PackedFloat32Array()
		buf.resize(ids.size() * 20)
		var j := 0
		for id in ids:
			_write(buf, j, id)
			j += 20
		if mm.instance_count != ids.size():
			mm.instance_count = ids.size()
		if not ids.is_empty():
			mm.buffer = buf
		mm.custom_aabb = box
		_drawn[g] = ids


## Instance data: the "transform" rows carry the motion (traffic_path.gdshader).
func _write(buf: PackedFloat32Array, j: int, id: int) -> void:
	buf[j] = float(l_base[c_lane[id]]); buf[j + 1] = c_s0[id]; buf[j + 2] = c_t0[id]; buf[j + 3] = c_v[id]
	buf[j + 4] = c_stop[id]; buf[j + 5] = c_ease[id]; buf[j + 6] = 0.0; buf[j + 7] = 0.0
	buf[j + 8] = 0.0; buf[j + 9] = 0.0; buf[j + 10] = 0.0; buf[j + 11] = 0.0
	var col: Color = c_col[id]
	buf[j + 12] = col.r; buf[j + 13] = col.g; buf[j + 14] = col.b; buf[j + 15] = 1.0
	buf[j + 16] = 0.0; buf[j + 17] = 0.0; buf[j + 18] = 0.0; buf[j + 19] = 0.0


func _motion(id: int) -> Transform3D:
	# Transform3D(x, y, z, origin) columns: row 0 = (x.x, y.x, z.x, o.x).
	return Transform3D(Vector3(float(l_base[c_lane[id]]), c_stop[id], 0.0), Vector3(c_s0[id], c_ease[id], 0.0),
		Vector3(c_t0[id], 0.0, 0.0), Vector3(c_v[id], 0.0, 0.0))


## A drawn car's motion changed: update its instance now.
func _dirty(id: int) -> void:
	var g := c_grp[id]
	if g < 0 or c_slot[id] < 0:
		return
	var mm: MultiMesh = _groups[g / 2][g % 2]
	if mm == null or c_slot[id] >= mm.instance_count:
		return
	mm.set_instance_transform(c_slot[id], _motion(id))
