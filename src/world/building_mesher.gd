class_name BuildingMesher
extends RefCounted
## Turns CityLayout building specs into merged mesh arrays (one surface per
## chunk per LOD) for building.gdshader. Pure data in, Mesh arrays out, so it
## can run on a worker thread or in the offline bake.
## Winding: Godot treats clockwise triangles as front faces.

const KIND_WALL := 0.0
const KIND_TRIM := 1.0
const KIND_ROOF := 2.0
const KIND_GLASS := 3.0
const KIND_SIGN := 4.0
const KIND_SHORE := 5.0   # rock / sand round the island (ground.gdshader shades it)
const ROOF_COLOR := Color(0.40, 0.40, 0.41)
## Roof finishes picked per building: gravel, tar, pale concrete, rust, green.
const ROOF_COLORS := [Color(0.40, 0.40, 0.41), Color(0.24, 0.25, 0.27), Color(0.6, 0.59, 0.56),
	Color(0.45, 0.33, 0.28), Color(0.36, 0.44, 0.3)]
const CRANE_YELLOW := Color(0.93, 0.68, 0.12)
const STEEL := Color(0.22, 0.23, 0.25)
const CONCRETE := Color(0.6, 0.59, 0.56)
const BRIDGE_RED := Color(0.66, 0.17, 0.12)
## Shop awnings at street level (brand-friendly, slightly muted).
const AWNING_COLORS := [Color(0.72, 0.16, 0.14), Color(0.13, 0.36, 0.3), Color(0.15, 0.22, 0.42),
	Color(0.85, 0.62, 0.18), Color(0.86, 0.82, 0.72), Color(0.42, 0.18, 0.36)]
const LEDGE_EVERY := 14.4   # m: a stone ledge every four floors on masonry facades
const KERB := 0.15        # m: pavement blocks stand this far above the road
const PARAPET := 0.3       # m: roof-edge lip; under Player.STEP_MAX, so a run steps onto it
const PARAPET_T := 0.3     # m: its thickness
const LEDGE_OUT := 0.08    # m: stone courses stand this far proud of the wall (visual only)
const PLINTH_OUT := 0.15   # m: ground-floor plinth band
const PLINTH_H := 0.9
const AWNING_Y := 3.25
const AWNING_OUT := 1.3
const IRON := [Color(0.11, 0.12, 0.12), Color(0.1, 0.16, 0.13), Color(0.3, 0.12, 0.09)]
const ESCAPE_DEPTH := 1.35   # m: fire-escape platforms stand this far out
const FIN_OUT := 0.24        # m: glass-tower fins
## Outskirt backdrop blocks opt out of features (drawn plain, collide plain).
const NO_FEATURES := {"draw": [], "beams": [], "col": [], "col_human": []}

var verts := PackedVector3Array()
var normals := PackedVector3Array()
var colors := PackedColorArray()
var uvs := PackedVector2Array()
var uv2s := PackedVector2Array()
var indices := PackedInt32Array()
## Frame applied to everything drawn while set (a building's lot frame, see
## CityLayout.bxf). Identity = world.
var xf := Transform3D.IDENTITY
var _xf_on := false


func _begin(b: Dictionary) -> void:
	if float(b.get("rot", 0.0)) != 0.0:
		xf = CityLayout.bxf(b)
		_xf_on = true


func _end() -> void:
	xf = Transform3D.IDENTITY
	_xf_on = false


func is_empty() -> bool:
	return verts.is_empty()


func arrays() -> Array:
	var a := []
	a.resize(Mesh.ARRAY_MAX)
	a[Mesh.ARRAY_VERTEX] = verts
	a[Mesh.ARRAY_NORMAL] = normals
	a[Mesh.ARRAY_COLOR] = colors
	a[Mesh.ARRAY_TEX_UV] = uvs
	a[Mesh.ARRAY_TEX_UV2] = uv2s
	a[Mesh.ARRAY_INDEX] = indices
	return a


## Quad from four corners given clockwise as seen from the front.
func quad(a: Vector3, b: Vector3, c: Vector3, d: Vector3, n: Vector3, ua: Vector2, ub: Vector2,
		uc: Vector2, ud: Vector2, col: Color, kind: float, style: float, seed: float) -> void:
	if _xf_on:
		a = xf * a
		b = xf * b
		c = xf * c
		d = xf * d
		n = xf.basis * n
	var i := verts.size()
	verts.append_array([a, b, c, d])
	normals.append_array([n, n, n, n])
	var cc := Color(col.r, col.g, col.b, kind / 8.0)
	colors.append_array([cc, cc, cc, cc])
	uvs.append_array([ua, ub, uc, ud])
	var s2 := Vector2(style, seed)
	uv2s.append_array([s2, s2, s2, s2])
	indices.append_array([i, i + 1, i + 2, i, i + 2, i + 3])


## Four outward walls of an axis-aligned box, UV u running round the perimeter.
func walls(x0: float, z0: float, x1: float, z1: float, y0: float, y1: float, col: Color,
		kind: float, style: float, seed: float, uv_y0 := -1.0, hole := {}) -> void:
	var vy0 := y0 if uv_y0 < 0.0 else uv_y0
	var vy1 := vy0 + (y1 - y0)
	var corners := [Vector2(x0, z1), Vector2(x1, z1), Vector2(x1, z0), Vector2(x0, z0)]
	var ns := [Vector3.BACK, Vector3.RIGHT, Vector3.FORWARD, Vector3.LEFT]
	var u := 0.0
	for k in 4:
		var a: Vector2 = corners[k]
		var b: Vector2 = corners[(k + 1) % 4]
		var w := a.distance_to(b)
		var cuts: Array = []
		if not hole.is_empty():
			if int(hole["face"]) == k:
				cuts.append([float(hole["oa0"]), float(hole["oa1"]), float(hole["oy0"]), float(hole["oy1"])])
			for wn in hole.get("wins", []):
				if int(wn[0]) == k:
					cuts.append([float(wn[1]), float(wn[2]), float(wn[3]), float(wn[4])])
		if not cuts.is_empty():
			# A home's windows: the face drawn round its openings (columns
			# between the openings' edges, each minus the openings it crosses),
			# UVs continuous with the rest.
			var xs := [0.0, w]
			for c in cuts:
				xs.append(clampf(c[0], 0.0, w))
				xs.append(clampf(c[1], 0.0, w))
			xs.sort()
			for ci in xs.size() - 1:
				var p0: float = xs[ci]
				var p1: float = xs[ci + 1]
				if p1 - p0 < 0.001:
					continue
				var ys := [[y0, y1]]
				for c in cuts:
					if c[0] <= p0 + 0.001 and c[1] >= p1 - 0.001:
						var nys := []
						for iv in ys:
							if c[3] <= iv[0] or c[2] >= iv[1]:
								nys.append(iv)
								continue
							if c[2] > iv[0]:
								nys.append([iv[0], c[2]])
							if c[3] < iv[1]:
								nys.append([c[3], iv[1]])
						ys = nys
				for iv in ys:
					var h0: float = iv[0]
					var h1: float = iv[1]
					if h1 - h0 < 0.001:
						continue
					var pa := a.lerp(b, p0 / w)
					var pb := a.lerp(b, p1 / w)
					quad(Vector3(pa.x, h1, pa.y), Vector3(pb.x, h1, pb.y), Vector3(pb.x, h0, pb.y), Vector3(pa.x, h0, pa.y), ns[k],
						Vector2(u + p0, vy0 + h1 - y0), Vector2(u + p1, vy0 + h1 - y0), Vector2(u + p1, vy0 + h0 - y0),
						Vector2(u + p0, vy0 + h0 - y0), col, kind, style, seed)
					_face_span(w, style, seed)
					var n2 := uv2s.size()
					for q in 4:  # (the corner shading's 0..1 across the whole face)
						var t := (p0 if q == 0 or q == 3 else p1) / w
						uv2s[n2 - 4 + q].x = style + minf(t, 0.999)
			u += w
			continue
		quad(Vector3(a.x, y1, a.y), Vector3(b.x, y1, b.y), Vector3(b.x, y0, b.y), Vector3(a.x, y0, a.y), ns[k],
			Vector2(u, vy1), Vector2(u + w, vy1), Vector2(u + w, vy0), Vector2(u, vy0), col, kind, style, seed)
		_face_span(w, style, seed)
		u += w


## Tells the shader where a wall face's corners are, for corner quoins and
## edge shading: UV2.x = style + 0..1 across the face, UV2.y = width (¼ m
## steps) + seed. Quads without it (roofs, undersides) read as width 0.
func _face_span(w: float, style: float, seed: float) -> void:
	var n := uv2s.size()
	# Seed in 1/256 steps, centred, so interpolation noise can't change it.
	var wy := floorf(w * 4.0) + (floorf(seed * 256.0) + 0.5) / 256.0
	uv2s[n - 4] = Vector2(style, wy)
	uv2s[n - 3] = Vector2(style + 0.999, wy)
	uv2s[n - 2] = Vector2(style + 0.999, wy)
	uv2s[n - 1] = Vector2(style, wy)


func top(x0: float, z0: float, x1: float, z1: float, y: float, col: Color, kind: float, style: float, seed: float) -> void:
	quad(Vector3(x0, y, z0), Vector3(x1, y, z0), Vector3(x1, y, z1), Vector3(x0, y, z1), Vector3.UP,
		Vector2(x0, z0), Vector2(x1, z0), Vector2(x1, z1), Vector2(x0, z1), col, kind, style, seed)


func bottom(x0: float, z0: float, x1: float, z1: float, y: float, col: Color, kind: float, style: float, seed: float) -> void:
	quad(Vector3(x0, y, z1), Vector3(x1, y, z1), Vector3(x1, y, z0), Vector3(x0, y, z0), Vector3.DOWN,
		Vector2(x0, z1), Vector2(x1, z1), Vector2(x1, z0), Vector2(x0, z0), col, kind, style, seed)


## The frame beam() builds a box in: x across (w), y up-ish (h), z along
## (negated, so the basis is right-handed for collision shapes).
static func beam_basis(a: Vector3, b: Vector3) -> Basis:
	var f := (b - a).normalized()
	var up := Vector3.UP if absf(f.y) < 0.95 else Vector3.RIGHT
	var s := f.cross(up).normalized()
	var u := s.cross(f).normalized()
	return Basis(s, u, -f)


## Box of cross-section w x h from a to b (any direction), four sides + caps.
func beam(a: Vector3, b: Vector3, w: float, h: float, col: Color, kind := KIND_TRIM, caps := false) -> void:
	var d := b - a
	var length := d.length()
	if length < 0.001:
		return
	var f := d / length
	var up := Vector3.UP if absf(f.y) < 0.95 else Vector3.RIGHT
	var s := f.cross(up).normalized()
	var u := s.cross(f).normalized()
	var hs := s * w * 0.5
	var hu := u * h * 0.5
	var sides := [[hu, s], [hs, -u], [-hu, -s], [-hs, u]]
	for k in 4:
		var c0: Vector3 = sides[k][0]
		var c1: Vector3 = sides[(k + 1) % 4][0]
		var p0 := c0 + c1
		var p1 := c0 - c1
		var n: Vector3 = (c0).normalized()
		# Pick the winding that faces outward (clockwise seen from outside).
		var qa := a + p0
		var qb := b + p0
		var qc := b + p1
		var qd := a + p1
		if (qb - qa).cross(qc - qa).dot(n) > 0.0:
			quad(qa, qd, qc, qb, n, Vector2.ZERO, Vector2(0, length), Vector2(w, length), Vector2(w, 0), col, kind, 0, 0)
		else:
			quad(qa, qb, qc, qd, n, Vector2.ZERO, Vector2(0, length), Vector2(w, length), Vector2(w, 0), col, kind, 0, 0)
	if caps:
		for e in [[b, f], [a, -f]]:
			var o: Vector3 = e[0]
			var n2: Vector3 = e[1]
			var v := [o + hs + hu, o - hs + hu, o - hs - hu, o + hs - hu]
			if (v[1] - v[0]).cross(v[2] - v[0]).dot(n2) > 0.0:
				v.reverse()
			quad(v[0], v[1], v[2], v[3], n2, Vector2.ZERO, Vector2.ZERO, Vector2.ZERO, Vector2.ZERO, col, kind, 0, 0)


## Solid axis-aligned box (walls, top, bottom) in one flat colour.
func solid(x0: float, z0: float, x1: float, z1: float, y0: float, y1: float, col: Color, kind := KIND_TRIM) -> void:
	walls(x0, z0, x1, z1, y0, y1, col, kind, 0, 0)
	top(x0, z0, x1, z1, y1, col, kind, 0, 0)
	bottom(x0, z0, x1, z1, y0, col.darkened(0.25), kind, 0, 0)


## Square lattice mast (4 chords, zig-zag bracing on every face).
func lattice(base: Vector3, height: float, size: float, col: Color, section := 4.0, detailed := true) -> void:
	var hs := size * 0.5
	var cs := [Vector3(-hs, 0, -hs), Vector3(hs, 0, -hs), Vector3(hs, 0, hs), Vector3(-hs, 0, hs)]
	if not detailed:
		solid(base.x - hs, base.z - hs, base.x + hs, base.z + hs, base.y, base.y + height, col)
		return
	for c in cs:
		beam(base + c, base + c + Vector3.UP * height, 0.45, 0.45, col)
	var n := maxi(1, int(height / section))
	var step := height / n
	for i in n:
		var y0 := base.y + i * step
		for k in 4:
			var a: Vector3 = cs[k]
			var b: Vector3 = cs[(k + 1) % 4]
			var p0 := Vector3(base.x, y0, base.z) + (a if i % 2 == 0 else b)
			var p1 := Vector3(base.x, y0 + step, base.z) + (b if i % 2 == 0 else a)
			beam(p0, p1, 0.22, 0.22, col)


## Triangular lattice girder from a to b (a jib or boom), apex on top.
func girder(a: Vector3, b: Vector3, width: float, depth: float, col: Color, detailed := true) -> void:
	var d := b - a
	var length := d.length()
	var f := d / length
	var s := f.cross(Vector3.UP).normalized() * width * 0.5
	var up := Vector3.UP * depth
	if not detailed:
		beam(a + up * 0.5, b + up * 0.5, width, depth, col, KIND_TRIM, true)
		return
	var chords := [a - s, a + s, a + up]
	for c in chords:
		beam(c, c + d, 0.4, 0.4, col)
	var n := maxi(1, int(length / 3.0))
	for i in n:
		var p := a + f * (length * i / n)
		var q := a + f * (length * (i + 1) / n)
		beam(p - s, q + up, 0.14, 0.14, col)
		beam(p + s, q + up, 0.14, 0.14, col)
		beam(q - s, q + s, 0.14, 0.14, col)


static func trim_color(b: Dictionary) -> Color:
	var c: Color = b["color"]
	match int(b["style"]):
		CityLayout.Style.GLASS, CityLayout.Style.DARK_GLASS:
			return Color(0.62, 0.66, 0.68)
		CityLayout.Style.BRICK, CityLayout.Style.WAREHOUSE:
			return Color(0.86, 0.82, 0.74)
		_:
			return c.lightened(0.12)


## Detailed LOD: walls, cornice slabs with undersides, parapet roof. Drawn in
## the building's frame (rotated lots).
func add_building(b: Dictionary, detailed: bool) -> void:
	_begin(b)
	_add_building(b, detailed)
	_end()


