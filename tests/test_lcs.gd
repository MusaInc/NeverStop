extends RefCounted

func match_with(n: int) -> LcsRules:
	var r := LcsRules.new()
	for id in range(1, n + 1):
		r.join(id, "Driver %d" % id, LcsRules.CLASSES[id % 4])
	r.start()
	r.advance(5.0)
	return r

func test_lcs_health_reward_once(t) -> void:
	var r := match_with(3)
	r.damage(1, 70)
	r.hit(2, 1)
	r.damage(2, 100)
	t.near(r.players[1].hp, 65, 0.001, "kill heals exactly 35 HP")
	r.damage(2, 100)
	r.eliminate(2, "collision")
	t.near(r.players[1].hp, 65, 0.001, "duplicate elimination cannot heal twice")
	t.check(r.players[1].kills == 1 and r.events.size() == 1, "kill/event idempotence")
	r.hit(3, 1)
	r.damage(3, 100)
	t.near(r.players[1].hp, 100, 0.001, "recovery capped at 100")
	r.complete()
	t.check(r.winner == 1 and r.state == "finished", "last survivor wins")

func test_lcs_credit_timeout_and_disconnect(t) -> void:
	var r := match_with(4)
	r.damage(1, 40)
	r.hit(2, 1)
	r.advance(8.1)
	r.damage(2, 100, "storm")
	t.near(r.players[1].hp, 60, 0.001, "expired hit earns no heal")
	r.hit(3, 1)
	r.eliminate(3, "disconnect")
	t.near(r.players[1].hp, 60, 0.001, "disconnect cannot be farmed for health")
	r.hit(4, 1)
	r.damage(4, 100, "storm")
	t.near(r.players[1].hp, 95, 0.001, "recent ram earns storm finish")

func test_lcs_no_heal_outside_elimination(t) -> void:
	var r := match_with(2)
	r.damage(1, 40)
	r.advance(400)
	r.damage(1, -100)
	r.damage(1, NAN)
	t.near(r.players[1].hp, 60, 0.001, "no regen, negative damage or NaN heal")
	for kind in LcsRules.CLASSES:
		var spec := LcsRules.vehicle(kind)
		t.check(spec.repair == 0 and spec.ram == 1.0, kind + " has no repair perk or upgraded ram")

func test_lcs_queue_capacity_and_countdown(t) -> void:
	var r := LcsRules.new()
	t.check(not r.start(), "empty queue cannot start")
	t.check(r.join(1, "Driver", "sports"), "first human enters queue")
	t.check(not r.join(1, "Duplicate", "sports"), "duplicate identity refused")
	t.check(not r.join(2, "Invalid", "godmode"), "invalid class refused")
	t.check(not r.start(), "solo human must wait or fill bots")
	for id in range(2, 101):
		r.join(id, "BOT %d" % id, "muscle", true)
	t.check(not r.join(101, "Overflow", "suv"), "100 player cap")
	t.check(r.start(), "full queue starts countdown")
	r.damage(1, 100)
	t.near(r.players[1].hp, 100, 0, "countdown is invulnerable")
	r.advance(4.99)
	t.check(r.state == "countdown", "full five-second countdown")
	r.advance(0.01)
	t.check(r.state == "active", "countdown enters active")
	t.check(not r.join(102, "Late", "suv"), "late joins refused")

func test_lcs_simultaneous_draw_and_no_posthumous_reward(t) -> void:
	var r := match_with(2)
	r.hit(2, 1)
	r.damage(1, 100, "storm")
	r.damage(2, 100)
	r.complete()
	t.check(r.state == "finished" and r.winner == 0, "same-tick last deaths draw")
	t.check(r.players[1].hp == 0 and r.players[1].kills == 0, "dead competitor cannot heal")

func test_lcs_storm_nested_and_finish(t) -> void:
	var storm := LcsStorm.new()
	storm.final_center = Vector2(-210, -17)
	var previous := storm.sample(0)
	var max_dps := 0.0
	for second in range(1, 800):
		var zone := storm.sample(second)
		t.check(float(zone.radius) <= float(previous.radius) + 0.001, "radius never grows")
		t.check((zone.center as Vector2).distance_to(previous.center) + float(zone.radius) <= float(previous.radius) + 0.01, "moving circle stays nested")
		t.check(float(zone.dps) >= max_dps, "storm damage increases")
		max_dps = zone.dps
		previous = zone
	t.near(previous.radius, 0, 0.001, "storm fully collapses within 10–15 min")
	t.check((previous.center as Vector2).distance_to(storm.final_center) < 0.001, "final centre preserved")
	t.check(LcsStorm.outside(Vector3(10000, 20, 0), storm.sample(0)), "outside test uses horizontal distance")
	t.check(not LcsStorm.outside(Vector3(0, 10000, 0), storm.sample(0)), "bridge height does not cause storm damage")

