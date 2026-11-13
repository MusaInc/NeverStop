class_name CarVisual
extends Node3D
## The drawn car: body mesh (assets/vehicles/<body>.glb) with runtime
## materials keyed off the glTF material names, four wheels that spin, steer
## and ride the suspension, brake/reverse lamps, police beacons (a shader –
## no CPU per flash), and procedural dents: impacts push nearby body vertices
## in along the hit direction (one ArrayMesh copy per car, made on the first
## dent), so damage accumulates where the car was actually hit.

const DIR := "res://assets/vehicles/"
const BEACON_SHADER := preload("res://src/vehicle/beacon.gdshader")
const PAINT_SHADER := preload("res://src/vehicle/car_paint.gdshader")
const GLASS_SHADER := preload("res://src/vehicle/car_glass.gdshader")
const FLARE_SHADER := preload("res://src/vehicle/lamp_flare.gdshader")

static var _mesh_cache := {}
static var _mat_cache := {}
static var _lamp_cache := {}
static var _flare_mat: ShaderMaterial
## 0 day .. 1 night (street lamps on). Set by Atmosphere every frame.
static var lamps := 0.0

var car: Car
var body: MeshInstance3D
var wheels: Array[Node3D] = []      # steer pivots
var _spins: Array[Node3D] = []      # spin nodes under them
var paint_mat: ShaderMaterial
var flares: MeshInstance3D
var head_lights: Array[SpotLight3D] = []
var lamp_pos := {}                  # "head"/"tail" -> Array[Vector3] (local, one per side)
var tail_mat: StandardMaterial3D
var head_mat: StandardMaterial3D
var beacon_mat: ShaderMaterial
var beacon_light_a: OmniLight3D
var beacon_light_b: OmniLight3D
var _deformed := false
var _dent_cooldown := 0.0
var _arrays: Array = []           # per surface: [arrays, material]
var _rest: Array = []             # per surface: original vertices
var dirt := 0.0
var siren_on := false
var _t := randf() * 10.0


static func load_mesh(name: String) -> Mesh:
	if _mesh_cache.has(name):
		return _mesh_cache[name]
	var path := DIR + name + ".glb"
	var m: Mesh = null
	if ResourceLoader.exists(path):
		var sc: PackedScene = load(path)
		var n := sc.instantiate()
		var mis := n.find_children("*", "MeshInstance3D", true, false)
		if mis.size() > 0:
			m = (mis[0] as MeshInstance3D).mesh
		n.free()
	_mesh_cache[name] = m
	return m


static func shared_mat(name: String) -> Material:
	if _mat_cache.has(name):
		return _mat_cache[name]
	var m := StandardMaterial3D.new()
	if name == "glass":
		var g := ShaderMaterial.new()
		g.shader = GLASS_SHADER
		_mat_cache[name] = g
		return g
	match name:
		"trim", "liner", "grille":
			m.albedo_color = Color(0.035, 0.035, 0.04) if name != "liner" else Color(0.015, 0.015, 0.015)
			m.roughness = 0.55 if name == "trim" else 0.85
			m.metallic = 0.2 if name == "grille" else 0.0
		"chrome":
			m.albedo_color = Color(0.72, 0.73, 0.76)
			m.metallic = 1.0
			m.roughness = 0.22
		"rim":
			# Bright machined alloy: less mirror than chrome, so spokes read
			# against the dark wheel well instead of turning sky-grey.
			m.albedo_color = Color(0.8, 0.81, 0.83)
			m.metallic = 0.65
			m.roughness = 0.3
		"tyre_wall":
			m.albedo_color = Color(0.085, 0.085, 0.09)
			m.roughness = 0.75
		"disc":
			m.albedo_color = Color(0.35, 0.35, 0.36)
			m.metallic = 0.8
			m.roughness = 0.45
		"caliper":
			m.albedo_color = Color(0.75, 0.08, 0.05)
			m.roughness = 0.35
			m.metallic = 0.2
		"rim_dark":
			m.albedo_color = Color(0.09, 0.09, 0.1)
			m.metallic = 0.8
			m.roughness = 0.35
		"tyre":
			m.albedo_color = Color(0.045, 0.045, 0.045)
			m.roughness = 0.88
		"seam":
			m.albedo_color = Color(0.01, 0.01, 0.012)
			m.roughness = 0.9
		"carbon":
			m.albedo_color = Color(0.05, 0.05, 0.056)
			m.roughness = 0.28
			m.metallic = 0.35
			m.clearcoat_enabled = true
			m.clearcoat = 0.5
		"cladding":
			m.albedo_color = Color(0.075, 0.075, 0.08)
			m.roughness = 0.85
		"bed":
			m.albedo_color = Color(0.05, 0.05, 0.05)
			m.roughness = 0.95
		"lamp_housing":
			m.albedo_color = Color(0.02, 0.02, 0.025)
			m.roughness = 0.12
			m.metallic = 0.7
		"lamp_amber", "sign":
			m.albedo_color = Color(0.95, 0.5, 0.06) if name == "lamp_amber" else Color(1.0, 0.86, 0.35)
			m.emission_enabled = true
			m.emission = m.albedo_color
			m.emission_energy_multiplier = 0.6 if name == "lamp_amber" else 1.2
			m.roughness = 0.25
		"plate":
			m.albedo_color = Color(0.9, 0.88, 0.78)
			m.roughness = 0.6
		"lamp_rev":
			m.albedo_color = Color(0.85, 0.85, 0.85)
			m.roughness = 0.2
		_:
			m.albedo_color = Color(0.5, 0.5, 0.5)
	_mat_cache[name] = m
	return m


