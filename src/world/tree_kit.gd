class_name TreeKit
## Procedural street/park trees: six species, each its own silhouette, built
## once at start-up (a few hundred triangles each) and drawn by MultiMesh
## with tree.gdshader. Per tree: height/width/lean from its position and a
## leaf tint in INSTANCE_CUSTOM, so no two read the same.
##   plane   London plane: broad, lumpy crown on a mottled trunk
##   lime    lime/linden: tall oval crown
##   birch   white trunk with dark marks, airy small clumps, yellow-green
##   pine    stone/Scots pine: stacked jagged cones
##   cherry  flowering cherry: low wide crown, pink or white blossom
##   poplar  Lombardy poplar: a tall narrow column
## A street is planted mostly with one species (pick()), as real avenues are.

const SPECIES := ["plane", "lime", "birch", "pine", "cherry", "poplar"]
static var _meshes := {}
static var _mat: ShaderMaterial
static var _ico: PackedVector3Array   # unit sphere, subdivided icosahedron (triangle list)


## Near LOD: the Blender-grown tree (tools/blender/ws_trees.py, assets/models/
## tree_<species>.glb: trunk, three orders of branches, ~120 leaf clumps),
## drawn within CityWorld.TREE_NEAR; the procedural tree below is the mid/far
## LOD. null when the model is missing.
static var _near := {}


static func near_mesh(sp: String) -> Mesh:
	if not _near.has(sp):
		var path := "res://assets/models/tree_%s.glb" % sp
		var m: Mesh = null
		if ResourceLoader.exists(path):
			var n := (load(path) as PackedScene).instantiate()
			var mis := n.find_children("*", "MeshInstance3D", true, false)
			if mis.size() > 0:
				m = ((mis[0] as MeshInstance3D).mesh as Mesh).duplicate()
				for i in m.get_surface_count():
					m.surface_set_material(i, material())
			n.free()
		_near[sp] = m
	return _near[sp]


static func mesh(sp: String) -> ArrayMesh:
	if not _meshes.has(sp):
		_meshes[sp] = _build(sp)
	return _meshes[sp]


static func material() -> ShaderMaterial:
	if _mat == null:
		_mat = ShaderMaterial.new()
		_mat.shader = load("res://src/world/shaders/tree.gdshader")
	return _mat


static func _h(p: Vector3, salt: int) -> float:
	return float(hash(Vector3i(int(floorf(p.x * 2.0)), int(floorf(p.z * 2.0)), salt)) % 10007) / 10007.0


## The species at `p`: the street's (≈ 50 m patch) main species 72% of the
## time, its second 22%, anything 6%. Parks (`park`) mix more freely.
static func pick(p: Vector3, park := false) -> String:
	var cell := Vector3(floorf(p.x / 55.0), 0.0, floorf(p.z / 55.0))
	var main := int(_h(cell * 0.5, 11) * 5.0)            # (poplar only as a second/odd one)
	var second := int(_h(cell * 0.5, 23) * 6.0)
	var r := _h(p, 5)
	if park:
		return SPECIES[int(_h(p, 31) * 6.0) % 6] if r < 0.55 else SPECIES[main]
	if r < 0.72:
		return SPECIES[main]
	if r < 0.94:
		return SPECIES[second]
	return SPECIES[int(_h(p, 41) * 6.0) % 6]


## This tree's shape: [scale (x, y, z), lean basis] from its position.
static func shape(p: Vector3, base_scale: float) -> Basis:
	var hy := lerpf(0.82, 1.22, _h(p, 7))
	var wx := lerpf(0.85, 1.15, _h(p, 9))
	var wz := lerpf(0.85, 1.15, _h(p, 13))
	var lean := Basis(Vector3(_h(p, 17) - 0.5, 0.0, _h(p, 19) - 0.5).normalized() if _h(p, 21) > 0.02 else Vector3.RIGHT,
		(_h(p, 23) - 0.5) * 0.08)
	return Basis(Vector3.UP, _h(p, 29) * TAU) * lean * Basis().scaled(Vector3(wx, hy, wz) * base_scale)


