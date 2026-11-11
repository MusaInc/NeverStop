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
##   --at=<x,z>             spawn on the lane nearest this point (captures)

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
var contracts: Contracts
var hud: Hud
var touch: TouchDrive
var ui: CanvasLayer
var audio: AudioDirector
var fx: VehicleFx
var props: Destructibles
var jumps: Jumps
var speed_fx: SpeedFx
var repairs: RepairPickups
var kit: BattleKit
var menus: Node            # Menus (title, garage, records, settings, pause, results)
var car_id := "kestrel"
var last_result := {}
var _bust_t := -1.0
var _bot_t := 0.0
var _shots: Array = []
var _shot_path := ""
var _time := 0.0
var _quit_after := -1.0
var _resumed_frame := -1
var daily := {}
## Off in headless runs (no window, spurious focus events); tests turn it on.
var autopause := DisplayServer.get_name() != "headless"


func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		var kv := a.trim_prefix("--").split("=", true, 1)
		args[kv[0]] = kv[1] if kv.size() > 1 else "1"
	if OS.has_feature("web"):
		# The web test build takes the same options from the URL (?seed=3&debug=1).
		var q = JavaScriptBridge.eval("window.location.search", true)
		if q is String:
			for part in (q as String).trim_prefix("?").split("&", false):
				var kv2 := part.split("=", true, 1)
				args[kv2[0]] = kv2[1] if kv2.size() > 1 else "1"
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
	Prof.enabled = args.has("bench")
	if args.has("selftest"):
		# Packaged-build smoke test: a short autopilot chase at heat 3.
		args["play"] = "1"
		args["bot"] = "1"
		args["heat"] = "3"
		args["save"] = "user://selftest_save.json"
		SaveData.use_file(args["save"])

	atmosphere = Atmosphere.new()
	atmosphere.name = "Atmosphere"
	add_child(atmosphere)
	var t0 := Time.get_ticks_msec()
	layout = CityLayout.new().generate()
	Car.water_check = layout.is_water
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
	contracts = Contracts.new()
	contracts.name = "Contracts"
	add_child(contracts)
	ui = CanvasLayer.new()
	add_child(ui)
	var sfx := SpeedFx.new()
	ui.add_child(sfx)
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
	hud.contracts = contracts
	contracts.completed.connect(func(c):
		hud.contract_done(c)
		if audio:
			audio.event_chime(int(c["score"]) * 2)
		Settings.haptic(40, 0.5))
	sfx.player = player
	speed_fx = sfx
	hud.minimap.camera = camera
	hud.minimap.bake.call_deferred(layout)
	director.unit_wrecked.connect(func(u, _b):
		score.on_police_wrecked(u)
		_on_unit_wrecked(u))
	director.roadblock_escaped.connect(score.on_roadblock_escaped)
	director.busted.connect(_on_busted)
	director.spiked.connect(func(): camera.shake(0.4))
	civilians.reset_around(player.global_position)
	jumps = Jumps.new()
	jumps.name = "Jumps"
	add_child(jumps)
	jumps.build(net)
	print("Jumps: %d ramps" % jumps.spots.size())
	civilians.jumps = jumps
	props = Destructibles.new()
	props.name = "Destructibles"
	add_child(props)
	props.setup(world)
	print("Destructibles: %d breakable items" % props.count())
	fx = VehicleFx.new()
	fx.name = "Fx"
	add_child(fx)
	audio = AudioDirector.new()
	audio.name = "Audio"
	add_child(audio)
	audio.attach(self, player, director)
	score.event.connect(func(_l, pts, _c): if pts > 0: audio.event_chime(pts))
	repairs = RepairPickups.new()
	repairs.name = "Repairs"
	add_child(repairs)
	repairs.setup(net, player)
	repairs.collected.connect(_on_repaired)
	kit = BattleKit.new()
	kit.name = "BattleKit"
	add_child(kit)
	kit.fx = fx
	kit.audio = audio
	kit.setup(player)
	input.kit = kit
	touch.kit = kit
	hud.kit = kit
	hud.repairs = repairs
	kit.hit.connect(func(kind, _c):
		if score and state == State.PLAYING:
			score.award("MINED A COP" if kind == "mines" else "SPIKED A COP", 300.0 if kind == "mines" else 150.0))
	props.broke.connect(func(kind, at, by):
		if by == player or player.global_position.distance_to(at) < 60.0:
			audio.play_at("prop_hit", at, 2.0 if by == player else -2.0)
		if by == player:
			contracts.smashed += 1
			camera.shake(0.08 if kind in ["bin", "bollard", "sign_post"] else 0.18))
	var menus_script: Script = load("res://src/ui/menus.gd") if ResourceLoader.exists("res://src/ui/menus.gd") else null
	if menus_script:
		menus = menus_script.new()
		ui.add_child(menus)
		menus.setup(self)
	if not (args.has("gametest") or args.has("lineup") or args.has("bench") or args.has("selftest")):
		daily = Progression.daily_claim(SaveData, Time.get_date_string_from_system())
	if args.has("lineup"):
		start_run()
		var lu: Node = load("res://tools/lineup.gd").new()
		lu.game = self
		lu.ids = str(args["lineup"]).split(",")
		lu.out_dir = str(args.get("lineup-out", "/tmp"))
		add_child(lu)
		return
	if args.has("gametest"):
		var gt: Node = load("res://tests/game_tests.gd").new()
		gt.game = self
		add_child(gt)
		return
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
	if args.has("at"):  # --at=x,z[,yaw°]: exact spot for captures/tests
		var xs := str(args["at"]).split(",")
		var q := Vector3(float(xs[0]), 0.0, float(xs[1]))
		var hd := Vector3.ZERO
		if xs.size() > 2:
			var yaw := deg_to_rad(float(xs[2]))
			hd = Vector3(sin(yaw), 0.0, -cos(yaw))
		var n0 := net.nearest(q, hd, 60.0, -1, true)
		if not n0.is_empty():
			var d0 := net.lane_dir(n0["lane"], n0["s"])
			return Transform3D(Basis.looking_at(d0, Vector3.UP), net.lane_point(n0["lane"], n0["s"]) + Vector3.UP * 0.3)
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
	player_visual.enable_headlights(Settings.quality == Settings.Quality.HIGH)
	player.visual = player_visual
	player.place(spawn_point())
	input.car = player
	camera.set_target(player, true)
	player.impact.connect(_on_player_impact)
	player.part_lost.connect(_on_part_lost)
	player.splashed.connect(_on_player_splash)
	player.landed.connect(func(a, v):
		if score:
			score.on_landed(a, v)
		camera.shake(clampf(v / 25.0, 0.05, 0.5)))
	world.build_all_near(player.global_position, 420.0)
	if audio:
		audio.set_player(player)
	if kit:
		kit.setup(player)
	if repairs:
		repairs.player = player
	if director:
		director.player = player
		civilians.player = player
		score.player = player
		hud.player = player
		hud.minimap.player = player
		touch.car = player
		if speed_fx:
			speed_fx.player = player


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
	if args.has("nociv"):
		civilians.enabled = false
		for c in civilians.cars:
			civilians._park(c)
	director.start(int(args.get("heat", "1")))
	if args.has("nopolice"):
		director.active = false
	score.begin()
	contracts.begin(score, int(args["seed"]) if args.has("seed") else -1)
	repairs.begin(int(args["seed"]) if args.has("seed") else -1)
	kit.reset()
	hud.start_coach(not SaveData.data.get("tutorial_done", false) and bot == null and not args.has("notutorial"))
	_scenario(args.get("scenario", ""))
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


