extends Node
## The driving experience, manoeuvre by manoeuvre, for every car. Each test
## prints its numbers (the handling report) and checks the feel targets:
##   lift-off   releasing GAS slows the car noticeably (press-to-go must not float)
##   lane change a quick swerve at 100 km/h moves a lane and settles straight
##   slalom     alternating full lock at 80 km/h stays controllable (no spin)
##   brake-turn braking hard mid-corner doesn't spin the car
##   handbrake  a handbrake flick at 60 km/h turns the car round fast
##   parking    full lock at walking pace turns in a tight circle
##   reverse    holding BRAKE when stopped reverses; GAS goes forward again
##   glance     scraping a wall at 30° keeps most of the speed, no spin-out
##   side hit   a police car T-boning at 50 km/h knocks you, not spins you out
##   nitro      the boost is felt (speed gained over 2 s at 100 km/h)

var bench: DriveBench


func setup() -> void:
	bench = DriveBench.new()
	add_child(bench)
	await get_tree().physics_frame


func teardown() -> void:
	bench.queue_free()
	await get_tree().physics_frame


func _ctl(car: Car, thr: float, brk: float, steer: float, hb := false, nos := false) -> void:
	car.throttle = thr
	car.brake = brk
	car.steer = steer
	car.handbrake = hb
	car.nitro = nos


func _car(id: String, kmh := 0.0, at := Vector3.ZERO) -> Car:
	var car := bench.spawn_car(id, at)
	await DriveBench.frames(get_tree(), 30)
	if kmh > 0.0:
		car.linear_velocity = -car.global_basis.z * kmh / 3.6
	await get_tree().physics_frame
	return car


func _done(car: Car) -> void:
	car.queue_free()
	await DriveBench.frames(get_tree(), 2)


func _hold(car: Car, kmh: float) -> void:
	car.throttle = clampf((kmh / 3.6 - car.forward_speed) * 0.5 + 0.35, 0.0, 1.0)


func test_lift_off_slows_the_car(t) -> void:
	for id in CarCatalog.ORDER:
		var car: Car = await _car(id, 100.0)
		_ctl(car, 0.0, 0.0, 0.0)
		await DriveBench.frames(get_tree(), 120)
		var kmh := car.forward_speed * 3.6
		var decel := (100.0 - kmh) / 3.6 / 2.0
		t.note("%-8s lift off at 100 km/h: %.0f km/h after 2 s (%.1f m/s²)" % [id, kmh, decel])
		t.check(decel > 1.6, "%s: letting go of GAS slows it (%.1f m/s²)" % [id, decel])
		await _done(car)


func test_lane_change(t) -> void:
	for id in CarCatalog.ORDER:
		var car: Car = await _car(id, 100.0)
		var x0 := car.global_position.x
		var max_beta := 0.0
		for i in 120:
			var tt := i / 60.0
			var st := 0.0
			if tt < 0.3:
				st = 1.0
			elif tt < 0.6:
				st = -1.0
			_ctl(car, 0.0, 0.0, st)
			_hold(car, 100.0)
			await get_tree().physics_frame
			max_beta = maxf(max_beta, absf(car.drift_angle))
		var dx := car.global_position.x - x0
		var hd := rad_to_deg(absf(angle_difference(0.0, car.global_rotation.y)))
		t.note("%-8s lane change at 100 km/h: moved %.1f m sideways, heading off %.1f°, max slip %.0f°, yaw now %.2f" % [
			id, dx, hd, rad_to_deg(max_beta), car.angular_velocity.y])
		t.check(dx > 2.5, "%s: a quick swerve moves at least a lane (%.1f m)" % [id, dx])
		t.check(hd < 12.0 and absf(car.angular_velocity.y) < 0.15, "%s: settles straight after the swerve" % id)
		t.check(max_beta < deg_to_rad(14.0), "%s: no slide in a swerve (%.0f°)" % [id, rad_to_deg(max_beta)])
		await _done(car)


