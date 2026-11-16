class_name LcsSession
extends Node3D
## ENet prototype: clients send bounded controls, never transforms/damage/kill claims.
## Channel 0 reliable lobby/events, 1 unreliable inputs, 2 unreliable snapshots.
const PORT := 27970
const PROTOCOL := 1
const INPUT_HZ := 20.0
const SNAPSHOT_HZ := 10.0
const RECONNECT_SECONDS := 25.0
var rules := LcsRules.new()
var storm := LcsStorm.new()
var sites := LcsRoadSites.new()
var cars := {}
var brains := {}
var peers := {} # peer -> stable competitor id
var tokens := {} # opaque reconnect capability -> competitor id (never broadcast)
var disconnected := {} # competitor id -> deadline in monotonic milliseconds
var controls := {} # id -> last sequence/arrival
var samples := {} # client id -> [previous, latest, local arrival ms]
var roster := {}
var circle := {}
var status := "waiting"
var clock := 0.0
var winner := 0
var local_id := 0
var spectating := 0
var token := ""
var last_event := 0
var next_id := 1
var tick := 0
var snapshot_tick := -1
var input_seq := 0
var pending_inputs := {}
var prediction_age := 0.0
var connected := false
var dedicated := false
var target_size := 10
var fill_bots := true
var queue_seconds := 20.0
var queue_elapsed := 0.0
var args := {}
var rng := RandomNumberGenerator.new()
var world: CityWorld
var layout: CityLayout
var net: RoadNet
var camera: ChaseCamera
var drive: DriveInput
var touch: TouchDrive
var hud: Control
var fx: VehicleFx
var audio: AudioDirector
var props: LcsProps
var broken_props := PackedVector3Array()
var storm_mesh: MeshInstance3D
var route_job: RoadNet.FieldJob
var route_field: RoadNet.Field
var route_timer := 0.0
var send_timer := 0.0
var input_timer := 0.0
var metadata_timer := 0.0
var announced_state := "waiting"
var roster_dirty := false
var last_emit := 0
var elapsed_wall := 0.0
var bench_frames: Array = []
var bench_start := 0
var gpu_samples: Array = []
var draw_call_samples: Array = []
var bytes_sent := 0
var snapshot_messages := 0
var snapshot_round := 0
var replication_cursor := 0
var peer_rounds := {}
var cached_tick := -1
var cached_rows := {}
var cached_positions := {}
var max_snapshot_bytes := 0
var last_reconnect := 0
var reconnect_started := 0
var connecting := false
var endpoint := "127.0.0.1"
var endpoint_port := PORT
var player_label := "Driver"
var player_class := "sports"
var ready_world := false
var spawn_positions := {}
var lods := {}
var lod_materials := {}
var ui_message := "Host a room or join a server"

func _ready() -> void:
	process_physics_priority = 20 # after Car collision processing
	var loader: LoadingScreen = null
	if DisplayServer.get_name() != "headless":
		loader = LoadingScreen.new()
		add_child(loader)
		await loader.step(0.05, "Preparing LAST CAR STANDING")
	for arg in OS.get_cmdline_user_args():
		var kv := arg.trim_prefix("--").split("=", true, 1)
		args[kv[0]] = kv[1] if kv.size() > 1 else "1"
	dedicated = args.has("lcs-server")
	target_size = clampi(int(args.get("players", 10)), 2, 100)
	fill_bots = not args.has("no-bots")
	queue_seconds = clampf(float(args.get("queue-seconds", 20)), 0.0, 120.0)
	rng.seed = 47 # world is fixed; match seed is independent
	Settings.apply()
	layout = LcsRoadSites.city_layout()
	Car.water_check = layout.is_water
	world = CityWorld.new()
	world.competitive = true
	world.layout = layout
	add_child(world)
	if loader:
		await loader.step(0.7, "Checking connected roads and bridge finales")
	net = RoadNet.new().build(layout)
	sites.build(net, layout)
	print("LCS validated road sites: %d / categories %s" % [sites.sites.size(), sites.categories.keys().map(func(k): return "%s:%d" % [k, sites.categories[k].size()])])
	rng.seed = int(args.get("match-seed", Time.get_unix_time_from_system()))
	if not dedicated:
		var atmosphere := Atmosphere.new()
		add_child(atmosphere)
		atmosphere.configure({"time": "16", "weather": "clear"}, world)
		camera = ChaseCamera.new()
		add_child(camera)
		world.set_viewer(camera)
		drive = DriveInput.new()
		add_child(drive)
		var canvas := CanvasLayer.new()
		add_child(canvas)
		touch = TouchDrive.new()
		canvas.add_child(touch)
		touch.input = drive
		touch.visible = DisplayServer.is_touchscreen_available() or args.has("touch")
		touch.pause_pressed.connect(func(): hud.toggle_menu())
		hud = load("res://src/lcs/hud.gd").new()
		hud.session = self
		canvas.add_child(hud)
		fx = VehicleFx.new()
		add_child(fx)
		if DisplayServer.get_name() != "headless":
			audio = load("res://src/lcs/audio.gd").new()
			audio.set("session", self)
			add_child(audio)
		_build_storm_visual()
		RenderingServer.viewport_set_measure_render_time(get_viewport().get_viewport_rid(), true)
		var governor := FrameGovernor.new()
		add_child(governor)
	props = LcsProps.new()
	add_child(props)
	props.setup(world)
	props.broke.connect(_prop_broken)
	multiplayer.peer_disconnected.connect(_peer_left)
	multiplayer.connected_to_server.connect(_client_connected)
	multiplayer.connection_failed.connect(_lost_connection)
	multiplayer.server_disconnected.connect(_lost_connection)
	ready_world = true
	if loader:
		loader.finish()
	if dedicated or args.has("host"):
		host(int(args.get("port", PORT)))
	elif args.has("join"):
		join_server(str(args.join), int(args.get("port", PORT)), str(args.get("name", "Driver")), str(args.get("class", "sports")))
	bench_start = Time.get_ticks_usec()

