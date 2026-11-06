class_name AdScreens
extends Node3D
## The city's advertising: LED screens built onto real facades.
##  * Lumen Circus – the entertainment district round the roundabout at
##    DISTRICT (west CBD, under the City Loop viaduct): big podium screens,
##    corner wraps, vertical strips up the towers, a few full-height building
##    campaigns, rooftop screens on lattice frames and news/market tickers.
##  * Elsewhere, only commercial streets (CBD, midtown, waterfront, docks)
##    get the odd small screen over the shops; Old Town and the suburbs
##    stay quiet.
## Every screen is checked against the layout before it is placed: the face
## must be open (nothing built in front of it), clear of the railway, of
## the façade's own features (fins, fire escapes, canopies – the screen
## stands proud of them or isn't placed) and of players' homes, and no two
## screens on a face overlap. Adverts and motion are all in one material
## (ad_screen.gdshader, one atlas); geometry is static, merged per chunk.
## Night light spill: ad_glow.gdshader halos and street pools, night only.

const DISTRICT := Vector2(318.0, -63.0)
const DISTRICT_R := 200.0
const ATLAS := "res://assets/ads/ads_atlas.png"
const META := "res://assets/ads/ads_meta.json"
const FX := {"sweep": 0, "eq": 1, "streaks": 2, "pulse": 3, "hand": 4, "none": 5, "bubbles": 6, "orbit": 7}
const STANDOFF := 0.42      # screen surface off the wall (m)
const BEZEL := 0.28         # casing round the screen (m)
const CHUNK := 320.0
const NEAR_COMMERCIAL := ["cbd", "midtown", "waterfront", "docks"]
## = CityWorld.HUMAN_LAYER (not referenced: CityWorld owns this node, and a
## class cycle breaks its preloads).
const HUMAN_LAYER := 1 << 5

var layout: CityLayout
var screen_mat: ShaderMaterial
var glow_mat: ShaderMaterial
var screens: Array = []     # placed specs (debug / tests): {kind, c, n, w, h, y0, district}
var _rng := RandomNumberGenerator.new()
var _grid := {}             # Vector2i(50 m) -> [building]
var _rail := {}             # Vector2i(20 m) -> [Vector3]
var _occupied := {}         # building id + face -> [Rect2(u, y)]
var _geo := {}              # chunk key -> {screen: arrays, glow: arrays}
var _glow_nodes: Array[Node3D] = []
var _glow_on := false
var _collision: StaticBody3D


func build(l: CityLayout) -> void:
	var t0 := Time.get_ticks_usec()
	layout = l
	_rng.seed = 0xad5c4ee7
	_materials()
	_index()
	_place_district()
	_place_citywide()
	_assign_offsets()
	_emit_meshes()
	print("AdScreens: %d screens (%d in Lumen Circus), %d ms" % [screens.size(),
		screens.filter(func(s): return s["district"]).size(), (Time.get_ticks_usec() - t0) / 1000])


func set_night(n: float) -> void:
	var on := n > 0.15
	if on == _glow_on:
		return
	_glow_on = on
	for g in _glow_nodes:
		g.visible = on


# ------------------------------------------------------------ materials
func _materials() -> void:
	var meta: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(META))
	var size: Array = meta["size"]
	var W := float(size[0])
	var H := float(size[1])
	var wide := PackedVector4Array()
	var tall := PackedVector4Array()
	var wfx := PackedVector4Array()
	var tfx := PackedVector4Array()
	var acc := PackedVector4Array()
	for ad: Dictionary in meta["ads"]:
		var w: Array = ad["wide"]
		var t: Array = ad["tall"]
		wide.append(Vector4(w[0] / W, w[1] / H, w[2] / W, w[3] / H))
		tall.append(Vector4(t[0] / W, t[1] / H, t[2] / W, t[3] / H))
		var a: Array = ad["wide_fx"]
		var b: Array = ad["tall_fx"]
		wfx.append(Vector4(a[0], a[1], a[2], a[3]))
		tfx.append(Vector4(b[0], b[1], b[2], b[3]))
		var c := Color(ad["accent"])
		acc.append(Vector4(c.r, c.g, c.b, float(FX.get(ad["fx"], 5)) / 8.0))
	var tk := PackedVector4Array()
	var per := PackedFloat32Array()
	for tkr: Dictionary in meta["tickers"]:
		var r: Array = tkr["rect"]
		tk.append(Vector4(r[0] / W, r[1] / H, r[2] / W, r[3] / H))
		per.append(float(tkr["period"]) / W)
	var tex: Texture2D = load(ATLAS)
	screen_mat = ShaderMaterial.new()
	screen_mat.shader = load("res://src/world/shaders/ad_screen.gdshader")
	glow_mat = ShaderMaterial.new()
	glow_mat.shader = load("res://src/world/shaders/ad_glow.gdshader")
	for m: ShaderMaterial in [screen_mat, glow_mat]:
		m.set_shader_parameter("atlas", tex)
		m.set_shader_parameter("wide_rect", wide)
		m.set_shader_parameter("tall_rect", tall)
	screen_mat.set_shader_parameter("wide_fx", wfx)
	screen_mat.set_shader_parameter("tall_fx", tfx)
	screen_mat.set_shader_parameter("accent", acc)
	screen_mat.set_shader_parameter("ticker_rect", tk)
	screen_mat.set_shader_parameter("ticker_period", per)


