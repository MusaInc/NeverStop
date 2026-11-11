class_name ChaseCamera
extends Node3D
## Third-person pursuit camera.
##  * Follows a smoothed heading: the car's nose blended toward its direction
##    of travel (so a drift swings the camera out gently instead of whipping
##    round with the body), lagging a little behind turns.
##  * Distance, height and FOV grow with speed; nitro punches the FOV.
##  * Separate, faster smoothing on height so crests and dips don't clip the
##    road or bury the car; a floor ray keeps the lens above ground.
##  * Pulls in when a building would block the view (sphere cast from the
##    car to the lens).
##  * World-up always: airborne cars and tumbles never roll the horizon.
##  * Trauma shake (squared, smooth noise), damped by Reduce Motion.
##  * Cinematic modes: "orbit" (results / garage), "fixed" (look from a set
##    point), "chase" (default).

var target: Car
var cam: Camera3D
var mode := "chase"
var distance_setting := 1   # 0 near, 1 normal, 2 far
var base_fov := 64.0
var reduce_motion := false

var _heading := Vector3.FORWARD
var _pos := Vector3.ZERO
var _height := 0.0
var _look := Vector3.ZERO
var _trauma := 0.0
var _noise := FastNoiseLite.new()
var _t := 0.0
var _fov_kick := 0.0
var _orbit_angle := 0.0
var _fixed_from := Vector3.ZERO
var _snap := true
var _query := PhysicsShapeQueryParameters3D.new()
var _sphere := SphereShape3D.new()
var _ray := PhysicsRayQueryParameters3D.new()
var _accel_offset := 0.0
var _prev_speed := 0.0


func _ready() -> void:
	cam = Camera3D.new()
	cam.name = "Camera"
	cam.fov = base_fov
	cam.near = 0.15
	cam.far = 2400.0
	add_child(cam)
	cam.make_current()
	_noise.frequency = 0.9
	_sphere.radius = 0.35
	_query.shape = _sphere
	_query.collision_mask = 1   # buildings / structures
	_ray.collision_mask = 1 | (1 << 3)


## Camera yaw (Godot convention: 0 looks along -Z), for the minimap.
func view_yaw() -> float:
	var f := -global_basis.z
	return atan2(-f.x, -f.z)


func set_target(c: Car, snap := true) -> void:
	target = c
	_snap = snap


func shake(amount: float) -> void:
	_trauma = clampf(_trauma + amount, 0.0, 1.0)


func kick_fov(deg: float) -> void:
	_fov_kick = maxf(_fov_kick, deg)


## A hit: the lens snaps in (negative FOV) and eases back out.
func punch(deg: float) -> void:
	if not reduce_motion and absf(deg) > absf(_fov_kick):
		_fov_kick = deg


func orbit(from_angle := 0.0) -> void:
	mode = "orbit"
	_orbit_angle = from_angle


func fixed(from: Vector3) -> void:
	mode = "fixed"
	_fixed_from = from


func chase() -> void:
	mode = "chase"


func _physics_process(dt: float) -> void:
	Prof.begin("camera")
	# Physics-rate so the lens moves in lockstep with the car (no jitter
	# from interpolating a body that moves at 60 Hz under a 120 Hz display).
	if target == null or not is_instance_valid(target):
		Prof.end("camera")
		return
	_t += dt
	match mode:
		"orbit":
			_orbit(dt)
		"fixed":
			_fixed(dt)
		_:
			_chase(dt)
	_apply_shake(dt)
	Prof.end("camera")


