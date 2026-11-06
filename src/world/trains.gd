class_name Trains
extends Node3D
## Moving trains on RailNetwork lines. Each car is an AnimatableBody3D moved
## along the line's samples every physics tick (bogie points on the track, so
## cars swing round curves and pitch on grades); players can land on a train
## and ride it (CharacterBody3D platform velocity). Timetable: accelerate,
## cruise, brake into each station, dwell, go – a pure function of the clock,
## so it never drifts. The City Loop runs one way round with trains spaced
## evenly through the timetable.
##
## Collision is on TRAIN_LAYER, which only human players collide with (bots
## and recorded courses are unaffected by where the trains happen to be).

const TRAIN_LAYER := CityWorld.HUMAN_LAYER
const CAR_LEN := 17.6
const CAR_PITCH := 18.0          # car + gap
const BOGIE := 6.2               # bogie centres from the car's centre
const V_MAX := 19.0              # m/s cruise (~68 km/h)
const ACCEL := 0.85              # m/s² (and braking)
const DWELL := 14.0              # s at each station

var _trains: Array = []          # {line, dir, offset, t, legs, cycle, cars: [AnimatableBody3D], audio}
var _car_mesh: Mesh
var _cab_mesh: Mesh
var _window_mat: BaseMaterial3D
var _lamp_mat: BaseMaterial3D
var _clock := 0.0


func setup(lines: Array, car_mesh: Mesh, cab_mesh: Mesh) -> void:
	if car_mesh == null or cab_mesh == null:
		return
	_car_mesh = car_mesh.duplicate()
	_cab_mesh = cab_mesh.duplicate()
	# Shared window/lamp materials across both meshes (lit at night).
	for m: Mesh in [_car_mesh, _cab_mesh]:
		for i in m.get_surface_count():
			var sm := m.surface_get_material(i) as BaseMaterial3D
			if sm == null:
				continue
			if sm.resource_name == "train_window":
				if _window_mat == null:
					_window_mat = sm.duplicate()
				m.surface_set_material(i, _window_mat)
			elif sm.resource_name == "lamp":
				if _lamp_mat == null:
					_lamp_mat = sm.duplicate()
				m.surface_set_material(i, _lamp_mat)
	set_night(0.0)
	var stream: AudioStream = load("res://assets/audio/train_loop.wav") if ResourceLoader.exists(
		"res://assets/audio/train_loop.wav") else null
	if stream is AudioStreamWAV:
		var w := stream as AudioStreamWAV
		w.loop_mode = AudioStreamWAV.LOOP_FORWARD
		w.loop_end = int(w.get_length() * w.mix_rate)
	for line in lines:
		if line.get("oneway", false):
			# One way round: trains spaced evenly through the timetable.
			var nt: int = line.get("trains", 2)
			for k in nt:
				_add_train(line, 1, line["tracks"][0], float(k) / nt, stream)
		elif line["loop"]:
			_add_train(line, 1, line["tracks"][0], 0.0, stream)
			_add_train(line, -1, -float(line["tracks"][0]), 0.5, stream)
		else:
			_add_train(line, 1, line["tracks"][0], 0.0, stream)
			if (line["tracks"] as Array).size() > 1:
				_add_train(line, 1, line["tracks"][1], 0.5, stream)  # the other track, half a cycle on
	_place_all()


## Lamps on (0 = day, 1 = night): lit saloon windows and bright headlights.
func set_night(n: float) -> void:
	if _window_mat:
		_window_mat.emission_energy_multiplier = lerpf(0.0, 1.6, n)
	if _lamp_mat:
		_lamp_mat.emission_energy_multiplier = lerpf(0.6, 5.0, n)


