class_name VehicleFx
extends Node3D
## All vehicle effects, pooled and drawn in a handful of MultiMeshes (so 30
## cars cost the same draw calls as one):
##   smoke    tyre smoke from sliding wheels; engine smoke from damaged cars
##   sparks   impacts, metal scraping walls, rims on shredded tyres
##   fire     a badly damaged engine (health < 20 %)
##   skids    dark tyre marks laid on the road (ring buffer)
##   debris   small physical chunks thrown off in heavy crashes (pooled,
##            budgeted by quality, cleaned up after a few seconds)
## Particles are integrated on the CPU in packed arrays and written to the
## MultiMesh buffer once per frame; the billboard happens in the shader.
## Works the same on the Mobile and Compatibility (web) renderers.

const SHADER := preload("res://src/fx/particle.gdshader")

class Pool:
	var mm: MultiMesh
	var node: MultiMeshInstance3D
	var n := 0
	var pos: PackedVector3Array
	var vel: PackedVector3Array
	var life: PackedFloat32Array
	var max_life: PackedFloat32Array
	var size0: PackedFloat32Array
	var size1: PackedFloat32Array
	var col: PackedColorArray
	var next := 0
	var drag := 1.0
	var gravity := 0.0
	var buf: PackedFloat32Array

	func _init(count: int, mat: Material, parent: Node3D) -> void:
		n = count
		mm = MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.use_colors = true
		var q := QuadMesh.new()
		q.size = Vector2(1, 1)
		mm.mesh = q
		mm.instance_count = n
		node = MultiMeshInstance3D.new()
		node.multimesh = mm
		node.material_override = mat
		node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		node.extra_cull_margin = 2000.0
		parent.add_child(node)
		pos.resize(n)
		vel.resize(n)
		life.resize(n)
		max_life.resize(n)
		size0.resize(n)
		size1.resize(n)
		col.resize(n)
		buf.resize(n * 16)
		life.fill(0.0)
		max_life.fill(1.0)

	func emit(p: Vector3, v: Vector3, l: float, s0: float, s1: float, c: Color) -> void:
		var i := next
		next = (next + 1) % n
		pos[i] = p
		vel[i] = v
		life[i] = l
		max_life[i] = l
		size0[i] = s0
		size1[i] = s1
		col[i] = c

	func step(dt: float) -> void:
		var damp := exp(-drag * dt)
		for i in n:
			var l := life[i]
			var o := i * 16
			if l <= 0.0:
				buf[o] = 0.0
				buf[o + 5] = 0.0
				buf[o + 10] = 0.0
				buf[o + 3] = 0.0
				buf[o + 7] = -9999.0
				buf[o + 11] = 0.0
				buf[o + 15] = 0.0
				continue
			l -= dt
			life[i] = l
			var v := vel[i] * damp
			v.y -= gravity * dt
			vel[i] = v
			var p := pos[i] + v * dt
			pos[i] = p
			var k := 1.0 - clampf(l / max_life[i], 0.0, 1.0)
			var s := lerpf(size0[i], size1[i], k)
			var c := col[i]
			# Basis is a uniform scale (the shader billboards it).
			buf[o] = s
			buf[o + 1] = 0.0
			buf[o + 2] = 0.0
			buf[o + 3] = p.x
			buf[o + 4] = 0.0
			buf[o + 5] = s
			buf[o + 6] = 0.0
			buf[o + 7] = p.y
			buf[o + 8] = 0.0
			buf[o + 9] = 0.0
			buf[o + 10] = s
			buf[o + 11] = p.z
			buf[o + 12] = c.r
			buf[o + 13] = c.g
			buf[o + 14] = c.b
			buf[o + 15] = c.a * (1.0 - k)
		mm.buffer = buf


var cars: Array = []           # Car list provided by the game each frame
var smoke: Pool
var sparks: Pool
var fire: Pool
var skid_mm: MultiMesh
var _skid_i := 0
var _skid_n := 1400
var _skid_last := {}           # car id * 4 + wheel -> last mark position
var debris_budget := 48
var _debris: Array = []        # [RigidBody3D, age]
var _debris_mesh: BoxMesh
var _t := 0.0
var _rng := RandomNumberGenerator.new()


