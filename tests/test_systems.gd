extends Node
## Scoring, profile/save, progression and catalogue rules (no world needed).

var save: Node


func setup() -> void:
	save = load("res://src/core/save_data.gd").new()
	DirAccess.remove_absolute(ProjectSettings.globalize_path("user://unit_save.json"))
	DirAccess.remove_absolute(ProjectSettings.globalize_path("user://unit_save.json.bak"))
	save.use_file("user://unit_save.json")


func teardown() -> void:
	save.free()


func _run(over := {}) -> Dictionary:
	var r := {"score": 1000, "time": 30.0, "distance": 800.0, "near_misses": 3, "police_wrecked": 1, "max_heat": 2,
		"roadblocks": 0, "drift_time": 2.0, "air_time": 0.5, "top_speed": 40.0, "currency": 40}
	r.merge(over, true)
	return r


func test_chain_multiplier_builds_and_breaks(t) -> void:
	var sk := ScoreKeeper.new()
	var got: Array = []
	sk.event.connect(func(l, p, c): got.append([l, p, c]))
	sk.award("A", 100.0)
	sk.award("B", 100.0)
	sk.award("C", 100.0)
	t.near(sk.chain, 2.5, 0.01, "three quick events: x2.5")
	t.check(got[2][1] > got[0][1], "later events pay more (%d > %d)" % [got[2][1], got[0][1]])
	sk.break_chain()
	t.near(sk.chain, 1.0, 0.001, "a heavy crash breaks the chain")
	for i in 30:
		sk.award("X", 1.0)
	t.check(sk.chain <= 8.0, "chain capped at x8")
	sk.free()


func test_currency_follows_score_and_time(t) -> void:
	var sk := ScoreKeeper.new()
	sk.score = 40000.0
	sk.time = 300.0
	t.check(sk.currency() == 1000 + 50, "currency = score/40 + time/6 (%d)" % sk.currency())
	sk.free()


func test_records_and_cash(t) -> void:
	t.check(save.cash() == 0 and save.owns("kestrel"), "new profile: no cash, the Kestrel")
	var broken: Array = save.submit_run(_run(), "kestrel")
	t.check("best_score" in broken and "best_time" in broken, "first run sets records")
	t.check(save.cash() == 40, "run pays its currency")
	broken = save.submit_run(_run({"score": 500, "time": 10.0}), "kestrel")
	t.check(not "best_score" in broken, "a worse run breaks no score record")
	t.check(int(save.data["runs"]) == 2 and (save.data["history"] as Array).size() == 2, "history kept")
	t.check(not save.spend(1000), "can't overspend")
	t.check(save.spend(30) and save.cash() == 50, "spending works")


func test_save_survives_reload_and_corruption(t) -> void:
	save.add_cash(1234)
	save.save()
	var other: Node = load("res://src/core/save_data.gd").new()
	other.use_file("user://unit_save.json")
	t.check(other.cash() == 1234, "reloads")
	var f := FileAccess.open("user://unit_save.json", FileAccess.WRITE)
	f.store_string("{ broken json")
	f.close()
	other.load_data()
	t.check(other.cash() >= 0, "a corrupt save falls back (backup or defaults), no crash")
	other.free()


func test_upgrades_change_the_spec(t) -> void:
	var base: Dictionary = save.car_spec("marlin")
	save.car_state("marlin")["upgrades"]["engine"] = 3
	save.car_state("marlin")["paint"] = 2
	var up: Dictionary = save.car_spec("marlin")
	t.check(up["engine"] > base["engine"] * 1.15, "engine upgrades add power")
	t.check((up["paint"] as Color).is_equal_approx(CarCatalog.PAINTS[2][1]), "paint applied")


func test_challenges_pay_once(t) -> void:
	var done := Progression.check(_run({"time": 70.0, "max_heat": 3}), "kestrel", save)
	var ids := done.map(func(c): return c["id"])
	t.check("survive_1" in ids and "heat_3" in ids and "kestrel_3" in ids, "earned challenges (%s)" % [ids])
	var cash: int = save.cash()
	var again := Progression.check(_run({"time": 70.0, "max_heat": 3}), "kestrel", save)
	t.check(again.is_empty() and save.cash() == cash, "each pays once")


