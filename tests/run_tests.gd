extends SceneTree
## Headless test runner:  godot --headless -s res://tests/run_tests.gd [-- filter]
## Runs every `test_*` method in tests/test_*.gd. Methods may `await`.
## Exit code is the number of failures (0 = green).

var failures := 0
var passes := 0
var _current := ""
var _current_failed := false
var _checks := 0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	# Never touch the player's real records.
	var save_data := root.get_node_or_null("SaveData")
	if save_data:
		DirAccess.remove_absolute(ProjectSettings.globalize_path("user://test_save.json"))
		save_data.use_file("user://test_save.json")
	var filter := ""
	var args := OS.get_cmdline_user_args()
	if args.size() > 0:
		filter = args[0]
	var dir := DirAccess.open("res://tests")
	var files: Array[String] = []
	for f in dir.get_files():
		if f.begins_with("test_") and f.ends_with(".gd"):
			files.append(f)
	files.sort()
	var t0 := Time.get_ticks_msec()
	for f in files:
		var script: GDScript = load("res://tests/" + f)
		var suite: Object = script.new()
		if suite is Node:
			root.add_child(suite)
		if suite.has_method("setup"):
			suite.set("runner", self)
		for m in suite.get_method_list():
			var name: String = m["name"]
			if not name.begins_with("test_"):
				continue
			if filter != "" and not (f + ":" + name).contains(filter):
				continue
			_current = f.get_basename() + "." + name
			_current_failed = false
			_checks = 0
			if suite.has_method("setup"):
				await suite.setup()
			await suite.call(name, self)
			if suite.has_method("teardown"):
				await suite.teardown()
			if _checks == 0:
				_current_failed = true
				print("        ✗ no assertions ran – the test crashed or returned early")
			if _current_failed:
				failures += 1
				print("  FAIL  ", _current)
			else:
				passes += 1
				print("  ok    ", _current)
		if suite is Node:
			suite.queue_free()
		elif not (suite is RefCounted):
			suite.free()
	print("\n%d passed, %d failed  (%.1fs)" % [passes, failures, (Time.get_ticks_msec() - t0) / 1000.0])
	quit(failures)


func check(cond: bool, msg: String) -> bool:
	_checks += 1
	if not cond:
		_current_failed = true
		print("        ✗ ", msg)
	return cond


func near(a: float, b: float, tol: float, msg: String) -> bool:
	return check(absf(a - b) <= tol, "%s: got %.4f expected %.4f ±%.4f" % [msg, a, b, tol])


func note(msg: String) -> void:
	print("        · ", msg)