func setup(p_car: Car) -> void:
	car = p_car
	var spec := car.spec
	body = MeshInstance3D.new()
	body.name = "Body"
	add_child(body)
	var mesh := load_mesh(spec["body"])
	body.mesh = mesh
	paint_mat = ShaderMaterial.new()
	paint_mat.shader = PAINT_SHADER
	paint_mat.set_shader_parameter("base_color", spec["paint"])
	var paint2 := StandardMaterial3D.new()
	paint2.albedo_color = spec.get("paint2", Color(0.9, 0.9, 0.9))
	paint2.roughness = 0.35
	paint2.metallic = 0.1
	head_mat = StandardMaterial3D.new()
	head_mat.albedo_color = Color(0.95, 0.95, 0.9)
	head_mat.emission_enabled = true
	head_mat.emission = Color(1.0, 0.95, 0.85)
	head_mat.emission_energy_multiplier = 1.2
	tail_mat = StandardMaterial3D.new()
	tail_mat.albedo_color = Color(0.5, 0.02, 0.02)
	tail_mat.emission_enabled = true
	tail_mat.emission = Color(1.0, 0.04, 0.02)
	tail_mat.emission_energy_multiplier = 0.8
	if mesh:
		for i in mesh.get_surface_count():
			var src := mesh.surface_get_material(i)
			var n := src.resource_name if src else ""
			var m: Material
			match n:
				"paint": m = paint_mat
				"paint2": m = paint2
				"lamp_head": m = head_mat
				"lamp_tail": m = tail_mat
				"beacon_red", "beacon_blue":
					if beacon_mat == null:
						beacon_mat = ShaderMaterial.new()
						beacon_mat.shader = BEACON_SHADER
					m = beacon_mat
				_: m = shared_mat(n)
			body.set_surface_override_material(i, m)
	# Wheels.
	var wmesh := load_mesh("wheel_" + str(spec.get("wheel", "five")))
	var wr: float = spec["wheel_r"]
	for i in 4:
		var pivot := Node3D.new()
		pivot.name = "Wheel%d" % i
		add_child(pivot)
		var spin := Node3D.new()
		pivot.add_child(spin)
		var wm := MeshInstance3D.new()
		wm.mesh = wmesh
		# Mesh: radius 1, tyre 0.44 wide along X.
		wm.scale = Vector3(float(spec.get("tyre_w", 0.26)) / 0.44, wr, wr)
		if wmesh:
			for s in wmesh.get_surface_count():
				var src := wmesh.surface_get_material(s)
				wm.set_surface_override_material(s, shared_mat(src.resource_name if src else "tyre"))
		# Left wheels face outward the other way.
		if i % 2 == 0:
			wm.rotation.y = PI
		spin.add_child(wm)
		# Brake caliper: on the steering pivot, not the spinning wheel.
		var cal := MeshInstance3D.new()
		cal.name = "Caliper"
		cal.mesh = _caliper_mesh()
		cal.material_override = shared_mat("caliper") if spec.get("caliper", true) else shared_mat("trim")
		var sx := -1.0 if i % 2 == 0 else 1.0
		var rr := wr * 0.53
		# Behind the axle (front wheels) / ahead of it (rear), at about 10 o'clock.
		var ang := deg_to_rad(35.0)
		var zs := 1.0 if i < 2 else -1.0
		cal.position = Vector3(sx * float(spec.get("tyre_w", 0.26)) * 0.03, rr * cos(ang), zs * rr * sin(ang))
		cal.rotation.x = -zs * ang
		cal.scale = Vector3.ONE * wr / 0.33
		pivot.add_child(cal)
		wheels.append(pivot)
		_spins.append(spin)
	if beacon_mat:
		beacon_mat.set_shader_parameter("phase", randf())
	lamp_pos = lamp_spots(spec["body"], mesh)
	_make_flares()
	_build_mods()
	car.part_lost.connect(detach)
	car.repaired.connect(reset_dents)


static var _cal_mesh: BoxMesh
static func _caliper_mesh() -> Mesh:
	if _cal_mesh == null:
		_cal_mesh = BoxMesh.new()
		_cal_mesh.size = Vector3(0.07, 0.07, 0.15)
	return _cal_mesh


func set_paint(c: Color) -> void:
	paint_mat.set_shader_parameter("base_color", c)


## Where the head and tail lamps are (body-local, one point per side), read
## once per body from the vertices of its lamp_head / lamp_tail surfaces.
static func lamp_spots(body_name: String, mesh: Mesh) -> Dictionary:
	if _lamp_cache.has(body_name):
		return _lamp_cache[body_name]
	var out := {"head": [], "tail": []}
	if mesh:
		for i in mesh.get_surface_count():
			var src := mesh.surface_get_material(i)
			var n := src.resource_name if src else ""
			var key := "head" if n == "lamp_head" else ("tail" if n == "lamp_tail" else "")
			if key == "":
				continue
			var v: PackedVector3Array = mesh.surface_get_arrays(i)[Mesh.ARRAY_VERTEX]
			for side in [-1.0, 1.0]:
				var sum := Vector3.ZERO
				var cnt := 0
				var end := INF if key == "head" else -INF
				for q in v:
					if q.x * side > 0.05:
						sum += q
						cnt += 1
						end = minf(end, q.z) if key == "head" else maxf(end, q.z)
				if cnt > 0:
					var c := sum / cnt
					out[key].append(Vector3(c.x, c.y, end))
	_lamp_cache[body_name] = out
	return out


