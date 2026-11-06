class_name RoadNet
extends RefCounted
## The shared road graph every AI driver uses.
##
## Built from CitySwing's lane network (Traffic.build_network: lanes each way,
## curved connectors through every junction and roundabout, the bridge
## roadway) for the island and the mainland, merged into one set of lanes and
## stitched where the bridge roadway meets Westbank's streets.
##
## Graph: nodes are junction points on lanes (lane starts/ends, every exit
## and every join), edges run along lanes and through connectors. Routing is
## a *flow field*: one reverse Dijkstra from a target fills `dist` for every
## node, and any number of units read their next hop from it – the cached,
## shared pathfinding the pursuit needs for dozens of units.

const STEP := Traffic.STEP
const CELL := 24.0

var lanes: Array = []                    # PackedVector3Array per lane (3 m spacing)
var lane_len := PackedFloat32Array()
var lane_loop := PackedByteArray()
var lane_speed := PackedFloat32Array()   # free-flow m/s for civilians
var lane_conn := PackedByteArray()       # 1 = junction connector
var lane_nodes: Array = []               # per lane: PackedInt32Array node ids, sorted by s
var node_lane := PackedInt32Array()
var node_s := PackedFloat32Array()
var node_pos := PackedVector3Array()
var out_edges: Array = []                # per node: PackedInt32Array [to, ...]
var out_cost: Array = []                 # per node: PackedFloat32Array
var in_edges: Array = []
var in_cost: Array = []
var _grid := {}                          # Vector2i -> PackedInt32Array of (lane << 12 | index)
var lane_next_choices: Array = []        # per lane: [[s, lane_to, s_to], ...] turn options (exits + end)


func build(layout: CityLayout) -> RoadNet:
	var lands: Array = [layout]
	if layout.mainland:
		lands.append(layout.mainland)
	var offs: Array = []
	var nets: Array = []
	for lay in lands:
		var tr := Traffic.new()
		tr.layout = lay
		tr.build_network()
		offs.append(lanes.size())
		nets.append(tr)
		for li in tr.lane_count():
			lanes.append(tr._lane_pts[li])
			lane_len.append(tr.l_len[li])
			lane_loop.append(tr.l_loop[li])
			lane_speed.append(tr.l_v[li])
			lane_conn.append(1 if tr.l_next[li] >= 0 else 0)
			lane_next_choices.append([])
	# Turn options, in merged ids.
	for ni in nets.size():
		var tr: Traffic = nets[ni]
		var o: int = offs[ni]
		for li in tr.lane_count():
			var ch: Array = lane_next_choices[li + o]
			for ex in tr.l_exits[li]:
				ch.append([float(ex[0]), int(ex[1]) + o, 0.0])
			for c in tr.l_ends[li]:
				if int(c) >= 0:
					ch.append([float(tr.l_len[li]), int(c) + o, 0.0])
			if tr.l_next[li] >= 0:
				ch.append([float(tr.l_len[li]), tr.l_next[li] + o, float(tr.l_snext[li])])
	_index()
	_stitch()
	for tr in nets:
		tr.free()
	_build_graph()
	return self


func _index() -> void:
	_grid.clear()
	for li in lanes.size():
		var lp: PackedVector3Array = lanes[li]
		for i in lp.size():
			var k := Vector2i(floori(lp[i].x / CELL), floori(lp[i].z / CELL))
			var cell: PackedInt32Array = _grid.get(k, PackedInt32Array())
			cell.append((li << 12) | i)
			_grid[k] = cell  # (packed arrays are values: write back)


