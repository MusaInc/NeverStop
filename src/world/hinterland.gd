class_name Hinterland
extends Node3D
## The land round the bay the city sits in: a horseshoe of hills and
## mountains – highest in the west behind Westbank (snow on the peaks, the
## sun sets behind them), lower ranges along the north and south, open sea to
## the east. Beaches and green foothills at the water, forest, rock, snow.
## Backdrop only (1.5–5 km out, far beyond web range): one heightfield mesh,
## triangles under the sea skipped, shaded by height and slope
## (hinterland.gdshader). Power lines come down off the hills on lattice
## pylons and cross the sound to Westbank (PowerLines).
##
## height_at() is pure (no scene access) so tests/tools can sample it.

const BAY_C := Vector2(-80.0, 0.0)   # bay ellipse centre (x, z)
const BAY_R := Vector2(1950.0, 1450.0)
const EXTENT := Rect2(-5600.0, -4600.0, 9800.0, 9200.0)
const CELL := 45.0
## Trees on the foothills facing the city (instanced cones), so the hills'
## outline and slopes read as land, not a smooth sheet.
const TREES := 5200
const TREE_REACH := 3300.0          # m from the bay centre
const SEA_Y := -1.6


## Ground height at (x, z): below the sea inside the bay, rising beyond it.
static func height_at(x: float, z: float) -> float:
	var q := Vector2((x - BAY_C.x) / BAY_R.x, (z - BAY_C.y) / BAY_R.y)
	var r := q.length()
	# Metres outside the bay's shoreline (roughly; the ellipse is stretched).
	var noise_r := 0.06 * (_fbm(Vector2(x, z) * 0.0011, 3) - 0.5)
	var out := (r - 1.0 - noise_r) * minf(BAY_R.x, BAY_R.y)
	if out < -40.0:
		return -30.0
	var ang := atan2(q.y, q.x)                    # 0 = east, ±PI = west
	var west := clampf(-cos(ang), 0.0, 1.0)       # 1 behind Westbank
	var east := clampf(cos(ang), 0.0, 1.0)
	# Open sea to the east: the land falls away there.
	var lift := 1.0 - smoothstep(0.35, 0.85, east)
	var peak := lerpf(360.0, 1150.0, pow(west, 1.4))
	var rise := smoothstep(0.0, 1.0, clampf(out / lerpf(1400.0, 1900.0, west), 0.0, 1.0))
	var ridges := 0.55 + 0.75 * _ridged(Vector2(x, z) * 0.00042)
	var hills := 30.0 * smoothstep(-40.0, 120.0, out) * (0.6 + _fbm(Vector2(x, z) * 0.004, 2))
	# Spurs and gullies down the slopes (finer ridged noise, strongest on
	# the steep middle of the rise), and knolls on the foothills: the land
	# reads as eroded ground, not one smooth sheet.
	var mid := smoothstep(0.05, 0.4, rise) * (1.0 - 0.5 * smoothstep(0.7, 1.0, rise))
	var gullies := (_ridged(Vector2(x, z) * 0.0019 + Vector2(3.1, 7.7)) - 0.35) * peak * 0.16 * mid
	var knolls := 22.0 * smoothstep(0.0, 260.0, out) * (_fbm(Vector2(x, z) * 0.011 + Vector2(11.0, 4.0), 3) - 0.45)
	var h := (hills + peak * rise * ridges + gullies + knolls) * lift
	# Beach: a gentle shelf through the waterline.
	h += clampf(out * 0.08, -6.0, 0.0)
	return h if lift > 0.02 else minf(h, -30.0)


static func _hash(p: Vector2) -> float:
	return fposmod(sin(p.dot(Vector2(127.1, 311.7))) * 43758.5453, 1.0)


static func _vnoise(p: Vector2) -> float:
	var i := p.floor()
	var f := p - i
	f = f * f * (Vector2(3, 3) - 2.0 * f)
	var a := _hash(i)
	var b := _hash(i + Vector2(1, 0))
	var c := _hash(i + Vector2(0, 1))
	var d := _hash(i + Vector2(1, 1))
	return lerpf(lerpf(a, b, f.x), lerpf(c, d, f.x), f.y)


static func _fbm(p: Vector2, octaves: int) -> float:
	var s := 0.0
	var w := 0.5
	var tot := 0.0
	for i in octaves:
		s += _vnoise(p) * w
		tot += w
		p = p * 2.03 + Vector2(17.3, 9.1)
		w *= 0.5
	return s / tot


## Sharp-crested ridges (1 - |noise|), a few octaves.
static func _ridged(p: Vector2) -> float:
	var s := 0.0
	var w := 0.6
	for i in 4:
		var n := 1.0 - absf(_vnoise(p) * 2.0 - 1.0)
		s += n * n * w
		p = p * 2.1 + Vector2(5.2, 1.3)
		w *= 0.45
	return s


