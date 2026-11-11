class_name CivilianTraffic
extends Node3D
## Civilian cars around the player.
##  * Each is a Car frozen as a kinematic body, moved along a wandering lane
##    route at its lane's speed: cheap (no suspension, no tyres) but solid –
##    the player and police hit real bodies.
##  * Following: slows for anything ahead in its path (other civilians,
##    police, the player), queues, pulls away again.
##  * Sirens: a police car closing from behind makes it slow and pull toward
##    the kerb. Roadblocks/wrecks ahead: it stops (that's how jams form).
##  * Hit hard (an impact on it, or the player shoving it), it wakes up as a
##    full physics car with nobody driving – it spins, rolls, piles up – and
##    stays as an obstacle until it's out of sight.
##  * Recycled: cars far behind / out of view respawn on lanes ahead or to
##    the side of the player, never on screen. Count follows the quality
##    preset and the player's speed (thinner at high speed on open roads).

## Models and their share of traffic: CarCatalog.CIVILIANS (compacts, saloons,
## taxis, SUVs, vans, box trucks, buses).
const RANGE := 300.0
const SPAWN_MIN := 90.0

var net: RoadNet
var player: Car
var director: PursuitDirector
var camera: ChaseCamera
var count := 22
var rng := RandomNumberGenerator.new()
var cars: Array = []        # [{car, path, i, v, lane, wrecked, t_wreck, offset}]
var _ray := PhysicsRayQueryParameters3D.new()
var _respawn_t := 0.0
var enabled := true
var _refill_t := 0.0
var jumps: Jumps


func setup(p_net: RoadNet, p_player: Car, p_camera: ChaseCamera, p_director: PursuitDirector) -> void:
	net = p_net
	player = p_player
	camera = p_camera
	director = p_director
	_ray.collision_mask = 1
	var st := get_node_or_null("/root/Settings")
	if st:
		count = st.preset()["civilians"]
	rng.randomize()


func reset_around(p: Vector3) -> void:
	for c in cars:
		_park(c)
	for i in count:
		if i >= cars.size():
			cars.append(_make())
		_respawn(cars[i], p, true)


func _make() -> Dictionary:
	var spec := CarCatalog.civ_spec(CarCatalog.civ_pick(rng), rng)
	var car := Car.new()
	car.setup(spec, "civilian")
	car.name = "Civilian_%d" % cars.size()
	add_child(car)
	var v := CarVisual.new()
	car.add_child(v)
	v.setup(car)
	car.visual = v
	car.freeze_mode = RigidBody3D.FREEZE_MODE_KINEMATIC
	car.freeze = true
	var c := {"car": car, "path": PackedVector3Array(), "i": 0.0, "v": 10.0, "lane": -1, "wrecked": false,
		"t_wreck": 0.0, "offset": 0.0, "cruise": 10.0, "active": false}
	car.impact.connect(func(strength: float, _a, _n, _o): _on_hit(c, strength))
	car.body_entered.connect(func(b): if b is Car and (b as Car).role != "civilian": _wake(c, b))
	return c


func _park(c: Dictionary) -> void:
	var car: Car = c["car"]
	car.freeze = true
	car.visible = false
	car.global_position = Vector3(0, -600, 0)
	c["active"] = false


func _respawn(c: Dictionary, around: Vector3, anywhere := false) -> bool:
	var heading := player.linear_velocity
	heading.y = 0.0
	for attempt in 16:
		var ang := rng.randf() * TAU
		if not anywhere and heading.length() > 5.0 and rng.randf() < 0.7:
			# Mostly ahead of the player, where they're going.
			ang = atan2(heading.z, heading.x) + rng.randf_range(-1.0, 1.0)
		var r := rng.randf_range(SPAWN_MIN if not anywhere else 25.0, RANGE * 0.9)
		var q := around + Vector3(cos(ang), 0.0, sin(ang)) * r
		var n := net.nearest(q, Vector3.ZERO, 30.0, -1, true)
		if n.is_empty():
			continue
		var p: Vector3 = n["pos"]
		if p.distance_to(player.global_position) < (SPAWN_MIN * 0.6 if not anywhere else 20.0):
			continue
		if not anywhere and _on_screen(p):
			continue
		if _occupied(p, c):
			continue
		var car: Car = c["car"]
		c["lane"] = n["lane"]
		c["path"] = net.wander(n["lane"], n["s"], 260.0, rng, 0.35)
		c["i"] = 0.0
		var heavy := float(car.spec["mass"]) > 4000.0
		c["cruise"] = net.lane_speed[n["lane"]] * (rng.randf_range(0.8, 0.95) if heavy else rng.randf_range(0.95, 1.35))
		c["v"] = c["cruise"] * 0.8
		c["wrecked"] = false
		c["active"] = true
		car.reset_damage()
		(car.visual as CarVisual).reset_dents()
		car.freeze_mode = RigidBody3D.FREEZE_MODE_KINEMATIC
		car.freeze = true
		car.visible = true
		_pose(c, 0.0)
		return true
	_park(c)
	return false


func _occupied(p: Vector3, me: Dictionary) -> bool:
	for o in cars:
		if o != me and o["active"] and (o["car"] as Car).global_position.distance_to(p) < 12.0:
			return true
	return false


func _on_screen(p: Vector3) -> bool:
	var cam := camera.cam
	if not cam.is_position_in_frustum(p + Vector3.UP):
		return false
	_ray.from = cam.global_position
	_ray.to = p + Vector3.UP
	return get_world_3d().direct_space_state.intersect_ray(_ray).is_empty()


