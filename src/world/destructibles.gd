class_name Destructibles
extends Node3D
## Street furniture cars knock flying: streetlights, traffic lights, sign
## posts, bins, benches, hydrants, bollards. (Trees, bus shelters and
## planters are solid: you crash into those.)
##  * A spatial hash of every breakable item, built from the same lists the
##    city draws (CityWorld.chunk_props / chunk_furniture).
##  * Every physics frame, each fast car near the camera checks the items in
##    its cells against its footprint; a hit removes the item from the city
##    (CityWorld.broken + a chunk refresh, throttled) and throws a physical
##    copy of it with the car's momentum. The car loses a little speed.
##  * Thrown pieces are pooled by budget and cleaned up after a while.

signal broke(kind: String, at: Vector3, by: Car)

const BREAKABLE := ["streetlight", "traffic_light", "sign_post", "bench", "bin", "hydrant", "bollard"]
const CELL := 8.0
const SLOW := {"streetlight": 0.92, "traffic_light": 0.9, "sign_post": 0.97, "bench": 0.95, "bin": 0.98,
	"hydrant": 0.95, "bollard": 0.93}

var world: CityWorld
var cars: Array = []
var budget := 24
var _grid := {}        # Vector2i -> Array of [kind, Transform3D, chunk key, item key]
var _pieces: Array = []  # [RigidBody3D, age]
var _dirty := {}       # chunk key -> seconds until refresh
var _meshes := {}
var _rng := RandomNumberGenerator.new()


func setup(p_world: CityWorld) -> void:
	world = p_world
	var st := get_node_or_null("/root/Settings")
	if st:
		budget = int(st.preset()["debris"] / 2)
	_index(world)
	if world.mainland:
		_index(world.mainland)


func _index(w: CityWorld) -> void:
	for key in w._all_keys:
		for it in w.chunk_props(key) + w.chunk_furniture(key):
			var kind: String = it[0]
			if not kind in BREAKABLE:
				continue
			var xf: Transform3D = it[1]
			var c := Vector2i(floori(xf.origin.x / CELL), floori(xf.origin.z / CELL))
			if not _grid.has(c):
				_grid[c] = []
			(_grid[c] as Array).append([kind, xf, key, CityWorld.item_key(xf.origin), w])


func count() -> int:
	var n := 0
	for c in _grid:
		n += (_grid[c] as Array).size()
	return n


func _physics_process(dt: float) -> void:
	for c: Car in cars:
		if not is_instance_valid(c) or c.freeze or not c.visible or c.speed < 4.0:
			continue
		_check(c)
	for k in _dirty.keys():
		_dirty[k] -= dt
		if _dirty[k] <= 0.0:
			var w: CityWorld = _dirty_world[k]
			w.refresh_props(k)
			_dirty.erase(k)
			_dirty_world.erase(k)
	var keep: Array = []
	for p in _pieces:
		p[1] += dt
		if p[1] > 10.0:
			(p[0] as Node).queue_free()
		else:
			keep.append(p)
	_pieces = keep


var _dirty_world := {}


func _check(car: Car) -> void:
	var p := car.global_position
	var size: Vector3 = car.spec["size"]
	var hw := size.x * 0.5 + 0.25
	var hl := size.z * 0.5 + 0.25
	var inv := car.global_transform.affine_inverse()
	var c0 := Vector2i(floori(p.x / CELL), floori(p.z / CELL))
	for dx in [-1, 0, 1]:
		for dz in [-1, 0, 1]:
			var cell: Array = _grid.get(c0 + Vector2i(dx, dz), [])
			if cell.is_empty():
				continue
			for i in range(cell.size() - 1, -1, -1):
				var it: Array = cell[i]
				var xf: Transform3D = it[1]
				var l := inv * xf.origin
				if absf(l.x) < hw and absf(l.z) < hl and l.y > -1.5 and l.y < 2.0:
					cell.remove_at(i)
					_break(it, car)


func _break(it: Array, car: Car) -> void:
	var kind: String = it[0]
	var xf: Transform3D = it[1]
	var w: CityWorld = it[4]
	w.broken[it[3]] = true
	_dirty[it[2]] = 0.15
	_dirty_world[it[2]] = w
	car.linear_velocity *= SLOW.get(kind, 0.95)
	_throw(kind, xf, car, w)
	broke.emit(kind, xf.origin, car)


func _mesh_for(kind: String, w: CityWorld) -> Mesh:
	if _meshes.has(kind):
		return _meshes[kind]
	var m: Mesh = w.prop_meshes.get(kind)
	if m == null:
		var src: Array = w._furn_src.get(kind, [])
		if not src.is_empty():
			var a := []
			a.resize(Mesh.ARRAY_MAX)
			a[Mesh.ARRAY_VERTEX] = src[0]
			a[Mesh.ARRAY_NORMAL] = src[1]
			a[Mesh.ARRAY_COLOR] = src[2]
			a[Mesh.ARRAY_INDEX] = src[3]
			var am := ArrayMesh.new()
			am.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, a)
			m = am
	_meshes[kind] = m
	return m


func _throw(kind: String, xf: Transform3D, car: Car, w: CityWorld) -> void:
	if _pieces.size() >= budget:
		var old: Array = _pieces.pop_front()
		(old[0] as Node).queue_free()
	var mesh := _mesh_for(kind, w)
	var b := RigidBody3D.new()
	b.collision_layer = 1 << 5
	b.collision_mask = 1 | (1 << 3)
	var tall := kind in ["streetlight", "traffic_light", "sign_post"]
	b.mass = 60.0 if tall else 25.0
	var cs := CollisionShape3D.new()
	var bs := BoxShape3D.new()
	var aabb := mesh.get_aabb() if mesh else AABB(Vector3(-0.3, 0, -0.3), Vector3(0.6, 1.0, 0.6))
	bs.size = aabb.size.max(Vector3.ONE * 0.1)
	cs.shape = bs
	cs.position = aabb.get_center()
	b.add_child(cs)
	if mesh:
		var mi := MeshInstance3D.new()
		mi.mesh = mesh
		if kind in ["bench", "bin", "hydrant", "bollard"]:
			mi.material_override = w.furniture_mat
		b.add_child(mi)
	add_child(b)
	b.global_transform = xf
	var v := car.linear_velocity
	b.linear_velocity = v * _rng.randf_range(0.6, 0.95) + Vector3.UP * _rng.randf_range(2.0, 5.0)
	# Tall posts topple over the car's nose.
	var axis := (-car.global_basis.x) if tall else Vector3(_rng.randf_range(-1, 1), 0, _rng.randf_range(-1, 1)).normalized()
	b.angular_velocity = axis * v.length() * (0.25 if tall else 0.6)
	_pieces.append([b, 0.0])