func _ready() -> void:
	var nx := int(EXTENT.size.x / CELL) + 1
	var nz := int(EXTENT.size.y / CELL) + 1
	var hs := PackedFloat32Array()
	hs.resize(nx * nz)
	for j in nz:
		for i in nx:
			hs[j * nx + i] = height_at(EXTENT.position.x + i * CELL, EXTENT.position.y + j * CELL)
	var verts := PackedVector3Array()
	var normals := PackedVector3Array()
	var idx := PackedInt32Array()
	var map := PackedInt32Array()
	map.resize(nx * nz)
	map.fill(-1)
	var vid := func(i: int, j: int) -> int:
		var k := j * nx + i
		if map[k] < 0:
			map[k] = verts.size()
			var h := hs[k]
			verts.append(Vector3(EXTENT.position.x + i * CELL, h, EXTENT.position.y + j * CELL))
			var hl := hs[j * nx + maxi(i - 1, 0)]
			var hr := hs[j * nx + mini(i + 1, nx - 1)]
			var hd := hs[maxi(j - 1, 0) * nx + i]
			var hu := hs[mini(j + 1, nz - 1) * nx + i]
			normals.append(Vector3(hl - hr, 2.0 * CELL, hd - hu).normalized())
		return map[k]
	for j in nz - 1:
		for i in nx - 1:
			var a := hs[j * nx + i]
			var b := hs[j * nx + i + 1]
			var c := hs[(j + 1) * nx + i]
			var d := hs[(j + 1) * nx + i + 1]
			if maxf(maxf(a, b), maxf(c, d)) < SEA_Y - 2.0:
				continue  # wholly under the sea
			var i0: int = vid.call(i, j)
			var i1: int = vid.call(i + 1, j)
			var i2: int = vid.call(i, j + 1)
			var i3: int = vid.call(i + 1, j + 1)
			idx.append_array([i0, i1, i3, i0, i3, i2])
	var arr := []
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = verts
	arr[Mesh.ARRAY_NORMAL] = normals
	arr[Mesh.ARRAY_INDEX] = idx
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
	var mi := MeshInstance3D.new()
	mi.name = "Mountains"
	mi.mesh = mesh
	var mat := ShaderMaterial.new()
	mat.shader = load("res://src/world/shaders/hinterland.gdshader")
	mi.material_override = mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mi.extra_cull_margin = 50.0
	add_child(mi)
	_trees()
	var lines := PowerLines.new()
	lines.name = "PowerLines"
	add_child(lines)


func triangle_count() -> int:
	var mi: MeshInstance3D = get_node_or_null("Mountains")
	return mi.mesh.surface_get_array_index_len(0) / 3 if mi else 0


## Conifer clumps on the forested foothills (where hinterland.gdshader paints
## forest: above the beach, below the rock and snow, not too steep), one
## MultiMesh of low-poly cones. Deterministic.
func _trees() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 90210
	var xfs: Array[Transform3D] = []
	var tries := 0
	while xfs.size() < TREES and tries < TREES * 12:
		tries += 1
		var a := rng.randf() * TAU
		var r := rng.randf_range(0.97, TREE_REACH / BAY_R.y)
		var x := BAY_C.x + cos(a) * BAY_R.x * r
		var z := BAY_C.y + sin(a) * BAY_R.y * r
		var h := height_at(x, z)
		if h < 8.0 or h > 520.0:
			continue
		var sl := Vector2(height_at(x + 12.0, z) - height_at(x - 12.0, z), height_at(x, z + 12.0) - height_at(x, z - 12.0)).length() / 24.0
		if sl > 0.7:
			continue
		# Clumped: the same noise the shader's forest uses decides.
		if _fbm(Vector2(x, z) * 0.006, 3) + 0.25 * smoothstep(20.0, 200.0, h) < 0.42 + rng.randf() * 0.12:
			continue
		# A clump of 3-6 round this spot.
		for k in rng.randi_range(3, 6):
			var q := Vector2(x, z) + Vector2(rng.randf_range(-22.0, 22.0), rng.randf_range(-22.0, 22.0))
			var s := rng.randf_range(0.75, 1.45) * lerpf(1.0, 0.7, smoothstep(250.0, 500.0, h))
			xfs.append(Transform3D(Basis(Vector3.UP, rng.randf() * TAU).scaled(Vector3(s, s * rng.randf_range(0.85, 1.25), s)),
				Vector3(q.x, height_at(q.x, q.y) - 1.0, q.y)))
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	mm.mesh = _tree_mesh()
	mm.instance_count = xfs.size()
	for i in xfs.size():
		mm.set_instance_transform(i, xfs[i])
		var g := rng.randf_range(0.75, 1.15)
		mm.set_instance_color(i, Color(0.13 * g, 0.21 * g, 0.12 * g))
	var mi := MultiMeshInstance3D.new()
	mi.name = "Trees"
	mi.multimesh = mm
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var mat := StandardMaterial3D.new()
	mat.vertex_color_use_as_albedo = true
	mat.roughness = 0.95
	mat.specular_mode = BaseMaterial3D.SPECULAR_DISABLED
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mi.material_override = mat
	add_child(mi)


## A conifer ~18 m tall in two tiers of six-sided cones (24 triangles).
static func _tree_mesh() -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for tier: Array in [[0.0, 11.0, 5.5], [7.0, 18.0, 4.0]]:
		var y0: float = tier[0]
		var y1: float = tier[1]
		var r: float = tier[2]
		for i in 6:
			var a0 := TAU * i / 6.0
			var a1 := TAU * (i + 1) / 6.0
			var p0 := Vector3(cos(a0) * r, y0, sin(a0) * r)
			var p1 := Vector3(cos(a1) * r, y0, sin(a1) * r)
			var tip := Vector3(0.0, y1, 0.0)
			var n := (p1 - p0).cross(tip - p0).normalized()
			if n.dot(p0 + p1) < 0.0:
				n = -n
			# (Lighter toward the tip: sunlit crowns, shaded skirts.)
			for v: Vector3 in [p0, tip, p1]:
				st.set_normal((n + Vector3.UP * 0.3).normalized())
				st.set_color(Color.WHITE * lerpf(0.75, 1.25, v.y / 18.0))
				st.add_vertex(v)
	return st.commit()
