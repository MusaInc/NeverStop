class_name AIDriver
extends RefCounted
## Drives a Car the way a person would: through the same throttle / brake /
## steering inputs the player uses (so AI cars skid, overshoot and crash for
## real). Used by every police unit and the capture autopilot.
##
##  * Pure-pursuit steering on a route polyline (look-ahead grows with speed),
##    or straight at a moving point (direct pursuit).
##  * Corner speed from the tightest curvature ahead within braking distance:
##    v = sqrt(a_lat · R), a_lat = grip · g · `skill`. Skill above ~0.95
##    overcooks corners; below 0.7 it's cautious.
##  * Whisker rays (vehicles + walls) steer round obstacles and brake for
##    stopped traffic; `ram` disables the vehicle whiskers toward the target.
##  * Stuck recovery: reverse out with opposite lock, then go again.

const WALL_MASK := 1
const CAR_MASK := 1 << 2

var car: Car
var path := PackedVector3Array()
var path_i := 0
var skill := 0.85
var speed_cap := 999.0
var lateral_offset := 0.0       # m: drive beside the route line (+ = right), e.g. flanking
var direct_target := Vector3.INF # when set: steer at this point instead of the path
var direct_vel := Vector3.ZERO   # target's velocity (lead the aim)
var ram := false
var brake_hold := false          # roadblock / parked
var avoid := true
var avoid_bias := 0.0
var _reverse_t := 0.0
var _reverse_steer := 0.0
var _ray := PhysicsRayQueryParameters3D.new()
var _wh_t := 0.0
var _whisk := Vector3.ZERO       # [steer bias, brake, unused]
var target_speed := 0.0


func _init(p_car: Car) -> void:
	car = p_car
	_ray.collision_mask = WALL_MASK | CAR_MASK
	_ray.exclude = [car.get_rid()]


func set_path(p: PackedVector3Array) -> void:
	path = p
	path_i = 0
	_advance_index()


func _advance_index() -> void:
	if path.size() < 2:
		return
	var cp := car.global_position
	var best := path_i
	var bd := INF
	var hi := mini(path.size(), path_i + 25)
	for i in range(maxi(0, path_i - 2), hi):
		var d := path[i].distance_squared_to(cp)
		if d < bd:
			bd = d
			best = i
	path_i = best


## Distance from the car to the route line (m), for "lost the route" checks.
func off_route() -> float:
	if path.size() < 2:
		return INF
	return path[path_i].distance_to(car.global_position)


func remaining() -> int:
	return path.size() - path_i