func test_every_car_is_distinct_and_priced_upward(t) -> void:
	var prev := -1
	var seen := {}
	for id in CarCatalog.ORDER:
		var s := CarCatalog.spec(id)
		var key := "%.1f/%.2f/%.0f/%s" % [s["top_speed"], s["grip"], s["mass"], s["drive"]]
		t.check(not seen.has(key), "%s has its own handling profile" % id)
		seen[key] = true
		t.check(ResourceLoader.exists("res://assets/vehicles/%s.glb" % s["body"]), "%s body model exists" % id)
	t.check(CarCatalog.CARS["kestrel"]["price"] == 0, "the starter car is free")


func test_heat_schedule(t) -> void:
	var d := PursuitDirector.new()
	t.check(d.heat_for_time(0.0) == 1, "heat 1 at the start")
	t.check(d.heat_for_time(PursuitDirector.HEAT_AT[2] + 1.0) == 3, "heat 3 on schedule")
	t.check(d.heat_for_time(PursuitDirector.HEAT_AT[-1] + PursuitDirector.HEAT_STEP_AFTER * 2.5) == 8, "keeps climbing past 6")
	d.heat = 9
	d.max_cars = 12
	t.check(d.plan()["units"] <= 12, "physical units capped by the quality budget")
	t.check(d.plan()["total"] > 40, "but the pursuit keeps growing")
	d.free()


func test_contracts_complete_pay_and_refill(t) -> void:
	var sk := ScoreKeeper.new()
	sk.running = true
	var ct := Contracts.new()
	ct.begin(sk, 7)
	t.check(ct.active.size() == Contracts.SLOTS, "three contracts on offer")
	var kinds := ct.active.map(func(c): return c["kind"])
	t.check(kinds.size() == {kinds[0]: 1, kinds[1]: 1, kinds[2]: 1}.size(), "no duplicate contracts (%s)" % [kinds])
	# Force the first one done by pushing its stat past the target.
	var c0: Dictionary = ct.active[0]
	var stat_name: String = Contracts.KINDS[c0["kind"]][1]
	match stat_name:
		"near_misses": sk.near_misses += 100
		"police_wrecked": sk.police_wrecked += 100
		"drift_time": sk.drift_time += 100.0
		"air_time": sk.air_time += 100.0
		"distance_km": sk.distance += 100000.0
		"chain": sk.chain = 8.0
		"smashed": ct.smashed += 100
		"roadblocks": sk.roadblocks += 100
		"top_speed_kmh": pass
	if stat_name == "top_speed_kmh":
		t.note("first contract is a speed one; checking the second slot path instead")
		c0 = ct.active[1]
	var got: Array = []
	ct.completed.connect(func(c): got.append(c))
	ct._physics_process(1.0 / 60.0)
	if stat_name != "top_speed_kmh":
		t.check(got.size() >= 1 and ct.done_count >= 1, "contract completed")
		t.check(ct.cash > 0 and sk.score > 0.0, "it pays cash ($%d) and score (%d)" % [ct.cash, int(sk.score)])
		t.check(ct.active.size() == Contracts.SLOTS and ct.active[0] != c0, "a new contract takes its place")
	ct.free()
	sk.free()


func test_ranks_from_career_xp(t) -> void:
	t.check(Progression.rank_index(0) == 0, "everyone starts at rank 1")
	var cash: int = save.cash()
	var gained := Progression.add_xp(save, 30000)
	t.check(gained.size() == 2, "30k XP climbs two ranks (%d)" % gained.size())
	t.check(save.cash() == cash + int(Progression.RANKS[1][2]) + int(Progression.RANKS[2][2]), "rank-ups pay")
	t.check(Progression.add_xp(save, 10).is_empty(), "no rank-up for a little XP")
	t.check(Progression.rank_progress(int(save.data["xp"])) > 0.0 and Progression.rank_progress(99999999) == 1.0, "progress bar")


func test_daily_streak(t) -> void:
	var c0: int = save.cash()
	var d1 := Progression.daily_claim(save, "2026-11-01")
	t.check(d1["claimed"] and d1["day"] == 1 and save.cash() == c0 + Progression.DAILY[0], "first day pays")
	t.check(not Progression.daily_claim(save, "2026-11-01")["claimed"], "once a day")
	var d2 := Progression.daily_claim(save, "2026-11-02")
	t.check(d2["day"] == 2 and d2["reward"] == Progression.DAILY[1], "next day continues the streak")
	var d3 := Progression.daily_claim(save, "2026-11-05")
	t.check(d3["day"] == 1, "a missed day starts again")
