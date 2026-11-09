class_name Contracts
extends Node
## In-run contracts: three short objectives on screen at all times, so every
## minute of a chase has something to go for besides "survive". Finish one
## and it pays score (through the chain, like any skill event) plus cash at
## the end of the run, and a harder one takes its place.
##
## Each contract measures progress from the moment it was handed out
## (counters are snapshotted), or a peak reached since then (speed, chain).

signal completed(c: Dictionary)

## kind: [label template, stat, mode, targets per tier, score, cash]
##   mode "delta": the stat's increase since the contract started
##   mode "peak":  the stat's highest value since the contract started
const KINDS := {
	"near": ["%d near misses", "near_misses", "delta", [3, 6, 10, 15], 900, 120],
	"wreck": ["Take out %d police", "police_wrecked", "delta", [1, 2, 4, 6], 1400, 200],
	"drift": ["Drift for %d s", "drift_time", "delta", [4, 8, 14, 20], 900, 120],
	"air": ["%.1f s of air", "air_time", "delta", [1.0, 2.5, 4.0, 6.0], 1000, 140],
	"speed": ["Hit %d km/h", "top_speed_kmh", "peak", [140, 170, 200, 230], 700, 100],
	"distance": ["Drive %.1f km", "distance_km", "delta", [1.0, 2.0, 3.5, 5.0], 800, 110],
	"chain": ["Build a x%.1f chain", "chain", "peak", [2.5, 4.0, 5.5, 7.0], 1200, 160],
	"smash": ["Smash %d street objects", "smashed", "delta", [5, 10, 18, 30], 700, 90],
	"roadblock": ["Escape %d roadblock", "roadblocks", "delta", [1, 1, 2, 3], 1600, 240],
}
const SLOTS := 3

var score: ScoreKeeper
var active: Array = []          # {kind, label, target, base, peak, progress, tier}
var done_count := 0
var cash := 0
var smashed := 0
var running := false
var _rng := RandomNumberGenerator.new()
var _tier := 0


func begin(p_score: ScoreKeeper, seed_value := -1) -> void:
	score = p_score
	if seed_value >= 0:
		_rng.seed = seed_value
	else:
		_rng.randomize()
	active.clear()
	done_count = 0
	cash = 0
	smashed = 0
	_tier = 0
	running = true
	for i in SLOTS:
		active.append(_make(i))


func stop() -> void:
	running = false


func stat(name: String) -> float:
	match name:
		"top_speed_kmh":
			return score.player.speed * 3.6 if score and score.player else 0.0
		"distance_km":
			return score.distance / 1000.0
		"smashed":
			return float(smashed)
		"chain":
			return score.chain
	return float(score.get(name))


func _make(slot: int) -> Dictionary:
	var used := active.map(func(c): return c["kind"])
	var kinds: Array = KINDS.keys().filter(func(k): return not (k in used))
	# Roadblocks only appear once the pursuit sets them up.
	if score and score.director and score.director.heat < 3:
		kinds.erase("roadblock")
	var kind: String = kinds[_rng.randi() % kinds.size()]
	var k: Array = KINDS[kind]
	# Tiers rise as you clear contracts; each slot is offset a little.
	var tier := clampi(_tier / 2 + (slot % 2), 0, (k[3] as Array).size() - 1)
	var target: float = float(k[3][tier])
	var label: String = (k[0] as String) % target if not (k[0] as String).contains("%d") else (k[0] as String) % int(target)
	return {"kind": kind, "label": label, "target": target, "base": stat(k[1]), "peak": 0.0, "progress": 0.0, "tier": tier,
		"score": int(k[4] * (1.0 + tier * 0.6)), "cash": int(k[5] * (1.0 + tier * 0.6)), "flash": 0.0}


func _physics_process(dt: float) -> void:
	if not running or score == null or not score.running:
		return
	for i in active.size():
		var c: Dictionary = active[i]
		c["flash"] = maxf(0.0, float(c["flash"]) - dt)
		var k: Array = KINDS[c["kind"]]
		var v := stat(k[1])
		var p := 0.0
		if k[2] == "delta":
			p = v - float(c["base"])
		else:
			c["peak"] = maxf(float(c["peak"]), v)
			p = float(c["peak"])
		c["progress"] = clampf(p / float(c["target"]), 0.0, 1.0)
		if p >= float(c["target"]):
			_complete(i)


func _complete(i: int) -> void:
	var c: Dictionary = active[i]
	done_count += 1
	cash += int(c["cash"])
	_tier += 1
	score.award("CONTRACT: " + str(c["label"]).to_upper(), float(c["score"]))
	completed.emit(c)
	var n := _make(i)
	n["flash"] = 1.2
	active[i] = n
