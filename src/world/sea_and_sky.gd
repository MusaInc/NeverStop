class_name SeaAndSky
extends Node3D
## Life on the water and in the air round the island – all visual (no
## collision, no physics): nothing here can change a swing, a recorded
## course or a bot run.
##
##   * The port: container ships come in from the open sea up the strait to a
##     berth along the docks quay, lie there a while, are turned by their tugs
##     and steam back out to sea. More ships pass along the shipping lanes
##     east and north of the island.
##   * Boats: motor boats and yachts cruising loops round the bays, with a
##     white wake.
##   * The sky: a news helicopter circling the business district, an airliner
##     crossing high over the city every couple of minutes, and gulls wheeling
##     over the beach, the docks, the marina and behind the ships.
##   * Navigation lights (red / green / white, the helicopter's beacon) glow at
##     night (set_night).
##
## Meshes are procedural (SurfaceTool boxes and prisms, vertex colours): a
## ship is a few hundred triangles. Routes are checked against
## CityLayout.is_water when built; a route that would touch land is dropped.

const SEA_Y := -1.6              # the drawn sea surface (CityWorld._build_water)
const SHIP_SPEED := 7.0          # m/s at sea (~14 knots)
const BERTH_TIME := 75.0         # s alongside before the tugs turn her
const TURN_TIME := 40.0          # s to swing her round at the berth
const HULLS := [Color(0.12, 0.16, 0.24), Color(0.55, 0.1, 0.08), Color(0.1, 0.1, 0.11), Color(0.16, 0.3, 0.42),
	Color(0.2, 0.32, 0.22)]
const BOX_COLORS := [Color(0.72, 0.18, 0.12), Color(0.12, 0.32, 0.55), Color(0.85, 0.6, 0.12),
	Color(0.2, 0.45, 0.3), Color(0.82, 0.82, 0.8), Color(0.45, 0.22, 0.4), Color(0.9, 0.4, 0.12), Color(0.3, 0.3, 0.33)]
const WHITE := Color(0.93, 0.93, 0.9)

var layout: CityLayout
var rng := RandomNumberGenerator.new()
var _mat: StandardMaterial3D
var _lamp_mat: StandardMaterial3D
var _wake_mat: StandardMaterial3D
var _ships: Array = []     # {node, path, s, state, t, speed, len, dir, bob}
var _boats: Array = []     # {node, c, r, a, w, bob}
var _heli: Node3D
var _heli_rotor: Node3D
var _heli_tail: Node3D
var _heli_a := 0.0
var _plane: Node3D
var _plane_t := 0.0
var _plane_from := Vector3.ZERO
var _plane_dir := Vector3.FORWARD
var _blinkers: Array[Node3D] = []
var _time := 0.0


func setup(l: CityLayout) -> void:
	layout = l
	rng.seed = l.seed * 53 + 11
	_materials()
	_port_ships()
	_lane_ships()
	_boats_on_loops()
	_helicopter()
	_airliner()
	_gulls()
	print("SeaAndSky: %d ships, %d boats, helicopter, airliner" % [_ships.size(), _boats.size()])


func set_night(n: float) -> void:
	if _lamp_mat:
		_lamp_mat.emission_energy_multiplier = lerpf(0.4, 5.0, n)


# ------------------------------------------------------------ materials
func _materials() -> void:
	_mat = StandardMaterial3D.new()
	_mat.vertex_color_use_as_albedo = true
	_mat.roughness = 0.75
	_lamp_mat = StandardMaterial3D.new()
	_lamp_mat.vertex_color_use_as_albedo = true
	_lamp_mat.emission_enabled = true
	_lamp_mat.emission_operator = BaseMaterial3D.EMISSION_OP_ADD
	_lamp_mat.emission = Color(1, 1, 1)
	_lamp_mat.emission_energy_multiplier = 0.4
	_lamp_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_wake_mat = StandardMaterial3D.new()
	_wake_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_wake_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_wake_mat.vertex_color_use_as_albedo = true
	_wake_mat.cull_mode = BaseMaterial3D.CULL_DISABLED