## Test / capture set-ups (--scenario=...):
##   ramp   at speed, 70 m before a kicker ramp, lined up with it
##   swarm  heat 8: the extreme pursuit (benchmarks)
func _scenario(name: String) -> void:
	match name:
		"ramp":
			if jumps.spots.is_empty():
				return
			var xf: Transform3D = jumps.spots[int(args.get("ramp", "0")) % jumps.spots.size()]
			var fwd := -xf.basis.z
			var at := xf.origin - fwd * 70.0
			at.y = layout.ground_y(at.x, at.z) + 0.4
			player.place(Transform3D(xf.basis, at), fwd * 32.0)
			camera.set_target(player, true)
			if bot:
				var line := PackedVector3Array()
				for k in 64:
					var q := at + fwd * (k * 3.0)
					q.y = layout.ground_y(q.x, q.z)
					line.append(q)
				bot.set_path(line)
				_bot_t = 6.0
			world.build_all_near(at, 300.0)
			civilians.reset_around(at)
		"swarm":
			director.start(8)
		"carbench":
			# N plain cars on lanes round the player, full throttle, no AI.
			var n := int(args.get("n", "10"))
			for i in n:
				var q := player.global_position + Vector3(rng.randf_range(-150, 150), 0, rng.randf_range(-150, 150))
				var nr := net.nearest(q, Vector3.ZERO, 60.0, -1, true)
				if nr.is_empty():
					continue
				var c := Car.new()
				c.setup(CarCatalog.police_spec("patrol"), "police")
				add_child(c)
				if args.has("vis"):
					var v := CarVisual.new()
					c.add_child(v)
					v.setup(c)
					v.set_siren(true)
				var d := net.lane_dir(nr["lane"], nr["s"])
				c.place(Transform3D(Basis.looking_at(d, Vector3.UP), (nr["pos"] as Vector3) + Vector3.UP * 0.4), d * 10.0)
				c.throttle = 0.6


