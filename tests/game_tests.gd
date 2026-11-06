extends Node
## Whole-game tests, run inside the real main scene (autoloads, world,
## pursuit, UI):  godot --headless --fixed-fps 60 res://scenes/main.tscn -- --gametest [--save=...]
## Prints ok/FAIL lines like tests/run_tests.gd and quits with the failure count.

var game: Node
var failures := 0
var passes := 0
var _cur := ""
var _cur_failed := false


func check(cond: bool, msg: String) -> void:
	if not cond:
		_cur_failed = true
		print("        ✗ ", msg)


func note(msg: String) -> void:
	print("        · ", msg)


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	SaveData.use_file("user://gametest_save.json")
	DirAccess.remove_absolute(ProjectSettings.globalize_path("user://gametest_save.json"))
	SaveData.load_data()
	_run.call_deferred()


func _frames(n: int) -> void:
	for i in n:
		await get_tree().physics_frame


func _run() -> void:
	var t0 := Time.get_ticks_msec()
	var only := str(game.args.get("gametest", "1"))
	for m in get_method_list():
		var n: String = m["name"]
		if not n.begins_with("test_"):
			continue
		if only != "1" and not only in n:
			continue
		_cur = n
		_cur_failed = false
		await call(n)
		if _cur_failed:
			failures += 1
			print("  FAIL  game.", n)
		else:
			passes += 1
			print("  ok    game.", n)
	print("\n%d passed, %d failed  (game tests, %.1fs)" % [passes, failures, (Time.get_ticks_msec() - t0) / 1000.0])
	get_tree().quit(failures)


func _start(heat := 1, bot := true) -> void:
	get_tree().paused = false
	if bot:
		game.args["bot"] = "1"
	else:
		game.args.erase("bot")
	game.args["heat"] = str(heat)
	game.state = game.State.MENU
	game.start_run()
	await _frames(5)


## Every lane is drivable: a ray down at each lane point (3 m apart) finds
## road surface at the lane's height. Catches gaps and steps in the deck
## (the bridge's west anchorage used to sit 2 m below the roadway).
func test_0_roads_are_continuous() -> void:
	var net: RoadNet = game.net
	var space: PhysicsDirectSpaceState3D = game.get_world_3d().direct_space_state
	var q := PhysicsRayQueryParameters3D.new()
	q.collision_mask = Car.RAY_MASK
	var bad: Array = []
	var total := 0
	for li in net.lanes.size():
		var pts: PackedVector3Array = net.lanes[li]
		for p in pts:
			total += 1
			q.from = p + Vector3.UP * 2.5
			q.to = p + Vector3.DOWN * 4.0
			var h := space.intersect_ray(q)
			var dy: float = (h["position"] as Vector3).y - p.y if not h.is_empty() else -99.0
			if game.jumps and dy > 0.0:
				dy -= maxf(0.0, game.jumps.height_at(p) - p.y)
			if dy < -0.45 or dy > 0.6:
				bad.append([p, dy])
				if OS.has_environment("ROAD_DEBUG"):
					note("lane %d p %s dy %.2f hit %s" % [li, str(p), dy, str(h.get("collider"))])
	# Cluster for the report.
	var clusters: Array = []
	for b in bad:
		var hit := false
		for c in clusters:
			if (c[0] as Vector3).distance_to(b[0]) < 25.0:
				c[1] += 1
				c[2] = minf(c[2], b[1])
				hit = true
				break
		if not hit:
			clusters.append([b[0], 1, b[1]])
	for c in clusters.slice(0, 30):
		note("gap at %s: %d points, worst %.2f m" % [str((c[0] as Vector3).round()), c[1], c[2]])
	note("%d / %d lane points without road under them (%d places)" % [bad.size(), total, clusters.size()])
	var holes := bad.filter(func(b): return b[1] < 0.0).size()
	check(holes == 0, "no holes or drops in the roadway (%d)" % holes)
	check(bad.size() - holes <= total / 2000, "almost no steps up out of the lane surface")


func test_1_menu_then_play() -> void:
	game.enter_menu()
	await _frames(10)
	check(game.state == game.State.MENU, "starts in the menu")
	check(game.menus.current == "title", "title screen shown")
	await _start(1)
	check(game.state == game.State.PLAYING, "PLAY starts a run")
	check(game.score.running and game.score.score < 50.0, "score reset")


func test_2_police_arrive_fairly() -> void:
	await _start(3)
	game.director.audit.clear()
	await _frames(60 * 40)
	var spawns := 0
	var bad := 0
	var promotes := 0
	var close := 0.0
	for a in game.director.audit:
		if a[0] == "spawn":
			spawns += 1
			if a[2] or a[1] < PursuitDirector.SPAWN_MIN * 0.75:
				bad += 1
		else:
			promotes += 1
			if a[2] or a[1] < 45.0:
				bad += 1
			close = maxf(close, a[1])
	note("%d dispatched, %d became cars, %d unfair" % [spawns, promotes, bad])
	check(spawns >= 4, "units are dispatched at heat 3")
	check(promotes >= 1, "some reach the player as cars")
	check(bad == 0, "nobody appears in view or right next to the player")