func is_host() -> bool:
	return connected and multiplayer.is_server()

func host(port := PORT) -> void:
	if connected or connecting:
		return
	var transport := ENetMultiplayerPeer.new()
	var err := transport.create_server(port, 100, 3)
	if err != OK:
		ui_message = "Could not open UDP port %d (%s)" % [port, error_string(err)]
		return
	# Authoritative topology: clients never address or discover each other.
	(multiplayer as SceneMultiplayer).server_relay = false
	multiplayer.multiplayer_peer = transport
	connected = true
	ui_message = "ROOM OPEN · UDP %d" % port
	if not dedicated:
		local_id = _admit(1, player_label, player_class)
	print("LCS listening UDP %d, target %d, bots %s" % [port, target_size, fill_bots])

func join_server(address: String, port: int, label: String, kind: String) -> void:
	if connected or connecting:
		return
	endpoint = address.strip_edges()
	endpoint_port = clampi(port, 1, 65535)
	player_label = label.strip_edges().left(20)
	player_class = kind if kind in LcsRules.CLASSES else "sports"
	var transport := ENetMultiplayerPeer.new()
	var err := transport.create_client(endpoint, endpoint_port, 3)
	if err != OK:
		ui_message = "Connection failed: " + error_string(err)
		return
	multiplayer.multiplayer_peer = transport
	connecting = true
	last_reconnect = Time.get_ticks_msec()
	ui_message = "Connecting to %s:%d…" % [endpoint, endpoint_port]

func _client_connected() -> void:
	connected = true
	connecting = false
	register.rpc_id(1, PROTOCOL, player_label, player_class, token)

func _lost_connection() -> void:
	connected = false
	connecting = false
	if token != "" and reconnect_started == 0:
		reconnect_started = Time.get_ticks_msec()
	ui_message = "Connection lost · reconnecting to your vehicle…" if token != "" else "Could not connect to server"
	if drive:
		drive.enabled = false
	if cars.has(local_id):
		cars[local_id].freeze = true

@rpc("any_peer", "call_remote", "reliable", 0)
func register(version: int, label: String, kind: String, resume_token: String) -> void:
	if not is_host():
		return
	var peer := multiplayer.get_remote_sender_id()
	if peers.has(peer):
		return
	if version != PROTOCOL or kind not in LcsRules.CLASSES or label.length() > 80 or resume_token.length() > 64:
		_refuse(peer, "Incompatible client")
		return
	if resume_token != "":
		if not tokens.has(resume_token):
			_refuse(peer, "Reconnect token expired")
			return
		var id: int = tokens[resume_token]
		if not disconnected.has(id) or Time.get_ticks_msec() > int(disconnected[id]):
			_refuse(peer, "Vehicle is already connected or reconnect grace expired")
			return
		peers[peer] = id
		disconnected.erase(id)
		controls.erase(id)
		accepted.rpc_id(peer, id, resume_token)
		if not broken_props.is_empty():
			props_removed.rpc_id(peer, broken_props)
		_broadcast_roster()
		return
	if rules.state != "waiting" or rules.players.size() >= target_size:
		_refuse(peer, "Match already started or room full")
		return
	var id := _admit(peer, label, kind)
	if id == 0:
		_refuse(peer, "Room full")

func _refuse(peer: int, reason: String) -> void:
	rejected.rpc_id(peer, reason)
	# Client closes after receiving the reliable rejection.

@rpc("authority", "call_remote", "reliable", 0)
func rejected(reason: String) -> void:
	token = ""
	connected = false
	connecting = false
	ui_message = reason
	multiplayer.multiplayer_peer.close()