# ------------------------------------------------------------ mesh kit
## Axis-aligned box (in the part's own frame) into a SurfaceTool.
static func _box(st: SurfaceTool, c: Vector3, size: Vector3, col: Color, xf := Transform3D.IDENTITY) -> void:
	var h := size * 0.5
	var faces := [
		[Vector3.RIGHT, [Vector3(1, -1, -1), Vector3(1, 1, -1), Vector3(1, 1, 1), Vector3(1, -1, 1)]],
		[Vector3.LEFT, [Vector3(-1, -1, 1), Vector3(-1, 1, 1), Vector3(-1, 1, -1), Vector3(-1, -1, -1)]],
		[Vector3.UP, [Vector3(-1, 1, -1), Vector3(-1, 1, 1), Vector3(1, 1, 1), Vector3(1, 1, -1)]],
		[Vector3.DOWN, [Vector3(-1, -1, 1), Vector3(-1, -1, -1), Vector3(1, -1, -1), Vector3(1, -1, 1)]],
		[Vector3.BACK, [Vector3(1, -1, 1), Vector3(1, 1, 1), Vector3(-1, 1, 1), Vector3(-1, -1, 1)]],
		[Vector3.FORWARD, [Vector3(-1, -1, -1), Vector3(-1, 1, -1), Vector3(1, 1, -1), Vector3(1, -1, -1)]],
	]
	for f in faces:
		var n: Vector3 = xf.basis * (f[0] as Vector3)
		var q: Array = f[1]
		var p: Array = []
		for v: Vector3 in q:
			p.append(xf * (c + v * h))
		for idx in [0, 2, 1, 0, 3, 2]:  # (front faces wind clockwise)
			st.set_color(col)
			st.set_normal(n.normalized())
			st.add_vertex(p[idx])


## A vertical prism over a convex outline (xz), y0..y1.
static func _prism(st: SurfaceTool, pts: PackedVector2Array, y0: float, y1: float, col: Color, top_col := Color.TRANSPARENT) -> void:
	var n := pts.size()
	var c := Vector2.ZERO
	for p in pts:
		c += p
	c /= n
	for i in n:
		var a := pts[i]
		var b := pts[(i + 1) % n]
		var nrm := Vector3(b.y - a.y, 0.0, -(b.x - a.x)).normalized()
		if Vector2(nrm.x, nrm.z).dot((a + b) * 0.5 - c) < 0.0:
			nrm = -nrm
		var quad := [Vector3(a.x, y0, a.y), Vector3(a.x, y1, a.y), Vector3(b.x, y1, b.y), Vector3(b.x, y0, b.y)]
		var order := [0, 1, 2, 0, 2, 3]
		if ((quad[1] as Vector3) - quad[0]).cross((quad[2] as Vector3) - quad[0]).dot(nrm) > 0.0:
			order = [0, 2, 1, 0, 3, 2]
		for idx in order:
			st.set_color(col)
			st.set_normal(nrm)
			st.add_vertex(quad[idx])
		# Deck: a fan from the centre.
		var tc := top_col if top_col.a > 0.0 else col
		var t := [Vector3(c.x, y1, c.y), Vector3(a.x, y1, a.y), Vector3(b.x, y1, b.y)]
		var to := [0, 1, 2] if ((t[1] as Vector3) - t[0]).cross((t[2] as Vector3) - t[0]).y < 0.0 else [0, 2, 1]
		for idx in to:
			st.set_color(tc)
			st.set_normal(Vector3.UP)
			st.add_vertex(t[idx])


func _mesh_node(st: SurfaceTool, mat: Material, name_: String) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.name = name_
	mi.mesh = st.commit()
	mi.material_override = mat
	return mi


## A hull outline: straight sides, a pointed bow at -Z, a squarer stern.
static func _hull_outline(length: float, beam: float, bow := 0.18) -> PackedVector2Array:
	var h := length * 0.5
	var b := beam * 0.5
	return PackedVector2Array([Vector2(0, -h), Vector2(b, -h + length * bow), Vector2(b, h - 2.0),
		Vector2(b * 0.85, h), Vector2(-b * 0.85, h), Vector2(-b, h - 2.0), Vector2(-b, -h + length * bow)])