func test_slalom_stays_controllable(t) -> void:
	for id in CarCatalog.ORDER:
		var car: Car = await _car(id, 80.0)
		var max_beta := 0.0
		var spun := false
		for i in 60 * 4:
			var st := 1.0 if int(i / 36) % 2 == 0 else -1.0
			_ctl(car, 0.0, 0.0, st)
			_hold(car, 80.0)
			await get_tree().physics_frame
			max_beta = maxf(max_beta, absf(car.drift_angle))
			if absf(car.drift_angle) > deg_to_rad(50.0):
				spun = true
		t.note("%-8s slalom at 80 km/h: max slip %.0f°, speed %.0f km/h" % [id, rad_to_deg(max_beta), car.speed * 3.6])
		t.check(not spun and max_beta < deg_to_rad(20.0), "%s: slalom stays planted (%.0f°)" % [id, rad_to_deg(max_beta)])
		t.check(car.speed * 3.6 > 55.0, "%s: keeps its pace through the slalom" % id)
		await _done(car)


func test_braking_mid_corner_does_not_spin(t) -> void:
	for id in CarCatalog.ORDER:
		var car: Car = await _car(id, 90.0)
		for i in 40:
			_ctl(car, 0.0, 0.0, 0.8)
			_hold(car, 90.0)
			await get_tree().physics_frame
		var max_beta := 0.0
		for i in 120:
			_ctl(car, 0.0, 1.0, 0.8)
			await get_tree().physics_frame
			max_beta = maxf(max_beta, absf(car.drift_angle))
			if car.forward_speed < 2.0:
				break
		t.note("%-8s brake hard mid-corner at 90 km/h: max slip %.0f°" % [id, rad_to_deg(max_beta)])
		t.check(max_beta < deg_to_rad(25.0), "%s: braking in a corner doesn't spin it (%.0f°)" % [id, rad_to_deg(max_beta)])
		await _done(car)


func test_handbrake_turn(t) -> void:
	for id in CarCatalog.ORDER:
		var car: Car = await _car(id, 60.0)
		var y0 := car.global_rotation.y
		for i in 60:
			_ctl(car, 0.4, 0.0, 1.0, true)
			await get_tree().physics_frame
		var turned := rad_to_deg(absf(angle_difference(y0, car.global_rotation.y)))
		var kmh := car.speed * 3.6
		for i in 90:
			_ctl(car, 1.0, 0.0, 0.0)
			await get_tree().physics_frame
		t.note("%-8s handbrake flick at 60 km/h: turned %.0f° in 1 s, %.0f km/h left, then %.0f km/h, upright %.2f" % [
			id, turned, kmh, car.speed * 3.6, car.global_basis.y.dot(Vector3.UP)])
		t.check(turned > 70.0, "%s: the handbrake swings it round (%.0f°)" % [id, turned])
		t.check(car.global_basis.y.dot(Vector3.UP) > 0.9, "%s: stays on its wheels" % id)
		t.check(absf(car.drift_angle) < deg_to_rad(15.0), "%s: drives away cleanly afterwards" % id)
		await _done(car)


func test_parking_lot_turning_circle(t) -> void:
	for id in CarCatalog.ORDER:
		var car: Car = await _car(id, 15.0)
		for i in 120:
			_ctl(car, 0.0, 0.0, 1.0)
			_hold(car, 15.0)
			await get_tree().physics_frame
		var r := car.speed / maxf(absf(car.angular_velocity.y), 0.01)
		t.note("%-8s turning circle at 15 km/h: radius %.1f m" % [id, r])
		t.check(r < 9.0, "%s: tight turning circle at low speed (%.1f m)" % [id, r])
		await _done(car)


func test_reverse_and_back(t) -> void:
	var car: Car = await _car("marlin")
	for i in 120:
		_ctl(car, 0.0, 1.0, 0.0)
		await get_tree().physics_frame
	var rev := car.forward_speed * 3.6
	for i in 90:
		_ctl(car, 1.0, 0.0, 0.0)
		await get_tree().physics_frame
	var fwd := car.forward_speed * 3.6
	t.note("reverse: %.0f km/h after 2 s of BRAKE at a standstill; %.0f km/h after 1.5 s of GAS" % [rev, fwd])
	t.check(rev < -8.0, "holding BRAKE when stopped reverses")
	t.check(fwd > 25.0, "GAS from reverse drives off forwards")
	await _done(car)


