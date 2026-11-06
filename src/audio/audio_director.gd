class_name AudioDirector
extends Node
## The whole mix.
##  * Player engine: two loops (low / high firing) per engine type, pitch
##    and crossfade from rpm, louder under throttle; a gear-change clunk.
##  * Tyres (squeal + scrub from wheel slip), wind (speed), metal scrape.
##  * Police: real 3-D sirens on the nearest few units (wail / yelp, with
##    doppler), their engines on the nearest two, the helicopter's rotor.
##    The siren pool is capped so a 30-car pursuit is a wall of sound, not
##    distortion.
##  * One-shots: crashes (heavy/light by impact), glass, landings, tyre pop,
##    nitro, chimes for score events, the BUSTED sting. 3-D one-shots for
##    crashes between other cars near the camera.
##  * Music: a pulse bed and an intensity stem crossfaded by heat.
## Buses: Music and SFX (Settings volumes), a limiter on Master.

const DIR := "res://assets/audio/"
const ENGINE_OF := {"kestrel": "i4", "marlin": "v6", "brute": "v8", "vanta": "f6", "halcyon": "v10", "warden": "diesel",
	"police_patrol": "v6", "police_interceptor": "f6", "police_heavy": "diesel"}
const SIRENS := 4
const SHOTS_3D := 8

var game: Node
var player: Car
var director: PursuitDirector
var _streams := {}
var _eng_lo: AudioStreamPlayer
var _eng_hi: AudioStreamPlayer
var _eng_kind := ""
var _loops := {}
var _sirens: Array[AudioStreamPlayer3D] = []
var _siren_owner: Array = []
var _police_eng: Array[AudioStreamPlayer3D] = []
var _shots3d: Array[AudioStreamPlayer3D] = []
var _shot_i := 0
var _pool: Array[AudioStreamPlayer] = []
var _pool_i := 0
var _heli: AudioStreamPlayer3D
var _gear := 1
var _nitro_was := false
var _music_bed: AudioStreamPlayer
var _music_int: AudioStreamPlayer
var _intensity := 0.0
var menu_mode := true


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_buses()
	_eng_lo = _player("SFX")
	_eng_hi = _player("SFX")
	for k in ["tyre_squeal", "tyre_scrub", "wind", "scrape", "city_ambience"]:
		var p := _player("SFX")
		p.stream = _loop(k)
		p.volume_db = -80.0
		p.play()
		_loops[k] = p
	for i in 10:
		_pool.append(_player("SFX"))
	for i in SIRENS:
		var s := AudioStreamPlayer3D.new()
		s.bus = "SFX"
		s.stream = _loop("siren_wail" if i % 2 == 0 else "siren_yelp")
		s.unit_size = 22.0
		s.max_distance = 420.0
		s.doppler_tracking = AudioStreamPlayer3D.DOPPLER_TRACKING_PHYSICS_STEP
		s.attenuation_model = AudioStreamPlayer3D.ATTENUATION_INVERSE_DISTANCE
		s.volume_db = -4.0
		add_child(s)
		_sirens.append(s)
		_siren_owner.append(null)
	for i in 2:
		var e := AudioStreamPlayer3D.new()
		e.bus = "SFX"
		e.unit_size = 10.0
		e.max_distance = 160.0
		e.doppler_tracking = AudioStreamPlayer3D.DOPPLER_TRACKING_PHYSICS_STEP
		add_child(e)
		_police_eng.append(e)
	for i in SHOTS_3D:
		var s3 := AudioStreamPlayer3D.new()
		s3.bus = "SFX"
		s3.unit_size = 14.0
		s3.max_distance = 220.0
		add_child(s3)
		_shots3d.append(s3)
	_heli = AudioStreamPlayer3D.new()
	_heli.bus = "SFX"
	_heli.stream = _loop("heli_rotor")
	_heli.unit_size = 45.0
	_heli.max_distance = 500.0
	add_child(_heli)
	_music_bed = _player("Music")
	_music_bed.stream = _loop("music_bed")
	_music_int = _player("Music")
	_music_int.stream = _loop("music_intense")
	_music_bed.play()
	_music_int.play()
	_music_int.volume_db = -80.0
	Settings.changed.connect(_volumes)
	_volumes()


func _buses() -> void:
	if AudioServer.get_bus_index("Music") < 0:
		for name in ["Music", "SFX"]:
			AudioServer.add_bus()
			var i := AudioServer.bus_count - 1
			AudioServer.set_bus_name(i, name)
			AudioServer.set_bus_send(i, "Master")
		var lim := AudioEffectHardLimiter.new()
		lim.ceiling_db = -0.5
		AudioServer.add_bus_effect(0, lim)
		var comp := AudioEffectCompressor.new()
		comp.threshold = -14.0
		comp.ratio = 3.0
		AudioServer.add_bus_effect(AudioServer.get_bus_index("SFX"), comp)