func _admit(peer: int, label: String, kind: String) -> int:
	var id := next_id
	if not rules.join(id, label, kind):
		return 0
	next_id += 1
	peers[peer] = id
	var capability := Crypto.new().generate_random_bytes(24).hex_encode()
	tokens[capability] = id
	if peer != 1:
		accepted.rpc_id(peer, id, capability)
	roster_dirty = true
	return id

@rpc("authority", "call_remote", "reliable", 0)
func accepted(id: int, capability: String) -> void:
	local_id = id
	token = capability
	input_seq = 0
	pending_inputs.clear()
	reconnect_started = 0
	ui_message = "Joined · waiting for competitors"
	print("LCS accepted competitor %d" % id)

func _peer_left(peer: int) -> void:
	if not is_host() or not peers.has(peer):
		return
	var id: int = peers[peer]
	peers.erase(peer)
	peer_rounds.erase(peer)
	if rules.state == "waiting":
		rules.players.erase(id)
		for key in tokens.keys():
			if tokens[key] == id:
				tokens.erase(key)
	else:
		disconnected[id] = Time.get_ticks_msec() + int(RECONNECT_SECONDS * 1000.0)
	if cars.has(id):
		_stop(cars[id])
	_broadcast_roster()

func _broadcast_roster() -> void:
	roster = rules.players.duplicate(true)
	for peer in peers:
		if _can_send(peer):
			match_info.rpc_id(peer, roster, rules.state, rules.elapsed, rules.winner, target_size, queue_seconds - queue_elapsed)

func _broadcast_status() -> void:
	var stats := PackedInt32Array()
	for id in rules.players:
		var entry: Dictionary = rules.players[id]
		stats.append_array([id, int(entry.alive), int(entry.kills)])
	roster = rules.players.duplicate(true)
	for peer in peers:
		if _can_send(peer):
			match_status.rpc_id(peer, stats, rules.state, rules.elapsed, rules.winner, queue_seconds - queue_elapsed)

@rpc("authority", "call_remote", "reliable", 0)
func match_status(stats: PackedInt32Array, match_state: String, at: float, won: int, queue_left: float) -> void:
	if status == "finished" and match_state != "finished":
		return
	for i in range(0, stats.size(), 3):
		if roster.has(stats[i]):
			roster[stats[i]].alive = stats[i + 1] != 0
			roster[stats[i]].kills = stats[i + 2]
	status = match_state
	clock = at
	winner = won
	queue_elapsed = queue_seconds - queue_left

@rpc("authority", "call_remote", "reliable", 0)
func match_info(data: Dictionary, match_state: String, at: float, won: int, capacity: int, queue_left: float) -> void:
	if status == "finished" and match_state != "finished":
		return
	roster = data
	status = match_state
	clock = at
	winner = won
	if match_state == "finished":
		# Terminal health must be reliable even for a distant/spectated winner.
		for id in cars:
			if roster.has(id):
				cars[id].health = float(roster[id].hp) / 100.0
				cars[id].disabled = not roster[id].alive
				cars[id].freeze = true
		if drive:
			drive.enabled = false
	target_size = capacity
	queue_elapsed = queue_seconds - queue_left

func begin_match() -> bool:
	if not is_host() or rules.state != "waiting":
		return false
	var required := target_size if fill_bots else rules.players.size()
	if required < 2 or sites.sites.size() < required:
		ui_message = "Need two competitors and enough clear road spawns"
		return false
	while rules.players.size() < required:
		var id := next_id
		next_id += 1
		rules.join(id, "BOT %02d" % id, LcsRules.CLASSES[id % 4], true)
	var positions := sites.spawns(rules.players.size(), rng)
	var final_pos := sites.final_site(rng)
	if not final_pos.is_finite():
		ui_message = "No reachable final circle available"
		return false
	storm.final_center = Vector2(final_pos.x, final_pos.z)
	var index := 0
	for id in rules.players:
		_spawn(id, positions[index], true)
		index += 1
	route_job = RoadNet.FieldJob.new(net)
	route_job.start(final_pos)
	rules.start()
	_broadcast_roster()
	return true

func _spawn(id: int, xf: Transform3D, authority: bool) -> LcsCompetitor:
	var car := LcsCompetitor.new()
	car.competitor_id = id
	car.authoritative = authority
	var entry: Dictionary = rules.players[id] if authority else roster[id]
	car.setup(LcsRules.vehicle(entry["class"]), "competitor")
	car.immortal = false
	car.freeze = true
	if not authority:
		car.collision_layer = 0
		car.collision_mask = 1 | (1 << 3) | (1 << 7) # only local prediction touches static geometry
	add_child(car)
	car.place(xf)
	cars[id] = car
	spawn_positions[id] = xf.origin
	if authority:
		car.impact.connect(func(strength, at, normal, other): _impact(id, strength, at, normal, other))
		if entry.bot:
			brains[id] = AIDriver.new(car)
	if not dedicated and (id == local_id or xf.origin.distance_to(camera.global_position) < 350.0):
		_attach_visual(car)
	if id == local_id and not dedicated:
		drive.car = car
		touch.car = car
		camera.set_target(car)
		if audio:
			audio.set_player(car)
	return car

