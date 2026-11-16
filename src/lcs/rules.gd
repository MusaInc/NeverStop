class_name LcsRules
extends RefCounted
## Pure authoritative match ledger. No client-facing method accepts health or kills.
const CAP := 100
const HEAL := 35.0
const CREDIT_SECONDS := 8.0
const CLASSES := ["sports", "muscle", "suv", "heavy"]
var players := {}
var state := "waiting"
var elapsed := 0.0
var winner := 0
var events: Array = []
var sequence := 0
var batching := false
var pending: Array = []

static func vehicle(kind: String) -> Dictionary:
	var bodies := {"sports": "vanta", "muscle": "brute", "suv": "warden", "heavy": "goliath"}
	var s := CarCatalog.spec(bodies.get(kind, "vanta"))
	# Competitive profiles: no save upgrades, repair perks or Workshop equipment.
	var values: Array = {
		"sports": [1300.0, 8.0, 64.0, 1.50, 0.95],
		"muscle": [1700.0, 8.6, 59.0, 1.32, 1.10],
		"suv": [2200.0, 6.8, 53.0, 1.38, 1.25],
		"heavy": [2800.0, 5.7, 47.0, 1.22, 1.40]}[kind if kind in CLASSES else "sports"]
	s["mass"] = values[0]
	s["engine"] = values[1]
	s["top_speed"] = values[2]
	s["grip"] = values[3]
	s["durability"] = values[4]
	s["ram"] = 1.0
	s["repair"] = 0.0
	s["nitro"] = 0.45
	return s

func join(id: int, label: String, kind: String, bot := false) -> bool:
	if state != "waiting" or players.size() >= CAP or players.has(id) or id <= 0 or kind not in CLASSES:
		return false
	players[id] = {"id": id, "name": label.left(20), "class": kind, "bot": bot,
		"hp": 100.0, "alive": true, "kills": 0, "attacker": 0, "hit_at": -100.0}
	return true

func start() -> bool:
	if state != "waiting" or players.size() < 2:
		return false
	state = "countdown"
	elapsed = 0.0
	return true

func advance(dt: float) -> void:
	if state == "countdown":
		elapsed += dt
		if elapsed >= 5.0:
			state = "active"
			elapsed = 0.0
	elif state == "active":
		elapsed += dt

func hit(victim: int, attacker: int) -> void:
	if state != "active" or not players.has(victim) or not players.has(attacker) or victim == attacker:
		return
	if players[victim].alive and players[attacker].alive:
		players[victim].attacker = attacker
		players[victim].hit_at = elapsed

func damage(id: int, hp: float, cause := "collision") -> void:
	if state != "active" or not players.has(id) or not players[id].alive or not is_finite(hp) or hp <= 0.0:
		return
	players[id].hp = maxf(0.0, players[id].hp - hp)
	if players[id].hp <= 0.0:
		eliminate(id, cause)

func eliminate(id: int, cause: String) -> void:
	if state != "active" or not players.has(id) or not players[id].alive:
		return
	var p: Dictionary = players[id]
	p.alive = false
	p.hp = 0.0
	var record := {"victim": id, "attacker": int(p.attacker), "hit_at": float(p.hit_at), "cause": cause}
	if batching:
		pending.append(record)
	else:
		_reward(record)

func begin_damage_batch() -> void:
	batching = true

func end_damage_batch() -> void:
	batching = false
	for record in pending:
		_reward(record)
	pending.clear()

func _reward(record: Dictionary) -> void:
	var id := int(record.victim)
	var cause := str(record.cause)
	var killer := int(record.attacker)
	var heal := 0.0
	# A recent ram can earn credit for a storm/water finish; disconnects never heal.
	if cause == "disconnect" or elapsed - float(record.hit_at) > CREDIT_SECONDS or not players.has(killer) or killer == id:
		killer = 0
	if killer != 0 and players[killer].alive:
		var k: Dictionary = players[killer]
		k.kills += 1
		heal = minf(HEAL, 100.0 - float(k.hp))
		k.hp += heal
	else:
		killer = 0
	sequence += 1
	events.append({"seq": sequence, "victim": id, "killer": killer, "heal": heal, "cause": cause, "left": remaining()})

func complete() -> void:
	# Called after processing the whole physics tick, so simultaneous last deaths draw.
	if state != "active" or remaining() > 1:
		return
	winner = 0
	for id in players:
		if players[id].alive:
			winner = id
	state = "finished"

func remaining() -> int:
	var n := 0
	for p in players.values():
		n += int(p.alive)
	return n
