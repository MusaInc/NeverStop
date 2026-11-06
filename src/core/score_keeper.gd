class_name ScoreKeeper
extends Node
## Arcade scoring for one run. Skill pays, random destruction doesn't:
##   * steady income: survival (per second, x heat) and distance
##   * skill events: near misses, drifts, airtime, top-speed runs, police
##     wrecked (only counted when the player was involved or it happened in
##     the pursuit), roadblocks escaped, spike-strip dodges
##   * a CHAIN multiplier (x1 .. x8): every skill event within CHAIN_WINDOW
##     of the last adds +0.5; a heavy crash or getting rammed breaks it.
## Final score = sum of everything; currency = score / 40 + survival bonus.

signal event(label: String, points: int, chain: float)
signal chain_broken

const CHAIN_WINDOW := 4.5
const NEAR_MISS_GAP := 1.3          # m of clear air between bodies
const NEAR_MISS_SPEED := 14.0       # m/s relative

var player: Car
var director: PursuitDirector
var civilians: CivilianTraffic
var score := 0.0
var chain := 1.0
var chain_t := 0.0
var time := 0.0
var distance := 0.0
var near_misses := 0
var drift_time := 0.0
var air_time := 0.0
var best_drift := 0.0
var top_speed := 0.0
var max_heat := 1
var police_wrecked := 0
var roadblocks := 0
var _drift_run := 0.0
var _fast_run := 0.0
var _last_pos := Vector3.INF
var _close := {}                    # instance id -> closest gap seen while passing
var running := false


func begin() -> void:
	score = 0.0
	chain = 1.0
	chain_t = 0.0
	time = 0.0
	distance = 0.0
	near_misses = 0
	drift_time = 0.0
	air_time = 0.0
	best_drift = 0.0
	top_speed = 0.0
	max_heat = 1
	police_wrecked = 0
	roadblocks = 0
	_drift_run = 0.0
	_fast_run = 0.0
	_last_pos = player.global_position
	_close.clear()
	running = true


func award(label: String, pts: float, extends_chain := true) -> void:
	var p := int(round(pts * chain))
	score += p
	if extends_chain:
		chain = minf(8.0, chain + 0.5) if chain_t > 0.0 else maxf(chain, 1.5)
		chain_t = CHAIN_WINDOW
	event.emit(label, p, chain)


func break_chain() -> void:
	if chain > 1.0:
		chain_broken.emit()
	chain = 1.0
	chain_t = 0.0


func _physics_process(dt: float) -> void:
	Prof.begin("score")
	if not running or player == null:
		Prof.end("score")
		return
	time += dt
	var heat := director.heat if director else 1
	max_heat = maxi(max_heat, heat)
	score += dt * 10.0 * heat
	var p := player.global_position
	if _last_pos != Vector3.INF:
		var step := Vector2(p.x - _last_pos.x, p.z - _last_pos.z).length()
		if step < 10.0:
			distance += step
			score += step * 0.1
	_last_pos = p
	var spd := player.speed
	top_speed = maxf(top_speed, spd)
	chain_t -= dt
	if chain_t <= 0.0 and chain > 1.0:
		chain = maxf(1.0, chain - dt * 0.8)  # decays gently, doesn't snap
	# Drifts: banked when the slide ends.
	if player.drifting and spd > 12.0:
		_drift_run += dt
		drift_time += dt
	elif _drift_run > 0.0:
		if _drift_run > 0.6:
			best_drift = maxf(best_drift, _drift_run)
			award("DRIFT %.1fs" % _drift_run, 120.0 * _drift_run * (1.0 + _drift_run * 0.3))
		_drift_run = 0.0
	if player.wheels_on_ground == 0:
		air_time += dt
	# Top-speed runs: every 3 s above 160 km/h.
	if spd > 44.0:
		_fast_run += dt
		if _fast_run > 3.0:
			_fast_run = 0.0
			award("FLAT OUT", 150.0)
	else:
		_fast_run = 0.0
	_near_misses()
	Prof.end("score")


func on_landed(airtime: float, _impact: float) -> void:
	if airtime > 0.45 and running:
		award("AIR %.1fs" % airtime, 250.0 * airtime * airtime + 100.0)


func on_player_impact(strength: float, other: Object) -> void:
	if not running:
		return
	if strength > 11.0:
		break_chain()
	# Contact cancels a near miss in progress.
	if other:
		_close.erase(other.get_instance_id())


func on_police_wrecked(_u: PoliceUnit) -> void:
	police_wrecked += 1
	award("COP TAKEN OUT", 600.0 + 100.0 * (director.heat if director else 1))


func on_roadblock_escaped() -> void:
	roadblocks += 1
	award("ROADBLOCK ESCAPED", 1500.0)


func _near_misses() -> void:
	if player.speed < 12.0:
		return
	var p := player.global_position
	var others: Array = []
	if civilians:
		others.append_array(civilians.active_cars())
	if director:
		for u in director.units:
			if u.car and u.alive():
				others.append(u.car)
	var pw: float = (player.spec["size"] as Vector3).x * 0.5
	var pl: float = (player.spec["size"] as Vector3).z * 0.5
	for o: Car in others:
		var rel := o.global_position - p
		if rel.length() > 14.0:
			var k := o.get_instance_id()
			if _close.has(k):
				var g: float = _close[k]
				_close.erase(k)
				if g < NEAR_MISS_GAP and g > -0.05:
					near_misses += 1
					award("NEAR MISS" if g > 0.5 else "RAZOR CLOSE", 180.0 if g > 0.5 else 320.0)
			continue
		var rv := (player.linear_velocity - o.linear_velocity).length()
		if rv < NEAR_MISS_SPEED:
			continue
		# Gap between the two bodies, measured across the player's heading.
		var right := player.global_basis.x
		var fwd := -player.global_basis.z
		var lat := absf(rel.dot(right))
		var lon := absf(rel.dot(fwd))
		var ow: float = (o.spec["size"] as Vector3).x * 0.5
		if lon < pl + 3.0:
			var gap := lat - pw - ow
			var k2 := o.get_instance_id()
			if not _close.has(k2) or gap < float(_close[k2]):
				_close[k2] = gap


func currency() -> int:
	return int(score / 40.0) + int(time / 6.0)


func summary() -> Dictionary:
	return {
		"score": int(score), "time": time, "distance": distance, "near_misses": near_misses,
		"police_wrecked": police_wrecked, "max_heat": max_heat, "roadblocks": roadblocks,
		"drift_time": drift_time, "air_time": air_time, "top_speed": top_speed, "currency": currency(),
	}