func enter_menu() -> void:
	state = State.MENU
	director.clear()
	score.running = false
	contracts.stop()
	hud.visible = false
	touch.visible = false
	if audio:
		audio.menu_mode = true
	repairs.clear()
	kit.reset()
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
	if OS.has_feature("web"):
		_web_t = 0.0
		_publish_web(0.0)


func resume() -> void:
	if state != State.PAUSED:
		return
	_resumed_frame = Engine.get_process_frames()
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
	contracts.stop()
	last_result = score.summary()
	last_result["car"] = car_id
	last_result["contracts"] = contracts.done_count
	last_result["contract_cash"] = contracts.cash
	last_result["smashed"] = contracts.smashed
	last_result["currency"] = int(last_result["currency"]) + contracts.cash
	var xp_before := int(SaveData.data.get("xp", 0))
	last_result["records"] = SaveData.submit_run(last_result, car_id)
	SaveData.data["total_contracts"] = int(SaveData.data.get("total_contracts", 0)) + contracts.done_count
	last_result["xp_before"] = xp_before
	last_result["ranks"] = Progression.add_xp(SaveData, int(last_result["score"]))
	last_result["challenges"] = Progression.check(last_result, car_id, SaveData)
	state_changed.emit(state)


func _on_player_impact(strength: float, at: Vector3, n: Vector3, other: Object) -> void:
	var rammed := other is Car and _ram(strength, at, n, other as Car)
	if score:
		score.on_player_impact(strength, other, rammed)
	if strength > 14.0 and hud:
		hud.flash(UiStyle.RED, clampf(strength / 60.0, 0.1, 0.4))
	camera.shake(clampf(strength / 30.0, 0.1, 0.8))
	if player_visual:
		player_visual.dent(at, -n, clampf(strength / 60.0, 0.03, 0.25))
	if fx and strength > 4.0:
		fx.impact(at, n, strength, player.spec["paint"])
	Settings.haptic(int(clampf(strength * 4.0, 20.0, 160.0)), clampf(strength / 25.0, 0.3, 1.0))


## Ramming: when the player drives INTO another car (closing fast, us the
## faster one), the hit lands like a hammer – the victim is shoved and spun
## with a pop, we keep most of our speed, the game freezes for a beat
## (hit-stop), the lens punches in, a heavy layered crunch, the victim's
## paint and glass fly, and it scores (SLAM / SMASH) without breaking the
## chain. Returns true when it counted as our ram.
const RAM_MIN := 6.0           # closing speed (m/s) for a ram
var _ram_cd := {}              # victim instance id -> _time of last ram
var _stick_demo := false
var _tfx_start := 0            # hit-stop / slow-mo, in real msec
var _tfx_end := 0
var _tfx_min := 1.0
var _tfx_hold := 1.0           # share of the effect held at _tfx_min before easing back