## Leaf tint (multiplies the species' colours): hue and brightness drift.
static func tint(p: Vector3, sp: String) -> Color:
	var a := _h(p, 3)
	var b := _h(p, 37)
	var c := Color(lerpf(0.86, 1.12, a), lerpf(0.9, 1.08, b), lerpf(0.85, 1.05, 1.0 - a))
	if sp == "cherry":
		# Some cherries are white-blossomed, most pink.
		return Color(1.0, 1.0, 1.0, 1.0) if b > 0.35 else Color(1.18, 1.25, 1.22, 1.0)
	return c


# ------------------------------------------------------------------ meshes
static func _lin(c: Color) -> Color:
	return c.srgb_to_linear()


static func _unit_sphere() -> PackedVector3Array:
	if not _ico.is_empty():
		return _ico
	var t := (1.0 + sqrt(5.0)) * 0.5
	var v := [Vector3(-1, t, 0), Vector3(1, t, 0), Vector3(-1, -t, 0), Vector3(1, -t, 0), Vector3(0, -1, t), Vector3(0, 1, t),
		Vector3(0, -1, -t), Vector3(0, 1, -t), Vector3(t, 0, -1), Vector3(t, 0, 1), Vector3(-t, 0, -1), Vector3(-t, 0, 1)]
	var f := [[0, 11, 5], [0, 5, 1], [0, 1, 7], [0, 7, 10], [0, 10, 11], [1, 5, 9], [5, 11, 4], [11, 10, 2], [10, 7, 6], [7, 1, 8],
		[3, 9, 4], [3, 4, 2], [3, 2, 6], [3, 6, 8], [3, 8, 9], [4, 9, 5], [2, 4, 11], [6, 2, 10], [8, 6, 7], [9, 8, 1]]
	var out := PackedVector3Array()
	for tri in f:
		var a: Vector3 = (v[tri[0]] as Vector3).normalized()
		var b: Vector3 = (v[tri[1]] as Vector3).normalized()
		var c: Vector3 = (v[tri[2]] as Vector3).normalized()
		var ab := ((a + b) * 0.5).normalized()
		var bc := ((b + c) * 0.5).normalized()
		var ca := ((c + a) * 0.5).normalized()
		# (Godot fronts are clockwise seen from outside.)
		for q in [[a, ca, ab], [b, ab, bc], [c, bc, ca], [ab, ca, bc]]:
			out.append_array(PackedVector3Array([q[0], q[2], q[1]]))
	_ico = out
	return out


## A lumpy leaf clump: a sphere pushed in and out by direction-noise, with
## soft normals and colour darker underneath and inside (vertex alpha 1 =
## foliage, which the shader sways and tints).
static func _blob(st: SurfaceTool, c: Vector3, r: Vector3, seed: float, top: Color, bot: Color, lump := 0.22) -> void:
	for u in _unit_sphere():
		var n := sin(u.x * 5.1 + seed) * sin(u.y * 4.3 + seed * 1.7) * sin(u.z * 5.7 + seed * 2.3)
		var k := 1.0 + lump * n + 0.08 * sin(u.x * 11.0 + u.z * 9.0 + seed * 3.0)
		var p := c + u * r * k
		var shade := clampf(0.5 + 0.5 * u.y, 0.0, 1.0)
		var col := bot.lerp(top, shade) * (0.88 + 0.12 * k)
		col.a = 1.0
		st.set_color(col)
		st.set_normal((u + Vector3.UP * 0.35).normalized())
		st.add_vertex(p)


## A tapered cylinder (trunk / branch), vertex alpha 0.
static func _cyl(st: SurfaceTool, a: Vector3, b: Vector3, r0: float, r1: float, col: Color, sides := 6, bands := false) -> void:
	var ax := (b - a).normalized()
	var side := ax.cross(Vector3.FORWARD if absf(ax.dot(Vector3.FORWARD)) < 0.9 else Vector3.RIGHT).normalized()
	var up := ax.cross(side)
	for i in sides:
		var a0 := TAU * i / sides
		var a1 := TAU * (i + 1) / sides
		var d0 := side * cos(a0) + up * sin(a0)
		var d1 := side * cos(a1) + up * sin(a1)
		var quad := [[a + d0 * r0, d0, 0.0], [a + d1 * r0, d1, 0.0], [b + d1 * r1, d1, 1.0], [b + d0 * r1, d0, 1.0]]
		for idx in [0, 2, 1, 0, 3, 2]:
			var q: Array = quad[idx]
			var cc := col
			if bands:
				# Birch: dark lenticel marks in bands up the white bark.
				var y := (q[0] as Vector3).y
				if fmod(y * 3.1 + float(i) * 0.37, 1.0) < 0.18:
					cc = col * 0.35
			cc.a = 0.0
			st.set_color(cc)
			st.set_normal(q[1])
			st.add_vertex(q[0])


