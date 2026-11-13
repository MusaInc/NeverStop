class_name Minimap
extends Control
## Live minimap at the top centre of the HUD (replaces the old token banner).
##
##  * The map is the real city: one texture baked once at startup from the
##    layout data the world is built from (coasts, blocks, the road surface
##    between them, parks, plazas, set pieces, every building footprint shaded
##    by height, the bridge and its approach, the rail lines, the mainland).
##    Baked by a one-shot 2-D render (a SubViewport drawn once, then freed), so
##    there is no per-frame map work and no second 3-D view.
##  * Drawn as one textured quad through minimap.gdshader: a soft-edged disc
##    that rotates with the camera's heading (forward is up) and zooms out a
##    little with speed (smoothed, so it never pumps).
##  * Overlay: the hero's arrow at the centre, a north tick on the rim, and a
##    few objective markers picked by priority and distance (pinned to the rim
##    when off the map) – never dozens of icons.
## Objectives are supplied by the mode: `markers` = [[world pos, kind], ...]
## with kind "token", "ring", "next" (the next ring/goal), "job" / "crime"
## (contract offers) or "poi".

const BOUNDS := Rect2(-1180.0, -720.0, 2260.0, 1420.0)  # world x/z covered by the texture
const M_PER_PX := 1.5
const R_SLOW := 140.0    # m shown from the centre to the rim, slow
const R_FAST := 260.0    # ... flat out
const MAX_MARKERS := 24
const SHADER := preload("res://src/ui/shaders/minimap.gdshader")

var player: Node3D
var camera: Node3D
var markers: Array = []
var map_tex: Texture2D
var _radius := R_SLOW
var _yaw := 0.0
var _overlay: Control
var _mat: ShaderMaterial
var _font: Font = preload("res://assets/fonts/outfit_bold.ttf")


func _ready() -> void:
	mouse_filter = MOUSE_FILTER_IGNORE
	_mat = ShaderMaterial.new()
	_mat.shader = SHADER
	material = _mat
	_overlay = Control.new()
	_overlay.mouse_filter = MOUSE_FILTER_IGNORE
	_overlay.set_anchors_preset(PRESET_FULL_RECT)
	_overlay.draw.connect(_draw_overlay)
	add_child(_overlay)


## Bakes the map texture from the island layout (and its mainland). Awaitable;
## a no-op without a renderer (headless tests).
func bake(layout: CityLayout) -> void:
	var size_px := Vector2i(int(BOUNDS.size.x / M_PER_PX), int(BOUNDS.size.y / M_PER_PX))
	var vp := SubViewport.new()
	vp.size = size_px
	vp.transparent_bg = false
	vp.disable_3d = true
	vp.render_target_update_mode = SubViewport.UPDATE_ONCE
	var painter := MapPainter.new()
	painter.layouts = [layout] if layout.mainland == null else [layout.mainland, layout]
	painter.layout = layout
	vp.add_child(painter)
	add_child(vp)
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	var img := vp.get_texture().get_image() if vp.get_texture() else null
	vp.queue_free()
	if img == null or img.is_empty():
		return
	img.convert(Image.FORMAT_RGB8)  # (no alpha needed: ~6 MB with mipmaps)
	img.generate_mipmaps()
	map_tex = ImageTexture.create_from_image(img)
	_mat.set_shader_parameter("map", map_tex)
	_mat.set_shader_parameter("origin", BOUNDS.position)
	_mat.set_shader_parameter("extent", BOUNDS.size)
	queue_redraw()


## Map-space (metres right / forward of the centre) → control pixels.
func world_to_map(p: Vector3) -> Vector2:
	var c := player.global_position
	var f := Vector2(-sin(_yaw), -cos(_yaw))   # forward on the map (x, z)
	var r := Vector2(-f.y, f.x)                 # right
	var d := Vector2(p.x - c.x, p.z - c.z)
	var rad := size.x * 0.5
	return size * 0.5 + Vector2(d.dot(r), -d.dot(f)) / _radius * rad


