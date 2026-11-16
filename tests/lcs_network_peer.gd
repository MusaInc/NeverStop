extends SceneTree
## A real ENet server/client pair; invoked by tools/lcs_network_test.py.
var session: Node
var role := "client"
var failed := false
var options := {}

func _initialize() -> void:
	for arg in OS.get_cmdline_user_args():
		var kv := arg.trim_prefix("--").split("=", true, 1)
		options[kv[0]] = kv[1] if kv.size() > 1 else "1"
	role = str(options.get("role", "client"))
	_run.call_deferred()

func check(condition: bool, label: String) -> void:
	print("NET ", "PASS " if condition else "FAIL ", label)
	failed = failed or not condition

func until(predicate: Callable, timeout_s := 20.0) -> bool:
	var deadline := Time.get_ticks_msec() + int(timeout_s * 1000)
	while not predicate.call() and Time.get_ticks_msec() < deadline:
		await process_frame
	return predicate.call()

func _run() -> void:
	session = load("res://src/lcs/session.gd").new()
	session.name = "LastCarStanding"
	root.add_child(session)
	if role == "server":
		print("NET_SERVER_READY")
		check(await until(func(): return session.rules.state == "active", 30), "two clients admitted and countdown completed")
		if session.rules.state != "active":
			quit(1)
			return
		var starts := {}
		for id in session.cars:
			starts[id] = session.cars[id].global_position
		check(await until(func(): return session.rules.elapsed > 7, 20), "authoritative simulation advances")
		var moved := 0.0
		for id in starts:
			moved = maxf(moved, starts[id].distance_to(session.cars[id].global_position))
		check(moved > 10, "remote controls move real shared-physics vehicles")
		check(session.rules.players.size() == 2, "reconnect preserves identity and roster")
		check(session.peers.size() == 2 and session.disconnected.is_empty(), "both clients connected after resume")
		# Exercise server validation directly with an unregistered RPC sender (0).
		var before: Vector3 = session.cars[1].global_position
		session.submit_input(999999, NAN, INF, -INF, true, true, 9999)
		check(before == session.cars[1].global_position, "invalid control packet cannot set position")
		# Deterministic authoritative takedown; health/events are verified on both clients.
		# Fix the fixture at 40 HP; earlier real driving may already have hit a wall.
		session.rules.players[1].hp = 40.0
		session.cars[1].health = 0.4
		session.rules.hit(2, 1)
		session.rules.damage(2, 100)
		for id in session.cars:
			session.cars[id].health = session.rules.players[id].hp / 100.0
		session.rules.complete()
		check(session.rules.winner == 1 and session.rules.players[1].hp == 75, "server confirms winner and +35 HP reward")
		await create_timer(3.0).timeout
		check(session.bytes_sent > 0 and session.max_snapshot_bytes < 1400, "bounded snapshot packets transmitted")
		print("NET_WIRE payload_bytes=", session.bytes_sent, " max_packet=", session.max_snapshot_bytes)
	else:
		check(await until(func(): return session.status == "active" and session.cars.has(session.local_id), 30), "client receives spawn and active match")
		if not session.cars.has(session.local_id):
			quit(1)
			return
		var identity: int = session.local_id
		session.drive.touch_gas = 1.0
		check(not session.cars[identity].authoritative, "client vehicle is prediction only")
		if str(options.get("name", "")) == "Reconnect":
			await create_timer(1.0).timeout
			var saved_token: String = session.token
			session.multiplayer.multiplayer_peer.close()
			session._lost_connection()
			await create_timer(0.3).timeout
			session.join_server("127.0.0.1", int(options.port), "Reconnect", "sports")
			check(await until(func(): return session.connected and not session.connecting, 10), "transport reconnects")
			await create_timer(0.5).timeout
			check(session.local_id == identity and session.token == saved_token, "opaque resume token restores same vehicle")
		check(await until(func(): return session.status == "finished", 20), "winner state replicated")
		await create_timer(0.5).timeout
		check(session.winner == 1, "winner identity replicated reliably")
		check(session.last_event == 1, "elimination delivered exactly once")
		check(session.roster[1].kills == 1 and not session.roster[2].alive, "kills and alive roster synchronized")
		check(absf(session.cars[1].health * 100.0 - 75) < 0.01, "authoritative healing synchronized")
	print("NET_RESULT ", role, " ", "FAIL" if failed else "PASS")
	quit(1 if failed else 0)
