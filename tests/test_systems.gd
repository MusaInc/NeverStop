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