# ------------------------------------------------------------ indexing
func _index() -> void:
	for b in layout.buildings:
		if not b["kind"] in ["normal", "landmark", "plain", "frame", "bridge", "spire"]:
			continue
		var seen := {}
		for t in b["tiers"]:
			var bx := CityLayout.tier_aabb(b, t)
			for gx in range(floori(bx.position.x / 50.0), floori(bx.end.x / 50.0) + 1):
				for gz in range(floori(bx.position.z / 50.0), floori(bx.end.z / 50.0) + 1):
					var k := Vector2i(gx, gz)
					if seen.has(k):
						continue
					seen[k] = true
					if not _grid.has(k):
						_grid[k] = []
					_grid[k].append(b)
	if layout.rail:
		for line: Dictionary in layout.rail.lines:
			var pts: PackedVector3Array = line["pts"]
			for p in pts:
				var k := Vector2i(floori(p.x / 20.0), floori(p.z / 20.0))
				if not _rail.has(k):
					_rail[k] = []
				_rail[k].append(p)


## Is the world point inside any building (other than `own`)?
func _solid(p: Vector3, own: Dictionary = {}) -> bool:
	for b in _grid.get(Vector2i(floori(p.x / 50.0), floori(p.z / 50.0)), []):
		if not own.is_empty() and is_same(b, own):
			continue
		var lp := CityLayout.bxf(b).affine_inverse() * p
		for t in b["tiers"]:
			if lp.x > t[0] and lp.x < t[2] and lp.z > t[1] and lp.z < t[3] and lp.y > t[4] - 0.5 and lp.y < t[5] + 3.0:
				return true
	return false


func _near_rail(p: Vector3, d: float) -> bool:
	var k := Vector2i(floori(p.x / 20.0), floori(p.z / 20.0))
	for dx in range(-1, 2):
		for dz in range(-1, 2):
			for q: Vector3 in _rail.get(k + Vector2i(dx, dz), []):
				# The viaduct: the deck and its piers below it.
				var flat := Vector2(p.x - q.x, p.z - q.z).length()
				if flat < d and p.y < q.y + 8.0:
					return true
	return false


# ------------------------------------------------------------ faces
## Face k of tier t in the building's local frame: [a, b] (left→right seen
## from outside), outward normal, width. World conversion via bxf.
func _face(b: Dictionary, t: Array, k: int) -> Dictionary:
	var x0: float = t[0]
	var z0: float = t[1]
	var x1: float = t[2]
	var z1: float = t[3]
	var a: Vector3
	var e: Vector3
	var n: Vector3
	match k:
		0:
			a = Vector3(x1, 0, z0); e = Vector3(x0, 0, z0); n = Vector3(0, 0, -1)
		1:
			a = Vector3(x1, 0, z1); e = Vector3(x1, 0, z0); n = Vector3(1, 0, 0)
		2:
			a = Vector3(x0, 0, z1); e = Vector3(x1, 0, z1); n = Vector3(0, 0, 1)
		_:
			a = Vector3(x0, 0, z0); e = Vector3(x0, 0, z1); n = Vector3(-1, 0, 0)
	var xf := CityLayout.bxf(b)
	return {"a": a, "e": e, "n": n, "w": a.distance_to(e), "xf": xf, "k": k,
		"na": xf.basis * n, "aw": xf * a, "ew": xf * e}


## Local-frame point on a face: u metres from its left end, `out` off the wall, at height y.
func _fp(f: Dictionary, u: float, out: float, y: float) -> Vector3:
	var a: Vector3 = f["a"]
	var dir: Vector3 = ((f["e"] as Vector3) - a).normalized()
	return a + dir * u + (f["n"] as Vector3) * out + Vector3(0, y, 0)


## Checks a screen rect on a face (u0..u1 along, y0..y1 up). Returns the
## standoff it needs (proud of any feature it covers) or -1 if it can't go.
func _check(b: Dictionary, f: Dictionary, u0: float, u1: float, y0: float, y1: float, key: String) -> float:
	if u0 < 0.3 or u1 > float(f["w"]) - 0.3 or y1 - y0 < 1.0:
		return -1.0
	for r: Rect2 in _occupied.get(key, []):
		if r.intersects(Rect2(u0 - 1.0, y0 - 1.0, u1 - u0 + 2.0, y1 - y0 + 2.0)):
			return -1.0
	var xf: Transform3D = f["xf"]
	# Open in front: nothing within 7 m of the screen face.
	for su: float in [0.0, 0.5, 1.0]:
		for sy: float in [0.0, 0.5, 1.0]:
			var u := lerpf(u0, u1, su)
			var y := lerpf(y0, y1, sy)
			for out: float in [1.5, 4.0, 7.0]:
				var p: Vector3 = xf * _fp(f, u, out, y)
				if _solid(p) or _near_rail(p, 10.0):
					return -1.0
	# Features on this face: stand proud of them (up to 1.4 m) or give up.
	var need := STANDOFF
	var vol := AABB(_fp(f, u0 - BEZEL, 0.0, y0 - BEZEL), Vector3.ZERO).expand(_fp(f, u1 + BEZEL, 1.6, y1 + BEZEL))
	var feats := BuildingMesher.features(b)
	var boxes: Array = []
	for d in feats["draw"]:
		boxes.append(d[0])
	for c in feats["col"]:
		boxes.append(c)
	for bm in feats["beams"]:
		boxes.append(AABB(bm[0], Vector3.ZERO).expand(bm[1]).grow(maxf(float(bm[2]), float(bm[3]))))
	var n: Vector3 = f["n"]
	var plane := (f["a"] as Vector3).dot(n)
	for box: AABB in boxes:
		if not box.intersects(vol):
			continue
		# How far the feature stands out from the wall.
		# (n is axis-aligned in the local frame: one of the two corners is the
		# furthest out.)
		var out := maxf(box.position.dot(n), box.end.dot(n)) - plane
		need = maxf(need, out + 0.12)
	if need > 1.4:
		return -1.0
	return need


