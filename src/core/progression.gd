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
	{"id": "contracts_3", "name": "Contractor", "desc": "Finish 3 contracts in one run", "reward": 700, "check": "contracts", "value": 3},
	{"id": "contracts_10", "name": "Fixer", "desc": "Finish 10 contracts in one run", "reward": 4000, "check": "contracts", "value": 10},
	{"id": "air_10", "name": "Frequent Flyer", "desc": "10 s of air in one run", "reward": 1500, "check": "air_time", "value": 10.0},
	{"id": "speed_220", "name": "Terminal Velocity", "desc": "Reach 220 km/h", "reward": 2500, "check": "top_speed", "value": 61.1},
	{"id": "smash_50", "name": "Street Sweeper", "desc": "Smash 50 street objects in one run", "reward": 1500, "check": "smashed", "value": 50},
	{"id": "survive_15", "name": "The Long Night", "desc": "Survive 15 minutes", "reward": 15000, "check": "time", "value": 900.0},
	{"id": "heat_9", "name": "Whole City", "desc": "Reach heat 9", "reward": 12000, "check": "max_heat", "value": 9},
	{"id": "mammoth_wreck", "name": "Road Train", "desc": "Take out 8 police in the Mammoth", "reward": 3000, "check": "police_wrecked", "value": 8, "car": "mammoth"},
]

## Career ranks: every point you score in a chase is career XP. Each rank
## up pays a cash bonus on the results screen.
const RANKS := [
	["Joyrider", 0, 0], ["Wheelman", 8000, 500], ["Getaway Driver", 25000, 800], ["Street Ghost", 60000, 1200],
	["Wanted", 120000, 1800], ["Road Outlaw", 220000, 2500], ["Most Wanted", 380000, 3500],
	["Public Enemy", 600000, 5000], ["Untouchable", 900000, 7000], ["City Legend", 1350000, 9000],
	["Never Stop", 2000000, 15000],
]


static func rank_index(xp: int) -> int:
	var r := 0
	for i in RANKS.size():
		if xp >= int(RANKS[i][1]):
			r = i
	return r


static func rank_name(xp: int) -> String:
	return str(RANKS[rank_index(xp)][0])


## 0..1 progress through the current rank (1 at the top rank).
static func rank_progress(xp: int) -> float:
	var i := rank_index(xp)
	if i >= RANKS.size() - 1:
		return 1.0
	return clampf(float(xp - int(RANKS[i][1])) / float(int(RANKS[i + 1][1]) - int(RANKS[i][1])), 0.0, 1.0)


## Adds a run's XP; returns the ranks gained ([name, reward] each), paying them.
static func add_xp(save: Node, amount: int) -> Array:
	var before := int(save.data.get("xp", 0))
	var after := before + maxi(amount, 0)
	save.data["xp"] = after
	var gained: Array = []
	for i in range(rank_index(before) + 1, rank_index(after) + 1):
		gained.append([RANKS[i][0], RANKS[i][2]])
		save.add_cash(int(RANKS[i][2]))
	save.save()
	return gained

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


## Daily streak: the first launch each day pays; consecutive days pay more
## (a missed day starts again at day 1). Offline, uses the device date.
const DAILY := [250, 400, 600, 800, 1000, 1500, 2500]


static func daily_claim(save: Node, today: String) -> Dictionary:
	var last := str(save.data.get("daily_last", ""))
	if last == today:
		return {"claimed": false, "day": int(save.data.get("daily_streak", 0)), "reward": 0}
	var streak := 1
	if last != "":
		var gap := int(round((Time.get_unix_time_from_datetime_string(today) - Time.get_unix_time_from_datetime_string(last)) / 86400.0))
		if gap == 1:
			streak = int(save.data.get("daily_streak", 0)) + 1
	var reward: int = DAILY[mini(streak, DAILY.size()) - 1]
	save.data["daily_last"] = today
	save.data["daily_streak"] = streak
	save.add_cash(reward)
	save.save()
	return {"claimed": true, "day": streak, "reward": reward}