## Night glows on every lamp: one mesh, one draw call (see lamp_flare.gdshader).
func _make_flares() -> void:
	if _flare_mat == null:
		_flare_mat = ShaderMaterial.new()
		_flare_mat.shader = FLARE_SHADER
	var verts := PackedVector3Array()
	var norms := PackedVector3Array()
	var cols := PackedColorArray()
	var uvs := PackedVector2Array()
	var uv2s := PackedVector2Array()
	var idx := PackedInt32Array()
	var lamps_list := []
	for p in lamp_pos["head"]:
		lamps_list.append([p, Vector3.FORWARD, Color(1.0, 0.93, 0.8, 1.0), 1.15])
	for p in lamp_pos["tail"]:
		lamps_list.append([p, Vector3.BACK, Color(1.0, 0.08, 0.05, 0.55), 0.7])
	if lamps_list.is_empty():
		return
	for l in lamps_list:
		var b := verts.size()
		var h: float = l[3] * 0.5
		for c in [Vector2(-1, -1), Vector2(1, -1), Vector2(1, 1), Vector2(-1, 1)]:
			verts.append(l[0])
			norms.append(l[1])
			cols.append(l[2])
			uvs.append((c + Vector2.ONE) * 0.5)
			uv2s.append(c * h)
		idx.append_array([b, b + 1, b + 2, b, b + 2, b + 3])
	var arr := []
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = verts
	arr[Mesh.ARRAY_NORMAL] = norms
	arr[Mesh.ARRAY_COLOR] = cols
	arr[Mesh.ARRAY_TEX_UV] = uvs
	arr[Mesh.ARRAY_TEX_UV2] = uv2s
	arr[Mesh.ARRAY_INDEX] = idx
	var am := ArrayMesh.new()
	am.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
	am.custom_aabb = AABB(Vector3(-3, -2, -5), Vector3(6, 5, 10))
	flares = MeshInstance3D.new()
	flares.name = "LampGlow"
	flares.mesh = am
	flares.material_override = _flare_mat
	flares.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(flares)


## Real headlights (the player's car), night only:
##  * a main beam: one spotlight just ahead of the bumper, dipped a little,
##    a broad soft-edged pool reaching ~75 m;
##  * a soft near spill: a wide, short, dim spot so the kerbs and lane
##    edges either side of the nose are lit, not just a cone ahead.
## One spot per job, never one per lamp: lamps inside their housings
## shadowed their own light (two dark discs on the road). The old visible
## air "beams" are gone too: seen from the chase camera their dim tips left
## two dark holes in the lit road.

func enable_headlights(_shadows := false) -> void:
	if not head_lights.is_empty() or lamp_pos["head"].is_empty():
		return
	var heads: Array = lamp_pos["head"]
	var mid := Vector3.ZERO
	for p: Vector3 in heads:
		mid += p
	mid /= float(heads.size())
	var main := SpotLight3D.new()
	main.name = "Headlight"
	main.light_color = Color(1.0, 0.95, 0.86)
	main.spot_range = 75.0
	main.spot_angle = 42.0
	main.spot_angle_attenuation = 0.35
	main.spot_attenuation = 0.65
	main.light_specular = 0.35
	main.position = Vector3(0.0, mid.y + 0.12, mid.z - 0.8)
	main.rotation = Vector3(deg_to_rad(-4.5), 0.0, 0.0)
	var spill := SpotLight3D.new()
	spill.name = "HeadSpill"
	spill.light_color = Color(1.0, 0.94, 0.84)
	spill.spot_range = 16.0
	spill.spot_angle = 68.0
	spill.spot_angle_attenuation = 1.6
	spill.spot_attenuation = 1.2
	spill.light_specular = 0.15
	spill.position = Vector3(0.0, mid.y + 0.25, mid.z - 0.6)
	spill.rotation = Vector3(deg_to_rad(-22.0), 0.0, 0.0)
	for l: SpotLight3D in [main, spill]:
		l.light_energy = 0.0
		l.shadow_enabled = false
		l.visible = false
		add_child(l)
		head_lights.append(l)


func set_siren(on: bool) -> void:
	siren_on = on
	if beacon_mat:
		beacon_mat.set_shader_parameter("on", 1.0 if on else 0.0)


## A real light pair for the nearest few police (the director hands them out).
func set_beacon_lights(on: bool) -> void:
	if on and beacon_light_a == null:
		beacon_light_a = _beacon_light(Color(1.0, 0.1, 0.08), -0.5)
		beacon_light_b = _beacon_light(Color(0.15, 0.3, 1.0), 0.5)
	if beacon_light_a:
		beacon_light_a.visible = on
		beacon_light_b.visible = on


func _beacon_light(c: Color, x: float) -> OmniLight3D:
	var l := OmniLight3D.new()
	l.light_color = c
	l.omni_range = 9.0
	l.light_energy = 0.0
	l.shadow_enabled = false
	var s: Vector3 = car.spec["size"]
	l.position = Vector3(x, s.y + car.spec["ride"] + 0.25, 0.0)
	add_child(l)
	return l