func _claim(key: String, u0: float, u1: float, y0: float, y1: float) -> void:
	if not _occupied.has(key):
		_occupied[key] = []
	_occupied[key].append(Rect2(u0, y0, u1 - u0, y1 - y0))


func _bid(b: Dictionary) -> int:
	return int(float(b["seed"]) * 1e9)


func _usable(b: Dictionary) -> bool:
	return b["kind"] == "normal" and not b.has("apt") and not b.has("shape") and (b["tiers"] as Array).size() > 0


# ------------------------------------------------------------ Lumen Circus
func _place_district() -> void:
	var near: Array = []
	for b in layout.buildings:
		if not _usable(b):
			continue
		var c: Vector2 = CityLayout.base_center(b)
		if c.distance_to(DISTRICT) < DISTRICT_R:
			near.append([c.distance_to(DISTRICT), b])
	near.sort_custom(func(x, y): return x[0] < y[0])
	var full_done := 0
	var wraps := 0
	var roofs := 0
	for e in near:
		var b: Dictionary = e[1]
		var bc: Vector2 = CityLayout.base_center(b)
		var base := BuildingMesher.base_of(b)
		var tiers: Array = b["tiers"]
		var t0: Array = tiers[0]
		var top := BuildingMesher.roof_y(b) - base
		var close := float(e[0]) < 120.0
		var faces: Array = []
		for k in 4:
			var f := _face(b, t0, k)
			var mid: Vector3 = ((f["aw"] as Vector3) + (f["ew"] as Vector3)) * 0.5
			var to_c := Vector3(DISTRICT.x - mid.x, 0, DISTRICT.y - mid.z).normalized()
			faces.append([(f["na"] as Vector3).dot(to_c), f])
		faces.sort_custom(func(x, y): return x[0] > y[0])
		# 1. A corner wrap on the corner nearest the circus (first: the podium
		# screens then fit round it).
		if close and wraps < 9 and float(t0[5]) - base > 22.0:
			if _try_wrap(b, t0, base, faces):
				wraps += 1
		# 2. The podium face toward the circus: a big screen (+ a ticker).
		for fi in 2:
			var score: float = faces[fi][0]
			var f: Dictionary = faces[fi][1]
			if score < (0.2 if fi == 0 else 0.6):
				continue
			var key := "%d:0:%d" % [_bid(b), f["k"]]
			var fw: float = f["w"]
			var th := float(t0[5]) - base
			if fw < 12.0 or th < 18.0:
				continue
			var ticker := _rng.randf() < 0.4
			var y0 := base + (8.8 if ticker else 7.2)
			var w := 0.0
			var h := 0.0
			var u0 := 0.0
			var so := -1.0
			for attempt in 4:  # narrower each time, round whatever is already there
				w = clampf(fw * _rng.randf_range(0.62, 0.86) * (1.0 - 0.17 * attempt), 9.0, 46.0)
				h = clampf(w / _rng.randf_range(1.7, 2.5), 5.0, minf(22.0, th - 12.0))
				u0 = (fw - w) * _rng.randf_range(0.0, 1.0) if attempt > 0 else (fw - w) * _rng.randf_range(0.3, 0.7)
				so = _check(b, f, u0, u0 + w, y0, y0 + h, key)
				if so > 0.0:
					break
			if so > 0.0:
				_add_flat(b, f, key, u0, u0 + w, y0, y0 + h, so, true, 1.0 if close else 0.9)
				if ticker:
					var tu0 := 0.6
					var tso := _check(b, f, tu0, fw - 0.6, base + 6.0, base + 7.5, key)
					if tso > 0.0:
						_add_flat(b, f, key, tu0, fw - 0.6, base + 6.0, base + 7.5, maxf(tso, so), true, 1.0,
							2 + _rng.randi() % 2)
		# 3. Towers: a vertical strip, or (a few) a whole-face campaign.
		for ti in tiers.size():
			var t: Array = tiers[ti]
			var tH := float(t[5]) - maxf(float(t[4]), base)
			if tH < 45.0:
				continue
			var f: Dictionary = _face(b, t, faces[0][1]["k"])
			var key := "%d:%d:%d" % [_bid(b), ti, f["k"]]
			var fw: float = f["w"]
			var ybase := maxf(float(t[4]), base) + (24.0 if ti == 0 else 4.0)
			if full_done < 3 and close and fw > 18.0 and _rng.randf() < 0.55:
				var w := minf(fw * 0.86, 44.0)
				var h := minf(float(t[5]) - 6.0 - ybase, w * 2.2)
				var u0 := (fw - w) * 0.5
				if h > 30.0:
					var so := _check(b, f, u0, u0 + w, ybase, ybase + h, key)
					if so > 0.0:
						_add_flat(b, f, key, u0, u0 + w, ybase, ybase + h, so, true, 1.1)
						full_done += 1
						continue
			if _rng.randf() < 0.6:
				var w := _rng.randf_range(6.5, 9.5)
				var h := minf(float(t[5]) - 5.0 - ybase, _rng.randf_range(34.0, 64.0))
				var u0: float = 0.9 if _rng.randf() < 0.5 else fw - 0.9 - w
				if h > 20.0:
					var so := _check(b, f, u0, u0 + w, ybase, ybase + h, key)
					if so > 0.0:
						_add_flat(b, f, key, u0, u0 + w, ybase, ybase + h, so, true, 1.0)
		# 4. Rooftop screens on the lower blocks, facing the circus.
		if roofs < 7 and top > 14.0 and top < 95.0 and float(e[0]) < 170.0 and _rng.randf() < 0.6:
			if _try_roof(b, faces):
				roofs += 1