func _add_building(b: Dictionary, detailed: bool) -> void:
	match b["kind"]:
		"invisible", "structure":
			return
		"sign":
			_add_sign(b, detailed)
			return
		"frame":
			_add_frame(b, detailed)
			return
		"plain":
			for t in b["tiers"]:
				solid(t[0], t[1], t[2], t[3], t[4], t[5], b["color"])
			return
	var style := float(b["style"])
	var seed: float = b["seed"]
	var col: Color = b["color"]
	var glassy := style == CityLayout.Style.GLASS or style == CityLayout.Style.DARK_GLASS
	var wall_kind := KIND_GLASS if glassy else KIND_WALL
	var trim := trim_color(b)
	var roof: Color = ROOF_COLORS[int(seed * 997.0) % ROOF_COLORS.size()]
	if roof == ROOF_COLORS[4] and tiers_top(b) > 60.0:
		roof = ROOF_COLORS[0]  # green roofs on low buildings only
	var tiers: Array = b["tiers"]
	var base := base_of(b)
	var bc := base_course(b)
	if bc.has_volume():
		# On a slope the lot is level at its uphill corner; down the hill the
		# building stands on a dressed-stone base course to the street.
		var stone := Color(0.56, 0.53, 0.48) if _glassy(b) else trim.darkened(0.18)
		solid(bc.position.x, bc.position.z, bc.end.x, bc.end.z, bc.position.y, bc.end.y, stone, KIND_WALL)
	if shaped(b):
		_add_shaped(b, detailed, style, seed, col, wall_kind, trim, roof, base, glassy)
		return
	for i in tiers.size():
		var t: Array = tiers[i]
		var x0: float = t[0]
		var z0: float = t[1]
		var x1: float = t[2]
		var z1: float = t[3]
		var y0: float = t[4]
		var y1: float = t[5]
		var apt: Dictionary = b.get("apt", {})
		var has_apt := not apt.is_empty() and int(apt["t"]) == i
		if has_apt:
			walls(x0, z0, x1, z1, y0, y1, col, wall_kind, style, seed, y0 - base, apt)
		else:
			walls(x0, z0, x1, z1, y0, y1, col, wall_kind, style, seed, y0 - base)
		if b["kind"] == "bridge" or _overhangs(tiers, i) or not _on_ground(b, t) and i == 0:
			# Underside: sky bridges, cantilevered tiers, towers' first tier
			# (hidden on their podium, but they never show a hole).
			bottom(x0, z0, x1, z1, y0, trim if b["kind"] == "bridge" else col.darkened(0.25), KIND_TRIM, style, seed)
		if detailed:
			var o := cornice_out(b)
			var ch := cornice_h(b)
			walls(x0 - o, z0 - o, x1 + o, z1 + o, y1 - ch * 0.5, y1 + ch * 0.5, trim, KIND_TRIM, style, seed)
			bottom(x0 - o, z0 - o, x1 + o, z1 + o, y1 - ch * 0.5, trim, KIND_TRIM, style, seed)
			roof_top(x0 - o, z0 - o, x1 + o, z1 + o, y1 + ch * 0.5, roof, seed)
			if b["kind"] != "bridge":
				_parapet(x0 - o, z0 - o, x1 + o, z1 + o, y1 + ch * 0.5, trim)
				if not glassy and not has_apt:
					_ledges(x0, z0, x1, z1, y0, y1, trim, style, seed, base)
			# Ground-floor plinth band on the base tier.
			if _has_plinth(b, i):
				var po := PLINTH_OUT
				var ph := base + PLINTH_H
				walls(x0 - po, z0 - po, x1 + po, z1 + po, base, ph, col.darkened(0.3), KIND_TRIM, style, seed)
				top(x0 - po, z0 - po, x1 + po, z0, ph, col.darkened(0.3), KIND_TRIM, style, seed)
				top(x0 - po, z1, x1 + po, z1 + po, ph, col.darkened(0.3), KIND_TRIM, style, seed)
				top(x0 - po, z0, x0, z1, ph, col.darkened(0.3), KIND_TRIM, style, seed)
				top(x1, z0, x1 + po, z1, ph, col.darkened(0.3), KIND_TRIM, style, seed)
				for aw in awning_runs(b):
					_awning(aw[0], aw[1], aw[2], aw[3], (aw[3] as Color).darkened(0.15))
		else:
			roof_top(x0, z0, x1, z1, y1, roof, seed)


## Architectural features (features()) as their own mesh: CityWorld draws it
## over a shorter range than the detailed LOD, since it is small detail.
## Fins only need their two sides and face (6 triangles, not 12).
func add_features(b: Dictionary) -> void:
	_begin(b)
	_add_features(b)
	_end()


func _add_features(b: Dictionary) -> void:
	var f := features(b)
	for d in f["draw"]:
		var bx: AABB = d[0]
		if d.size() > 2 and d[2] is String:
			continue  # skyline pieces: drawn with the building (add_skyline)
		if d.size() > 2 and d[2] is Vector3:
			_fin(bx, d[2], d[1])
		else:
			solid(bx.position.x, bx.position.z, bx.end.x, bx.end.z, bx.position.y, bx.end.y, d[1])
	for bm in f["beams"]:
		beam(bm[0], bm[1], bm[2], bm[3], bm[4])


## Feature pieces that shape the skyline (glass crowns): part of the building
## mesh at every LOD, not the short-range feature mesh.
func add_skyline(b: Dictionary) -> void:
	if b["kind"] != "normal":
		return
	_begin(b)
	for d in features(b)["draw"]:
		if d.size() > 2 and d[2] is String:
			var bx: AABB = d[0]
			if d.size() > 3 and d[3] == "roof":
				# Crown deck: the roof you land on gets the roof finish.
				walls(bx.position.x, bx.position.z, bx.end.x, bx.end.z, bx.position.y, bx.end.y, d[1], KIND_TRIM, 0, 0)
				roof_top(bx.position.x, bx.position.z, bx.end.x, bx.end.z, bx.end.y, d[1], fmod(float(b["seed"]) * 3.7, 1.0))
				continue
			solid(bx.position.x, bx.position.z, bx.end.x, bx.end.z, bx.position.y, bx.end.y, d[1])
	_end()


## A thin vertical fin standing out of a wall along `out`: face + two sides.
func _fin(bx: AABB, out: Vector3, col: Color) -> void:
	var y0 := bx.position.y
	var y1 := bx.end.y
	var lo := bx.position
	var hi := bx.end
	var c := bx.get_center()
	var side := Vector3(out.z, 0, -out.x).abs()  # along the wall
	var hw := (side * bx.size).length() * 0.5
	var depth := (out.abs() * bx.size).length()
	var base := c - out * depth * 0.5  # on the wall plane
	var tip := c + out * depth * 0.5
	var s := Vector3(out.z, 0, -out.x)  # wall tangent (right of `out`)
	var a := tip - s * hw
	var e := tip + s * hw
	_vquad(a, e, y0, y1, out, col)
	_vquad(e, base + s * hw, y0, y1, s, col.darkened(0.12))
	_vquad(base - s * hw, a, y0, y1, -s, col.darkened(0.12))


## Vertical quad from a to b (seen with `n` toward the viewer), y0..y1.
func _vquad(a: Vector3, b: Vector3, y0: float, y1: float, n: Vector3, col: Color) -> void:
	var p := [Vector3(a.x, y1, a.z), Vector3(b.x, y1, b.z), Vector3(b.x, y0, b.z), Vector3(a.x, y0, a.z)]
	if (p[1] - p[0]).cross(p[2] - p[0]).dot(n) > 0.0:
		p.reverse()
	quad(p[0], p[1], p[2], p[3], n, Vector2.ZERO, Vector2.ZERO, Vector2.ZERO, Vector2.ZERO, col, KIND_TRIM, 0, 0)


## Cornice: how far the roof slab overhangs the walls, and its depth (it
## straddles the tier top, so the roof surface is half of it above t[5]).
static func cornice_out(b: Dictionary) -> float:
	return 0.25 if _glassy(b) else 0.3


static func cornice_h(b: Dictionary) -> float:
	return 0.6 if _glassy(b) else 1.0


## Where a building stands: its block's terrace (0 on flat ground). Tiers,
## roofs and features are absolute; facade bands (shopfronts, ledges, plinth,
## awnings) are measured from here.
static func base_of(b: Dictionary) -> float:
	return float(b.get("base", 0.0))


## The stone base a building stands on down a slope: from its lowest street
## corner (b["foot"]) up to its lot level, a little proud of the walls.
## Empty when the lot is level.
static func base_course(b: Dictionary) -> AABB:
	var foot: float = b.get("foot", base_of(b))
	var base := base_of(b)
	if base - foot < 0.05 or b["kind"] not in ["normal", "landmark", "frame"]:
		return AABB()
	var t: Array = b["tiers"][0]
	var o := PLINTH_OUT + 0.05
	return _aabb(t[0] - o, t[1] - o, t[2] + o, t[3] + o, foot - 0.3, base + CityTerrain.KERB)


## True if tier i sticks out past the tier below it (a cantilever): its
## underside shows.
static func _overhangs(tiers: Array, i: int) -> bool:
	if i == 0:
		return false
	var t: Array = tiers[i]
	var p: Array = tiers[i - 1]
	return t[0] < p[0] - 0.01 or t[1] < p[1] - 0.01 or t[2] > p[2] + 0.01 or t[3] > p[3] + 0.01


static func _on_ground(b: Dictionary, t: Array) -> bool:
	return absf(float(t[4]) - base_of(b)) < 0.01


static func _glassy(b: Dictionary) -> bool:
	return int(b["style"]) == CityLayout.Style.GLASS or int(b["style"]) == CityLayout.Style.DARK_GLASS


static func _parapeted(b: Dictionary) -> bool:
	return b["kind"] in ["normal", "landmark", "spire"]


static func _has_plinth(b: Dictionary, tier: int) -> bool:
	return tier == 0 and _on_ground(b, b["tiers"][0]) and not _glassy(b) and b["kind"] != "bridge"


## Height of the walkable roof of the top tier as drawn in the detailed LOD
## (props stand on it, collision matches it).
static func roof_y(b: Dictionary) -> float:
	var top: float = b["tiers"][-1][5]
	if _parapeted(b) or b["kind"] == "bridge":
		return top + cornice_h(b) * 0.5 + crown_h(b)
	return top


## Glass crowns: on some glass towers over 100 m the curtain wall carries on
## 4–7 m past the roof, with a deck across its top – the walkable roof is up
## there (an open-topped screen made every such roof a pit you couldn't run
## or swing out of). 0 = no crown. Own random stream (cached on b).
static func crown_h(b: Dictionary) -> float:
	if b.has("_crown"):
		return b["_crown"]
	var h := 0.0
	if b["kind"] == "normal" and _glassy(b) and float(b["tiers"][-1][5]) > 100.0 and not b.has("shape"):
		var r := RandomNumberGenerator.new()
		r.seed = int(float(b["seed"]) * 6151.0 * 1000.0) ^ 0xc20
		if r.randf() < 0.7:
			h = r.randf_range(4.0, 7.0)
	b["_crown"] = h
	return h


## The solid boxes of a building exactly as the detailed LOD draws it:
## walls, the cornice/roof slab with its overhang, the parapet ring, the
## ground-floor plinth and shop awnings; construction frames with their
## columns, hoarding and edge barrier. Collision is built from this, so what
## you see is what you stand on and bump into.
static func collision_boxes(b: Dictionary) -> Array[AABB]:
	var out: Array[AABB] = []
	var kind: String = b["kind"]
	var tiers: Array = b["tiers"]
	match kind:
		"invisible":
			return out  # stand-ins for landmark models, which collide with their own mesh
		"structure", "sign", "plain":
			for t in tiers:
				out.append(_aabb(t[0], t[1], t[2], t[3], t[4], t[5]))
			if kind == "sign":
				_sign_boxes(b, out)
			return out
		"frame":
			if base_course(b).has_volume():
				out.append(base_course(b))
			for t in tiers:
				out.append(_aabb(t[0], t[1], t[2], t[3], t[4], t[5]))
			var t0: Array = tiers[0]
			var ytop: float = tiers[-1][5]
			var base: float = b.get("base", 0.0)
			var nx := maxi(2, int((t0[2] - t0[0]) / 8.0) + 1)
			var nz := maxi(2, int((t0[3] - t0[1]) / 8.0) + 1)
			for i in nx:
				for j in nz:
					if i != 0 and i != nx - 1 and j != 0 and j != nz - 1:
						continue
					var x: float = lerpf(t0[0] + 0.5, t0[2] - 0.5, i / float(nx - 1))
					var z: float = lerpf(t0[1] + 0.5, t0[3] - 0.5, j / float(nz - 1))
					out.append(_aabb(x - 0.3, z - 0.3, x + 0.3, z + 0.3, base, ytop + 3.0))
			_ring(out, t0[0] - 1.5, t0[1] - 1.5, t0[2] + 1.5, t0[3] + 1.5, base, base + 2.6, 0.12)
			_ring(out, t0[0] - 0.2, t0[1] - 0.2, t0[2] + 0.2, t0[3] + 0.2, ytop + 0.1, ytop + 1.2, 0.12)
			return out
	var o := cornice_out(b)
	var ch := cornice_h(b)
	var bc := base_course(b)
	if bc.has_volume():
		out.append(bc)
	var apt: Dictionary = b.get("apt", {})
	if shaped(b):
		# (the walls themselves collide as convex prisms: collision_hulls)
		out.append_array(features(b)["col"])
		return out
	for i in tiers.size():
		var t: Array = tiers[i]
		var y1: float = t[5]
		out.append(_aabb(t[0], t[1], t[2], t[3], t[4], y1 - ch * 0.5))
		out.append(_aabb(t[0] - o, t[1] - o, t[2] + o, t[3] + o, y1 - ch * 0.5, y1 + ch * 0.5))
		if kind != "bridge":
			_ring(out, t[0] - o, t[1] - o, t[2] + o, t[3] + o, y1 + ch * 0.5, y1 + ch * 0.5 + PARAPET, PARAPET_T)
		if _has_plinth(b, i):
			out.append(_aabb(t[0] - PLINTH_OUT, t[1] - PLINTH_OUT, t[2] + PLINTH_OUT, t[3] + PLINTH_OUT, base_of(b),
				base_of(b) + PLINTH_H))
	for aw in awning_runs(b):
		var a: Vector3 = aw[0]
		var e: Vector3 = aw[1]
		var far: Vector3 = e + (aw[2] as Vector3)
		var ay: float = a.y  # awning_runs gives absolute points
		var lo := Vector3(minf(a.x, far.x), ay - 0.38, minf(a.z, far.z))
		var hi := Vector3(maxf(a.x, far.x), ay + 0.18, maxf(a.z, far.z))
		out.append(AABB(lo, hi - lo))
	out.append_array(features(b)["col"])
	return out


## Feature boxes clear of a home's window (balconies, fire escapes, fins and
## ledges never block the opening or the view out).
static func _clear_of_apt(b: Dictionary, out: Dictionary) -> Dictionary:
	var apt: Dictionary = b.get("apt", {})
	if apt.is_empty():
		return out
	# Glass all round: nothing stuck on any face of the home's storey.
	var t: Array = (b["tiers"] as Array)[int(apt["t"])]
	var keep := AABB(Vector3(float(t[0]) - 4.0, float(apt["y0"]) - 3.0, float(t[1]) - 4.0),
		Vector3(float(t[2]) - float(t[0]) + 8.0, float(apt["y1"]) - float(apt["y0"]) + 4.0, float(t[3]) - float(t[1]) + 8.0))
	var res := {"draw": [], "col": [], "col_human": [], "beams": []}
	for d in out["draw"]:
		if not (d[0] as AABB).intersects(keep):
			res["draw"].append(d)
	for c in out["col"]:
		if not (c as AABB).intersects(keep):
			res["col"].append(c)
	for c in out.get("col_human", []):
		if not (c as AABB).intersects(keep):
			res["col_human"].append(c)
	for bm in out["beams"]:
		var bb := AABB(bm[0], Vector3.ZERO).expand(bm[1]).grow(0.3)
		if not bb.intersects(keep):
			res["beams"].append(bm)
	for k in out:
		if not res.has(k):
			res[k] = out[k]
	return res


# ------------------------------------------------------------ features
## A wall face of a tier in the order walls() draws them (k = 0 +z, 1 +x,
## 2 −z, 3 −x): [origin at the left end, along, outward, length, u at origin]
## (u = the shader's metres round the building, so features can line up with
## its window columns and shop bays).
static func _face(t: Array, k: int) -> Array:
	var w: float = t[2] - t[0]
	var d: float = t[3] - t[1]
	match k:
		0: return [Vector3(t[0], 0, t[3]), Vector3.RIGHT, Vector3.BACK, w, 0.0]
		1: return [Vector3(t[2], 0, t[3]), Vector3.FORWARD, Vector3.RIGHT, d, w]
		2: return [Vector3(t[2], 0, t[1]), Vector3.LEFT, Vector3.FORWARD, w, w + d]
	return [Vector3(t[0], 0, t[1]), Vector3.BACK, Vector3.LEFT, d, w * 2.0 + d]


## World box from face-local ranges: along a0..a1, out o0..o1, height y0..y1.
static func _fbox(f: Array, a0: float, a1: float, o0: float, o1: float, y0: float, y1: float) -> AABB:
	var org: Vector3 = f[0]
	var p: Vector3 = org + (f[1] as Vector3) * a0 + (f[2] as Vector3) * o0
	var q: Vector3 = org + (f[1] as Vector3) * a1 + (f[2] as Vector3) * o1
	var lo := Vector3(minf(p.x, q.x), y0, minf(p.z, q.z))
	var hi := Vector3(maxf(p.x, q.x), y1, maxf(p.z, q.z))
	return AABB(lo, hi - lo)


static func _fpt(f: Array, a: float, o: float, y: float) -> Vector3:
	return (f[0] as Vector3) + (f[1] as Vector3) * a + (f[2] as Vector3) * o + Vector3(0, y, 0)


## Architectural features of a building, decided from its seed (so the mesher
## and the collision agree without storing anything): fire escapes, entrance
## portals and canopies, glass fins, chimneys and crowns.
##   draw: [[AABB, Color]] solid boxes   beams: [[a, b, w, h, Color]]
##   col:  [AABB] what you stand on / bump into (covers draw and beams)
static func features(b: Dictionary) -> Dictionary:
	if b.has("_features"):
		return b["_features"]
	var out := _clear_of_apt(b, _features(b))
	b["_features"] = out  # (the mesher, awnings and collision all ask)
	return out


