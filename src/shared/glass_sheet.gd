class_name GlassSheet
extends Panel
## A floating glass sheet for menus (Musa shared foundation, from
## WorldState's Glass design system): whatever is behind it – the live game
## or the title cinematic – blurred and slightly more saturated under a
## tint, with rounded corners and a hairline rim. Purely decorative: put it
## behind a menu column and keep `follow` pointed at that column.
##
## Source of truth: WorldState src/shared/glass_sheet.gd (tools/shared/sync.py).

const SHADER := preload("res://src/shared/glass_sheet.gdshader")

var follow: Control           # the content it sits behind
var pad := Vector4(28, 22, 28, 22)   # left, top, right, bottom (px)
var radius := 30


func _init(p_follow: Control = null, tint := Color(0.06, 0.06, 0.09, 0.5), blur := 3.4) -> void:
	follow = p_follow
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color.WHITE        # alpha = coverage for the shader
	sb.set_corner_radius_all(radius)
	sb.anti_aliasing = true
	sb.border_color = Color.WHITE
	add_theme_stylebox_override("panel", sb)
	var m := ShaderMaterial.new()
	m.shader = SHADER
	m.set_shader_parameter("tint", tint)
	m.set_shader_parameter("blur", blur)
	material = m


func _process(_dt: float) -> void:
	if follow == null or not is_instance_valid(follow):
		return
	visible = follow.is_visible_in_tree()
	var r := follow.get_global_rect()
	global_position = r.position - Vector2(pad.x, pad.y)
	size = r.size + Vector2(pad.x + pad.z, pad.y + pad.w)
