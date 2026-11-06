class_name PoliceHeli
extends Node3D
## Air support: circles above the player with lag, a searchlight on the car
## (strong at night), rotor wash audio hook. While it is up, every unit knows
## where the player is (PursuitDirector awareness).

var target: Node3D
var altitude := 62.0
var _rotor: Node3D
var _tail_rotor: Node3D
var light: SpotLight3D
var _vel := Vector3.ZERO
var _orbit := 0.0
var _beacon: OmniLight3D
var _t := 0.0


func _ready() -> void:
	var body_m := StandardMaterial3D.new()
	body_m.albedo_color = Color(0.07, 0.08, 0.11)
	body_m.metallic = 0.5
	body_m.roughness = 0.35
	var stripe := StandardMaterial3D.new()
	stripe.albedo_color = Color(0.92, 0.94, 0.96)
	var glass := StandardMaterial3D.new()
	glass.albedo_color = Color(0.05, 0.07, 0.1)
	glass.metallic = 0.8
	glass.roughness = 0.05
	_part(_capsule(1.3, 5.4), body_m, Vector3.ZERO, Vector3(PI / 2, 0, 0), Vector3(1.0, 1.0, 0.8))
	_part(_capsule(1.0, 2.4), glass, Vector3(0, 0.15, -1.9), Vector3(PI / 2, 0, 0), Vector3(0.95, 1.0, 0.75))
	_part(_box(Vector3(0.35, 0.35, 5.5)), body_m, Vector3(0, 0.35, 4.6), Vector3.ZERO)
	_part(_box(Vector3(0.1, 1.3, 0.9)), body_m, Vector3(0, 0.9, 7.1), Vector3.ZERO)
	_part(_box(Vector3(2.6, 0.06, 0.25)), stripe, Vector3(0, -0.15, 0.2), Vector3.ZERO)
	for sx in [-1.0, 1.0]:
		_part(_box(Vector3(0.08, 0.08, 3.4)), body_m, Vector3(sx * 0.9, -1.25, 0.0), Vector3.ZERO)
	_rotor = Node3D.new()
	_rotor.position = Vector3(0, 1.25, 0)
	add_child(_rotor)
	for i in 4:
		var blade := MeshInstance3D.new()
		blade.mesh = _box(Vector3(0.32, 0.04, 5.6))
		blade.material_override = body_m
		blade.position = Vector3(0, 0, 2.8).rotated(Vector3.UP, i * PI / 2)
		blade.rotation.y = i * PI / 2
		_rotor.add_child(blade)
	_tail_rotor = Node3D.new()
	_tail_rotor.position = Vector3(0.15, 0.9, 7.2)
	add_child(_tail_rotor)
	for i in 2:
		var tb := MeshInstance3D.new()
		tb.mesh = _box(Vector3(0.03, 1.3, 0.12))
		tb.material_override = body_m
		tb.rotation.x = i * PI / 2
		_tail_rotor.add_child(tb)
	light = SpotLight3D.new()
	light.spot_range = 160.0
	light.spot_angle = 9.0
	light.light_energy = 6.0
	light.light_color = Color(1.0, 0.97, 0.9)
	light.shadow_enabled = false
	light.position = Vector3(0, -1.2, -2.0)
	add_child(light)
	_beacon = OmniLight3D.new()
	_beacon.light_color = Color(1.0, 0.1, 0.1)
	_beacon.omni_range = 6.0
	_beacon.position = Vector3(0, -1.3, 1.0)
	add_child(_beacon)


func _part(mesh: Mesh, mat: Material, pos: Vector3, rot: Vector3, scl := Vector3.ONE) -> void:
	var m := MeshInstance3D.new()
	m.mesh = mesh
	m.material_override = mat
	m.position = pos
	m.rotation = rot
	m.scale = scl
	add_child(m)


static func _capsule(r: float, h: float) -> Mesh:
	var c := CapsuleMesh.new()
	c.radius = r
	c.height = h
	c.radial_segments = 12
	c.rings = 4
	return c


static func _box(s: Vector3) -> Mesh:
	var b := BoxMesh.new()
	b.size = s
	return b


func _physics_process(dt: float) -> void:
	Prof.begin("heli")
	if target == null or not is_instance_valid(target):
		Prof.end("heli")
		return
	_t += dt
	_rotor.rotate_y(dt * 28.0)
	_tail_rotor.rotate_x(dt * 40.0)
	_beacon.light_energy = 2.0 if fmod(_t, 1.0) < 0.12 else 0.0
	_orbit += dt * 0.12
	var tp := target.global_position
	var tv: Vector3 = target.linear_velocity if "linear_velocity" in target else Vector3.ZERO
	var want := tp + tv * 2.5 + Vector3(cos(_orbit), 0.0, sin(_orbit)) * 45.0 + Vector3.UP * altitude
	var acc := (want - global_position) * 0.8 - _vel * 1.2
	_vel += acc.limit_length(14.0) * dt
	global_position += _vel * dt
	# Bank into the motion, nose toward the target.
	var to := tp - global_position
	to.y = 0.0
	if to.length() > 1.0:
		var yaw := atan2(-to.x, -to.z)
		rotation.y = lerp_angle(rotation.y, yaw, 1.0 - exp(-1.5 * dt))
	rotation.z = lerpf(rotation.z, clampf(-_vel.dot(global_basis.x) * 0.02, -0.3, 0.3), 1.0 - exp(-2.0 * dt))
	rotation.x = lerpf(rotation.x, clampf(-_vel.dot(-global_basis.z) * 0.012, -0.25, 0.25), 1.0 - exp(-2.0 * dt))
	light.look_at(tp, Vector3.UP)
	var atmo := get_node_or_null("/root/Game/Atmosphere")
	var night: float = atmo.night if atmo else 0.0
	light.visible = night > 0.2
	light.light_energy = 6.0 * night
	Prof.end("heli")