func _chase(dt: float) -> void:
	var car := target
	var cp := car.global_position
	var b := car.global_basis
	var fwd := -b.z
	fwd.y = 0.0
	if fwd.length() < 0.2:
		fwd = _heading  # nose up / down or tumbling: keep the last heading
	fwd = fwd.normalized()
	var v := car.linear_velocity
	var vh := Vector3(v.x, 0.0, v.z)
	var spd := vh.length()
	var want := fwd
	if spd > 4.0:
		var vd := vh / spd
		# Reversing: look forward still, don't flip round.
		if vd.dot(fwd) > -0.2:
			want = fwd.lerp(vd, 0.35 if car.drifting else 0.15).normalized()
	if car.wheels_on_ground == 0 and spd > 6.0:
		want = (vh / spd).lerp(fwd, 0.3).normalized()
	if _snap:
		_heading = want
	else:
		var rate := 4.0 + clampf(spd / 40.0, 0.0, 1.0) * 2.5
		_heading = _slerp_flat(_heading, want, 1.0 - exp(-rate * dt))
	var top: float = car.spec.get("top_speed", 55.0)
	var sp_t := clampf(spd / top, 0.0, 1.2)
	var dist_base: float = [5.0, 6.0, 7.4][clampi(distance_setting, 0, 2)]
	var dist := dist_base + sp_t * 1.6
	var height := 1.85 + sp_t * 0.35 + (car.spec["size"] as Vector3).y * 0.35
	if car.wheels_on_ground == 0:
		dist += 0.8
		height += 0.4
	# Acceleration response: pull back a touch on hard acceleration, in on braking.
	var acc := (spd - _prev_speed) / maxf(dt, 0.001)
	_prev_speed = spd
	_accel_offset = lerpf(_accel_offset, clampf(acc * 0.04, -0.6, 0.45), 1.0 - exp(-3.0 * dt))
	dist += _accel_offset
	var desired := cp - _heading * dist
	var ground_y := cp.y
	if _snap:
		_pos = desired
		_height = cp.y + height
	else:
		var k := 1.0 - exp(-14.0 * dt)
		_pos = _pos.lerp(Vector3(desired.x, _pos.y, desired.z), k)
		_height = lerpf(_height, ground_y + height, 1.0 - exp(-9.0 * dt))
	var lens := Vector3(_pos.x, _height, _pos.z)
	# Keep the horizontal distance honest (smoothing can let it creep in at speed).
	var flat := Vector3(lens.x - cp.x, 0.0, lens.z - cp.z)
	if flat.length() < dist * 0.8:
		flat = flat.normalized() * dist * 0.8 if flat.length() > 0.01 else -_heading * dist
		lens = Vector3(cp.x + flat.x, lens.y, cp.z + flat.z)
	var look_ahead := 2.5 + sp_t * 6.0
	var look := cp + Vector3.UP * 0.9 + _heading * look_ahead
	# Pull in in front of walls.
	var space := get_world_3d().direct_space_state
	var from := cp + Vector3.UP * 1.2
	_query.transform = Transform3D(Basis(), from)
	_query.motion = lens - from
	_query.exclude = [car.get_rid()]
	var frac := space.cast_motion(_query)
	if frac.size() == 2 and frac[0] < 1.0:
		lens = from + (lens - from) * maxf(frac[0], 0.15)
	# Above the ground.
	_ray.from = lens + Vector3.UP * 3.0
	_ray.to = lens - Vector3.UP * 1.0
	_ray.exclude = [car.get_rid()]
	var hit := space.intersect_ray(_ray)
	if not hit.is_empty():
		lens.y = maxf(lens.y, (hit["position"] as Vector3).y + 0.6)
	if _snap:
		_look = look
	else:
		_look = _look.lerp(look, 1.0 - exp(-16.0 * dt))
	_snap = false
	global_position = lens
	if lens.distance_to(_look) > 0.1:
		look_at(_look, Vector3.UP)
	# FOV: speed and nitro.
	_fov_kick = move_toward(_fov_kick, 0.0, dt * 14.0)
	var nitro_fov := 6.0 if (car.nitro and car.nitro_amount > 0.0) else 0.0
	var fov := base_fov + pow(sp_t, 1.5) * 16.0 + nitro_fov + _fov_kick
	if reduce_motion:
		fov = base_fov + sp_t * 8.0
	cam.fov = lerpf(cam.fov, fit_fov(fov), 1.0 - exp(-4.0 * dt))


