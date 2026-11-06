class_name PowerLines
extends Node3D
## High-voltage lines in the hills round the bay: lattice pylons stride along
## the foothills behind Westbank and round the north shore, and a spur climbs
## to a pass in the western mountains. Pylons are one procedural lattice mesh
## (tapered legs, cross bracing, two cross-arms, insulator strings) drawn as a
## MultiMesh; the conductors sag between them as catenaries, all in one mesh.
## Backdrop only: no collision.

const PYLON_H := 48.0
const ARMS := [[36.0, 7.5], [43.0, 5.5]]    # [height, half span] of each cross-arm
const INSULATOR := 3.2
const STEEL := Color(0.58, 0.6, 0.62)

var pylons: Array = []   # [position, yaw] (also for tests)


## Pylon routes: points on the foothills (ellipse radius factor r, angle a).
static func routes() -> Array:
	var out: Array = []
	# Main line: along the hills from the south-west round to the north.
	var main: Array = []
	var a := deg_to_rad(215.0)
	while a > deg_to_rad(95.0):
		main.append(_on_hills(1.13 + 0.03 * sin(a * 7.0), a))
		a -= 0.135
	out.append(main)
	# Spur: from the main line up to a pass in the western mountains.
	var spur: Array = []
	var a2 := deg_to_rad(176.0)
	var r := 1.13
	while r < 1.95:
		spur.append(_on_hills(r, a2 + (r - 1.13) * 0.18))
		r += 0.085
	out.append(spur)
	return out


static func _on_hills(r: float, a: float) -> Vector3:
	var x := Hinterland.BAY_C.x + cos(a) * Hinterland.BAY_R.x * r
	var z := Hinterland.BAY_C.y + sin(a) * Hinterland.BAY_R.y * r
	return Vector3(x, Hinterland.height_at(x, z), z)


func _ready() -> void:
	var cable := PackedVector3Array()
	var cable_n := PackedVector3Array()
	for route: Array in routes():
		var pts: Array = route.filter(func(p): return p.y > 2.0)
		for i in pts.size():
			var p: Vector3 = pts[i]
			var prev: Vector3 = pts[maxi(i - 1, 0)]
			var nxt: Vector3 = pts[mini(i + 1, pts.size() - 1)]
			var d := Vector3(nxt.x - prev.x, 0.0, nxt.z - prev.z).normalized()
			pylons.append([p, atan2(d.x, d.z)])
		for i in pts.size() - 1:
			_span(pts[i], pts[i + 1], pylons[pylons.size() - pts.size() + i][1],
				pylons[pylons.size() - pts.size() + i + 1][1], cable, cable_n)
	# Pylons.
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = pylon_mesh()
	mm.instance_count = pylons.size()
	for i in pylons.size():
		mm.set_instance_transform(i, Transform3D(Basis(Vector3.UP, pylons[i][1]), pylons[i][0] - Vector3.UP * 1.0))
	var mmi := MultiMeshInstance3D.new()
	mmi.name = "Pylons"
	mmi.multimesh = mm
	var mat := StandardMaterial3D.new()
	mat.albedo_color = STEEL
	mat.metallic = 0.4
	mat.roughness = 0.5
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mmi.material_override = mat
	mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mmi)
	# Conductors.
	var arr := []
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = cable
	arr[Mesh.ARRAY_NORMAL] = cable_n
	var cm := ArrayMesh.new()
	cm.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
	var ci := MeshInstance3D.new()
	ci.name = "Conductors"
	ci.mesh = cm
	var cmat := StandardMaterial3D.new()
	cmat.albedo_color = Color(0.18, 0.18, 0.2)
	cmat.cull_mode = BaseMaterial3D.CULL_DISABLED
	cmat.roughness = 0.6
	ci.material_override = cmat
	ci.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(ci)


## Where a conductor hangs on a pylon at `p` facing `yaw` (arm k, side s).
static func _attach(p: Vector3, yaw: float, k: int, side: float) -> Vector3:
	var arm: Array = ARMS[k]
	var off := Vector3(side * float(arm[1]), float(arm[0]) - INSULATOR - 1.0, 0.0).rotated(Vector3.UP, yaw)
	return p + off


