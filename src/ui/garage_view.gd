class_name GarageView
extends SubViewportContainer
## The garage's car preview: its own small 3-D world (a dark studio floor,
## key/rim/fill lights, a slow turntable) so it never touches the city.
## Drag to spin the car.

var vp: SubViewport
var stage: Node3D
var car: Car
var visual: CarVisual
var cam: Camera3D
var _spin := 0.6
var _drag := false
var _yaw := 0.6
## The part of the screen the car must fit in (the garage's free area right
## of the stats card, above the switcher). Whole view when unset.
var focus: Control
var _centre := Vector3(0, 0.7, 0)  # middle of the car's visual bounds
var _radius := 3.0                  # bounding sphere: fits at every turntable yaw
var _disc: Array[Node3D] = []       # turntable floor + rim (sized to the car)
const ELEV := 0.166                 # camera ~9.5° above the car's middle


func _ready() -> void:
	stretch = true
	vp = SubViewport.new()
	vp.own_world_3d = true
	vp.transparent_bg = false
	vp.msaa_3d = Viewport.MSAA_4X
	add_child(vp)
	stage = Node3D.new()
	vp.add_child(stage)
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.035, 0.04, 0.055)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.32, 0.34, 0.4)
	env.ambient_light_energy = 0.6
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	env.glow_enabled = true
	env.glow_intensity = 0.4
	env.fog_enabled = true
	env.fog_light_color = Color(0.035, 0.04, 0.055)
	env.fog_density = 0.04
	var we := WorldEnvironment.new()
	we.environment = env
	stage.add_child(we)
	var key := DirectionalLight3D.new()
	key.rotation_degrees = Vector3(-50, 35, 0)
	key.light_energy = 1.4
	key.shadow_enabled = true
	stage.add_child(key)
	for l in [[Vector3(-5, 3, -4), Color(1.0, 0.3, 0.3), 6.0], [Vector3(5, 3, 4), Color(0.3, 0.5, 1.0), 6.0], [Vector3(0, 6, 0), Color(1, 1, 1), 3.0]]:
		var o := OmniLight3D.new()
		o.position = l[0]
		o.light_color = l[1]
		o.light_energy = l[2]
		o.omni_range = 14.0
		stage.add_child(o)
	var floor_m := StandardMaterial3D.new()
	floor_m.albedo_color = Color(0.06, 0.065, 0.075)
	floor_m.roughness = 0.25
	floor_m.metallic = 0.4
	var floor := MeshInstance3D.new()
	var pm := CylinderMesh.new()
	pm.top_radius = 4.2
	pm.bottom_radius = 4.3
	pm.height = 0.1
	pm.radial_segments = 48
	floor.mesh = pm
	floor.material_override = floor_m
	floor.position.y = -0.05
	stage.add_child(floor)
	_disc.append(floor)
	var ring := MeshInstance3D.new()
	var tm := TorusMesh.new()
	tm.inner_radius = 4.22
	tm.outer_radius = 4.3
	ring.mesh = tm
	var rm := StandardMaterial3D.new()
	rm.albedo_color = UiStyle.AMBER
	rm.emission_enabled = true
	rm.emission = UiStyle.AMBER
	rm.emission_energy_multiplier = 0.6
	ring.material_override = rm
	ring.scale = Vector3(1, 0.2, 1)
	stage.add_child(ring)
	_disc.append(ring)
	cam = Camera3D.new()
	cam.fov = 34.0
	stage.add_child(cam)
	# The car sits right of centre (the stats are on the left).
	cam.position = Vector3(-2.6, 1.9, 8.6)
	cam.look_at(Vector3(-2.6, 0.45, 0), Vector3.UP)
	cam.current = true


func show_car(spec: Dictionary) -> void:
	if car:
		car.queue_free()
	car = Car.new()
	car.setup(spec, "player")
	car.freeze = true
	stage.add_child(car)
	visual = CarVisual.new()
	car.add_child(visual)
	visual.setup(car)
	for i in 4:
		car.wheel_comp_visual[i] = 0.08
	car.position = Vector3.ZERO
	car.rotation.y = 0.0
	_measure()
	car.rotation.y = _yaw
	_frame()


## The car's real drawn bounds (body, wheels, bars – not the catalogue size):
## a sphere round them fits whatever way the turntable faces.
func _measure() -> void:
	var inv := car.global_transform.affine_inverse()
	var box := AABB()
	var first := true
	for mi: MeshInstance3D in car.find_children("*", "MeshInstance3D", true, false):
		if mi.mesh == null or not mi.is_visible_in_tree():
			continue
		var b := (inv * mi.global_transform) * mi.get_aabb()
		box = b if first else box.merge(b)
		first = false
	if first:
		var sz: Vector3 = car.spec.get("size", Vector3(2, 1.5, 4.6)) if "spec" in car else Vector3(2, 1.5, 4.6)
		box = AABB(Vector3(-sz.x, 0, -sz.z) * 0.5, sz)
	box.position.y = maxf(box.position.y, 0.0)
	var half_xz := Vector2(maxf(absf(box.position.x), absf(box.end.x)), maxf(absf(box.position.z), absf(box.end.z))).length()
	_centre = Vector3(0, box.get_center().y, 0)
	# Turntable just wider than the car's swept circle; the framed sphere
	# holds both, so the rim never runs off the free area either.
	var disc_r := half_xz + 0.45
	var k := disc_r / 4.3
	for d in _disc:
		d.scale = Vector3(k, d.scale.y, k)
	_radius = Vector2(disc_r, maxf(box.size.y * 0.5, _centre.y)).length() * 1.02


## Camera distance and lens shift so the sphere sits in `focus` at any aspect.
func _frame() -> void:
	if size.x < 8.0 or size.y < 8.0:
		return
	var r := Rect2(Vector2.ZERO, size)
	if focus and is_instance_valid(focus) and focus.size.x > 40.0 and focus.size.y > 40.0:
		r = Rect2(focus.get_global_rect().position - get_global_rect().position, focus.size).intersection(r)
	var asp := size.x / size.y
	cam.keep_aspect = Camera3D.KEEP_HEIGHT
	cam.fov = 34.0
	var tv := tan(deg_to_rad(cam.fov) * 0.5)
	var th := tv * asp
	# Focus rect in normalised device coordinates (centre, half extents).
	var cx := r.get_center().x / size.x * 2.0 - 1.0
	var cy := 1.0 - r.get_center().y / size.y * 2.0
	var a := atan(minf(r.size.x / size.x * th, r.size.y / size.y * tv))
	var dist := _radius / sin(a)
	var dir := Vector3(0, ELEV, 1).normalized()
	cam.position = _centre + dir * dist
	cam.look_at(_centre, Vector3.UP)
	cam.h_offset = -cx * dist * th
	cam.v_offset = -cy * dist * tv
	cam.far = dist + _radius * 4.0 + 20.0


func _gui_input(ev: InputEvent) -> void:
	if ev is InputEventMouseButton:
		_drag = (ev as InputEventMouseButton).pressed
	elif ev is InputEventMouseMotion and _drag:
		_yaw += (ev as InputEventMouseMotion).relative.x * 0.01
		_spin = 0.0


func _process(dt: float) -> void:
	if size.x < 8.0 and get_parent() is Control:
		size = (get_parent() as Control).size
	if size.x > 8.0 and Vector2i(size) != vp.size:
		vp.size = Vector2i(size)
	if car:
		_frame()  # (cheap; follows window/layout changes, iPad and wide phones)
		if not _drag:
			_spin = move_toward(_spin, 0.35, dt * 0.3)
		_yaw += _spin * dt
		car.rotation.y = _yaw