func _ram(strength: float, at: Vector3, n: Vector3, oc: Car) -> bool:
	if state != State.PLAYING or oc.role == "player":
		return false
	var pv := player.vel_before()
	var to := oc.global_position - player.global_position
	to.y = 0.0
	if to.length() < 0.1:
		return false
	to = to.normalized()
	var closing := pv.dot(to) - oc.vel_before().dot(to)
	if closing < RAM_MIN or pv.length() < oc.vel_before().length() * 0.8:
		return false
	var id := oc.get_instance_id()
	if _time - float(_ram_cd.get(id, -10.0)) < 0.6:
		return true
	_ram_cd[id] = _time
	var k := clampf((closing - RAM_MIN) / 22.0, 0.0, 1.0)
	var weight := clampf(player.mass / maxf(oc.mass, 1.0), 0.6, 1.8) * float(player.spec.get("ram", 1.0))
	var cop := oc.role == "police"
	# Shove, pop and spin the victim (more for a T-bone than a rear-end).
	var side := absf(to.dot(oc.global_basis.x))
	var push := to * closing * (0.28 + 0.22 * k) * weight
	oc.linear_velocity += push + Vector3.UP * (1.2 + 3.2 * k) * clampf(weight, 0.7, 1.4)
	var spin_dir := signf(pv.cross(to).y + 0.001)
	oc.angular_velocity += Vector3(randf_range(-0.6, 0.6) * k, spin_dir * (1.0 + 2.6 * side) * (0.5 + k) * weight, randf_range(-1.2, 1.2) * k)
	# We barrel on: give back part of the speed the hit took.
	var lost := pv.length() - player.linear_velocity.length()
	if lost > 0.0:
		player.linear_velocity += pv.normalized() * lost * (0.35 + 0.25 * k) * clampf(weight, 0.6, 1.3)
	player.angular_velocity *= 0.6
	# Big hits rip a panel off the victim on the side we hit.
	if k > 0.35:
		var local := oc.global_transform.affine_inverse() * at
		var sz: Vector3 = oc.spec["size"]
		var hit_side := ("right" if local.x > 0.0 else "left") if absf(local.x) / sz.x > absf(local.z) / sz.z \
			else ("front" if local.z < 0.0 else "rear")
		for pn in Car.SIDE_PARTS[hit_side]:
			if oc.parts.get(pn, 0.0) > 0.0:
				oc._wear_part(pn, 0.5 + k, at, -n)
				break
	# Feel.
	var heavy := k > 0.25
	camera.shake(0.25 + 0.45 * k)
	camera.punch(-(3.0 + 7.0 * k))
	if heavy:
		_time_fx(0.06, 45.0 + 70.0 * k, 1.0)
	if fx:
		fx.impact(at, n, strength + 8.0 + 14.0 * k, oc.spec["paint"])
	if audio:
		# A low, heavy layer under the normal crash: weight.
		audio.play("crash_heavy_%d" % (randi() % 3), -3.0 + 4.0 * k, randf_range(0.66, 0.78))
		if heavy:
			audio.play("glass", -8.0 + 4.0 * k, randf_range(0.95, 1.15))
	Settings.haptic(int(60 + 120 * k), 0.6 + 0.4 * k)
	if score and score.running:
		if cop:
			score.award("SLAM" if k < 0.6 else "BIG SLAM", 150.0 + 450.0 * k)
		elif oc.role == "civilian":
			score.award("SMASH", 40.0 + 120.0 * k)
	return true


## A cop wrecked by contact with us: TAKEDOWN – a short slow-motion beat.
func _on_unit_wrecked(u: PoliceUnit) -> void:
	if state != State.PLAYING or u.car == null:
		return
	if director.time - u.hit_player_t > 1.5:
		return
	score.award("TAKEDOWN", 500.0)
	if hud:
		hud.flash(UiStyle.AMBER, 0.25)
	camera.shake(0.4)
	camera.punch(-9.0)
	_time_fx(0.3, 650.0, 0.35)
	Settings.haptic(140, 1.0)


