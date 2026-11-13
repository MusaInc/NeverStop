class_name RepairPickups
extends Node3D
## Repair stations scattered across the whole city: drive through one and the
## car is good as new (panels back on, dents out, tyres fixed). Never fewer
## than MIN_LIVE or more than MAX_LIVE at once; a used one is replaced
## somewhere else, far from the player, so a battered car has to go hunting
## across the map – and the hunt goes through the police.
##
## Each one is a tall green beacon (visible over the rooftops), a spinning
## wrench-cross and a ring on the road. The minimap shows the ones in range
## and pins the nearest to its rim.
##
## kind = "cash": the same machinery for gold cash drops (a spinning coin,
## a gold beacon): score and cash, more of them, always somewhere new.
##
## Both are placed on the city's inner streets far more than on the coastal
## ring road (lanes weighted by type), so chasing them takes you through
## the middle of town instead of lapping the edge.

signal collected(at: Vector3)

const MIN_LIVE := 3
const MAX_LIVE := 6
const PICK_R := 4.2
const SPACING := 200.0       # between pickups
const AWAY := 230.0          # from the player when one appears
const SPAWN_EVERY := Vector2(18.0, 32.0)
const BEACON_H := 70.0
const GREEN := Color(0.25, 1.0, 0.45)

## Lane weights for placement, by free-flow speed (Traffic.LANE_V): the
## ring road (13 m/s) is rarely used, streets (9) are favoured.
const W_RING := 0.12
const W_MAJOR := 0.9
const W_STREET := 1.6
const GOLD := Color(1.0, 0.78, 0.2)

var kind := "repair"
var net: RoadNet
var player: Car
var active := false
var live: Array = []         # [{pos, node}]
var collected_count := 0
var rng := RandomNumberGenerator.new()
var _t := 0.0
var _spawn_t := 0.0
static var _mats := {}
static var _meshes := {}
static var _beam_shader: Shader


func setup(p_net: RoadNet, p_player: Car) -> void:
	net = p_net
	player = p_player


## A fresh set for a new run: four or five, spread over the map.
func begin(seed := -1) -> void:
	clear()
	if seed >= 0:
		rng.seed = seed
	else:
		rng.randomize()
	active = true
	collected_count = 0
	var want := rng.randi_range(_min_live() + 1, _min_live() + 2)
	for i in want:
		_spawn(150.0)
	_spawn_t = rng.randf_range(SPAWN_EVERY.x, SPAWN_EVERY.y)


func clear() -> void:
	for p in live:
		if is_instance_valid(p["node"]):
			(p["node"] as Node).queue_free()
	live.clear()
	active = false


func positions() -> Array:
	return live.map(func(p): return p["pos"])


func nearest(from: Vector3) -> Vector3:
	var best := Vector3.INF
	var bd := INF
	for p in live:
		var d := from.distance_squared_to(p["pos"])
		if d < bd:
			bd = d
			best = p["pos"]
	return best


func _physics_process(dt: float) -> void:
	if not active or player == null or not is_instance_valid(player):
		return
	_t += dt
	var pp := player.global_position
	for i in range(live.size() - 1, -1, -1):
		var p: Dictionary = live[i]
		var at: Vector3 = p["pos"]
		var d := Vector2(pp.x - at.x, pp.z - at.z).length()
		if d < PICK_R and absf(pp.y - at.y) < 3.5:
			(p["node"] as Node).queue_free()
			live.remove_at(i)
			collected_count += 1
			if kind == "repair":
				player.repair_full()
			collected.emit(at)
	# Never below the minimum: replace at once, somewhere else.
	while live.size() < _min_live():
		if not _spawn(AWAY):
			break
	_spawn_t -= dt
	if _spawn_t <= 0.0:
		_spawn_t = rng.randf_range(SPAWN_EVERY.x, SPAWN_EVERY.y)
		if live.size() < (MAX_LIVE + 2 if kind == "cash" else MAX_LIVE):
			_spawn(AWAY * (0.7 if kind == "cash" else 1.0))