func _add_train(line: Dictionary, dir: int, offset: float, phase: float, stream: AudioStream) -> void:
	var pts: PackedVector3Array = line["pts"]
	var total := (pts.size() if line["loop"] else pts.size() - 1) * RailNetwork.STEP
	var st: Array = line["stations"].duplicate()
	st.sort()
	# Legs in travel order: [from s, signed distance, duration].
	var legs: Array = []
	if line["loop"]:
		var n := st.size()
		for i in n:
			if dir > 0:
				var a: float = st[i]
				var b: float = st[(i + 1) % n]
				legs.append([a, fposmod(b - a, total)])
			else:
				var a: float = st[(n - i) % n]
				var b: float = st[(n - i - 1 + n) % n]
				legs.append([a, -fposmod(a - b, total)])
	else:
		# End to end through every station, then back.
		for i in st.size() - 1:
			legs.append([st[i], float(st[i + 1]) - float(st[i])])
		for i in range(st.size() - 1, 0, -1):
			legs.append([st[i], float(st[i - 1]) - float(st[i])])
	var cycle := 0.0
	for leg in legs:
		leg.append(_leg_time(absf(leg[1])))
		cycle += float(leg[2]) + DWELL
	var tr := {"line": line, "dir": dir, "offset": offset, "legs": legs, "cycle": cycle, "phase": phase * cycle,
		"total": total, "cars": [], "s": 0.0, "v": 0.0}
	var n_cars: int = line["cars"]
	for k in n_cars:
		var body := AnimatableBody3D.new()
		body.name = "%s_%d_car%d" % [line["name"], _trains.size(), k]
		body.sync_to_physics = false  # (moved in _physics_process already)
		body.collision_layer = TRAIN_LAYER
		body.collision_mask = 0
		var cab := k == 0 or k == n_cars - 1
		# Collision = the drawn body (its curved roof, the cab's raked nose)
		# plus the roof's air-con pods, so a rider stands right on the roof.
		for shape_xf in car_shapes(cab):
			var cs := CollisionShape3D.new()
			cs.shape = shape_xf[0]
			cs.transform = shape_xf[1]
			if k == n_cars - 1:
				cs.transform = Transform3D(Basis(Vector3.UP, PI), Vector3.ZERO) * cs.transform
			body.add_child(cs)
		var mi := MeshInstance3D.new()
		mi.mesh = _cab_mesh if cab else _car_mesh
		if k == n_cars - 1:
			mi.rotation.y = PI  # the rear cab faces backwards
		mi.visibility_range_end = 1100.0
		body.add_child(mi)
		add_child(body)
		tr["cars"].append(body)
	if stream:
		var au := AudioStreamPlayer3D.new()
		au.stream = stream
		au.bus = "SFX"
		au.unit_size = 22.0
		au.max_distance = 320.0
		au.volume_db = -80.0
		tr["cars"][n_cars / 2].add_child(au)
		au.play()
		tr["audio"] = au
	_trains.append(tr)


## The car body's cross-section (half, from the floor up): the same profile
## tools/blender/build_kit.py lofts (TRAIN_PROFILE: x, height above rail).
const PROFILE := [[1.40, 0.95], [1.45, 1.35], [1.46, 2.7], [1.40, 3.2], [1.2, 3.6], [0.75, 3.84], [0.0, 3.92]]
## Cab nose rings (z from the centre toward the front, width and height scale).
const NOSE := [[6.2, 1.0, 1.0], [7.4, 0.97, 0.94], [8.3, 0.88, 0.8], [8.8, 0.74, 0.62]]
const ROOF_TOP := 3.92
static var _shapes := {}


## [Shape3D, Transform3D] pairs for a car (front = -Z, like the mesh).
static func car_shapes(cab: bool) -> Array:
	if _shapes.has(cab):
		return _shapes[cab]
	var rings: Array = [[-CAR_LEN * 0.5, 1.0, 1.0]]
	if cab:
		rings.append_array(NOSE)
	else:
		rings.append([CAR_LEN * 0.5, 1.0, 1.0])
	var pts := PackedVector3Array()
	for r in rings:
		for q in PROFILE:
			for sx: float in [-1.0, 1.0]:
				var x: float = float(q[0]) * float(r[1]) * sx
				var y: float = 0.95 + (float(q[1]) - 0.95) * float(r[2])
				pts.append(Vector3(x, y, -float(r[0])))
	var hull := ConvexPolygonShape3D.new()
	hull.points = pts
	var out: Array = [[hull, Transform3D.IDENTITY]]
	for ry: float in [-4.0, 3.0]:
		var pod := BoxShape3D.new()
		pod.size = Vector3(1.7, 0.2, 2.6)
		out.append([pod, Transform3D(Basis.IDENTITY, Vector3(0.0, 4.11 - 0.1, -ry))])
	_shapes[cab] = out
	return out


