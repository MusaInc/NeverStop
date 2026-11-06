class_name RainFx
extends MultiMeshInstance3D
## Rain round the camera: a fixed set of streak quads that wrap inside a box
## centred on the camera, all animated in the vertex shader (no CPU work per
## drop, no particles – works the same on the web build). Hidden when dry.

const BOX := Vector3(46.0, 30.0, 46.0)

var _mat: ShaderMaterial


func _ready() -> void:
	var count := 1400
	var settings := get_node_or_null("/root/Settings")
	if settings:
		count = [600, 1100, 1800][clampi(settings.quality, 0, 2)]
	var quad := QuadMesh.new()
	quad.size = Vector2(0.018, 0.85)
	_mat = ShaderMaterial.new()
	_mat.shader = load("res://src/world/shaders/rain.gdshader")
	_mat.set_shader_parameter("box", BOX)
	quad.material = _mat
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = quad
	mm.instance_count = count
	var rng := RandomNumberGenerator.new()
	rng.seed = 4242
	for i in count:
		mm.set_instance_transform(i, Transform3D(Basis(), Vector3(rng.randf() * BOX.x, rng.randf() * BOX.y, rng.randf() * BOX.z)))
	multimesh = mm
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	custom_aabb = AABB(Vector3(-1e5, -1e4, -1e5), Vector3(2e5, 2e4, 2e5))  # (placed by the shader)
	visible = false


func set_rain(amount: float, sky_lin: Color, lamps: float) -> void:
	visible = amount > 0.02
	if not visible:
		return
	_mat.set_shader_parameter("amount", amount)
	# Drops catch the sky by day and the street lamps' orange at night.
	var c := Color(sky_lin.r, sky_lin.g, sky_lin.b).lerp(Color(1.0, 0.75, 0.45), lamps * 0.35)
	_mat.set_shader_parameter("tint", Vector3(c.r, c.g, c.b) * 1.3 + Vector3.ONE * 0.08)
