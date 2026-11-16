class_name LcsRoadSites
extends RefCounted
## Mutually reachable road nodes; both directions must connect to the bridge.
var sites: Array[Transform3D] = []
var categories := {"bridge": [], "industrial": [], "waterfront": [], "streets": []}

static func city_layout() -> CityLayout:
	# All generation is synchronous here; restore the shared default before returning.
	var previous := CityRoads.parallel_field_bake
	CityRoads.parallel_field_bake = false
	var layout := CityLayout.new().generate()
	CityRoads.parallel_field_bake = previous
	return layout

func build(net: RoadNet, layout: CityLayout) -> void:
	var bridge := net.nearest(Vector3(-200, CityLayout.BRIDGE_DECK, CityLayout.BRIDGE_Z), Vector3.ZERO, 100.0)
	if bridge.is_empty():
		return
	var start := net.node_after(bridge.lane, bridge.s)
	var forward := reachable(start, net.out_edges)
	var backward := reachable(start, net.in_edges)
	# Include bridge mid-span, which has no junction nodes of its own.
	for lane in net.lanes.size():
		var distance := 12.0
		while distance < net.lane_len[lane] - 6.0:
			var before := -1
			var after := -1
			for node in net.lane_nodes[lane]:
				if net.node_s[node] <= distance:
					before = node
				if net.node_s[node] >= distance and after == -1:
					after = node
			if forward.has(before) and backward.has(before) and forward.has(after) and backward.has(after):
				var p := net.lane_point(lane, distance)
				_add_site(p, net.lane_dir(lane, distance), layout)
			distance += 24.0

func _add_site(p: Vector3, direction: Vector3, layout: CityLayout) -> void:
	if layout.is_water(p) and p.y < Car.WATER_Y + 2.0:
		return
	for xf in sites:
		if xf.origin.distance_squared_to(p) < 18.0 * 18.0:
			return
	sites.append(Transform3D(Basis.looking_at(direction), p + Vector3.UP * 0.5))
	var category := "streets"
	if p.x > -430 and p.x < 50 and absf(p.z - CityLayout.BRIDGE_Z) < 25:
		category = "bridge"
	elif p.z < -330:
		category = "industrial"
	elif absf(p.x - CityLayout.RIVER_EDGE) < 110 or absf(p.x - CityLayout.FAR_SHORE) < 110:
		category = "waterfront"
	categories[category].append(p)

static func reachable(start: int, edges: Array) -> Dictionary:
	var seen := {}
	if start < 0:
		return seen
	var stack := [start]
	while not stack.is_empty():
		var i: int = stack.pop_back()
		if seen.has(i):
			continue
		seen[i] = true
		for neighbor in edges[i]:
			if not seen.has(neighbor):
				stack.append(neighbor)
	return seen

func final_site(rng: RandomNumberGenerator) -> Vector3:
	var available: Array = []
	for values in categories.values():
		if not values.is_empty():
			available.append(values)
	if available.is_empty():
		return Vector3.INF
	var group: Array = available[rng.randi_range(0, available.size() - 1)]
	return group[rng.randi_range(0, group.size() - 1)]

func spawns(count: int, rng: RandomNumberGenerator) -> Array[Transform3D]:
	var candidates := sites.duplicate()
	var out: Array[Transform3D] = []
	# Seeded Fisher-Yates; minimum spacing is guaranteed by build().
	for i in range(candidates.size() - 1, 0, -1):
		var j := rng.randi_range(0, i)
		var swap: Transform3D = candidates[i]
		candidates[i] = candidates[j]
		candidates[j] = swap
	# Guarantee both islands participate, even in a small two-player room.
	if count >= 2:
		for mainland in [false, true]:
			for xf in candidates:
				if (mainland and xf.origin.x < -440.0) or (not mainland and xf.origin.x > 70.0):
					out.append(xf)
					break
	for xf in candidates:
		if out.size() >= count:
			break
		if not out.has(xf):
			out.append(xf)
	return out