## Velocity of a moving train car the point is inside (beside or in front of
## the car, not riding on its roof), or zero. For VehicleHits.
func hit_test(p: Vector3) -> Vector3:
	for tr in _trains:
		var v: float = tr["v"]
		if v < 3.0:
			continue
		var cars: Array = tr["cars"]
		var mid: Vector3 = (cars[cars.size() / 2] as Node3D).global_position
		if mid.distance_squared_to(p) > pow(CAR_PITCH * cars.size() * 0.5 + 10.0, 2.0):
			continue
		for car: AnimatableBody3D in cars:
			var xf := car.global_transform
			var lp := xf.affine_inverse() * p
			# (The capsule's centre: 0.9 m above the feet, radius 0.35. Up
			# to the shoulder of the roof: above that you're riding it.)
			if absf(lp.x) < 1.46 + 0.4 and absf(lp.z) < CAR_LEN * 0.5 + 0.4 and lp.y > 0.2 \
					and lp.y < 3.4:
				return -xf.basis.z.normalized() * v
	return Vector3.ZERO


## Time to cover d metres from rest to rest (trapezoid speed profile).
static func _leg_time(d: float) -> float:
	var d_ramp := V_MAX * V_MAX / ACCEL  # accelerate + brake distance
	if d >= d_ramp:
		return d / V_MAX + V_MAX / ACCEL
	return 2.0 * sqrt(d / ACCEL)


## Distance covered after time t of a leg of length d (and the speed then).
static func _leg_pos(d: float, T: float, t: float) -> Vector2:
	var vp := minf(V_MAX, sqrt(ACCEL * d))
	var ta := vp / ACCEL
	if t <= ta:
		return Vector2(0.5 * ACCEL * t * t, ACCEL * t)
	if t >= T - ta:
		var r := maxf(T - t, 0.0)
		return Vector2(d - 0.5 * ACCEL * r * r, ACCEL * r)
	return Vector2(0.5 * ACCEL * ta * ta + vp * (t - ta), vp)


func _physics_process(dt: float) -> void:
	_clock += dt
	_place_all()


func _place_all() -> void:
	for tr in _trains:
		var t := fposmod(_clock + float(tr["phase"]), float(tr["cycle"]))
		var s := 0.0
		var v := 0.0
		for leg in tr["legs"]:
			var T: float = leg[2]
			if t < DWELL:
				s = leg[0]
				break
			t -= DWELL
			if t < T:
				var sv := _leg_pos(absf(leg[1]), T, t)
				s = float(leg[0]) + sv.x * signf(leg[1])
				v = sv.y
				break
			t -= T
		tr["s"] = s
		tr["v"] = v
		_place(tr, s)
		var au: AudioStreamPlayer3D = tr.get("audio")
		if au:
			var k := clampf(v / V_MAX, 0.0, 1.0)
			au.volume_db = linear_to_db(maxf(0.12 + 0.88 * k, 0.001)) - 2.0
			au.pitch_scale = 0.7 + 0.4 * k


## Cars laid out round the train's middle at s (cabs at both ends, so a
## shuttle reversing needs no shuffle).
func _place(tr: Dictionary, s: float) -> void:
	var line: Dictionary = tr["line"]
	var pts: PackedVector3Array = line["pts"]
	var loop: bool = line["loop"]
	var cars: Array = tr["cars"]
	var n := cars.size()
	var off: float = tr["offset"]
	var fwd: int = tr["dir"]
	for k in n:
		var sc := s + fwd * ((n - 1) * 0.5 - k) * CAR_PITCH
		var pf := _track_point(pts, loop, sc + fwd * BOGIE, off)
		var pr := _track_point(pts, loop, sc - fwd * BOGIE, off)
		var f := pf - pr
		if f.length_squared() < 1e-6:
			continue
		var xf := Transform3D(Basis.looking_at(f.normalized(), Vector3.UP), (pf + pr) * 0.5)
		(cars[k] as AnimatableBody3D).global_transform = xf


static func _track_point(pts: PackedVector3Array, loop: bool, s: float, off: float) -> Vector3:
	var n := pts.size()
	var f := s / RailNetwork.STEP
	if loop:
		f = fposmod(f, float(n))
	else:
		f = clampf(f, 0.0, float(n - 1) - 0.001)
	var i := int(f)
	var j := (i + 1) % n
	var p := pts[i].lerp(pts[j], f - i)
	var d := pts[j] - pts[i]
	var left := Vector3(-d.z, 0.0, d.x).normalized()
	# (Blend the side vector over the next sample too, so it doesn't step.)
	var k2 := (j + 1) % n if loop else mini(j + 1, n - 1)
	var d2 := pts[k2] - pts[j]
	if d2.length_squared() > 1e-6:
		left = left.lerp(Vector3(-d2.z, 0.0, d2.x).normalized(), f - i).normalized()
	return p + left * off
