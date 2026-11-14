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
	var spawn_ahead := 0
	var promote_ahead := 0
	for a in game.director.audit:
		if a[0] == "spawn" and float(a[3]) > 0.0:
			spawn_ahead += 1
		elif a[0] == "promote" and float(a[3]) > 0.0:
			promote_ahead += 1
		if a[0] == "spawn":
			spawns += 1
			if a[2] or a[1] < PursuitDirector.SPAWN_MIN * 0.75:
				bad += 1
		else:
			promotes += 1
			if a[2] or a[1] < 45.0:
				bad += 1
			close = maxf(close, a[1])
	note("%d dispatched (%d ahead), %d became cars (%d ahead), %d unfair" % [spawns, spawn_ahead, promotes, promote_ahead, bad])
	# Police come at the player from where they're heading, not up from behind.
	check(spawn_ahead >= spawns * 0.8, "most units start ahead of the player (%d / %d)" % [spawn_ahead, spawns])
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
				var p: Vector3 = (it[1] as Transform3D).origin
				if game.world.broken.has(it[3]) or (it[4] as CityWorld).broken.has(it[3]):
					continue
				# Nothing parked or wrecked in the way (earlier tests leave cars around).
				var clear := true
				for c in game.civilians.active_cars():
					if (c as Car).global_position.distance_to(p + Vector3(0, 0, 3)) < 8.0:
						clear = false
				if not clear:
					continue
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
	note("streetlight at %s, car now at %s (%.0f km/h), health %.2f" % [str(at.round()), str(game.player.global_position.round()),
		game.player.speed * 3.6, game.player.health])
	check(game.world.broken.has(item[3]) or (item[4] as CityWorld).broken.has(item[3]), "driving through a streetlight knocks it down")


func _press(text: String) -> bool:
	for b in game.menus.find_children("*", "Button", true, false):
		var bt := b as Button
		if bt.is_visible_in_tree() and (str(bt.name) == text or bt.text == text) and not bt.disabled:
			# On screen (a button pushed below the edge can't be tapped).
			var r := bt.get_global_rect()
			var vp := game.get_viewport().get_visible_rect()
			if not vp.encloses(r):
				note("'%s' is off screen at %s" % [text, r])
				return false
			bt.pressed.emit()
			return true
	return false


func test_9_garage_select_changes_car() -> void:
	game.quit_to_menu()
	await _frames(5)
	SaveData.data["cash"] = 100000
	SaveData.data["owned"] = ["kestrel"]
	SaveData.data["car"] = "kestrel"
	game.select_car("kestrel")
	await _frames(3)
	game.menus.show_screen("garage")
	await _frames(5)
	# Through the real buttons: NEXT to the Marlin, buy it, drive it.
	check(_press("Next"), "NEXT is on screen and tappable")
	await _frames(3)
	check(_press("Buy"), "BUY is offered for a car you don't own")
	await _frames(3)
	check(SaveData.owns("marlin"), "bought the Marlin")
	check(game.car_id == "marlin" and game.player.spec["id"] == "marlin", "buying selects it (%s)" % game.car_id)
	check(_press("Prev"), "PREV is on screen and tappable")
	await _frames(3)
	check(_press("Drive"), "DRIVE THIS for an owned car")
	await _frames(3)
	check(game.car_id == "kestrel" and SaveData.data["car"] == "kestrel", "switched back to the Kestrel")
	_press("Next")
	await _frames(3)
	check(_press("Drive"), "and to the Marlin again")
	await _frames(3)
	check(_press("Back"), "BACK to the title")
	await _frames(3)
	check(_press("PLAY"), "PLAY")
	await _frames(10)
	check(game.state == game.State.PLAYING and game.player.spec["id"] == "marlin", "the chase uses the chosen car (%s)" % game.player.spec["id"])
	# Busted -> CHANGE CAR -> garage works from the results screen too.
	game.state = game.State.BUSTED
	game.quit_to_menu()
	game.menus.show_screen("garage")
	await _frames(3)
	check(game.menus.current == "garage" and _press("Next"), "garage reachable again after a chase")
	SaveData.data["car"] = "kestrel"
	game.select_car("kestrel")
	game.menus.show_screen("")


