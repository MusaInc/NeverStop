class_name CityWorld
extends Node3D
## The procedural city at runtime.
##  * Collision for every building tier is created up front (cheap boxes on the
##    world + grappleable layers), so traversal never depends on streaming.
##  * Visuals stream by distance in 200 m chunks: mesh arrays are generated on
##    worker threads (~1.6 ms/chunk on the dev VPS) and turned into nodes on
##    the main thread, a couple per frame.
##  * Each chunk has a detailed LOD (cornices, plinths) and a low LOD (plain
##    massing) switched with visibility ranges, MultiMesh props with short
##    ranges, GPU-animated traffic, and an occluder for occlusion culling.

const CHUNK := CityLayout.CHUNK
## Street furniture, lamp posts, trunks, roof units and parked cars: solid to
## the body (and ragdoll), but not web targets and not in the way of webs.
const PROPS_LAYER := 1 << 4
## Solid for people only (Player sets mask bit 6 for humans): trains,
## balconies, rooftop plant – detail bots and recorded courses ignore.
const HUMAN_LAYER := 1 << 5
const HUMAN_ONLY_PROPS := ["cooling_tower"]
const MODEL_DIR := "res://assets/models/"
const PROP_RANGES := {
	"streetlight": 260.0, "tree": 320.0, "water_tower": 520.0, "ac_unit": 240.0, "antenna": 700.0, "crane": 1200.0,
	"traffic_light": 220.0, "roof_hut": 650.0, "tree_tall": 320.0, "cooling_tower": 450.0,
}
## Street furniture (tools/blender/build_street.py), merged into one mesh per
## chunk: [kind, inset from the kerb line (m)].
const FURNITURE := ["bench", "bin", "hydrant", "bollard", "sign_post", "bus_shelter", "planter"]
const FURNITURE_RANGE := 190.0
## Traffic models (tools/blender/build_cars.py) and how common each is.
const CAR_KINDS := [["car_sedan", 0.32], ["car_hatch", 0.25], ["car_suv", 0.2], ["car_taxi", 0.13], ["car_van", 0.1]]
const TAXI_YELLOW := Color(0.98, 0.76, 0.12)
const CAR_COLORS := [Color(0.85, 0.85, 0.83), Color(0.1, 0.1, 0.11), Color(0.62, 0.08, 0.07), Color(0.12, 0.24, 0.45),
	Color(0.55, 0.57, 0.6), Color(0.9, 0.72, 0.15), Color(0.2, 0.35, 0.3)]

var layout: CityLayout
var viewer: Node3D
var detail_range := 380.0
## Fire escapes, fins, portals, chimneys: small detail, drawn nearer than the
## detailed LOD (they still collide at any distance).
var feature_range := 190.0
## The streamed chunk grid: its ground is drawn per chunk; beyond it, the
## outskirts draw (and collide) a coarser ground.
var grid_rect := Rect2()
var view_distance := 900.0
var prop_density := 1.0
var traffic_density := 1.0
var traffic: Traffic
## CitySwing's GPU-animated traffic has no collision: off in NEVER STOP
## (CivilianTraffic drives real cars instead).
var gpu_traffic := false
## Street furniture knocked down this session (Destructibles): item key ->
## true. Filtered out of chunk_props / chunk_furniture, so a chunk that
## streams back in doesn't resurrect it.
var broken := {}
## Props cars crash into rather than flatten (on their own collision layer).
## Trees used to be here too; they're knocked down now (Destructibles) -
## street trees line every pavement and were too hard to avoid at speed.
const SOLID_PROPS := ["bus_shelter", "planter"]
const SOLID_LAYER := 1 << 7
var max_builds_per_frame := 2

var building_mat: ShaderMaterial
var ground_mat: ShaderMaterial
var water_mat: ShaderMaterial
var prop_meshes := {}
var car_meshes: Array[Mesh] = []  # CAR_KINDS order; null where the model is missing
var car_far_meshes: Array[Mesh] = []  # two-box stand-ins (24 tris) for chunks past CAR_NEAR
## Full car models only in chunks this close (centre distance); 1 650 tris each
## is wasted on a car a few pixels long.
const CAR_NEAR := 260.0
const CAR_FAR := 520.0
var walker_mesh: Mesh
var furniture_mat: StandardMaterial3D
var trains: Trains
var sea_sky: SeaAndSky   # port ships, boats, helicopter, airliner, gulls (visual only)
var ads: AdScreens
var _lamp_mat: BaseMaterial3D   # the streetlight head's emissive material (brightened at night)
var _lamp_base := 1.0
var _glow_mats: Array[ShaderMaterial] = []  # [pool, halo]
var _glow_meshes: Array[Mesh] = []  # [pool (PlaneMesh), halo (QuadMesh)]
var _glow_nodes: Array = []
var _glow_on := false
## Lamp head in the streetlight model's frame (build_kit.py streetlight()).
const LAMP_HEAD := Vector3(0.0, 6.72, -1.45)
var _furn_src := {}             # kind -> [verts, normals, colors, indices] (material colours baked in)
var _furniture_by_chunk := {}   # Vector2i -> Array of [kind, Transform3D]
var _walk_paths: Array = []  # [from, to] pavement segments (directional)
const WALKER_RANGE := 130.0
const CLOTHES := [Color(0.85, 0.85, 0.82), Color(0.12, 0.13, 0.16), Color(0.55, 0.12, 0.12), Color(0.16, 0.28, 0.5),
	Color(0.36, 0.42, 0.3), Color(0.75, 0.6, 0.35), Color(0.45, 0.45, 0.48), Color(0.62, 0.36, 0.5), Color(0.2, 0.45, 0.48)]

var _by_chunk := {}
var _props_by_chunk := {}
var _all_keys: Array[Vector2i] = []
var _loaded := {}      # key -> Node3D
var _pending := {}     # key -> WorkerThreadPool task id
var _results := {}     # key -> Dictionary of mesh arrays
var _mutex := Mutex.new()
var _want := {}        # key -> distance, from the latest streaming update
var chunks_built := 0
var gen_ms_total := 0.0


## The mainland (Westbank) is a second CityWorld, `secondary`, streaming its
## own layout (CityLayout.generate_mainland) as a child of the island's.
var secondary := false
var mainland: CityWorld


func _ready() -> void:
	var t0 := Time.get_ticks_msec()
	if layout == null:
		layout = CityLayout.new().generate()
	_by_chunk = layout.buildings_by_chunk()
	_props_by_chunk = layout.props_by_chunk()
	var settings := get_node_or_null("/root/Settings")
	if settings:
		var p: Dictionary = settings.preset()
		view_distance = p["view_distance"]
		prop_density = p["props"]
		traffic_density = p["traffic"]
		detail_range = minf(380.0, view_distance * 0.45)
	_materials()
	_load_props()
	var land := layout.island.grow(130.0)  # (the shore apron reaches past the coast)
	var kx := Vector2i(floori(land.position.x / CHUNK) - 1, ceili(land.end.x / CHUNK))
	var kz := Vector2i(floori(land.position.y / CHUNK), ceili(land.end.y / CHUNK))
	grid_rect = Rect2(kx.x * CHUNK, kz.x * CHUNK, (kx.y - kx.x) * CHUNK, (kz.y - kz.x) * CHUNK)
	for cx in range(kx.x, kx.y):
		for cz in range(kz.x, kz.y):
			_all_keys.append(Vector2i(cx, cz))
	for key in _by_chunk:
		if not key in _all_keys:
			_all_keys.append(key)  # e.g. the far bridge anchorage across the river
	_build_collision()
	_build_prop_collision()
	if not secondary:
		_build_water()
	_build_landmarks()
	_build_structures()
	if not secondary:
		ads = AdScreens.new()
		ads.name = "Ads"
		add_child(ads)
		ads.build(layout)
	if gpu_traffic and traffic_density > 0.0 and not car_meshes.is_empty():
		traffic = Traffic.new()
		traffic.name = "Traffic"
		traffic.near_range = CAR_NEAR
		traffic.far_range = CAR_FAR
		add_child(traffic)
		traffic.setup(layout, car_meshes, car_far_meshes, traffic_density)
	trains = Trains.new()
	trains.name = "Trains"
	add_child(trains)
	trains.setup(layout.rail.lines, _load_mesh("train_car"), _load_mesh("train_cab"))
	sea_sky = SeaAndSky.new()
	sea_sky.name = "SeaAndSky"
	add_child(sea_sky)
	sea_sky.setup(layout)
	_bake_street_maps()
	if secondary:
		print("Mainland: %d buildings, %d chunks, %d ms" % [layout.buildings.size(), _all_keys.size(),
			Time.get_ticks_msec() - t0])
		return
	_bake_ground_height()
	_build_birds()
	var hinter := Hinterland.new()
	hinter.name = "Hinterland"
	add_child(hinter)
	mainland = CityWorld.new()
	mainland.name = "Mainland"
	mainland.secondary = true
	# (The island's layout made Westbank's already: the railway crosses to it.)
	mainland.layout = layout.mainland if layout.mainland else CityLayout.new().generate_mainland(layout.seed)
	add_child(mainland)
	layout.mainland = mainland.layout
	# (The bridge's anchor lines are the island layout's; the mainland's
	# approach viaduct edges join them.)
	print("CityWorld: %d buildings, %d props, %d chunks, layout+collision %d ms" % [
		layout.buildings.size(), layout.props.size(), _all_keys.size(), Time.get_ticks_msec() - t0])