static func _features(b: Dictionary) -> Dictionary:
	# col: collides for everyone; col_human: solid for people only
	# (CityWorld.HUMAN_LAYER) – detail added after the courses were recorded,
	# so bots and recorded flights don't depend on it.
	var out := {"draw": [], "beams": [], "col": [], "col_human": []}
	if not _parapeted(b) or b["kind"] != "normal" or b.has("shape"):
		return out  # (shaped plans: the form is the feature; nothing hangs off a cut corner)
	var rng := RandomNumberGenerator.new()
	rng.seed = int(float(b["seed"]) * 7919.0 * 1000.0) ^ 0x5f3
	var style := int(b["style"])
	var t0: Array = b["tiers"][0]
	var col: Color = b["color"]
	var trim := trim_color(b)
	var single := (b["tiers"] as Array).size() == 1
	var base := base_of(b)
	var h0: float = float(t0[5]) - base  # storeys above the terrace
	# Fire escapes: brick flats and warehouses, 2nd floor to the top floor.
	if style in [CityLayout.Style.BRICK, CityLayout.Style.WAREHOUSE] and _on_ground(b, t0) \
			and h0 > 13.0 and h0 < 75.0 and rng.randf() < 0.7:
		var n := 1 + int(rng.randf() < 0.35)
		var iron: Color = IRON[rng.randi() % IRON.size()]
		var first := rng.randi() % 4
		for i in n:
			var k := (first + i * 2) % 4
			_fire_escape(out, _face(t0, k), style, h0, iron, rng, base)
	# Balconies on blocks of flats: stacks in front of every other window
	# bay up the longest face (and its opposite if long), slab + railing,
	# from the first floor over the shops to below the cornice.
	var flats := style in [CityLayout.Style.MODERN, CityLayout.Style.SANDSTONE] \
		or style == CityLayout.Style.BRICK and h0 >= 75.0
	var brng := RandomNumberGenerator.new()
	brng.seed = int(float(b["seed"]) * 4099.0 * 1000.0) ^ 0xba1c
	if flats and _on_ground(b, t0) and h0 > 14.0 and h0 < 120.0 and brng.randf() < 0.55:
		_balconies(out, b, t0, style, h0, base, brng)
	# Entrances: a stone portal on masonry, a steel canopy on modern/glass.
	if _on_ground(b, t0) and h0 > 24.0 and style != CityLayout.Style.WAREHOUSE:
		var k := 0
		var best := 0.0
		for kk in 4:
			var L: float = _face(t0, kk)[3]
			if L > best + 0.5:
				best = L
				k = kk
		if best > 18.0:
			var part := {"draw": [], "beams": [], "col": []}
			_portal(part, _face(t0, k), style, col, trim, rng)
			_raise_into(out, part, base)
	# Fins up the glass towers (a vertical rhythm the shader alone can't give).
	if _glassy(b) and rng.randf() < 0.6:
		var fin_col := trim.darkened(rng.randf_range(0.0, 0.5))
		for t in b["tiers"]:
			if float(t[5]) - float(t[4]) < 24.0:
				continue
			var y0: float = maxf(float(t[4]), base + 4.6)
			var y1: float = float(t[5]) - cornice_h(b) * 0.5
			for k in 4:
				var f := _face(t, k)
				var L: float = f[3]
				var u0: float = f[4]
				var m := ceili((u0 + 0.9) / 3.2)
				while m * 3.2 - u0 < L - 0.9:
					var a := m * 3.2 - u0
					out["draw"].append([_fbox(f, a - 0.07, a + 0.07, 0.0, FIN_OUT, y0, y1), fin_col, f[2]])
					m += 1
			out["col"].append(_aabb(t[0] - FIN_OUT, t[1] - FIN_OUT, t[2] + FIN_OUT, t[3] + FIN_OUT, y0, y1))
	var tt: Array = b["tiers"][-1]
	var ry := roof_y(b) - crown_h(b)  # (the tier's own roof)
	var o := cornice_out(b)
	# Chimney stacks near the corners of brick roofs.
	if style in [CityLayout.Style.BRICK, CityLayout.Style.SANDSTONE] and float(tt[5]) < 60.0:
		var stack := col.darkened(0.25)
		for c in 4:
			if rng.randf() > 0.45:
				continue
			var f := _face(tt, c)
			var a := 1.2 + rng.randf_range(0.0, 0.4)
			var hgt := rng.randf_range(1.6, 2.8)
			var bx := _fbox(f, a - 0.45, a + 0.45, -1.4, -0.6, ry, ry + hgt)
			out["draw"].append([bx, stack])
			var cap := bx.grow(0.08)
			cap.position.y = ry + hgt
			cap.size.y = 0.18
			out["draw"].append([cap, trim])
			out["col"].append(AABB(cap.position - Vector3(0, hgt, 0), Vector3(cap.size.x, hgt + 0.18, cap.size.z)))
	# Glass crowns: the curtain wall carries on past the roof as a screen with
	# a light coping band, so each tower ends in its own cap (and the plant
	# behind it is hidden).
	if crown_h(b) > 0.0:
		var ch2 := crown_h(b)
		var scr := trim.darkened(rng.randf_range(0.25, 0.55))
		var x0: float = float(tt[0]) - o
		var z0: float = float(tt[1]) - o
		var x1: float = float(tt[2]) + o
		var z1: float = float(tt[3]) + o
		var rings: Array[AABB] = []
		_ring(rings, x0, z0, x1, z1, ry, ry + ch2, 0.3)
		for r in rings:
			out["draw"].append([r, scr, "far"])
			out["col"].append(r)
		# The deck across the top: the roof you land on.
		var deck := _aabb(x0 + 0.3, z0 + 0.3, x1 - 0.3, z1 - 0.3, ry + ch2 - 0.3, ry + ch2)
		out["draw"].append([deck, ROOF_COLORS[int(float(b["seed"]) * 997.0) % 4], "far", "roof"])
		out["col"].append(deck)
		var caps: Array[AABB] = []
		_ring(caps, x0 - 0.05, z0 - 0.05, x1 + 0.05, z1 + 0.05, ry + ch2, ry + ch2 + PARAPET, 0.4)
		for r in caps:
			out["draw"].append([r, trim.lightened(0.25), "far"])
			out["col"].append(r)
	# Crowns: tall corner piers and low mid-edge finials over the parapet of
	# deco/stone towers.
	if style in [CityLayout.Style.DECO, CityLayout.Style.STONE] and float(tt[5]) > 70.0 \
			and float(tt[2]) - float(tt[0]) > 14.0 and float(tt[3]) - float(tt[1]) > 14.0:
		var ph := rng.randf_range(3.5, 6.0)
		var pc := trim.lightened(0.08)
		for k in 4:
			var f := _face(tt, k)
			var L: float = f[3]
			for a in [-o + 0.0, L * 0.5 - 0.6]:
				var w := 1.6 if a < 0.0 else 1.2
				# Mid-edge finials stay low (≤ 1.1 m): they stood where you land
				# and blocked the roof; the mantle carries you over this height.
				var bx := _fbox(f, a, a + w, -w + o, o, ry, ry + (ph if a < 0.0 else 1.1))
				out["draw"].append([bx, pc])
				out["col"].append(bx)
	_roof_crowns(out, b, tt, ry, style, trim)
	# Facade depth follows the architectural family: paired slender bronze
	# blades on office towers; stone piers on tall masonry. Shared collision
	# and opening filtering keep apartments and climbing geometry aligned.
	if h0 > 85.0:
		for tier: Array in b["tiers"]:
			for k in 4:
				var face := _face(tier, k)
				var length: float = face[3]
				var count := maxi(2, int(length / 7.0))
				for i in range(1, count):
					var a := length * float(i) / count
					var depth := 0.34 if _glassy(b) else 0.22
					var width := 0.18 if _glassy(b) else 0.42
					var rib := _fbox(face, a - width, a + width, -0.08, depth,
						float(tier[4]) + 1.2, float(tier[5]) - 0.8)
					out["draw"].append([rib, Color(0.32, 0.29, 0.23) if _glassy(b) else trim])
					out["col_human"].append(rib)
	return out


## Roof tops with character (own random stream, so nothing else moves):
## supertall towers (> 150 m – no tokens, spawns or jobs up there) get a
## spire, a helipad or a louvred plant crown with a mast, drawn at every LOD
## for the skyline; mid-rise masonry and modern blocks may get a roof garden
## (low planters inside the parapet, trees, a pergola) – all kept to the
## edges so the middle of the roof stays clear to land on.
static func _roof_crowns(out: Dictionary, b: Dictionary, tt: Array, ry: float, style: int, trim: Color) -> void:
	if crown_h(b) > 0.0 or b.has("apt"):
		return
	var crng := RandomNumberGenerator.new()
	crng.seed = int(float(b["seed"]) * 2753.0 * 1000.0) ^ 0xc70
	var x0: float = tt[0]
	var z0: float = tt[1]
	var x1: float = tt[2]
	var z1: float = tt[3]
	var w := x1 - x0
	var d := z1 - z0
	var cx := (x0 + x1) * 0.5
	var cz := (z0 + z1) * 0.5
	var hgt: float = float(tt[5]) - base_of(b)
	var red := Color(0.95, 0.15, 0.12)
	if hgt > 150.0 and w > 18.0 and d > 18.0:
		match crng.randi() % 3:
			0:
				# Spire: a plinth, a shaft and a needle with an aviation light.
				var pb := _aabb(cx - 2.2, cz - 2.2, cx + 2.2, cz + 2.2, ry, ry + 5.0)
				var sh := _aabb(cx - 1.0, cz - 1.0, cx + 1.0, cz + 1.0, ry + 5.0, ry + 17.0)
				var nd := _aabb(cx - 0.35, cz - 0.35, cx + 0.35, cz + 0.35, ry + 17.0, ry + 17.0 + crng.randf_range(16.0, 30.0))
				for bx in [pb, sh, nd]:
					out["draw"].append([bx, trim.lightened(0.15), "far"])
				out["col"].append(pb)
				out["col"].append(sh)
				out["draw"].append([AABB(Vector3(cx - 0.45, nd.end.y, cz - 0.45), Vector3(0.9, 0.7, 0.9)), red, "far"])
			1:
				# Helipad: a raised deck with a square marking and an H.
				var hw := minf(minf(w, d) * 0.32, 8.5)
				var pad := _aabb(cx - hw, cz - hw, cx + hw, cz + hw, ry, ry + 0.6)
				out["draw"].append([pad, Color(0.22, 0.23, 0.25), "far", "roof"])
				out["col"].append(pad)
				var mk: Array[AABB] = []
				_ring(mk, cx - hw * 0.8, cz - hw * 0.8, cx + hw * 0.8, cz + hw * 0.8, ry + 0.6, ry + 0.63, 0.35)
				for r in mk:
					out["draw"].append([r, Color(0.95, 0.8, 0.15)])
				var hs := hw * 0.42
				out["draw"].append([_aabb(cx - hs, cz - hs, cx - hs + 0.6, cz + hs, ry + 0.6, ry + 0.63), Color.WHITE])
				out["draw"].append([_aabb(cx + hs - 0.6, cz - hs, cx + hs, cz + hs, ry + 0.6, ry + 0.63), Color.WHITE])
				out["draw"].append([_aabb(cx - hs, cz - 0.3, cx + hs, cz + 0.3, ry + 0.6, ry + 0.63), Color.WHITE])
				for p in [Vector2(cx - hw, cz - hw), Vector2(cx + hw, cz - hw), Vector2(cx + hw, cz + hw), Vector2(cx - hw, cz + hw)]:
					out["draw"].append([_aabb(p.x - 0.2, p.y - 0.2, p.x + 0.2, p.y + 0.2, ry + 0.6, ry + 0.9), Color(0.4, 1.0, 0.5)])
			_:
				# Plant crown: a louvred box set back from the edges, a mast.
				var ix := w * 0.24
				var iz := d * 0.24
				var bx := _aabb(x0 + ix, z0 + iz, x1 - ix, z1 - iz, ry, ry + 6.0)
				out["draw"].append([bx, trim.darkened(0.45), "far"])
				out["col"].append(bx)
				for k in 4:
					var y := ry + 1.0 + k * 1.3
					var lv := _aabb(x0 + ix - 0.08, z0 + iz - 0.08, x1 - ix + 0.08, z1 - iz + 0.08, y, y + 0.25)
					out["draw"].append([lv, trim.lightened(0.1), "far"])
				var mx := x1 - ix - 1.2
				var mz := z1 - iz - 1.2
				var mast := _aabb(mx - 0.3, mz - 0.3, mx + 0.3, mz + 0.3, ry + 6.0, ry + 6.0 + crng.randf_range(12.0, 22.0))
				out["draw"].append([mast, Color(0.75, 0.75, 0.77), "far"])
				out["draw"].append([AABB(Vector3(mx - 0.4, mast.end.y, mz - 0.4), Vector3(0.8, 0.6, 0.8)), red, "far"])
		return
	if hgt > 40.0 and hgt <= 150.0 and w > 16.0 and d > 16.0 and style in [CityLayout.Style.BRICK,
			CityLayout.Style.MODERN, CityLayout.Style.SANDSTONE, CityLayout.Style.STONE] and crng.randf() < 0.3:
		# Roof garden along two opposite edges, inside the parapet.
		var soil := Color(0.36, 0.27, 0.2)
		var leaf := [Color(0.22, 0.42, 0.2), Color(0.3, 0.5, 0.24), Color(0.5, 0.6, 0.25)]
		var along_x := w >= d
		for e: float in [0.0, 1.0]:
			var pl: AABB
			if along_x:
				var zz := z0 + 0.45 if e == 0.0 else z1 - 1.45
				pl = _aabb(x0 + 1.5, zz, x1 - 1.5, zz + 1.0, ry, ry + 0.34)
			else:
				var xx := x0 + 0.45 if e == 0.0 else x1 - 1.45
				pl = _aabb(xx, z0 + 1.5, xx + 1.0, z1 - 1.5, ry, ry + 0.34)
			out["draw"].append([pl, trim])
			out["col"].append(pl)
			var top := pl
			top.position.y = ry + 0.34
			top.size.y = 0.3
			out["draw"].append([top.grow(-0.08), leaf[crng.randi() % 3]])
			# A few small trees along it.
			var n := 2 + crng.randi() % 3
			for i in n:
				var t := (i + 0.5) / n
				var p := Vector3(lerpf(pl.position.x, pl.end.x, t), ry, lerpf(pl.position.z, pl.end.z, t))
				out["draw"].append([AABB(p + Vector3(-0.1, 0.34, -0.1), Vector3(0.2, 1.4, 0.2)), Color(0.35, 0.25, 0.18)])
				var cs := crng.randf_range(1.1, 1.7)
				out["draw"].append([AABB(p + Vector3(-cs * 0.5, 1.5, -cs * 0.5), Vector3(cs, cs * 0.9, cs)), leaf[crng.randi() % 3]])
		# Pergola in a corner of the other edge.
		var px := x0 + 1.0 if crng.randf() < 0.5 else x1 - 5.0
		var pz := z0 + 1.0 if not along_x else (z0 + d * 0.5 - 2.0)
		if along_x:
			px = x0 + 1.0 if crng.randf() < 0.5 else x1 - 5.0
		var wood := Color(0.48, 0.34, 0.22)
		for q in [Vector2(px, pz), Vector2(px + 4.0, pz), Vector2(px, pz + 4.0), Vector2(px + 4.0, pz + 4.0)]:
			out["draw"].append([_aabb(q.x, q.y, q.x + 0.18, q.y + 0.18, ry, ry + 2.5), wood])
		for i in 6:
			var sx := px + i * 0.8
			out["draw"].append([_aabb(sx, pz - 0.2, sx + 0.12, pz + 4.4, ry + 2.5, ry + 2.65), wood])


## Appends `part`'s pieces to `out`, raised by dy (pieces built from 0).
static func _raise_into(out: Dictionary, part: Dictionary, dy: float) -> void:
	var up := Vector3(0, dy, 0)
	for d in part["draw"]:
		var bx: AABB = d[0]
		var nd: Array = d.duplicate()
		nd[0] = AABB(bx.position + up, bx.size)
		out["draw"].append(nd)
	for bm in part["beams"]:
		out["beams"].append([bm[0] + up, bm[1] + up, bm[2], bm[3], bm[4]])
	for bx: AABB in part["col"]:
		out["col"].append(AABB(bx.position + up, bx.size))


const BALCONY_CELLS := {CityLayout.Style.BRICK: Vector2(3.2, 3.0), CityLayout.Style.MODERN: Vector2(2.6, 3.6),
	CityLayout.Style.SANDSTONE: Vector2(3.6, 4.2)}


