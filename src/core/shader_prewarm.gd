class_name ShaderPrewarm
extends Node3D
## Compiles the shaders of things that first appear mid-play (rain, sirens,
## headlight beams, sparks / smoke / debris, repair beacons, ad screens…)
## while the loading screen still covers the view. On a fresh install every
## shader is compiled the first time it is drawn – 50–300 ms each on a phone,
## the kind of stall that got CitySwing's first build rejected. Each one is
## drawn once on a tiny quad just in front of the lens, then the node frees
## itself and emits `done`. Later launches hit the shader cache.
## (Ported from CitySwing's src/core/shader_prewarm.gd.)

signal done

const SHADERS := [
	"res://src/vehicle/beacon.gdshader",
	"res://src/vehicle/car_glass.gdshader",
	"res://src/vehicle/lamp_flare.gdshader",
	"res://src/vehicle/car_paint.gdshader",
	"res://src/fx/particle.gdshader",
	"res://src/world/shaders/ad_glow.gdshader",
	"res://src/world/shaders/ad_screen.gdshader",
	"res://src/world/shaders/beacon.gdshader",
	"res://src/world/shaders/birds.gdshader",
	"res://src/world/shaders/rain.gdshader",
	"res://src/world/shaders/lamp_glow.gdshader",
	"res://src/world/shaders/pedestrian.gdshader",
	"res://src/world/shaders/traffic.gdshader",
	"res://src/world/shaders/traffic_path.gdshader",
	"res://src/world/shaders/water.gdshader",
]
const FRAMES := 3

var cam: Camera3D
var _left := FRAMES


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	if cam == null:
		_finish.call_deferred()
		return
	var quad := QuadMesh.new()
	quad.size = Vector2(0.02, 0.02)
	var i := 0
	for path in SHADERS:
		var sh := load(path) as Shader
		if sh == null or sh.get_mode() != Shader.MODE_SPATIAL:
			continue
		var mat := ShaderMaterial.new()
		mat.shader = sh
		_add_quad(quad, mat, i)
		i += 1
	# StandardMaterial3D variants the game creates later (thrown furniture,
	# panels, jump ramps, battle kit, arena rims): unshaded+alpha, emissive,
	# alpha, vertex colour.
	var variants: Array[StandardMaterial3D] = []
	var a := StandardMaterial3D.new()
	a.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	a.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	a.cull_mode = BaseMaterial3D.CULL_DISABLED
	variants.append(a)
	var e := StandardMaterial3D.new()
	e.emission_enabled = true
	e.emission = Color(1, 0.8, 0.3)
	variants.append(e)
	var t := StandardMaterial3D.new()
	t.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	t.albedo_color = Color(1, 1, 1, 0.5)
	variants.append(t)
	var u := StandardMaterial3D.new()
	u.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	u.vertex_color_use_as_albedo = true
	variants.append(u)
	for m in variants:
		_add_quad(quad, m, i)
		i += 1


func _add_quad(quad: QuadMesh, mat: Material, i: int) -> void:
	var mi := MeshInstance3D.new()
	mi.mesh = quad
	mi.material_override = mat
	mi.extra_cull_margin = 4.0
	mi.ignore_occlusion_culling = true
	add_child(mi)
	# A small grid 1 m in front of the lens: inside the frustum, under the
	# loading screen, and casting shadows so the shadow variant compiles too.
	mi.position = Vector3((i % 6 - 2.5) * 0.03, (i / 6 - 1.5) * 0.03, -1.0)


func _process(_dt: float) -> void:
	if cam and is_instance_valid(cam):
		global_transform = cam.global_transform
	_left -= 1
	if _left <= 0:
		_finish()


func _finish() -> void:
	set_process(false)
	done.emit()
	queue_free()