func _try_wrap(b: Dictionary, t0: Array, base: float, faces: Array) -> bool:
	# The two faces nearest the circus share a corner if they're adjacent.
	var fa: Dictionary = faces[0][1]
	var fb: Dictionary = faces[1][1]
	if float(faces[1][0]) < -0.2:
		return false
	var ka: int = fa["k"]
	var kb: int = fb["k"]
	# Face k's right end (e) is face (k-1)'s left end (a).
	var left: Dictionary
	var right: Dictionary
	if (kb + 1) % 4 == ka:
		left = fa; right = fb
	elif (ka + 1) % 4 == kb:
		left = fb; right = fa
	else:
		return false
	var wl := _rng.randf_range(9.0, 14.0)
	var wr := _rng.randf_range(9.0, 14.0)
	var h := _rng.randf_range(9.0, 14.0)
	var y0 := base + 9.0 + _rng.randf_range(0.0, 6.0)
	var y1 := y0 + h
	if y1 > float(t0[5]) - 3.0 or float(left["w"]) < wl + 2.0 or float(right["w"]) < wr + 2.0:
		return false
	var kl := "%d:0:%d" % [_bid(b), left["k"]]
	var kr := "%d:0:%d" % [_bid(b), right["k"]]
	var lw: float = left["w"]
	var s1 := _check(b, left, lw - wl, lw - 0.31, y0, y1, kl)
	var s2 := _check(b, right, 0.31, wr, y0, y1, kr)
	if s1 < 0.0 or s2 < 0.0 or maxf(s1, s2) > 0.95:
		return false  # corner wraps only on fairly plain corners
	var so := maxf(s1, s2)
	# The path: along the left face to the corner, round it, along the right.
	var xf: Transform3D = left["xf"]
	var pts: Array[Vector3] = []
	var nrm: Array[Vector3] = []
	var nl: Vector3 = left["n"]
	var nr: Vector3 = right["n"]
	var corner: Vector3 = left["e"]
	pts.append(xf * _fp(left, lw - wl, so, 0.0))
	nrm.append(xf.basis * nl)
	for i in 7:
		var a := float(i) / 6.0
		var dir := nl.slerp(nr, a).normalized()
		pts.append(xf * (corner + dir * so))
		nrm.append(xf.basis * dir)
	pts.append(xf * _fp(right, wr, so, 0.0))
	nrm.append(xf.basis * nr)
	_claim(kl, lw - wl, lw, y0, y1)
	_claim(kr, 0.0, wr, y0, y1)
	_add_path(pts, nrm, y0, y1, 1, true, 1.05, false, so)
	screens[-1]["bkey"] = kl.get_slice(":", 0)
	return true