static func _build(sp: String) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var bark := _lin(Color(0.33, 0.27, 0.21))
	match sp:
		"plane":
			var g_top := _lin(Color(0.42, 0.58, 0.24))
			var g_bot := _lin(Color(0.16, 0.26, 0.11))
			_cyl(st, Vector3.ZERO, Vector3(0, 3.4, 0), 0.24, 0.17, _lin(Color(0.55, 0.52, 0.42)))
			_cyl(st, Vector3(0, 2.9, 0), Vector3(1.4, 4.6, 0.3), 0.12, 0.06, bark)
			_cyl(st, Vector3(0, 3.1, 0), Vector3(-1.2, 4.9, -0.5), 0.12, 0.06, bark)
			for b in [[Vector3(0, 6.0, 0), Vector3(2.6, 2.1, 2.6)], [Vector3(1.7, 5.2, 0.5), Vector3(1.8, 1.5, 1.7)],
					[Vector3(-1.6, 5.5, -0.6), Vector3(1.9, 1.6, 1.8)], [Vector3(0.3, 5.0, 1.8), Vector3(1.6, 1.4, 1.5)],
					[Vector3(-0.4, 7.4, -0.3), Vector3(1.7, 1.3, 1.7)], [Vector3(0.6, 4.8, -1.7), Vector3(1.5, 1.3, 1.4)]]:
				_blob(st, b[0], b[1], (b[0] as Vector3).x * 3.0 + 1.0, g_top, g_bot)
		"lime":
			var g_top := _lin(Color(0.46, 0.62, 0.26))
			var g_bot := _lin(Color(0.18, 0.3, 0.12))
			_cyl(st, Vector3.ZERO, Vector3(0, 3.0, 0), 0.22, 0.16, bark)
			for b in [[Vector3(0, 5.2, 0), Vector3(2.0, 2.6, 2.0)], [Vector3(0.2, 7.6, 0.1), Vector3(1.5, 1.9, 1.5)],
					[Vector3(-0.8, 4.2, 0.4), Vector3(1.4, 1.2, 1.3)], [Vector3(0.9, 4.5, -0.5), Vector3(1.3, 1.2, 1.3)]]:
				_blob(st, b[0], b[1], (b[0] as Vector3).y * 1.7, g_top, g_bot, 0.16)
		"birch":
			var g_top := _lin(Color(0.62, 0.7, 0.3))
			var g_bot := _lin(Color(0.3, 0.4, 0.16))
			var white := _lin(Color(0.86, 0.85, 0.8))
			_cyl(st, Vector3.ZERO, Vector3(0.15, 7.6, 0.05), 0.15, 0.06, white, 6, true)
			_cyl(st, Vector3(0.05, 3.6, 0), Vector3(1.1, 5.4, 0.3), 0.06, 0.03, white)
			_cyl(st, Vector3(0.1, 4.4, 0), Vector3(-0.9, 6.0, -0.4), 0.05, 0.03, white)
			for b in [[Vector3(1.1, 5.6, 0.3), Vector3(0.9, 1.1, 0.9)], [Vector3(-0.9, 6.2, -0.4), Vector3(0.9, 1.0, 0.8)],
					[Vector3(0.2, 7.4, 0.0), Vector3(0.9, 1.3, 0.9)], [Vector3(0.6, 4.6, -0.7), Vector3(0.8, 0.9, 0.8)],
					[Vector3(-0.5, 4.9, 0.8), Vector3(0.8, 0.9, 0.8)], [Vector3(0.1, 8.5, 0.1), Vector3(0.5, 0.8, 0.5)]]:
				_blob(st, b[0], b[1], (b[0] as Vector3).z * 5.0 + 2.0, g_top, g_bot, 0.3)
		"pine":
			var g_top := _lin(Color(0.34, 0.5, 0.3))
			var g_bot := _lin(Color(0.14, 0.26, 0.15))
			_cyl(st, Vector3.ZERO, Vector3(0, 8.6, 0), 0.22, 0.08, _lin(Color(0.42, 0.26, 0.17)))
			var y := 2.6
			var r := 2.3
			for i in 5:
				_cone(st, Vector3(0, y, 0), r, 2.4, g_top, g_bot, float(i) * 1.3)
				y += 1.35
				r *= 0.74
		"cherry":
			var g_top := _lin(Color(0.97, 0.72, 0.8))
			var g_bot := _lin(Color(0.62, 0.38, 0.46))
			_cyl(st, Vector3.ZERO, Vector3(0.1, 1.9, 0), 0.2, 0.16, _lin(Color(0.3, 0.2, 0.18)))
			_cyl(st, Vector3(0.1, 1.7, 0), Vector3(1.3, 3.2, 0.4), 0.12, 0.07, _lin(Color(0.3, 0.2, 0.18)))
			_cyl(st, Vector3(0.1, 1.8, 0), Vector3(-1.2, 3.3, -0.3), 0.12, 0.07, _lin(Color(0.3, 0.2, 0.18)))
			for b in [[Vector3(0, 3.8, 0), Vector3(2.4, 1.3, 2.3)], [Vector3(1.6, 3.4, 0.5), Vector3(1.5, 1.0, 1.4)],
					[Vector3(-1.5, 3.5, -0.4), Vector3(1.5, 1.0, 1.4)], [Vector3(0.2, 4.6, 0.2), Vector3(1.4, 0.9, 1.4)]]:
				_blob(st, b[0], b[1], (b[0] as Vector3).x * 4.0 + 7.0, g_top, g_bot, 0.25)
		"poplar":
			var g_top := _lin(Color(0.4, 0.55, 0.24))
			var g_bot := _lin(Color(0.14, 0.24, 0.1))
			_cyl(st, Vector3.ZERO, Vector3(0, 2.2, 0), 0.2, 0.15, bark)
			for b in [[Vector3(0, 4.2, 0), Vector3(1.25, 2.6, 1.2)], [Vector3(0, 7.6, 0.05), Vector3(1.05, 2.4, 1.0)],
					[Vector3(0.05, 10.4, 0), Vector3(0.7, 1.8, 0.7)]]:
				_blob(st, b[0], b[1], (b[0] as Vector3).y, g_top, g_bot, 0.14)
	var m := st.commit()
	m.surface_set_material(0, material())
	return m