func _attach_visual(car: LcsCompetitor) -> void:
	if car.visual:
		return
	var visual := CarVisual.new()
	car.add_child(visual)
	visual.setup(car)
	car.visual = visual
	for part in car.parts:
		if car.parts[part] <= 0:
			visual.detach(part, car.global_position, Vector3.UP)

func _impact(id: int, strength: float, at: Vector3, normal: Vector3, other: Object) -> void:
	if rules.state != "active":
		return
	if other is LcsCompetitor and strength > 2.0:
		rules.hit(id, other.competitor_id)
	if not dedicated:
		_present_impact(id, strength, at, normal)
	# Send local deformation only to interested clients; no global hit-stop in online play.
	for peer in peers:
		if not _can_send(peer):
			continue
		var observer: int = peers[peer]
		if rules.players.has(observer) and not rules.players[observer].alive:
			observer = int(controls.get(observer, {}).get("watch", observer))
		if cars.has(observer) and cars[observer].global_position.distance_squared_to(at) < 300.0 * 300.0:
			impact_event.rpc_id(peer, id, strength, at, normal)

@rpc("authority", "call_remote", "unreliable", 2)
func impact_event(id: int, strength: float, at: Vector3, normal: Vector3) -> void:
	_present_impact(id, strength, at, normal)

func _prop_broken(_kind: String, at: Vector3, _by: Car) -> void:
	if not is_host():
		return
	broken_props.append(at)
	for peer in peers:
		if _can_send(peer):
			props_removed.rpc_id(peer, PackedVector3Array([at]))

@rpc("authority", "call_remote", "reliable", 0)
func props_removed(positions: PackedVector3Array) -> void:
	for at in positions:
		var nearby: Car = null
		if camera and camera.target and camera.target.global_position.distance_squared_to(at) < 100.0 * 100.0:
			nearby = camera.target
		props.apply_remote(at, nearby)

func _present_impact(id: int, strength: float, at: Vector3, normal: Vector3) -> void:
	if not cars.has(id):
		return
	if camera and camera.global_position.distance_squared_to(at) > 300.0 * 300.0:
		return
	var car: Car = cars[id]
	if car.visual:
		car.visual.dent(at, -normal, clampf(strength / 60.0, 0.03, 0.25))
	if fx:
		fx.impact(at, normal, strength, car.spec.paint)
	if audio:
		if id == local_id and not is_host():
			audio._on_player_impact(strength, at, normal, null)
		elif id != local_id and strength > 6.0:
			audio.play_at("crash_heavy_%d" % (randi() % 3), at, -3.0)
	if camera and id == local_id:
		camera.shake(clampf(strength / 30.0, 0.05, 0.7))
		camera.punch(-minf(strength * 0.2, 7.0))
		Settings.haptic(int(minf(strength * 4.0, 120.0)), 0.6)

@rpc("any_peer", "call_remote", "unreliable_ordered", 1)
func submit_input(sequence: int, throttle: float, brake: float, steer: float, handbrake: bool, nitro: bool, watch: int) -> void:
	if not is_host():
		return
	var peer := multiplayer.get_remote_sender_id()
	if not peers.has(peer):
		return
	var id: int = peers[peer]
	if not cars.has(id) or not is_finite(throttle) or not is_finite(brake) or not is_finite(steer):
		return
	var previous: Dictionary = controls.get(id, {"seq": -1, "at": -1000})
	var now := Time.get_ticks_msec()
	if sequence <= int(previous.seq) or sequence > int(previous.seq) + 10000 or now - int(previous.at) < 20:
		return
	controls[id] = {"seq": sequence, "at": now, "watch": watch if rules.players.has(watch) and rules.players[watch].alive else id}
	var c: Car = cars[id]
	if rules.state != "active" or not rules.players[id].alive:
		_stop(c)
		return
	c.throttle = clampf(throttle, 0, 1)
	c.brake = clampf(brake, 0, 1)
	c.steer = clampf(steer, -1, 1)
	c.handbrake = handbrake
	c.nitro = nitro

func _stop(c: Car) -> void:
	c.throttle = 0.0
	c.brake = 1.0
	c.steer = 0.0
	c.nitro = false
	c.handbrake = false