func test_lcs_collision_momentum_and_deformation(t) -> void:
	var a := LcsCompetitor.new()
	var b := LcsCompetitor.new()
	a.setup(LcsRules.vehicle("sports"), "competitor")
	b.setup(LcsRules.vehicle("heavy"), "competitor")
	t.root.add_child(a)
	t.root.add_child(b)
	a.immortal = false
	b.immortal = false
	# Same Jolt impulse / own mass = physical change in velocity.
	var impulse := 26000.0
	a._impacts.append([impulse / a.mass, a.global_position, Vector3.RIGHT, b])
	b._impacts.append([impulse / b.mass, b.global_position, Vector3.LEFT, a])
	a._handle_impacts()
	b._handle_impacts()
	t.check(a.health < b.health, "heavier, tougher car takes less impulse damage")
	t.check(a.dmg.front + a.dmg.rear + a.dmg.left + a.dmg.right > 0, "side damage drives handling deterioration")
	t.check(a.parts.bumper_f < 1 or a.parts.bumper_r < 1 or a.parts.door_l < 1 or a.parts.door_r < 1, "existing panel wear retained")
	var hp := a.health
	a.repair_full()
	t.near(a.health, hp, 0, "repair call cannot heal competitor")
	a.authoritative = false
	a._impacts.append([50.0, a.global_position, Vector3.RIGHT, b])
	a._handle_impacts()
	t.near(a.health, hp, 0, "client collision cannot author health")
	a.queue_free()
	b.queue_free()
	await t.process_frame

func test_lcs_graph_reachability(t) -> void:
	var edges := [PackedInt32Array([1]), PackedInt32Array([0, 2]), PackedInt32Array([]), PackedInt32Array([3])]
	var found := LcsRoadSites.reachable(0, edges)
	t.check(found.has(0) and found.has(1) and found.has(2) and not found.has(3), "road traversal excludes disconnected geometry")

func test_lcs_same_tick_trade_is_order_independent(t) -> void:
	for order in [[1, 2], [2, 1]]:
		var r := match_with(2)
		r.hit(1, 2)
		r.hit(2, 1)
		r.begin_damage_batch()
		for id in order:
			r.damage(id, 100)
		r.end_damage_batch()
		r.complete()
		t.check(r.winner == 0 and r.remaining() == 0, "lethal trade cannot be rescued by iteration-order healing")
		t.check(r.players[1].hp == 0 and r.players[2].hp == 0, "both lethal vehicles stay eliminated")

func test_lcs_city_spawns_and_finales(t) -> void:
	var layout := LcsRoadSites.city_layout()
	t.check(CityRoads.parallel_field_bake, "LCS generation restores the original mode's parallel-bake setting")
	var net := RoadNet.new().build(layout)
	var sites := LcsRoadSites.new()
	sites.build(net, layout)
	t.check(sites.sites.size() >= 100, "city supplies 100 distinct connected road spawns")
	for category in sites.categories:
		t.check(not sites.categories[category].is_empty(), category + " finale category available")
	var rng := RandomNumberGenerator.new()
	rng.seed = 2026
	var spawns := sites.spawns(100, rng)
	var east := 0
	var west := 0
	for i in spawns.size():
		var p: Vector3 = spawns[i].origin
		east += int(p.x > 0)
		west += int(p.x < -440)
		t.check(not layout.is_water(p) or p.y > Car.WATER_Y + 2, "spawn is dry road or raised bridge")
		for j in range(i):
			t.check(p.distance_to(spawns[j].origin) >= 17.99, "spawn clearance prevents overlap")
	t.check(east > 0 and west > 0, "competitors distributed over both islands")
	for seed_value in 10:
		rng.seed = seed_value
		var pair := sites.spawns(2, rng)
		t.check(pair[0].origin.x > 70 and pair[1].origin.x < -440, "two-player rooms also spawn on both islands, excluding the bridge")
	for i in 100:
		var p := sites.final_site(rng)
		t.check(p.is_finite() and (not layout.is_water(p) or p.y > Car.WATER_Y + 2), "random finale is reachable road geometry")

func test_lcs_terminal_result_cannot_regress(t) -> void:
	# Reliable results and unreliable snapshots travel on different channels.
	var session: Node = load("res://src/lcs/session.gd").new()
	session.status = "finished"
	session.clock = 123.0
	session.winner = 5
	session.snapshot(200, [], {}, "active", 120.0, -1)
	session.match_status(PackedInt32Array(), "active", 120.0, 0, 0)
	session.match_info({}, "countdown", 0.0, 0, 10, 0)
	t.check(session.status == "finished" and session.winner == 5, "late packets cannot undo a confirmed winner")
	t.near(session.clock, 123.0, 0, "late packets cannot rewind terminal match time")
	session.free()