func _ready() -> void:
	var st := get_node_or_null("/root/Settings")
	if st:
		debris_budget = st.preset()["debris"]
	smoke = Pool.new(260, _mat(false, 0.85), self)
	smoke.drag = 1.6
	smoke.gravity = -0.6
	sparks = Pool.new(180, _mat(true, 1.0), self)
	sparks.drag = 0.6
	sparks.gravity = 9.0
	fire = Pool.new(60, _mat(true, 1.0), self)
	fire.drag = 2.0
	fire.gravity = -3.0
	# Skid marks: flat quads on the road.
	skid_mm = MultiMesh.new()
	skid_mm.transform_format = MultiMesh.TRANSFORM_3D
	var pm := PlaneMesh.new()
	pm.size = Vector2(0.24, 0.6)
	skid_mm.mesh = pm
	skid_mm.instance_count = _skid_n
	for i in _skid_n:
		skid_mm.set_instance_transform(i, Transform3D(Basis().scaled(Vector3.ZERO), Vector3(0, -9999, 0)))
	var sk := MultiMeshInstance3D.new()
	sk.multimesh = skid_mm
	var skm := StandardMaterial3D.new()
	skm.albedo_color = Color(0.02, 0.02, 0.02, 0.55)
	skm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	skm.roughness = 0.9
	skm.render_priority = -1
	sk.material_override = skm
	sk.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	sk.extra_cull_margin = 2000.0
	add_child(sk)
	_debris_mesh = BoxMesh.new()
	_debris_mesh.size = Vector3(0.35, 0.06, 0.25)


func _mat(additive: bool, alpha: float) -> ShaderMaterial:
	var m := ShaderMaterial.new()
	m.shader = SHADER
	m.set_shader_parameter("additive", additive)
	m.set_shader_parameter("alpha", alpha)
	m.render_priority = 1
	return m


func _process(dt: float) -> void:
	_t += dt
	var cam := get_viewport().get_camera_3d()
	var cp := cam.global_position if cam else Vector3.ZERO
	for c: Car in cars:
		if not is_instance_valid(c) or not c.visible or c.freeze:
			continue
		if c.global_position.distance_squared_to(cp) > 160.0 * 160.0:
			continue
		_car_fx(c, dt)
	smoke.step(dt)
	sparks.step(dt)
	fire.step(dt)
	# Debris lifetime.
	var keep: Array = []
	for d in _debris:
		d[1] += dt
		var b: RigidBody3D = d[0]
		if d[1] > 7.0 or b.global_position.y < -50.0:
			b.queue_free()
		else:
			keep.append(d)
	_debris = keep


func _car_fx(c: Car, dt: float) -> void:
	var xf := c.global_transform
	var sp := c.speed
	var id := c.get_instance_id()
	for i in 4:
		var slip := c.wheel_slip[i]
		if not c.wheel_contact(i):
			_skid_last.erase(id * 4 + i)
			continue
		var p := c.wheel_contact_point(i)
		if slip > 0.35 and sp > 4.0:
			if _rng.randf() < slip * dt * 30.0:
				# Low and wide, hugging the road: a drift trail you can see
				# past, not a wall between the camera and the car.
				var v := -c.linear_velocity * 0.1 + Vector3(_rng.randf_range(-1.4, 1.4), _rng.randf_range(0.3, 1.0), _rng.randf_range(-1.4, 1.4))
				var g := _rng.randf_range(0.8, 0.9)
				smoke.emit(p + Vector3.UP * 0.25, v, _rng.randf_range(1.0, 1.7), 0.6, 2.4 + slip * 1.2, Color(g, g * 0.99, g * 0.97, 0.24 * slip))
			_skid(id * 4 + i, p, c.linear_velocity, slip)
		else:
			_skid_last.erase(id * 4 + i)
		if c.puncture > 0.0 and sp > 6.0 and _rng.randf() < dt * 25.0:
			sparks.emit(p + Vector3.UP * 0.05, -c.linear_velocity * 0.2 + Vector3(_rng.randf_range(-2, 2), _rng.randf_range(1, 3), _rng.randf_range(-2, 2)),
				0.35, 0.08, 0.02, Color(1.0, 0.7, 0.3, 1.0))
	# Engine smoke / fire.
	var hood := xf * Vector3(0, (c.spec["size"] as Vector3).y * 0.75, -(c.spec["size"] as Vector3).z * 0.32)
	if c.health < 0.55 and _rng.randf() < dt * (5.0 + (0.55 - c.health) * 26.0):
		# Thin wisps at first, darker as the engine gets worse; they stream
		# back with the car's speed instead of hanging in front of the camera.
		var dark := clampf(0.55 - c.health, 0.0, 0.5)
		var g2 := 0.5 - dark * 0.7
		smoke.emit(hood, Vector3(_rng.randf_range(-0.3, 0.3), _rng.randf_range(1.0, 2.0), _rng.randf_range(-0.3, 0.3)) - c.linear_velocity * 0.25,
			_rng.randf_range(1.0, 1.8), 0.35, 1.6 + dark * 1.2, Color(g2, g2, g2 * 1.03, 0.2 + dark * 0.6))
	if c.health < 0.2 and _rng.randf() < dt * 30.0:
		fire.emit(hood + Vector3(_rng.randf_range(-0.3, 0.3), 0, _rng.randf_range(-0.3, 0.3)), Vector3(0, _rng.randf_range(1.5, 3.0), 0),
			_rng.randf_range(0.3, 0.6), 0.5, 0.15, Color(1.0, _rng.randf_range(0.35, 0.6), 0.1, 1.0))
	# Scraping: sparks off the side.
	if c.scraping > 0.3 and sp > 5.0 and _rng.randf() < dt * 40.0 * c.scraping:
		var side := xf.basis.x * (1.0 if _rng.randf() < 0.5 else -1.0) * (c.spec["size"] as Vector3).x * 0.5
		sparks.emit(c.global_position + side + Vector3.UP * 0.5, -c.linear_velocity * 0.3 + Vector3(_rng.randf_range(-3, 3), _rng.randf_range(1, 4), _rng.randf_range(-3, 3)),
			0.4, 0.1, 0.02, Color(1.0, 0.75, 0.35, 1.0))