func _physics_process(dt: float) -> void:
	if not ready_world:
		return
	if is_host():
		_server_tick(dt)
	elif connected:
		_client_tick(dt)
	elif token != "" and reconnect_started > 0 and Time.get_ticks_msec() - reconnect_started > int(RECONNECT_SECONDS * 1000):
		token = ""
		connecting = false
		ui_message = "Reconnect grace expired · return to the room menu"
	elif token != "" and not connecting and Time.get_ticks_msec() - last_reconnect > 3000:
		join_server(endpoint, endpoint_port, player_label, player_class)
	if camera and camera.target:
		RenderingServer.global_shader_parameter_set(&"player_pos", camera.target.global_position)
		if fx:
			fx.cars = cars.values().filter(func(c): return c.visual != null)


func _server_tick(dt: float) -> void:
	tick += 1
	props.cars = cars.values()
	if rules.state == "waiting":
		if not rules.players.is_empty() or args.has("bench"):
			queue_elapsed += dt
		if rules.players.size() >= target_size or queue_elapsed >= queue_seconds:
			begin_match()
	rules.advance(dt)
	circle = storm.sample(rules.elapsed if rules.state == "active" or rules.state == "finished" else 0.0)
	if rules.state == "active":
		# First collect all physical losses, then apply storm, then rewards/finish.
		rules.begin_damage_batch()
		var losses := {}
		for id in cars:
			if rules.players[id].alive:
				losses[id] = maxf(0.0, float(rules.players[id].hp) - cars[id].health * 100.0)
		for id in losses:
			rules.damage(id, losses[id])
		for id in cars:
			var car: Car = cars[id]
			if rules.players[id].alive:
				if LcsStorm.outside(car.global_position, circle):
					rules.damage(id, float(circle.dps) * dt, "storm")
				if car.water_t > 2.0 or car.global_position.y < -30:
					rules.damage(id, 100.0, "water")
		for id in disconnected.keys():
			if Time.get_ticks_msec() >= int(disconnected[id]):
				rules.eliminate(id, "disconnect")
				disconnected.erase(id)
		rules.end_damage_batch()
		for id in cars:
			var car: Car = cars[id]
			var entry: Dictionary = rules.players[id]
			car.health = float(entry.hp) / 100.0
			car.disabled = not entry.alive
			if not entry.alive:
				_stop(car)
			elif car.upside_time > 3.0:
				# Right in place; never teleport across a storm or heal on recovery.
				car.place(Transform3D(Basis(Vector3.UP, car.rotation.y), car.global_position + Vector3.UP * 0.4))
		rules.complete()
		_update_bots(dt)
	for id in cars:
		cars[id].freeze = rules.state != "active"
		if not brains.has(id) and id != local_id and Time.get_ticks_msec() - int(controls.get(id, {}).get("at", 0)) > 500:
			_stop(cars[id])
	if drive:
		drive.enabled = rules.state == "active" and rules.players.has(local_id) and rules.players[local_id].alive
	_emit_events()
	status = rules.state
	clock = rules.elapsed
	winner = rules.winner
	send_timer += dt
	metadata_timer += dt
	# Stagger peers over physics frames instead of a 100-client burst at 10 Hz.
	_send_snapshots()
	if announced_state != rules.state or (roster_dirty and metadata_timer >= 0.2):
		metadata_timer = 0.0
		announced_state = rules.state
		roster_dirty = false
		_broadcast_roster()
	elif metadata_timer >= 1.0:
		metadata_timer = 0.0
		_broadcast_status()

func _update_bots(dt: float) -> void:
	if route_job and not route_job.done:
		if route_job.step(800):
			route_field = route_job.field
	var space := get_world_3d().direct_space_state
	for id in brains:
		var brain: AIDriver = brains[id]
		var car: Car = cars[id]
		if not rules.players[id].alive:
			continue
		# One route decision per bot per second, spread over sixty ticks.
		if (tick + int(id) * 7) % 60 == 0:
			var nearest: Car = null
			var dist := 80.0 * 80.0
			for other in cars:
				if other == id or not rules.players[other].alive:
					continue
				var d := car.global_position.distance_squared_to(cars[other].global_position)
				if d < dist:
					dist = d
					nearest = cars[other]
			brain.direct_target = Vector3.INF
			brain.ram = false
			if nearest and not LcsStorm.outside(car.global_position, circle):
				var query := PhysicsRayQueryParameters3D.create(car.global_position + Vector3.UP, nearest.global_position + Vector3.UP, 1)
				if space.intersect_ray(query).is_empty():
					brain.direct_target = nearest.global_position
					brain.direct_vel = nearest.linear_velocity
					brain.ram = true
			if not brain.ram:
				var near := net.nearest(car.global_position, -car.global_basis.z, 65.0)
				if not near.is_empty():
					if route_field:
						brain.set_path(net.route(route_field, near.lane, near.s, 280.0))
					else:
						brain.set_path(net.wander(near.lane, near.s, 200.0, rng))
		brain.update(dt, space)