## A jagged cone (pine tier): a ring of points round the base, drooping tips.
static func _cone(st: SurfaceTool, base: Vector3, r: float, h: float, top: Color, bot: Color, seed: float) -> void:
	var n := 9
	var tip := base + Vector3(0, h, 0)
	for i in n:
		var a0 := TAU * i / n + seed
		var a1 := TAU * (i + 1) / n + seed
		var r0 := r * (0.8 + 0.3 * absf(sin(i * 2.7 + seed)))
		var r1 := r * (0.8 + 0.3 * absf(sin((i + 1) * 2.7 + seed)))
		var p0 := base + Vector3(cos(a0) * r0, -0.35 * absf(sin(i * 1.9 + seed)), sin(a0) * r0)
		var p1 := base + Vector3(cos(a1) * r1, -0.35 * absf(sin((i + 1) * 1.9 + seed)), sin(a1) * r1)
		var nrm := (p1 - p0).cross(tip - p0).normalized()
		if nrm.y < 0.0:
			nrm = -nrm
		var cb := bot
		cb.a = 1.0
		var ct := top
		ct.a = 1.0
		# Outer face (clockwise from outside), then the underside.
		for q in [[p0, ct if false else cb, nrm], [tip, ct, nrm], [p1, cb, nrm]]:
			st.set_color(q[1])
			st.set_normal(q[2])
			st.add_vertex(q[0])
		var bc := base + Vector3(0, 0.15, 0)
		for q in [[p0, cb], [p1, cb], [bc, cb * 0.7]]:
			st.set_color(q[1])
			st.set_normal(Vector3.DOWN)
			st.add_vertex(q[0])