func _process(dt: float) -> void:
	if player == null:
		return
	if camera:
		# Follows the camera (what the player sees), smoothed a touch more.
		_yaw = lerp_angle(_yaw, camera.view_yaw(), 1.0 - exp(-10.0 * dt))
	var spd: float = player.speed
	var want := lerpf(R_SLOW, R_FAST, smoothstep(10.0, 60.0, spd))
	# Zoom eases slowly (out faster than in) so it never pumps with each swing.
	_radius = lerpf(_radius, want, 1.0 - exp(-(0.9 if want > _radius else 0.4) * dt))
	var c := player.global_position
	_mat.set_shader_parameter("center", Vector2(c.x, c.z))
	_mat.set_shader_parameter("forward", Vector2(-sin(_yaw), -cos(_yaw)))
	_mat.set_shader_parameter("radius_m", _radius)
	_overlay.queue_redraw()


func _draw() -> void:
	# The disc itself (the shader samples the map from the hero's frame).
	if map_tex:
		draw_texture_rect(map_tex, Rect2(Vector2.ZERO, size), false)
	else:
		draw_circle(size * 0.5, size.x * 0.5, Color(0.08, 0.1, 0.13, 0.6))


func _draw_overlay() -> void:
	if player == null:
		return
	var ctr := size * 0.5
	var rad := size.x * 0.5
	var ov := _overlay
	# Objectives: nearest few, by priority; off-map ones pinned to the rim.
	var pc := player.global_position
	var list := markers.duplicate()
	list.sort_custom(func(a, b):
		var pa := _prio(a[1])
		var pb := _prio(b[1])
		if pa != pb:
			return pa > pb
		return pc.distance_squared_to(a[0]) < pc.distance_squared_to(b[0]))
	var shown := 0
	for m in list:
		if shown >= MAX_MARKERS:
			break
		var sp := world_to_map(m[0])
		var off := sp - ctr
		var edge := off.length() > rad - 9.0
		if edge:
			if m[1] != "roadblock" and m[1] != "heli" and m[1] != "repair_pin":
				continue  # only roadblocks, the helicopter and the nearest repair are pinned to the rim
			sp = ctr + off.normalized() * (rad - 9.0)
		_marker(ov, sp, String(m[1]), edge)
		shown += 1
	# North tick on the rim.
	var n := world_to_map(pc + Vector3(0, 0, -1000.0)) - ctr
	var np := ctr + n.normalized() * (rad - 1.0)
	ov.draw_circle(np, 8.5, Color(0.07, 0.08, 0.1, 0.85))
	if _font:
		var fs := 11
		var w := _font.get_string_size("N", HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
		ov.draw_string(_font, np + Vector2(-w * 0.5, 4.0), "N", HORIZONTAL_ALIGNMENT_LEFT, -1, fs, Color(1, 1, 1, 0.95))
	# The hero: a crisp arrowhead pointing forward (map up), on a soft halo.
	var s := clampf(rad / 70.0, 0.8, 1.3)
	ov.draw_circle(ctr, 9.0 * s, Color(1, 1, 1, 0.16))
	var pts := PackedVector2Array([ctr + Vector2(0, -8.5) * s, ctr + Vector2(6.0, 6.0) * s,
		ctr + Vector2(0, 3.0) * s, ctr + Vector2(-6.0, 6.0) * s])
	ov.draw_colored_polygon(pts, UiStyle.GOLD)
	ov.draw_polyline(pts + PackedVector2Array([pts[0]]), Color(0.05, 0.05, 0.06, 0.9), 1.5, true)


static func _prio(kind: String) -> int:
	return {"repair_pin": 5, "repair": 3, "cash": 2, "roadblock": 4, "heli": 3, "heavy": 2, "patrol": 2, "interceptor": 2, "wreck": 0}.get(kind, 1)


func _marker(ov: Control, p: Vector2, kind: String, pinned: bool) -> void:
	var t := Time.get_ticks_msec() / 1000.0
	match kind:
		"roadblock":
			ov.draw_rect(Rect2(p + Vector2(-8, -3.5), Vector2(16, 7)), Color(0.05, 0.05, 0.06, 0.9))
			for i in 4:
				ov.draw_rect(Rect2(p + Vector2(-7 + i * 3.6, -2.5), Vector2(1.8, 5)), UiStyle.RED if i % 2 == 0 else UiStyle.WHITE)
		"heli":
			ov.draw_circle(p, 6.5, Color(0.05, 0.05, 0.06, 0.8))
			ov.draw_arc(p, 5.0, t * 9.0, t * 9.0 + PI * 0.7, 8, UiStyle.WHITE, 1.6, true)
			ov.draw_arc(p, 5.0, t * 9.0 + PI, t * 9.0 + PI * 1.7, 8, UiStyle.WHITE, 1.6, true)
		"wreck":
			ov.draw_circle(p, 2.6, Color(0.6, 0.6, 0.62, 0.7))
		"rival":
			ov.draw_circle(p, 5.0, Color(0.03, 0.03, 0.04, 0.85))
			ov.draw_circle(p, 3.6, UiStyle.AMBER.lerp(UiStyle.RED, 0.5))
		"enroute":
			# Backup on its way (not on the streets near you yet).
			ov.draw_arc(p, 3.4, 0.0, TAU, 14, Color(UiStyle.RED, 0.7), 1.4, true)
		"repair", "repair_pin":
			# A green plus on a dark disc (pulsing when it's the nearest).
			var pr := 7.0 + (1.0 + sin(t * 5.0)) * (1.0 if kind == "repair_pin" else 0.0)
			ov.draw_circle(p, pr, Color(0.03, 0.06, 0.04, 0.85))
			ov.draw_rect(Rect2(p + Vector2(-4.5, -1.5), Vector2(9, 3)), UiStyle.GREEN)
			ov.draw_rect(Rect2(p + Vector2(-1.5, -4.5), Vector2(3, 9)), UiStyle.GREEN)
		"cash":
			# A gold coin with a dark edge.
			ov.draw_circle(p, 5.6, Color(0.08, 0.06, 0.02, 0.85))
			ov.draw_circle(p, 4.2, RepairPickups.GOLD)
			ov.draw_rect(Rect2(p + Vector2(-0.8, -2.6), Vector2(1.6, 5.2)), Color(0.45, 0.3, 0.05))
		_:
			# Police: a dot flashing red/blue; heavy units bigger.
			var r := 4.6 if kind == "heavy" else 3.6
			var col := UiStyle.RED if fmod(t * 2.6, 1.0) < 0.5 else UiStyle.BLUE
			ov.draw_circle(p, r + 1.5, Color(0.03, 0.03, 0.04, 0.85))
			ov.draw_circle(p, r, col)
	if pinned:
		ov.draw_arc(p, 9.0, 0.0, TAU, 20, Color(1, 1, 1, 0.35), 1.0, true)


## Draws the whole world once into the bake viewport (1 px = M_PER_PX m).
class MapPainter:
	extends Node2D
	var layouts: Array = []
	var layout: CityLayout

	const WATER := Color(0.13, 0.22, 0.3)
	const SHORE := Color(0.62, 0.6, 0.53)
	const ROAD := Color(0.24, 0.25, 0.28)
	const BLOCK := Color(0.42, 0.43, 0.45)
	const PLAZA := Color(0.56, 0.55, 0.52)
	const PARK := Color(0.27, 0.43, 0.27)
	const PIECE := Color(0.45, 0.42, 0.38)
	const BRIDGE := Color(0.72, 0.3, 0.24)
	const RAIL := Color(0.15, 0.15, 0.17)

	func _px(v: Vector2) -> Vector2:
		return (v - Minimap.BOUNDS.position) / Minimap.M_PER_PX

	func _poly(pts: PackedVector2Array, col: Color) -> void:
		if pts.size() < 3:
			return
		var out := PackedVector2Array()
		for v in pts:
			out.append(_px(v))
		# Concave polygons: triangulate (draw_colored_polygon needs a valid one).
		var tri := Geometry2D.triangulate_polygon(out)
		if tri.is_empty():
			return
		var cols := PackedColorArray()
		cols.resize(out.size())
		cols.fill(col)
		RenderingServer.canvas_item_add_triangle_array(get_canvas_item(), tri, out, cols)

	func _line(pts: PackedVector2Array, w_m: float, col: Color) -> void:
		var out := PackedVector2Array()
		for v in pts:
			out.append(_px(v))
		if out.size() >= 2:
			draw_polyline(out, col, maxf(w_m / Minimap.M_PER_PX, 1.0), true)

	func _draw() -> void:
		draw_rect(Rect2(Vector2.ZERO, Minimap.BOUNDS.size / Minimap.M_PER_PX), WATER)
		for L: CityLayout in layouts:
			if L.coast.size() >= 3:
				_poly(L.coast, SHORE)  # esplanade / quay edge
				var inner := Geometry2D.offset_polygon(L.coast, -CityRoads.ESPLANADE)
				if not inner.is_empty():
					_poly(inner[0], ROAD)   # the street surface between blocks
			for b in L.blocks:
				var kind: String = b.get("kind", "block")
				var col := BLOCK
				match kind:
					"park", "green":
						col = PARK
					"plaza":
						col = PLAZA
					"piece":
						col = PIECE
					"basin":
						col = WATER
					"esplanade":
						continue
				_poly(b["poly"], col)
			# Buildings: footprints of the lowest tier, lighter the taller.
			for b in L.buildings:
				var kd: String = b.get("kind", "normal")
				if kd == "invisible" or kd == "structure":
					continue
				var tiers: Array = b["tiers"]
				if tiers.is_empty():
					continue
				var t: Array = tiers[0]
				var top := float(tiers[-1][5]) - float(t[4])
				var k := clampf(top / 220.0, 0.0, 1.0)
				var col := Color(0.6, 0.6, 0.62).lerp(Color(0.9, 0.88, 0.84), k)
				if kd == "landmark":
					col = Color(0.92, 0.82, 0.6)
				var rot: float = b.get("rot", 0.0)
				var pv: Vector2 = b.get("pivot", Vector2.ZERO)
				var quad := PackedVector2Array()
				# (shaped towers: their real plan – round, chamfered, notched)
				var pts: Array = Array(BuildingMesher.footprint(b, t)) if BuildingMesher.shaped(b) else \
					[Vector2(t[0], t[1]), Vector2(t[2], t[1]), Vector2(t[2], t[3]), Vector2(t[0], t[3])]
				for c in pts:
					quad.append(c if rot == 0.0 else CityLayout.to_world2(c, rot, pv))
				_poly(quad, col)
			if L.rail:
				for ln in L.rail.lines:
					var p2 := PackedVector2Array()
					for v: Vector3 in (ln["pts"] as PackedVector3Array):
						p2.append(Vector2(v.x, v.z))
					_line(p2, 3.0, RAIL)
			if L.expressway:
				_line(L.expressway.line, 13.0, Color(0.1, 0.1, 0.11))
				_line(L.expressway.line, 9.0, Color(0.95, 0.72, 0.3))
		# The suspension bridge and its approach onto Westbank.
		var z := CityLayout.BRIDGE_Z
		_line(PackedVector2Array([Vector2(56.0, z), Vector2(CityLayout.APPROACH_END, z)]), 20.0, BRIDGE.darkened(0.2))
		_line(PackedVector2Array([Vector2(56.0, z), Vector2(CityLayout.APPROACH_END, z)]), 12.0, BRIDGE)
		for tx: float in CityLayout.BRIDGE_TOWERS:
			draw_circle(_px(Vector2(tx, z)), 14.0 / Minimap.M_PER_PX, Color(0.95, 0.45, 0.35))