func _exit_tree() -> void:
	for task in _pending.values():
		WorkerThreadPool.wait_for_task_completion(task)
	_pending.clear()
	_results.clear()


func set_viewer(v: Node3D) -> void:
	viewer = v
	if mainland:
		mainland.set_viewer(v)


func spawn_point() -> Vector3:
	# A tall rooftop near the business district with open avenue ahead.
	var best: Dictionary = {}
	var best_score := -INF
	for b in layout.buildings:
		if b["kind"] != "normal":
			continue
		var t: Array = b["tiers"][-1]
		var tc := CityLayout.top_center(b)
		var c := Vector2(tc.x, tc.z)
		var h: float = t[5] - BuildingMesher.base_of(b)  # above its street
		if h < 55.0 or h > 95.0 or t[2] - t[0] < 14.0 or t[3] - t[1] < 14.0 or b.get("roof_blocked", false):
			continue
		var s := -c.distance_to(CityLayout.CBD_CENTER + Vector2(-60, 260)) - absf(h - 75.0) * 2.0
		if s > best_score:
			best_score = s
			best = b
	if best.is_empty():
		return Vector3(300, 120, 0)
	var tc := CityLayout.top_center(best)
	return Vector3(tc.x, BuildingMesher.roof_y(best) + 2.0, tc.z)


## Clearance (m) to keep from each kind of rooftop prop when standing.
const PROP_CLEARANCE := {"water_tower": 6.0, "ac_unit": 4.0, "antenna": 3.0, "roof_hut": 5.5, "cooling_tower": 5.0}
const ROOF_EDGE_CLEARANCE := 4.5

var _roof_spawns: Array = []
var _ground_cache := {}  # chunk key -> ground mesh arrays (built with the collision, at startup)
var _ground_meshers: Array = []
var _ground_lock := Mutex.new()


func _ground_task(i: int) -> void:
	var gm := BuildingMesher.new()
	var key: Vector2i = _all_keys[i]
	gm.add_ground(layout, Rect2(Vector2(key) * CHUNK, Vector2(CHUNK, CHUNK)))
	_ground_lock.lock()
	_ground_meshers[i] = gm
	_ground_lock.unlock()





func bot_heading() -> Vector3:
	return Vector3.FORWARD


## Autopilot goal: 90 m on along a boulevard. The bot keeps to its road and
## direction (picked from the nearest boulevard and the way it was moving)
## until it strays from it; at the coast it turns back.
func bot_goal(p: Node3D) -> Vector3:
	if _boulevards.is_empty():
		for name in ["diagonal", "spine", "valley", "heights", "crescent", "inner"]:
			var r: Dictionary = layout.roads.by_name.get(name, {})
			if not r.is_empty():
				_boulevards.append(r["pts"])
	var q := Vector2(p.global_position.x, p.global_position.z)
	var id := p.get_instance_id()
	var st: Dictionary = _goal_state.get(id, {})
	var bi := -1
	if not st.is_empty():
		var pts0: PackedVector2Array = _boulevards[st["road"]]
		var bd := INF
		for i in pts0.size():
			var d := pts0[i].distance_squared_to(q)
			if d < bd:
				bd = d
				bi = i
		if bd > 80.0 * 80.0:
			st = {}
	if st.is_empty():
		var best_d := INF
		for ri in _boulevards.size():
			var pts1: PackedVector2Array = _boulevards[ri]
			for i in range(0, pts1.size(), 2):
				var d := pts1[i].distance_squared_to(q)
				if d < best_d:
					best_d = d
					st = {"road": ri}
					bi = i
		if st.is_empty():
			return p.global_position + Vector3.FORWARD * 90.0
		var pts2: PackedVector2Array = _boulevards[st["road"]]
		var v := Vector3.FORWARD
		if "velocity" in p and (p.velocity as Vector3).length() > 3.0:
			v = p.velocity
		var fwd := pts2[mini(bi + 1, pts2.size() - 1)] - pts2[maxi(bi - 1, 0)]
		st["dir"] = 1 if fwd.dot(Vector2(v.x, v.z)) >= 0.0 else -1
		_goal_state[id] = st
	var bp: PackedVector2Array = _boulevards[st["road"]]
	var j: int = bi + 15 * int(st["dir"])
	if j < 0 or j >= bp.size():
		st["dir"] = -int(st["dir"])  # the coast: turn back
		j = bi + 15 * int(st["dir"])
	j = clampi(j, 0, bp.size() - 1)
	return Vector3(bp[j].x, 0.0, bp[j].y)


var _goal_state := {}  # player instance id -> {road, dir}
var _boulevards: Array = []


func is_water(p: Vector3) -> bool:
	return layout.is_water(p)


# ------------------------------------------------------------- materials
func _materials() -> void:
	building_mat = ShaderMaterial.new()
	building_mat.shader = load("res://src/world/shaders/building.gdshader")
	ground_mat = ShaderMaterial.new()
	ground_mat.shader = load("res://src/world/shaders/ground.gdshader")
	water_mat = ShaderMaterial.new()
	water_mat.shader = load("res://src/world/shaders/water.gdshader")


## (Sky colours and the sun now reach every shader as global uniforms, set by
## Atmosphere as the day turns; kept for callers.)
func set_sky_colors(_top: Color, _horizon: Color) -> void:
	pass


## Lamps on (0 = day, 1 = full night): streetlight heads glow, their light
## pools and halos fade in. Called by Atmosphere every frame (cheap: two
## material values and, on a change of state, the glow nodes' visibility).
func set_night(n: float) -> void:
	if trains:
		trains.set_night(n)
	if sea_sky:
		sea_sky.set_night(n)
	if ads:
		ads.set_night(n)
	if mainland:
		mainland.set_night(n)
	if _lamp_mat:
		_lamp_mat.emission_energy_multiplier = lerpf(_lamp_base, _lamp_base * 7.0, n)
	var on := n > 0.2
	if on != _glow_on:
		_glow_on = on
		for g in _glow_nodes:
			if is_instance_valid(g):
				(g as Node3D).visible = on
		_glow_nodes = _glow_nodes.filter(func(g): return is_instance_valid(g))


func _load_mesh(name: String) -> Mesh:
	var path := MODEL_DIR + name + ".glb"
	if not ResourceLoader.exists(path):
		return null
	var scene: PackedScene = load(path)
	var inst := scene.instantiate()
	var mis := inst.find_children("*", "MeshInstance3D", true, false)
	var mesh: Mesh = (mis[0] as MeshInstance3D).mesh if mis.size() > 0 else null
	inst.free()
	return mesh