static func _balconies(out: Dictionary, b: Dictionary, t0: Array, style: int, h0: float, base: float,
		rng: RandomNumberGenerator) -> void:
	var cell: Vector2 = BALCONY_CELLS[style]
	var depth := 1.25 if style == CityLayout.Style.MODERN else 1.05
	var slab_c := Color(0.68, 0.67, 0.64) if style != CityLayout.Style.BRICK else Color(0.6, 0.58, 0.55)
	var rail_c := Color(0.32, 0.38, 0.42) if style == CityLayout.Style.MODERN else Color(0.14, 0.15, 0.16)
	var first_floor := ceilf(5.0 / cell.y)
	var top := h0 - cornice_h(b) - 1.4
	var best := 0
	for k in 4:
		if float(_face(t0, k)[3]) > float(_face(t0, best)[3]):
			best = k
	var faces: Array = [best]
	if float(_face(t0, (best + 2) % 4)[3]) > 24.0 and rng.randf() < 0.6:
		faces.append((best + 2) % 4)
	var phase := rng.randi() % 2
	var wb := cell.x * 0.86
	for k in faces:
		var f := _face(t0, k)
		var L: float = f[3]
		var u0: float = f[4]
		var m := ceili(u0 / cell.x)
		while m * cell.x - u0 < L:
			var a := (m + 0.5) * cell.x - u0  # a window bay's centre on this face
			if (m + phase) % 2 == 0 and a - wb * 0.5 > 1.2 and a + wb * 0.5 < L - 1.2:
				var fl := first_floor
				var y_first := -1.0
				var y_last := -1.0
				while fl * cell.y + 1.2 < top:
					var y := base + fl * cell.y
					out["draw"].append([_fbox(f, a - wb * 0.5, a + wb * 0.5, 0.0, depth, y - 0.16, y), slab_c])
					out["draw"].append([_fbox(f, a - wb * 0.5, a + wb * 0.5, depth - 0.06, depth, y, y + 1.05), rail_c])
					if y_first < 0.0:
						y_first = y
					y_last = y
					fl += 1.0
				if y_first > 0.0:
					out["col_human"].append(_fbox(f, a - wb * 0.5, a + wb * 0.5, 0.0, depth, y_first - 0.16, y_last + 1.05))
			m += 1


static func _fire_escape(out: Dictionary, f: Array, style: int, h: float, iron: Color,
		rng: RandomNumberGenerator, base := 0.0) -> void:
	var L: float = f[3]
	var u0: float = f[4]
	if L < 12.0:
		return
	var col_w := 4.0 if style == CityLayout.Style.WAREHOUSE else 3.2
	var floor_h := 4.4 if style == CityLayout.Style.WAREHOUSE else 3.0
	var sill := 1.0 if style == CityLayout.Style.WAREHOUSE else 0.6
	# Centred on a window-column boundary, so it spans two windows.
	var c := roundf((u0 + rng.randf_range(4.0, L - 4.0)) / col_w) * col_w - u0
	var hw := col_w + 0.2
	if c - hw < 1.2 or c + hw > L - 1.2:
		return
	var d := ESCAPE_DEPTH
	var levels: Array[float] = []
	var k := 2 if style != CityLayout.Style.WAREHOUSE else 1
	while k * floor_h + sill < h - 3.2:
		levels.append(base + k * floor_h + sill)
		k += 1
	if levels.size() < 2:
		return
	for i in levels.size():
		var y: float = levels[i]
		out["draw"].append([_fbox(f, c - hw, c + hw, 0.0, d, y - 0.08, y), iron])
		var r := 1.0
		out["beams"].append([_fpt(f, c - hw, d - 0.03, y + r), _fpt(f, c + hw, d - 0.03, y + r), 0.06, 0.06, iron])
		for e in [c - hw + 0.03, c + hw - 0.03]:
			out["beams"].append([_fpt(f, e, 0.05, y + r), _fpt(f, e, d - 0.03, y + r), 0.06, 0.06, iron])
			out["beams"].append([_fpt(f, e, d - 0.03, y), _fpt(f, e, d - 0.03, y + r), 0.05, 0.05, iron])
		if i + 1 < levels.size():
			# Zig-zag stair to the next platform, against the wall.
			var y2: float = levels[i + 1]
			var lr := 1.0 if i % 2 == 0 else -1.0
			var a := _fpt(f, c - lr * (hw - 0.4), 0.45, y)
			var e2 := _fpt(f, c + lr * (hw - 1.3), 0.45, y2 - 0.08)
			out["beams"].append([a, e2, 0.7, 0.07, iron])
			out["beams"].append([a + Vector3.UP * 0.9 + (f[2] as Vector3) * 0.32, e2 + Vector3.UP * 0.9 + (f[2] as Vector3) * 0.32,
				0.04, 0.04, iron])
	var ya: float = levels[0]
	var yb: float = levels[-1]
	out["col"].append(_fbox(f, c - hw, c + hw, 0.0, d, ya - 0.08, yb))
	out["col"].append(_fbox(f, c - hw, c + hw, d - 0.1, d, yb, yb + 1.0))
	out["col"].append(_fbox(f, c - hw, c - hw + 0.1, 0.0, d, yb, yb + 1.0))
	out["col"].append(_fbox(f, c + hw - 0.1, c + hw, 0.0, d, yb, yb + 1.0))
	# Counterweighted drop ladder under the lowest platform.
	var lx := c + hw - 0.7
	for s2 in [-0.22, 0.22]:
		out["beams"].append([_fpt(f, lx + s2, d - 0.2, ya - 2.3), _fpt(f, lx + s2, d - 0.2, ya), 0.05, 0.05, iron])
	for j in 3:
		var yy := ya - 2.0 + j * 0.8
		out["beams"].append([_fpt(f, lx - 0.22, d - 0.2, yy), _fpt(f, lx + 0.22, d - 0.2, yy), 0.03, 0.03, iron])
	out["col"].append(_fbox(f, lx - 0.27, lx + 0.27, d - 0.25, d - 0.15, ya - 2.3, ya))


static func _portal(out: Dictionary, f: Array, style: int, col: Color, trim: Color,
		rng: RandomNumberGenerator) -> void:
	var L: float = f[3]
	var u0: float = f[4]
	# On a shop-bay centre (the shader draws the door there), near the middle.
	var bay := roundf((u0 + L * 0.5 - 3.0) / 6.0)
	var c := bay * 6.0 + 3.0 - u0
	if c < 5.0 or c > L - 5.0:
		return
	var glassy := style == CityLayout.Style.GLASS or style == CityLayout.Style.DARK_GLASS
	var door := Color(0.07, 0.08, 0.1)
	if glassy or style == CityLayout.Style.MODERN:
		# Cantilevered steel-and-glass canopy over a full-height glazed lobby.
		var steel := Color(0.78, 0.8, 0.82) if rng.randf() < 0.5 else Color(0.16, 0.17, 0.19)
		var cw := rng.randf_range(4.5, 6.5)
		out["draw"].append([_fbox(f, c - 2.8, c + 2.8, 0.0, 0.2, 0.0, 4.3), door])
		var can := _fbox(f, c - cw, c + cw, 0.0, 3.2, 4.4, 4.75)
		out["draw"].append([can, steel])
		out["col"].append(_fbox(f, c - 2.8, c + 2.8, 0.0, 0.2, 0.0, 4.3))
		out["col"].append(can)
		return
	# Classical portal: two pilasters, entablature and a cornice cap.
	var stone := Color(0.7, 0.64, 0.55) if style == CityLayout.Style.BRICK else col.lightened(0.04)
	var pw := 1.0
	var ph := rng.randf_range(5.6, 6.6)
	var parts := [
		[_fbox(f, c - 2.6 - pw, c - 2.6, 0.0, 0.55, 0.0, ph), stone],
		[_fbox(f, c + 2.6, c + 2.6 + pw, 0.0, 0.55, 0.0, ph), stone],
		[_fbox(f, c - 2.9 - pw, c + 2.9 + pw, 0.0, 0.7, ph, ph + 1.1), stone],
		[_fbox(f, c - 3.1 - pw, c + 3.1 + pw, 0.0, 0.88, ph + 1.1, ph + 1.35), stone.lightened(0.08)],
		[_fbox(f, c - 2.6, c + 2.6, 0.0, 0.18, 0.0, ph - 0.9), door],
		[_fbox(f, c - 2.6, c + 2.6, 0.0, 0.12, ph - 0.9, ph), stone.darkened(0.25)],
	]
	for pt in parts:
		out["draw"].append(pt)
		out["col"].append(pt[0])
	# Brass lamps either side of the door.
	for e in [c - 2.6 - pw * 0.5, c + 2.6 + pw * 0.5]:
		out["draw"].append([_fbox(f, e - 0.14, e + 0.14, 0.55, 0.85, 3.0, 3.5), Color(0.95, 0.78, 0.4)])
		out["col"].append(_fbox(f, e - 0.14, e + 0.14, 0.55, 0.85, 3.0, 3.5))


## A billboard's legs and its catwalk, as _add_sign draws them.
static func _sign_boxes(b: Dictionary, out: Array[AABB]) -> void:
	var t: Array = b["tiers"][0]
	var roof: float = b.get("roof", float(t[4]) - 2.6)
	var along_x: bool = t[2] - t[0] > t[3] - t[1]
	var length: float = (t[2] - t[0]) if along_x else (t[3] - t[1])
	var n := maxi(2, int(length / 5.0) + 1)
	for i in n:
		var u := lerpf(0.1, 0.9, i / float(n - 1))
		var x: float = lerpf(t[0], t[2], u) if along_x else (t[0] + t[2]) * 0.5
		var z: float = (t[1] + t[3]) * 0.5 if along_x else lerpf(t[1], t[3], u)
		out.append(_aabb(x - 0.125, z - 0.125, x + 0.125, z + 0.125, roof, t[4]))
	var cx: float = (t[0] + t[2]) * 0.5
	var cz: float = (t[1] + t[3]) * 0.5
	var y: float = float(t[4]) - 0.1
	if along_x:
		out.append(_aabb(cx - length * 0.5, cz + 0.27 - 0.45, cx + length * 0.5, cz + 0.27 + 0.45, y - 0.06, y + 0.06))
	else:
		out.append(_aabb(cx + 0.27 - 0.45, cz - length * 0.5, cx + 0.27 + 0.45, cz + length * 0.5, y - 0.06, y + 0.06))


static func _aabb(x0: float, z0: float, x1: float, z1: float, y0: float, y1: float) -> AABB:
	return AABB(Vector3(x0, y0, z0), Vector3(x1 - x0, y1 - y0, z1 - z0))


## Four thin walls of thickness t just inside the rectangle.
static func _ring(out: Array[AABB], x0: float, z0: float, x1: float, z1: float, y0: float, y1: float, t: float) -> void:
	out.append(_aabb(x0, z0, x1, z0 + t, y0, y1))
	out.append(_aabb(x0, z1 - t, x1, z1, y0, y1))
	out.append(_aabb(x0, z0 + t, x0 + t, z1 - t, y0, y1))
	out.append(_aabb(x1 - t, z0 + t, x1, z1 - t, y0, y1))


## Low lip round a roof edge: outer and inner faces plus a top ring.
func _parapet(x0: float, z0: float, x1: float, z1: float, y: float, col: Color) -> void:
	var t := PARAPET_T
	var y1 := y + PARAPET
	walls(x0, z0, x1, z1, y, y1, col, KIND_TRIM, 0, 0)
	_inner_walls(Rect2(x0 + t, z0 + t, x1 - x0 - t * 2.0, z1 - z0 - t * 2.0), y, y1, col.darkened(0.15), KIND_TRIM)
	top(x0, z0, x1, z0 + t, y1, col, KIND_TRIM, 0, 0)
	top(x0, z1 - t, x1, z1, y1, col, KIND_TRIM, 0, 0)
	top(x0, z0 + t, x0 + t, z1 - t, y1, col, KIND_TRIM, 0, 0)
	top(x1 - t, z0 + t, x1, z1 - t, y1, col, KIND_TRIM, 0, 0)


## Projecting stone courses every few floors (relief the shader can't fake).
func _ledges(x0: float, z0: float, x1: float, z1: float, y0: float, y1: float, col: Color, style: float,
		seed: float, base := 0.0) -> void:
	var y := base + (floorf((y0 - base) / LEDGE_EVERY) + 1.0) * LEDGE_EVERY
	while y < y1 - 4.0:
		var o := LEDGE_OUT
		walls(x0 - o, z0 - o, x1 + o, z1 + o, y, y + 0.32, col, KIND_TRIM, style, seed)
		bottom(x0 - o, z0 - o, x1 + o, z1 + o, y, col.darkened(0.25), KIND_TRIM, style, seed)
		top(x0 - o, z0 - o, x1 + o, z1 + o, y + 0.32, col.lightened(0.1), KIND_TRIM, style, seed)
		y += LEDGE_EVERY


## Shop awnings along the ground floor of masonry buildings, in runs with
## gaps, colours per shop: [a, b, out, colour] (a on the left looking out).
## Solid: collision_boxes() makes a slab of each, so you can land on them.
static func awning_runs(b: Dictionary) -> Array:
	var out_runs: Array = []
	if b.has("shape") or not _has_plinth(b, 0) or not _parapeted(b) or int(b["style"]) not in [CityLayout.Style.BRICK,
			CityLayout.Style.STONE, CityLayout.Style.SANDSTONE, CityLayout.Style.DECO]:
		return out_runs
	var t: Array = b["tiers"][0]
	var x0: float = t[0]
	var z0: float = t[1]
	var x1: float = t[2]
	var z1: float = t[3]
	var avoid: Array = []  # entrance portals take the ground floor where they stand
	for bx: AABB in features(b)["col"]:
		if bx.position.y < base_of(b) + AWNING_Y + 1.0:
			avoid.append(bx.grow(0.6))
	var rng := RandomNumberGenerator.new()
	rng.seed = int(float(b["seed"]) * 1000003.0) ^ 0xa3
	var out := AWNING_OUT
	var y := base_of(b) + AWNING_Y
	for side in 4:
		var along_x := side % 2 == 0
		var a := x0 if along_x else z0
		var bb := x1 if along_x else z1
		var d := a + 1.5
		while d + 4.0 < bb - 1.5:
			var w := rng.randf_range(3.5, 6.0)
			if rng.randf() < 0.55 and d + w < bb - 1.5:
				var col: Color = AWNING_COLORS[rng.randi() % AWNING_COLORS.size()]
				var e := d + w
				var span: AABB
				match side:
					0, 2: span = _aabb(d, (z0 if side == 0 else z1) - out, e, (z0 if side == 0 else z1) + out, y - 0.75, y + 0.75)
					_: span = _aabb((x1 if side == 1 else x0) - out, d, (x1 if side == 1 else x0) + out, e, y - 0.75, y + 0.75)
				if avoid.any(func(a2: AABB) -> bool: return a2.intersects(span)):
					d += w + rng.randf_range(0.6, 2.5)
					continue
				match side:
					0: out_runs.append([Vector3(d, y, z0), Vector3(e, y, z0), Vector3.FORWARD * out, col])
					1: out_runs.append([Vector3(x1, y, d), Vector3(x1, y, e), Vector3.RIGHT * out, col])
					2: out_runs.append([Vector3(e, y, z1), Vector3(d, y, z1), Vector3.BACK * out, col])
					3: out_runs.append([Vector3(x0, y, e), Vector3(x0, y, d), Vector3.LEFT * out, col])
			d += w + rng.randf_range(0.6, 2.5)
	return out_runs


## One awning from wall points a→b (a on the left looking out), sticking out
## by `out`: canopy top and underside, a front valance. 6 triangles.
func _awning(a: Vector3, b: Vector3, out: Vector3, col: Color, drop: Color) -> void:
	var n := out.normalized()
	var up := Vector3.UP * 0.18
	var fa := a + out
	var fb := b + out
	# (Clockwise from the visible side, like top(): a → fa → fb → b from above.)
	quad(a + up, fa + up, fb + up, b + up, Vector3.UP, Vector2.ZERO, Vector2.ZERO, Vector2.ZERO, Vector2.ZERO,
		col, KIND_TRIM, 0, 0)
	quad(a, b, fb, fa, Vector3.DOWN, Vector2.ZERO, Vector2.ZERO, Vector2.ZERO, Vector2.ZERO,
		col.darkened(0.3), KIND_TRIM, 0, 0)
	quad(fa + up, fa + Vector3.DOWN * 0.38, fb + Vector3.DOWN * 0.38, fb + up, n, Vector2.ZERO, Vector2.ZERO,
		Vector2.ZERO, Vector2.ZERO, drop, KIND_TRIM, 0, 0)


static func tiers_top(b: Dictionary) -> float:
	return b["tiers"][-1][5]