## Hit-stop / slow-motion: drop the time scale to `scale` for `ms` of real
## time (held for `hold` of it, then easing back). Off with Reduce motion and
## in headless runs (tests measure simulated time).
func _time_fx(scale: float, ms: float, hold: float) -> void:
	if Settings.reduce_motion or DisplayServer.get_name() == "headless":
		return
	var now := Time.get_ticks_msec()
	if now < _tfx_end and scale >= _tfx_min:
		return  # a deeper effect is already running
	_tfx_start = now
	_tfx_end = now + int(ms)
	_tfx_min = scale
	_tfx_hold = hold
	Engine.time_scale = scale


func _update_time_fx() -> void:
	if _tfx_end == 0:
		return
	var now := Time.get_ticks_msec()
	if state != State.PLAYING:
		_tfx_end = 0  # busted / menu own the time scale now
		return
	if now >= _tfx_end:
		Engine.time_scale = 1.0
		_tfx_end = 0
		_tfx_min = 1.0
		return
	var t := float(now - _tfx_start) / float(maxi(_tfx_end - _tfx_start, 1))
	var e := 0.0 if t < _tfx_hold else smoothstep(0.0, 1.0, (t - _tfx_hold) / maxf(1.0 - _tfx_hold, 0.001))
	Engine.time_scale = lerpf(_tfx_min, 1.0, e)


const PART_NAMES := {"bumper_f": "FRONT BUMPER", "bumper_r": "REAR BUMPER", "hood": "BONNET", "boot": "BOOT LID",
	"door_l": "LEFT DOOR", "door_r": "RIGHT DOOR", "plate_f": "BONNET PLATE", "plate_r": "REAR PLATE",
	"plate_l": "LEFT PLATE", "plate_rt": "RIGHT PLATE"}


func _on_part_lost(part: String, _at: Vector3, _n: Vector3) -> void:
	if state != State.PLAYING:
		return
	if hud:
		hud.part_gone(PART_NAMES.get(part, part.to_upper()))
	if audio:
		audio.play("panel_off", -1.0, randf_range(0.9, 1.1))
	camera.shake(0.25)


func _on_repaired(_at: Vector3) -> void:
	if state != State.PLAYING:
		return
	score.award("REPAIRED", 250.0, false)
	if audio:
		audio.play("repair", 0.0)
	if hud:
		hud.flash(UiStyle.GREEN, 0.35)
	Settings.haptic(60, 0.6)


func _physics_process(dt: float) -> void:
	Prof.begin("game")
	_time += dt
	RenderingServer.global_shader_parameter_set(&"player_pos", player.global_position)
	if bot:
		_drive_bot(dt)
	if fx:
		var list: Array = [player]
		for u in director.units:
			if u.car:
				list.append(u.car)
		list.append_array(civilians.active_cars())
		fx.cars = list
		props.cars = list
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
		elif player.water_t > 1.4:
			# Into the river / the sea: back onto the nearest dry road.
			recover_player()
			if hud and state == State.PLAYING:
				hud.notice("FISHED OUT OF THE WATER")
	if state == State.PLAYING and Input.is_action_just_pressed("pause") and Engine.get_process_frames() - _resumed_frame > 1:
		pause()
	if state == State.MENU and bot and player.disabled:
		quit_to_menu()
	if _bust_t >= 0.0:
		_bust_t += dt / maxf(Engine.time_scale, 0.01)
		if _bust_t > 3.2 and Engine.time_scale < 1.0:
			Engine.time_scale = 1.0
			hud.visible = false
			if menus:
				menus.show_results(last_result)
	Prof.end("game")