func _load_props() -> void:
	for k in ["streetlight", "tree", "tree_tall", "water_tower", "ac_unit", "antenna", "crane", "viaduct", "clock_crown",
			"harbour_dome", "beacon", "cathedral_top", "traffic_light", "roof_hut", "cooling_tower"]:
		var m := _load_mesh(k)
		if m:
			if k == "streetlight":
				m = m.duplicate()
				for i in m.get_surface_count():
					var sm := m.surface_get_material(i) as BaseMaterial3D
					if sm and sm.emission_enabled:
						_lamp_mat = sm.duplicate()
						_lamp_base = _lamp_mat.emission_energy_multiplier
						m.surface_set_material(i, _lamp_mat)
			prop_meshes[k] = m
	for mode in 2:
		var gm := ShaderMaterial.new()
		gm.shader = load("res://src/world/shaders/lamp_glow.gdshader")
		gm.set_shader_parameter("mode", mode)
		var q: PrimitiveMesh
		if mode == 0:
			q = PlaneMesh.new()  # (flat, facing up)
			(q as PlaneMesh).size = Vector2(15.0, 15.0)
		else:
			q = QuadMesh.new()
			(q as QuadMesh).size = Vector2(1.8, 1.8)
		q.material = gm
		_glow_mats.append(gm)
		_glow_meshes.append(q)
	var shader: Shader = load("res://src/world/shaders/traffic.gdshader")
	for kind in CAR_KINDS:
		var car := _load_mesh(kind[0])
		var cm: Mesh = null
		if car:
			cm = car.duplicate()
			for i in cm.get_surface_count():
				var src := cm.surface_get_material(i)
				var sm := ShaderMaterial.new()
				sm.shader = shader
				var name := String(src.resource_name) if src else ""
				if src is BaseMaterial3D:
					sm.set_shader_parameter("tint", (src as BaseMaterial3D).albedo_color)
				sm.set_shader_parameter("use_instance_color", name == "paint")
				sm.set_shader_parameter("emission", 2.0 if name.begins_with("lamp") else 0.0)
				sm.set_shader_parameter("roughness", 0.25 if name == "car_glass" else 0.45)
				cm.surface_set_material(i, sm)
		car_meshes.append(cm)
		car_far_meshes.append(_car_far_mesh(cm) if cm else null)
	var walker := _load_mesh("pedestrian")
	if walker:
		walker_mesh = walker.duplicate()
		var wshader: Shader = load("res://src/world/shaders/pedestrian.gdshader")
		for i in walker_mesh.get_surface_count():
			var src := walker_mesh.surface_get_material(i)
			var sm := ShaderMaterial.new()
			sm.shader = wshader
			if src is BaseMaterial3D:
				sm.set_shader_parameter("tint", (src as BaseMaterial3D).albedo_color)
			var nm := String(src.resource_name) if src else ""
			sm.set_shader_parameter("use_instance_color", nm == "shirt")
			sm.set_shader_parameter("part", {"skin": 1, "pants": 2, "hair": 3}.get(nm, 0))
			walker_mesh.surface_set_material(i, sm)
	_walk_paths = _pavement_paths()
	for k in FURNITURE:
		var fm := _load_mesh(k)
		if fm:
			_furn_src[k] = _flatten_colors(fm)
	furniture_mat = StandardMaterial3D.new()
	furniture_mat.vertex_color_use_as_albedo = true
	furniture_mat.vertex_color_is_srgb = true
	furniture_mat.roughness = 0.75
	_furniture_by_chunk = _place_furniture()


## Body + cabin boxes sized from the full model, sharing its paint and glass
## materials (so the GPU drive, instance colour and taxi yellow still apply).
static func _car_far_mesh(full: Mesh) -> Mesh:
	var paint: Material
	var glass: Material
	for i in full.get_surface_count():
		var m := full.surface_get_material(i) as ShaderMaterial
		if m == null:
			continue
		if m.get_shader_parameter("use_instance_color"):
			paint = m
		elif is_equal_approx(float(m.get_shader_parameter("roughness")), 0.25):
			glass = m
	var bb := full.get_aabb()
	var h := bb.size.y
	var c := bb.get_center()
	var out := ArrayMesh.new()
	for part in [[Vector3(bb.size.x * 0.96, h * 0.42, bb.size.z * 0.98), Vector3(c.x, bb.position.y + h * 0.34, c.z), paint],
			[Vector3(bb.size.x * 0.84, h * 0.4, bb.size.z * 0.5), Vector3(c.x, bb.position.y + h * 0.74, c.z + bb.size.z * 0.04), glass]]:
		var box := BoxMesh.new()
		box.size = part[0]
		var arr := box.get_mesh_arrays()
		var v: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
		for j in v.size():
			v[j] += part[1]
		arr[Mesh.ARRAY_VERTEX] = v
		out.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
		out.surface_set_material(out.get_surface_count() - 1, part[2])
	return out


## One mesh's surfaces flattened into a single vertex-coloured array set.
static func _flatten_colors(m: Mesh) -> Array:
	var v := PackedVector3Array()
	var nrm := PackedVector3Array()
	var col := PackedColorArray()
	var idx := PackedInt32Array()
	for i in m.get_surface_count():
		var a := m.surface_get_arrays(i)
		var mat := m.surface_get_material(i) as BaseMaterial3D
		var c := mat.albedo_color if mat else Color.WHITE
		var base := v.size()
		v.append_array(a[Mesh.ARRAY_VERTEX])
		nrm.append_array(a[Mesh.ARRAY_NORMAL])
		for j in (a[Mesh.ARRAY_VERTEX] as PackedVector3Array).size():
			col.append(c)
		for j in a[Mesh.ARRAY_INDEX]:
			idx.append(base + j)
	return [v, nrm, col, idx]


## Street furniture along every built-up block (not parks or dock basins):
## kerbside bins, bollards, hydrants and corner street signs; benches,
## planters and – on avenues – bus shelters back by the building line.
## Placement walks each block edge with its own RNG (the layout's random
## streams are untouched), keeps clear of junction corners, streetlights and
## the two pedestrian walking lines (1.7 m / 3.0 m in from the kerb).
func _place_furniture() -> Dictionary:
	var out := {}
	for blk in layout.blocks:
		if blk["kind"] not in ["block", "plaza"]:
			continue
		var poly: PackedVector2Array = blk["poly"]
		var c := CityRoads._centroid(poly)
		var rng := RandomNumberGenerator.new()
		rng.seed = hash(Vector2i(int(c.x), int(c.y))) ^ 0xf00d
		# Curved kerbs are sampled every few metres: merge them into runs.
		var simple := CityRoads._simplify(CityLayout._closed(poly), 1.5)
		simple.remove_at(simple.size() - 1)
		var full := poly
		poly = simple
		for ei in poly.size():
			var o: Vector2 = poly[ei]
			var e: Vector2 = poly[(ei + 1) % poly.size()] - o
			var length := e.length()
			if length < 16.0:
				continue
			var along := e / length
			var nrm := Vector2(along.y, -along.x)  # towards the road
			if Geometry2D.is_point_in_polygon(o + along * length * 0.5 + nrm * 0.5, poly):
				nrm = -nrm
			var inward := -nrm
			var basis := Basis.looking_at(Vector3(nrm.x, 0, nrm.y), Vector3.UP)  # front faces the road
			var fw: Vector4 = layout.roads.field_at(o + along * length * 0.5 + nrm * 3.0)
			var avenue := absf(fw.y) * 2.0 > 20.0
			var put := func(kind: String, d: float, inset: float, yaw := 0.0):
				var p2 := o + along * d + inward * inset
				if not Geometry2D.is_point_in_polygon(p2, full):
					return
				var key := Vector2i(floori(p2.x / CHUNK), floori(p2.y / CHUNK))
				if not out.has(key):
					out[key] = []
				out[key].append([kind, Transform3D(basis * Basis(Vector3.UP, yaw), Vector3(p2.x, layout.ground_y(p2.x, p2.y), p2.y))])
			# Corner street sign at the start of every other edge.
			if ei % 2 == 0:
				put.call("sign_post", 2.2, 0.5, PI * 0.25)
			# Kerbside line, clear of the street lights (every 32 m from 8 m).
			var d := 7.0 + rng.randf_range(0.0, 6.0)
			while d < length - 7.0:
				var lamp_d := fposmod(d - 8.0, 32.0)
				if lamp_d > 1.5 and lamp_d < 30.5:
					var roll := rng.randf()
					if roll < 0.32:
						put.call("bin", d, 0.55)
					elif roll < 0.44:
						put.call("hydrant", d, 0.5, PI * 0.5)
					elif roll < 0.58:
						put.call("bollard", d, 0.45)
						put.call("bollard", d + 1.4, 0.45)
				d += rng.randf_range(11.0, 22.0)
			# Building line: one bus shelter per boulevard edge, benches/planters.
			var shelter_at := length * rng.randf_range(0.35, 0.65) if avenue and length > 40.0 and rng.randf() < 0.7 else -100.0
			if shelter_at > 0.0:
				put.call("bus_shelter", shelter_at, 3.95)
			d = 12.0 + rng.randf_range(0.0, 10.0)
			while d < length - 10.0:
				if absf(d - shelter_at) > 5.0:
					var roll := rng.randf()
					if roll < 0.4:
						put.call("bench", d, 4.1)
					elif roll < 0.6:
						put.call("planter", d, 4.0)
				d += rng.randf_range(16.0, 34.0)
	for item in layout.public_furniture:
		var p: Vector3 = item[1].origin
		var key := Vector2i(floori(p.x / CHUNK), floori(p.z / CHUNK))
		if not out.has(key):
			out[key] = []
		out[key].append(item)
	return out


