extends Node
## Vehicle physics: settling, acceleration, top speed, braking, cornering,
## drifting, stability, jumps and damage. Numbers are behaviour checks with
## generous tolerances: they catch a broken model, not tune it.

var bench: DriveBench


func setup() -> void:
	bench = DriveBench.new()
	add_child(bench)
	await get_tree().physics_frame


func teardown() -> void:
	bench.queue_free()
	await get_tree().physics_frame


func _drive(car: Car, thr: float, brk: float, steer: float, hb := false) -> void:
	car.throttle = thr
	car.brake = brk
	car.steer = steer
	car.handbrake = hb


func test_car_settles_on_four_wheels(t) -> void:
	var car := bench.spawn_car("marlin")
	await DriveBench.frames(get_tree(), 120)
	t.check(car.wheels_on_ground == 4, "all four wheels on the ground (%d)" % car.wheels_on_ground)
	t.check(car.speed < 0.3, "at rest (%.2f m/s)" % car.speed)
	t.check(car.global_basis.y.dot(Vector3.UP) > 0.99, "level")
	t.near(car.global_position.y, 0.0, 0.2, "body origin near the ground")


func test_accelerates_and_tops_out(t) -> void:
	for id in CarCatalog.ORDER:
		var car := bench.spawn_car(id, Vector3(0, 0, 0))
		await DriveBench.frames(get_tree(), 30)
		_drive(car, 1.0, 0.0, 0.0)
		var t100 := -1.0
		var time := 0.0
		for i in 60 * 40:
			await get_tree().physics_frame
			time += 1.0 / 60.0
			if t100 < 0.0 and car.forward_speed >= 27.78:
				t100 = time
			if car.global_position.z < -1850.0:
				break  # (the bench slab ends at 2 km)
		var top: float = car.spec["top_speed"]
		t.note("%s: 0-100 km/h %.1f s, speed at the end %.0f km/h (spec top %.0f)" % [id, t100, car.forward_speed * 3.6, top * 3.6])
		t.check(t100 > 2.0 and t100 < 9.0, "%s 0-100 in a sensible arcade range" % id)
		t.check(car.forward_speed > top * 0.85 and car.forward_speed < top * 1.08, "%s reaches ~top speed" % id)
		t.check(absf(car.global_position.x) < absf(car.global_position.z) * 0.03, "%s drives straight (drift %.1f m over %.0f m)" % [id, car.global_position.x, -car.global_position.z])
		car.queue_free()
		await get_tree().physics_frame


func test_brakes_from_100(t) -> void:
	var car := bench.spawn_car("marlin")
	await DriveBench.frames(get_tree(), 30)
	car.linear_velocity = -car.global_basis.z * 27.78
	await get_tree().physics_frame
	_drive(car, 0.0, 1.0, 0.0)
	var start := car.global_position
	for i in 60 * 6:
		await get_tree().physics_frame
		if car.forward_speed < 0.5:
			break
	var d := start.distance_to(car.global_position)
	t.note("100-0 km/h in %.1f m" % d)
	t.check(d > 20.0 and d < 55.0, "braking distance plausible")
	t.check(car.global_basis.y.dot(Vector3.UP) > 0.95, "stays level under braking")


func test_full_lock_at_speed_does_not_flip(t) -> void:
	for id in CarCatalog.ORDER:
		var car := bench.spawn_car(id)
		await DriveBench.frames(get_tree(), 30)
		car.linear_velocity = -car.global_basis.z * 40.0
		_drive(car, 1.0, 0.0, 1.0)
		var min_up := 1.0
		var yaw0 := car.global_rotation.y
		for i in 60 * 4:
			await get_tree().physics_frame
			min_up = minf(min_up, car.global_basis.y.dot(Vector3.UP))
		t.note("%s full lock at 144 km/h: min up %.2f, speed now %.0f km/h, turned %.0f°" % [id, min_up,
			car.speed * 3.6, rad_to_deg(angle_difference(yaw0, car.global_rotation.y))])
		t.check(min_up > 0.6, "%s doesn't roll over" % id)
		t.check(car.wheels_on_ground >= 3, "%s still on its wheels" % id)
		car.queue_free()
		await get_tree().physics_frame


func test_turn_direction_matches_steering(t) -> void:
	var car := bench.spawn_car("marlin")
	await DriveBench.frames(get_tree(), 30)
	car.linear_velocity = -car.global_basis.z * 15.0
	_drive(car, 0.6, 0.0, 1.0)
	await DriveBench.frames(get_tree(), 90)
	# Facing -Z, a right turn heads toward +X.
	t.check(car.global_position.x > 3.0, "steer right goes right (x %.1f)" % car.global_position.x)
	var r := car.speed / maxf(absf(car.angular_velocity.y), 0.01)
	t.note("turn radius at %.0f km/h: %.1f m" % [car.speed * 3.6, r])
	t.check(r > 5.0 and r < 40.0, "sensible turning circle")