func _process(dt: float) -> void:
	if car == null:
		return
	_t += dt
	_dent_cooldown -= dt
	var spec := car.spec
	for i in 4:
		var p := wheels[i]
		p.position = car.wheel_local(i)
		if i < 2:
			p.rotation.y = -car.steer_angle
		_spins[i].rotation.x = -car.wheel_spin[i]
	# Brake lights (and a dim glow when lit at night).
	var braking := car.brake > 0.1 and car.forward_speed > 0.5
	tail_mat.emission_energy_multiplier = (3.2 if braking or car.disabled else 0.7) + lamps * 1.6
	head_mat.emission_energy_multiplier = 1.2 + lamps * 5.0
	if not head_lights.is_empty():
		var on := lamps > 0.05 and not car.disabled
		head_lights[0].visible = on
		head_lights[0].light_energy = 18.0 * lamps
		head_lights[1].visible = on
		head_lights[1].light_energy = 3.0 * lamps
	if beacon_light_a and beacon_light_a.visible:
		var ph := fmod(_t * 2.6, 1.0)
		var a := 1.0 if ph < 0.5 else 0.0
		var flick := 0.6 + 0.4 * sin(_t * 40.0)
		beacon_light_a.light_energy = 3.0 * a * flick
		beacon_light_b.light_energy = 3.0 * (1.0 - a) * flick
	# Damage tint: dirt and scorch build with damage.
	var d := 1.0 - car.health
	if absf(d - dirt) > 0.02:
		dirt = d
		paint_mat.set_shader_parameter("dirt", d)


## Dents the body around `world_at`, pushing along `dir` (world), by
## `amount` metres at the centre, falling off over `radius`.
func dent(world_at: Vector3, dir: Vector3, amount: float, radius := 0.9) -> void:
	if body == null or body.mesh == null or _dent_cooldown > 0.0:
		return
	_dent_cooldown = 0.12
	_ensure_copy()
	var inv := body.global_transform.affine_inverse()
	var c := inv * world_at
	var d := (inv.basis * dir).normalized()
	var r2 := radius * radius
	var size: Vector3 = car.spec["size"]
	for s in _arrays.size():
		var arr: Array = _arrays[s]
		var v: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
		var rest: PackedVector3Array = _rest[s]
		for i in v.size():
			var q := v[i]
			var dd := q.distance_squared_to(c)
			if dd < r2:
				var f := 1.0 - dd / r2
				var np := q + d * amount * f * f
				# Never crumple more than 35 cm from the original shape.
				var off := np - rest[i]
				if off.length() > 0.35:
					np = rest[i] + off.normalized() * 0.35
				np.x = clampf(np.x, -size.x * 0.5, size.x * 0.5)
				v[i] = np
		arr[Mesh.ARRAY_VERTEX] = v
	_rebuild()
	# Bolt-on plates and ram bars crumple too (a little shove inwards).
	if _mods:
		for ch in _mods.get_children():
			var n3 := ch as Node3D
			if n3 and n3.visible and n3.position.distance_to(c) < radius + 0.8:
				n3.position += d * amount * 0.25


func _ensure_copy() -> void:
	if _deformed:
		return
	_deformed = true
	var src: Mesh = load_mesh(car.spec["body"])
	_part_tri = part_map(car.spec["body"], src)
	for s in src.get_surface_count():
		var arr := src.surface_get_arrays(s)
		_arrays.append(arr)
		_rest.append((arr[Mesh.ARRAY_VERTEX] as PackedVector3Array).duplicate())
		_rest_idx.append((arr[Mesh.ARRAY_INDEX] as PackedInt32Array).duplicate())


## The working copy back into the body (dents, minus any panels that fell off).
func _rebuild() -> void:
	var am := ArrayMesh.new()
	var mats: Array = []
	for s in body.mesh.get_surface_count():
		mats.append(body.get_surface_override_material(s))
	for s in _arrays.size():
		var arr: Array = _arrays[s]
		if not _lost.is_empty():
			var src_idx: PackedInt32Array = _rest_idx[s]
			var pm: PackedByteArray = _part_tri[s]
			var idx := PackedInt32Array()
			for t in pm.size():
				var pid := pm[t]
				if pid != NO_PART and _lost.has(Car.PARTS[pid]):
					continue
				idx.append(src_idx[t * 3])
				idx.append(src_idx[t * 3 + 1])
				idx.append(src_idx[t * 3 + 2])
			if idx.is_empty():
				idx = PackedInt32Array([0, 0, 0])  # keep the surface (materials stay in step)
			arr[Mesh.ARRAY_INDEX] = idx
		else:
			arr[Mesh.ARRAY_INDEX] = _rest_idx[s]
		am.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
	body.mesh = am
	for s in mats.size():
		body.set_surface_override_material(s, mats[s])


func reset_dents() -> void:
	for f in _frames:
		if is_instance_valid(f):
			f.queue_free()
	_frames.clear()
	_lost.clear()
	if _mods:
		_build_mods()
	if not _deformed:
		return
	_deformed = false
	_arrays.clear()
	_rest.clear()
	_rest_idx.clear()
	var mats: Array = []
	for s in body.mesh.get_surface_count():
		mats.append(body.get_surface_override_material(s))
	body.mesh = load_mesh(car.spec["body"])
	for s in mats.size():
		body.set_surface_override_material(s, mats[s])


