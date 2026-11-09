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
const BEAM_SHADER := preload("res://src/vehicle/head_beam.gdshader")
const BEAM_LEN := 20.0

static var _mesh_cache := {}
static var _mat_cache := {}
static var _lamp_cache := {}
static var _flare_mat: ShaderMaterial
static var _beam_mat: ShaderMaterial
## 0 day .. 1 night (street lamps on). Set by Atmosphere every frame.
static var lamps := 0.0

var car: Car
var body: MeshInstance3D
var wheels: Array[Node3D] = []      # steer pivots
var _spins: Array[Node3D] = []      # spin nodes under them
var paint_mat: ShaderMaterial
var flares: MeshInstance3D
var head_lights: Array[SpotLight3D] = []
var beams: Array[MeshInstance3D] = []
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


## Real headlights (the player's car): two spotlights that light the road
## ahead at night, plus a faint visible beam in the air. Off by day.
func enable_headlights(shadows := false) -> void:
	if not head_lights.is_empty() or lamp_pos["head"].is_empty():
		return
	if _beam_mat == null:
		_beam_mat = ShaderMaterial.new()
		_beam_mat.shader = BEAM_SHADER
		_beam_mat.set_shader_parameter("height", BEAM_LEN)
	var cone := CylinderMesh.new()
	cone.top_radius = 0.12
	cone.bottom_radius = 3.2
	cone.height = BEAM_LEN
	cone.radial_segments = 16
	cone.rings = 1
	cone.cap_top = false
	cone.cap_bottom = false
	# One soft, wide pool of light from just ahead of the bumper. (Two lamps
	# each had their own spotlight inside the lamp housing: the housing
	# shadowed its own light, leaving two dark discs on the road.)
	var heads: Array = lamp_pos["head"]
	var mid := Vector3.ZERO
	for p: Vector3 in heads:
		mid += p
	mid /= float(heads.size())
	var l := SpotLight3D.new()
	l.name = "Headlight"
	l.light_color = Color(1.0, 0.95, 0.86)
	l.spot_range = 80.0
	l.spot_angle = 38.0
	l.spot_angle_attenuation = 0.6
	l.spot_attenuation = 0.8
	l.light_energy = 0.0
	l.light_specular = 0.4
	l.shadow_enabled = false
	l.position = Vector3(0.0, mid.y + 0.15, mid.z - 0.9)
	l.rotation = Vector3(deg_to_rad(-6.0), 0.0, 0.0)
	l.visible = false
	add_child(l)
	head_lights.append(l)
	for p: Vector3 in heads:
		var bm := MeshInstance3D.new()
		bm.name = "Beam"
		bm.mesh = cone
		bm.material_override = _beam_mat
		bm.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		# Narrow end at the lamp, opening forward, flattened (stays off the road).
		bm.transform = Transform3D(Basis(Vector3.RIGHT, PI * 0.5).scaled(Vector3(1.0, 1.0, 0.22)),
			p + Vector3(0, 0, -BEAM_LEN * 0.5 - 0.1))
		bm.rotation.y = -signf(p.x) * deg_to_rad(3.0)
		bm.visible = false
		add_child(bm)
		beams.append(bm)


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
		for l in head_lights:
			l.visible = on
			l.light_energy = 14.0 * lamps
		for b in beams:
			b.visible = on
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
	if not _deformed:
		_deformed = true
		var src: Mesh = body.mesh
		for s in src.get_surface_count():
			var arr := src.surface_get_arrays(s)
			_arrays.append(arr)
			_rest.append((arr[Mesh.ARRAY_VERTEX] as PackedVector3Array).duplicate())
	var inv := body.global_transform.affine_inverse()
	var c := inv * world_at
	var d := (inv.basis * dir).normalized()
	var r2 := radius * radius
	var am := ArrayMesh.new()
	var src_mesh: Mesh = body.mesh
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
		am.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
	var mats: Array = []
	for s in src_mesh.get_surface_count():
		mats.append(body.get_surface_override_material(s))
	body.mesh = am
	for s in mats.size():
		body.set_surface_override_material(s, mats[s])


func reset_dents() -> void:
	if not _deformed:
		return
	_deformed = false
	_arrays.clear()
	_rest.clear()
	var mats: Array = []
	for s in body.mesh.get_surface_count():
		mats.append(body.get_surface_override_material(s))
	body.mesh = load_mesh(car.spec["body"])
	for s in mats.size():
		body.set_surface_override_material(s, mats[s])