func _emit_events() -> void:
	while last_emit < rules.events.size():
		var event: Dictionary = rules.events[last_emit]
		last_emit += 1
		if hud:
			hud.elimination(event)
		_elimination_audio(event)
		for peer in peers:
			if _can_send(peer):
				elimination_event.rpc_id(peer, event)

@rpc("authority", "call_remote", "reliable", 0)
func elimination_event(event: Dictionary) -> void:
	if int(event.seq) <= last_event:
		return
	last_event = event.seq
	if hud:
		hud.elimination(event)
	_elimination_audio(event)

func _elimination_audio(event: Dictionary) -> void:
	if not audio:
		return
	if int(event.killer) == local_id:
		audio.event_chime(800)
	elif int(event.victim) == local_id:
		audio.play("busted", -3.0)

func _cache_snapshot_rows() -> void:
	if cached_tick == tick:
		return
	cached_tick = tick
	cached_rows.clear()
	cached_positions.clear()
	for id in cars:
		var car: Car = cars[id]
		var p := car.global_position
		var q := car.global_basis.get_rotation_quaternion()
		var v := car.linear_velocity
		var a := car.angular_velocity
		cached_positions[id] = p
		cached_rows[id] = PackedFloat32Array([id, p.x, p.y, p.z, q.x, q.y, q.z, q.w,
			v.x, v.y, v.z, a.x, a.y, a.z, car.health, car.dmg.front, car.dmg.rear, car.dmg.left, car.dmg.right, car.nitro_amount,
			car.parts.bumper_f, car.parts.bumper_r, car.parts.hood, car.parts.boot, car.parts.door_l, car.parts.door_r])

func snapshot_rows(observer: int, include_far: bool) -> Array:
	_cache_snapshot_rows()
	var center: Vector3 = cached_positions.get(observer, Vector3.ZERO)
	var nearby: Array = []
	for id in cached_positions:
		var distance := center.distance_squared_to(cached_positions[id])
		if distance < 350.0 * 350.0:
			nearby.append([id, distance])
	nearby.sort_custom(func(a, b): return a[1] < b[1])
	var selected := {}
	# Never demote a car close enough to become an immediate collision threat.
	for pair in nearby:
		if float(pair[1]) < 60.0 * 60.0:
			selected[pair[0]] = true
	for i in mini(32, nearby.size()):
		selected[nearby[i][0]] = true
	var rows: Array = []
	for id in cached_rows:
		if include_far or selected.has(id):
			rows.append(cached_rows[id])
	return rows

func _send_snapshots() -> void:
	var remote := peers.keys().filter(func(peer): return peer != 1)
	if remote.is_empty():
		return
	var slots := maxi(1, ceili(remote.size() * SNAPSHOT_HZ / 60.0))
	for slot in mini(slots, remote.size()):
		var peer: int = remote[replication_cursor % remote.size()]
		replication_cursor += 1
		if not _can_send(peer):
			continue
		# Small rooms still send at 10 Hz; large rooms rotate through clients.
		var entry: Dictionary = peer_rounds.get(peer, {"tick": -60, "round": 0})
		if tick - int(entry.tick) < 6:
			continue
		entry.tick = tick
		entry.round += 1
		peer_rounds[peer] = entry
		var id: int = peers[peer]
		var watch := int(controls.get(id, {}).get("watch", id)) if rules.players.has(id) and not rules.players[id].alive else id
		var rows := snapshot_rows(watch, int(entry.round) % 10 == 1)
		var ack := int(controls.get(id, {}).get("seq", -1))
		for offset in range(0, rows.size(), 6):
			var packet := rows.slice(offset, mini(offset + 6, rows.size()))
			var packet_bytes := var_to_bytes([tick, packet, circle, rules.state, rules.elapsed, ack]).size()
			bytes_sent += packet_bytes
			max_snapshot_bytes = maxi(max_snapshot_bytes, packet_bytes)
			snapshot_messages += 1
			snapshot.rpc_id(peer, tick, packet, circle, rules.state, rules.elapsed, ack)