## Merged furniture arrays for one chunk (worker-thread safe: reads only).
func _furniture_arrays(key: Vector2i):
	var items: Array = chunk_furniture(key)
	if items.is_empty() or _furn_src.is_empty():
		return null
	var v := PackedVector3Array()
	var nrm := PackedVector3Array()
	var col := PackedColorArray()
	var idx := PackedInt32Array()
	for it in items:
		var src: Array = _furn_src.get(it[0], [])
		if src.is_empty():
			continue
		var xf: Transform3D = it[1]
		var base := v.size()
		for p in src[0]:
			v.append(xf * p)
		for q in src[1]:
			nrm.append(xf.basis * q)
		col.append_array(src[2])
		for i in src[3]:
			idx.append(base + i)
	if v.is_empty():
		return null
	var a := []
	a.resize(Mesh.ARRAY_MAX)
	a[Mesh.ARRAY_VERTEX] = v
	a[Mesh.ARRAY_NORMAL] = nrm
	a[Mesh.ARRAY_COLOR] = col
	a[Mesh.ARRAY_INDEX] = idx
	return a


# ------------------------------------------------------------- collision
## Collision mirrors the drawn city exactly (BuildingMesher.collision_boxes):
## roofs at the height they're drawn, cornices, parapets, plinths and awnings
## solid, the street at 0 and the raised pavements at their kerb height.
func _build_collision() -> void:
	# Fill every building's feature cache here, on the main thread, before
	# any chunk task reads them.
	for b in layout.buildings:
		BuildingMesher.features(b)
	var by_chunk := _by_chunk
	for key in by_chunk:
		var body := StaticBody3D.new()
		body.name = "Col_%d_%d" % [key.x, key.y]
		body.collision_layer = 1 | (1 << 1)
		body.collision_mask = 0
		var soft := StaticBody3D.new()
		soft.name = "ColHuman_%d_%d" % [key.x, key.y]
		soft.collision_layer = HUMAN_LAYER
		soft.collision_mask = 0
		for b in by_chunk[key]:
			var X := CityLayout.bxf(b)
			var turned := float(b.get("rot", 0.0)) != 0.0
			for box in BuildingMesher.collision_boxes(b):
				if turned:
					_add_box_xf(body, box, X)
				else:
					_add_box(body, box)
			for hull: PackedVector3Array in BuildingMesher.collision_hulls(b):
				var cs := CollisionShape3D.new()
				var cp := ConvexPolygonShape3D.new()
				cp.points = hull
				cs.shape = cp
				cs.transform = X
				body.add_child(cs)
			if b["kind"] == "normal":
				for box: AABB in BuildingMesher.features(b)["col_human"]:
					_add_box_xf(soft, box, X)
		add_child(body)
		if soft.get_child_count() > 0:
			add_child(soft)
		else:
			soft.free()
	var street := StaticBody3D.new()
	street.name = "Street"
	street.collision_layer = 1 << 3
	street.collision_mask = 0
	street.add_to_group("street")
	# The ground follows the terrain: collide with exactly the triangles drawn
	# (streets, sloping pavements and kerbs, terraces and retaining walls).
	# Every chunk's ground on the worker pool (pure data), then collision on
	# the main thread from exactly those triangles.
	_ground_meshers.clear()
	_ground_meshers.resize(_all_keys.size())
	var task := WorkerThreadPool.add_group_task(_ground_task, _all_keys.size(), -1, true)
	WorkerThreadPool.wait_for_group_task_completion(task)
	for i in _all_keys.size():
		var gm: BuildingMesher = _ground_meshers[i]
		_add_faces(street, gm)
		_ground_cache[_all_keys[i]] = null if gm.is_empty() else gm.arrays()  # drawn later from the same triangles
	_ground_meshers.clear()
	var og := BuildingMesher.new()
	for r in outer_ground_rects():
		og.terrain_patch(layout.terrain, r, 0.0, Color.WHITE, OUTER_STEP)
	_add_faces(street, og)
	# River wall along the promenade (the parapet drawn by add_ground).
	if not layout.is_mainland:
		_add_box(street, AABB(Vector3(CityLayout.RIVER_EDGE, -4.0, layout.island.position.y),
			Vector3(0.6, 5.1, layout.island.size.y)))
	add_child(street)
	var water_floor := StaticBody3D.new()
	water_floor.name = "WaterFloor"
	water_floor.collision_layer = 1 << 3
	water_floor.add_to_group("street")
	water_floor.add_to_group("water")
	for w in layout.water:
		var shape := CollisionShape3D.new()
		var box := BoxShape3D.new()
		box.size = Vector3(w.size.x, 2.0, w.size.y)
		shape.shape = box
		shape.position = Vector3(w.get_center().x, -4.0, w.get_center().y)
		water_floor.add_child(shape)
	add_child(water_floor)
	# Set pieces: oriented beams and convex prisms (their boxes are buildings).
	var kit := StaticBody3D.new()
	kit.name = "SetPieceCol"
	kit.collision_layer = 1 | (1 << 1)
	kit.collision_mask = 0
	for ob in layout.kit_obbs:
		var cs := CollisionShape3D.new()
		var bs := BoxShape3D.new()
		bs.size = ob[1]
		cs.shape = bs
		cs.transform = ob[0]
		kit.add_child(cs)
	for hull in layout.kit_hulls:
		var cs2 := CollisionShape3D.new()
		var cv := ConvexPolygonShape3D.new()
		cv.points = hull
		cs2.shape = cv
		kit.add_child(cs2)
	add_child(kit)
	if not layout.street_obbs.is_empty():
		# The expressway's deck: drives like the street (wheels, camera floor),
		# isn't a wall to the AI's whiskers.
		var deck := StaticBody3D.new()
		deck.name = "ExpresswayDeck"
		deck.collision_layer = 1 << 3
		deck.collision_mask = 0
		deck.add_to_group("street")
		for ob in layout.street_obbs:
			var csd := CollisionShape3D.new()
			var bsd := BoxShape3D.new()
			bsd.size = ob[1]
			csd.shape = bsd
			csd.transform = ob[0]
			deck.add_child(csd)
		add_child(deck)
	if not layout.kit_obbs_solid.is_empty():
		var solid := StaticBody3D.new()
		solid.name = "SetPieceSolid"
		solid.collision_layer = 1  # (no web layer: see CityLayout.kit_solid_only)
		solid.collision_mask = 0
		for ob in layout.kit_obbs_solid:
			var cs3 := CollisionShape3D.new()
			var bs3 := BoxShape3D.new()
			bs3.size = ob[1]
			cs3.shape = bs3
			cs3.transform = ob[0]
			solid.add_child(cs3)
		add_child(solid)


## Solid shapes for every drawn prop, in the prop's own frame:
## [size, centre] boxes (poles, trunks, units, furniture, cars).
func _prop_boxes(kind: String) -> Array:
	match kind:
		"streetlight":
			return [[Vector3(0.24, 7.0, 0.24), Vector3(0, 3.5, 0)]]
		"traffic_light":
			return [[Vector3(0.3, 6.2, 0.3), Vector3(0, 2.8, 0)]]
		"sign_post":
			return [[Vector3(0.14, 2.9, 0.14), Vector3(0, 1.45, 0)]]
		"tree", "tree_tall":
			return [[Vector3(0.36, 2.6, 0.36), Vector3(0, 1.3, 0)]]
		"antenna":
			return [[Vector3(0.3, 14.3, 0.3), Vector3(0, 7.15, 0)]]
		"roof_hut", "crane":
			return []  # the layout's own boxes
	var m: Mesh = prop_meshes.get(kind)
	if m == null:
		var src: Array = _furn_src.get(kind, [])
		if src.is_empty():
			return []
		var bb := AABB((src[0] as PackedVector3Array)[0], Vector3.ZERO)
		for v in src[0]:
			bb = bb.expand(v)
		return [[bb.size, bb.get_center()]]
	var a := m.get_aabb()
	return [[a.size, a.get_center()]]


func _build_prop_collision() -> void:
	var car_boxes: Array = []
	for k in CAR_KINDS:
		var cm := _load_mesh(k[0])
		var a := cm.get_aabb() if cm else AABB(Vector3(-1, 0, -2.3), Vector3(2, 1.45, 4.6))
		car_boxes.append([a.size, a.get_center()])
	var cache := {}
	var keys := {}
	for k in _props_by_chunk:
		keys[k] = true
	for k in _furniture_by_chunk:
		keys[k] = true
	for k in _all_keys:
		keys[k] = true
	for key in keys:
		var body := StaticBody3D.new()
		body.name = "Props_%d_%d" % [key.x, key.y]
		body.collision_layer = PROPS_LAYER
		body.collision_mask = 0
		var soft := StaticBody3D.new()
		soft.name = "PropsHuman_%d_%d" % [key.x, key.y]
		soft.collision_layer = HUMAN_LAYER
		soft.collision_mask = 0
		var solid := StaticBody3D.new()
		solid.name = "PropsSolid_%d_%d" % [key.x, key.y]
		solid.collision_layer = PROPS_LAYER | SOLID_LAYER
		solid.collision_mask = 0
		var items: Array = chunk_props(key) + chunk_furniture(key)
		for it in items:
			var kind: String = it[0]
			if not cache.has(kind):
				cache[kind] = _prop_boxes(kind)
			for bx in cache[kind]:
				var target := soft if kind in HUMAN_ONLY_PROPS else (solid if kind in SOLID_PROPS else body)
				_add_oriented_box(target, it[1], bx[0], bx[1])
		if solid.get_child_count() > 0:
			add_child(solid)
		else:
			solid.free()
		if soft.get_child_count() > 0:
			add_child(soft)
		else:
			soft.free()
		for pc in parked_cars(key):
			var bx: Array = car_boxes[int(pc[1])]
			_add_oriented_box(body, pc[0], bx[0], bx[1])
		if body.get_child_count() > 0:
			add_child(body)
		else:
			body.free()