# ------------------------------------------------------------ ships
## A container ship facing -Z, waterline at y = 0: dark hull with a red
## boot-top, a white superstructure and funnel aft, container stacks forward.
func _container_ship(length: float) -> Node3D:
	var root := Node3D.new()
	root.name = "Ship"
	var beam := length * 0.15
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var hull: Color = HULLS[rng.randi() % HULLS.size()]
	_prism(st, _hull_outline(length, beam + 0.3), -3.0, 1.2, Color(0.55, 0.12, 0.1))       # boot-top
	_prism(st, _hull_outline(length, beam), 1.2, 9.0, hull, Color(0.32, 0.3, 0.28))        # topsides + deck
	# Container stacks: bays of 12 m along the forward 70 %, rows across.
	var bays := int(length * 0.62 / 13.0)
	for i in bays:
		var z := -length * 0.36 + i * 13.0
		var tiers := rng.randi_range(2, 5)
		var rows := int((beam - 2.0) / 2.6)
		for r in rows:
			var x := -beam * 0.5 + 1.0 + (r + 0.5) * 2.6
			var hgt := rng.randi_range(maxi(1, tiers - 2), tiers)
			for k in hgt:
				var col: Color = BOX_COLORS[rng.randi() % BOX_COLORS.size()]
				_box(st, Vector3(x, 9.0 + 1.3 + k * 2.6, z), Vector3(2.45, 2.5, 12.0), col.darkened(rng.randf_range(0.0, 0.2)))
	# Superstructure aft: a tall white block, bridge wings, funnel.
	var sz := length * 0.5 - length * 0.12
	_box(st, Vector3(0, 9.0 + 9.0, sz), Vector3(beam * 0.8, 18.0, length * 0.09), WHITE)
	_box(st, Vector3(0, 9.0 + 16.8, sz - length * 0.045 - 0.3), Vector3(beam * 0.78, 1.6, 0.4), Color(0.08, 0.1, 0.12))  # bridge windows
	_box(st, Vector3(0, 9.0 + 17.2, sz - 2.0), Vector3(beam + 2.0, 1.2, 3.0), WHITE)  # bridge wings
	_box(st, Vector3(0, 9.0 + 22.0, sz + length * 0.06), Vector3(4.5, 9.0, 6.0), hull)  # funnel
	_box(st, Vector3(0, 9.0 + 26.8, sz + length * 0.06), Vector3(4.6, 1.2, 6.1), Color(0.85, 0.65, 0.12))
	_box(st, Vector3(0, 9.0 + 24.0, sz - 3.0), Vector3(0.5, 10.0, 0.5), Color(0.8, 0.8, 0.78))  # mast
	root.add_child(_mesh_node(st, _mat, "Hull"))
	var lamps := SurfaceTool.new()
	lamps.begin(Mesh.PRIMITIVE_TRIANGLES)
	_box(lamps, Vector3(beam * 0.5 + 1.0, 9.0 + 17.6, sz - 2.0), Vector3(0.7, 0.7, 0.7), Color(0.1, 0.9, 0.2))   # starboard green
	_box(lamps, Vector3(-beam * 0.5 - 1.0, 9.0 + 17.6, sz - 2.0), Vector3(0.7, 0.7, 0.7), Color(0.95, 0.1, 0.08))  # port red
	_box(lamps, Vector3(0, 9.0 + 29.2, sz - 3.0), Vector3(0.8, 0.8, 0.8), Color(1, 1, 0.92))   # masthead
	_box(lamps, Vector3(0, 10.0, length * 0.5 - 0.5), Vector3(0.8, 0.8, 0.5), Color(1, 1, 0.92))  # stern
	_box(lamps, Vector3(0, 10.5, -length * 0.5 + 2.0), Vector3(0.6, 0.6, 0.6), Color(1, 1, 0.92))  # bow
	root.add_child(_mesh_node(lamps, _lamp_mat, "Lights"))
	root.add_child(_wake(beam * 1.2, length * 1.6, length * 0.5))
	return root


## A white V of foam trailing astern (z > 0 is behind).
func _wake(width: float, length: float, start: float) -> MeshInstance3D:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var a := Color(1, 1, 1, 0.32)
	var b := Color(1, 1, 1, 0.0)
	var y := 0.15
	var pts := [Vector3(-width * 0.3, y, start - 2.0), Vector3(width * 0.3, y, start - 2.0),
		Vector3(width * 1.4, y, start + length), Vector3(-width * 1.4, y, start + length)]
	var cols := [a, a, b, b]
	for idx in [0, 1, 2, 0, 2, 3]:
		st.set_color(cols[idx])
		st.set_normal(Vector3.UP)
		st.add_vertex(pts[idx])
	var mi := _mesh_node(st, _wake_mat, "Wake")
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return mi


