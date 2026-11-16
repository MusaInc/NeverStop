extends SceneTree
func _initialize() -> void:
	_run.call_deferred()
func _run() -> void:
	var session: Node = load("res://src/lcs/session.gd").new()
	session.name = "LastCarStanding"
	root.add_child(session)
	var deadline := Time.get_ticks_msec() + 180000
	while session.rules.state != "finished" and session.elapsed_wall < 755 and Time.get_ticks_msec() < deadline:
		await physics_frame
	var remaining: int = session.rules.remaining()
	var ok: bool = session.rules.state == "finished" and remaining <= 1
	ok = ok and session.rules.elapsed <= 750 and session.rules.events.size() == 10 - remaining
	for car in session.cars.values():
		ok = ok and car.health >= 0 and car.health <= 1
	session._report()
	print("LCS_FULL_MATCH ", "PASS" if ok else "FAIL", " active_seconds=", session.rules.elapsed,
		" winner=", session.rules.winner, " remaining=", remaining, " unique_eliminations=", session.rules.events.size())
	quit(0 if ok else 1)