func _add_sign(b: Dictionary, detailed: bool) -> void:
	var t: Array = b["tiers"][0]
	var col: Color = b["color"]
	walls(t[0], t[1], t[2], t[3], t[4], t[5], col, KIND_SIGN, 0, b["seed"], 0.0)
	top(t[0], t[1], t[2], t[3], t[5], STEEL, KIND_TRIM, 0, 0)
	bottom(t[0], t[1], t[2], t[3], t[4], STEEL, KIND_TRIM, 0, 0)
	if not detailed:
		return
	var roof: float = b.get("roof", t[4] - 2.6)
	var along_x: bool = t[2] - t[0] > t[3] - t[1]
	var length: float = (t[2] - t[0]) if along_x else (t[3] - t[1])
	var n := maxi(2, int(length / 5.0) + 1)
	for i in n:
		var u := lerpf(0.1, 0.9, i / float(n - 1))
		var x: float = lerpf(t[0], t[2], u) if along_x else (t[0] + t[2]) * 0.5
		var z: float = (t[1] + t[3]) * 0.5 if along_x else lerpf(t[1], t[3], u)
		beam(Vector3(x, roof, z), Vector3(x, t[4], z), 0.25, 0.25, STEEL)
	# Catwalk along the bottom edge.
	var o := Vector3(0, 0, 0.9) if along_x else Vector3(0.9, 0, 0)
	var c := Vector3((t[0] + t[2]) * 0.5, t[4] - 0.1, (t[1] + t[3]) * 0.5)
	var half := Vector3(length * 0.5, 0, 0) if along_x else Vector3(0, 0, length * 0.5)
	beam(c - half + o * 0.3, c + half + o * 0.3, 0.9, 0.12, STEEL)
	# A steel frame round the panel (proud of both faces), braces down to the
	# roof behind it, and gooseneck floodlights reaching out over the advert.
	var f2: Vector2 = b.get("face", Vector2(o.x, o.z).normalized())
	var fwd := Vector3(f2.x, 0, f2.y)
	var thick := 0.6
	var mid := Vector3((t[0] + t[2]) * 0.5, 0, (t[1] + t[3]) * 0.5)
	var ytop: float = t[5]
	var ybot: float = t[4]
	var dark := STEEL.darkened(0.35)
	for side: float in [1.0, -1.0]:
		var off := fwd * (thick * 0.5 + 0.06) * side
		var top_c := Vector3(mid.x, ytop - 0.12, mid.z) + off
		var bot_c := Vector3(mid.x, ybot + 0.12, mid.z) + off
		beam(top_c - half, top_c + half, 0.24, 0.24, dark)
		beam(bot_c - half, bot_c + half, 0.24, 0.24, dark)
		for e: float in [-1.0, 1.0]:
			var post := Vector3(mid.x, 0, mid.z) + half * e * 0.995 + off
			beam(Vector3(post.x, ybot, post.z), Vector3(post.x, ytop, post.z), 0.24, 0.24, dark)
	var back := -fwd
	var nl := maxi(2, int(length / 4.5))
	for i in nl:
		var u := lerpf(-0.42, 0.42, i / float(nl - 1))
		var at := Vector3(mid.x, 0, mid.z) + half * 2.0 * u
		if i % 2 == 0:
			beam(at + back * 0.3 + Vector3(0, ytop - 1.0, 0), at + back * 2.6 + Vector3(0, roof, 0), 0.14, 0.14, STEEL)
		# Gooseneck: up from the bottom rail, out over the face, a lamp head.
		var root := at + fwd * (thick * 0.5 + 0.1) + Vector3(0, ybot + 0.1, 0)
		var elbow := root + fwd * 1.4 + Vector3(0, 0.55, 0)
		beam(root, elbow, 0.11, 0.11, dark)
		var head := elbow + fwd * 0.05 + Vector3(0, 0.3, 0)
		beam(elbow - Vector3(0, 0.05, 0), head, 0.55, 0.3, Color(0.12, 0.12, 0.13))


## Construction frame: open floor slabs, columns, a safety-net band on the top floors.
func _add_frame(b: Dictionary, detailed: bool) -> void:
	var tiers: Array = b["tiers"]
	var t0: Array = tiers[0]
	var bc := base_course(b)
	if bc.has_volume():
		solid(bc.position.x, bc.position.z, bc.end.x, bc.end.z, bc.position.y, bc.end.y, CONCRETE.darkened(0.2))
	for t in tiers:
		solid(t[0], t[1], t[2], t[3], t[4], t[5], CONCRETE)
	if not detailed:
		return
	var ytop: float = tiers[-1][5]
	var base: float = b.get("base", 0.0)
	var nx := maxi(2, int((t0[2] - t0[0]) / 8.0) + 1)
	var nz := maxi(2, int((t0[3] - t0[1]) / 8.0) + 1)
	for i in nx:
		for j in nz:
			if i != 0 and i != nx - 1 and j != 0 and j != nz - 1:
				continue  # perimeter columns only
			var x: float = lerpf(t0[0] + 0.5, t0[2] - 0.5, i / float(nx - 1))
			var z: float = lerpf(t0[1] + 0.5, t0[3] - 0.5, j / float(nz - 1))
			beam(Vector3(x, base, z), Vector3(x, ytop + 3.0, z), 0.6, 0.6, CONCRETE.darkened(0.12))
	# Hoarding round the site at street level, safety screens on the top two floors.
	_frame_barrier(t0, 1.5, base, base + 2.6, Color(0.2, 0.36, 0.3))
	# Edge-protection barrier round the working floor.
	_frame_barrier(t0, 0.2, ytop + 0.1, ytop + 1.2, Color(0.95, 0.55, 0.15))


func _frame_barrier(t: Array, outset: float, bottom_y: float, top_y: float, color: Color) -> void:
	# Inner faces and the top cap match the existing 12 cm collision ring.
	# Single outer quads disappeared when viewed from the working floor.
	var boxes: Array[AABB] = []
	_ring(boxes, t[0] - outset, t[1] - outset, t[2] + outset, t[3] + outset, bottom_y, top_y, 0.12)
	for box in boxes:
		solid(box.position.x, box.position.z, box.end.x, box.end.z, box.position.y, box.end.y, color)


## Cranes and the bridge. `detailed` = lattice/girder geometry, else solid massing.
func add_structure(s: Dictionary, detailed: bool) -> void:
	var first := verts.size()
	_structure(s, detailed)
	# Structures are specified from street level 0; y0 lifts them onto their
	# block's terrace (CityLayout._lift).
	var dy: float = s.get("y0", 0.0)
	if dy != 0.0:
		for i in range(first, verts.size()):
			verts[i].y += dy


func _structure(s: Dictionary, detailed: bool) -> void:
	match s["type"]:
		"tower_crane":
			_tower_crane(s, detailed)
		"quay_crane":
			_quay_crane(s, detailed)
		"bridge":
			_bridge(s, detailed)
		"kit":
			_kit(s, detailed)


## Set pieces (SetPieces): boxes, beams and prisms; the far LOD drops thin beams.
func _kit(s: Dictionary, detailed: bool) -> void:
	for v in s["solids"]:
		solid(v[0], v[1], v[2], v[3], v[4], v[5], v[6])
	for v in s["beams"]:
		if detailed or minf(v[2], v[3]) >= 0.45:
			beam(v[0], v[1], v[2], v[3], v[4], KIND_TRIM, true)
	for v in s["prisms"]:
		prism(v[0], v[1], v[2], v[3])


## Vertical prism over a convex polygon given counter-clockwise or clockwise
## in (x, z): side walls, top and bottom.
func prism(pts: PackedVector2Array, y0: float, y1: float, col: Color) -> void:
	var n := pts.size()
	var c := Vector2.ZERO
	for p in pts:
		c += p
	c /= n
	for i in n:
		var a := pts[i]
		var b := pts[(i + 1) % n]
		var mid := (a + b) * 0.5
		var nrm := Vector3(b.y - a.y, 0.0, -(b.x - a.x)).normalized()
		if Vector2(nrm.x, nrm.z).dot(mid - c) < 0.0:
			nrm = -nrm
		var qa := Vector3(a.x, y1, a.y)
		var qb := Vector3(b.x, y1, b.y)
		var qc := Vector3(b.x, y0, b.y)
		var qd := Vector3(a.x, y0, a.y)
		var w := a.distance_to(b)
		if (qb - qa).cross(qc - qa).dot(nrm) > 0.0:
			quad(qa, qd, qc, qb, nrm, Vector2.ZERO, Vector2(0, y1 - y0), Vector2(w, y1 - y0), Vector2(w, 0), col, KIND_TRIM, 0, 0)
		else:
			quad(qa, qb, qc, qd, nrm, Vector2.ZERO, Vector2(w, 0), Vector2(w, y1 - y0), Vector2(0, y1 - y0), col, KIND_TRIM, 0, 0)
		# Top and bottom as fans from the centre.
		var ct := Vector3(c.x, y1, c.y)
		var cb := Vector3(c.x, y0, c.y)
		_tri(ct, qa, qb, Vector3.UP, col)
		_tri(cb, qd, qc, Vector3.DOWN, col.darkened(0.25))


func _tri(a: Vector3, b: Vector3, c: Vector3, n: Vector3, col: Color) -> void:
	if _xf_on:
		a = xf * a
		b = xf * b
		c = xf * c
		n = xf.basis * n
	if (b - a).cross(c - a).dot(n) > 0.0:
		var t := b
		b = c
		c = t
	var i := verts.size()
	verts.append_array([a, b, c])
	normals.append_array([n, n, n])
	var cc := Color(col.r, col.g, col.b, KIND_TRIM / 8.0)
	colors.append_array([cc, cc, cc])
	uvs.append_array([Vector2(a.x, a.z), Vector2(b.x, b.z), Vector2(c.x, c.z)])
	uv2s.append_array([Vector2.ZERO, Vector2.ZERO, Vector2.ZERO])
	indices.append_array([i, i + 1, i + 2])


func _tower_crane(s: Dictionary, detailed: bool) -> void:
	var m := Vector3(s["x"], 0.0, s["z"])
	var h: float = s["h"]
	var d2: Vector2 = s["dir"]
	var d := Vector3(d2.x, 0.0, d2.y)
	var side := Vector3(-d.z, 0.0, d.x)
	var jib: float = s["jib"]
	var counter: float = s["counter"]
	solid(m.x - 3.0, m.z - 3.0, m.x + 3.0, m.z + 3.0, 0.0, 1.2, CONCRETE)
	lattice(m, h, 2.8, CRANE_YELLOW, 4.0, detailed)
	var ytop := m + Vector3.UP * h
	# Slewing unit, cab and tower head.
	solid(m.x - 1.8, m.z - 1.8, m.x + 1.8, m.z + 1.8, h, h + 1.2, STEEL)
	var cab := ytop + side * 2.2 + d * 0.6
	solid(cab.x - 1.2, cab.z - 1.2, cab.x + 1.2, cab.z + 1.2, h - 1.2, h + 1.4, Color(0.92, 0.92, 0.9))
	var apex := ytop + Vector3.UP * 13.0
	lattice(ytop + Vector3.UP * 1.2, 11.8, 1.6, CRANE_YELLOW, 3.0, detailed)
	# Jib and counter-jib.
	var j0 := ytop + Vector3.UP * 1.2
	girder(j0, j0 + d * jib, 2.0, 2.2, CRANE_YELLOW, detailed)
	girder(j0, j0 - d * counter, 3.0, 1.8, CRANE_YELLOW, detailed)
	var back := j0 - d * counter
	var w := back + d * 2.0
	solid(minf(w.x, back.x) - 1.8 * absf(side.x) - 0.1, minf(w.z, back.z) - 1.8 * absf(side.z) - 0.1,
		maxf(w.x, back.x) + 1.8 * absf(side.x) + 0.1, maxf(w.z, back.z) + 1.8 * absf(side.z) + 0.1,
		h - 2.6, h + 1.2, CONCRETE.darkened(0.15))
	# Pendant ties from the head to the jib and counter-jib.
	beam(apex, j0 + Vector3.UP * 2.2 + d * jib * 0.62, 0.12, 0.12, STEEL)
	beam(apex, j0 + Vector3.UP * 1.8 - d * counter * 0.9, 0.12, 0.12, STEEL)
	# Trolley, hoist line and hook block (with a load of steel beams).
	var tr := j0 + d * jib * float(s["trolley"])
	solid(tr.x - 0.8, tr.z - 0.8, tr.x + 0.8, tr.z + 0.8, tr.y - 0.5, tr.y, STEEL)
	var hook_y: float = lerpf(8.0, h - 6.0, float(s["hook"]))
	beam(tr, Vector3(tr.x, hook_y + 1.4, tr.z), 0.07, 0.07, STEEL)
	solid(tr.x - 0.5, tr.z - 0.5, tr.x + 0.5, tr.z + 0.5, hook_y + 0.4, hook_y + 1.4, CRANE_YELLOW)
	# The load of beams (drawn at every distance: it collides at every distance).
	for k in 3:
		var o := side * (k - 1) * 0.5
		beam(Vector3(tr.x, hook_y - 0.5, tr.z) + o - d * 3.0, Vector3(tr.x, hook_y - 0.5, tr.z) + o + d * 3.0,
			0.35, 0.5, Color(0.5, 0.24, 0.16))
	# Red warning light on the head.
	solid(apex.x - 0.3, apex.z - 0.3, apex.x + 0.3, apex.z + 0.3, apex.y, apex.y + 0.5, Color(1.0, 0.15, 0.1))


func _quay_crane(s: Dictionary, detailed: bool) -> void:
	var qx: float = s["x"]
	var z: float = s["z"]
	var ytop: float = s["top"]
	var reach: float = s["reach"]
	var col: Color = s["color"]
	for lx: float in [qx - 3.0, qx + 13.0]:
		for lz: float in [z - 6.0, z + 6.0]:
			solid(lx - 0.8, lz - 0.8, lx + 0.8, lz + 0.8, -2.0, ytop, col)
		beam(Vector3(lx, 4.0, z - 6.0), Vector3(lx, ytop - 4.0, z + 6.0), 0.4, 0.4, col)  # solid: drawn at every distance
		beam(Vector3(lx, 4.0, z + 6.0), Vector3(lx, ytop - 4.0, z - 6.0), 0.4, 0.4, col)
	for lz: float in [z - 6.0, z + 6.0]:
		solid(qx - 3.8, lz - 0.9, qx + 13.8, lz + 0.9, ytop - 4.0, ytop, col)
		solid(qx - 3.8, lz - 0.9, qx + 13.8, lz + 0.9, 7.0, 8.4, col)
	# Boom (out over the water) and back-reach with the machinery house.
	girder(Vector3(qx - 11.0, ytop, z), Vector3(qx + reach, ytop, z), 3.6, 3.0, col, detailed)
	solid(qx - 11.0, z - 2.6, qx - 3.0, z + 2.6, ytop + 3.0, ytop + 7.0, Color(0.9, 0.9, 0.88))
	lattice(Vector3(qx + 4.5, ytop + 3.0, z), 19.0, 2.0, col, 4.0, detailed)
	var apex := Vector3(qx + 4.5, ytop + 22.0, z)
	beam(apex, Vector3(qx + reach * 0.75, ytop + 3.0, z), 0.14, 0.14, STEEL)
	beam(apex, Vector3(qx - 10.0, ytop + 3.0, z), 0.14, 0.14, STEEL)
	# Trolley with a hanging container spreader.
	var tx := qx + reach * 0.6
	solid(tx - 1.5, z - 2.0, tx + 1.5, z + 2.0, ytop - 1.0, ytop, STEEL)
	beam(Vector3(tx, ytop - 1.0, z), Vector3(tx, 14.0, z), 0.08, 0.08, STEEL)
	solid(tx - 6.0, z - 1.3, tx + 6.0, z + 1.3, 11.4, 14.0, [Color(0.2, 0.42, 0.62), Color(0.75, 0.25, 0.15),
		Color(0.2, 0.5, 0.3)][int(absf(z)) % 3])