## A route is usable when every point along it (every 40 m) is open water
## and well off the coast (the hull's half-beam + margin either side).
func _route_ok(pts: PackedVector3Array, clear: float) -> bool:
	for i in pts.size() - 1:
		var a := pts[i]
		var b := pts[i + 1]
		var n := maxi(1, int(a.distance_to(b) / 40.0))
		for k in n + 1:
			var p := a.lerp(b, k / float(n))
			for o: Vector3 in [Vector3.ZERO, Vector3(clear, 0, 0), Vector3(-clear, 0, 0), Vector3(0, 0, clear), Vector3(0, 0, -clear)]:
				if not layout.is_water(p + o):
					return false
	return true


func _add_ship(path: PackedVector3Array, length: float, mode: String, start_s := 0.0) -> void:
	var node := _container_ship(length)
	add_child(node)
	var total := 0.0
	for i in path.size() - 1:
		total += path[i].distance_to(path[i + 1])
	_ships.append({"node": node, "path": path, "total": total, "s": start_s, "dir": 1.0, "state": "sail",
		"t": 0.0, "mode": mode, "len": length, "yaw": 0.0, "phase": rng.randf() * TAU, "speed": SHIP_SPEED})
	_place_ship(_ships[-1], 0.0, true)


## The port: one ship working the berth on the docks quay (in, alongside,
## turned, out to sea, and back in again later).
func _port_ships() -> void:
	var berth := Vector3(CityLayout.RIVER_EDGE - 19.0, 0, 440.0)
	var path := PackedVector3Array([Vector3(-250, 0, 2600), Vector3(-250, 0, 1000), Vector3(-210, 0, 700),
		Vector3(-90, 0, 520), Vector3(berth.x - 8.0, 0, 470.0), berth])
	if _route_ok(path.slice(0, path.size() - 1), 18.0):
		_add_ship(path, 150.0, "port", 1550.0)  # (already coming in when you arrive)
	else:
		push_warning("SeaAndSky: port route crosses land; no port ship")


## Ships passing the island on the lanes east and north (loop end to end,
## far out in the haze).
func _lane_ships() -> void:
	var lanes := [
		[PackedVector3Array([Vector3(1450, 0, -3200), Vector3(1450, 0, 3200)]), 0.0],
		[PackedVector3Array([Vector3(1720, 0, 3200), Vector3(1720, 0, -3200)]), 2600.0],
		[PackedVector3Array([Vector3(3000, 0, -1250), Vector3(-200, 0, -1250)]), 1200.0],
		[PackedVector3Array([Vector3(-150, 0, 1500), Vector3(3000, 0, 1500)]), 600.0],
	]
	for ln in lanes:
		var pth: PackedVector3Array = ln[0]
		if _route_ok(pth, 30.0):
			_add_ship(pth, rng.randf_range(170.0, 230.0), "lane", ln[1])


func _place_ship(sh: Dictionary, dt: float, snap := false) -> void:
	var path: PackedVector3Array = sh["path"]
	var s: float = sh["s"]
	var p := path[0]
	var tangent := Vector3.FORWARD
	var acc := 0.0
	for i in path.size() - 1:
		var seg := path[i].distance_to(path[i + 1])
		if s <= acc + seg or i == path.size() - 2:
			var k := clampf((s - acc) / maxf(seg, 0.001), 0.0, 1.0)
			p = path[i].lerp(path[i + 1], k)
			tangent = (path[i + 1] - path[i]).normalized()
			break
		acc += seg
	var want_yaw := atan2(-tangent.x, -tangent.z) if float(sh["dir"]) > 0.0 else atan2(tangent.x, tangent.z)
	if sh["state"] == "turn":
		want_yaw = float(sh["turn_to"])
	var y: float = sh["yaw"]
	if snap:
		y = want_yaw
	else:
		var rate := deg_to_rad(4.5) if sh["state"] != "turn" else PI / TURN_TIME
		y += clampf(wrapf(want_yaw - y, -PI, PI), -rate * dt, rate * dt)
	sh["yaw"] = y
	var ph: float = sh["phase"] + _time * 0.35
	var n: Node3D = sh["node"]
	n.transform = Transform3D(Basis.from_euler(Vector3(sin(ph) * 0.012, y, sin(ph * 0.7) * 0.02)),
		Vector3(p.x, SEA_Y + sin(ph * 1.3) * 0.25, p.z))
	(n.get_node("Wake") as Node3D).visible = sh["state"] == "sail" and float(sh["speed"]) > 2.0