@rpc("authority", "call_remote", "unreliable_ordered", 2)
func snapshot(server_tick: int, rows: Array, zone: Dictionary, match_state: String, at: float, _ack: int) -> void:
	if server_tick < snapshot_tick or (status == "finished" and match_state != "finished"):
		return
	snapshot_tick = server_tick
	circle = zone
	if match_state != "finished" or status == "finished":
		status = match_state
	clock = at
	var now := Time.get_ticks_msec()
	if pending_inputs.has(_ack):
		prediction_age = clampf((now - int(pending_inputs[_ack])) / 2000.0, 0.0, 0.15)
		for sequence in pending_inputs.keys():
			if sequence <= _ack:
				pending_inputs.erase(sequence)
	for row: PackedFloat32Array in rows:
		var id := int(row[0])
		if not roster.has(id):
			continue
		if not cars.has(id):
			_spawn(id, _row_transform(row), false)
		var previous: PackedFloat32Array = samples[id][1] if samples.has(id) else row
		samples[id] = [previous, row, now]
		var c: Car = cars[id]
		c.health = row[14]
		c.disabled = not roster[id].alive or c.health <= 0.0
		c.dmg = {"front": row[15], "rear": row[16], "left": row[17], "right": row[18]}
		c.nitro_amount = row[19]
		var panels := ["bumper_f", "bumper_r", "hood", "boot", "door_l", "door_r"]
		for index in panels.size():
			var part: String = panels[index]
			if c.parts[part] > 0 and row[20 + index] <= 0 and c.visual:
				c.visual.detach(part, c.global_position, Vector3.UP)
			c.parts[part] = row[20 + index]
		if id == local_id:
			var xf := _row_transform(row)
			xf.origin += Vector3(row[8], row[9], row[10]) * prediction_age
			var error := xf.origin - c.global_position
			# Predict immediately with shared Car; reconcile to authoritative velocity/pose.
			c.global_position += error if error.length() > 8.0 else error * 0.35
			c.global_basis = c.global_basis.slerp(xf.basis, 0.35)
			c.linear_velocity = Vector3(row[8], row[9], row[10])
			c.angular_velocity = Vector3(row[11], row[12], row[13])
			c.freeze = status != "active" or c.disabled
			c.set_physics_process(not c.freeze)

static func _row_transform(row: PackedFloat32Array) -> Transform3D:
	return Transform3D(Basis(Quaternion(row[4], row[5], row[6], row[7]).normalized()), Vector3(row[1], row[2], row[3]))

func _client_tick(dt: float) -> void:
	if not cars.has(local_id):
		return
	var local: Car = cars[local_id]
	drive.enabled = status == "active" and not local.disabled
	input_timer += dt
	if input_timer >= 1.0 / INPUT_HZ:
		input_timer = 0.0
		input_seq += 1
		pending_inputs[input_seq] = Time.get_ticks_msec()
		if pending_inputs.size() > 128:
			pending_inputs.erase(pending_inputs.keys()[0])
		submit_input.rpc_id(1, input_seq, local.throttle, local.brake, local.steer, local.handbrake, local.nitro, spectating)
	# Missing server snapshots brake prediction after half a second.
	if samples.has(local_id) and Time.get_ticks_msec() - int(samples[local_id][2]) > 500:
		drive.enabled = false
		_stop(local)

func _process(dt: float) -> void:
	elapsed_wall += dt
	if not ready_world:
		return
	if not dedicated and camera:
		_update_presentation(dt)
	if args.has("bench") and elapsed_wall > 4.0:
		var now := Time.get_ticks_usec()
		bench_frames.append((now - bench_start) / 1000.0)
		if DisplayServer.get_name() != "headless":
			gpu_samples.append(RenderingServer.viewport_get_measured_render_time_gpu(get_viewport().get_viewport_rid()))
			draw_call_samples.append(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME))
		bench_start = now
	else:
		bench_start = Time.get_ticks_usec()
	if args.has("quit-after") and elapsed_wall >= float(args["quit-after"]):
		if args.has("bench"):
			_report()
		get_tree().quit()

func _update_presentation(_dt: float) -> void:
	if cars.has(local_id) and cars[local_id].disabled and status == "active":
		if not cars.has(spectating) or cars[spectating].disabled:
			next_spectator()
	var ordered := cars.keys()
	ordered.sort_custom(func(a, b): return cars[a].global_position.distance_squared_to(camera.global_position) < cars[b].global_position.distance_squared_to(camera.global_position))
	var detailed := ordered.slice(0, 24)
	for id in cars:
		var car: Car = cars[id]
		if not is_host() and id != local_id and samples.has(id):
			var sample: Array = samples[id]
			var prev: PackedFloat32Array = sample[0]
			var row: PackedFloat32Array = sample[1]
			var k := clampf((Time.get_ticks_msec() - int(sample[2])) / 100.0, 0, 1)
			car.global_transform = _row_transform(prev).interpolate_with(_row_transform(row), k)
			car.linear_velocity = Vector3(row[8], row[9], row[10])
			car.speed = car.linear_velocity.length()
			car.set_physics_process(false)
		var distance := car.global_position.distance_squared_to(camera.global_position)
		var near: bool = id == local_id or (detailed.has(id) and distance < 220.0 * 220.0)
		if near and not car.visual:
			_attach_visual(car)
		elif not near and car.visual:
			car.visual.queue_free()
			car.visual = null
		if not near and distance < 650.0 * 650.0:
			if not lods.has(id):
				_attach_lod(id, car)
			lods[id].visible = true
		elif lods.has(id):
			lods[id].visible = false
	if not circle.is_empty() and storm_mesh:
		storm_mesh.position = Vector3(circle.center.x, 100.0, circle.center.y)
		storm_mesh.scale = Vector3(maxf(circle.radius, 0.01), 1.0, maxf(circle.radius, 0.01))