func test_9b_backgrounding_pauses_and_back_resumes() -> void:
	await _start(1, false)
	await _frames(20)
	game.autopause = true
	game._notification(NOTIFICATION_APPLICATION_FOCUS_OUT)
	await _frames(2)
	check(game.state == game.State.PAUSED and get_tree().paused, "going to the background pauses the chase")
	# B / Esc on the pause screen resumes, and doesn't instantly re-pause.
	var ev := InputEventAction.new()
	ev.action = "ui_cancel"
	ev.pressed = true
	Input.parse_input_event(ev)
	await _frames(4)
	check(game.state == game.State.PLAYING and not get_tree().paused, "Back resumes")
	game.autopause = false
	# Back from a menu screen returns to the title.
	game.quit_to_menu()
	game.menus._back_to = "title"
	game.menus.show_screen("records")
	await _frames(2)
	Input.parse_input_event(ev)
	await _frames(3)
	check(game.menus.current == "title", "Back leaves Records (%s)" % game.menus.current)


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


## Police sanity over a long chase: nobody falls through the world, sits
## inside a building, lingers off-road or stuck, and the minimap shows only
## units that really exist where they really are.
func test_2b_police_stay_sane() -> void:
	await _start(5)
	var d: PursuitDirector = game.director
	var space: PhysicsDirectSpaceState3D = game.get_world_3d().direct_space_state
	var q := PhysicsRayQueryParameters3D.new()
	q.collision_mask = Car.RAY_MASK
	var counts := {"fell": 0, "inside": 0, "offroad": 0, "stuck": 0, "hidden": 0, "marker": 0, "samples": 0, "ghost": 0, "wet": 0}
	var stuck_t := {}
	var off_t := {}
	var box := PhysicsShapeQueryParameters3D.new()
	var bs := BoxShape3D.new()
	bs.size = Vector3(0.6, 0.6, 0.6)
	box.shape = bs
	box.collision_mask = 1
	for i in 60 * 90:
		await get_tree().physics_frame
		if game.state == game.State.BUSTED:
			await _start(5)
		if i % 30 != 0:
			continue
		var pp: Vector3 = game.player.global_position
		for u: PoliceUnit in d.units:
			if not u.car:
				# Virtual units: their marker should be on a road, and never
				# right by the player (a dot with no car you can see).
				var nv: Dictionary = game.net.nearest(u.pos, Vector3.ZERO, 30.0)
				if nv.is_empty():
					counts["marker"] += 1
				if u.alive() and u.pos.distance_to(pp) < 110.0:
					counts["ghost"] += 1
					note("ghost unit %d %s %.0f m from the player" % [u.id, u.state, u.pos.distance_to(pp)])
				continue
			if u.car.water_t > 3.0:
				counts["wet"] += 1
			var c: Car = u.car
			counts["samples"] += 1
			if not c.visible or c.freeze or c.global_position.y < -100.0:
				counts["hidden"] += 1
				note("unit %d (%s) has a pooled car but is in the chase" % [u.id, u.state])
				continue
			var p := c.global_position
			q.from = p + Vector3.UP * 1.0
			q.to = p + Vector3.DOWN * 30.0
			q.exclude = [c.get_rid()]
			if space.intersect_ray(q).is_empty():
				counts["fell"] += 1
				note("unit %d %s at %s: no ground under it (v %s, ground_y %.1f, tier %d, hp %.2f)" % [u.id, u.state, p.snapped(Vector3.ONE), c.linear_velocity.snapped(Vector3.ONE), game.layout.ground_y(p.x, p.z), u.tier, c.health])
			box.transform = Transform3D(Basis(), p + Vector3.UP * 0.9)
			box.exclude = [c.get_rid()]
			var ins := space.intersect_shape(box, 1)
			off_t["in%d" % u.id] = off_t.get("in%d" % u.id, 0.0) + 0.5 if not ins.is_empty() else 0.0
			if off_t["in%d" % u.id] == 2.0:
				counts["inside"] += 1
				var col: Object = ins[0]["collider"]
				note("unit %d %s at %s: inside %s (%s)" % [u.id, u.state, p.snapped(Vector3.ONE), col.name if col is Node else col, (col as Node).get_parent().name if col is Node and (col as Node).get_parent() else ""])
			if u.state == "wrecked" or u.state == "roadblock":
				continue
			var nr: Dictionary = game.net.nearest(p, Vector3.ZERO, 40.0)
			var off := (nr.is_empty() or float(nr["dist"]) > 18.0) and p.distance_to(pp) > 40.0
			off_t[u.id] = off_t.get(u.id, 0.0) + 0.5 if off else 0.0
			if off_t[u.id] == 5.0:
				counts["offroad"] += 1
				note("unit %d %s off-road for 5 s at %s" % [u.id, u.state, p.snapped(Vector3.ONE)])
			var slow := c.speed < 1.5 and p.distance_to(pp) > 15.0
			stuck_t[u.id] = stuck_t.get(u.id, 0.0) + 0.5 if slow else 0.0
			if stuck_t[u.id] == 8.0:
				counts["stuck"] += 1
				var dv: AIDriver = u.driver
				note("unit %d %s stuck 8 s at %s (hp %.2f, stuck %.1f) thr %.2f brk %.2f str %.2f path %d rem %d direct %s tspd %.1f cap %.1f whisk %s dmg %s" % [u.id, u.state, p.snapped(Vector3.ONE), c.health, c.stuck_time,
					c.throttle, c.brake, c.steer, dv.path.size(), dv.remaining(), dv.direct_target != Vector3.INF, dv.target_speed, dv.speed_cap, dv._whisk, c.dmg])
	note("police sanity: %s" % counts)
	check(counts["fell"] == 0, "no police car falls through the world")
	check(counts["inside"] == 0, "no police car inside a building")
	check(counts["hidden"] == 0, "every unit in the chase has a live car")
	check(counts["stuck"] <= 2, "police don't sit stuck")
	check(counts["offroad"] <= 2, "police don't wander off-road")
	check(counts["marker"] == 0, "minimap markers are on roads")
	check(counts["ghost"] <= 3, "no invisible police near the player (map dot without a car)")
	check(counts["wet"] == 0, "no police car drives about under the water")