func _skid(key: int, p: Vector3, v: Vector3, slip: float) -> void:
	var last: Vector3 = _skid_last.get(key, Vector3.INF)
	if last != Vector3.INF and last.distance_to(p) < 0.5:
		return
	if last == Vector3.INF or last.distance_to(p) > 3.0:
		_skid_last[key] = p
		return
	var mid := (last + p) * 0.5 + Vector3.UP * 0.03
	var d := p - last
	var len := d.length()
	var fwd := d / len
	var right := fwd.cross(Vector3.UP).normalized()
	var b := Basis(right, Vector3.UP, -fwd)
	b = b.scaled(Vector3(clampf(0.6 + slip, 0.6, 1.3), 1.0, len / 0.6))
	skid_mm.set_instance_transform(_skid_i, Transform3D(b, mid))
	_skid_i = (_skid_i + 1) % _skid_n
	_skid_last[key] = p


## A hit: sparks, a puff of dust/debris, chunks off the car for big ones.
func impact(at: Vector3, normal: Vector3, strength: float, paint: Color) -> void:
	var n := int(clampf(strength * 1.2, 4.0, 40.0))
	for i in n:
		var v := (normal * _rng.randf_range(1.0, 4.0) + Vector3(_rng.randf_range(-1, 1), _rng.randf_range(0.5, 1.5), _rng.randf_range(-1, 1)) * strength * 0.25)
		sparks.emit(at, v, _rng.randf_range(0.25, 0.6), 0.12, 0.03, Color(1.0, _rng.randf_range(0.6, 0.85), 0.35, 1.0))
	for i in int(clampf(strength * 0.3, 1.0, 8.0)):
		smoke.emit(at + Vector3(_rng.randf_range(-0.5, 0.5), 0.2, _rng.randf_range(-0.5, 0.5)),
			Vector3(_rng.randf_range(-1, 1), _rng.randf_range(0.5, 1.5), _rng.randf_range(-1, 1)), 1.0, 0.7, 2.2, Color(0.55, 0.53, 0.5, 0.28))
	if strength > 10.0:
		for i in int(clampf((strength - 8.0) * 0.4, 1.0, 6.0)):
			_chunk(at, normal, strength, paint if i % 2 == 0 else Color(0.05, 0.05, 0.06))


func _chunk(at: Vector3, normal: Vector3, strength: float, col: Color) -> void:
	if _debris.size() >= debris_budget:
		var old: Array = _debris.pop_front()
		(old[0] as Node).queue_free()
	var b := RigidBody3D.new()
	b.collision_layer = 1 << 5
	b.collision_mask = 1 | (1 << 3)
	b.mass = 3.0
	var cs := CollisionShape3D.new()
	var bs := BoxShape3D.new()
	bs.size = _debris_mesh.size
	cs.shape = bs
	b.add_child(cs)
	var mi := MeshInstance3D.new()
	mi.mesh = _debris_mesh
	var m := StandardMaterial3D.new()
	m.albedo_color = col
	m.metallic = 0.4
	m.roughness = 0.4
	mi.material_override = m
	mi.scale = Vector3.ONE * _rng.randf_range(0.6, 1.6)
	b.add_child(mi)
	add_child(b)
	b.global_position = at + normal * 0.3 + Vector3.UP * 0.3
	b.linear_velocity = normal * _rng.randf_range(2, 6) + Vector3(_rng.randf_range(-3, 3), _rng.randf_range(2, 6), _rng.randf_range(-3, 3)) * clampf(strength / 20.0, 0.5, 2.0)
	b.angular_velocity = Vector3(_rng.randf_range(-12, 12), _rng.randf_range(-12, 12), _rng.randf_range(-12, 12))
	_debris.append([b, 0.0])
