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
	var ring := MeshInstance3D.new()
	var tm := TorusMesh.new()
	tm.inner_radius = 4.15
	tm.outer_radius = 4.3
	ring.mesh = tm
	var rm := StandardMaterial3D.new()
	rm.albedo_color = UiStyle.AMBER
	rm.emission_enabled = true
	rm.emission = UiStyle.AMBER
	rm.emission_energy_multiplier = 1.5
	ring.material_override = rm
	ring.scale = Vector3(1, 0.2, 1)
	stage.add_child(ring)
	cam = Camera3D.new()
	cam.fov = 34.0
	stage.add_child(cam)
	cam.position = Vector3(1.2, 1.6, 9.0)
	cam.look_at(Vector3(1.2, 0.55, 0), Vector3.UP)
	cam.position.x -= 2.2  # car sits right of centre (the stats are on the left)
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
	car.rotation.y = _yaw


func _gui_input(ev: InputEvent) -> void:
	if ev is InputEventMouseButton:
		_drag = (ev as InputEventMouseButton).pressed
	elif ev is InputEventMouseMotion and _drag:
		_yaw += (ev as InputEventMouseMotion).relative.x * 0.01
		_spin = 0.0


func _process(dt: float) -> void:
	if car:
		if not _drag:
			_spin = move_toward(_spin, 0.35, dt * 0.3)
		_yaw += _spin * dt
		car.rotation.y = _yaw