## Position along the path at index-distance i (3 m per point), at `y` lift.
func _pose(c: Dictionary, dt: float) -> void:
	var path: PackedVector3Array = c["path"]
	var car: Car = c["car"]
	if path.size() < 2:
		return
	var f: float = c["i"]
	var k := clampi(int(f), 0, path.size() - 2)
	var a := path[k]
	var b := path[k + 1]
	var p := a.lerp(b, clampf(f - k, 0.0, 1.0))
	var k2 := clampi(k + 2, 0, path.size() - 1)
	var dir := path[k2] - path[maxi(k - 1, 0)]
	if dir.length() < 0.01:
		return
	dir = dir.normalized()
	var right := Vector3(-dir.z, 0.0, dir.x).normalized()
	p += right * float(c["offset"])
	if jumps:
		p.y = maxf(p.y, jumps.height_at(p))
	var basis := Basis.looking_at(dir, Vector3.UP)
	var xf := Transform3D(basis, p + Vector3.UP * 0.02)
	if dt > 0.0:
		car.linear_velocity = (xf.origin - car.global_position) / dt
	car.global_transform = xf
	var v: float = c["v"]
	car.forward_speed = v
	car.speed = v
	var wr: float = car.spec["wheel_r"]
	for i in 4:
		car.wheel_spin[i] += v / wr * dt
		car.wheel_comp_visual[i] = 0.08
	car.brake = 1.0 if v < float(c["cruise"]) * 0.6 else 0.0


func _physics_process(dt: float) -> void:
	Prof.begin("civilians")
	if not enabled or player == null:
		Prof.end("civilians")
		return
	var pp := player.global_position
	_respawn_t -= dt
	var police: Array = director.unit_markers() if director and director.active else []
	_refill_t -= dt
	for c in cars:
		if not c["active"]:
			# Parked because no spot was free last time: try again now and then.
			if _refill_t <= 0.0:
				_refill_t = 0.25
				_respawn(c, pp)
			continue
		var car: Car = c["car"]
		if c["wrecked"]:
			c["t_wreck"] += dt
			var sunk := car.in_water and float(c["t_wreck"]) > 4.0
			if sunk or (c["t_wreck"] > 6.0 and car.global_position.distance_to(pp) > 120.0 and not _on_screen(car.global_position)):
				_respawn(c, pp)
			continue
		# Distance to the nearest thing ahead in our lane.
		var fwd := -car.global_basis.z
		var gap := _gap_ahead(car, fwd, police)
		var target: float = c["cruise"]
		# (gap is bumper to bumper-ish: long vehicles keep their own length clear)
		gap -= (float(car.spec["size"].z) - 4.5) * 0.5
		if gap < 30.0:
			target = minf(target, maxf(0.0, (gap - 7.0) * 0.8))
		# Sirens behind: slow and pull over.
		var pull := 0.0
		for m in police:
			var mp: Vector3 = m[0]
			var rel := mp - car.global_position
			if m[3] and rel.length() < 40.0 and rel.dot(fwd) < 0.0 and m[2] != "wrecked" and m[2] != "roadblock":
				pull = 2.6
				target = minf(target, 5.0)
		c["offset"] = move_toward(float(c["offset"]), pull, dt * 1.2)
		var v: float = c["v"]
		v = move_toward(v, target, dt * (2.5 if target > v else 7.0))
		c["v"] = v
		c["i"] = float(c["i"]) + v * dt / RoadNet.STEP
		var path: PackedVector3Array = c["path"]
		if float(c["i"]) > path.size() - 30:
			# Extend the route from where we are.
			var n := net.nearest(car.global_position, fwd, 20.0, -1)
			if not n.is_empty():
				c["path"] = net.wander(n["lane"], n["s"], 260.0, rng, 0.35)
				c["i"] = 0.0
		_pose(c, dt)
		# Recycle when far away and out of view.
		if car.global_position.distance_to(pp) > RANGE and _respawn_t <= 0.0:
			_respawn_t = 0.05
			if not _on_screen(car.global_position):
				_respawn(c, pp)
	Prof.end("civilians")


func _gap_ahead(car: Car, fwd: Vector3, police: Array) -> float:
	var best := 999.0
	var p := car.global_position
	for o in cars:
		if not o["active"]:
			continue
		var oc: Car = o["car"]
		if oc == car:
			continue
		best = minf(best, _ahead(p, fwd, oc.global_position) - (float(oc.spec["size"].z) - 4.5) * 0.5)
	best = minf(best, _ahead(p, fwd, player.global_position))
	for m in police:
		best = minf(best, _ahead(p, fwd, m[0]))
	return best


static func _ahead(p: Vector3, fwd: Vector3, q: Vector3) -> float:
	var rel := q - p
	var along := rel.dot(fwd)
	if along < 0.0 or along > 40.0:
		return 999.0
	var side := (rel - fwd * along).length()
	return along if side < 2.6 else 999.0


func _on_hit(c: Dictionary, strength: float) -> void:
	if strength > 3.0:
		_wake(c, null)


## The crash: the kinematic car becomes a real body carrying its speed.
func _wake(c: Dictionary, _by: Object) -> void:
	if c["wrecked"] or not c["active"]:
		return
	c["wrecked"] = true
	c["t_wreck"] = 0.0
	var car: Car = c["car"]
	var v := car.linear_velocity
	car.freeze = false
	car.disabled = true
	car.linear_velocity = v
	car.brake = 1.0
	car.throttle = 0.0


func active_cars() -> Array:
	var out: Array = []
	for c in cars:
		if c["active"]:
			out.append(c["car"])
	return out