func next_spectator() -> void:
	var alive: Array = cars.keys().filter(func(id): return not cars[id].disabled)
	if alive.is_empty() or not camera:
		return
	var index := alive.find(spectating)
	spectating = alive[(index + 1) % alive.size()]
	camera.set_target(cars[spectating])

func _attach_lod(id: int, car: Car) -> void:
	var root := Node3D.new()
	car.add_child(root)
	lods[id] = root
	var body := MeshInstance3D.new()
	body.mesh = CarVisual.load_mesh(car.spec.body)
	body.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var kind: String = car.spec.body
	if not lod_materials.has(kind):
		var mat := StandardMaterial3D.new()
		mat.albedo_color = car.spec.paint
		mat.roughness = 0.5
		lod_materials[kind] = mat
	body.material_override = lod_materials[kind]
	root.add_child(body)
	var wheel_mesh := CarVisual.load_mesh("wheel_" + str(car.spec.wheel))
	for index in 4:
		var wheel := MeshInstance3D.new()
		wheel.mesh = wheel_mesh
		wheel.position = car.wheel_local(index)
		wheel.scale = Vector3.ONE * float(car.spec.wheel_r) / 0.33
		wheel.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		root.add_child(wheel)

func _build_storm_visual() -> void:
	storm_mesh = MeshInstance3D.new()
	var cylinder := CylinderMesh.new()
	cylinder.top_radius = 1.0
	cylinder.bottom_radius = 1.0
	cylinder.height = 240.0
	cylinder.radial_segments = 128
	cylinder.cap_top = false
	cylinder.cap_bottom = false
	storm_mesh.mesh = cylinder
	var material := ShaderMaterial.new()
	material.shader = load("res://src/lcs/storm.gdshader")
	storm_mesh.material_override = material
	storm_mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(storm_mesh)

func _report() -> void:
	bench_frames.sort()
	var avg := 0.0
	for ms in bench_frames:
		avg += ms
	avg /= maxf(bench_frames.size(), 1)
	var p95: float = bench_frames[int(bench_frames.size() * 0.95)] if not bench_frames.is_empty() else 0.0
	var max_distance := 0.0
	var max_speed := 0.0
	for id in cars:
		max_distance = maxf(max_distance, cars[id].global_position.distance_to(spawn_positions[id]))
		max_speed = maxf(max_speed, cars[id].speed)
	var report := {"max_distance_from_spawn_m": max_distance, "max_speed_mps": max_speed, "eliminations": rules.events.size(), "players": cars.size(), "state": status, "remaining": rules.remaining(), "frame_avg_ms": avg,
		"frame_p95_ms": p95, "memory_static_mib": Performance.get_monitor(Performance.MEMORY_STATIC) / 1048576.0,
		"network_payload_bytes": bytes_sent, "snapshot_messages": snapshot_messages, "max_snapshot_payload_bytes": max_snapshot_bytes,
		"gpu": "unmeasured" if DisplayServer.get_name() == "headless" else "capture device profiler separately",
		"duration_s": elapsed_wall, "physics_objects": Performance.get_monitor(Performance.PHYSICS_3D_ACTIVE_OBJECTS)}
	if not gpu_samples.is_empty():
		gpu_samples.sort()
		report["gpu_adapter"] = RenderingServer.get_video_adapter_name()
		report["gpu_p95_ms"] = gpu_samples[int(gpu_samples.size() * 0.95)]
		report["gpu"] = "software renderer" if "llvmpipe" in str(report.gpu_adapter).to_lower() else "renderer timestamp"
		report["draw_calls_peak"] = draw_call_samples.max()
	print("LCS_BENCH ", JSON.stringify(report))
	if args.has("report"):
		var file := FileAccess.open(str(args.report), FileAccess.WRITE)
		if file:
			file.store_string(JSON.stringify(report, "  "))

func leave() -> void:
	if connected or connecting:
		multiplayer.multiplayer_peer.close()
	Car.water_check = Callable()
	get_tree().change_scene_to_file("res://scenes/main.tscn")

func _exit_tree() -> void:
	Car.water_check = Callable()
	if connected:
		connected = false
		multiplayer.multiplayer_peer.close()

func _can_send(peer: int) -> bool:
	if peer == 1 or not connected or not multiplayer.get_peers().has(peer):
		return false
	var transport := multiplayer.multiplayer_peer as ENetMultiplayerPeer
	return transport != null and transport.get_peer(peer).get_state() == ENetPacketPeer.STATE_CONNECTED
