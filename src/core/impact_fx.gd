class_name ImpactFx
extends Node
## Game-feel time effects: a wall knockout freezes for a beat (hit-stop),
## then plays the crumple in slow motion and eases back to full speed.
## Runs on real time (unaffected by its own time_scale) and always restores
## Engine.time_scale – also when the game is paused or the effect is cut.

const FREEZE := 0.07       # s at near-zero speed
const SLOW := 0.55         # s of slow motion after the freeze
const SLOW_SCALE := 0.3
const EASE := 0.45         # s back to full speed

var _t := -1.0
var _last_ms := 0


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS


func knockout(speed: float) -> void:
	# Harder hits hold the freeze a touch longer.
	_t = -clampf((speed - 17.0) / 40.0, 0.0, 1.0) * 0.05
	_last_ms = Time.get_ticks_msec()
	Engine.time_scale = 0.03


## A limp body slapping into the ground: a much shorter beat than a wall
## knockout (only for hard hits, and never over one already playing).
func slam(speed: float) -> void:
	if busy() or speed < 16.0:
		return
	_t = FREEZE + SLOW - 0.18 - clampf((speed - 16.0) / 30.0, 0.0, 1.0) * 0.12
	_last_ms = Time.get_ticks_msec()
	Engine.time_scale = SLOW_SCALE


## A puff of dust where something hit the ground (one-shot CPU particles,
## freed when done; CPU so it also runs on the web build).
static func dust(parent: Node, at: Vector3, strength: float) -> void:
	var p := CPUParticles3D.new()
	p.one_shot = true
	p.emitting = false
	p.amount = int(clampf(10.0 + strength, 12.0, 40.0))
	p.lifetime = 0.9
	p.explosiveness = 0.95
	p.emission_shape = CPUParticles3D.EMISSION_SHAPE_SPHERE
	p.emission_sphere_radius = 0.4
	p.direction = Vector3.UP
	p.spread = 80.0
	p.initial_velocity_min = 1.0
	p.initial_velocity_max = clampf(strength * 0.18, 2.0, 6.0)
	p.gravity = Vector3(0, -1.5, 0)
	p.damping_min = 2.5
	p.damping_max = 4.0
	p.scale_amount_min = 0.5
	p.scale_amount_max = 1.2
	var curve := Curve.new()
	curve.add_point(Vector2(0.0, 0.4))
	curve.add_point(Vector2(0.3, 1.0))
	curve.add_point(Vector2(1.0, 1.4))
	p.scale_amount_curve = curve
	var grad := Gradient.new()
	grad.set_color(0, Color(0.78, 0.74, 0.68, 0.55))
	grad.set_color(1, Color(0.78, 0.74, 0.68, 0.0))
	p.color_ramp = grad
	var mesh := QuadMesh.new()
	mesh.size = Vector2(0.7, 0.7)
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.vertex_color_use_as_albedo = true
	mat.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	mat.albedo_texture = _soft_dot()
	mesh.material = mat
	p.mesh = mesh
	parent.add_child(p)
	p.global_position = at + Vector3.UP * 0.2
	p.emitting = true
	p.finished.connect(p.queue_free)


static var _dot: Texture2D


static func _soft_dot() -> Texture2D:
	if _dot == null:
		var g := Gradient.new()
		g.set_color(0, Color(1, 1, 1, 1))
		g.set_color(1, Color(1, 1, 1, 0))
		var tex := GradientTexture2D.new()
		tex.gradient = g
		tex.fill = GradientTexture2D.FILL_RADIAL
		tex.fill_from = Vector2(0.5, 0.5)
		tex.fill_to = Vector2(1.0, 0.5)
		tex.width = 32
		tex.height = 32
		_dot = tex
	return _dot


func cancel() -> void:
	_t = -1.0
	Engine.time_scale = 1.0


## The knockout effect is driving time_scale right now.
func busy() -> bool:
	return _t > -1.0


func active() -> bool:
	return _t > -1.0 or Engine.time_scale < 1.0


func _process(_dt: float) -> void:
	if _t <= -1.0:
		return
	if get_tree().paused:
		cancel()
		return
	var now := Time.get_ticks_msec()
	_t += (now - _last_ms) / 1000.0
	_last_ms = now
	var t := _t - FREEZE
	if t < 0.0:
		Engine.time_scale = 0.03
	elif t < SLOW:
		Engine.time_scale = SLOW_SCALE
	elif t < SLOW + EASE:
		var k := (t - SLOW) / EASE
		Engine.time_scale = lerpf(SLOW_SCALE, 1.0, k * k * (3.0 - 2.0 * k))
	else:
		cancel()