func update(dt: float, space: PhysicsDirectSpaceState3D) -> void:
	if car.disabled:
		car.throttle = 0.0
		car.brake = 1.0
		car.steer = 0.0
		return
	if brake_hold:
		car.throttle = 0.0
		car.brake = 1.0
		car.handbrake = car.speed < 2.0
		car.steer = 0.0
		return
	# Stuck: back out.
	if _reverse_t > 0.0:
		_reverse_t -= dt
		car.throttle = 0.0
		car.brake = 1.0
		car.handbrake = false
		car.steer = _reverse_steer
		return
	if car.stuck_time > 1.1:
		_reverse_t = 1.2
		_reverse_steer = -signf(car.steer + 0.01)
		car.stuck_time = 0.0
		return
	var xf := car.global_transform
	var pos := xf.origin
	var fwd := -xf.basis.z
	fwd.y = 0.0
	fwd = fwd.normalized()
	var right := Vector3(-fwd.z, 0.0, fwd.x)
	var spd := car.speed
	var grip: float = car.spec["grip"]
	var a_lat := grip * Car.GRAVITY * skill
	var aim: Vector3
	var v_target := speed_cap
	if direct_target != Vector3.INF:
		var dist := pos.distance_to(direct_target)
		var lead := clampf(dist / maxf(spd, 8.0), 0.0, 1.2)
		aim = direct_target + direct_vel * lead
	else:
		_advance_index()
		if path.size() < 2:
			car.throttle = 0.0
			car.brake = 0.6
			car.steer = 0.0
			return
		var look := 5.0 + spd * 0.45
		var k := path_i
		var acc := 0.0
		while k < path.size() - 1 and acc < look:
			acc += path[k].distance_to(path[k + 1])
			k += 1
		aim = path[k]
		if lateral_offset != 0.0 and k > 0:
			var d := path[k] - path[k - 1]
			d.y = 0.0
			if d.length() > 0.01:
				d = d.normalized()
				aim += Vector3(-d.z, 0.0, d.x) * lateral_offset
		# Corner speed: tightest bend within braking distance.
		var horizon := 15.0 + spd * spd / (2.0 * 9.0) + 10.0
		acc = 0.0
		var j := path_i
		while j < path.size() - 3 and acc < horizon:
			var a := path[j]
			var b := path[j + 1]
			var c := path[j + 2]
			var ab := Vector2(b.x - a.x, b.z - a.z)
			var bc := Vector2(c.x - b.x, c.z - b.z)
			var la := ab.length()
			var lb := bc.length()
			acc += la
			if la > 0.3 and lb > 0.3:
				var turn := absf(ab.angle_to(bc))
				if turn > 0.01:
					var r := (la + lb) * 0.5 / turn
					var vc := sqrt(a_lat * r)
					# Allow for the distance left to brake before it.
					var vb := sqrt(vc * vc + 2.0 * 8.0 * maxf(acc - 4.0, 0.0))
					v_target = minf(v_target, vb)
			j += 1
		if path_i >= path.size() - 2:
			v_target = minf(v_target, 6.0)
	var to := aim - pos
	to.y = 0.0
	var ang := fwd.signed_angle_to(to.normalized(), Vector3.UP) if to.length() > 0.1 else 0.0
	# Godot: positive angle about +Y = turning left; steer + = right.
	var steer := clampf(-ang / maxf(car.max_steer_angle(), 0.05) * 0.9, -1.0, 1.0)
	# Whiskers a few times a second.
	_wh_t -= dt
	if avoid and _wh_t <= 0.0:
		_wh_t = 0.1
		_whiskers(space, pos, fwd, right, spd)
	steer = clampf(steer + _whisk.x, -1.0, 1.0)
	v_target = minf(v_target, maxf(0.0, spd - _whisk.y * 20.0) if _whisk.y > 0.0 else v_target)
	target_speed = v_target
	var dv := v_target - car.forward_speed
	car.steer = steer
	car.handbrake = false
	if dv > -1.0:
		car.throttle = clampf(dv / 4.0 + 0.4, 0.0, 1.0)
		car.brake = 0.0
	else:
		car.throttle = 0.0
		car.brake = clampf(-dv / 6.0, 0.2, 1.0)
	# A sharp turn at low speed: a dab of handbrake gets the nose round.
	if absf(ang) > 1.2 and spd > 7.0 and spd < 22.0:
		car.handbrake = true
	# Facing away from a close target: reverse-and-turn is quicker.
	if absf(ang) > 2.3 and spd < 4.0 and to.length() < 25.0:
		_reverse_t = 0.8
		_reverse_steer = signf(ang)


func _whiskers(space: PhysicsDirectSpaceState3D, pos: Vector3, fwd: Vector3, right: Vector3, spd: float) -> void:
	_whisk = Vector3.ZERO
	var reach := 8.0 + spd * 0.9
	var base := pos + Vector3.UP * 0.7
	var hits := [0.0, 0.0, 0.0]
	var dirs := [fwd, (fwd + right * 0.35).normalized(), (fwd - right * 0.35).normalized()]
	for i in 3:
		_ray.from = base + fwd * 2.4
		_ray.to = _ray.from + (dirs[i] as Vector3) * reach
		var hit := space.intersect_ray(_ray)
		if hit.is_empty():
			continue
		var col = hit.get("collider")
		if ram and col is Car and (col as Car).role == "player":
			continue
		var d := (_ray.from as Vector3).distance_to(hit["position"])
		hits[i] = 1.0 - d / reach
	# Steer away from the side that's more blocked; brake if dead ahead.
	_whisk.x = (hits[2] - hits[1]) * 0.9
	if hits[0] > 0.0 and absf(_whisk.x) < 0.2:
		_whisk.x = 0.5 * (1.0 if avoid_bias >= 0.0 else -1.0) * hits[0]
	_whisk.y = hits[0] if hits[0] > 0.55 else 0.0