## Phone call, home swipe, notification centre, another window: pause the
## chase instead of letting the police bust a car nobody is driving.
func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_PAUSED or what == NOTIFICATION_APPLICATION_FOCUS_OUT \
			or what == NOTIFICATION_WM_WINDOW_FOCUS_OUT:
		if state == State.PLAYING and bot == null and autopause:
			pause()
	# iOS can kill a backgrounded app without warning: flush the profile.
	if what == NOTIFICATION_APPLICATION_PAUSED or what == NOTIFICATION_WM_CLOSE_REQUEST:
		SaveData.save()


func _on_player_splash(at: Vector3, sp: float) -> void:
	if fx:
		fx.splash(Vector3(at.x, Car.WATER_Y, at.z), sp)
	if audio:
		audio.play("crash_heavy_%d" % (randi() % 3), -6.0, 0.55)
	camera.shake(0.3)
	Settings.haptic(80, 0.7)


## Puts the car back on the nearest lane facing along it (context recovery).
## Never onto a lane over water (a dry road the car can actually drive).
func recover_player() -> void:
	var near := net.nearest(player.global_position, -player.global_basis.z, 60.0, -1, true)
	if not near.is_empty() and layout.is_water(near["pos"]) and (near["pos"] as Vector3).y < Car.WATER_Y + 1.0:
		near = {}
	if near.is_empty():
		near = net.nearest(player.global_position, Vector3.ZERO, 300.0)
	if near.is_empty():
		return
	var d := net.lane_dir(near["lane"], near["s"])
	player.place(Transform3D(Basis.looking_at(d, Vector3.UP), (near["pos"] as Vector3) + Vector3.UP * 0.4), d * 8.0)
	camera.set_target(player, true)


func _drive_bot(dt: float) -> void:
	_bot_t -= dt
	if _bot_t <= 0.0 or (bot.remaining() < 15 and _bot_t < 5.0):
		_bot_t = 1.5
		var near := net.nearest(player.global_position, -player.global_basis.z, 40.0)
		if not near.is_empty():
			# Evade like a player would: of a few onward routes, take the one
			# that ends furthest from the police and stays straightest.
			var cops: Array = []
			for u in director.units:
				if u.alive():
					cops.append(u.world_pos())
			var best := PackedVector3Array()
			var best_s := -INF
			for k in 5:
				var path := net.wander(near["lane"], near["s"], 320.0, rng, 0.45)
				if path.size() < 4:
					continue
				var end := path[-1]
				var sc := 0.0
				for c in cops:
					sc += minf((c as Vector3).distance_to(end), 400.0) * 0.01
					sc -= 4.0 if (c as Vector3).distance_to(path[mini(12, path.size() - 1)]) < 25.0 else 0.0
				var turn := 0.0
				for i in range(2, path.size() - 2, 4):
					turn += absf((path[i] - path[i - 2]).normalized().angle_to(path[i + 2] - path[i]))
				sc -= turn * 0.6
				if sc > best_s:
					best_s = sc
					best = path
			if not best.is_empty():
				bot.set_path(best)
	bot.skill = 0.95 if state == State.PLAYING else 0.88
	bot.update(dt, get_world_3d().direct_space_state)


var _selftest_start := Vector3.INF
var _bench: Array = []          # [process ms, physics ms, physical cars, units]
var _bench_wall := 0
var _web_t := 0.0


## Web test hook: publishes the game state as window.__ns (debug builds or
## ?debug=1 only) so tools/web/web_test.mjs can drive the real build.
func _publish_web(dt: float) -> void:
	_web_t -= dt
	if _web_t > 0.0:
		return
	_web_t = 0.25
	var st := {
		"state": ["menu", "playing", "paused", "busted", "garage"][state],
		"screen": menus.current if menus else "",
		"speed": player.speed * 3.6, "steer": player.steer, "brake": player.brake, "throttle": player.throttle, "handbrake": player.handbrake,
		"heat": director.heat, "police": director.alive_count(), "cars": director.physical_count(),
		"score": score.score, "time": score.time, "bust": director.bust, "touch": touch.visible,
		"fps": Engine.get_frames_per_second(),
	}
	if menus and menus.has_method("button_centres"):
		st["buttons"] = menus.button_centres()
	st["touch_buttons"] = touch.button_centres()
	JavaScriptBridge.eval("window.__ns = %s;" % JSON.stringify(st), true)