## A box of `size` at `centre` in the frame `xf` (uniform scale baked into the size).
static func _add_oriented_box(body: StaticBody3D, xf: Transform3D, size: Vector3, centre: Vector3) -> void:
	var sc := xf.basis.get_scale()
	var shape := CollisionShape3D.new()
	var bs := BoxShape3D.new()
	bs.size = size * sc
	shape.shape = bs
	shape.transform = Transform3D(xf.basis.orthonormalized(), xf * centre)
	body.add_child(shape)


static func _add_faces(body: StaticBody3D, m: BuildingMesher) -> void:
	if m.is_empty():
		return
	var shape := ConcavePolygonShape3D.new()
	shape.set_faces(m.faces())
	var cs := CollisionShape3D.new()
	cs.shape = shape
	body.add_child(cs)


## A box in a building's frame (turned lots).
static func _add_box_xf(body: StaticBody3D, box: AABB, xf: Transform3D) -> void:
	if box.size.x <= 0.0 or box.size.y <= 0.0 or box.size.z <= 0.0:
		return
	var shape := CollisionShape3D.new()
	var bs := BoxShape3D.new()
	bs.size = box.size
	shape.shape = bs
	shape.transform = xf * Transform3D(Basis(), box.get_center())
	body.add_child(shape)


static func _add_box(body: StaticBody3D, box: AABB) -> void:
	if box.size.x <= 0.0 or box.size.y <= 0.0 or box.size.z <= 0.0:
		return
	var shape := CollisionShape3D.new()
	var bs := BoxShape3D.new()
	bs.size = box.size
	shape.shape = bs
	shape.position = box.get_center()
	body.add_child(shape)


## Ground outside the streamed chunks: the mainland across the strait.
func ground_rects() -> Array:
	return []  # (the mainland is its own world now; sea all round)


const OUTER_STEP := 400.0  # m: the mainland is level (the landform is clamped past its grid)


func outer_ground_rects() -> Array:
	var out: Array = []
	for r in ground_rects():
		out.append_array(CityLayout._subtract(r, grid_rect))
	return out


func _build_water() -> void:
	var m := BuildingMesher.new()
	for w in layout.water:
		if w in layout.basins:
			continue  # (the sea surface runs under the whole island and shows through the basins)
		var r: Rect2 = w
		m.top(r.position.x, r.position.y, r.end.x, r.end.y, -1.6, Color.WHITE, 0, 0, 0)
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, m.arrays())
	# The sea bed, under the whole sea (and the island's skirts and quay
	# walls, which stop at -4.5): from the water or a quay you see sand and
	# shadow, not the underside of the world.
	var bed := BuildingMesher.new()
	var all := Rect2()
	for w in layout.water:
		all = w if all.size == Vector2.ZERO else all.merge(w)
	if all.size != Vector2.ZERO:
		bed.top(all.position.x, all.position.y, all.end.x, all.end.y, -5.2, Color(0.32, 0.36, 0.33), 0, 0, 0)
		var bm := ArrayMesh.new()
		bm.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, bed.arrays())
		var bmi := MeshInstance3D.new()
		bmi.name = "SeaBed"
		bmi.mesh = bm
		var smat := StandardMaterial3D.new()
		smat.albedo_color = Color(0.3, 0.34, 0.31)
		smat.roughness = 1.0
		bmi.material_override = smat
		bmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(bmi)
	var mi := MeshInstance3D.new()
	mi.name = "Water"
	mi.mesh = mesh
	mi.material_override = water_mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mi)


func _build_landmarks() -> void:
	var groups := {}
	for lm in layout.landmarks:
		if not groups.has(lm[0]):
			groups[lm[0]] = []
		groups[lm[0]].append(lm[1])
	for k in groups:
		var mesh: Mesh = prop_meshes.get(k)
		if mesh == null:
			continue
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.mesh = mesh
		mm.instance_count = groups[k].size()
		for i in groups[k].size():
			mm.set_instance_transform(i, groups[k][i])
		var mmi := MultiMeshInstance3D.new()
		mmi.name = "Landmark_" + k
		mmi.multimesh = mm
		add_child(mmi)
		# Landmarks collide with their exact surface (domes, crowns, the
		# viaduct's arches), not a box round them.
		var body := StaticBody3D.new()
		body.name = "LandmarkCol_" + k
		body.collision_layer = 1 | (1 << 1)
		body.collision_mask = 0
		var shape := ConcavePolygonShape3D.new()
		shape.set_faces(mesh.get_faces())
		for xf in groups[k]:
			var cs := CollisionShape3D.new()
			cs.shape = shape
			cs.transform = xf
			body.add_child(cs)
		add_child(body)


## Cranes and the bridge: one mesh per structure (own culling box), detailed
## lattices near, solid massing far. Always loaded – they're the skyline's
## landmarks and few in number. Collision comes from the layout boxes.
func _build_structures() -> void:
	for i in layout.structures.size():
		var s: Dictionary = layout.structures[i]
		var root := Node3D.new()
		root.name = "Structure_%s_%d" % [s["type"], i]
		for detailed in [true, false]:
			var m := BuildingMesher.new()
			m.add_structure(s, detailed)
			if m.is_empty():
				continue
			var mi := MeshInstance3D.new()
			mi.name = "Detail" if detailed else "Low"
			mi.mesh = _mesh_from(m.arrays())
			mi.material_override = building_mat
			if detailed:
				mi.visibility_range_end = detail_range
				mi.visibility_range_end_margin = 30.0
			else:
				mi.visibility_range_begin = detail_range
				mi.visibility_range_begin_margin = 30.0
				mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			root.add_child(mi)
		add_child(root)


## Pigeon flocks circling over parks, plazas and a few rooftops – a little
## life in the sky. A tiny procedural bird; flight is all in the shader.
func _build_birds() -> void:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	# Body (thin diamond) and two wings, facing -Z, ~0.6 m span.
	for tri in [[Vector3(0, 0, -0.16), Vector3(0.05, 0, 0.0), Vector3(0, 0, 0.18)],
			[Vector3(0, 0, -0.16), Vector3(0, 0, 0.18), Vector3(-0.05, 0, 0.0)],
			[Vector3(0.04, 0, -0.06), Vector3(0.32, 0.02, 0.02), Vector3(0.04, 0, 0.07)],
			[Vector3(-0.04, 0, -0.06), Vector3(-0.04, 0, 0.07), Vector3(-0.32, 0.02, 0.02)]]:
		for v in tri:
			st.set_normal(Vector3.UP)
			st.add_vertex(v)
	var mesh := st.commit()
	var mat := ShaderMaterial.new()
	mat.shader = load("res://src/world/shaders/birds.gdshader")
	mesh.surface_set_material(0, mat)
	var rng := RandomNumberGenerator.new()
	rng.seed = layout.seed * 7
	var homes: Array = []
	for blk in layout.blocks:
		if blk["kind"] == "park":
			var pc := CityRoads._centroid(blk["poly"])
			homes.append(Vector3(pc.x, layout.ground_y(pc.x, pc.y) + rng.randf_range(18.0, 34.0), pc.y))
	for i in 10:
		var b: Dictionary = layout.buildings[rng.randi() % layout.buildings.size()]
		if b["kind"] == "normal":
			homes.append(CityLayout.top_center(b) + Vector3.UP * rng.randf_range(10.0, 22.0))
	for h in homes:
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.use_custom_data = true
		mm.mesh = mesh
		var n := rng.randi_range(6, 12)
		mm.instance_count = n
		var dir := 1.0 if rng.randf() < 0.5 else -1.0
		var base_r := rng.randf_range(10.0, 22.0)
		for i in n:
			var c := (h as Vector3) + Vector3(rng.randf_range(-2.0, 2.0), rng.randf_range(-2.5, 2.5), rng.randf_range(-2.0, 2.0))
			mm.set_instance_transform(i, Transform3D(Basis(), c))
			mm.set_instance_custom_data(i, Color(base_r + rng.randf_range(-3.0, 3.0), dir * rng.randf_range(0.45, 0.6),
				i * 0.35 + rng.randf_range(0.0, 0.2), rng.randf_range(0.5, 1.6)))
		var mmi := MultiMeshInstance3D.new()
		mmi.name = "Birds"
		mmi.multimesh = mm
		mmi.extra_cull_margin = 30.0
		mmi.visibility_range_end = 320.0
		mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(mmi)