# ------------------------------------------------------------------ panels
## Which triangles belong to which removable panel, per body (cached):
## per surface, one byte per triangle (Car.PARTS index, or NO_PART). Regions
## are fractions of the body's bounds, so one rule fits every model; glass,
## lamps and the dark under-liners always stay on the car.
const NO_PART := 255
const KEEP_MATS := ["glass", "liner", "lamp_head", "lamp_tail", "lamp_rev", "lamp_housing", "beacon_red", "beacon_blue",
	"tyre", "tyre_wall", "rim", "rim_dark", "disc", "caliper"]
static var _part_cache := {}
static var _profile_cache := {}
static var _frame_mat: StandardMaterial3D
static var _steel_mat: StandardMaterial3D
static var _spike_mat: StandardMaterial3D
static var _debris: Array = []
const DEBRIS_MAX := 16
const DEBRIS_LIFE := 9.0

var _part_tri: Array = []        # per surface: PackedByteArray
var _rest_idx: Array = []        # per surface: original index array
var _lost := {}                  # part -> true
var _frames: Array = []          # bare-frame meshes where panels came off
var _mods: Node3D                # Workshop kit


static func part_of(c: Vector3, aabb: AABB) -> int:
	var nx := (c.x - aabb.get_center().x) / maxf(aabb.size.x * 0.5, 0.01)
	var ny := (c.y - aabb.position.y) / maxf(aabb.size.y, 0.01)
	var nz := (c.z - aabb.get_center().z) / maxf(aabb.size.z * 0.5, 0.01)
	if nz < -0.78 and ny < 0.44:
		return 0  # bumper_f
	if nz > 0.8 and ny < 0.46:
		return 1  # bumper_r
	if nz < -0.4 and ny >= 0.42:
		return 2  # hood
	if nz > 0.52 and ny >= 0.46:
		return 3  # boot
	if absf(nx) > 0.72 and nz >= -0.4 and nz <= 0.52 and ny > 0.1 and ny < 0.7:
		return 4 if nx < 0.0 else 5  # door_l / door_r
	return NO_PART


static func part_map(body_name: String, mesh: Mesh) -> Array:
	if _part_cache.has(body_name):
		return _part_cache[body_name]
	var out: Array = []
	var aabb := mesh.get_aabb()
	for s in mesh.get_surface_count():
		var src := mesh.surface_get_material(s)
		var keep := (src.resource_name if src else "") in KEEP_MATS
		var arr := mesh.surface_get_arrays(s)
		var v: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
		var idx: PackedInt32Array = arr[Mesh.ARRAY_INDEX]
		var pm := PackedByteArray()
		pm.resize(idx.size() / 3)
		for t in pm.size():
			if keep:
				pm[t] = NO_PART
				continue
			var c := (v[idx[t * 3]] + v[idx[t * 3 + 1]] + v[idx[t * 3 + 2]]) / 3.0
			pm[t] = part_of(c, aabb)
		out.append(pm)
	_part_cache[body_name] = out
	return out


## Heights and widths the Workshop kit is fitted to (per body, cached).
static func profile(body_name: String, mesh: Mesh) -> Dictionary:
	if _profile_cache.has(body_name):
		return _profile_cache[body_name]
	var aabb := mesh.get_aabb()
	var pr := {"aabb": aabb, "hood_y": aabb.position.y + aabb.size.y * 0.55, "boot_y": aabb.position.y + aabb.size.y * 0.55,
		"side_x": aabb.size.x * 0.5, "front_z": aabb.position.z, "rear_z": aabb.end.z, "belt_y": aabb.position.y + aabb.size.y * 0.55}
	var hz := -INF
	var bz := -INF
	var sx := 0.0
	var gx := 0.0
	var gy0 := INF
	var gy1 := -INF
	var ws := Vector3.ZERO
	var ws_n := 0
	for s in mesh.get_surface_count():
		var src := mesh.surface_get_material(s)
		if src and src.resource_name == "glass":
			# Side windows: the glasshouse width and height mid-car.
			for q: Vector3 in mesh.surface_get_arrays(s)[Mesh.ARRAY_VERTEX]:
				var gz := (q.z - aabb.get_center().z) / (aabb.size.z * 0.5)
				if gz < -0.05 and absf(q.x) < aabb.size.x * 0.25:
					ws += q
					ws_n += 1
				if gz > -0.25 and gz < 0.25 and absf(q.x) > aabb.size.x * 0.25:
					gx = maxf(gx, absf(q.x))
					gy0 = minf(gy0, q.y)
					gy1 = maxf(gy1, q.y)
			continue
		if src == null or src.resource_name != "paint":
			continue
		for q: Vector3 in mesh.surface_get_arrays(s)[Mesh.ARRAY_VERTEX]:
			var nz := (q.z - aabb.get_center().z) / (aabb.size.z * 0.5)
			if nz > -0.75 and nz < -0.5:
				hz = maxf(hz, q.y)
			elif nz > 0.6 and nz < 0.82:
				bz = maxf(bz, q.y)
			if nz > -0.2 and nz < 0.3 and q.y < aabb.position.y + aabb.size.y * 0.5:
				sx = maxf(sx, absf(q.x))
	if hz > -INF:
		pr["hood_y"] = hz
	if bz > -INF:
		pr["boot_y"] = bz
	if sx > 0.0:
		pr["side_x"] = sx
	pr["glass_x"] = gx if gx > 0.0 else aabb.size.x * 0.4
	pr["windscreen"] = ws / ws_n if ws_n > 0 else Vector3(0, aabb.position.y + aabb.size.y * 0.75, aabb.position.z + aabb.size.z * 0.3)
	pr["glass_y0"] = gy0 if gy0 < INF else aabb.position.y + aabb.size.y * 0.62
	pr["glass_y1"] = gy1 if gy1 > -INF else aabb.position.y + aabb.size.y * 0.85
	_profile_cache[body_name] = pr
	return pr