func _try_roof(b: Dictionary, faces: Array) -> bool:
	var tiers: Array = b["tiers"]
	var t: Array = tiers[-1]
	var f: Dictionary = _face(b, t, faces[0][1]["k"])
	var fw: float = f["w"]
	if fw < 14.0:
		return false
	var roof := BuildingMesher.roof_y(b)
	var w := clampf(fw * 0.7, 12.0, 24.0)
	var h := w * 0.5
	var leg := 3.0
	var u0 := (fw - w) * 0.5
	# Set back 2.5 m from the edge, on the roof (inside the parapet).
	var inset := -2.5
	var xf: Transform3D = f["xf"]
	var y0 := roof + leg
	var y1 := y0 + h
	for su: float in [0.0, 0.5, 1.0]:
		for sy: float in [0.0, 1.0]:
			for out: float in [1.5, 6.0]:
				var p: Vector3 = xf * _fp(f, lerpf(u0, u0 + w, su), out, lerpf(y0, y1, sy))
				if _solid(p) or _near_rail(p, 10.0):
					return false
	# Nothing standing on that strip of roof (tanks, huts, cooling towers):
	# props in the screen's own footprint, behind it to the bracing.
	var inv := xf.affine_inverse()
	var dir: Vector3 = ((f["e"] as Vector3) - (f["a"] as Vector3)).normalized()
	for pr in layout.props:
		if pr is Array and pr.size() > 1 and pr[1] is Transform3D:
			var o: Vector3 = (pr[1] as Transform3D).origin
			if absf(o.y - roof) > 6.0:
				continue
			var lo := inv * o - (f["a"] as Vector3)
			var u := lo.dot(dir)
			var out := lo.dot(f["n"] as Vector3)
			if u > u0 - 3.0 and u < u0 + w + 3.0 and out > inset - 5.0 and out < 0.5:
				return false
	var pts: Array[Vector3] = [xf * _fp(f, u0, inset, 0.0), xf * _fp(f, u0 + w, inset, 0.0)]
	var nrm: Array[Vector3] = [xf.basis * (f["n"] as Vector3), xf.basis * (f["n"] as Vector3)]
	_add_path(pts, nrm, y0, y1, 1, true, 1.0, true)
	screens[-1]["bkey"] = str(_bid(b))
	# Lattice legs and a back frame (solid for people, like rooftop plant).
	var nw: Vector3 = xf.basis * (f["n"] as Vector3)
	var g := _district_geo()
	for su: float in [0.12, 0.5, 0.88]:
		var p: Vector3 = xf * _fp(f, lerpf(u0, u0 + w, su), inset - 0.35, 0.0)
		_box(g["screen"], p + Vector3(0, roof + leg * 0.5 + h * 0.5 - 0.0, 0) - nw * 0.6, Vector3(0.35, leg + h, 0.35), nw, 4)
		_collide(p + Vector3(0, roof + (leg + h) * 0.5, 0) - nw * 0.6, Vector3(0.5, leg + h, 0.5), nw)
		# A brace back to the roof.
		_box(g["screen"], p + Vector3(0, roof + leg * 0.6, 0) - nw * 2.0, Vector3(0.22, 0.22, 3.2), nw, 4, deg_to_rad(-38.0))
	_collide((pts[0] + pts[1]) * 0.5 + Vector3(0, (y0 + y1) * 0.5, 0) - nw * 0.25, Vector3(w + BEZEL * 2.0, h + BEZEL * 2.0, 0.6), nw)
	return true


# ------------------------------------------------------------ citywide
func _place_citywide() -> void:
	for b in layout.buildings:
		if not _usable(b):
			continue
		var c: Vector2 = CityLayout.base_center(b)
		if c.distance_to(DISTRICT) < DISTRICT_R + 20.0:
			continue
		var dist := layout.district(c.x, c.y)
		if not dist in NEAR_COMMERCIAL:
			continue
		var chance := 0.22 if dist in ["cbd", "midtown"] else 0.12
		if _rng.randf() > chance:
			continue
		var base := BuildingMesher.base_of(b)
		var t0: Array = b["tiers"][0]
		if float(t0[5]) - base < 14.0:
			continue
		var order := [0, 1, 2, 3]
		for i in range(3, 0, -1):  # seeded shuffle (deterministic placement)
			var j := _rng.randi() % (i + 1)
			var tmp: int = order[i]
			order[i] = order[j]
			order[j] = tmp
		for k in order:
			var f := _face(b, t0, k)
			# Must face a street: open ground 10 m out isn't in a block.
			var mid: Vector3 = (f["xf"] as Transform3D) * _fp(f, float(f["w"]) * 0.5, 10.0, 0.0)
			if layout.block_at(mid.x, mid.z) >= 0 or not layout.district(mid.x, mid.z) in NEAR_COMMERCIAL:
				continue  # (a quiet street on the other side stays quiet)
			var fw: float = f["w"]
			var big := _rng.randf() < 0.18 and fw > 20.0
			var w := _rng.randf_range(12.0, 16.0) if big else _rng.randf_range(5.0, 8.0)
			var h := w * (0.5 if big else _rng.randf_range(0.45, 0.6))
			if fw < w + 2.0:
				continue
			var u0 := (fw - w) * _rng.randf_range(0.2, 0.8)
			var y0 := base + _rng.randf_range(6.0, 9.0)
			var key := "%d:0:%d" % [_bid(b), k]
			var so := _check(b, f, u0, u0 + w, y0, y0 + h, key)
			if so > 0.0:
				_add_flat(b, f, key, u0, u0 + w, y0, y0 + h, so, false, 0.85)
				break


# ------------------------------------------------------------ geometry
func _chunk_geo(p: Vector3) -> Dictionary:
	var k := Vector2i(floori(p.x / CHUNK), floori(p.z / CHUNK))
	if not _geo.has(k):
		_geo[k] = {"screen": _arrays(), "glow": _arrays(), "far": false}
	return _geo[k]