## The road surface as a texture for the GPU-driven traffic and pedestrians
## (global shader uniforms ground_height / ground_rect). 2 m texels over the
## junction grid; clamped sampling continues it level beyond, like road_y.
func _bake_ground_height() -> void:
	var T := layout.terrain
	var cell := 2.0
	var r := Rect2(T.xs[0], T.zs[0], T.xs[-1] - T.xs[0], T.zs[-1] - T.zs[0])
	var tex := T.bake(r, cell)
	var w := tex.get_width()
	var h := tex.get_height()
	RenderingServer.global_shader_parameter_set(&"ground_height", tex)
	RenderingServer.global_shader_parameter_set(&"ground_rect",
		Vector4(r.position.x - cell * 0.5, r.position.y - cell * 0.5, cell * w, cell * h))


## The road field (CityRoads.bake_field) for ground.gdshader: lane paint,
## crossings, kerbs and paving all follow the real roads, curves included.
func _bake_street_maps() -> void:
	var R := layout.roads
	ground_mat.set_shader_parameter("road_field", R.field_texture())
	ground_mat.set_shader_parameter("road_rect", Vector4(R.field_rect.position.x, R.field_rect.position.y,
		R.field_w * R.field_cell, R.field_h * R.field_cell))
	ground_mat.set_shader_parameter("has_streets", true)


# ------------------------------------------------------------- streaming
func _process(_dt: float) -> void:
	if viewer == null:
		return
	update_streaming(viewer.global_position)


## Request/instantiate/free chunks around `pos`. `budget` caps instantiations.
func update_streaming(pos: Vector3, budget := -1) -> void:
	if budget < 0:
		budget = max_builds_per_frame
	var here := Vector2(pos.x, pos.z)
	var want := {}
	# Elevated homes need distant skyline chunks after the initial spawn load.
	var elevation := maxf(0.0, pos.y - layout.ground_y(pos.x, pos.z))
	var vista_range := view_distance + minf(elevation * 1.5, 550.0)
	for key in _all_keys:
		var c := (Vector2(key) + Vector2(0.5, 0.5)) * CHUNK
		var d := c.distance_to(here)
		if d < vista_range + CHUNK * 0.75:
			want[key] = d
		elif _loaded.has(key) and d > vista_range + CHUNK * 1.25:
			_loaded[key].queue_free()
			_loaded.erase(key)
	_want = want
	# Nearest first.
	var order := want.keys()
	order.sort_custom(func(a, b): return want[a] < want[b])
	var in_flight := _pending.size()
	for key in order:
		_mutex.lock()
		var ready: bool = _results.has(key)
		_mutex.unlock()
		if _loaded.has(key) or _pending.has(key) or ready:
			continue
		if in_flight >= 3:
			break
		_request(key)
		in_flight += 1
	_collect(budget)


func _request(key: Vector2i) -> void:
	_pending[key] = WorkerThreadPool.add_task(_generate.bind(key), false, "city chunk")


func _generate(key: Vector2i) -> void:
	var t0 := Time.get_ticks_usec()
	var res := generate_chunk_arrays(key)
	res["usec"] = Time.get_ticks_usec() - t0
	_mutex.lock()
	_results[key] = res
	_mutex.unlock()


## Pure data: mesh arrays for one chunk. Safe to call from worker threads.
func generate_chunk_arrays(key: Vector2i) -> Dictionary:
	var rect := Rect2(Vector2(key) * CHUNK, Vector2(CHUNK, CHUNK))
	var detail := BuildingMesher.new()
	var low := BuildingMesher.new()
	var feats := BuildingMesher.new()
	for b in _by_chunk.get(key, []):
		detail.add_building(b, true)
		low.add_building(b, false)
		if b["kind"] == "normal":
			feats.add_features(b)
			detail.add_skyline(b)
			low.add_skyline(b)
	var furn: Variant = _furniture_arrays(key)
	return {
		"detail": null if detail.is_empty() else detail.arrays(),
		"low": null if low.is_empty() else low.arrays(),
		"features": null if feats.is_empty() else feats.arrays(),
		"ground": _ground_cache.get(key),
		"furniture": furn,
	}


func _collect(budget: int) -> void:
	var done: Array = []
	for key in _pending:
		if WorkerThreadPool.is_task_completed(_pending[key]):
			WorkerThreadPool.wait_for_task_completion(_pending[key])
			done.append(key)
	for key in done:
		_pending.erase(key)
	var built := 0
	_mutex.lock()
	var keys := _results.keys()
	_mutex.unlock()
	for key in keys:
		if built >= budget:
			break
		_mutex.lock()
		var res: Dictionary = _results[key]
		_results.erase(key)
		_mutex.unlock()
		if not _want.has(key):
			continue  # viewer moved on while this chunk was generating
		_instantiate(key, res)
		built += 1


## Blocks until every chunk within `radius` of `pos` is built (loading screen).
func build_all_near(pos: Vector3, radius: float) -> void:
	var here := Vector2(pos.x, pos.z)
	for key in _all_keys:
		var c := (Vector2(key) + Vector2(0.5, 0.5)) * CHUNK
		if c.distance_to(here) < radius and not _loaded.has(key):
			var t0 := Time.get_ticks_usec()
			var res := generate_chunk_arrays(key)
			res["usec"] = Time.get_ticks_usec() - t0
			_instantiate(key, res)


func _mesh_from(arrays) -> ArrayMesh:
	if arrays == null:
		return null
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh


func _instantiate(key: Vector2i, res: Dictionary) -> void:
	if _loaded.has(key):
		return
	gen_ms_total += res.get("usec", 0) / 1000.0
	var root := Node3D.new()
	root.name = "Chunk_%d_%d" % [key.x, key.y]
	var detail := _mesh_from(res.get("detail"))
	var low := _mesh_from(res.get("low"))
	var ground := _mesh_from(res.get("ground"))
	if detail:
		var mi := MeshInstance3D.new()
		mi.name = "Detail"
		mi.mesh = detail
		mi.material_override = building_mat
		mi.visibility_range_end = detail_range
		mi.visibility_range_end_margin = 30.0
		root.add_child(mi)
		if low:
			# Shadows come from the plain massing (walls + roofs, ~1/6 of the
			# triangles): ledges, parapets and awnings don't need to be drawn
			# twice more into the shadow splits.
			mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			var sh := MeshInstance3D.new()
			sh.name = "ShadowProxy"
			sh.mesh = low
			sh.material_override = building_mat
			sh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_SHADOWS_ONLY
			sh.visibility_range_end = detail_range
			sh.visibility_range_end_margin = 30.0
			root.add_child(sh)
	var feats := _mesh_from(res.get("features"))
	if feats:
		var fi := MeshInstance3D.new()
		fi.name = "Features"
		fi.mesh = feats
		fi.material_override = building_mat
		fi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		fi.visibility_range_end = feature_range
		fi.visibility_range_end_margin = 20.0
		root.add_child(fi)
	if low:
		var lo := MeshInstance3D.new()
		lo.name = "Low"
		lo.mesh = low
		lo.material_override = building_mat
		lo.visibility_range_begin = detail_range
		lo.visibility_range_begin_margin = 30.0
		lo.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		root.add_child(lo)
	if ground:
		var gi := MeshInstance3D.new()
		gi.name = "Ground"
		gi.mesh = ground
		gi.material_override = ground_mat
		gi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		root.add_child(gi)
	var furn := _mesh_from(res.get("furniture"))
	if furn:
		var fi := MeshInstance3D.new()
		fi.name = "Furniture"
		fi.mesh = furn
		fi.material_override = furniture_mat
		fi.visibility_range_end = FURNITURE_RANGE
		fi.visibility_range_end_margin = 20.0
		root.add_child(fi)
	_add_props(root, key)
	_add_traffic(root, key)
	_add_walkers(root, key)
	_add_occluder(root, key)
	add_child(root)
	_loaded[key] = root
	chunks_built += 1