## FOVs are tuned for 16:9 and wider (the vertical angle is kept, so wide
## phones see more road at the sides). On a narrower screen – an iPad's 4:3 –
## keep the 16:9 horizontal angle instead, so the road ahead isn't cropped
## at the sides; the extra height shows more sky and street.
func fit_fov(v_deg: float) -> float:
	var vp := get_viewport().get_visible_rect().size if get_viewport() else Vector2(16, 9)
	var aspect := vp.x / maxf(vp.y, 1.0)
	if aspect >= 16.0 / 9.0 - 0.01:
		return v_deg
	var h := 2.0 * atan(tan(deg_to_rad(v_deg) * 0.5) * 16.0 / 9.0)
	return minf(rad_to_deg(2.0 * atan(tan(h * 0.5) / aspect)), 100.0)


func _orbit(dt: float) -> void:
	# The capture shot: a slow elevated orbit round the car (and whoever has
	# boxed it in), pulled in in front of walls and kept off the ground.
	var cp := target.global_position
	_orbit_angle += dt * 0.22
	var off := Vector3(sin(_orbit_angle), 0.0, cos(_orbit_angle)) * 11.0 + Vector3.UP * 5.5
	var want := cp + off
	var space := get_world_3d().direct_space_state
	var from := cp + Vector3.UP * 1.5
	_query.transform = Transform3D(Basis(), from)
	_query.motion = want - from
	_query.collision_mask = 1 | (1 << 2)
	_query.exclude = [target.get_rid()]
	var frac := space.cast_motion(_query)
	_query.collision_mask = 1
	if frac.size() == 2 and frac[0] < 1.0:
		want = from + (want - from) * maxf(frac[0] - 0.05, 0.1) + Vector3.UP * 1.5
	_ray.from = want + Vector3.UP * 4.0
	_ray.to = want - Vector3.UP * 3.0
	_ray.exclude = [target.get_rid()]
	var hit := space.intersect_ray(_ray)
	if not hit.is_empty():
		want.y = maxf(want.y, (hit["position"] as Vector3).y + 1.5)
	global_position = global_position.lerp(want, 1.0 - exp(-3.0 * dt))
	look_at(cp + Vector3.UP * 0.5, Vector3.UP)
	cam.fov = lerpf(cam.fov, fit_fov(52.0), 1.0 - exp(-2.0 * dt))


func _fixed(dt: float) -> void:
	global_position = global_position.lerp(_fixed_from, 1.0 - exp(-3.0 * dt))
	var cp := target.global_position + Vector3.UP * 0.6
	if global_position.distance_to(cp) > 0.5:
		look_at(cp, Vector3.UP)
	cam.fov = lerpf(cam.fov, fit_fov(45.0), 1.0 - exp(-2.0 * dt))


func _apply_shake(dt: float) -> void:
	_trauma = maxf(0.0, _trauma - dt * 1.4)
	var s := _trauma * _trauma * (0.25 if reduce_motion else 1.0)
	if s <= 0.0001:
		cam.position = Vector3.ZERO
		cam.rotation = Vector3.ZERO
		return
	cam.position = Vector3(_noise.get_noise_2d(_t * 25.0, 0.0), _noise.get_noise_2d(0.0, _t * 25.0), 0.0) * 0.35 * s
	cam.rotation = Vector3(_noise.get_noise_2d(_t * 20.0, 50.0) * 0.05, _noise.get_noise_2d(50.0, _t * 20.0) * 0.05,
		_noise.get_noise_2d(_t * 15.0, 90.0) * 0.06) * s


static func _slerp_flat(a: Vector3, b: Vector3, t: float) -> Vector3:
	var aa := atan2(a.x, a.z)
	var bb := atan2(b.x, b.z)
	var r := lerp_angle(aa, bb, t)
	return Vector3(sin(r), 0.0, cos(r))