## Water: a car that goes into the river / sea doesn't drive about on the
## bottom – it stalls, splashes and the player is fished back onto a road.
## Ramming: driving into a police car shoves it, keeps our speed, scores.
func test_2d_water_and_ramming() -> void:
	await _start(3, false)
	var pl: Car = game.player
	var wp := Vector3.INF
	for w in game.layout.water:
		var r: Rect2 = w
		var c := r.get_center()
		if r.size.x > 40.0 and r.size.y > 40.0 and game.layout.is_water(Vector3(c.x, 0, c.y)):
			wp = Vector3(c.x, 1.0, c.y)
			break
	check(wp != Vector3.INF, "found open water")
	var splashed := [false]
	pl.splashed.connect(func(_a, _s): splashed[0] = true)
	pl.place(Transform3D(Basis(), wp), Vector3(0, 0, -15))
	var was_wet := false
	var back := false
	for i in 60 * 5:
		await get_tree().physics_frame
		was_wet = was_wet or pl.in_water
		if was_wet and not pl.in_water and pl.global_position.y > Car.WATER_Y + 0.5:
			back = true
			break
	await _frames(30)
	var nr: Dictionary = game.net.nearest(pl.global_position, Vector3.ZERO, 20.0)
	note("water: splashed %s, wet %s, back %s at %s" % [splashed[0], was_wet, back, pl.global_position.snapped(Vector3.ONE)])
	check(splashed[0] and was_wet, "driving into the water splashes")
	check(back and not nr.is_empty() and not pl.in_water, "the player is put back on a dry road")
	# Ramming.
	await _start(3, false)
	pl = game.player
	var cop: Car = null
	for i in 60 * 25:
		await get_tree().physics_frame
		for u in game.director.units:
			if u.car and u.alive():
				cop = u.car
				break
		if cop:
			break
	check(cop != null, "a police car to ram")
	if cop == null:
		return
	var labels: Array = []
	game.score.event.connect(func(l, _p, _c): labels.append(l))
	var xf: Transform3D = pl.global_transform
	var fwd := -xf.basis.z
	fwd.y = 0.0
	fwd = fwd.normalized()
	var cp := xf.origin + fwd * 16.0
	cop.place(Transform3D(Basis.looking_at(fwd.cross(Vector3.UP), Vector3.UP), cp + Vector3.UP * 0.3))
	pl.place(Transform3D(Basis.looking_at(fwd, Vector3.UP), xf.origin + Vector3.UP * 0.3), fwd * 26.0)
	var hit := false
	var cop_v := 0.0
	var pl_v := 0.0
	for i in 60 * 2:
		pl.throttle = 1.0
		await get_tree().physics_frame
		if not hit and pl.global_position.distance_to(cop.global_position) < 4.5:
			hit = true
		if hit and i % 6 == 0:
			cop_v = maxf(cop_v, cop.linear_velocity.length())
		if labels.has("SLAM") or labels.has("BIG SLAM"):
			await _frames(10)
			cop_v = maxf(cop_v, cop.linear_velocity.length())
			pl_v = pl.linear_velocity.length()
			break
	note("ram: labels %s, cop thrown at %.1f m/s, player kept %.1f m/s, cop panels %s" % [labels, cop_v, pl_v, cop.parts_lost()])
	check(labels.has("SLAM") or labels.has("BIG SLAM"), "ramming a police car scores a SLAM")
	check(cop_v > 9.0, "the rammed car is thrown")
	check(pl_v > 9.0, "the rammer keeps going")


