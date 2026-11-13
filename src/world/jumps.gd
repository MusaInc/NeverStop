class_name Jumps
extends Node3D
## Kicker ramps on long straights: the city's stunt spots. Placed where a
## lane runs straight for at least 70 m before and 110 m after (so the run-up
## is readable and the landing is road), never near a junction. Each is a
## wedge on the street collision layer (wheels ride it) with chevrons, one
## lane wide – take it or don't. Police drive the same road and sometimes
## launch off them too.

const LENGTH := 10.0
const HEIGHT := 1.7
const WIDTH := 4.6

var spots: Array = []     # [Transform3D]


func build(net: RoadNet, rng_seed := 77, count := 18) -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = rng_seed
	var mat := StandardMaterial3D.new()
	mat.albedo_texture = _chevrons()
	mat.roughness = 0.6
	mat.metallic = 0.2
	mat.uv1_scale = Vector3(1, 2, 1)
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	var side_mat := StandardMaterial3D.new()
	side_mat.albedo_color = Color(0.12, 0.12, 0.13)
	side_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	var tries := 0
	while spots.size() < count and tries < 4000:
		tries += 1
		var li := rng.randi() % net.lanes.size()
		# (Not up on the expressway: a kicker there throws cars over its barrier.)
		if net.lane_conn[li] == 1 or net.lane_len[li] < 220.0 or net.lane_speed[li] >= Expressway.SPEED - 0.1:
			continue
		var s := rng.randf_range(80.0, net.lane_len[li] - 120.0)
		var d := net.lane_dir(li, s)
		var ok := true
		for k in [-60.0, -30.0, 30.0, 60.0, 95.0]:
			if net.lane_dir(li, s + k).dot(d) < 0.98:
				ok = false
				break
			var h := net.lane_point(li, s + k).y - net.lane_point(li, s).y
			if absf(h) > 6.0:
				ok = false
				break
		if not ok:
			continue
		var p := net.lane_point(li, s)
		var clear := true
		for q in spots:
			if (q as Transform3D).origin.distance_to(p) < 170.0:
				clear = false
				break
		if not clear:
			continue
		var xf := Transform3D(Basis.looking_at(d, Vector3.UP), p)
		spots.append(xf)
		_ramp(xf, mat, side_mat)


func _ramp(xf: Transform3D, mat: Material, side_mat: Material) -> void:
	var body := StaticBody3D.new()
	body.collision_layer = 1 << 3
	body.collision_mask = 0
	var w := WIDTH * 0.5
	# Local: -Z is forward; the wedge rises from z=+LENGTH/2 to z=-LENGTH/2.
	var z0 := LENGTH * 0.5
	var z1 := -LENGTH * 0.5
	var pts := PackedVector3Array([Vector3(-w, -0.05, z0), Vector3(w, -0.05, z0), Vector3(-w, -0.05, z1),
		Vector3(w, -0.05, z1), Vector3(-w, HEIGHT, z1), Vector3(w, HEIGHT, z1)])
	var cs := CollisionShape3D.new()
	var hull := ConvexPolygonShape3D.new()
	hull.points = pts
	cs.shape = hull
	body.add_child(cs)
	# Mesh: the slope (chevrons), sides, back.
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var a := Vector3(-w, 0.02, z0)
	var b := Vector3(w, 0.02, z0)
	var c := Vector3(w, HEIGHT, z1)
	var dd := Vector3(-w, HEIGHT, z1)
	var n := (b - a).cross(dd - a).normalized()
	for v in [[a, Vector2(0, 1)], [b, Vector2(1, 1)], [c, Vector2(1, 0)], [a, Vector2(0, 1)], [c, Vector2(1, 0)], [dd, Vector2(0, 0)]]:
		st.set_normal(-n if n.y < 0 else n)
		st.set_uv(v[1])
		st.add_vertex(v[0])
	var mi := MeshInstance3D.new()
	mi.mesh = st.commit()
	mi.material_override = mat
	body.add_child(mi)
	var st2 := SurfaceTool.new()
	st2.begin(Mesh.PRIMITIVE_TRIANGLES)
	for sx in [-1.0, 1.0]:
		var p0 := Vector3(sx * w, 0.0, z0)
		var p1 := Vector3(sx * w, 0.0, z1)
		var p2 := Vector3(sx * w, HEIGHT, z1)
		for v in ([p0, p2, p1] if sx < 0 else [p0, p1, p2]):
			st2.add_vertex(v)
	for v in [Vector3(-w, 0, z1), Vector3(w, HEIGHT, z1), Vector3(-w, HEIGHT, z1), Vector3(-w, 0, z1), Vector3(w, 0, z1), Vector3(w, HEIGHT, z1)]:
		st2.add_vertex(v)
	st2.generate_normals()
	var mi2 := MeshInstance3D.new()
	mi2.mesh = st2.commit()
	mi2.material_override = side_mat
	body.add_child(mi2)
	add_child(body)
	body.global_transform = xf


## Height of a ramp's surface at p (world), or -INF off every ramp. For
## cars moved kinematically (civilians), so they ride up the wedge.
func height_at(p: Vector3) -> float:
	for xf: Transform3D in spots:
		if absf(xf.origin.x - p.x) > 8.0 or absf(xf.origin.z - p.z) > 8.0:
			continue
		var l := xf.affine_inverse() * p
		if absf(l.x) < WIDTH * 0.5 and l.z < LENGTH * 0.5 and l.z > -LENGTH * 0.5:
			var k := (LENGTH * 0.5 - l.z) / LENGTH
			return xf.origin.y + k * HEIGHT
	return -INF


static func _chevrons() -> ImageTexture:
	var img := Image.create(64, 64, false, Image.FORMAT_RGB8)
	for y in 64:
		for x in 64:
			var u := absf(x - 32) / 32.0
			var band := fposmod(y / 64.0 * 2.0 + u * 0.8, 1.0)
			var c := Color(0.95, 0.68, 0.08) if band < 0.5 else Color(0.08, 0.08, 0.09)
			img.set_pixel(x, y, c)
	return ImageTexture.create_from_image(img)