static func _mat_frame() -> StandardMaterial3D:
	if _frame_mat == null:
		_frame_mat = StandardMaterial3D.new()
		# Bare primed steel with a rusty tint: obviously "panel missing".
		_frame_mat.albedo_color = Color(0.38, 0.33, 0.29)
		_frame_mat.metallic = 0.55
		_frame_mat.roughness = 0.7
		_frame_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	return _frame_mat


static func steel_mat() -> StandardMaterial3D:
	if _steel_mat == null:
		_steel_mat = StandardMaterial3D.new()
		# Raw gunmetal: lighter than any paint's shadow side, so the kit
		# reads from the chase camera behind the car.
		_steel_mat.albedo_color = Color(0.43, 0.44, 0.46)
		_steel_mat.metallic = 0.6
		_steel_mat.roughness = 0.36
	return _steel_mat


static func spike_mat() -> StandardMaterial3D:
	if _spike_mat == null:
		_spike_mat = StandardMaterial3D.new()
		_spike_mat.albedo_color = Color(0.78, 0.78, 0.8)
		_spike_mat.metallic = 1.0
		_spike_mat.roughness = 0.2
	return _spike_mat


## A panel comes off: it leaves the body (bare frame showing where it was)
## and tumbles away as debris.
func detach(part: String, world_at: Vector3, normal: Vector3) -> void:
	if body == null or body.mesh == null or _lost.has(part):
		return
	if part.begins_with("plate"):
		_detach_plate(part, normal)
		return
	var pid := Car.PARTS.find(part)
	if pid < 0:
		return
	_ensure_copy()
	# The panel's triangles (as dented now), by surface/material.
	var st_frame := SurfaceTool.new()
	st_frame.begin(Mesh.PRIMITIVE_TRIANGLES)
	var piece := ArrayMesh.new()
	var piece_mats: Array = []
	var any := false
	for s in _arrays.size():
		var pm: PackedByteArray = _part_tri[s]
		var arr: Array = _arrays[s]
		var v: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
		var nrm = arr[Mesh.ARRAY_NORMAL]
		var src_idx: PackedInt32Array = _rest_idx[s]
		var pv := PackedVector3Array()
		var pn := PackedVector3Array()
		for t in pm.size():
			if pm[t] != pid:
				continue
			for k in 3:
				var vi := src_idx[t * 3 + k]
				var q := v[vi]
				var qn: Vector3 = nrm[vi] if nrm != null else Vector3.UP
				pv.append(q)
				pn.append(qn)
				# The frame underneath: the same shape a few cm in, bare metal.
				st_frame.set_normal(qn)
				st_frame.add_vertex(q - qn * 0.045)
		if pv.is_empty():
			continue
		any = true
		var a := []
		a.resize(Mesh.ARRAY_MAX)
		a[Mesh.ARRAY_VERTEX] = pv
		a[Mesh.ARRAY_NORMAL] = pn
		piece.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, a)
		piece_mats.append(body.get_surface_override_material(s))
	_lost[part] = true
	_rebuild()
	if not any:
		return
	var fm := MeshInstance3D.new()
	fm.name = "Frame_" + part
	fm.mesh = st_frame.commit()
	fm.material_override = _mat_frame()
	add_child(fm)
	_frames.append(fm)
	_throw(piece, piece_mats, Transform3D.IDENTITY, normal)


func _detach_plate(part: String, normal: Vector3) -> void:
	_lost[part] = true
	if _mods == null:
		return
	var n := _mods.get_node_or_null(part) as MeshInstance3D
	if n == null or not n.visible:
		return
	n.visible = false
	_throw(n.mesh, [n.material_override], n.transform, normal)


