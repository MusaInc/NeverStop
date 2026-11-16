extends SceneTree
var session: Node
func _initialize() -> void:
	_run.call_deferred()
func _run() -> void:
	session = load("res://src/lcs/session.gd").new()
	session.name = "LastCarStanding"
	root.add_child(session)
	while not session.ready_world:
		await process_frame
	await create_timer(1.0).timeout
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png("res://build/lcs-lobby.png")
	if not session.connected:
		session.host(27977)
	if session.rules.state == "waiting":
		session.begin_match()
	# Capture the actual countdown, shared city, cars and HUD.
	await create_timer(2.0).timeout
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png("res://build/lcs-match.png")
	session.drive.touch_gas = 1.0
	await create_timer(5.0).timeout
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png("res://build/lcs-active.png")
	session._report()
	print("LCS_CAPTURE lobby and match saved")
	quit()