## Repair stations: always 3-6 live, spread out, far from the player when
## they appear; driving through one fixes the car and another appears.
## Mines from the Workshop dropper wreck police cars.
func test_2c_repairs_and_battle_kit() -> void:
	await _start(3)
	var rp: RepairPickups = game.repairs
	var lo := 99
	var hi := 0
	var min_gap := INF
	for i in 60 * 40:
		await get_tree().physics_frame
		if i % 60 == 0:
			var n := rp.live.size()
			lo = mini(lo, n)
			hi = maxi(hi, n)
			var ps := rp.positions()
			for a in ps.size():
				for b in range(a + 1, ps.size()):
					min_gap = minf(min_gap, (ps[a] as Vector3).distance_to(ps[b]))
	note("repairs live %d..%d over 40 s, closest pair %.0f m" % [lo, hi, min_gap])
	check(lo >= RepairPickups.MIN_LIVE and hi <= RepairPickups.MAX_LIVE, "between 3 and 6 repair stations at all times")
	check(min_gap > 100.0, "spread across the map")
	# Batter the car, then drive into the nearest station.
	var p: Car = game.player
	p.health = 0.3
	p.dmg["front"] = 0.8
	p._wear_part("bumper_f", 2.0, p.global_position, Vector3.FORWARD)
	p._wear_part("door_l", 2.0, p.global_position, Vector3.LEFT)
	check(p.parts["bumper_f"] <= 0.0 and p.parts["door_l"] <= 0.0, "panels knocked off")
	var target := rp.nearest(p.global_position)
	var before := rp.collected_count
	game.bot = null
	p.place(Transform3D(Basis(), target + Vector3.UP * 0.5))
	await _frames(10)
	check(rp.collected_count == before + 1, "drove through a repair station")
	check(p.health == 1.0 and p.parts_lost() == 0 and p.dmg["front"] == 0.0, "the car is good as new")
	check(rp.live.size() >= RepairPickups.MIN_LIVE, "a replacement appears (%d live)" % rp.live.size())
	var far := true
	for q in rp.positions():
		if (q as Vector3).distance_to(target) < 30.0:
			far = false
	check(far, "the used one is gone")
	# Battle kit: a mine under a police car wrecks it.
	var cop: Car = null
	for i in 60 * 20:
		await get_tree().physics_frame
		for u in game.director.units:
			if u.car and u.alive():
				cop = u.car
				break
		if cop:
			break
	check(cop != null, "a police car to test on")
	if cop:
		var w0: int = game.director.stats["wrecked"]
		game.kit._explode(cop.global_position, cop)
		await _frames(5)
		note("mine: police health %.2f, wrecked %d -> %d" % [cop.health, w0, game.director.stats["wrecked"]])
		check(game.director.stats["wrecked"] > w0, "a mine wrecks the police car")
	game.args.erase("bot")