## Debris: a loose panel with a box collider, flung off the car. Shared
## budget across all cars; each piece is cleared after a few seconds.
func _throw(mesh: Mesh, mats: Array, local: Transform3D, normal: Vector3) -> void:
	var world := car.get_parent()
	if world == null or not car.is_inside_tree():
		return
	while _debris.size() >= DEBRIS_MAX:
		var old = _debris.pop_front()
		if is_instance_valid(old):
			old.queue_free()
	var b := RigidBody3D.new()
	b.collision_layer = 1 << 5
	b.collision_mask = 1 | (1 << 3)
	var aabb := mesh.get_aabb()
	b.mass = clampf(aabb.size.x * aabb.size.y * aabb.size.z * 60.0, 6.0, 40.0)
	var cs := CollisionShape3D.new()
	var bs := BoxShape3D.new()
	bs.size = aabb.size.max(Vector3.ONE * 0.08)
	cs.shape = bs
	cs.position = aabb.get_center()
	b.add_child(cs)
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	for i in mini(mats.size(), mesh.get_surface_count()):
		if mats[i]:
			mi.set_surface_override_material(i, mats[i])
	b.add_child(mi)
	world.add_child(b)
	b.global_transform = global_transform * local
	var out := normal if normal.length() > 0.1 else (global_transform.basis * aabb.get_center()).normalized()
	b.linear_velocity = car.linear_velocity * randf_range(0.55, 0.85) + out * randf_range(2.0, 4.5) + Vector3.UP * randf_range(2.5, 5.0)
	b.angular_velocity = Vector3(randf_range(-6, 6), randf_range(-4, 4), randf_range(-6, 6))
	_debris.append(b)
	b.get_tree().create_timer(DEBRIS_LIFE).timeout.connect(func():
		if is_instance_valid(b):
			b.queue_free())