func _district_geo() -> Dictionary:
	var k := Vector2i(999999, 999999)
	if not _geo.has(k):
		_geo[k] = {"screen": _arrays(), "glow": _arrays(), "far": true}
	return _geo[k]


func _arrays() -> Dictionary:
	return {"v": PackedVector3Array(), "n": PackedVector3Array(), "uv": PackedVector2Array(),
		"uv2": PackedVector2Array(), "c": PackedColorArray(), "i": PackedInt32Array()}


func _add_flat(b: Dictionary, f: Dictionary, key: String, u0: float, u1: float, y0: float, y1: float, so: float,
		district: bool, bright: float, kind := 1) -> void:
	_claim(key, u0, u1, y0, y1)
	var xf: Transform3D = f["xf"]
	var nw: Vector3 = xf.basis * (f["n"] as Vector3)
	var pts: Array[Vector3] = [xf * _fp(f, u0, so, 0.0), xf * _fp(f, u1, so, 0.0)]
	var nrm: Array[Vector3] = [nw, nw]
	_add_path(pts, nrm, y0, y1, kind, district, bright, false, so)
	screens[-1]["bkey"] = key.get_slice(":", 0)


## A screen along a horizontal path (2 points: flat; more: wraps round a
## corner), y0..y1, with its casing back to the wall and the night spill.
func _add_path(pts: Array[Vector3], nrm: Array[Vector3], y0: float, y1: float, kind: int, district: bool,
		bright: float, freestanding := false, depth := STANDOFF) -> void:
	var length := 0.0
	var acc: Array[float] = [0.0]
	for i in range(1, pts.size()):
		length += pts[i].distance_to(pts[i - 1])
		acc.append(length)
	var h := y1 - y0
	var aspect := length / h
	var spec := {"kind": kind, "pts": pts, "n": nrm, "y0": y0, "y1": y1, "aspect": aspect, "district": district,
		"bright": bright, "off": 0, "phase": _rng.randf(), "c": (pts[0] + pts[-1]) * 0.5 + Vector3(0, (y0 + y1) * 0.5, 0),
		"w": length, "h": h, "free": freestanding, "depth": depth}
	screens.append(spec)


func _assign_offsets() -> void:
	# Each screen takes the offset that clashes least with the screens around
	# it: the same advert at once costs most, the next one along (a slot
	# boundary apart) a little; near screens count far more than distant
	# ones. Screens on one building change together (same phase), so on a
	# building the offsets only have to differ.
	var phase_of := {}
	for i in screens.size():
		var s: Dictionary = screens[i]
		if int(s["kind"]) != 1:
			continue
		var bkey: String = s.get("bkey", str(i))
		if not phase_of.has(bkey):
			phase_of[bkey] = _rng.randf()
		s["phase"] = phase_of[bkey]
		var reach := 160.0 if s["district"] else 80.0
		var cost := PackedFloat32Array()
		cost.resize(12)
		for j in i:
			var o: Dictionary = screens[j]
			if int(o["kind"]) != 1:
				continue
			var d := (o["c"] as Vector3).distance_to(s["c"])
			if d > reach:
				continue
			var w := 1.0 / (1.0 + d / 18.0)
			var same_b: bool = o.get("bkey", "") == bkey
			var oo: int = o["off"]
			cost[oo] += 4.0 * w + (10.0 if same_b else 0.0)
			if not same_b:
				cost[(oo + 1) % 12] += 1.0 * w
				cost[(oo + 11) % 12] += 1.0 * w
		var best := INF
		var picks: Array = []
		for o in 12:
			if cost[o] < best - 0.001:
				best = cost[o]
				picks = [o]
			elif absf(cost[o] - best) <= 0.001:
				picks.append(o)
		s["off"] = picks[_rng.randi() % picks.size()]


func _emit_meshes() -> void:
	for s: Dictionary in screens:
		# Lumen Circus is one mesh (one draw call); street screens elsewhere
		# are merged per chunk.
		var g := _district_geo() if s["district"] else _chunk_geo(s["c"])
		_screen_geo(g, s)
	_collision_flush()
	for k in _geo:
		var g: Dictionary = _geo[k]
		var range_end := 1500.0 if g["far"] else 520.0
		var mi := _mesh_instance(g["screen"], screen_mat, range_end)
		if mi:
			mi.name = "Ads_%d_%d" % [k.x, k.y]
			add_child(mi)
		var gi := _mesh_instance(g["glow"], glow_mat, minf(range_end, 700.0))
		if gi:
			gi.name = "AdGlow_%d_%d" % [k.x, k.y]
			gi.visible = false
			add_child(gi)
			_glow_nodes.append(gi)


func _mesh_instance(a: Dictionary, mat: Material, range_end: float) -> MeshInstance3D:
	if (a["i"] as PackedInt32Array).is_empty():
		return null
	var arr := []
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = a["v"]
	arr[Mesh.ARRAY_NORMAL] = a["n"]
	arr[Mesh.ARRAY_TEX_UV] = a["uv"]
	arr[Mesh.ARRAY_TEX_UV2] = a["uv2"]
	arr[Mesh.ARRAY_COLOR] = a["c"]
	arr[Mesh.ARRAY_INDEX] = a["i"]
	var m := ArrayMesh.new()
	m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
	m.surface_set_material(0, mat)
	var mi := MeshInstance3D.new()
	mi.mesh = m
	# (Flush on the walls: their shadows would be a sliver – not worth the
	# extra shadow-pass draw calls.)
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mi.visibility_range_end = range_end
	mi.visibility_range_end_margin = 40.0
	mi.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_DISABLED
	return mi