func test_3_single_touch_is_not_a_bust() -> void:
	await _start(2)
	await _frames(60 * 8)
	check(game.director.bust < 0.5 or game.player.speed < 3.5, "bust meter only fills when stopped")


func test_4_stopping_among_police_gets_busted() -> void:
	await _start(4, false)
	game.input.enabled = false
	# Park the player and bring the nearest police in.
	var busted := [false]
	game.director.busted.connect(func(): busted[0] = true, CONNECT_ONE_SHOT)
	for i in 60 * 70:
		game.player.throttle = 0.0
		game.player.brake = 1.0
		await get_tree().physics_frame
		if busted[0]:
			break
	note("bust after %.0f s of standing still (%d units)" % [game.director.time - PursuitDirector.HEAT_AT[3], game.director.alive_count()])
	check(busted[0], "a stopped car surrounded by police is busted")
	await _frames(60 * 4)
	check(game.state == game.State.BUSTED, "busted state")
	check(game.menus.current == "results", "results screen shown")
	check(not game.hud.visible, "HUD hidden behind the results")
	check(SaveData.data["runs"] >= 1, "run recorded in the profile")
	game.input.enabled = true


func test_5_retry_is_instant_and_clean() -> void:
	var n0 := Performance.get_monitor(Performance.OBJECT_NODE_COUNT)
	for i in 3:
		await _start(3)
		await _frames(60 * 6)
		game.director.busted.emit()
		await _frames(60 * 5)
	await _start(1)
	await _frames(30)
	var n1 := Performance.get_monitor(Performance.OBJECT_NODE_COUNT)
	note("nodes: %d before, %d after 3 retries" % [n0, n1])
	check(game.state == game.State.PLAYING, "retry runs again")
	check(n1 < n0 + 400, "no runaway node growth across retries")


func test_6_pause_and_resume() -> void:
	await _start(1)
	game.pause()
	await get_tree().process_frame
	check(get_tree().paused and game.state == game.State.PAUSED, "paused")
	var p0: Vector3 = game.player.global_position
	await get_tree().create_timer(0.5, true).timeout
	check(game.player.global_position.distance_to(p0) < 0.01, "nothing moves while paused")
	game.resume()
	await _frames(10)
	check(not get_tree().paused and game.state == game.State.PLAYING, "resumed")


func test_7_civilians_drive_and_crash() -> void:
	await _start(1)
	await _frames(60 * 3)
	var cars: Array = game.civilians.active_cars()
	check(cars.size() > 8, "civilian traffic around the player (%d)" % cars.size())
	var c: Dictionary = {}
	for e in game.civilians.cars:
		if e["active"]:
			c = e
			break
	var p0: Vector3 = (c["car"] as Car).global_position
	await _frames(60)
	check((c["car"] as Car).global_position.distance_to(p0) > 1.0 or c["v"] < 1.0, "a civilian moves along its lane (or queues)")
	game.civilians._wake(c, null)
	await _frames(5)
	check(not (c["car"] as Car).freeze and c["wrecked"], "a hit civilian becomes a physical wreck")


func test_8_street_furniture_breaks() -> void:
	await _start(1)
	var item: Array = []
	for cell in game.props._grid.values():
		for it in cell:
			if it[0] == "streetlight" and (it[1] as Transform3D).origin.distance_to(game.player.global_position) < 300.0:
				item = it
				break
		if not item.is_empty():
			break
	check(not item.is_empty(), "a streetlight nearby")
	if item.is_empty():
		return
	var at: Vector3 = (item[1] as Transform3D).origin
	game.player.place(Transform3D(Basis(), at + Vector3(0, 0.5, 6.0)), Vector3(0, 0, -15.0))
	await _frames(40)
	check(game.world.broken.has(item[3]) or (item[4] as CityWorld).broken.has(item[3]), "driving through a streetlight knocks it down")


func test_9_garage_select_changes_car() -> void:
	game.quit_to_menu()
	await _frames(5)
	SaveData.data["owned"].append("brute")
	game.select_car("brute")
	await _frames(5)
	check(game.player.spec["id"] == "brute", "garage selection changes the car")
	game.select_car("kestrel")


func test_z_long_session_stays_stable() -> void:
	await _start(1)
	var n0 := Performance.get_monitor(Performance.OBJECT_NODE_COUNT)
	var mem0 := Performance.get_monitor(Performance.MEMORY_STATIC)
	var peak_units := 0
	# Five simulated minutes with the escalation running (recoveries on).
	for i in 60 * 300:
		await get_tree().physics_frame
		if i % 600 == 0:
			peak_units = maxi(peak_units, game.director.alive_count())
		if game.state == game.State.BUSTED:
			await _start(int(game.director.heat))
	var n1 := Performance.get_monitor(Performance.OBJECT_NODE_COUNT)
	var mem1 := Performance.get_monitor(Performance.MEMORY_STATIC)
	note("5 min: heat %d, peak units %d, nodes %d -> %d, static memory %.0f -> %.0f MB" % [game.director.heat, peak_units, n0, n1, mem0 / 1e6, mem1 / 1e6])
	check(n1 < n0 + 600, "node count bounded")
	check(mem1 < mem0 * 1.5 + 50e6, "memory bounded")
