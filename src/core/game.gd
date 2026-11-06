class_name Game
extends Node3D
## Composition root and state machine:
##   MENU (attract chase behind the title) -> PLAYING -> PAUSED / BUSTED
##   (capture cinematic + results) -> PLAYING (retry) / MENU / GARAGE.
##
## Command-line user args (after `--`), for tools, tests and captures:
##   --play                 skip the menu, start a run
##   --car=<id>             player car         --start=<spot id>
##   --bot                  autopilot drives the player car
##   --heat=<n>             start at heat n    --seed=<n>
##   --shot=<png> --shot-at=<s,s,...>   timed screenshots then quit
##   --quit-after=<s>       quit after s seconds (benchmarks)
##   --time=<h> --weather=<w> --quality=0|1|2 --perf --touch --menu=<screen>
##   --save=<path>          scratch save file (never the player's)

enum State { MENU, PLAYING, PAUSED, BUSTED, GARAGE }

signal state_changed(s: int)

var state := State.MENU
var args := {}
var rng := RandomNumberGenerator.new()
var world: CityWorld
var layout: CityLayout
var net: RoadNet
var atmosphere: Atmosphere
var player: Car
var player_visual: CarVisual
var input: DriveInput
var camera: ChaseCamera
var bot: AIDriver
var bot_field: RoadNet.Field
var director: PursuitDirector
var civilians: CivilianTraffic
var score: ScoreKeeper
var hud: Hud
var touch: TouchDrive
var ui: CanvasLayer
var audio: AudioDirector
var menus: Node            # Menus (title, garage, records, settings, pause, results)
var car_id := "kestrel"
var last_result := {}
var _bust_t := -1.0
var _bot_t := 0.0
var _shots: Array = []
var _shot_path := ""
var _time := 0.0
var _quit_after := -1.0


func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		var kv := a.trim_prefix("--").split("=", true, 1)
		args[kv[0]] = kv[1] if kv.size() > 1 else "1"
	if args.has("save"):
		SaveData.use_file(args["save"])
	if args.has("quality"):
		Settings.quality = int(args["quality"])
	if args.has("perf"):
		Settings.show_perf = true
	Settings.apply()
	if args.has("seed"):
		rng.seed = int(args["seed"])
	else:
		rng.randomize()
	if args.has("shot"):
		_shot_path = args["shot"]
		for t in str(args.get("shot-at", "3")).split(","):
			_shots.append(float(t))
	if args.has("quit-after"):
		_quit_after = float(args["quit-after"])

	atmosphere = Atmosphere.new()
	atmosphere.name = "Atmosphere"
	add_child(atmosphere)
	var t0 := Time.get_ticks_msec()
	layout = CityLayout.new().generate()
	world = CityWorld.new()
	world.name = "World"
	world.layout = layout
	add_child(world)
	atmosphere.configure(args, world)
	net = RoadNet.new().build(layout)
	print("World + road graph: %d ms (%d lanes, %d nodes)" % [Time.get_ticks_msec() - t0, net.lanes.size(), net.node_count()])

	camera = ChaseCamera.new()
	camera.name = "ChaseCamera"
	add_child(camera)
	camera.reduce_motion = Settings.reduce_motion
	camera.distance_setting = Settings.camera_distance
	world.set_viewer(camera)
	input = DriveInput.new()
	input.name = "DriveInput"
	add_child(input)
	director = PursuitDirector.new()
	director.name = "Pursuit"
	add_child(director)
	civilians = CivilianTraffic.new()
	civilians.name = "Civilians"
	add_child(civilians)
	score = ScoreKeeper.new()
	score.name = "Score"
	add_child(score)
	ui = CanvasLayer.new()
	add_child(ui)
	hud = Hud.new()
	ui.add_child(hud)
	touch = TouchDrive.new()
	ui.add_child(touch)
	touch.input = input
	touch.pause_pressed.connect(pause)
	hud.touch_mode = DisplayServer.is_touchscreen_available() or args.has("touch")
	touch.visible = hud.touch_mode
	car_id = args.get("car", SaveData.data["car"])
	if not SaveData.owns(car_id) and not args.has("car"):
		car_id = "kestrel"
	spawn_player(car_id)
	director.setup(self, net, player, camera)
	civilians.setup(net, player, camera, director)
	score.player = player
	score.director = director
	score.civilians = civilians
	hud.bind(self, player, director, score)
	hud.minimap.camera = camera
	hud.minimap.bake.call_deferred(layout)
	director.unit_wrecked.connect(func(u, _b): score.on_police_wrecked(u))
	director.roadblock_escaped.connect(score.on_roadblock_escaped)
	director.busted.connect(_on_busted)
	director.spiked.connect(func(): camera.shake(0.4))
	civilians.reset_around(player.global_position)
	audio = AudioDirector.new()
	audio.name = "Audio"
	add_child(audio)
	audio.attach(self, player, director)
	score.event.connect(func(_l, pts, _c): if pts > 0: audio.event_chime(pts))
	var menus_script: Script = load("res://src/ui/menus.gd") if ResourceLoader.exists("res://src/ui/menus.gd") else null
	if menus_script:
		menus = menus_script.new()
		ui.add_child(menus)
		menus.setup(self)
	if args.has("play") or (args.has("shot") and not args.has("menu")) or menus == null:
		start_run()
	else:
		enter_menu()