## Lane ends with nowhere to go (the bridge roadway's far end, Westbank's
## streets that meet it) join the nearest lane heading on within 30 m.
func _stitch() -> void:
	for li in lanes.size():
		if lane_loop[li] == 1:
			continue
		var lp: PackedVector3Array = lanes[li]
		var e := lp[-1]
		# Only where the bridge roadway meets Westbank.
		if absf(e.x - CityLayout.APPROACH_END) > 80.0 or absf(e.z - CityLayout.BRIDGE_Z) > 80.0:
			continue
		var de := lane_dir(li, lane_len[li] - 1.5)
		# Nearest lane point on the *other* land heading the same way.
		var m := -1
		var ms := 0.0
		var md := 30.0
		for lj in lanes.size():
			if _same_land(li, lj) or lane_conn[lj] == 1:
				continue
			var lq: PackedVector3Array = lanes[lj]
			for k in lq.size():
				var dd := lq[k].distance_to(e)
				if dd < md and lane_dir(lj, k * STEP).dot(de) > 0.3 and (lq[k] - e).dot(de) > -2.0:
					md = dd
					m = lj
					ms = k * STEP
		if m < 0:
			continue
		var s: float = minf(ms + 3.0, lane_len[m])
		(lane_next_choices[li] as Array).append([lane_len[li], m, s])


func _same_land(a: int, b: int) -> bool:
	return (lanes[a][0] as Vector3).x > -100.0 == ((lanes[b][0] as Vector3).x > -100.0)


func _build_graph() -> void:
	# Node positions on each lane: start, end, every turn-off and every join.
	var marks: Array = []
	for li in lanes.size():
		marks.append({0.0: true, snappedf(lane_len[li], 0.01): true})
	for li in lanes.size():
		for c in lane_next_choices[li]:
			marks[li][snappedf(float(c[0]), 0.01)] = true
			marks[int(c[1])][snappedf(float(c[2]), 0.01)] = true
	lane_nodes.clear()
	for li in lanes.size():
		var ss: Array = marks[li].keys()
		ss.sort()
		var ids := PackedInt32Array()
		for s in ss:
			var sf := clampf(float(s), 0.0, lane_len[li])
			ids.append(node_lane.size())
			node_lane.append(li)
			node_s.append(sf)
			node_pos.append(lane_point(li, sf))
			out_edges.append(PackedInt32Array())
			out_cost.append(PackedFloat32Array())
			in_edges.append(PackedInt32Array())
			in_cost.append(PackedFloat32Array())
		lane_nodes.append(ids)
	for li in lanes.size():
		var ids: PackedInt32Array = lane_nodes[li]
		for k in ids.size() - 1:
			_edge(ids[k], ids[k + 1], node_s[ids[k + 1]] - node_s[ids[k]])
		if lane_loop[li] == 1 and ids.size() > 1:
			_edge(ids[-1], ids[0], 0.01)
		for c in lane_next_choices[li]:
			var a := node_at(li, float(c[0]))
			var b := node_at(int(c[1]), float(c[2]))
			if a >= 0 and b >= 0 and a != b:
				_edge(a, b, 0.5)


func _edge(a: int, b: int, cost: float) -> void:
	# (packed arrays are values: modify and write back)
	var oe: PackedInt32Array = out_edges[a]
	oe.append(b)
	out_edges[a] = oe
	var oc: PackedFloat32Array = out_cost[a]
	oc.append(maxf(cost, 0.01))
	out_cost[a] = oc
	var ie: PackedInt32Array = in_edges[b]
	ie.append(a)
	in_edges[b] = ie
	var ic: PackedFloat32Array = in_cost[b]
	ic.append(maxf(cost, 0.01))
	in_cost[b] = ic


func node_at(lane: int, s: float) -> int:
	var ids: PackedInt32Array = lane_nodes[lane]
	var best := -1
	var bd := 0.6
	for id in ids:
		var d := absf(node_s[id] - s)
		if d < bd:
			bd = d
			best = id
	return best


func node_count() -> int:
	return node_lane.size()


func lane_point(lane: int, s: float) -> Vector3:
	var lp: PackedVector3Array = lanes[lane]
	var n := lp.size()
	var f := s / STEP
	if lane_loop[lane] == 1:
		f = fposmod(f, float(n - 1))
	else:
		f = clampf(f, 0.0, n - 1.001)
	var i := int(f)
	return lp[i].lerp(lp[mini(i + 1, n - 1)], f - i)


func lane_dir(lane: int, s: float) -> Vector3:
	var d := lane_point(lane, s + 1.5) - lane_point(lane, s - 1.5)
	d.y = 0.0
	return d.normalized() if d.length_squared() > 1e-6 else Vector3.FORWARD


