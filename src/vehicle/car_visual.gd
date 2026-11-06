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

static var _mesh_cache := {}
static var _mat_cache := {}

var car: Car
var body: MeshInstance3D
var wheels: Array[Node3D] = []      # steer pivots
var _spins: Array[Node3D] = []      # spin nodes under them
var paint_mat: StandardMaterial3D
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
	match name:
		"glass":
			m.albedo_color = Color(0.03, 0.035, 0.045)
			m.metallic = 0.7
			m.roughness = 0.06
			m.metallic_specular = 0.9
		"trim", "liner", "grille":
			m.albedo_color = Color(0.035, 0.035, 0.04) if name != "liner" else Color(0.015, 0.015, 0.015)
			m.roughness = 0.55 if name == "trim" else 0.85
			m.metallic = 0.2 if name == "grille" else 0.0
		"chrome", "rim":
			m.albedo_color = Color(0.72, 0.73, 0.76)
			m.metallic = 1.0
			m.roughness = 0.22
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
	paint_mat = StandardMaterial3D.new()
	paint_mat.albedo_color = spec["paint"]
	paint_mat.metallic = 0.5
	paint_mat.roughness = 0.3
	paint_mat.clearcoat_enabled = true
	paint_mat.clearcoat = 0.6
	paint_mat.clearcoat_roughness = 0.15
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
		wheels.append(pivot)
		_spins.append(spin)
	if beacon_mat:
		beacon_mat.set_shader_parameter("phase", randf())


func set_paint(c: Color) -> void:
	paint_mat.albedo_color = c


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
	tail_mat.emission_energy_multiplier = 3.2 if braking or car.disabled else 0.7
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
		var base: Color = spec.get("paint_now", spec["paint"])
		paint_mat.albedo_color = base.lerp(Color(0.08, 0.07, 0.06), d * 0.45)
		paint_mat.roughness = lerpf(0.3, 0.75, d)
		paint_mat.clearcoat = lerpf(0.6, 0.0, d)


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