func test_handbrake_drift_is_held_and_recoverable(t) -> void:
	var car := bench.spawn_car("marlin")
	await DriveBench.frames(get_tree(), 30)
	car.linear_velocity = -car.global_basis.z * 30.0
	await get_tree().physics_frame
	_drive(car, 1.0, 0.0, 1.0, true)
	await DriveBench.frames(get_tree(), 25)
	_drive(car, 1.0, 0.0, 0.7, false)
	var max_angle := 0.0
	var drifted := 0
	for i in 90:
		await get_tree().physics_frame
		max_angle = maxf(max_angle, absf(car.drift_angle))
		if car.drifting:
			drifted += 1
	t.note("drift: max slip %.0f°, %d frames drifting, speed %.0f km/h" % [rad_to_deg(max_angle), drifted, car.speed * 3.6])
	t.check(max_angle > deg_to_rad(14.0), "the handbrake kicks the tail out")
	t.check(max_angle < deg_to_rad(75.0), "the drift assist stops a spin")
	t.check(car.speed > 12.0, "a drift keeps momentum")
	_drive(car, 1.0, 0.0, 0.0)
	await DriveBench.frames(get_tree(), 120)
	t.check(absf(car.drift_angle) < deg_to_rad(8.0), "straightens up when steering is released (%.0f°)" % rad_to_deg(car.drift_angle))


func test_ramp_jump_lands_upright(t) -> void:
	bench.add_ramp(Vector3(0, 0, -40), 10.0, 2.2, 10.0)
	var car := bench.spawn_car("marlin")
	await DriveBench.frames(get_tree(), 30)
	car.linear_velocity = -car.global_basis.z * 30.0
	_drive(car, 1.0, 0.0, 0.0)
	var max_air := 0.0
	var landed_air := [0.0]
	car.landed.connect(func(a, _v): landed_air[0] = a)
	var peak := 0.0
	for i in 60 * 5:
		await get_tree().physics_frame
		max_air = maxf(max_air, car.airtime)
		peak = maxf(peak, car.global_position.y)
	t.note("ramp: airtime %.2f s, peak %.1f m" % [max_air, peak])
	t.check(max_air > 0.4, "gets airborne off a ramp")
	t.check(landed_air[0] > 0.4, "landed signal fires")
	t.check(car.global_basis.y.dot(Vector3.UP) > 0.9 and car.wheels_on_ground >= 3, "lands on its wheels")


func test_wall_impact_damages_the_right_side(t) -> void:
	bench.add_wall(Vector3(0, 1.5, -40), Vector3(20, 3, 1))
	var car := bench.spawn_car("marlin")
	await DriveBench.frames(get_tree(), 30)
	var hits := [0.0]
	car.impact.connect(func(s, _a, _n, _o): hits[0] = maxf(hits[0], s))
	car.linear_velocity = -car.global_basis.z * 20.0
	_drive(car, 1.0, 0.0, 0.0)
	await DriveBench.frames(get_tree(), 120)
	t.note("wall hit at 72 km/h: impact %.1f m/s, front damage %.2f, health %.2f" % [hits[0], car.dmg["front"], car.health])
	t.check(hits[0] > 8.0, "impact registered")
	t.check(car.dmg["front"] > car.dmg["rear"] and car.dmg["front"] > 0.1, "front takes the damage")
	t.check(car.health < 1.0 and car.health > 0.0, "damaged, not destroyed by one hit")


func test_stuck_and_upside_down_are_detected(t) -> void:
	var car := bench.spawn_car("marlin")
	await DriveBench.frames(get_tree(), 20)
	car.place(Transform3D(Basis(Vector3.FORWARD, PI), Vector3(0, 1.5, 0)))
	await DriveBench.frames(get_tree(), 120)
	t.check(car.upside_time > 0.5, "upside-down timer runs (%.2f)" % car.upside_time)


## Kerbs (0.15 m) and low ledges (0.4 m) are driven over, head-on or at an
## angle, without a crash, damage or losing most of the speed.
func test_kerbs_and_low_ledges_are_driven_over(t) -> void:
	for c in [["marlin", 0.15, 0.0, 12.0], ["marlin", 0.15, 35.0, 12.0], ["stiletto", 0.15, 0.0, 15.0],
			["kestrel", 0.4, 0.0, 14.0], ["vanta", 0.4, 30.0, 16.0], ["mammoth", 0.15, 20.0, 10.0]]:
		var id: String = c[0]
		var h: float = c[1]
		var wall := bench.add_wall(Vector3(0, h * 0.5, -60), Vector3(60, h, 100), deg_to_rad(c[2]))
		var car := bench.spawn_car(id)
		await DriveBench.frames(get_tree(), 30)
		var v0: float = c[3]
		car.linear_velocity = -car.global_basis.z * v0
		_drive(car, 0.6, 0.0, 0.0)
		var min_sp := INF
		var hits := [0.0]
		car.impact.connect(func(s, _a, _n, _o): hits[0] = maxf(hits[0], s))
		for i in 150:
			await get_tree().physics_frame
			if car.global_position.z < -11.0 and car.global_position.z > -16.0:
				min_sp = minf(min_sp, car.speed)
		var on_top := car.global_position.y > h - 0.1
		t.note("%s over a %.2f m ledge at %d°, %.0f km/h: slowest %.0f km/h, health %.2f, z %.1f, on top %s" % [
			id, h, int(c[2]), v0 * 3.6, min_sp * 3.6, car.health, car.global_position.z, on_top])
		t.check(on_top and car.global_position.z < -14.0, "%s climbs the %.2f m ledge" % [id, h])
		t.check(car.health > 0.97 and hits[0] < 2.0, "%s takes no crash damage from the ledge" % id)
		t.check(min_sp > v0 * 0.6, "%s keeps its speed over the ledge" % id)
		t.check(car.global_basis.y.dot(Vector3.UP) > 0.9, "%s stays upright" % id)
		car.queue_free()
		wall.queue_free()
		await DriveBench.frames(get_tree(), 2)