# ------------------------------------------------------------------ Workshop kit
## Bolt-on battle kit from the spec's mods: ram bar / plough, armour plates
## (one node per side so each can come off), window cages, spiked hubs, the
## rear dropper. Primitive shapes merged per piece: a handful of draw calls.
func _build_mods() -> void:
	if _mods:
		_mods.queue_free()
		_mods = null
	for sp in _spins:
		var old := sp.get_node_or_null("Spikes")
		if old:
			old.queue_free()
	var spec := car.spec
	var ram := int(spec.get("mod_ram", 0))
	var pl := int(spec.get("mod_plating", 0))
	var spikes := int(spec.get("mod_spikes", 0))
	var rear := str(spec.get("mod_rear", ""))
	if ram == 0 and pl == 0 and spikes == 0 and rear == "":
		return
	_mods = Node3D.new()
	_mods.name = "Mods"
	add_child(_mods)
	var pr := profile(spec["body"], load_mesh(spec["body"]))
	var aabb: AABB = pr["aabb"]
	var y0 := aabb.position.y
	var h := aabb.size.y
	var w := aabb.size.x
	var fz: float = pr["front_z"]
	var rz: float = pr["rear_z"]
	var steel := steel_mat()
	if ram > 0:
		var st := SurfaceTool.new()
		st.begin(Mesh.PRIMITIVE_TRIANGLES)
		var bar_y := y0 + h * 0.22
		if ram == 1:
			# Push bar: two uprights and two cross tubes ahead of the bumper.
			for x in [-w * 0.28, w * 0.28]:
				_add_box(st, Vector3(0.09, h * 0.36, 0.09), Vector3(x, bar_y + h * 0.1, fz - 0.12))
			for yy in [bar_y, bar_y + h * 0.22]:
				_add_box(st, Vector3(w * 0.86, 0.08, 0.08), Vector3(0, yy, fz - 0.14))
		else:
			# Spiked plough: a raked wedge across the nose with a row of spikes.
			var plate := Transform3D(Basis(Vector3.RIGHT, deg_to_rad(-32.0)), Vector3(0, bar_y + h * 0.04, fz - 0.2))
			_add_box(st, Vector3(w * 1.02, h * 0.36, 0.06), Vector3.ZERO, plate)
			for x in [-w * 0.3, w * 0.3]:
				_add_box(st, Vector3(0.1, 0.1, 0.35), Vector3(x, bar_y, fz + 0.02))
			for i in 6:
				var x2 := lerpf(-w * 0.42, w * 0.42, i / 5.0)
				_add_cone(st, Vector3(x2, bar_y + h * 0.02, fz - 0.27), Vector3.FORWARD, 0.06, 0.3, true)
		var mi := MeshInstance3D.new()
		mi.name = "ram"
		mi.mesh = st.commit()
		mi.material_override = steel
		_mods.add_child(mi)
	if pl > 0:
		var sx: float = pr["side_x"] + 0.03
		var door_h := h * (0.26 + 0.04 * pl)
		var door_y := y0 + h * 0.36
		var door_l := aabb.size.z * 0.46
		var dz := aabb.get_center().z + aabb.size.z * 0.03
		var defs := {
			"plate_l": [Vector3(0.05, door_h, door_l), Vector3(-sx, door_y, dz)],
			"plate_rt": [Vector3(0.05, door_h, door_l), Vector3(sx, door_y, dz)],
			"plate_f": [Vector3(w * 0.7, 0.05, aabb.size.z * 0.16), Vector3(0, float(pr["hood_y"]) + 0.03, fz + aabb.size.z * 0.14)],
			"plate_r": [Vector3(w * 0.78, h * 0.22, 0.05), Vector3(0, y0 + h * 0.3, rz + 0.04)],
		}
		for k in defs:
			var st := SurfaceTool.new()
			st.begin(Mesh.PRIMITIVE_TRIANGLES)
			var sz: Vector3 = defs[k][0]
			_add_box(st, sz, Vector3.ZERO)
			# Rivets along the edges.
			var axis := Vector3(0, 0, 1) if sz.z > sz.x else Vector3(1, 0, 0)
			var span := maxf(sz.x, sz.z)
			var out_n: Vector3 = Vector3(signf((defs[k][1] as Vector3).x), 0, 0) if k in ["plate_l", "plate_rt"] else (Vector3.UP if k == "plate_f" else Vector3.BACK)
			for i in 5:
				var t := lerpf(-span * 0.42, span * 0.42, i / 4.0)
				for e: float in [-1.0, 1.0]:
					var edge: Vector3 = Vector3(0, 0, e * sz.z * 0.38) if k == "plate_f" else Vector3.UP * e * sz.y * 0.38
					_add_box(st, Vector3(0.035, 0.035, 0.035), axis * t + edge + out_n * 0.03)
			var mi := MeshInstance3D.new()
			mi.name = k
			mi.mesh = st.commit()
			mi.material_override = steel
			mi.position = defs[k][1]
			mi.visible = not _lost.has(k)
			_mods.add_child(mi)
		if pl >= 3:
			# Juggernaut: cages over the side windows and the windscreen.
			var st := SurfaceTool.new()
			st.begin(Mesh.PRIMITIVE_TRIANGLES)
			var gx: float = pr["glass_x"]
			var gy0: float = pr["glass_y0"]
			var gy1: float = pr["glass_y1"]
			var gl := aabb.size.z * 0.36
			for side in [-1.0, 1.0]:
				# Rails along the side windows, uprights between them.
				for t in [0.25, 0.6]:
					_add_box(st, Vector3(0.04, 0.04, gl), Vector3(side * (gx + 0.03), lerpf(gy0, gy1, t), aabb.get_center().z))
				for i in 4:
					var z := aabb.get_center().z + lerpf(-gl * 0.45, gl * 0.45, i / 3.0)
					_add_box(st, Vector3(0.04, (gy1 - gy0) * 0.6, 0.04), Vector3(side * (gx + 0.03), lerpf(gy0, gy1, 0.42), z))
			var wsc: Vector3 = pr["windscreen"]
			for i in 4:
				var x := lerpf(-w * 0.26, w * 0.26, i / 3.0)
				_add_box(st, Vector3(0.04, 0.04, aabb.size.z * 0.13), Vector3(x, wsc.y + 0.05, wsc.z - 0.03),
					Transform3D(Basis(Vector3.RIGHT, deg_to_rad(-34.0)), Vector3.ZERO))
			var mi := MeshInstance3D.new()
			mi.name = "cage"
			mi.mesh = st.commit()
			mi.material_override = steel
			_mods.add_child(mi)
	if rear != "":
		var st := SurfaceTool.new()
		st.begin(Mesh.PRIMITIVE_TRIANGLES)
		# A dark hopper under the rear bumper with a coloured hazard band.
		_add_box(st, Vector3(w * 0.36, h * 0.09, 0.2), Vector3(0, y0 + h * 0.2, rz - 0.04))
		var hop := MeshInstance3D.new()
		hop.name = "dropper_box"
		hop.mesh = st.commit()
		hop.material_override = steel
		_mods.add_child(hop)
		st = SurfaceTool.new()
		st.begin(Mesh.PRIMITIVE_TRIANGLES)
		_add_box(st, Vector3(w * 0.37, h * 0.025, 0.21), Vector3(0, y0 + h * 0.2, rz - 0.04))
		var mi := MeshInstance3D.new()
		mi.name = "dropper"
		mi.mesh = st.commit()
		var m := StandardMaterial3D.new()
		m.albedo_color = Color(0.95, 0.6, 0.05) if rear == "caltrops" else Color(0.75, 0.1, 0.06)
		m.roughness = 0.5
		m.emission_enabled = true
		m.emission = m.albedo_color
		m.emission_energy_multiplier = 0.25
		mi.material_override = m
		_mods.add_child(mi)
	if spikes > 0:
		var tw: float = spec.get("tyre_w", 0.26)
		var wr: float = spec["wheel_r"]
		for i in _spins.size():
			var st := SurfaceTool.new()
			st.begin(Mesh.PRIMITIVE_TRIANGLES)
			var side := -1.0 if i % 2 == 0 else 1.0
			var hub := Vector3(side * tw * 0.5, 0, 0)
			_add_cone(st, hub, Vector3(side, 0, 0), 0.07, 0.28, true)
			for k in 6:
				var a := TAU * k / 6.0
				var p := hub + Vector3(0, sin(a), cos(a)) * wr * 0.45
				_add_cone(st, p, Vector3(side, 0, 0), 0.035, 0.14, true)
			var mi := MeshInstance3D.new()
			mi.name = "Spikes"
			mi.mesh = st.commit()
			mi.material_override = spike_mat()
			_spins[i].add_child(mi)


static func _add_box(st: SurfaceTool, size: Vector3, at: Vector3, xf := Transform3D.IDENTITY) -> void:
	var bm := BoxMesh.new()
	bm.size = size
	st.append_from(bm, 0, Transform3D(xf.basis, xf.origin + at))


## A cone from `base` pointing along `dir` (spikes).
static func _add_cone(st: SurfaceTool, base: Vector3, dir: Vector3, r: float, length: float, _sharp: bool) -> void:
	var cm := CylinderMesh.new()
	cm.top_radius = 0.0
	cm.bottom_radius = r
	cm.height = length
	cm.radial_segments = 8
	cm.rings = 1
	var y := dir.normalized()
	var x := y.cross(Vector3.UP if absf(y.y) < 0.9 else Vector3.RIGHT).normalized()
	var z := x.cross(y)
	st.append_from(cm, 0, Transform3D(Basis(x, y, z), base + y * length * 0.5))