func _process(_dt: float) -> void:
	# Spin and bob (visual only).
	var t := Time.get_ticks_msec() / 1000.0
	for p in live:
		var icon: Node3D = (p["node"] as Node3D).get_node_or_null("Icon")
		if icon:
			icon.rotation.y = t * (3.2 if kind == "cash" else 2.2)
			icon.position.y = 1.7 + sin(t * 2.6 + float(p["phase"])) * 0.18


func _min_live() -> int:
	return MIN_LIVE + 1 if kind == "cash" else MIN_LIVE


## Placement weight of a lane: its length times its type's weight
## (junction connectors never: a pickup mid-junction is a pile-up).
func _lane_w(li: int) -> float:
	if net.lane_conn.size() > li and net.lane_conn[li] == 1:
		return 0.0
	var v: float = net.lane_speed[li] if net.lane_speed.size() > li else 9.0
	var w := W_STREET if v < 10.5 else (W_MAJOR if v < 12.5 else W_RING)
	return net.lane_len[li] * w


## A random lane point anywhere in the city (weighted by _lane_w), away
## from the player and from the others.
func _spawn(min_from_player: float) -> bool:
	if net == null or net.lanes.is_empty():
		return false
	var weights := PackedFloat32Array()
	weights.resize(net.lane_len.size())
	var total := 0.0
	for li in net.lane_len.size():
		weights[li] = _lane_w(li)
		total += weights[li]
	if total <= 0.0:
		return false
	var pp := player.global_position if player else Vector3.ZERO
	var spacing := SPACING * (0.65 if kind == "cash" else 1.0)
	for attempt in 40:
		var r := rng.randf() * total
		var li := 0
		while li < weights.size() - 1 and r > weights[li]:
			r -= weights[li]
			li += 1
		r = r / maxf(weights[li], 0.001) * net.lane_len[li]
		var s := clampf(r, 6.0, maxf(6.0, net.lane_len[li] - 6.0))
		var at := net.lane_point(li, s)
		var sp := min_from_player * (1.0 - attempt / 60.0)
		if at.distance_to(pp) < sp:
			continue
		var ok := true
		for p in live:
			if at.distance_to(p["pos"]) < spacing * (1.0 - attempt / 80.0):
				ok = false
				break
		if not ok:
			continue
		var node := _make(at, net.lane_dir(li, s))
		live.append({"pos": at, "node": node, "phase": rng.randf() * TAU})
		return true
	return false


func _make(at: Vector3, dir: Vector3) -> Node3D:
	var root := Node3D.new()
	root.name = "Repair"
	add_child(root)
	root.global_position = at
	if dir.length() > 0.1:
		root.global_basis = Basis.looking_at(Vector3(dir.x, 0, dir.z).normalized(), Vector3.UP)
	var ring := MeshInstance3D.new()
	ring.mesh = _mesh("ring")
	ring.material_override = _mat("glow" + _sfx())
	ring.position.y = 0.06
	ring.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	root.add_child(ring)
	var icon := Node3D.new()
	icon.name = "Icon"
	icon.position.y = 1.7
	root.add_child(icon)
	var cross := MeshInstance3D.new()
	cross.mesh = _mesh("coin" if kind == "cash" else "cross")
	cross.material_override = _mat("icon" + _sfx())
	icon.add_child(cross)
	var beam := MeshInstance3D.new()
	beam.mesh = _mesh("beam")
	beam.material_override = _mat("beam" + _sfx())
	beam.position.y = BEACON_H * 0.5
	beam.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	root.add_child(beam)
	return root


func _sfx() -> String:
	return "_cash" if kind == "cash" else ""