## Battle arenas (Sky Arena / Rooftop Rumble): the arena is built where it
## should be, every start slot and ramp is drivable, the rooftop decks are
## all connected, ten cars fight, cars that go over get knocked out (with
## credit), and leaving puts the city back (police, civilians, no rivals).
func test_9c_battle_arenas() -> void:
	var space: PhysicsDirectSpaceState3D = game.get_world_3d().direct_space_state
	var q := PhysicsRayQueryParameters3D.new()
	q.collision_mask = Car.RAY_MASK
	for m in ["sky", "rooftops"]:
		game.mode = m
		await _start(1, true)
		var ar: Arena = game.arena
		check(ar != null and ar.running, "%s: arena running" % m)
		if ar == null:
			continue
		check(ar.cars.size() == Arena.N_CARS, "%s: %d cars" % [m, ar.cars.size()])
		check(game.director.alive_count() == 0 and game.civilians.active_cars().is_empty(), "%s: no police or traffic" % m)
		if m == "sky":
			check(ar.decks.size() == 1 and ar.floor_y > game.layout.ground_y(ar.centre.x, ar.centre.z) + 50.0, "sky: disc floats over the city")
		else:
			check(ar.decks.size() >= 4, "rooftops: %d decks" % ar.decks.size())
			check(ar.floor_y > 100.0, "rooftops: roofs up in the towers (%.0f m)" % ar.floor_y)
			var styles: Array = ar.links.map(func(l): return l[5])
			check(styles.has("ramp") or styles.has("gap") or styles.has("jump"), "rooftops: ramps / jumps (%s)" % str(styles))
			for di in ar.decks:
				check(ar.pieces[di].get("roof", false), "rooftops: battle floors are the towers' own roofs")
			for a in ar.decks.size():
				for b in ar.decks.size():
					if a != b:
						check(not ar.route(a, b).is_empty(), "rooftops: deck %d reaches deck %d" % [a, b])
			# Every link is a continuous surface: under its centre line every 2 m
			# (a jump road's open gap and its lips aside; kicker jumps fly).
			for l in ar.links:
				if l[5] == "jump":
					continue
				var pa: Vector3 = l[3]
				var pb: Vector3 = l[4]
				var n := int(pa.distance_to(pb) / 2.0)
				for i in n + 1:
					var p := pa.lerp(pb, float(i) / maxf(n, 1))
					if l[5] == "gap" and p.distance_to((pa + pb) * 0.5) < Arena.GAP * 0.5 + Arena.GAP_LIP.x + 0.5:
						continue
					q.from = p + Vector3.UP * 2.0
					q.to = p - Vector3.UP * 2.0
					var hit := space.intersect_ray(q)
					if hit.is_empty() or absf((hit["position"] as Vector3).y - p.y) > 0.6:
						check(false, "rooftops: bridge surface missing at %s" % p.snapped(Vector3.ONE))
						break
		for xf: Transform3D in ar.slots():
			check(ar.on_surface(xf.origin, 1.5), "%s: start slot %s on the deck" % [m, xf.origin.snapped(Vector3.ONE)])
		# Countdown: everyone stays put.
		var starts: Array = ar.cars.map(func(c): return (c as Car).global_position)
		await _frames(150)
		var moved := 0.0
		for i in ar.cars.size():
			var mv := (ar.cars[i] as Car).global_position.distance_to(starts[i])
			if mv > 1.0:
				note("%s: %s moved %.1f m from %s" % [m, (ar.cars[i] as Car).name, mv, (starts[i] as Vector3).snapped(Vector3.ONE)])
			moved = maxf(moved, mv)
		check(moved < 1.0, "%s: cars held during the countdown (moved %.1f m)" % [m, moved])
		# The fight.
		var frames := 0
		# (The others fight on after the player is out: keep watching them.)
		while frames < 60 * 70 and ar.alive.size() > 3:
			await _frames(30)
			frames += 30
			for c: Car in ar.alive:
				if is_instance_valid(c) and c.global_position.y < ar.floor_y - Arena.KO_DROP - 3.0:
					check(false, "%s: %s fell without being knocked out" % [m, c.name])
		var credited := 0
		for c in ar.out_order:
			if is_instance_valid(c) and c.last_hit_by:
				credited += 1
		note("%s: %d out in %.0f s (%d with a pusher), player %s" % [m, ar.out_order.size(), ar.time, credited,
			"out" if game.state == game.State.BUSTED else "in"])
		check(ar.out_order.size() >= 3, "%s: cars get knocked off (%d)" % [m, ar.out_order.size()])
		if game.state == game.State.BUSTED:
			check(game.last_result.has("battle") and int(game.last_result["place"]) >= 2, "%s: result has a place" % m)
		game.quit_to_menu()
		await _frames(5)
		check(game.arena == null and game.mode == "chase", "%s: back to the chase" % m)
		var left := game.get_children().filter(func(n): return str(n.name).begins_with("Rival_") and not n.is_queued_for_deletion())
		check(left.is_empty(), "%s: rivals cleaned up (%d left)" % [m, left.size()])
	# And the next chase is a normal one.
	await _start(1, true)
	await _frames(240)
	check(game.civilians.active_cars().size() > 0, "civilians back after a battle")
	check(game.director.active, "police back after a battle")