func _screen_geo(g: Dictionary, s: Dictionary) -> void:
	var pts: Array[Vector3] = s["pts"]
	var nrm: Array[Vector3] = s["n"]
	var y0: float = s["y0"]
	var y1: float = s["y1"]
	var kind: int = s["kind"]
	var aspect: float = s["aspect"]
	var code := Vector2(float(kind) + 8.0 * float(s["off"]), aspect)
	var col := Color(s["phase"], clampf(float(s["bright"]), 0.0, 2.0), 0.0, 1.0)
	var bez_code := Vector2(0.0, aspect)
	var A: Dictionary = g["screen"]
	var length: float = s["w"]
	var acc := 0.0
	var free: bool = s["free"]
	var depth: float = s["depth"]
	var back := depth if not free else 0.5
	for i in range(1, pts.size()):
		var p0: Vector3 = pts[i - 1]
		var p1: Vector3 = pts[i]
		var n0: Vector3 = nrm[i - 1]
		var n1: Vector3 = nrm[i]
		var seg := p0.distance_to(p1)
		var ua := acc / length
		var ub := (acc + seg) / length
		acc += seg
		# The screen face.
		_quad(A, [p0 + Vector3(0, y1, 0), p1 + Vector3(0, y1, 0), p1 + Vector3(0, y0, 0), p0 + Vector3(0, y0, 0)],
			[n0, n1, n1, n0], [Vector2(ua, 0), Vector2(ub, 0), Vector2(ub, 1), Vector2(ua, 1)], code, col)
		# Casing: a frame strip above and below the screen, and its top and
		# bottom faces back to the wall (or the back panel).
		var t0 := p0 + Vector3(0, y1 + BEZEL, 0)
		var t1 := p1 + Vector3(0, y1 + BEZEL, 0)
		var b0 := p0 + Vector3(0, y0 - BEZEL, 0)
		var b1 := p1 + Vector3(0, y0 - BEZEL, 0)
		var z := [Vector2.ZERO, Vector2.ZERO, Vector2.ZERO, Vector2.ZERO]
		_quad(A, [t0, t1, p1 + Vector3(0, y1, 0), p0 + Vector3(0, y1, 0)], [n0, n1, n1, n0], z, bez_code, col)
		_quad(A, [p0 + Vector3(0, y0, 0), p1 + Vector3(0, y0, 0), b1, b0], [n0, n1, n1, n0], z, bez_code, col)
		_quad(A, [t0 - n0 * back, t1 - n1 * back, t1, t0], [Vector3.UP, Vector3.UP, Vector3.UP, Vector3.UP], z, bez_code, col)
		_quad(A, [b0, b1, b1 - n1 * back, b0 - n0 * back], [Vector3.DOWN, Vector3.DOWN, Vector3.DOWN, Vector3.DOWN], z, bez_code, col)
		if free:
			# Freestanding: a steel back panel.
			_quad(A, [t1 - n1 * back, t0 - n0 * back, b0 - n0 * back, b1 - n1 * back], [-n1, -n0, -n0, -n1], z,
				Vector2(4.0, aspect), col)
	# End caps (left and right edges of the casing).
	for end in [0, pts.size() - 1]:
		var p: Vector3 = pts[end]
		var n: Vector3 = nrm[end]
		var along: Vector3 = (pts[1] - pts[0]).normalized() if end == 0 else (pts[end] - pts[end - 1]).normalized()
		var sgn := -1.0 if end == 0 else 1.0
		var o := along * BEZEL * sgn
		var side := along * sgn
		var z := [Vector2.ZERO, Vector2.ZERO, Vector2.ZERO, Vector2.ZERO]
		var q := [p + o + Vector3(0, y1 + BEZEL, 0), p + o + Vector3(0, y0 - BEZEL, 0),
			p + o - n * back + Vector3(0, y0 - BEZEL, 0), p + o - n * back + Vector3(0, y1 + BEZEL, 0)]
		_quad(A, q, [side, side, side, side], z, bez_code, col)
		# The bezel's front strip at the end.
		_quad(A, [p + Vector3(0, y1 + BEZEL, 0), p + o + Vector3(0, y1 + BEZEL, 0), p + o + Vector3(0, y0 - BEZEL, 0),
			p + Vector3(0, y0 - BEZEL, 0)], [n, n, n, n], z, bez_code, col)
	# Night spill: a halo on the wall round it, a pool on the ground in front.
	var G: Dictionary = g["glow"]
	var m := minf(0.3 * (y1 - y0), 4.0)
	var mv := m / (y1 - y0)
	var gcol := Color(s["phase"], clampf(float(s["bright"]), 0.0, 2.0), 0.0, mv)
	var pa: Vector3 = pts[0] - (pts[1] - pts[0]).normalized() * m - nrm[0] * 0.3
	var pb: Vector3 = pts[-1] + (pts[-1] - pts[-2]).normalized() * m - nrm[-1] * 0.3
	var mu := m / length
	if pts.size() == 2 and not free:
		_quad(G, [pa + Vector3(0, y1 + m, 0), pb + Vector3(0, y1 + m, 0), pb + Vector3(0, y0 - m, 0), pa + Vector3(0, y0 - m, 0)],
			[nrm[0], nrm[0], nrm[0], nrm[0]], [Vector2(-mu, -mv), Vector2(1.0 + mu, -mv), Vector2(1.0 + mu, 1.0 + mv), Vector2(-mu, 1.0 + mv)],
			code, gcol)
	# The pool: on whatever is below the screen's middle, reaching out ~ its height.
	var mid: Vector3 = (pts[0] + pts[-1]) * 0.5
	var nm: Vector3 = (nrm[0] + nrm[-1]).normalized()
	var gy := layout.ground_y(mid.x + nm.x * 4.0, mid.z + nm.z * 4.0) + 0.06
	if free:
		gy = y0 - 3.0 + 0.08  # rooftop screens: their roof
	var reach := clampf((y1 - y0) * 1.1, 6.0, 22.0)
	if y0 - gy < 40.0:
		var gc := Color(s["phase"], clampf(float(s["bright"]) * clampf(1.2 - (y0 - gy) / 40.0, 0.2, 1.0), 0.0, 2.0), 1.0, 1.0)
		var e0: Vector3 = pts[0] - (pts[1] - pts[0]).normalized() * 2.0
		var e1: Vector3 = pts[-1] + (pts[-1] - pts[-2]).normalized() * 2.0
		var u := Vector3.UP
		_quad(G, [Vector3(e0.x, gy, e0.z), Vector3(e1.x, gy, e1.z), Vector3(e1.x, gy, e1.z) + nm * reach, Vector3(e0.x, gy, e0.z) + nm * reach],
			[u, u, u, u], [Vector2(0, 0), Vector2(1, 0), Vector2(1, 1), Vector2(0, 1)], code, gc)