static func _mesh(kind: String) -> Mesh:
	if _meshes.has(kind):
		return _meshes[kind]
	var m: Mesh
	match kind:
		"ring":
			var t := TorusMesh.new()
			t.inner_radius = 3.0
			t.outer_radius = 3.5
			t.rings = 32
			t.ring_segments = 6
			m = t
		"cross":
			# A chunky plus with a wrench-like ring round it.
			var st := SurfaceTool.new()
			st.begin(Mesh.PRIMITIVE_TRIANGLES)
			var a := BoxMesh.new()
			a.size = Vector3(1.3, 0.36, 0.36)
			st.append_from(a, 0, Transform3D.IDENTITY)
			var b := BoxMesh.new()
			b.size = Vector3(0.36, 1.3, 0.36)
			st.append_from(b, 0, Transform3D.IDENTITY)
			var r := TorusMesh.new()
			r.inner_radius = 0.85
			r.outer_radius = 1.0
			r.rings = 24
			r.ring_segments = 6
			st.append_from(r, 0, Transform3D(Basis(Vector3.RIGHT, PI * 0.5), Vector3.ZERO))
			m = st.commit()
		"coin":
			# A fat gold coin standing on its edge, with a raised rim.
			var st2 := SurfaceTool.new()
			st2.begin(Mesh.PRIMITIVE_TRIANGLES)
			var face := CylinderMesh.new()
			face.top_radius = 0.85
			face.bottom_radius = 0.85
			face.height = 0.22
			face.radial_segments = 24
			st2.append_from(face, 0, Transform3D(Basis(Vector3.RIGHT, PI * 0.5), Vector3.ZERO))
			var rim := TorusMesh.new()
			rim.inner_radius = 0.78
			rim.outer_radius = 0.95
			rim.rings = 24
			rim.ring_segments = 6
			st2.append_from(rim, 0, Transform3D(Basis(Vector3.RIGHT, PI * 0.5), Vector3.ZERO))
			m = st2.commit()
		"beam":
			var c := CylinderMesh.new()
			c.top_radius = 0.7
			c.bottom_radius = 1.1
			c.height = BEACON_H
			c.radial_segments = 12
			c.rings = 1
			c.cap_top = false
			c.cap_bottom = false
			m = c
	_meshes[kind] = m
	return m


static func _mat(key: String) -> Material:
	if _mats.has(key):
		return _mats[key]
	var cash := key.ends_with("_cash")
	var kind := key.trim_suffix("_cash")
	var col := GOLD if cash else GREEN
	var m: Material
	match kind:
		"glow":
			var s := StandardMaterial3D.new()
			s.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
			s.albedo_color = col
			m = s
		"icon":
			var s2 := StandardMaterial3D.new()
			s2.albedo_color = Color(1.0, 0.86, 0.4) if cash else Color(0.85, 1.0, 0.88)
			s2.metallic = 0.6 if cash else 0.0
			s2.roughness = 0.35 if cash else 1.0
			s2.emission_enabled = true
			s2.emission = col
			s2.emission_energy_multiplier = 2.2
			m = s2
		"beam":
			# One shader for both kinds (one compile); the colour is a uniform.
			if _beam_shader == null:
				_beam_shader = Shader.new()
				_beam_shader.code = """
shader_type spatial;
render_mode unshaded, blend_add, depth_draw_never, cull_disabled, shadows_disabled;
uniform vec3 col = vec3(0.25, 1.0, 0.45);
varying float h;
void vertex() { h = VERTEX.y / %.1f + 0.5; }
void fragment() {
	float rim = pow(1.0 - abs(dot(NORMAL, VIEW)), 1.5);
	float fade = (1.0 - h) * (1.0 - h);
	ALBEDO = col;
	ALPHA = clamp((0.12 + rim * 0.35) * fade, 0.0, 1.0);
}
""" % BEACON_H
			var sm := ShaderMaterial.new()
			sm.shader = _beam_shader
			sm.set_shader_parameter("col", Vector3(col.r, col.g, col.b))
			m = sm
	_mats[key] = m
	return m
