extends Node
## Steering response: how quickly and cleanly the car answers the wheel.
## These are the numbers the "steering feels off" complaints come down to:
##   * response  time from a steering step to 90 % of the steady yaw rate
##   * overshoot yaw rate peak above the steady value (twitchiness)
##   * settle    after letting go, time until the heading stops moving
##   * grip      a hard steady turn without the handbrake must stay a grip
##               turn (the drift assist taking over unasked feels like a bug)

var bench: DriveBench


func setup() -> void:
	bench = DriveBench.new()
	add_child(bench)
	await get_tree().physics_frame


func teardown() -> void:
	bench.queue_free()
	await get_tree().physics_frame


func _launch(id: String, kmh: float) -> Car:
	var car := bench.spawn_car(id)
	await DriveBench.frames(get_tree(), 30)
	car.linear_velocity = -car.global_basis.z * kmh / 3.6
	car.throttle = 0.0
	car.steer = 0.0
	await get_tree().physics_frame
	return car


## Holds speed roughly constant (part throttle) while measuring.
func _hold_speed(car: Car, target: float) -> void:
	car.throttle = clampf((target - car.forward_speed) * 0.5 + 0.35, 0.0, 1.0)


func _step(id: String, kmh: float, amount: float) -> Dictionary:
	var car: Car = await _launch(id, kmh)
	var target := kmh / 3.6
	var yaws: Array = []
	var drift_frames := 0
	car.steer = amount
	for i in 90:
		_hold_speed(car, target)
		await get_tree().physics_frame
		yaws.append(absf(car.angular_velocity.y))
		if car.drifting:
			drift_frames += 1
	var steady: float = (yaws.slice(70) as Array).reduce(func(a, b): return a + b, 0.0) / 20.0
	var t90 := -1.0
	for i in yaws.size():
		if yaws[i] >= steady * 0.9:
			t90 = (i + 1) / 60.0
			break
	var peak: float = yaws.max()
	# Let go: how long until the yaw rate dies away.
	car.steer = 0.0
	var settle := -1.0
	for i in 120:
		_hold_speed(car, target)
		await get_tree().physics_frame
		if absf(car.angular_velocity.y) < 0.03 and settle < 0.0:
			settle = (i + 1) / 60.0
	var out := {"t90": t90, "overshoot": (peak / maxf(steady, 0.001) - 1.0), "steady": steady, "settle": settle,
		"drift": drift_frames, "kmh": car.forward_speed * 3.6}
	car.queue_free()
	await get_tree().physics_frame
	return out


func test_steering_response(t) -> void:
	for id in CarCatalog.ORDER:
		for kmh in [50.0, 110.0]:
			var r: Dictionary = await _step(id, kmh, 0.6)
			t.note("%-8s %3d km/h  t90 %.2f s  overshoot %3d%%  yaw %.2f rad/s  settle %.2f s  drift frames %d" % [id, kmh,
				r["t90"], int(r["overshoot"] * 100.0), r["steady"], r["settle"], r["drift"]])
			t.check(r["t90"] > 0.0 and r["t90"] < 0.45, "%s %d km/h: turns in within 0.45 s (%.2f)" % [id, kmh, r["t90"]])
			t.check(r["overshoot"] < 0.22, "%s %d km/h: no big yaw overshoot (%d%%)" % [id, kmh, int(r["overshoot"] * 100.0)])
			t.check(r["settle"] > 0.0 and r["settle"] < 0.6, "%s %d km/h: straightens within 0.6 s of letting go (%.2f)" % [id, kmh, r["settle"]])


func test_hard_turn_stays_a_grip_turn(t) -> void:
	for id in CarCatalog.ORDER:
		var r: Dictionary = await _step(id, 90.0, 1.0)
		t.note("%-8s full lock at 90 km/h: drift frames %d / 90, yaw %.2f rad/s" % [id, r["drift"], r["steady"]])
		t.check(r["drift"] < 20, "%s: full lock without the handbrake doesn't snap into a drift" % id)
		# Sharp enough to weave through traffic: ~30 m circle at 90 km/h or tighter.
		t.check(r["steady"] > 0.75, "%s: full lock is a sharp turn (%.2f rad/s at 90 km/h)" % [id, r["steady"]])


## U-turns: full lock from a rolling start (30 / 60 km/h, throttle held) and
## from a standstill (full throttle + full lock). Time to face the other way
## and the width of road it took (the turning circle).
func _u_turn(id: String, kmh: float) -> Dictionary:
	var car: Car = await _launch(id, kmh) if kmh > 0.0 else bench.spawn_car(id)
	if kmh <= 0.0:
		await DriveBench.frames(get_tree(), 30)
	var start := car.global_position
	var f0 := -car.global_basis.z
	var right0 := car.global_basis.x
	car.steer = 1.0
	var t := -1.0
	var width := 0.0
	var turned := 0.0
	var last := f0
	for i in 600:
		if kmh > 0.0:
			_hold_speed(car, kmh / 3.6)
		else:
			car.throttle = 1.0
		await get_tree().physics_frame
		var f := -car.global_basis.z
		f.y = 0.0
		turned += absf(last.signed_angle_to(f, Vector3.UP))
		last = f
		width = maxf(width, absf((car.global_position - start).dot(right0)))
		if turned >= PI:
			t = (i + 1) / 60.0
			break
	car.queue_free()
	await get_tree().physics_frame
	return {"t": t, "width": width}


func test_u_turns(t) -> void:
	for id in CarCatalog.ORDER:
		var line := "%-8s" % id
		for kmh in [0.0, 30.0, 60.0]:
			var r: Dictionary = await _u_turn(id, kmh)
			line += "   %2d km/h: %.2f s, %4.1f m wide" % [kmh, r["t"], r["width"]]
			# A U-turn at town speed fits across a two-lane street (~10 m).
			if kmh == 30.0:
				t.check(r["t"] > 0.0 and r["t"] < 2.2 and r["width"] < 10.0, "%s: U-turn at 30 km/h in %.2f s, %.1f m wide" % [id, r["t"], r["width"]])
			if kmh == 60.0:
				t.check(r["t"] > 0.0 and r["width"] < 45.0, "%s: full lock at 60 km/h comes round in %.1f m" % [id, r["width"]])
		t.note(line)