## A lane point near the chosen start spot with a long straight ahead,
## facing along it (so the first five seconds are a clean launch).
func spawn_point() -> Transform3D:
	var spot_id: String = args.get("start", SaveData.data.get("start", "downtown"))
	var spot: Dictionary = Progression.STARTS.get(spot_id, Progression.STARTS["downtown"])
	var c: Vector3 = spot["at"]
	var best := Transform3D(Basis(), Vector3(560, 25, -170))
	var best_score := -INF
	for attempt in 60:
		var q := c + Vector3(rng.randf_range(-160, 160), 0, rng.randf_range(-160, 160))
		var n := net.nearest(q, Vector3.ZERO, 40.0, -1, true)
		if n.is_empty():
			continue
		var li: int = n["lane"]
		var s: float = n["s"]
		if net.lane_len[li] - s < 90.0:
			continue
		var d := net.lane_dir(li, s)
		var straight := net.lane_dir(li, s + 60.0).dot(d) + net.lane_dir(li, s + 30.0).dot(d)
		var sc := straight - (net.nearest(q).get("dist", 0.0) as float) * 0.01 + rng.randf() * 0.2
		if sc > best_score:
			best_score = sc
			best = Transform3D(Basis.looking_at(d, Vector3.UP), net.lane_point(li, s) + Vector3.UP * 0.3)
	return best


func spawn_player(id: String) -> void:
	if player:
		player.queue_free()
		player = null
	car_id = id
	player = Car.new()
	player.name = "Player"
	player.setup(SaveData.car_spec(id), "player")
	add_child(player)
	player_visual = CarVisual.new()
	player.add_child(player_visual)
	player_visual.setup(player)
	player.visual = player_visual
	player.place(spawn_point())
	input.car = player
	camera.set_target(player, true)
	player.impact.connect(_on_player_impact)
	player.landed.connect(func(a, v):
		if score:
			score.on_landed(a, v)
		camera.shake(clampf(v / 25.0, 0.05, 0.5)))
	world.build_all_near(player.global_position, 420.0)
	if audio:
		audio.set_player(player)
	if director:
		director.player = player
		civilians.player = player
		score.player = player
		hud.player = player
		hud.minimap.player = player
		touch.car = player


func start_run() -> void:
	get_tree().paused = false
	Engine.time_scale = 1.0
	if state == State.BUSTED or state == State.MENU or state == State.GARAGE:
		# Fresh car at a fresh start spot.
		spawn_player(car_id)
	state = State.PLAYING
	_bust_t = -1.0
	camera.chase()
	camera.set_target(player, true)
	input.enabled = true
	bot = null
	if args.has("bot"):
		bot = AIDriver.new(player)
		bot.skill = 0.9
		input.enabled = false
	civilians.reset_around(player.global_position)
	director.start(int(args.get("heat", "1")))
	score.begin()
	hud.visible = true
	touch.visible = hud.touch_mode
	if audio:
		audio.menu_mode = false
	touch.release_all()
	if menus:
		menus.show_screen("")
	state_changed.emit(state)


## Garage: switch the car used for the next chase (and the attract drive).
func select_car(id: String) -> void:
	car_id = id
	if state == State.MENU:
		var xf := player.global_transform
		var v := player.linear_velocity
		spawn_player(id)
		player.place(xf, v)
		bot = AIDriver.new(player)
		bot.skill = 0.88


func ui_click() -> void:
	if has_node("Audio"):
		get_node("Audio").ui_click()


func enter_menu() -> void:
	state = State.MENU
	director.clear()
	score.running = false
	hud.visible = false
	touch.visible = false
	if audio:
		audio.menu_mode = true
	# Attract mode: the autopilot drives with a couple of cops in tow.
	bot = AIDriver.new(player)
	bot.skill = 0.88
	input.enabled = false
	director.start(2)
	if menus:
		menus.show_screen("title")
	state_changed.emit(state)


func pause() -> void:
	if state != State.PLAYING:
		return
	state = State.PAUSED
	get_tree().paused = true
	touch.release_all()
	if menus:
		menus.show_screen("pause")
	state_changed.emit(state)


func resume() -> void:
	if state != State.PAUSED:
		return
	state = State.PLAYING
	get_tree().paused = false
	if menus:
		menus.show_screen("")
	state_changed.emit(state)


func quit_to_menu() -> void:
	get_tree().paused = false
	Engine.time_scale = 1.0
	spawn_player(car_id)
	civilians.reset_around(player.global_position)
	enter_menu()