func _update_ship(sh: Dictionary, dt: float) -> void:
	var total: float = sh["total"]
	match String(sh["state"]):
		"sail":
			var s: float = sh["s"]
			var to_end := (total - s) if float(sh["dir"]) > 0.0 else s
			var spd := SHIP_SPEED
			if sh["mode"] == "port":
				# Slow ahead into the berth, and gather way leaving it.
				spd = lerpf(1.2, SHIP_SPEED, clampf((total - s) / 450.0, 0.0, 1.0))
			sh["speed"] = spd
			sh["s"] = clampf(s + spd * dt * float(sh["dir"]), 0.0, total)
			if to_end <= 0.01:
				if sh["mode"] == "lane":
					sh["s"] = 0.0  # back to the far end of the lane, out in the haze
					_place_ship(sh, 0.0, true)
					return
				if float(sh["dir"]) > 0.0:
					sh["state"] = "berth"
					sh["t"] = 0.0
				else:
					sh["state"] = "away"
					sh["t"] = 0.0
		"berth":
			sh["speed"] = 0.0
			sh["t"] = float(sh["t"]) + dt
			if float(sh["t"]) > BERTH_TIME:
				sh["state"] = "turn"
				sh["t"] = 0.0
				sh["turn_to"] = wrapf(float(sh["yaw"]) + PI, -PI, PI)
		"turn":
			sh["t"] = float(sh["t"]) + dt
			if float(sh["t"]) > TURN_TIME:
				sh["state"] = "sail"
				sh["dir"] = -1.0
		"away":
			# Out past the haze: a while at sea, then the next call comes in.
			sh["t"] = float(sh["t"]) + dt
			if float(sh["t"]) > 90.0:
				sh["state"] = "sail"
				sh["dir"] = 1.0
				sh["s"] = 0.0
				_place_ship(sh, 0.0, true)
				return
	_place_ship(sh, dt)


# ------------------------------------------------------------ boats
func _motorboat(length: float) -> Node3D:
	var root := Node3D.new()
	root.name = "Boat"
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var hull: Color = WHITE if rng.randf() < 0.7 else [Color(0.15, 0.25, 0.45), Color(0.6, 0.12, 0.1)][rng.randi() % 2]
	_prism(st, _hull_outline(length, length * 0.34, 0.3), -0.4, 1.0, hull, Color(0.7, 0.6, 0.45))
	_box(st, Vector3(0, 1.7, length * 0.08), Vector3(length * 0.24, 1.4, length * 0.3), WHITE)
	_box(st, Vector3(0, 1.75, length * 0.08 - length * 0.15), Vector3(length * 0.23, 0.8, 0.15), Color(0.1, 0.13, 0.16))
	root.add_child(_mesh_node(st, _mat, "Hull"))
	root.add_child(_wake(length * 0.4, length * 4.0, length * 0.5))
	return root


func _yacht(length: float) -> Node3D:
	var root := Node3D.new()
	root.name = "Boat"
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	_prism(st, _hull_outline(length, length * 0.3, 0.32), -0.5, 0.9, WHITE, Color(0.72, 0.6, 0.42))
	_box(st, Vector3(0, 1.3, length * 0.1), Vector3(length * 0.2, 0.8, length * 0.25), WHITE)
	var mast_h := length * 1.35
	_box(st, Vector3(0, 0.9 + mast_h * 0.5, -length * 0.08), Vector3(0.18, mast_h, 0.18), Color(0.8, 0.8, 0.8))
	# Mainsail and jib: flat triangles (both sides).
	var sail := Color(0.97, 0.96, 0.92) if rng.randf() < 0.8 else Color(0.9, 0.35, 0.25)
	for tri in [[Vector3(0, 1.6, -length * 0.08), Vector3(0, 0.9 + mast_h * 0.95, -length * 0.08), Vector3(0, 1.6, length * 0.38)],
			[Vector3(0, 1.4, -length * 0.12), Vector3(0, 0.9 + mast_h * 0.8, -length * 0.1), Vector3(0, 1.2, -length * 0.48)]]:
		for side in [1.0, -1.0]:
			for v: Vector3 in (tri if side > 0.0 else [tri[0], tri[2], tri[1]]):
				st.set_color(sail)
				st.set_normal(Vector3(side, 0, 0))
				st.add_vertex(v)
	root.add_child(_mesh_node(st, _mat, "Hull"))
	root.add_child(_wake(length * 0.3, length * 2.5, length * 0.5))
	return root