func _bridge(s: Dictionary, detailed: bool) -> void:
	var zc: float = s["z"]
	var deck: float = s["deck"]
	var ytop: float = s["top"]
	var xe: float = s["x_east"]
	var xw: float = s["x_west"]
	# Deck: road surface, red side girders, railings.
	top(xw, zc - 10.0, xe, zc + 10.0, deck, Color(0.23, 0.24, 0.26), KIND_TRIM, 0, 0)
	bottom(xw, zc - 10.0, xe, zc + 10.0, deck - 2.0, BRIDGE_RED.darkened(0.4), KIND_TRIM, 0, 0)
	for sz: float in [-1.0, 1.0]:
		var z0 := zc + sz * 10.0
		solid(xw, minf(z0, z0 - sz * 1.2), xe, maxf(z0, z0 - sz * 1.2), deck - 2.4, deck + 0.4, BRIDGE_RED)
		if detailed:
			beam(Vector3(xw, deck + 1.2, z0 - sz * 0.4), Vector3(xe, deck + 1.2, z0 - sz * 0.4), 0.12, 0.12, STEEL)
	if detailed:
		# Road: a double yellow centre line, lane dashes, edge lines; raised
		# walkways along both sides.
		for zz: float in [-0.25, 0.25]:
			top(xw, zc + zz - 0.08, xe, zc + zz + 0.08, deck + 0.02, Color(0.92, 0.78, 0.25), KIND_TRIM, 0, 0)
		for sz: float in [-1.0, 1.0]:
			top(xw, zc + sz * 7.5 - 0.08, xe, zc + sz * 7.5 + 0.08, deck + 0.02, Color(0.9, 0.9, 0.86), KIND_TRIM, 0, 0)
			var x := xw
			while x < xe:
				top(x, zc + sz * 3.8 - 0.07, x + 3.0, zc + sz * 3.8 + 0.07, deck + 0.02, Color(0.9, 0.9, 0.86), KIND_TRIM,
					0, 0)
				x += 9.0
			var w0 := zc + sz * 8.0
			solid(xw, minf(w0, w0 + sz * 1.6), xe, maxf(w0, w0 + sz * 1.6), deck, deck + 0.22, Color(0.55, 0.54, 0.52))
		# Stiffening truss under the deck edges: Warren diagonals between a
		# top and bottom chord, the classic suspension-bridge look.
		for sz: float in [-1.0, 1.0]:
			var zt := zc + sz * 9.4
			beam(Vector3(xw, deck - 6.0, zt), Vector3(xe, deck - 6.0, zt), 0.6, 0.6, BRIDGE_RED)
			var x2 := xw
			var up := true
			while x2 < xe - 0.1:
				var nx := minf(x2 + 7.5, xe)
				beam(Vector3(x2, deck - (6.0 if up else 2.2), zt), Vector3(nx, deck - (2.2 if up else 6.0), zt), 0.35, 0.35,
					BRIDGE_RED)
				x2 = nx
				up = not up
		var x3 := xw + 15.0
		while x3 < xe:  # floor beams under the roadway
			beam(Vector3(x3, deck - 6.0, zc - 9.4), Vector3(x3, deck - 6.0, zc + 9.4), 0.5, 0.5, BRIDGE_RED.darkened(0.2))
			x3 += 15.0
	# Towers: two legs, three portal beams.
	for tx: float in s["towers"]:
		for sz: float in [-1.0, 1.0]:
			solid(tx - 3.0, minf(zc + sz * 15.0, zc + sz * 9.5), tx + 3.0, maxf(zc + sz * 15.0, zc + sz * 9.5),
				-2.0, ytop, BRIDGE_RED)
			solid(tx - 3.5, minf(zc + sz * 15.5, zc + sz * 9.0), tx + 3.5, maxf(zc + sz * 15.5, zc + sz * 9.0),
				ytop, ytop + 2.5, BRIDGE_RED.darkened(0.2))
		for yy in [[deck - 6.0, deck - 2.0], [88.0, 92.0], [ytop - 6.0, ytop - 2.0]]:
			solid(tx - 2.5, zc - 9.5, tx + 2.5, zc + 9.5, yy[0], yy[1], BRIDGE_RED)
		solid(tx - 5.0, zc - 18.0, tx + 5.0, zc + 18.0, -3.0, 1.0, Color(0.5, 0.47, 0.42))
		if detailed:
			# Recessed panels up the legs and X-bracing between the portals.
			for sz: float in [-1.0, 1.0]:
				for side: float in [-1.0, 1.0]:
					var y := deck + 6.0
					while y < ytop - 8.0:
						solid(tx + side * 3.0 - 0.06, zc + sz * 10.4 - 0.5, tx + side * 3.0 + 0.06, zc + sz * 10.4 + 0.5,
							y, y + 7.0, BRIDGE_RED.darkened(0.25))
						y += 9.0
			for yy in [[deck - 2.0, 88.0], [92.0, ytop - 6.0]]:
				beam(Vector3(tx, yy[0], zc - 9.0), Vector3(tx, yy[1], zc + 9.0), 0.9, 0.9, BRIDGE_RED)
				beam(Vector3(tx, yy[0], zc + 9.0), Vector3(tx, yy[1], zc - 9.0), 0.9, 0.9, BRIDGE_RED)
		# Aviation lights on the tower tops (glow at night: KIND_SIGN emits).
		for sz: float in [-1.0, 1.0]:
			solid(tx - 0.5, zc + sz * 12.25 - 0.5, tx + 0.5, zc + sz * 12.25 + 0.5, ytop + 2.5, ytop + 3.3,
				Color(1.0, 0.12, 0.08), KIND_SIGN)
	# Main cables and vertical suspenders down to the deck.
	for pts in s["cables"]:
		var cable: PackedVector3Array = pts
		for i in cable.size() - 1:
			beam(cable[i], cable[i + 1], 0.9, 0.9, BRIDGE_RED)
			# A string of lamps along each main cable – the bridge's night necklace.
			var nl := maxi(1, int(cable[i].distance_to(cable[i + 1]) / 9.0))
			for k in nl:
				var lp := cable[i].lerp(cable[i + 1], (k + 0.5) / nl) + Vector3.UP * 0.55
				solid(lp.x - 0.22, lp.z - 0.22, lp.x + 0.22, lp.z + 0.22, lp.y - 0.15, lp.y + 0.2,
					Color(1.0, 0.92, 0.75), KIND_SIGN)
		if not detailed:
			continue
		for i in cable.size() - 1:
			var a := cable[i]
			var b := cable[i + 1]
			var n := maxi(1, int(absf(b.x - a.x) / 7.5))
			for k in n:
				var p := a.lerp(b, (k + 0.5) / n)
				if p.y > deck + 2.0:
					beam(p, Vector3(p.x, deck + 0.4, p.z), 0.22, 0.22, BRIDGE_RED.darkened(0.15))


## Ground for one chunk: asphalt, raised pavement blocks with kerbs, park
## lawns and dashed avenue centre lines, clipped to the chunk rectangle.
const GROUND_STEP := 16.0  # m: far-shore ground tessellation
const SLAB_EDGE := 3.0     # m between boundary samples of a ground slab
const KERB_STEP := 4.0     # m: kerb / wall pieces follow the ground in steps this long


## One chunk of the island's ground (drawn = collision):
##   * the road surface: the landform over all the land in the chunk (the
##     coast minus the dock basins); everywhere a block isn't, this is road
##     (or the esplanade's foot, which is covered by its pavement);
##   * every block's pavement slab (sloping with the ground + kerb, or level
##     on a terrace), cut to the chunk, with kerbs / retaining walls round it;
##   * dock basins' quay walls, the sea walls and the shore apron.
func add_ground(layout: CityLayout, chunk_rect: Rect2) -> void:
	var asphalt := Color(0.2, 0.21, 0.23)
	var pave := Color(0.58, 0.57, 0.55)
	var kerb := Color(0.7, 0.69, 0.66)
	var grass := Color(0.32, 0.45, 0.24)
	var wall := Color(0.5, 0.46, 0.4)
	var T := layout.terrain
	var crect := CityLayout._rect_poly(chunk_rect)
	# Road surface.
	var outers: Array = []
	for q in Geometry2D.intersect_polygons(crect, layout.coast):
		if not Geometry2D.is_polygon_clockwise(q):
			outers.append(q)
	if not outers.is_empty():
		var holes: Array = []
		for bs in layout.basins:
			if (bs as Rect2).intersects(chunk_rect):
				holes.append(CityLayout._rect_poly(bs))
		_slab(T, outers, holes, func(x: float, z: float) -> float: return T.road_y(x, z), asphalt)
	# Blocks.
	for blk in layout.blocks:
		var poly: PackedVector2Array = blk["poly"]
		var bb := CityLayout._bbox(poly)
		if not bb.intersects(chunk_rect):
			continue
		var level: float = blk["level"]
		var flat := not is_nan(level)
		var kind: String = blk["kind"]
		var district_paving: Color = {"cbd": Color(0.55, 0.57, 0.59), "docks": Color(0.53, 0.52, 0.50),
			"georgian": Color(0.62, 0.55, 0.51), "waterfront": Color(0.56, 0.57, 0.54)}.get(blk["district"], pave)
		var col := grass if kind == "park" else district_paving
		var b_outers: Array = []
		for q in Geometry2D.intersect_polygons(crect, poly):
			if not Geometry2D.is_polygon_clockwise(q):
				b_outers.append(q)
		if b_outers.is_empty():
			continue
		var b_holes: Array = blk["holes"].duplicate()
		var basin: Rect2 = blk["basin"]
		if basin.has_area():
			b_holes.append(CityLayout._rect_poly(basin))
		var hf := (func(x: float, z: float) -> float: return level) if flat \
			else (func(x: float, z: float) -> float: return T.road_y(x, z) + CityTerrain.KERB)
		_slab(T, b_outers, b_holes, hf, col)
		if flat:
			for g in layout.greens:
				var gr: Rect2 = (g as Rect2).intersection(chunk_rect)
				if gr.has_area() and Geometry2D.is_point_in_polygon((g as Rect2).get_center(), poly):
					top(gr.position.x, gr.position.y, gr.end.x, gr.end.y, level + 0.02, grass, KIND_ROOF, 0, 0)
		# Kerb (sloping) or retaining wall (terrace) round the block; the
		# esplanade's kerb is round its hole (the ring road side).
		var rings: Array = blk["holes"] if kind == "esplanade" else [poly]
		for rg in rings:
			_skirt(T, layout, rg, chunk_rect, level, kerb if not flat else wall, not flat, kind == "esplanade")
		if basin.has_area():
			var w2: Rect2 = basin.intersection(chunk_rect)
			if w2.has_area():
				_inner_walls(w2, -3.0, level + 0.01, Color(0.4, 0.33, 0.28))
	_coast(layout, chunk_rect)
	_shore(layout, chunk_rect)
	# The strait's quay wall (west promenade edge).
	var I := layout.island
	if chunk_rect.position.x <= CityLayout.RIVER_EDGE and chunk_rect.end.x > CityLayout.RIVER_EDGE:
		var z0 := maxf(chunk_rect.position.y, I.position.y)
		var z1 := minf(chunk_rect.end.y, I.end.y)
		if z1 > z0:
			var x := CityLayout.RIVER_EDGE
			quad(Vector3(x, 0.0, z0), Vector3(x, 0.0, z1), Vector3(x, -4.0, z1), Vector3(x, -4.0, z0), Vector3.LEFT,
				Vector2(z0, 0), Vector2(z1, 0), Vector2(z1, -4), Vector2(z0, -4), Color(0.45, 0.4, 0.34), KIND_WALL, 5, 0.3)
			solid(x, z0, x + 0.6, z1, 0.0, 1.1, Color(0.3, 0.32, 0.33))


## A ground surface over polygons (minus holes), following height(x, z):
## Delaunay over the landform's grid points inside plus the boundary sampled
## every SLAB_EDGE m, keeping the triangles whose centre is inside.
func _slab(T: CityTerrain, outers: Array, holes: Array, height: Callable, col: Color) -> void:
	for o in outers:
		var poly: PackedVector2Array = o
		var pts := PackedVector2Array()
		_densify(poly, SLAB_EDGE, pts)
		var my_holes: Array = []
		for h in holes:
			var hp: PackedVector2Array = h
			if CityLayout._bbox(hp).intersects(CityLayout._bbox(poly)):
				my_holes.append(hp)
				var cut: Array = Geometry2D.intersect_polygons(hp, poly)
				for c in cut:
					_densify(c, SLAB_EDGE, pts)
		var bb := CityLayout._bbox(poly)
		var g := CityTerrain.GRID
		var x := ceilf(bb.position.x / g) * g
		while x < bb.end.x:
			var z := ceilf(bb.position.y / g) * g
			while z < bb.end.y:
				var p := Vector2(x, z)
				if Geometry2D.is_point_in_polygon(p, poly) and not _in_any(p, my_holes):
					pts.append(p)
				z += g
			x += g
		if pts.size() < 3:
			continue
		var tri := Geometry2D.triangulate_delaunay(pts)
		var hs := PackedFloat32Array()
		hs.resize(pts.size())
		for i in pts.size():
			hs[i] = height.call(pts[i].x, pts[i].y)
		for k in range(0, tri.size(), 3):
			var a := pts[tri[k]]
			var b := pts[tri[k + 1]]
			var c := pts[tri[k + 2]]
			var m := (a + b + c) / 3.0
			if not Geometry2D.is_point_in_polygon(m, poly) or _in_any(m, my_holes):
				continue
			var A := Vector3(a.x, hs[tri[k]], a.y)
			var B := Vector3(b.x, hs[tri[k + 1]], b.y)
			var C := Vector3(c.x, hs[tri[k + 2]], c.y)
			var n := (B - A).cross(C - A)
			if n.y < 0.0:
				var t := B
				B = C
				C = t
				n = -n
			_ground_tri(A, B, C, n.normalized(), col)


## A building's flat roof. UVs run from the roof's centre and UV2.x packs its
## half-extents (negative = "roof with extents"), so building.gdshader knows
## how far each pixel is from the parapet: grime and flashing along the edges,
## drains, a walkway – all without extra vertices.
func roof_top(x0: float, z0: float, x1: float, z1: float, y: float, col: Color, seed: float) -> void:
	var cx := (x0 + x1) * 0.5
	var cz := (z0 + z1) * 0.5
	var hx := minf(floorf((x1 - x0) * 2.0), 4095.0)  # half-extent in ¼ m
	var hz := minf(floorf((z1 - z0) * 2.0), 4095.0)
	var i := verts.size()
	var a := Vector3(x0, y, z0)
	var b := Vector3(x1, y, z0)
	var c := Vector3(x1, y, z1)
	var d := Vector3(x0, y, z1)
	var n := Vector3.UP
	if _xf_on:
		a = xf * a
		b = xf * b
		c = xf * c
		d = xf * d
		n = xf.basis * n
	verts.append_array([a, b, c, d])
	normals.append_array([n, n, n, n])
	var cc := Color(col.r, col.g, col.b, KIND_ROOF / 8.0)
	colors.append_array([cc, cc, cc, cc])
	uvs.append_array([Vector2(x0 - cx, z0 - cz), Vector2(x1 - cx, z0 - cz), Vector2(x1 - cx, z1 - cz), Vector2(x0 - cx, z1 - cz)])
	var s2 := Vector2(-(1.0 + hx + hz * 4096.0), seed)
	uv2s.append_array([s2, s2, s2, s2])
	indices.append_array([i, i + 1, i + 2, i, i + 2, i + 3])


## Upward-facing triangle with world-XZ UVs (ground shader), KIND_ROOF.
func _ground_tri(a: Vector3, b: Vector3, c: Vector3, n: Vector3, col: Color) -> void:
	# quad()'s convention is clockwise seen from the front; for a triangle,
	# emit a degenerate quad (a, c, b, b) in that order.
	var i := verts.size()
	verts.append_array([a, c, b])
	normals.append_array([n, n, n])
	var cc := Color(col.r, col.g, col.b, KIND_ROOF / 8.0)
	colors.append_array([cc, cc, cc])
	uvs.append_array([Vector2(a.x, a.z), Vector2(c.x, c.z), Vector2(b.x, b.z)])
	uv2s.append_array([Vector2.ZERO, Vector2.ZERO, Vector2.ZERO])
	indices.append_array([i, i + 1, i + 2])


static func _in_any(p: Vector2, polys: Array) -> bool:
	for q in polys:
		if Geometry2D.is_point_in_polygon(p, q):
			return true
	return false


## Appends the polygon's boundary, sampled every `step` m, to `out`.
static func _densify(poly: PackedVector2Array, step: float, out: PackedVector2Array) -> void:
	for i in poly.size():
		var a := poly[i]
		var b := poly[(i + 1) % poly.size()]
		var n := maxi(1, ceili(a.distance_to(b) / step))
		for k in n:
			out.append(a.lerp(b, float(k) / n))


## Kerb (sloping blocks: pavement + KERB down to under the road) or
## retaining wall (terraces: from `level`) along a block ring, the pieces
## whose middle is inside `clip`. `inward` = the face looks into the ring
## (the esplanade's hole).
func _skirt(T: CityTerrain, layout: CityLayout, ring: PackedVector2Array, clip: Rect2, level: float, col: Color,
		sloping: bool, inward: bool) -> void:
	var ccw := not Geometry2D.is_polygon_clockwise(ring)
	for i in ring.size():
		var a := ring[i]
		var b := ring[(i + 1) % ring.size()]
		var L := a.distance_to(b)
		if L < 0.01:
			continue
		var d := (b - a) / L
		# Outward normal of a ccw ring (Geometry2D's orientation) is to the right of travel.
		var out := Vector2(d.y, -d.x) if ccw else Vector2(-d.y, d.x)
		if not Geometry2D.is_point_in_polygon((a + b) * 0.5 - out * 0.5, ring):
			out = -out  # (orientation convention guard)
		if inward:
			out = -out
		var n := maxi(1, ceili(L / KERB_STEP))
		for k in n:
			var p := a.lerp(b, float(k) / n)
			var q := a.lerp(b, float(k + 1) / n)
			if not clip.has_point((p + q) * 0.5):
				continue
			var yp := T.road_y(p.x, p.y)
			var yq := T.road_y(q.x, q.y)
			var tp := yp + CityTerrain.KERB if sloping else level
			var tq := yq + CityTerrain.KERB if sloping else level
			var N := Vector3(out.x, 0.0, out.y)
			var P0 := Vector3(p.x, tp, p.y)
			var Q0 := Vector3(q.x, tq, q.y)
			var P1 := Vector3(p.x, yp - 0.3, p.y)
			var Q1 := Vector3(q.x, yq - 0.3, q.y)
			var u0 := float(k) / n * L
			var u1 := float(k + 1) / n * L
			if (Q0 - P0).cross(P1 - P0).dot(N) < 0.0:  # (front = first triangle's cross against n, as top())
				quad(P0, Q0, Q1, P1, N, Vector2(u0, tp), Vector2(u1, tq), Vector2(u1, yq - 0.3), Vector2(u0, yp - 0.3),
					col, KIND_TRIM if sloping else KIND_WALL, 5, 0.42)
			else:
				quad(Q0, P0, P1, Q1, N, Vector2(u1, tq), Vector2(u0, tp), Vector2(u0, yp - 0.3), Vector2(u1, yq - 0.3),
					col, KIND_TRIM if sloping else KIND_WALL, 5, 0.42)