func _process(_dt: float) -> void:
	_update_time_fx()
	if args.has("stick") and state == State.PLAYING and touch.visible and _time > 1.0 and not _stick_demo:
		# Captures: hold the smart stick at an offset (--stick=dx,dy in px).
		_stick_demo = true
		var o := str(args["stick"]).split(",")
		var h := touch.stick_home()
		var to_win := get_viewport().get_final_transform()
		var ev := InputEventScreenTouch.new()
		ev.index = 7
		ev.position = to_win * h
		ev.pressed = true
		Input.parse_input_event(ev)
		var dr := InputEventScreenDrag.new()
		dr.index = 7
		dr.position = to_win * (h + Vector2(float(o[0]), float(o[1] if o.size() > 1 else "0")))
		Input.parse_input_event(dr)
	if OS.has_feature("web") and (OS.is_debug_build() or args.has("debug")):
		_publish_web(_dt)
	if args.has("selftest"):
		if _selftest_start == Vector3.INF and _time > 0.5:
			_selftest_start = player.global_position
		if _time > 12.0:
			var moved := player.global_position.distance_to(_selftest_start)
			var ok := moved > 40.0 and director.alive_count() > 0 and civilians.active_cars().size() > 0
			print("SELFTEST moved %.0f m, %d police, %d civilians, score %d: %s" % [moved, director.alive_count(),
				civilians.active_cars().size(), score.score, "OK" if ok else "FAIL"])
			get_tree().quit(0 if ok else 1)
			return
	if args.has("bench"):
		# Wall-clock cost of each whole frame (headless --fixed-fps runs flat
		# out, so this is the CPU time of script + physics + audio + UI).
		var now := Time.get_ticks_usec()
		if _bench_wall > 0 and _time > 3.0:
			_bench.append([(now - _bench_wall) / 1000.0, Prof.frame_ms(), director.physical_count(), director.alive_count()])
		_bench_wall = now
	if _quit_after > 0.0 and _time >= _quit_after:
		if args.has("bench"):
			_bench_report()
		get_tree().quit()
	if not _shots.is_empty() and _time >= float(_shots[0]):
		var t: float = _shots.pop_front()
		_capture(t)


## CPU cost of the simulation (this machine): averages, 95th percentile and
## worst frame of script/physics time, with the pursuit size it handled.
func _bench_report() -> void:
	if _bench.is_empty():
		return
	for col in [0, 1]:
		var v: Array = _bench.map(func(r): return r[col])
		v.sort()
		var avg: float = v.reduce(func(a, b): return a + b, 0.0) / v.size()
		print("BENCH %s ms: avg %.2f  p95 %.2f  p99 %.2f  max %.2f" % [["frame (wall)", "scripts (profiled)"][col], avg,
			v[int(v.size() * 0.95)], v[int(v.size() * 0.99)], v[-1]])
	var cars: Array = _bench.map(func(r): return r[2])
	var units: Array = _bench.map(func(r): return r[3])
	print("BENCH physics3d: active %d  pairs %d  islands %d" % [Performance.get_monitor(Performance.PHYSICS_3D_ACTIVE_OBJECTS),
		Performance.get_monitor(Performance.PHYSICS_3D_COLLISION_PAIRS), Performance.get_monitor(Performance.PHYSICS_3D_ISLAND_COUNT)])
	print("BENCH pursuit: physical cars max %d, units max %d, heat %d, frames %d, wrecked %d" % [cars.max(), units.max(),
		director.heat, _bench.size(), director.stats["wrecked"]])
	Prof.report(Engine.get_physics_frames())


func _capture(t: float) -> void:
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	var path := _shot_path.get_basename() + "_%d.png" % int(round(t * 10.0))
	img.save_png(path)
	print("SCREENSHOT %s  speed %.0f km/h  pos %s" % [path, player.speed * 3.6, player.global_position.snapped(Vector3.ONE)])
	if _shots.is_empty():
		get_tree().quit()
