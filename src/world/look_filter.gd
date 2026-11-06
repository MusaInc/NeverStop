class_name LookFilter
extends MeshInstance3D
## Full-screen stylisation quad parented to the game camera (see look.gdshader).
## Settings.look picks the style; "clean" hides the quad so it costs nothing.

const STYLES := {
	"clean": 0,
	"comic": 1,
	"toon": 2,
	"painted": 3,
	"debug_pass": 8,
	"debug_edges": 9,
}
## Per-style shader parameters on top of the shader defaults.
const TUNING := {
	# Clean comic: crisp ink and flat cel tones, no halftone grain, gentle grade.
	"comic": {"line_px": 1.15, "bands": 3.0, "band_soft": 0.1, "saturation": 1.3, "halftone": 0.0,
		"color_edge": 0.38, "exposure": 1.06, "lift": 0.015, "split_tone": 0.22, "vignette": 0.12,
		"shadow_tint": Color(0.7, 0.62, 0.84)},
	"toon": {"line_px": 1.0, "bands": 4.0, "band_soft": 0.12, "saturation": 1.5, "halftone": 0.0,
		"color_edge": 0.4, "exposure": 1.12, "lift": 0.04, "split_tone": 0.35,
		"shadow_tint": Color(0.66, 0.5, 0.86), "vignette": 0.18},
	"painted": {"line_px": 0.9, "saturation": 1.3, "halftone": 0.0, "color_edge": 0.45,
		"depth_edge": 0.09, "exposure": 1.06, "split_tone": 0.4, "haze_amount": 0.5, "vignette": 0.3},
}

var mat: ShaderMaterial
var _speed := 0.0


func _ready() -> void:
	var quad := QuadMesh.new()
	quad.size = Vector2(2.0, 2.0)
	mesh = quad
	mat = ShaderMaterial.new()
	mat.shader = load("res://src/world/shaders/look.gdshader")
	mat.render_priority = 100  # after other transparent surfaces, before the web (127)
	material_override = mat
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	extra_cull_margin = 16384.0  # the vertex shader ignores the transform
	ignore_occlusion_culling = true
	var settings := get_node_or_null("/root/Settings")
	if settings:
		settings.changed.connect(func(): set_style(settings.look))
		set_style(settings.look)


func set_style(look: String) -> void:
	var id: int = STYLES.get(look, 0)
	# The web build's Compatibility renderer hands back an empty screen/depth
	# copy here (the whole frame washes out white), so it stays clean there.
	if RenderingServer.get_current_rendering_method() == "gl_compatibility":
		id = 0
	visible = id != 0
	if id == 0:
		return
	var defaults := mat.shader.get_shader_uniform_list()
	for u in defaults:
		mat.set_shader_parameter(u["name"], null)  # back to shader default
	mat.set_shader_parameter("style", id)
	var t: Dictionary = TUNING.get(look, {})
	for k in t:
		mat.set_shader_parameter(k, t[k])


## 0..1 how fast the hero is going (speed lines); smoothed here.
func set_speed(amount: float, dt: float) -> void:
	_speed = lerpf(_speed, clampf(amount, 0.0, 1.0), 1.0 - exp(-4.0 * dt))
	if visible:
		mat.set_shader_parameter("speed", _speed)