## Quad a-b-c-d (any winding), facing its normals.
func _quad(A: Dictionary, q: Array, n: Array, uv: Array, code: Vector2, col: Color) -> void:
	var base := (A["v"] as PackedVector3Array).size()
	for i in 4:
		A["v"].append(q[i])
		A["n"].append(n[i])
		A["uv"].append(uv[i])
		A["uv2"].append(code)
		A["c"].append(col)
	var face := ((q[1] as Vector3) - (q[0] as Vector3)).cross((q[2] as Vector3) - (q[0] as Vector3))
	var want := (n[0] as Vector3) + (n[2] as Vector3)
	if face.dot(want) < 0.0:
		A["i"].append_array([base, base + 1, base + 2, base, base + 2, base + 3])
	else:
		A["i"].append_array([base, base + 2, base + 1, base, base + 3, base + 2])


## An oriented box (steelwork): centre, size (x across, y up, z along -n), facing n, tilted about its x.
func _box(A: Dictionary, c: Vector3, size: Vector3, n: Vector3, kind: int, tilt := 0.0) -> void:
	var z := n.normalized()
	var x := Vector3.UP.cross(z).normalized()
	var B := Basis(x, Vector3.UP, z) * Basis(Vector3.RIGHT, tilt)
	var h := size * 0.5
	var code := Vector2(float(kind), 1.0)
	var col := Color(0, 1, 0, 1)
	var zz := [Vector2.ZERO, Vector2.ZERO, Vector2.ZERO, Vector2.ZERO]
	for ax in 3:
		for sg: float in [-1.0, 1.0]:
			var nl := Vector3.ZERO
			nl[ax] = sg
			var u := Vector3.ZERO
			u[(ax + 1) % 3] = 1.0
			var v := Vector3.ZERO
			v[(ax + 2) % 3] = 1.0
			var corners := []
			for cu: float in [-1.0, 1.0]:
				for cv: float in ([-1.0, 1.0] if cu < 0.0 else [1.0, -1.0]):
					corners.append(c + B * ((nl + u * cu + v * cv) * h))
			var nw := B * nl
			_quad(A, corners, [nw, nw, nw, nw], zz, code, col)


# ------------------------------------------------------------ collision
var _col_boxes: Array = []


func _collide(c: Vector3, size: Vector3, n: Vector3) -> void:
	_col_boxes.append([c, size, n])


func _collision_flush() -> void:
	if _col_boxes.is_empty():
		return
	_collision = StaticBody3D.new()
	_collision.name = "AdCollision"
	_collision.collision_layer = HUMAN_LAYER
	_collision.collision_mask = 0
	add_child(_collision)
	for cb in _col_boxes:
		var cs := CollisionShape3D.new()
		var sh := BoxShape3D.new()
		sh.size = cb[1]
		cs.shape = sh
		var z: Vector3 = (cb[2] as Vector3).normalized()
		var x := Vector3.UP.cross(z).normalized()
		cs.transform = Transform3D(Basis(x, Vector3.UP, z), cb[0])
		_collision.add_child(cs)
