class_name BattleKit
extends Node3D
## The player's active Workshop gear during a chase:
##   * Hydraulics: JUMP hops the car (cooldown in Car.hydraulic_jump).
##   * Rear dropper: DROP lays caltrops (punctures police tyres) or a
##     proximity mine (wrecks the police car that finds it). Charges refill
##     over time.
## Passive gear (ram bar, plating, spiked hubs) lives in the spec and in
## Car._handle_impacts.

signal used(kind: String)
signal hit(kind: String, car: Car)

const CALTROP_LIFE := 22.0
const MINE_LIFE := 50.0
const MINE_ARM := 0.7
const MINE_R := 3.6
const BLAST_R := 9.0
const MAX_DROPS := 8

var car: Car
var fx: VehicleFx
var audio: AudioDirector
var rear := ""           # "caltrops" | "mines" | ""
var charges := 0
var max_charges := 0
var recharge := 25.0
var _recharge_t := 0.0
var _drops: Array = []   # [{kind, node, t, pos}]


func setup(p_car: Car) -> void:
	car = p_car
	rear = str(car.spec.get("mod_rear", ""))
	var lvl := int(car.spec.get("mod_rear_lvl", 0))
	match rear:
		"caltrops":
			max_charges = [0, 3, 5][clampi(lvl, 0, 2)]
			recharge = 22.0 if lvl < 2 else 16.0
		"mines":
			max_charges = [0, 2, 4][clampi(lvl, 0, 2)]
			recharge = 28.0 if lvl < 2 else 20.0
	charges = max_charges
	_recharge_t = 0.0


func has_jump() -> bool:
	return car != null and int(car.spec.get("mod_jump", 0)) > 0


func has_drop() -> bool:
	return rear != "" and max_charges > 0


func jump_ready() -> float:
	if not has_jump():
		return 0.0
	var cd := 6.0 if int(car.spec.get("mod_jump", 0)) == 1 else 4.0
	return 1.0 - car.jump_cd / cd


func recharge_k() -> float:
	return 1.0 if charges >= max_charges else _recharge_t / recharge


func reset() -> void:
	charges = max_charges
	_recharge_t = 0.0
	for d in _drops:
		if is_instance_valid(d["node"]):
			(d["node"] as Node).queue_free()
	_drops.clear()


func jump() -> bool:
	if car == null or not car.hydraulic_jump():
		return false
	if audio:
		audio.play("hydraulic", -2.0)
	used.emit("jump")
	return true


func drop() -> bool:
	if not has_drop() or charges <= 0 or car.disabled:
		return false
	charges -= 1
	var back := car.global_basis.z
	back.y = 0.0
	back = back.normalized()
	var size: Vector3 = car.spec["size"]
	var at := car.global_position + back * (size.z * 0.5 + 1.4)
	# Onto the road under the drop point.
	var q := PhysicsRayQueryParameters3D.create(at + Vector3.UP * 2.0, at + Vector3.DOWN * 6.0, Car.RAY_MASK)
	q.exclude = [car.get_rid()]
	var h := get_world_3d().direct_space_state.intersect_ray(q)
	if h:
		at = h["position"]
	var node: Node3D = _caltrops(at, back) if rear == "caltrops" else _mine(at)
	_drops.append({"kind": rear, "node": node, "t": 0.0, "pos": at})
	while _drops.size() > MAX_DROPS:
		var old: Dictionary = _drops.pop_front()
		if is_instance_valid(old["node"]):
			(old["node"] as Node).queue_free()
	if audio:
		audio.play("drop", -3.0)
	used.emit(rear)
	return true


func _physics_process(dt: float) -> void:
	if car == null:
		return
	if charges < max_charges:
		_recharge_t += dt
		if _recharge_t >= recharge:
			_recharge_t = 0.0
			charges += 1
	var keep: Array = []
	for d in _drops:
		d["t"] += dt
		var node: Node3D = d["node"]
		if not is_instance_valid(node):
			continue
		var life := CALTROP_LIFE if d["kind"] == "caltrops" else MINE_LIFE
		if d["t"] > life:
			node.queue_free()
			continue
		if d["kind"] == "mines":
			# Blink faster as it arms; then wait for a police car.
			var lamp := node.get_node_or_null("Lamp") as MeshInstance3D
			if lamp:
				lamp.visible = fmod(d["t"] * (2.0 if d["t"] > MINE_ARM else 8.0), 1.0) < 0.5
			if d["t"] > MINE_ARM:
				var victim := _police_near(d["pos"], MINE_R)
				if victim:
					_explode(d["pos"], victim)
					node.queue_free()
					continue
		else:
			for c in _police_list():
				var cc := c as Car
				if cc.puncture < 1.0 and _in_strip(cc.global_position, d):
					cc.puncture = 1.0
					cc.grip_loss = 0.8
					hit.emit("caltrops", cc)
		keep.append(d)
	_drops = keep


func _police_list() -> Array:
	var out: Array = []
	var dir := get_node_or_null("../Pursuit") as PursuitDirector
	if dir == null:
		return out
	for u in dir.units:
		if u.car and u.alive():
			out.append(u.car)
	return out