## Loops in the bays: each an ellipse checked against the coast (shrunk until
## it fits, or dropped).
func _boats_on_loops() -> void:
	var loops := [
		[Vector2(1230, -120), Vector2(140, 320)], [Vector2(1190, 380), Vector2(110, 160)],
		[Vector2(380, -880), Vector2(230, 90)], [Vector2(-210, -330), Vector2(110, 170)],
		[Vector2(-200, 230), Vector2(90, 150)], [Vector2(330, 860), Vector2(260, 110)],
		[Vector2(800, -860), Vector2(160, 80)], [Vector2(-230, 900), Vector2(120, 200)],
	]
	for lp in loops:
		var c: Vector2 = lp[0]
		var r: Vector2 = lp[1]
		var ok := false
		for shrink in [1.0, 0.75, 0.55]:
			ok = true
			for i in 24:
				var a := TAU * i / 24.0
				var p: Vector2 = c + Vector2(cos(a) * r.x, sin(a) * r.y) * shrink
				if not layout.is_water(Vector3(p.x, 0, p.y)) or not layout.is_water(Vector3(p.x + 12, 0, p.y)) \
						or not layout.is_water(Vector3(p.x - 12, 0, p.y)):
					ok = false
					break
			if ok:
				r *= shrink
				break
		if not ok:
			continue
		var yacht := rng.randf() < 0.45
		var length := rng.randf_range(9.0, 14.0) if yacht else rng.randf_range(7.0, 12.0)
		var node := _yacht(length) if yacht else _motorboat(length)
		add_child(node)
		var spd := rng.randf_range(4.0, 6.0) if yacht else rng.randf_range(9.0, 15.0)
		var dir := 1.0 if rng.randf() < 0.5 else -1.0
		# Angular speed from the mean radius (close enough on an ellipse).
		_boats.append({"node": node, "c": c, "r": r, "a": rng.randf() * TAU, "w": dir * spd / ((r.x + r.y) * 0.5),
			"phase": rng.randf() * TAU, "heel": 0.12 if yacht else 0.04})


func _update_boat(b: Dictionary, dt: float) -> void:
	var a: float = b["a"] + float(b["w"]) * dt
	b["a"] = a
	var c: Vector2 = b["c"]
	var r: Vector2 = b["r"]
	var p := c + Vector2(cos(a) * r.x, sin(a) * r.y)
	var w: float = b["w"]
	var v := Vector2(-sin(a) * r.x, cos(a) * r.y) * signf(w)
	var yaw := atan2(-v.x, -v.y)
	var ph: float = b["phase"] + _time * 1.7
	var heel := float(b["heel"]) * signf(w)
	(b["node"] as Node3D).transform = Transform3D(Basis.from_euler(Vector3(0.03 + sin(ph) * 0.03, yaw, heel + sin(ph * 0.8) * 0.04)),
		Vector3(p.x, SEA_Y + 0.1 + sin(ph * 1.2) * 0.15, p.y))