## Harbour Point: the Harbour Wheel's pier is reached from the esplanade
## along its walkway (nothing on the way stops a car), and Westbank's coast
## has sea walls (its quay and shore edges were once left bare).
func test_9e_harbour_wheel_pier_and_westbank_edges() -> void:
	await _start(1, false)
	game.director.active = false
	var hp: HarbourPoint = game.layout.harbour
	check(hp != null, "Harbour Point is laid out")
	if hp == null:
		game.director.active = true
		return
	var top := hp.base_y + 1.0
	var pier := Vector3(hp.wheel_c.x, top, hp.wheel_c.z)
	var d3 := Vector3(hp.dir.x, 0.0, hp.dir.y)
	var from := Vector3(hp.wheel_c.x, hp.base_y + 0.6, hp.base.y) - d3 * 14.0
	game.input.enabled = false
	game.player.place(Transform3D(Basis.looking_at(d3, Vector3.UP), from), d3 * 8.0)
	var best := INF
	for i in 60 * 6:
		var to_pier: Vector2 = Vector2(pier.x - game.player.global_position.x, pier.z - game.player.global_position.z)
		game.player.throttle = 0.5 if to_pier.dot(hp.dir) > 4.0 else 0.0
		game.player.brake = 0.0 if to_pier.dot(hp.dir) > 4.0 else 1.0
		await get_tree().physics_frame
		best = minf(best, to_pier.length())
	var p: Vector3 = game.player.global_position
	note("walkway: closest %.1f m to the pier centre, car at %s (pier top %.1f), %.0f km/h" % [best, str(p.snapped(Vector3.ONE * 0.1)), top, game.player.speed * 3.6])
	check(best < 9.0, "a car drives along the walkway onto the wheel's pier")
	check(absf(p.y - top) < 1.5, "and is up on the pier, not in the sea")
	game.player.throttle = 0.0
	game.player.brake = 0.0
	game.input.enabled = true
	# Westbank: sea walls round its coast as well as the island's.
	var ml: CityLayout = game.layout.mainland
	check(ml != null and BuildingMesher.coast_edges(ml.coast).size() > ml.coast.size() - 3, "Westbank's coast has sea walls")
	game.director.active = true