func _volumes() -> void:
	AudioServer.set_bus_volume_db(AudioServer.get_bus_index("Music"), linear_to_db(maxf(Settings.music_volume, 0.0001)))
	AudioServer.set_bus_volume_db(AudioServer.get_bus_index("SFX"), linear_to_db(maxf(Settings.sfx_volume, 0.0001)))


func _player(bus: String) -> AudioStreamPlayer:
	var p := AudioStreamPlayer.new()
	p.bus = bus
	add_child(p)
	return p


func _stream(name: String) -> AudioStream:
	if _streams.has(name):
		return _streams[name]
	var path := DIR + name + ".wav"
	var s: AudioStream = load(path) if ResourceLoader.exists(path) else null
	_streams[name] = s
	return s


func _loop(name: String) -> AudioStream:
	var s := _stream(name)
	if s is AudioStreamWAV:
		var w := (s as AudioStreamWAV).duplicate() as AudioStreamWAV
		w.loop_mode = AudioStreamWAV.LOOP_FORWARD
		w.loop_begin = 0
		w.loop_end = int(w.get_length() * w.mix_rate)
		_streams[name + "#loop"] = w
		return w
	return s


func attach(p_game: Node, p_player: Car, p_director: PursuitDirector) -> void:
	game = p_game
	director = p_director
	set_player(p_player)
	director.busted.connect(func(): play("busted", 0.0))
	director.spiked.connect(func(): play("tyre_pop", 0.0))
	director.unit_wrecked.connect(func(u: PoliceUnit, _b):
		if u.car:
			play_at("crash_heavy_%d" % (randi() % 3), u.car.global_position, 4.0))
	director.roadblock_escaped.connect(func(): play("chime", -2.0, 1.2))


func set_player(p: Car) -> void:
	player = p
	var kind: String = ENGINE_OF.get(str(p.spec.get("id", "kestrel")), "v6")
	if kind != _eng_kind:
		_eng_kind = kind
		_eng_lo.stream = _loop("engine_%s_low" % kind)
		_eng_hi.stream = _loop("engine_%s_high" % kind)
		_eng_lo.play()
		_eng_hi.play()
	p.impact.connect(_on_player_impact)
	p.landed.connect(func(a, v): if a > 0.3: play("land", linear_to_db(clampf(v / 10.0, 0.3, 1.0))))


func _on_player_impact(strength: float, _at: Vector3, _n: Vector3, _other: Object) -> void:
	if strength > 12.0:
		play("crash_heavy_%d" % (randi() % 3), linear_to_db(clampf(strength / 30.0, 0.5, 1.0)), randf_range(0.9, 1.05))
		if strength > 20.0:
			play("glass", -6.0, randf_range(0.9, 1.1))
	elif strength > 3.0:
		play("crash_light_%d" % (randi() % 3), linear_to_db(clampf(strength / 12.0, 0.25, 1.0)), randf_range(0.9, 1.15))


func play(name: String, db := 0.0, pitch := 1.0) -> void:
	var s := _stream(name)
	if s == null:
		return
	var p := _pool[_pool_i]
	_pool_i = (_pool_i + 1) % _pool.size()
	p.stream = s
	p.volume_db = db
	p.pitch_scale = pitch
	p.play()


func play_at(name: String, at: Vector3, db := 0.0) -> void:
	var s := _stream(name)
	if s == null:
		return
	var p := _shots3d[_shot_i]
	_shot_i = (_shot_i + 1) % _shots3d.size()
	p.stream = s
	p.global_position = at
	p.volume_db = db
	p.pitch_scale = randf_range(0.9, 1.1)
	p.play()


func ui_click() -> void:
	play("ui_click", -4.0)


func event_chime(points: int) -> void:
	play("chime", linear_to_db(clampf(points / 800.0, 0.25, 0.8)), 1.0 + randf() * 0.1)