func test_glancing_a_wall(t) -> void:
	var wall := bench.add_wall(Vector3(6, 1.5, -60), Vector3(1, 3, 200))
	for id in ["kestrel", "marlin", "halcyon", "mammoth"]:
		var car: Car = await _car(id, 0.0, Vector3(0, 0, 0))
		car.global_rotation.y = deg_to_rad(-30.0)  # nose toward the wall on the right
		car.linear_velocity = -car.global_basis.z * 90.0 / 3.6
		var max_yaw := 0.0
		var min_kmh := INF
		for i in 90:
			_ctl(car, 0.6, 0.0, 0.0)
			await get_tree().physics_frame
			max_yaw = maxf(max_yaw, absf(car.angular_velocity.y))
			if i > 20:
				min_kmh = minf(min_kmh, car.speed * 3.6)
		t.note("%-8s glancing a wall at 30°, 90 km/h: slowest %.0f km/h, max yaw %.1f rad/s, health %.2f" % [
			id, min_kmh, max_yaw, car.health])
		t.check(min_kmh > 45.0, "%s: a glancing hit keeps most of the speed (%.0f km/h)" % [id, min_kmh])
		t.check(max_yaw < 3.5, "%s: no violent spin off the wall (%.1f rad/s)" % [id, max_yaw])
		await _done(car)
	wall.queue_free()


func test_side_hit_by_police(t) -> void:
	for id in ["kestrel", "marlin", "stiletto"]:
		var car: Car = await _car(id, 70.0)
		var cop := bench.spawn_car("police_patrol", car.global_position + Vector3(-12, 0, -17), -PI * 0.5, "police")
		await get_tree().physics_frame
		cop.linear_velocity = Vector3(50.0 / 3.6, 0, 0)
		var max_yaw := 0.0
		var max_beta := 0.0
		for i in 120:
			_ctl(car, 0.0, 0.0, 0.0)
			_hold(car, 70.0)
			cop.throttle = 1.0
			await get_tree().physics_frame
			max_yaw = maxf(max_yaw, absf(car.angular_velocity.y))
			max_beta = maxf(max_beta, absf(car.drift_angle))
		t.note("%-8s T-boned at 50 km/h while doing 70: max yaw %.1f rad/s, max slip %.0f°, upright %.2f, %.0f km/h after" % [
			id, max_yaw, rad_to_deg(max_beta), car.global_basis.y.dot(Vector3.UP), car.speed * 3.6])
		t.check(car.global_basis.y.dot(Vector3.UP) > 0.8, "%s: stays on its wheels" % id)
		t.check(max_beta < deg_to_rad(60.0), "%s: knocked, not spun round (%.0f°)" % [id, rad_to_deg(max_beta)])
		cop.queue_free()
		await _done(car)


func test_nitro_is_felt(t) -> void:
	for id in ["scout", "brute", "vanta", "halcyon", "stiletto"]:
		var car: Car = await _car(id, 100.0)
		for i in 120:
			_ctl(car, 1.0, 0.0, 0.0, false, true)
			await get_tree().physics_frame
		var with_n := car.forward_speed * 3.6
		await _done(car)
		car = await _car(id, 100.0)
		for i in 120:
			_ctl(car, 1.0, 0.0, 0.0)
			await get_tree().physics_frame
		var without := car.forward_speed * 3.6
		t.note("%-8s 2 s from 100 km/h: %.0f km/h with nitro, %.0f without (+%.0f)" % [id, with_n, without, with_n - without])
		t.check(with_n - without > 12.0, "%s: nitro is a real shove (+%.0f km/h)" % [id, with_n - without])
		await _done(car)
