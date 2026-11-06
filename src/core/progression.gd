class_name Progression
extends RefCounted
## Challenges and starting locations. Challenges are checked against each
## finished run (ScoreKeeper.summary + the car used); each pays once.

const CHALLENGES := [
	{"id": "survive_1", "name": "Warm-Up", "desc": "Survive 1 minute", "reward": 300, "check": "time", "value": 60.0},
	{"id": "survive_5", "name": "Five Minute Legend", "desc": "Survive 5 minutes", "reward": 2500, "check": "time", "value": 300.0},
	{"id": "survive_10", "name": "Never Stop", "desc": "Survive 10 minutes", "reward": 8000, "check": "time", "value": 600.0},
	{"id": "heat_3", "name": "Wanted", "desc": "Reach heat 3", "reward": 500, "check": "max_heat", "value": 3},
	{"id": "heat_5", "name": "Most Wanted", "desc": "Reach heat 5", "reward": 2000, "check": "max_heat", "value": 5},
	{"id": "heat_7", "name": "Public Enemy", "desc": "Reach heat 7", "reward": 6000, "check": "max_heat", "value": 7},
	{"id": "wreck_5", "name": "Demolition", "desc": "Take out 5 police cars in one run", "reward": 800, "check": "police_wrecked", "value": 5},
	{"id": "wreck_20", "name": "Scrapyard", "desc": "Take out 20 police cars in one run", "reward": 4000, "check": "police_wrecked", "value": 20},
	{"id": "roadblocks_3", "name": "Gatecrasher", "desc": "Escape 3 roadblocks in one run", "reward": 2500, "check": "roadblocks", "value": 3},
	{"id": "near_25", "name": "Threading", "desc": "25 near misses in one run", "reward": 1200, "check": "near_misses", "value": 25},
	{"id": "distance_10", "name": "Long Way Round", "desc": "Drive 10 km in one run", "reward": 2000, "check": "distance", "value": 10000.0},
	{"id": "drift_30", "name": "Sideways", "desc": "30 s of drifting in one run", "reward": 1000, "check": "drift_time", "value": 30.0},
	{"id": "kestrel_3", "name": "Underdog", "desc": "Reach heat 3 in the Kestrel", "reward": 1500, "check": "max_heat", "value": 3, "car": "kestrel"},
	{"id": "score_100k", "name": "Six Figures", "desc": "Score 100,000 in one run", "reward": 5000, "check": "score", "value": 100000},
]

## Starting spots: a centre point the game spawns near (on a lane facing a
## good road), unlocked with cash.
const STARTS := {
	"downtown": {"name": "Downtown", "at": Vector3(560, 0, -170), "price": 0},
	"docks": {"name": "The Docks", "at": Vector3(420, 0, -520), "price": 1500},
	"oldtown": {"name": "Old Town", "at": Vector3(860, 0, 120), "price": 2500},
	"coast": {"name": "Coast Road", "at": Vector3(900, 0, 520), "price": 3500},
	"westbank": {"name": "Westbank", "at": Vector3(-900, 0, 100), "price": 5000},
}


static func check(run: Dictionary, car_id: String, save: Node) -> Array:
	var done: Array = []
	for c in CHALLENGES:
		if save.challenge_done(c["id"]):
			continue
		if c.has("car") and c["car"] != car_id:
			continue
		if float(run.get(c["check"], 0.0)) >= float(c["value"]):
			save.complete_challenge(c["id"], c["reward"])
			done.append(c)
	return done