## Nearest lane point to p: {lane, s, dist, pos}. With a heading, lanes going
## the other way cost extra (so a car picks its own side of the road).
func nearest(p: Vector3, heading := Vector3.ZERO, max_d := 40.0, exclude := -1, skip_conn := false) -> Dictionary:
	var best := {}
	var bscore := INF
	var r := int(ceil(max_d / CELL))
	var k0 := Vector2i(floori(p.x / CELL), floori(p.z / CELL))
	for dx in range(-r, r + 1):
		for dz in range(-r, r + 1):
			var key := k0 + Vector2i(dx, dz)
			if not _grid.has(key):
				continue
			var cell: PackedInt32Array = _grid[key]
			for code: int in cell:
				var li: int = code >> 12
				if li == exclude or (skip_conn and lane_conn[li] == 1):
					continue
				var i: int = code & 4095
				var q: Vector3 = (lanes[li] as PackedVector3Array)[i]
				var d := Vector2(q.x - p.x, q.z - p.z).length() + maxf(0.0, absf(q.y - p.y) - 5.0) * 2.0
				if d > max_d or d >= bscore:
					continue
				var score := d
				if heading != Vector3.ZERO:
					var dd := lane_dir(li, i * STEP)
					score += (1.0 - dd.dot(heading)) * 6.0
				if score < bscore:
					bscore = score
					best = {"lane": li, "s": i * STEP, "dist": d, "pos": q}
	return best


## Next graph node at or after s on a lane.
func node_after(lane: int, s: float) -> int:
	var ids: PackedInt32Array = lane_nodes[lane]
	for id in ids:
		if node_s[id] >= s - 0.01:
			return id
	if lane_loop[lane] == 1 and ids.size() > 0:
		return ids[0]
	return ids[-1] if ids.size() > 0 else -1


# ------------------------------------------------------------- flow fields
class Field:
	var dist: PackedFloat32Array
	var target: Vector3
	var lane := -1
	var s := 0.0
	var time := 0.0


## Reverse Dijkstra from the lane node nearest `target`: dist[n] = road metres
## from node n to the target.
func flow_field(target: Vector3, heading := Vector3.ZERO) -> Field:
	var f := Field.new()
	f.target = target
	var n := node_count()
	f.dist = PackedFloat32Array()
	f.dist.resize(n)
	f.dist.fill(INF)
	var near := nearest(target, heading, 80.0)
	if near.is_empty():
		near = nearest(target, Vector3.ZERO, 400.0)
	if near.is_empty():
		return f
	# Seed: the nodes either side of the target on its lane.
	var lane: int = near["lane"]
	f.lane = lane
	f.s = near["s"]
	var ids: PackedInt32Array = lane_nodes[lane]
	var heap_d := PackedFloat32Array()
	var heap_n := PackedInt32Array()
	for id in ids:
		var dd := node_s[id] - float(near["s"])
		if dd <= 0.0 or lane_loop[lane] == 1:
			var c := absf(dd)
			f.dist[id] = c
			_push(heap_d, heap_n, c, id)
	while heap_n.size() > 0:
		var top := _pop(heap_d, heap_n)
		var d: float = top[0]
		var u: int = top[1]
		if d > f.dist[u]:
			continue
		var ie: PackedInt32Array = in_edges[u]
		var ic: PackedFloat32Array = in_cost[u]
		for k in ie.size():
			var v := ie[k]
			var nd := d + ic[k]
			if nd < f.dist[v]:
				f.dist[v] = nd
				_push(heap_d, heap_n, nd, v)
	return f


## Road distance from a lane position to the field's target (INF if none).
func field_distance(f: Field, lane: int, s: float) -> float:
	var id := node_after(lane, s)
	if id < 0:
		return INF
	return f.dist[id] + maxf(0.0, node_s[id] - s)