const SEA_WALL_LOW := -4.0   # m: sea walls run down under the water (drawn at -1.6)
const RAIL_H := 1.1           # m: esplanade railing
const RAIL_T := 0.5


## The coast's edges (not the straight strait quay in the west), each as
## [a, b, outward normal (2-D)], in order round from the north-west corner.
static func coast_edges(coast: PackedVector2Array) -> Array:
	var n := coast.size()
	var out: Array = []
	for i in n:
		var a := coast[i]
		var b := coast[(i + 1) % n]
		if a.x < CityLayout.RIVER_EDGE + 0.5 and b.x < CityLayout.RIVER_EDGE + 0.5:
			continue  # the strait quay
		var d := (b - a).normalized()
		var o := Vector2(d.y, -d.x)
		if Geometry2D.is_point_in_polygon((a + b) * 0.5 + o * 0.5, coast):
			o = -o
		out.append([a, b, o])
	return out


## Sea walls round the coast (drawn = collision): a quay wall where the land
## is low, the cliff's top course where it's high, with a stone railing.
func _coast(layout: CityLayout, clip: Rect2) -> void:
	var T := layout.terrain
	var rail := Color(0.3, 0.32, 0.33)
	for e in coast_edges(layout.coast):
		var a: Vector2 = e[0]
		var b: Vector2 = e[1]
		var o: Vector2 = e[2]
		var n3 := Vector3(o.x, 0.0, o.y)
		var L := a.distance_to(b)
		var m := maxi(1, ceili(L / KERB_STEP))
		for k in m:
			var p := a.lerp(b, float(k) / m)
			var q := a.lerp(b, float(k + 1) / m)
			if not clip.has_point((p + q) * 0.5):
				continue
			var yp := T.road_y(p.x, p.y) + CityTerrain.KERB
			var yq := T.road_y(q.x, q.y) + CityTerrain.KERB
			var high := maxf(yp, yq) > 6.0
			var face := Color(0.47, 0.43, 0.38) if high else Color(0.45, 0.4, 0.34)
			var P0 := Vector3(p.x, yp, p.y)
			var Q0 := Vector3(q.x, yq, q.y)
			var P1 := Vector3(p.x, SEA_WALL_LOW, p.y)
			var Q1 := Vector3(q.x, SEA_WALL_LOW, q.y)
			_vface(P0, Q0, Q1, P1, n3, face, KIND_WALL)
			# Railing: a low stone wall just inside the edge, riding the slope.
			var pi := p - o * RAIL_T
			var qi := q - o * RAIL_T
			var up := Vector3(0, RAIL_H, 0)
			var Pi := Vector3(pi.x, yp, pi.y)
			var Qi := Vector3(qi.x, yq, qi.y)
			_vface(P0 + up, Q0 + up, Q0, P0, n3, rail, KIND_TRIM)
			_vface(Pi + up, Qi + up, Qi, Pi, -n3, rail, KIND_TRIM)
			var top := [Pi + up, Qi + up, Q0 + up, P0 + up]
			var tn: Vector3 = ((top[1] - top[0]) as Vector3).cross(top[3] - top[0])
			if tn.y > 0.0:
				top.reverse()
			quad(top[0], top[1], top[2], top[3], Vector3.UP, Vector2.ZERO, Vector2.ZERO, Vector2.ZERO, Vector2.ZERO,
				rail.lightened(0.1), KIND_TRIM, 0, 0)


## A vertical face with the winding quad() wants for normal n.
func _vface(a: Vector3, b: Vector3, c: Vector3, d: Vector3, n: Vector3, col: Color, kind: float) -> void:
	if (b - a).cross(d - a).dot(n) > 0.0:
		quad(b, a, d, c, n, Vector2(b.x + b.z, b.y), Vector2(a.x + a.z, a.y), Vector2(d.x + d.z, d.y), Vector2(c.x + c.z, c.y),
			col, kind, 5, 0.3)
	else:
		quad(a, b, c, d, n, Vector2(a.x + a.z, a.y), Vector2(b.x + b.z, b.y), Vector2(c.x + c.z, c.y), Vector2(d.x + d.z, d.y),
			col, kind, 5, 0.3)


const SHORE_STEP := 8.0      # m between shoreline samples


## The shoreline: samples along the coast (not the strait quay) as
## [point on the sea wall, outward normal, arc length].
static func shore_samples(coast: PackedVector2Array) -> Array:
	var out: Array = []
	var s := 0.0
	var edges := coast_edges(coast)
	for ei in edges.size():
		var e: Array = edges[ei]
		var a: Vector2 = e[0]
		var b: Vector2 = e[1]
		var o: Vector2 = e[2]
		# Smooth normals across the joints.
		var prev: Vector2 = edges[ei - 1][2] if ei > 0 else o
		var L := a.distance_to(b)
		var k := maxi(1, ceili(L / SHORE_STEP))
		for i in k:
			var f := float(i) / k
			var nn := (prev.lerp(o, clampf(0.5 + f, 0.0, 1.0)) if i == 0 else o).normalized()
			out.append([a.lerp(b, f), nn, s + L * f])
		s += L
	if not edges.is_empty():
		out.append([edges[-1][1], edges[-1][2], s])
	return out


static func _snoise(x: float) -> float:
	var i := floorf(x)
	var f := x - i
	f = f * f * (3.0 - 2.0 * f)
	var a := fmod(sin(i * 127.1) * 43758.5453, 1.0)
	var b := fmod(sin((i + 1.0) * 127.1) * 43758.5453, 1.0)
	return lerpf(absf(a), absf(b), f)


## Profile across the apron at one shoreline sample: [distance out, height]
## rows from the sea wall's foot to under the water, then the rock share.
## High ground meets the sea in rocky slopes under the cliffs; low ground in
## a sand beach under the sea wall; the docks keep a plain quay wall.
static func shore_profile(layout: CityLayout, smp: Array) -> Array:
	var T := layout.terrain
	var p: Vector2 = smp[0]
	var s: float = smp[2]
	var H := T.road_y(p.x, p.y)
	var x_taper := smoothstep(CityLayout.RIVER_EDGE + 10.0, CityLayout.RIVER_EDGE + 90.0, p.x)
	var dock := 1.0 - smoothstep(500.0, 590.0, p.x) if p.y > 250.0 and p.x > 0.0 else 0.0
	if layout.is_mainland:  # (its straight quay faces east, onto the strait)
		x_taper = smoothstep(CityLayout.FAR_SHORE - 10.0, CityLayout.FAR_SHORE - 90.0, p.x)
	var n1 := _snoise(s / 70.0)
	var n2 := _snoise(s / 23.0 + 40.0)
	var amt := x_taper * (1.0 - dock)
	var r := smoothstep(4.0, 9.0, H)
	var w := lerpf(16.0 + 30.0 * n1 + 6.0 * n2, 14.0 + H * 0.9 + 46.0 * pow(n1, 1.6) + 9.0 * n2, r) * amt
	# North Beach (CoastLife): a long, wide, shallow sand beach.
	var bk := 0.0 if layout.is_mainland else CoastLife.beach_k(p)
	if bk > 0.0:
		r *= 1.0 - bk
		w = lerpf(w, CoastLife.BEACH_W + 6.0 * n2, bk)
	var j := func(k: int) -> float: return (_snoise(s / 32.0 + k * 17.3) - 0.5) * r
	var rock := [[0.0, H - 0.5], [w * 0.07 + 2.0 * j.call(1), H * 0.66 + H * 0.14 * j.call(2)],
		[w * 0.3 + 6.0 * j.call(3), H * 0.32 + H * 0.2 * j.call(4)],
		[w * 0.6 + 8.0 * j.call(5), 1.2 + 3.0 * absf(j.call(6)) * 2.0],
		[w * 0.82 + 4.0 * j.call(7), -0.6], [w, -4.5]]
	var sand := [[0.0, 0.9], [w * 0.12, 0.85], [w * 0.4, 0.45], [w * 0.62, 0.0], [w * 0.8, -0.9], [w, -3.6]]
	var out: Array = []
	for k in rock.size():
		out.append([lerpf(sand[k][0], rock[k][0], r), lerpf(sand[k][1], rock[k][1], r)])
	out.append(r)
	return out


func _shore(layout: CityLayout, clip: Rect2) -> void:
	var smp := shore_samples(layout.coast)
	var rows: Array = []
	var rocky: Array = []
	for sm in smp:
		var prof := shore_profile(layout, sm)
		var p: Vector2 = sm[0]
		var n: Vector2 = sm[1]
		rocky.append(prof.pop_back())
		var r: Array = []
		for k in prof.size():
			var d: float = prof[k][0]
			r.append(Vector3(p.x + n.x * d, prof[k][1], p.y + n.y * d))
		rows.append(r)
	var rock := Color(0.23, 0.225, 0.225)
	var sand := Color(0.78, 0.7, 0.52)
	for i in smp.size() - 1:
		var A: Array = rows[i]
		var B: Array = rows[i + 1]
		var mid: Vector3 = (A[0] + B[0]) * 0.5
		if not clip.has_point(Vector2(mid.x, mid.z)):
			continue
		if (A[-1] as Vector3).distance_to(A[0]) < 0.5 and (B[-1] as Vector3).distance_to(B[0]) < 0.5:
			continue  # no apron here (docks quay)
		var high: bool = float(rocky[i]) + float(rocky[i + 1]) > 1.0
		var out_n := Vector3(smp[i][1].x, 0.0, smp[i][1].y)
		for k in A.size() - 1:
			var a: Vector3 = A[k]
			var b: Vector3 = B[k]
			var c: Vector3 = B[k + 1]
			var d: Vector3 = A[k + 1]
			var col := rock if high else sand
			if not high and k == A.size() - 2:
				col = sand.darkened(0.25)
			var nn := (c - a).cross(b - d)
			if nn.length_squared() < 1e-8:
				nn = (c - a).cross(d - b)
			if nn.dot(Vector3.UP + out_n) < 0.0:
				var t := b
				b = d
				d = t
				nn = -nn
			quad(a, b, c, d, nn.normalized(), Vector2(a.x, a.z), Vector2(b.x, b.z), Vector2(c.x, c.z),
				Vector2(d.x, d.z), col, KIND_SHORE, 0, 0)


## The ground over `r`, dy above the road surface (CityTerrain.road_y): a
## grid through every junction line, at most `step` apart, so it matches
## road_y everywhere (collision is built from these very triangles).
func terrain_patch(T: CityTerrain, r: Rect2, dy: float, col: Color, step := GROUND_STEP) -> void:
	var xs := T.splits(r.position.x, r.end.x, T.xs, step)
	var zs := T.splits(r.position.y, r.end.y, T.zs, step)
	var row := PackedFloat32Array()
	row.resize(xs.size() * zs.size())
	for i in xs.size():
		for j in zs.size():
			row[i * zs.size() + j] = T.road_y(xs[i], zs[j]) + dy
	for i in xs.size() - 1:
		for j in zs.size() - 1:
			var x0 := xs[i]
			var x1 := xs[i + 1]
			var z0 := zs[j]
			var z1 := zs[j + 1]
			var a := Vector3(x0, row[i * zs.size() + j], z0)
			var b := Vector3(x1, row[(i + 1) * zs.size() + j], z0)
			var c := Vector3(x1, row[(i + 1) * zs.size() + j + 1], z1)
			var d := Vector3(x0, row[i * zs.size() + j + 1], z1)
			var n := (c - a).cross(b - d).normalized()
			if n.y < 0.0:
				n = -n
			quad(a, b, c, d, n, Vector2(x0, z0), Vector2(x1, z0), Vector2(x1, z1), Vector2(x0, z1), col, KIND_ROOF, 0, 0)


## Walls round a block (only the parts inside `clip`): from below the street
## up to the pavement – a kerb where the pavement follows the street
## (level = NAN), a retaining wall up to a terrace at `level`.
func terrain_skirt(T: CityTerrain, blk: Rect2, clip: Rect2, level: float, col: Color, step := GROUND_STEP) -> void:
	var x0 := blk.position.x
	var z0 := blk.position.y
	var x1 := blk.end.x
	var z1 := blk.end.y
	# Same corner order and outward normals as walls().
	var corners := [Vector2(x0, z1), Vector2(x1, z1), Vector2(x1, z0), Vector2(x0, z0)]
	var ns := [Vector3.BACK, Vector3.RIGHT, Vector3.FORWARD, Vector3.LEFT]
	for k in 4:
		var a: Vector2 = corners[k]
		var b: Vector2 = corners[(k + 1) % 4]
		var along_x := absf(a.y - b.y) < 0.01
		var lines := T.xs if along_x else T.zs
		var u0 := a.x if along_x else a.y
		var u1 := b.x if along_x else b.y
		var cuts := T.splits(minf(u0, u1), maxf(u0, u1), lines, step)
		if u0 > u1:
			cuts.reverse()
		for m in cuts.size() - 1:
			var p := Vector2(cuts[m], a.y) if along_x else Vector2(a.x, cuts[m])
			var q := Vector2(cuts[m + 1], a.y) if along_x else Vector2(a.x, cuts[m + 1])
			var mid := (p + q) * 0.5
			if not clip.has_point(mid):
				continue
			var yp := T.road_y(p.x, p.y)
			var yq := T.road_y(q.x, q.y)
			var tp := level if not is_nan(level) else yp + CityTerrain.KERB
			var tq := level if not is_nan(level) else yq + CityTerrain.KERB
			quad(Vector3(p.x, tp, p.y), Vector3(q.x, tq, q.y), Vector3(q.x, yq - 0.3, q.y), Vector3(p.x, yp - 0.3, p.y),
				ns[k], Vector2(cuts[m], tp), Vector2(cuts[m + 1], tq), Vector2(cuts[m + 1], yq - 0.3),
				Vector2(cuts[m], yp - 0.3), col, KIND_TRIM if is_nan(level) else KIND_WALL, 5, 0.42)


## All triangles, for a ConcavePolygonShape3D (collision = what's drawn).
func faces() -> PackedVector3Array:
	var out := PackedVector3Array()
	out.resize(indices.size())
	for i in indices.size():
		out[i] = verts[indices[i]]
	return out


func _inner_walls(r: Rect2, y0: float, y1: float, col: Color, kind := KIND_WALL) -> void:
	# Walls facing inward (towards the basin centre).
	var x0 := r.position.x
	var z0 := r.position.y
	var x1 := r.end.x
	var z1 := r.end.y
	var corners := [Vector2(x0, z0), Vector2(x1, z0), Vector2(x1, z1), Vector2(x0, z1)]
	var ns := [Vector3.BACK, Vector3.LEFT, Vector3.FORWARD, Vector3.RIGHT]
	for k in 4:
		var a: Vector2 = corners[k]
		var b: Vector2 = corners[(k + 1) % 4]
		var w := a.distance_to(b)
		quad(Vector3(a.x, y1, a.y), Vector3(b.x, y1, b.y), Vector3(b.x, y0, b.y), Vector3(a.x, y0, a.y), ns[k],
			Vector2(0, y1), Vector2(w, y1), Vector2(w, y0), Vector2(0, y0), col, kind, 3, 0.5)