# ------------------------------------------------------------ aircraft
func _helicopter() -> void:
	var root := Node3D.new()
	root.name = "Helicopter"
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var body := Color(0.12, 0.2, 0.42)
	_box(st, Vector3(0, 0, 0), Vector3(2.4, 2.4, 5.2), body)                       # cabin
	_box(st, Vector3(0, 0.3, -2.7), Vector3(2.0, 1.6, 0.6), Color(0.12, 0.16, 0.2))  # windscreen
	_box(st, Vector3(0, 0.5, 5.6), Vector3(0.6, 0.7, 6.5), body)                   # tail boom
	_box(st, Vector3(0, 1.5, 8.6), Vector3(0.3, 2.4, 1.2), WHITE)                  # fin
	_box(st, Vector3(0, -0.2, 1.0), Vector3(2.45, 0.5, 2.4), WHITE)                # livery band
	for x in [-1.1, 1.1]:
		_box(st, Vector3(x, -1.75, 0.0), Vector3(0.15, 0.15, 4.4), Color(0.2, 0.2, 0.2))  # skids
		_box(st, Vector3(x, -1.4, 0.0), Vector3(0.12, 0.7, 0.12), Color(0.2, 0.2, 0.2))
	_box(st, Vector3(0, 1.55, 0.3), Vector3(0.4, 0.7, 0.4), Color(0.2, 0.2, 0.2))  # mast
	root.add_child(_mesh_node(st, _mat, "Body"))
	var rotor := Node3D.new()
	rotor.position = Vector3(0, 1.95, 0.3)
	var rs := SurfaceTool.new()
	rs.begin(Mesh.PRIMITIVE_TRIANGLES)
	_box(rs, Vector3.ZERO, Vector3(11.0, 0.08, 0.35), Color(0.15, 0.15, 0.15))
	_box(rs, Vector3.ZERO, Vector3(0.35, 0.08, 11.0), Color(0.15, 0.15, 0.15))
	rotor.add_child(_mesh_node(rs, _mat, "Rotor"))
	root.add_child(rotor)
	var tail := Node3D.new()
	tail.position = Vector3(0.35, 1.6, 8.8)
	var ts := SurfaceTool.new()
	ts.begin(Mesh.PRIMITIVE_TRIANGLES)
	_box(ts, Vector3.ZERO, Vector3(0.06, 1.8, 0.2), Color(0.15, 0.15, 0.15))
	tail.add_child(_mesh_node(ts, _mat, "TailRotor"))
	root.add_child(tail)
	var ls := SurfaceTool.new()
	ls.begin(Mesh.PRIMITIVE_TRIANGLES)
	_box(ls, Vector3(0, -1.3, 0), Vector3(0.35, 0.25, 0.35), Color(1, 0.1, 0.05))
	var beacon := _mesh_node(ls, _lamp_mat, "Beacon")
	root.add_child(beacon)
	_blinkers.append(beacon)
	add_child(root)
	_heli = root
	_heli_rotor = rotor
	_heli_tail = tail


func _airliner() -> void:
	var root := Node3D.new()
	root.name = "Airliner"
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	_box(st, Vector3.ZERO, Vector3(4.0, 4.2, 38.0), WHITE)                        # fuselage
	_box(st, Vector3(0, -0.4, -19.5), Vector3(3.2, 3.2, 2.0), WHITE)               # nose
	_box(st, Vector3(0, 0.6, -20.3), Vector3(2.0, 1.2, 0.6), Color(0.15, 0.18, 0.22))
	_box(st, Vector3(0, -0.8, 1.0), Vector3(36.0, 0.5, 6.0), Color(0.85, 0.86, 0.88))  # wings
	_box(st, Vector3(0, 0.6, 18.0), Vector3(12.0, 0.35, 3.0), Color(0.85, 0.86, 0.88))  # tailplane
	_box(st, Vector3(0, 4.2, 17.5), Vector3(0.4, 6.5, 4.0), Color(0.75, 0.16, 0.12))   # fin
	for x in [-7.5, 7.5]:
		_box(st, Vector3(x, -2.0, -1.0), Vector3(2.0, 2.0, 4.5), Color(0.6, 0.62, 0.66))  # engines
	root.add_child(_mesh_node(st, _mat, "Body"))
	var ls := SurfaceTool.new()
	ls.begin(Mesh.PRIMITIVE_TRIANGLES)
	_box(ls, Vector3(18.0, -0.6, 1.0), Vector3(0.6, 0.6, 0.6), Color(0.1, 0.9, 0.2))
	_box(ls, Vector3(-18.0, -0.6, 1.0), Vector3(0.6, 0.6, 0.6), Color(0.95, 0.1, 0.08))
	var strobe := _mesh_node(ls, _lamp_mat, "NavLights")
	root.add_child(strobe)
	var bs := SurfaceTool.new()
	bs.begin(Mesh.PRIMITIVE_TRIANGLES)
	_box(bs, Vector3(0, -2.3, 0), Vector3(0.6, 0.4, 0.6), Color(1, 0.15, 0.1))
	var beacon := _mesh_node(bs, _lamp_mat, "Beacon")
	root.add_child(beacon)
	_blinkers.append(beacon)
	add_child(root)
	_plane = root
	_next_flight()


## A straight pass high over the island on a random heading.
func _next_flight() -> void:
	var ang := rng.randf() * TAU
	var d := Vector3(cos(ang), 0, sin(ang))
	var mid := Vector3(540.0 + rng.randf_range(-300, 300), rng.randf_range(650.0, 950.0), rng.randf_range(-300, 300))
	_plane_from = mid - d * 3200.0
	_plane_dir = d
	_plane_t = -rng.randf_range(10.0, 50.0)  # (a gap between flights)