## The props drawn in a chunk at the current density: [kind, Transform3D].
## Collision is built from the same list, so a prop you can't see never blocks you.
func chunk_props(key: Vector2i) -> Array:
	var out: Array = []
	var i := 0
	for p in _props_by_chunk.get(key, []):
		i += 1
		if prop_density < 1.0 and p[0] in ["streetlight", "tree", "ac_unit", "traffic_light"] \
				and fmod(i * 0.618, 1.0) > prop_density:
			continue
		var kind: String = p[0]
		var xf: Transform3D = p[1]
		if kind == "tree":
			# Mix in the columnar tree and turn each one differently (looks
			# only: the layout's tree positions don't change).
			var h := hash(Vector2i(int(xf.origin.x * 4.0), int(xf.origin.z * 4.0)))
			if h % 5 < 2 and prop_meshes.has("tree_tall"):
				kind = "tree_tall"
			xf.basis = xf.basis * Basis(Vector3.UP, (h % 628) * 0.01)
		if not broken.is_empty() and broken.has(item_key(xf.origin)):
			continue
		out.append([kind, xf])
	return out


static func item_key(p: Vector3) -> Vector3i:
	return Vector3i(roundi(p.x * 10.0), roundi(p.y * 10.0), roundi(p.z * 10.0))


## Rebuilds a loaded chunk's props and furniture (after something broke).
func refresh_props(key: Vector2i) -> void:
	var root: Node3D = _loaded.get(key)
	if root == null:
		return
	for ch in root.get_children():
		if ch.name.begins_with("Props_") or ch.name == "Furniture" or ch.name.begins_with("Lamp"):
			root.remove_child(ch)
			ch.queue_free()
	_add_props(root, key)
	var arr = _furniture_arrays(key)
	var furn := _mesh_from(arr)
	if furn:
		var fi := MeshInstance3D.new()
		fi.name = "Furniture"
		fi.mesh = furn
		fi.material_override = furniture_mat
		fi.visibility_range_end = FURNITURE_RANGE
		fi.visibility_range_end_margin = 20.0
		root.add_child(fi)


## Furniture drawn in a chunk at the current density: [kind, Transform3D].
func chunk_furniture(key: Vector2i) -> Array:
	var out: Array = []
	var n := 0
	for it in _furniture_by_chunk.get(key, []):
		n += 1
		if prop_density < 1.0 and fmod(n * 0.618, 1.0) > prop_density:
			continue
		if not broken.is_empty() and broken.has(item_key((it[1] as Transform3D).origin)):
			continue
		out.append(it)
	return out


func _add_props(root: Node3D, key: Vector2i) -> void:
	var by_kind := {}
	for p in chunk_props(key):
		var kind: String = p[0]
		var xf: Transform3D = p[1]
		if not by_kind.has(kind):
			by_kind[kind] = []
		by_kind[kind].append(xf)
	for kind in by_kind:
		var mesh: Mesh = prop_meshes.get(kind)
		if mesh == null:
			continue
		var list: Array = by_kind[kind]
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.mesh = mesh
		mm.instance_count = list.size()
		for j in list.size():
			mm.set_instance_transform(j, list[j])
		var mmi := MultiMeshInstance3D.new()
		mmi.name = "Props_" + kind
		mmi.multimesh = mm
		mmi.visibility_range_end = PROP_RANGES.get(kind, 300.0)
		mmi.visibility_range_end_margin = 20.0
		if kind in ["ac_unit", "streetlight", "traffic_light"]:
			mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		root.add_child(mmi)
		if kind == "streetlight" and not _glow_meshes.is_empty():
			_add_lamp_glow(root, list)


## Night light for a chunk's streetlights: a ground pool under each head and
## a halo round it (two instanced draws per chunk, hidden by day).
func _add_lamp_glow(root: Node3D, lamps: Array) -> void:
	for mode in 2:
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.mesh = _glow_meshes[mode]
		mm.instance_count = lamps.size()
		for j in lamps.size():
			var xf: Transform3D = lamps[j]
			var head := xf * LAMP_HEAD
			var at := Vector3(head.x, xf.origin.y + 0.03, head.z) if mode == 0 else head
			mm.set_instance_transform(j, Transform3D(Basis(), at))
		var mmi := MultiMeshInstance3D.new()
		mmi.name = "LampPools" if mode == 0 else "LampHalos"
		mmi.multimesh = mm
		mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		mmi.visibility_range_end = 420.0 if mode == 0 else 700.0
		mmi.extra_cull_margin = 4.0
		mmi.visible = _glow_on
		root.add_child(mmi)
		_glow_nodes.append(mmi)


func _add_traffic(root: Node3D, key: Vector2i) -> void:
	if car_meshes.is_empty() or traffic_density <= 0.0:
		return
	var rect := Rect2(Vector2(key) * CHUNK, Vector2(CHUNK, CHUNK))
	var rng := RandomNumberGenerator.new()
	rng.seed = hash(key)
	# (Moving cars are the Traffic node's; chunks only hold the parked ones.)
	var xf: Array = []
	var custom: Array = []
	var moving := xf.size()
	var parked := parked_cars(key)
	for pc in parked:
		var m: Transform3D = pc[0]
		xf.append(Transform3D(m.basis, m.origin + m.basis.z * 5.0))  # the shader's 5 m phase
		custom.append(Color(0.0, 5.0, 10.0, 0.0))
	if xf.is_empty():
		return
	# Sort the cars into one MultiMesh per model (own RNG: the colour draws
	# below stay as they were).
	var kind_rng := RandomNumberGenerator.new()
	kind_rng.seed = hash(key) ^ 0xca75
	var groups: Array = []
	for k in CAR_KINDS.size():
		groups.append([])
	for i in xf.size():
		var k := _car_kind(kind_rng.randf()) if i < moving else int(parked[i - moving][1])
		if car_meshes[k] == null:
			k = 0
		var col: Color = CAR_COLORS[rng.randi() % CAR_COLORS.size()]
		groups[k].append([xf[i], custom[i], TAXI_YELLOW if CAR_KINDS[k][0] == "car_taxi" else col])
	# Cars only ever drive inside their chunk (lanes are clipped to it), so the
	# chunk itself is an exact culling box for the GPU-moved instances.
	var bounds := AABB(Vector3(rect.position.x, -1.0, rect.position.y), Vector3(CHUNK, 70.0, CHUNK))  # (terrain)
	for k in groups.size():
		var g: Array = groups[k]
		if g.is_empty() or car_meshes[k] == null:
			continue
		# One packed buffer for both LODs (much cheaper than per-instance setters
		# on the main thread while chunks stream in).
		var buf := _instance_buffer(g)
		for far in [false, true]:
			var mm := MultiMesh.new()
			mm.transform_format = MultiMesh.TRANSFORM_3D
			mm.use_colors = true
			mm.use_custom_data = true
			mm.mesh = car_far_meshes[k] if far else car_meshes[k]
			mm.instance_count = g.size()
			mm.buffer = buf
			mm.custom_aabb = bounds
			var mmi := MultiMeshInstance3D.new()
			mmi.name = "Traffic_" + CAR_KINDS[k][0] + ("_far" if far else "")
			mmi.multimesh = mm
			if far:
				mmi.visibility_range_begin = CAR_NEAR
				mmi.visibility_range_end = CAR_FAR
			else:
				mmi.visibility_range_end = CAR_NEAR
			mmi.visibility_range_begin_margin = 20.0
			mmi.visibility_range_end_margin = 20.0
			mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			root.add_child(mmi)


## MultiMesh buffer (TRANSFORM_3D + colour + custom) for [xform, custom, colour] items.
static func _instance_buffer(items: Array) -> PackedFloat32Array:
	var buf := PackedFloat32Array()
	buf.resize(items.size() * 20)
	var j := 0
	for it in items:
		var x: Transform3D = it[0]
		var cu: Color = it[1]
		var co: Color = it[2]
		for r in 3:
			buf[j] = x.basis.x[r]
			buf[j + 1] = x.basis.y[r]
			buf[j + 2] = x.basis.z[r]
			buf[j + 3] = x.origin[r]
			j += 4
		buf[j] = co.r; buf[j + 1] = co.g; buf[j + 2] = co.b; buf[j + 3] = co.a
		buf[j + 4] = cu.r; buf[j + 5] = cu.g; buf[j + 6] = cu.b; buf[j + 7] = cu.a
		j += 8
	return buf


## Two walking lines along every pavement (one each way), between the kerb
## and the building line; round park edges too. Not on dock quays.
func _pavement_paths() -> Array:
	var out: Array = []
	for blk in layout.blocks:
		if blk["kind"] not in ["block", "plaza", "park"]:
			continue
		var poly: PackedVector2Array = blk["poly"]
		for inset_dir in [[1.7, 1.0], [3.0, -1.0]]:
			var ring := Geometry2D.offset_polygon(poly, -float(inset_dir[0]))
			if ring.is_empty():
				continue
			var r: PackedVector2Array = ring[0]
			var fwd: bool = inset_dir[1] > 0.0
			for k in r.size():
				var a := Vector3(r[k].x, 0.15, r[k].y)
				var b := Vector3(r[(k + 1) % r.size()].x, 0.15, r[(k + 1) % r.size()].y)
				if a.distance_to(b) > 6.0:
					out.append([a, b] if fwd else [b, a])
	# The quay promenade has its own walking route, clear of the garden bays.
	if not layout.is_mainland:
		for z in range(-500, 501, 100):
			var a := Vector3(33.8, 0.15, z)
			var b := a + Vector3(0, 0, 85)
			if not layout.is_water(a) and not layout.is_water(b):
				out.append([a, b])
				out.append([b + Vector3(1.1, 0, 0), a + Vector3(1.1, 0, 0)])
	return out