func _add_shaped(b: Dictionary, detailed: bool, style: float, seed: float, col: Color, wall_kind: float,
		trim: Color, roof: Color, base: float, glassy: bool) -> void:
	var tiers: Array = b["tiers"]
	var light := int(b["shape"].get("segs", 0)) > 8  # curved plans: no stone courses (vertex cost)
	for i in tiers.size():
		var t: Array = tiers[i]
		var y0: float = t[4]
		var y1: float = t[5]
		var fp := footprint(b, t)
		walls_poly(fp, y0, y1, col, wall_kind, style, seed, y0 - base)
		if _overhangs(tiers, i) or not _on_ground(b, t) and i == 0:
			cap_poly(fp, y0, col.darkened(0.25), KIND_TRIM, style, seed, false)
		if not detailed:
			cap_poly(fp, y1, roof, KIND_ROOF, style, seed, true, true)
			continue
		var o := cornice_out(b)
		var ch := cornice_h(b)
		var co := footprint(b, t, o)
		walls_poly(co, y1 - ch * 0.5, y1 + ch * 0.5, trim, KIND_TRIM, style, seed)
		cap_poly(co, y1 - ch * 0.5, trim, KIND_TRIM, style, seed, false)
		var ry := y1 + ch * 0.5
		cap_poly(co, ry, roof, KIND_ROOF, style, seed, true, true)
		# Parapet: outer face, inner face, top ring.
		var inner := offset_poly(co, -PARAPET_T)
		walls_poly(co, ry, ry + PARAPET, trim, KIND_TRIM, 0, 0)
		walls_poly(inner, ry, ry + PARAPET, trim.darkened(0.15), KIND_TRIM, 0, 0, -1.0, true)
		ring_poly(co, inner, ry + PARAPET, trim)
		if not glassy and not light:
			var ly := base + (floorf((y0 - base) / LEDGE_EVERY) + 1.0) * LEDGE_EVERY
			var lo := offset_poly(fp, LEDGE_OUT)
			while ly < y1 - 4.0:
				walls_poly(lo, ly, ly + 0.32, trim, KIND_TRIM, style, seed)
				ring_poly(lo, fp, ly, trim.darkened(0.25), false)
				ring_poly(lo, fp, ly + 0.32, trim.lightened(0.1))
				ly += LEDGE_EVERY
		if _has_plinth(b, i):
			var pp := offset_poly(fp, PLINTH_OUT)
			walls_poly(pp, base, base + PLINTH_H, col.darkened(0.3), KIND_TRIM, style, seed)
			ring_poly(pp, fp, base + PLINTH_H, col.darkened(0.3))


# ------------------------------------------------------------ shaped towers
## Buildings with b["shape"] (CityLayout._shape_for) are not boxes: each
## tier's rect is the bounding box of a footprint with chamfered, rounded or
## notched corners, round drums or a flatiron prow. shape = {"c": [corner
## treatments for corners 0..3]}, corner = [kind, size as a fraction of the
## tier's short side]: kind 0 sharp, 1 chamfer, 2 round, 3 notch.
## Corners run (x0,z1) → (x1,z1) → (x1,z0) → (x0,z0), the order walls() uses
## (negative shoelace area; outward normal of edge d is (-d.y, d.x)).
const SHAPE_SHARP := 0
const SHAPE_CHAMFER := 1
const SHAPE_ROUND := 2
const SHAPE_NOTCH := 3
const ARC_SEGS := 5          # per quarter circle (18° steps: smooth-shaded)
const SMOOTH_TURN := 0.55    # rad: vertices turning less than this shade smooth


static func shaped(b: Dictionary) -> bool:
	return b.has("shape") and b["kind"] == "normal"


## The footprint of one tier (building-local xz), in walls() order.
static func footprint(b: Dictionary, t: Array, grow := 0.0) -> PackedVector2Array:
	var x0: float = float(t[0]) - grow
	var z0: float = float(t[1]) - grow
	var x1: float = float(t[2]) + grow
	var z1: float = float(t[3]) + grow
	var cs := [Vector2(x0, z1), Vector2(x1, z1), Vector2(x1, z0), Vector2(x0, z0)]
	var short := minf(float(t[2]) - float(t[0]), float(t[3]) - float(t[1]))
	var spec: Array = b["shape"]["c"]
	var out := PackedVector2Array()
	for k in 4:
		var p: Vector2 = cs[k]
		var din: Vector2 = (p - (cs[(k + 3) % 4] as Vector2)).normalized()
		var dout: Vector2 = ((cs[(k + 1) % 4] as Vector2) - p).normalized()
		var kind: int = spec[k][0]
		var s: float = float(spec[k][1]) * short
		if kind == SHAPE_ROUND:
			s = minf(s + grow, short * 0.5 + grow - 0.001)
		elif kind == SHAPE_CHAMFER:
			s += grow * 0.414  # (keeps an outset chamfer parallel)
		match kind:
			SHAPE_CHAMFER:
				out.append(p - din * s)
				out.append(p + dout * s)
			SHAPE_ROUND:
				var c := p - din * s + dout * s
				var a0 := (-dout).angle()  # from the centre back to the incoming edge
				var a1 := din.angle()
				var da := wrapf(a1 - a0, -PI, PI)
				for i in ARC_SEGS + 1:
					var a := a0 + da * i / float(ARC_SEGS)
					out.append(c + Vector2.from_angle(a) * s)
			SHAPE_NOTCH:
				# A square bite out of the corner (an L / stepped plan); the
				# inner corner moves with the outset, so cornices follow it.
				var sn := s - grow * 2.0
				out.append(p - din * sn)
				out.append(p - din * sn + dout * sn)
				out.append(p + dout * sn)
			_:
				out.append(p)
	# Drop doubled points (a drum's arcs meet mid-face).
	var clean := PackedVector2Array()
	for q in out:
		if clean.is_empty() or q.distance_to(clean[-1]) > 0.02:
			clean.append(q)
	if clean.size() > 2 and clean[0].distance_to(clean[-1]) < 0.02:
		clean.remove_at(clean.size() - 1)
	return clean


## Mitre offset (d > 0 outward) keeping the vertex count (rings pair up).
static func offset_poly(pts: PackedVector2Array, d: float) -> PackedVector2Array:
	var n := pts.size()
	var out := PackedVector2Array()
	out.resize(n)
	for i in n:
		var a := pts[(i + n - 1) % n]
		var p := pts[i]
		var c := pts[(i + 1) % n]
		var e0 := (p - a).normalized()
		var e1 := (c - p).normalized()
		var n0 := Vector2(-e0.y, e0.x)
		var n1 := Vector2(-e1.y, e1.x)
		var m := (n0 + n1)
		if m.length_squared() < 1e-6:
			m = n0
		m = m.normalized()
		var k := maxf(m.dot(n0), 0.35)
		out[i] = p + m * (d / k)
	return out


## Walls round a footprint. Straight runs between sharp turns are faces
## (UV2 0..1 across each, like walls()); curved runs shade smooth.
func walls_poly(pts: PackedVector2Array, y0: float, y1: float, col: Color, kind: float, style: float,
		seed: float, uv_y0 := -1.0, inward := false) -> void:
	var n := pts.size()
	if n < 3:
		return
	var vy0 := y0 if uv_y0 < 0.0 else uv_y0
	var vy1 := vy0 + (y1 - y0)
	var en: Array[Vector2] = []  # outward normal of edge i (pts[i] → pts[i+1])
	var el: Array[float] = []
	for i in n:
		var d := pts[(i + 1) % n] - pts[i]
		el.append(d.length())
		var nn := Vector2(-d.y, d.x).normalized()
		en.append(-nn if inward else nn)
	# A vertex is a crease when the edges either side turn sharply there.
	var crease: Array[bool] = []
	var any := false
	for i in n:
		var turn := absf(en[(i + n - 1) % n].angle_to(en[i]))
		crease.append(turn > SMOOTH_TURN)
		any = any or crease[i]
	var start := 0
	if any:
		while not crease[start]:
			start += 1
	var u := 0.0
	var i := start
	var done := 0
	while done < n:
		# One face: edges from a crease to the next crease.
		var run: Array[int] = []
		var j := i
		while true:
			run.append(j)
			j = (j + 1) % n
			if crease[j] or j == start or run.size() >= n:
				break
		var L := 0.0
		for e in run:
			L += el[e]
		var acc := 0.0
		for e in run:
			var a := pts[e]
			var b := pts[(e + 1) % n]
			var na := en[e]
			var nb := en[e]
			if not crease[e]:
				na = (en[(e + n - 1) % n] + en[e]).normalized()
			if not crease[(e + 1) % n]:
				nb = (en[e] + en[(e + 1) % n]).normalized()
			var w := el[e]
			var t0 := acc / maxf(L, 0.001)
			var t1 := (acc + w) / maxf(L, 0.001)
			var A := Vector3(a.x, y1, a.y)
			var B := Vector3(b.x, y1, b.y)
			var C := Vector3(b.x, y0, b.y)
			var D := Vector3(a.x, y0, a.y)
			if inward:
				_quad_n(B, A, D, C, Vector3(nb.x, 0, nb.y), Vector3(na.x, 0, na.y),
					Vector2(u + w, vy1), Vector2(u, vy1), Vector2(u, vy0), Vector2(u + w, vy0), col, kind, style, seed)
			else:
				_quad_n(A, B, C, D, Vector3(na.x, 0, na.y), Vector3(nb.x, 0, nb.y),
					Vector2(u, vy1), Vector2(u + w, vy1), Vector2(u + w, vy0), Vector2(u, vy0), col, kind, style, seed)
			var wy := floorf(L * 4.0) + (floorf(seed * 256.0) + 0.5) / 256.0
			var m := uv2s.size()
			var ta := minf(t0, 0.999)
			var tb := minf(t1, 0.999)
			if inward:
				uv2s[m - 4] = Vector2(style + tb, wy)
				uv2s[m - 3] = Vector2(style + ta, wy)
				uv2s[m - 2] = Vector2(style + ta, wy)
				uv2s[m - 1] = Vector2(style + tb, wy)
			else:
				uv2s[m - 4] = Vector2(style + ta, wy)
				uv2s[m - 3] = Vector2(style + tb, wy)
				uv2s[m - 2] = Vector2(style + tb, wy)
				uv2s[m - 1] = Vector2(style + ta, wy)
			acc += w
			u += w
		done += run.size()
		i = j


## A quad whose left edge (a, d) and right edge (b, c) carry their own normals.
func _quad_n(a: Vector3, b: Vector3, c: Vector3, d: Vector3, na: Vector3, nb: Vector3, ua: Vector2, ub: Vector2,
		uc: Vector2, ud: Vector2, col: Color, kind: float, style: float, seed: float) -> void:
	if _xf_on:
		a = xf * a
		b = xf * b
		c = xf * c
		d = xf * d
		na = xf.basis * na
		nb = xf.basis * nb
	var i := verts.size()
	verts.append_array([a, b, c, d])
	normals.append_array([na, nb, nb, na])
	var cc := Color(col.r, col.g, col.b, kind / 8.0)
	colors.append_array([cc, cc, cc, cc])
	uvs.append_array([ua, ub, uc, ud])
	var s2 := Vector2(style, seed)
	uv2s.append_array([s2, s2, s2, s2])
	indices.append_array([i, i + 1, i + 2, i, i + 2, i + 3])


## Flat cap over (up) or under (down) a footprint, triangulated (L plans are
## concave). Roofs pack the bounding half-extents like roof_top().
func cap_poly(pts: PackedVector2Array, y: float, col: Color, kind: float, style: float, seed: float, up := true,
		roof := false) -> void:
	var tri := Geometry2D.triangulate_polygon(pts)
	if tri.is_empty():
		return
	var lo := pts[0]
	var hi := pts[0]
	for p in pts:
		lo = Vector2(minf(lo.x, p.x), minf(lo.y, p.y))
		hi = Vector2(maxf(hi.x, p.x), maxf(hi.y, p.y))
	var c := (lo + hi) * 0.5
	var s2 := Vector2(style, seed)
	if roof:
		var hx := minf(floorf((hi.x - lo.x) * 2.0), 4095.0)
		var hz := minf(floorf((hi.y - lo.y) * 2.0), 4095.0)
		s2 = Vector2(-(1.0 + hx + hz * 4096.0), seed)
		kind = KIND_ROOF
	var nrm := Vector3.UP if up else Vector3.DOWN
	var nw := xf.basis * nrm if _xf_on else nrm
	var cc := Color(col.r, col.g, col.b, kind / 8.0)
	var base := verts.size()
	for p in pts:
		var v := Vector3(p.x, y, p.y)
		verts.append(xf * v if _xf_on else v)
		normals.append(nw)
		colors.append(cc)
		uvs.append(p - c if roof else p)
		uv2s.append(s2)
	for k in range(0, tri.size(), 3):
		var ia := tri[k]
		var ib := tri[k + 1]
		var ic := tri[k + 2]
		var pa := Vector3(pts[ia].x, y, pts[ia].y)
		var pb := Vector3(pts[ib].x, y, pts[ib].y)
		var pc := Vector3(pts[ic].x, y, pts[ic].y)
		# Godot's front faces wind clockwise: pick the order that faces nrm.
		if (pb - pa).cross(pc - pa).dot(nrm) > 0.0:
			indices.append_array([base + ia, base + ic, base + ib])
		else:
			indices.append_array([base + ia, base + ib, base + ic])


## Horizontal ring between two footprints with the same vertex count.
func ring_poly(outer: PackedVector2Array, inner: PackedVector2Array, y: float, col: Color, up := true) -> void:
	var n := outer.size()
	var nrm := Vector3.UP if up else Vector3.DOWN
	for i in n:
		var j := (i + 1) % n
		var a := Vector3(outer[i].x, y, outer[i].y)
		var b := Vector3(outer[j].x, y, outer[j].y)
		var c := Vector3(inner[j].x, y, inner[j].y)
		var d := Vector3(inner[i].x, y, inner[i].y)
		_tri(a, b, c, nrm, col)
		_tri(a, c, d, nrm, col)


## Collision for shaped buildings: one convex prism per convex piece of each
## tier's footprint (walls, the cornice/roof slab, the plinth), exactly the
## drawn faces – no stair-steps for the rope to catch on. Points are in the
## building's frame (CityWorld applies its rotation).
static func collision_hulls(b: Dictionary) -> Array[PackedVector3Array]:
	var out: Array[PackedVector3Array] = []
	if not shaped(b):
		return out
	var o := cornice_out(b)
	var ch := cornice_h(b)
	var tiers: Array = b["tiers"]
	for i in tiers.size():
		var t: Array = tiers[i]
		var y1: float = t[5]
		_hulls_of(footprint(b, t), t[4], y1 - ch * 0.5, out)
		_hulls_of(footprint(b, t, o), y1 - ch * 0.5, y1 + ch * 0.5, out)
		if _has_plinth(b, i):
			_hulls_of(footprint(b, t, PLINTH_OUT), base_of(b), base_of(b) + PLINTH_H, out)
	return out


static func _hulls_of(fp: PackedVector2Array, y0: float, y1: float, out: Array[PackedVector3Array]) -> void:
	var parts: Array = [fp]
	if not _convex(fp):
		parts = Geometry2D.decompose_polygon_in_convex(fp)
	for part: PackedVector2Array in parts:
		var pts := PackedVector3Array()
		for v in part:
			pts.append(Vector3(v.x, y0, v.y))
			pts.append(Vector3(v.x, y1, v.y))
		out.append(pts)


static func _convex(p: PackedVector2Array) -> bool:
	var n := p.size()
	var sgn := 0.0
	for i in n:
		var a := p[(i + 1) % n] - p[i]
		var b := p[(i + 2) % n] - p[(i + 1) % n]
		var c := a.cross(b)
		if absf(c) < 1e-6:
			continue
		if sgn == 0.0:
			sgn = signf(c)
		elif signf(c) != sgn:
			return false
	return true


## (Old) collision for a shaped tier: vertical slices along x, each the footprint's
## z-extent there (exact on straight runs, within ~0.4 m on curves and
## chamfers). Notched plans give two intervals in a slice.
static func shape_boxes(pts: PackedVector2Array, y0: float, y1: float) -> Array[AABB]:
	var out: Array[AABB] = []
	var xs: Array[float] = []
	for p in pts:
		xs.append(p.x)
	xs.sort()
	var cuts: Array[float] = [xs[0]]
	for x in xs:
		if x - cuts[-1] > 0.05:
			cuts.append(x)
	var edges: Array[float] = []
	for k in cuts.size() - 1:
		var a: float = cuts[k]
		var b: float = cuts[k + 1]
		var za := _span_at(pts, a + 0.01)
		var zb := _span_at(pts, b - 0.01)
		var flat := za.size() == zb.size()
		if flat:
			for q in za.size():
				flat = flat and absf(za[q] - zb[q]) < 0.05
		var steps := 1 if flat else maxi(1, ceili((b - a) / 1.6))
		for s in steps:
			edges.append(lerpf(a, b, s / float(steps)))
	edges.append(cuts[-1])
	for k in edges.size() - 1:
		var a := edges[k]
		var b := edges[k + 1]
		var zs := _span_at(pts, (a + b) * 0.5)
		for q in range(0, zs.size() - 1, 2):
			out.append(AABB(Vector3(a, y0, zs[q]), Vector3(b - a, y1 - y0, zs[q + 1] - zs[q])))
	return out


## Sorted z where the vertical line x crosses the footprint's edges.
static func _span_at(pts: PackedVector2Array, x: float) -> Array[float]:
	var zs: Array[float] = []
	var n := pts.size()
	for i in n:
		var a := pts[i]
		var b := pts[(i + 1) % n]
		if (a.x <= x and b.x > x) or (b.x <= x and a.x > x):
			zs.append(lerpf(a.y, b.y, (x - a.x) / (b.x - a.x)))
	zs.sort()
	return zs
