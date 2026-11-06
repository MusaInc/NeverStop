class_name SpeedFx
extends ColorRect
## Speed streaks: faint radial lines at the screen edges above ~150 km/h and
## with nitro – the "motion blur" read without a costly blur pass. Off with
## Reduce Motion.

var player: Car
var _amount := 0.0
const SHADER := preload("res://src/fx/speed_lines.gdshader")


func _ready() -> void:
	set_anchors_preset(PRESET_FULL_RECT)
	mouse_filter = MOUSE_FILTER_IGNORE
	var m := ShaderMaterial.new()
	m.shader = SHADER
	material = m
	color = Color(1, 1, 1, 0)


func _process(dt: float) -> void:
	if player == null or Settings.reduce_motion:
		visible = false
		return
	var want := smoothstep(40.0, 70.0, player.speed)
	if player.nitro and player.nitro_amount > 0.0:
		want = maxf(want, 0.8)
	_amount = lerpf(_amount, want, 1.0 - exp(-4.0 * dt))
	visible = _amount > 0.02
	(material as ShaderMaterial).set_shader_parameter("amount", _amount)