func _police_near(at: Vector3, r: float) -> Car:
	for c in _police_list():
		if (c as Car).global_position.distance_to(at) < r:
			return c
	return null


func _in_strip(p: Vector3, d: Dictionary) -> bool:
	var node: Node3D = d["node"]
	var local := node.global_transform.affine_inverse() * p
	return absf(local.x) < 2.6 and absf(local.z) < 1.6 and absf(local.y) < 2.0


func _explode(at: Vector3, victim: Car) -> void:
	for c in _police_list():
		var cc := c as Car
		var d := cc.global_position.distance_to(at)
		if d > BLAST_R:
			continue
		var k := 1.0 - d / BLAST_R
		var away := (cc.global_position - at)
		away.y = 0.0
		away = away.normalized() if away.length() > 0.1 else Vector3.FORWARD
		cc.linear_velocity += (away * 9.0 + Vector3.UP * 7.5) * k
		cc.angular_velocity += Vector3(randf_range(-3, 3), randf_range(-2, 2), randf_range(-3, 3)) * k
		cc.health = minf(cc.health, 0.05) if cc == victim else maxf(0.0, cc.health - 0.6 * k)
		# Panels blown off.
		for pn in Car.PARTS:
			if randf() < 0.55 * k + (0.3 if cc == victim else 0.0):
				cc._wear_part(pn, 2.0, cc.global_position, away)
		if cc == victim or cc.health < 0.12:
			hit.emit("mines", cc)
	# The player feels it too if they're close (a shove, no damage).
	var pd := car.global_position.distance_to(at)
	if pd < BLAST_R:
		var a2 := car.global_position - at
		a2.y = 0.0
		car.linear_velocity += a2.normalized() * 4.0 * (1.0 - pd / BLAST_R) + Vector3.UP * 2.0 * (1.0 - pd / BLAST_R)
	if fx:
		fx.explosion(at)
	if audio:
		audio.play_at("explosion", at, 4.0)


# ------------------------------------------------------------------ props
static var _mats := {}


static func _m(kind: String) -> Material:
	if _mats.has(kind):
		return _mats[kind]
	var m := StandardMaterial3D.new()
	match kind:
		"steel":
			m.albedo_color = Color(0.2, 0.2, 0.22)
			m.metallic = 0.8
			m.roughness = 0.35
		"hazard":
			m.albedo_color = Color(0.95, 0.65, 0.05)
			m.emission_enabled = true
			m.emission = Color(0.95, 0.55, 0.05)
			m.emission_energy_multiplier = 0.5
		"lamp":
			m.albedo_color = Color(1.0, 0.1, 0.05)
			m.emission_enabled = true
			m.emission = Color(1.0, 0.1, 0.05)
			m.emission_energy_multiplier = 4.0
	_mats[kind] = m
	return m


func _caltrops(at: Vector3, back: Vector3) -> Node3D:
	var root := Node3D.new()
	root.name = "Caltrops"
	get_parent().add_child(root)
	root.global_transform = Transform3D(Basis.looking_at(back, Vector3.UP), at + Vector3.UP * 0.02)
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	var spike := PrismMesh.new()
	spike.size = Vector3(0.12, 0.16, 0.12)
	mm.mesh = spike
	mm.instance_count = 40
	var r := RandomNumberGenerator.new()
	for i in 40:
		mm.set_instance_transform(i, Transform3D(Basis(Vector3.UP, r.randf() * TAU), Vector3(r.randf_range(-2.4, 2.4), 0.08, r.randf_range(-1.4, 1.4))))
	var mmi := MultiMeshInstance3D.new()
	mmi.multimesh = mm
	mmi.material_override = _m("steel")
	root.add_child(mmi)
	# Hazard tape so the player can see what they left behind.
	for z in [-1.5, 1.5]:
		var bar := MeshInstance3D.new()
		var bm := BoxMesh.new()
		bm.size = Vector3(5.0, 0.03, 0.12)
		bar.mesh = bm
		bar.position = Vector3(0, 0.02, z)
		bar.material_override = _m("hazard")
		root.add_child(bar)
	return root


func _mine(at: Vector3) -> Node3D:
	var root := Node3D.new()
	root.name = "Mine"
	get_parent().add_child(root)
	root.global_position = at
	var body := MeshInstance3D.new()
	var cm := CylinderMesh.new()
	cm.top_radius = 0.35
	cm.bottom_radius = 0.45
	cm.height = 0.16
	cm.radial_segments = 16
	body.mesh = cm
	body.position.y = 0.08
	body.material_override = _m("steel")
	root.add_child(body)
	var lamp := MeshInstance3D.new()
	lamp.name = "Lamp"
	var sm := SphereMesh.new()
	sm.radius = 0.09
	sm.height = 0.18
	lamp.mesh = sm
	lamp.position.y = 0.2
	lamp.material_override = _m("lamp")
	root.add_child(lamp)
	return root