func _add_walkers(root: Node3D, key: Vector2i) -> void:
	if walker_mesh == null or traffic_density <= 0.0:
		return
	var rect := Rect2(Vector2(key) * CHUNK, Vector2(CHUNK, CHUNK))
	var rng := RandomNumberGenerator.new()
	rng.seed = hash(key) ^ 0x5eed
	var xf: Array = []
	var custom: Array = []
	for path in _walk_paths:
		var seg := _clip_segment(path[0], path[1], rect)
		if seg.is_empty():
			continue
		var s0: Vector3 = seg[0]
		var s1: Vector3 = seg[1]
		var length := s0.distance_to(s1)
		if length < 6.0:
			continue
		var dir := (s1 - s0) / length
		var basis := Basis.looking_at(dir, Vector3.UP)
		var n := int(length / 9.0 * traffic_density + rng.randf())
		for i in n:
			var sc := rng.randf_range(0.9, 1.08)
			xf.append(Transform3D(basis.scaled(Vector3.ONE * sc), Vector3(s0.x, 0.15, s0.z)))
			custom.append(Color(rng.randf_range(1.1, 1.6), rng.randf_range(0.0, length), length, 0.0))
	if xf.is_empty():
		return
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	mm.use_custom_data = true
	mm.mesh = walker_mesh
	mm.instance_count = xf.size()
	var items: Array = []
	for i in xf.size():
		items.append([xf[i], custom[i], CLOTHES[rng.randi() % CLOTHES.size()]])
	mm.buffer = _instance_buffer(items)
	mm.custom_aabb = AABB(Vector3(rect.position.x, -1.0, rect.position.y), Vector3(CHUNK, 70.0, CHUNK))  # walks stay in the chunk
	var mmi := MultiMeshInstance3D.new()
	mmi.name = "Walkers"
	mmi.multimesh = mm
	mmi.visibility_range_end = WALKER_RANGE
	mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	root.add_child(mmi)


## Cars parked along both kerbs of the ordinary streets (not the avenues,
## not near junctions), with gaps. Same MultiMesh as traffic: speed 0 and a
## phase in the middle of a short "segment", the transform offset to match.
static func _car_kind(r: float) -> int:
	var k := 0
	while k < CAR_KINDS.size() - 1 and r > CAR_KINDS[k][1]:
		r -= CAR_KINDS[k][1]
		k += 1
	return k


## Parked cars in a chunk: [Transform3D of the model, CAR_KINDS index]. Own
## random stream per chunk, independent of the traffic density, so the
## collision built up front matches what the chunk later draws.
func parked_cars(key: Vector2i) -> Array:
	if not gpu_traffic:
		return []  # (NEVER STOP: no static parked cars – only real, hittable traffic)
	var rect := Rect2(Vector2(key) * CHUNK, Vector2(CHUNK, CHUNK))
	var rng := RandomNumberGenerator.new()
	rng.seed = hash(key) ^ 0x9a4c
	var xf: Array = []
	var custom: Array = []
	_parked_cars(rect, rng, xf, custom)
	var out: Array = []
	for t in xf:
		# The shader shifts a parked car 5 m back along its segment (see below).
		out.append([Transform3D((t as Transform3D).basis, (t as Transform3D).origin - (t as Transform3D).basis.z * 5.0),
			_car_kind(rng.randf())])
	return out


func _parked_cars(rect: Rect2, rng: RandomNumberGenerator, xf: Array, custom: Array) -> void:
	var T := layout.terrain
	for r in layout.roads.roads:
		if r["kind"] != "minor" or float(r["w"]) < 14.0:
			continue
		var pts := CityRoads._simplify(r["pts"], 0.5)
		var hw: float = float(r["w"]) * 0.5
		var total := CityRoads.length_of(pts)
		var acc := 0.0
		for i in pts.size() - 1:
			var a := pts[i]
			var b := pts[i + 1]
			var L := a.distance_to(b)
			var dir := (b - a) / maxf(L, 0.001)
			var right := Vector2(-dir.y, dir.x)
			for side: float in [-1.0, 1.0]:
				var d := 0.0
				while d < L:
					var along := acc + d
					var p2 := a + dir * d + right * side * (hw - 1.5)
					if along > 12.0 and along < total - 12.0 and rect.has_point(p2) and rng.randf() < 0.6 \
							and layout.roads.field_at(p2).w > 6.0:
						# Parked facing with the traffic on that side (right-hand drive lanes: +side = with dir).
						var f2 := dir if side > 0.0 else -dir
						var fwd := Vector3(f2.x, 0.0, f2.y)
						var pos := Vector3(p2.x, 0.02 + T.road_y(p2.x, p2.y), p2.y)
						var grade := (T.road_y(p2.x + f2.x, p2.y + f2.y) - T.road_y(p2.x - f2.x, p2.y - f2.y)) * 0.5
						var basis := Basis.looking_at((fwd + Vector3.UP * grade).normalized(), Vector3.UP)
						xf.append(Transform3D(basis, pos + basis.z * 5.0))
						custom.append(Color(0.0, 5.0, 10.0, 0.0))
					d += rng.randf_range(6.2, 7.5)
			acc += L


## The part of segment a→b inside r (Liang–Barsky), or [] if under 1 m.
static func _clip_segment(a: Vector3, b: Vector3, r: Rect2) -> Array:
	var t0 := 0.0
	var t1 := 1.0
	var dx := b.x - a.x
	var dz := b.z - a.z
	for e in [[-dx, a.x - r.position.x], [dx, r.end.x - a.x], [-dz, a.z - r.position.y], [dz, r.end.y - a.z]]:
		var pp: float = e[0]
		var q: float = e[1]
		if absf(pp) < 1e-9:
			if q < 0.0:
				return []
		else:
			var t := q / pp
			if pp < 0.0:
				t0 = maxf(t0, t)
			else:
				t1 = minf(t1, t)
	if t1 - t0 <= 0.0:
		return []
	var s0 := a.lerp(b, t0)
	var s1 := a.lerp(b, t1)
	s0.y = 0.0
	s1.y = 0.0
	return [] if s0.distance_to(s1) < 1.0 else [s0, s1]


func _add_occluder(root: Node3D, key: Vector2i) -> void:
	var v := PackedVector3Array()
	var idx := PackedInt32Array()
	for b in _by_chunk.get(key, []):
		if b["kind"] not in ["normal", "landmark"]:
			continue
		var t: Array = b["tiers"][0]
		if t[5] - t[4] < 20.0 or t[2] - t[0] < 12.0 or t[3] - t[1] < 12.0:
			continue
		# Slightly shrunken so occluders never poke out of their building.
		var x0: float = t[0] + 0.5
		var z0: float = t[1] + 0.5
		var x1: float = t[2] - 0.5
		var z1: float = t[3] - 0.5
		var y1: float = t[5] - 0.5
		if b.has("apt"):
			# A home is cut into this tower: an occluder round the room would
			# hide the whole city from inside it (the view is the point), so
			# it stops below the room's floor.
			y1 = minf(y1, float(b["apt"]["y0"]) - 0.5)
			if y1 - t[4] < 20.0:
				continue
		var base := v.size()
		var X := CityLayout.bxf(b)
		for q: Vector3 in [Vector3(x0, 0, z0), Vector3(x1, 0, z0), Vector3(x1, 0, z1), Vector3(x0, 0, z1),
				Vector3(x0, y1, z0), Vector3(x1, y1, z0), Vector3(x1, y1, z1), Vector3(x0, y1, z1)]:
			v.append(X * q)
		for f in [[0, 1, 5, 4], [1, 2, 6, 5], [2, 3, 7, 6], [3, 0, 4, 7], [4, 5, 6, 7]]:
			idx.append_array([base + f[0], base + f[1], base + f[2], base + f[0], base + f[2], base + f[3]])
	if v.is_empty():
		return
	var occ := ArrayOccluder3D.new()
	occ.set_arrays(v, idx)
	var oi := OccluderInstance3D.new()
	oi.occluder = occ
	root.add_child(oi)


func loaded_chunk_count() -> int:
	return _loaded.size()