## The title: every control is on screen (inside the safe area), a mode card
## picks what PLAY starts, and the attract camera frames the car off-centre.
func test_9d_title_screen() -> void:
	get_tree().paused = false
	game.args.erase("bot")
	game.state = game.State.BUSTED
	game.quit_to_menu()
	await _frames(5)
	check(game.menus.current == "title", "quit lands on the title")
	check(game.camera.frame_shift > 0.0, "attract camera frames the car to the side")
	for n in ["PLAY", "mode_chase", "mode_sky", "mode_rooftops", "Garage", "Records", "How to play", "Settings"]:
		var b := game.menus.find_child(n, true, false) as Button
		var vp := game.get_viewport().get_visible_rect()
		check(b != null and b.is_visible_in_tree() and vp.encloses(b.get_global_rect()), "title: '%s' on screen" % n)
	check(_press("mode_sky"), "Sky Arena card is tappable")
	await _frames(2)
	check(game.state == game.State.MENU, "a card only selects, it doesn't start")
	check(_press("PLAY"), "PLAY")
	await _frames(10)
	check(game.state == game.State.PLAYING and game.mode == "sky", "PLAY starts the selected mode (%s)" % game.mode)
	check(game.camera.frame_shift == 0.0, "the chase camera is centred again")
	game.quit_to_menu()
	await _frames(5)
	check(_press("mode_chase"), "Pursuit card")
	check(_press("PLAY"), "PLAY again")
	await _frames(10)
	check(game.state == game.State.PLAYING and game.mode == "chase" and game.director.active, "and back to a pursuit")
	game.state = game.State.BUSTED
	game.quit_to_menu()
	await _frames(3)


## Trees line every pavement; at speed they're knocked down, not walls: the
## car loses some speed but no health, and the tree is gone for good.
func test_8b_trees_are_knocked_down() -> void:
	await _start(1, false)
	game.director.active = false
	var space: PhysicsDirectSpaceState3D = game.get_world_3d().direct_space_state
	var q := PhysicsRayQueryParameters3D.new()
	q.collision_mask = 1 | (1 << 7)   # buildings / structures + solid props
	var item: Array = []
	var from := Vector3.ZERO
	for cell in game.props._grid.values():
		for it in cell:
			if not str(it[0]).begins_with("tree") or game.world.broken.has(it[3]) or (it[4] as CityWorld).broken.has(it[3]):
				continue
			var p: Vector3 = (it[1] as Transform3D).origin
			if p.distance_to(game.player.global_position) > 600.0:
				continue
			# A clear 14 m run-up from +z (no wall, shelter or planter between).
			var start := p + Vector3(0, 0, 14.0)
			q.from = start + Vector3.UP * 1.0
			q.to = p + Vector3.UP * 1.0
			if not space.intersect_ray(q).is_empty():
				continue
			q.from = start + Vector3.UP * 3.0
			q.to = start - Vector3.UP * 3.0
			var g := space.intersect_ray(q)
			if g.is_empty() or absf((g["position"] as Vector3).y - p.y) > 0.6:
				continue
			var busy := false
			for c in game.civilians.active_cars():
				if (c as Car).global_position.distance_to(p + Vector3(0, 0, 7)) < 12.0:
					busy = true
			if busy:
				continue
			item = it
			from = (g["position"] as Vector3) + Vector3.UP * 0.5
			break
		if not item.is_empty():
			break
	check(not item.is_empty(), "a street tree with a clear run-up")
	if item.is_empty():
		game.director.active = true
		return
	game.player.place(Transform3D(Basis(), from), Vector3(0, 0, -20.0))
	var h0: float = game.player.health
	await _frames(90)
	var kmh: float = game.player.speed * 3.6
	note("%s at %s: car %.0f km/h after, health %.2f -> %.2f" % [item[0], str((item[1] as Transform3D).origin.round()), kmh, h0, game.player.health])
	check(game.world.broken.has(item[3]) or (item[4] as CityWorld).broken.has(item[3]), "driving into a tree knocks it down")
	check(game.player.global_position.z < (item[1] as Transform3D).origin.z - 2.0, "the car drives on past it")
	check(game.player.health >= h0 - 0.01, "no damage from a tree")
	game.director.active = true