## Points to drive along toward the field's target, starting at (lane, s):
## ~`ahead` metres of road, following the downhill of the field at each
## junction.
func route(f: Field, lane: int, s: float, ahead: float) -> PackedVector3Array:
	var out := PackedVector3Array()
	var cur_lane := lane
	var cur_s := s
	var travelled := 0.0
	var guard := 0
	while travelled < ahead and guard < 200:
		guard += 1
		# On the target's lane, short of it: drive the last bit and stop.
		if cur_lane == f.lane and cur_s <= f.s:
			var ts := cur_s
			while ts < f.s and travelled < ahead:
				out.append(lane_point(cur_lane, ts))
				ts += STEP
				travelled += STEP
			out.append(f.target)
			break
		var id := node_after(cur_lane, cur_s)
		if id < 0:
			break
		var end_s := node_s[id]
		if lane_loop[cur_lane] == 1 and end_s < cur_s:
			end_s += lane_len[cur_lane]
		var ss := cur_s
		while ss < end_s and travelled < ahead:
			out.append(lane_point(cur_lane, ss))
			ss += STEP
			travelled += STEP
		if travelled >= ahead:
			break
		# Best successor by field distance.
		var best := -1
		var bd := INF
		var oe: PackedInt32Array = out_edges[id]
		var oc: PackedFloat32Array = out_cost[id]
		for k in oe.size():
			var v := oe[k]
			var d := f.dist[v] + oc[k]
			if d < bd:
				bd = d
				best = v
		if best < 0 or bd == INF:
			break
		if f.dist[id] < 2.0:
			out.append(f.target)
			break
		cur_s = _advance_s(id, best)
		cur_lane = node_lane[best]
	if out.is_empty():
		out.append(lane_point(lane, s))
	return out


## A random onward route (civilians, patrols): follow the lane, take a turn
## at junctions with probability p_turn.
func wander(lane: int, s: float, ahead: float, rng: RandomNumberGenerator, p_turn := 0.35) -> PackedVector3Array:
	var out := PackedVector3Array()
	var cur_lane := lane
	var cur_s := s
	var travelled := 0.0
	var guard := 0
	while travelled < ahead and guard < 32:
		guard += 1
		var id := node_after(cur_lane, cur_s)
		if id < 0:
			break
		var end_s := node_s[id]
		if lane_loop[cur_lane] == 1 and end_s < cur_s:
			end_s += lane_len[cur_lane]
		var ss := cur_s
		while ss < end_s and travelled < ahead:
			out.append(lane_point(cur_lane, ss))
			ss += STEP
			travelled += STEP
		var oe: PackedInt32Array = out_edges[id]
		if oe.is_empty():
			break
		var pick := oe[0]
		# Prefer staying on the lane unless turning.
		for v in oe:
			if node_lane[v] == cur_lane:
				pick = v
		if oe.size() > 1 and rng.randf() < p_turn:
			pick = oe[rng.randi() % oe.size()]
		cur_s = _advance_s(id, pick)
		cur_lane = node_lane[pick]
	return out


## Where driving resumes after taking edge a -> b: along the same lane we
## carry on from a (so the road up to b is driven, not skipped); onto
## another lane (a connector, a join) we start at b.
func _advance_s(a: int, b: int) -> float:
	if node_lane[a] == node_lane[b] and node_s[b] > node_s[a]:
		return node_s[a] + 0.05   # (past a, so node_after finds b)
	return node_s[b]              # (node_after finds b itself: its turn options apply)


static func _push(hd: PackedFloat32Array, hn: PackedInt32Array, d: float, n: int) -> void:
	hd.append(d)
	hn.append(n)
	var i := hd.size() - 1
	while i > 0:
		var p := (i - 1) >> 1
		if hd[p] <= hd[i]:
			break
		var td := hd[p]
		hd[p] = hd[i]
		hd[i] = td
		var tn := hn[p]
		hn[p] = hn[i]
		hn[i] = tn
		i = p


static func _pop(hd: PackedFloat32Array, hn: PackedInt32Array) -> Array:
	var top := [hd[0], hn[0]]
	var last := hd.size() - 1
	hd[0] = hd[last]
	hn[0] = hn[last]
	hd.resize(last)
	hn.resize(last)
	var i := 0
	var n := last
	while true:
		var l := 2 * i + 1
		var r := l + 1
		var m := i
		if l < n and hd[l] < hd[m]:
			m = l
		if r < n and hd[r] < hd[m]:
			m = r
		if m == i:
			break
		var td := hd[m]
		hd[m] = hd[i]
		hd[i] = td
		var tn := hn[m]
		hn[m] = hn[i]
		hn[i] = tn
		i = m
	return top