func _on_busted() -> void:
	if state != State.PLAYING:
		return
	state = State.BUSTED
	_bust_t = 0.0
	input.enabled = false
	bot = null
	player.throttle = 0.0
	player.brake = 1.0
	score.running = false
	hud.flash(UiStyle.RED, 0.6)
	# The capture cinematic: slow motion, the camera swings round the scene.
	Engine.time_scale = 0.35
	camera.orbit(camera.view_yaw() + PI)
	touch.visible = false
	last_result = score.summary()
	last_result["car"] = car_id
	last_result["records"] = SaveData.submit_run(last_result, car_id)
	last_result["challenges"] = Progression.check(last_result, car_id, SaveData)
	state_changed.emit(state)


func _on_player_impact(strength: float, at: Vector3, n: Vector3, other: Object) -> void:
	if score:
		score.on_player_impact(strength, other)
	if strength > 14.0 and hud:
		hud.flash(UiStyle.RED, clampf(strength / 60.0, 0.1, 0.4))
	camera.shake(clampf(strength / 30.0, 0.1, 0.8))
	if player_visual:
		player_visual.dent(at, -n, clampf(strength / 60.0, 0.03, 0.25))
	Settings.haptic(int(clampf(strength * 4.0, 20.0, 160.0)), clampf(strength / 25.0, 0.3, 1.0))


func _physics_process(dt: float) -> void:
	_time += dt
	RenderingServer.global_shader_parameter_set(&"player_pos", player.global_position)
	if bot:
		_drive_bot(dt)
	if args.has("trace") and Engine.get_physics_frames() % 30 == 0:
		var hits := []
		for i in 4:
			hits.append(player.wheel_contact(i))
		if not args.has("quiet"): print("TRACE t=%.1f pos=%s v=%.0f km/h on=%d thr=%.2f brk=%.2f steer=%.2f hits=%s ground=%.2f" % [_time,
			player.global_position.snapped(Vector3.ONE * 0.01), player.speed * 3.6, player.wheels_on_ground,
			player.throttle, player.brake, player.steer, hits, layout.ground_y(player.global_position.x, player.global_position.z)])
		if Engine.get_physics_frames() % 120 == 0:
			var states := {}
			for u in director.units:
				states[u.state + ("*" if u.car else "")] = states.get(u.state + ("*" if u.car else ""), 0) + 1
			print("PURSUIT t=%.0f heat=%d alive=%d cars=%d bust=%.2f score=%d chain=%.1f near=%d wrecked=%d rb=%d civ=%d hp=%.2f %s" % [
				director.time, director.heat, director.alive_count(), director.physical_count(), director.bust, score.score,
				score.chain, score.near_misses, director.stats["wrecked"], director.roadblocks.size(), civilians.active_cars().size(),
				player.health, states])
	if state == State.PLAYING or state == State.MENU:
		if player.upside_time > 2.0 or (Input.is_action_just_pressed("recover") and state == State.PLAYING):
			recover_player()
		elif player.stuck_time > 3.5 and not player.disabled and director.bust < 0.05:
			recover_player()
	if state == State.PLAYING and Input.is_action_just_pressed("pause"):
		pause()
	if state == State.MENU and bot and player.disabled:
		quit_to_menu()
	if _bust_t >= 0.0:
		_bust_t += dt / maxf(Engine.time_scale, 0.01)
		if _bust_t > 3.2 and Engine.time_scale < 1.0:
			Engine.time_scale = 1.0
			if menus:
				menus.show_results(last_result)


## Puts the car back on the nearest lane facing along it (context recovery).
func recover_player() -> void:
	var near := net.nearest(player.global_position, -player.global_basis.z, 60.0, -1, true)
	if near.is_empty():
		near = net.nearest(player.global_position, Vector3.ZERO, 300.0)
	if near.is_empty():
		return
	var d := net.lane_dir(near["lane"], near["s"])
	player.place(Transform3D(Basis.looking_at(d, Vector3.UP), (near["pos"] as Vector3) + Vector3.UP * 0.4), d * 8.0)
	camera.set_target(player, true)


func _drive_bot(dt: float) -> void:
	_bot_t -= dt
	if _bot_t <= 0.0 or bot.remaining() < 15:
		_bot_t = 2.0
		var near := net.nearest(player.global_position, -player.global_basis.z, 40.0)
		if not near.is_empty():
			bot.set_path(net.wander(near["lane"], near["s"], 400.0, rng, 0.3))
	bot.update(dt, get_world_3d().direct_space_state)


func _process(_dt: float) -> void:
	if _quit_after > 0.0 and _time >= _quit_after:
		get_tree().quit()
	if not _shots.is_empty() and _time >= float(_shots[0]):
		var t: float = _shots.pop_front()
		_capture(t)


func _capture(t: float) -> void:
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	var path := _shot_path.get_basename() + "_%d.png" % int(round(t * 10.0))
	img.save_png(path)
	print("SCREENSHOT %s  speed %.0f km/h  pos %s" % [path, player.speed * 3.6, player.global_position.snapped(Vector3.ONE)])
	if _shots.is_empty():
		get_tree().quit()