func _process(dt: float) -> void:
	if player == null or not is_instance_valid(player):
		return
	var paused := get_tree().paused
	var k := 1.0 - exp(-10.0 * dt)
	# Engine.
	var rpm := player.rpm
	var thr := player.throttle
	var hi_mix := smoothstep(0.35, 0.85, rpm)
	var base := lerpf(-9.0, -2.0, thr) if not paused else -40.0
	_eng_lo.pitch_scale = lerpf(0.75, 2.2, rpm) if rpm < 0.7 else lerpf(1.9, 2.4, (rpm - 0.7) / 0.3)
	_eng_hi.pitch_scale = lerpf(0.45, 1.05, rpm)
	_eng_lo.volume_db = lerpf(_eng_lo.volume_db, base + linear_to_db(maxf(1.0 - hi_mix, 0.02)), k)
	_eng_hi.volume_db = lerpf(_eng_hi.volume_db, base + linear_to_db(maxf(hi_mix, 0.02)), k)
	if player.gear != _gear:
		if player.gear > _gear and thr > 0.5:
			play("gear", -8.0, randf_range(0.95, 1.05))
		_gear = player.gear
	if player.nitro and player.nitro_amount > 0.0 and not _nitro_was and float(player.spec.get("nitro", 0.0)) > 0.0:
		play("nitro", -3.0)
	_nitro_was = player.nitro
	# Tyres, wind, scrape.
	var slip := 0.0
	for i in 4:
		slip = maxf(slip, player.wheel_slip[i])
	var sp := player.speed
	_set_loop("tyre_squeal", -80.0 if paused or slip < 0.25 or sp < 6.0 else lerpf(-18.0, -4.0, slip), k, lerpf(0.9, 1.1, clampf(sp / 50.0, 0.0, 1.0)))
	_set_loop("tyre_scrub", -80.0 if paused or slip < 0.15 else lerpf(-24.0, -10.0, slip), k)
	_set_loop("wind", -80.0 if paused else lerpf(-40.0, -6.0, clampf(sp / 60.0, 0.0, 1.0)), k, lerpf(0.8, 1.3, clampf(sp / 60.0, 0.0, 1.0)))
	_set_loop("scrape", -80.0 if paused or player.scraping < 0.1 or sp < 3.0 else lerpf(-16.0, -4.0, player.scraping), k * 2.0)
	_set_loop("city_ambience", -14.0 if not paused else -30.0, k)
	_police_audio()
	# Music: heat drives the intensity stem.
	var heat: int = director.heat if director and director.active else 1
	var want := 0.0 if menu_mode else clampf((heat - 1) / 3.0, 0.0, 1.0)
	if director and director.busted_flag:
		want = 0.0
	_intensity = move_toward(_intensity, want, dt * 0.25)
	_music_int.volume_db = linear_to_db(maxf(_intensity, 0.0001))
	_music_bed.volume_db = -6.0 if menu_mode else -3.0


func _set_loop(name: String, db: float, k: float, pitch := 1.0) -> void:
	var p: AudioStreamPlayer = _loops[name]
	p.volume_db = lerpf(p.volume_db, db, clampf(k, 0.0, 1.0))
	p.pitch_scale = pitch


func _police_audio() -> void:
	if director == null:
		return
	var cam := get_viewport().get_camera_3d()
	if cam == null:
		return
	var cp := cam.global_position
	# Nearest sirens (physical cars only; virtual units are silent until close).
	var cars: Array = []
	for u in director.units:
		if u.car and u.alive():
			cars.append(u.car)
	cars.sort_custom(func(a, b): return a.global_position.distance_squared_to(cp) < b.global_position.distance_squared_to(cp))
	for i in SIRENS:
		var s := _sirens[i]
		if i < cars.size():
			var c: Car = cars[i]
			s.global_position = c.global_position + Vector3.UP * 1.5
			if not s.playing:
				s.play(randf() * 3.0)
			# More units: each one a little quieter (keeps the mix clean).
			s.volume_db = -3.0 - i * 2.5
			if i < 3:
				(c.visual as CarVisual).set_beacon_lights(true)
		elif s.playing:
			s.stop()
	for i in 2:
		var e := _police_eng[i]
		if i < cars.size():
			var c2: Car = cars[i]
			var kind: String = ENGINE_OF.get(str(c2.spec["id"]), "v6")
			var want: AudioStream = _loop("engine_%s_low" % kind)
			if e.stream != want:
				e.stream = want
			e.global_position = c2.global_position
			e.pitch_scale = lerpf(0.8, 2.1, c2.rpm)
			e.volume_db = -6.0
			if not e.playing:
				e.play()
		elif e.playing:
			e.stop()
	for i in range(3, cars.size()):
		(cars[i].visual as CarVisual).set_beacon_lights(false)
	if director.heli:
		_heli.global_position = director.heli.global_position
		if not _heli.playing:
			_heli.play()
	elif _heli.playing:
		_heli.stop()