## Six conductors from pylon a to pylon b, each a sagging catenary of thin
## crossed ribbons (wide enough to stay a line at a kilometre).
func _span(a: Vector3, b: Vector3, ya: float, yb: float, out: PackedVector3Array, nrm: PackedVector3Array) -> void:
	var span := a.distance_to(b)
	var sag := span * 0.035
	var w := 0.22
	for k in ARMS.size():
		for side: float in [-1.0, 1.0]:
			var p0 := _attach(a, ya, k, side)
			var p1 := _attach(b, yb, k, side)
			var seg := 10
			var dir := (p1 - p0)
			var across := Vector3(dir.z, 0.0, -dir.x).normalized() * w
			for i in seg:
				var t0 := float(i) / seg
				var t1 := float(i + 1) / seg
				var q0 := p0.lerp(p1, t0) - Vector3.UP * sag * 4.0 * t0 * (1.0 - t0)
				var q1 := p0.lerp(p1, t1) - Vector3.UP * sag * 4.0 * t1 * (1.0 - t1)
				for o: Vector3 in [across, Vector3.UP * w]:
					out.append_array([q0 - o, q1 - o, q1 + o, q0 - o, q1 + o, q0 + o])
					var n := (q1 - q0).cross(o).normalized()
					nrm.append_array([n, n, n, n, n, n])


## A lattice pylon (local: up +Y, line along Z, arms along X).
static func pylon_mesh() -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var base := 4.2
	var top := 1.1
	var waist := 32.0
	var leg := func(h: float) -> float: return lerpf(base, top, pow(clampf(h / waist, 0.0, 1.0), 0.8)) if h <= waist else top
	var corners := [Vector2(1, 1), Vector2(-1, 1), Vector2(-1, -1), Vector2(1, -1)]
	var levels := [0.0, 6.0, 12.0, 18.0, 24.0, 30.0, 36.0, 43.0, PYLON_H]
	# Legs.
	for c: Vector2 in corners:
		for i in levels.size() - 1:
			var h0: float = levels[i]
			var h1: float = levels[i + 1]
			_bar(st, Vector3(c.x * leg.call(h0), h0, c.y * leg.call(h0)), Vector3(c.x * leg.call(h1), h1, c.y * leg.call(h1)), 0.22)
	# Bracing: an X on every face of every panel, and a ring at each level.
	for i in levels.size() - 1:
		var h0: float = levels[i]
		var h1: float = levels[i + 1]
		for k in 4:
			var c0: Vector2 = corners[k]
			var c1: Vector2 = corners[(k + 1) % 4]
			var a0 := Vector3(c0.x * leg.call(h0), h0, c0.y * leg.call(h0))
			var a1 := Vector3(c1.x * leg.call(h0), h0, c1.y * leg.call(h0))
			var b0 := Vector3(c0.x * leg.call(h1), h1, c0.y * leg.call(h1))
			var b1 := Vector3(c1.x * leg.call(h1), h1, c1.y * leg.call(h1))
			_bar(st, a0, b1, 0.1)
			_bar(st, a1, b0, 0.1)
			_bar(st, b0, b1, 0.12)
	# Cross-arms with insulator strings, and an earth-wire peak.
	for arm: Array in ARMS:
		var h: float = arm[0]
		var half: float = arm[1]
		var w: float = leg.call(h)
		for side: float in [-1.0, 1.0]:
			_bar(st, Vector3(side * w, h, w), Vector3(side * half, h, 0.0), 0.12)
			_bar(st, Vector3(side * w, h, -w), Vector3(side * half, h, 0.0), 0.12)
			_bar(st, Vector3(side * w, h - 2.0, 0.0), Vector3(side * half, h, 0.0), 0.1)
			_bar(st, Vector3(side * half, h, 0.0), Vector3(side * half, h - INSULATOR, 0.0), 0.16)
	_bar(st, Vector3(top, PYLON_H, top), Vector3(0.0, PYLON_H + 4.0, 0.0), 0.1)
	_bar(st, Vector3(-top, PYLON_H, -top), Vector3(0.0, PYLON_H + 4.0, 0.0), 0.1)
	st.generate_normals()
	return st.commit()


## A square bar from a to b (half width r).
static func _bar(st: SurfaceTool, a: Vector3, b: Vector3, r: float) -> void:
	var ax := (b - a).normalized()
	var u := ax.cross(Vector3.UP)
	if u.length() < 0.01:
		u = ax.cross(Vector3.RIGHT)
	u = u.normalized() * r
	var v := ax.cross(u).normalized() * r
	var ring := [u + v, -u + v, -u - v, u - v]
	for i in 4:
		var o0: Vector3 = ring[i]
		var o1: Vector3 = ring[(i + 1) % 4]
		st.add_vertex(a + o0)
		st.add_vertex(b + o1)
		st.add_vertex(b + o0)
		st.add_vertex(a + o0)
		st.add_vertex(a + o1)
		st.add_vertex(b + o1)