## Panels wear off with repeated hits; the player's engine never dies; a
## police car with the same beating is written off; a repair restores all.
func test_panels_fall_off_engine_never_dies(t) -> void:
	bench.add_wall(Vector3(0, 1.5, -30), Vector3(30, 3, 1))
	var car := bench.spawn_car("marlin")
	var visual := CarVisual.new()
	car.add_child(visual)
	visual.setup(car)
	car.visual = visual
	var lost: Array = []
	car.part_lost.connect(func(p, _a, _n): lost.append(p))
	await DriveBench.frames(get_tree(), 30)
	for i in 6:
		car.place(Transform3D(Basis(), Vector3(0, 0.3, 0)), Vector3(0, 0, -24.0))
		_drive(car, 1.0, 0.0, 0.0)
		await DriveBench.frames(get_tree(), 90)
	t.note("player after 6 wall hits at ~86 km/h: health %.2f, lost %s" % [car.health, lost])
	t.check("bumper_f" in lost, "front bumper came off")
	t.check(not car.disabled and car.health >= 0.2, "engine still runs (immortal)")
	var frames := visual.get_children().filter(func(n): return str(n.name).begins_with("Frame_"))
	t.check(frames.size() == lost.size(), "bare frame shown where each panel was (%d)" % frames.size())
	_drive(car, 1.0, 0.0, 0.0)
	car.place(Transform3D(Basis(Vector3.UP, PI), Vector3(0, 0.3, 0)))
	await DriveBench.frames(get_tree(), 90)
	t.check(car.speed > 4.0, "still drives away, slowly (%.1f m/s)" % car.speed)
	car.repair_full()
	await DriveBench.frames(get_tree(), 2)
	t.check(car.parts_lost() == 0 and car.health == 1.0, "repair puts everything back")
	t.check(visual.get_children().filter(func(n): return str(n.name).begins_with("Frame_") and not n.is_queued_for_deletion()).is_empty(), "frames cleared")
	var cop := bench.spawn_car("marlin", Vector3(20, 0, 0), 0.0, "police")
	await DriveBench.frames(get_tree(), 20)
	for i in 4:
		cop.place(Transform3D(Basis(), Vector3(5, 0.3, 0)), Vector3(0, 0, -24.0))
		_drive(cop, 1.0, 0.0, 0.0)
		await DriveBench.frames(get_tree(), 90)
	t.note("police after 4 hits: health %.2f, disabled %s, lost %d" % [cop.health, cop.disabled, cop.parts_lost()])
	t.check(cop.disabled, "a police car is wrecked by the same beating")


## Workshop: hydraulics hop, plating soaks hits, a ram bar shields the nose.
func test_workshop_mods(t) -> void:
	var s := CarCatalog.spec("marlin", {}, {"jump": 2, "plating": 3, "ram": 2})
	t.check(s["mod_jump"] == 2 and s["plating_k"] < 0.6 and s["front_armour"] < 0.5, "mods reach the spec")
	t.check(float(s["ram"]) > float(CarCatalog.spec("marlin")["ram"]) * 2.0, "spiked plough rams harder")
	var car := Car.new()
	car.setup(s, "player")
	bench.add_child(car)
	car.place(Transform3D(Basis(), Vector3(0, 0.6, 40)))
	await DriveBench.frames(get_tree(), 60)
	t.check(car.parts.has("plate_l"), "plating adds armour plates as parts")
	var y0 := car.global_position.y
	var ok := car.hydraulic_jump()
	var peak := y0
	for i in 90:
		await get_tree().physics_frame
		peak = maxf(peak, car.global_position.y)
	t.note("hydraulic jump: peak +%.1f m" % (peak - y0))
	t.check(ok and peak - y0 > 2.5, "hydraulics hop the car > 2.5 m")
	t.check(not car.hydraulic_jump() or car.jump_cd > 0.0, "cooldown")
	# A side hit wears the plate first, not the door.
	car._wear_part("plate_l", 0.0, Vector3.ZERO, Vector3.ZERO)
	var before: float = car.parts["door_l"]
	car._impacts.append([20.0, car.global_position - car.global_basis.x * 1.0 + Vector3.UP * 0.6, car.global_basis.x, null])
	car._handle_impacts()
	t.check(car.parts["plate_l"] < 1.0 and car.parts["door_l"] == before, "plate takes the side hit, door untouched")