# ------------------------------------------------------------ gulls
## Bigger, white birds wheeling over the shore, reusing the flock shader.
func _gulls() -> void:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for tri in [[Vector3(0, 0, -0.3), Vector3(0.09, 0, 0.0), Vector3(0, 0, 0.32)],
			[Vector3(0, 0, -0.3), Vector3(0, 0, 0.32), Vector3(-0.09, 0, 0.0)],
			[Vector3(0.07, 0, -0.1), Vector3(0.45, 0.06, 0.0), Vector3(0.07, 0, 0.12)],
			[Vector3(0.45, 0.06, 0.0), Vector3(0.75, -0.02, 0.08), Vector3(0.4, 0.05, 0.1)],
			[Vector3(-0.07, 0, -0.1), Vector3(-0.07, 0, 0.12), Vector3(-0.45, 0.06, 0.0)],
			[Vector3(-0.45, 0.06, 0.0), Vector3(-0.4, 0.05, 0.1), Vector3(-0.75, -0.02, 0.08)]]:
		for v in tri:
			st.set_normal(Vector3.UP)
			st.add_vertex(v)
	var mesh := st.commit()
	var mat := ShaderMaterial.new()
	mat.shader = load("res://src/world/shaders/birds.gdshader")
	mat.set_shader_parameter("tint", Color(0.88, 0.88, 0.86))
	mesh.surface_set_material(0, mat)
	var spots := [Vector3(380, 22, -720), Vector3(170, 26, 470), Vector3(-60, 18, 200), Vector3(20, 30, 540),
		Vector3(1080, 24, -60), Vector3(620, 30, -700), Vector3(-200, 28, -260)]
	for h: Vector3 in spots:
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.use_custom_data = true
		mm.mesh = mesh
		var n := rng.randi_range(7, 14)
		mm.instance_count = n
		var dir := 1.0 if rng.randf() < 0.5 else -1.0
		var base_r := rng.randf_range(18.0, 40.0)
		for i in n:
			var c := h + Vector3(rng.randf_range(-6, 6), rng.randf_range(-5, 8), rng.randf_range(-6, 6))
			mm.set_instance_transform(i, Transform3D(Basis(), c))
			mm.set_instance_custom_data(i, Color(base_r + rng.randf_range(-8.0, 8.0), dir * rng.randf_range(0.25, 0.4),
				rng.randf() * TAU, rng.randf_range(1.0, 3.5)))
		var mmi := MultiMeshInstance3D.new()
		mmi.name = "Gulls"
		mmi.multimesh = mm
		mmi.extra_cull_margin = 60.0
		mmi.visibility_range_end = 520.0
		mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(mmi)


# ------------------------------------------------------------ update
func _process(dt: float) -> void:
	dt = minf(dt, 0.1)
	_time += dt
	for sh in _ships:
		_update_ship(sh, dt)
	for b in _boats:
		_update_boat(b, dt)
	if _heli:
		_heli_a += dt * 32.0 / 260.0
		var c := Vector3(CityLayout.CBD_CENTER.x, 0, CityLayout.CBD_CENTER.y)
		var p := c + Vector3(cos(_heli_a) * 260.0, 235.0 + sin(_heli_a * 2.0) * 12.0, sin(_heli_a) * 260.0)
		var v := Vector3(-sin(_heli_a), 0, cos(_heli_a))
		var yaw := atan2(-v.x, -v.z)
		_heli.transform = Transform3D(Basis.from_euler(Vector3(-0.08, yaw, 0.16)), p)
		_heli_rotor.rotate_y(dt * 28.0)
		_heli_tail.rotate_x(dt * 45.0)
	if _plane:
		_plane_t += dt
		_plane.visible = _plane_t > 0.0
		if _plane_t > 0.0:
			_plane.transform = Transform3D(Basis(Vector3.UP, atan2(-_plane_dir.x, -_plane_dir.z)), _plane_from + _plane_dir * 70.0 * _plane_t)
			if _plane_t * 70.0 > 6400.0:
				_next_flight()
	var on := fmod(_time, 1.2) < 0.12
	for bl in _blinkers:
		bl.visible = on
