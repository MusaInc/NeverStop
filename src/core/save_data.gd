extends Node
## The player's offline profile (user://save.json): currency, owned cars and
## their upgrades/paint/wheels, unlocked starts, personal records, lifetime
## stats and challenge progress. No accounts, no network, no tracking.

signal changed

const DEFAULT_PATH := "user://save.json"

## Tests point this at a scratch file so they never touch a player's records.
var path := DEFAULT_PATH
var data := {}
const DEFAULTS := {
	"version": 1,
	"cash": 0,
	"cash_earned": 0,
	"car": "kestrel",
	"owned": ["kestrel"],
	"cars": {},          # id -> {"upgrades": {engine, grip, armour, nitro}, "mods": {ram, plating, ...}, "paint": idx, "wheel": id}
	"paints": [0, 1],    # owned paint indices (CarCatalog.PAINTS)
	"wheels": ["steel"], # owned wheel styles
	"start": "downtown",
	"starts": ["downtown"],
	"best_score": 0,
	"best_time": 0.0,
	"best_heat": 0,
	"best_wrecked": 0,
	"best_near_misses": 0,
	"best_distance": 0.0,
	"runs": 0,
	"total_time": 0.0,
	"total_distance": 0.0,
	"total_wrecked": 0,
	"total_near_misses": 0,
	"total_roadblocks": 0,
	"challenges": {},    # id -> true when complete
	"history": [],       # last 10 runs: {score, time, heat, car}
	"xp": 0,             # career XP (sum of run scores) -> Progression.RANKS
	"tutorial_done": false,
	"total_contracts": 0,
	"daily_last": "",    # YYYY-MM-DD of the last daily bonus
	"daily_streak": 0,
}


func _ready() -> void:
	load_data()


func use_file(p: String) -> void:
	path = p
	load_data()


func load_data() -> void:
	data = DEFAULTS.duplicate(true)
	# The save, or – if it is missing or unreadable (the app killed mid-write
	# on an older build, a bad disk block) – the last good copy.
	for p in [path, path + ".bak"]:
		var parsed = _read(p)
		if parsed is Dictionary:
			for k in parsed:
				data[k] = parsed[k]
			if p != path:
				push_warning("SaveData: %s unreadable, recovered from backup" % path)
			_sanitise()
			return


## A readable file can still hold nonsense (an edited or half-migrated save):
## wrong-typed fields go back to their defaults, the rest is kept (SH-03).
func _sanitise() -> void:
	SafeSave.repair(data, DEFAULTS)
	data["cash"] = maxi(0, int(data["cash"]))
	var owned: Array = []
	for id in data["owned"]:
		if CarCatalog.CARS.has(id) and not owned.has(id):
			owned.append(id)
	if owned.is_empty():
		owned = ["kestrel"]
	data["owned"] = owned
	if not owned.has(data["car"]):
		data["car"] = owned[0]
	if not (data["start"] in data["starts"]):
		data["start"] = "downtown"
	for id in data["cars"].keys():
		if not (data["cars"][id] is Dictionary):
			data["cars"].erase(id)


static func _read(p: String):
	if not FileAccess.file_exists(p):
		return null
	var f := FileAccess.open(p, FileAccess.READ)
	if f == null:
		return null
	var parsed = JSON.parse_string(f.get_as_text())
	return parsed if parsed is Dictionary and not (parsed as Dictionary).is_empty() else null


## Atomic save: write a temp file, check it reads back, keep the previous save
## as .bak, then move the new one into place. A crash or the OS killing the
## app at any point leaves a complete save (or its backup) on disk.
func save() -> void:
	# (SafeSave: read-back check, only a valid file becomes .bak, every rename
	# and copy checked.)
	last_error = SafeSave.write(path, data)
	if last_error != "":
		push_warning("SaveData: save failed – %s; keeping the old save" % last_error)
	changed.emit()


## "" after a good save, else why it failed (Settings can show it).
var last_error := ""


## Settings → Reset everything: a fresh profile (settings are kept).
func reset_profile() -> void:
	data = DEFAULTS.duplicate(true)
	save()


func cash() -> int:
	return int(data["cash"])


func spend(n: int) -> bool:
	if cash() < n:
		return false
	data["cash"] = cash() - n
	save()
	return true


func add_cash(n: int) -> void:
	data["cash"] = cash() + n
	data["cash_earned"] = int(data["cash_earned"]) + n


func owns(car_id: String) -> bool:
	return car_id in data["owned"]


func car_state(car_id: String) -> Dictionary:
	var cs: Dictionary = data["cars"].get(car_id, {})
	if cs.is_empty():
		cs = {"upgrades": {"engine": 0, "grip": 0, "armour": 0, "nitro": 0}, "paint": -1, "wheel": ""}
		data["cars"][car_id] = cs
	return cs


func upgrades(car_id: String) -> Dictionary:
	var u: Dictionary = car_state(car_id)["upgrades"]
	var out := {}
	for k in u:
		out[k] = int(u[k])
	return out


## Workshop mods owned on this car: {key: tier, "rear": fitted dropper}.
func mods(car_id: String) -> Dictionary:
	var cs := car_state(car_id)
	if not cs.has("mods"):
		cs["mods"] = {}
	return cs["mods"]


## The spec a run uses: catalogue + upgrades + Workshop mods + chosen paint/wheels.
func car_spec(car_id: String) -> Dictionary:
	var s := CarCatalog.spec(car_id, upgrades(car_id), mods(car_id))
	var cs := car_state(car_id)
	var pi := int(cs.get("paint", -1))
	if pi >= 0 and pi < CarCatalog.PAINTS.size():
		s["paint"] = CarCatalog.PAINTS[pi][1]
	var w := str(cs.get("wheel", ""))
	if w != "":
		s["wheel"] = w
	return s


## Records a finished run. Returns which records were broken.
func submit_run(r: Dictionary, car_id: String) -> Array:
	var broken: Array = []
	data["runs"] = int(data["runs"]) + 1
	data["total_time"] = float(data["total_time"]) + r["time"]
	data["total_distance"] = float(data["total_distance"]) + r["distance"]
	data["total_wrecked"] = int(data["total_wrecked"]) + r["police_wrecked"]
	data["total_near_misses"] = int(data["total_near_misses"]) + r["near_misses"]
	data["total_roadblocks"] = int(data["total_roadblocks"]) + r["roadblocks"]
	for pair in [["best_score", "score"], ["best_time", "time"], ["best_heat", "max_heat"], ["best_wrecked", "police_wrecked"],
			["best_near_misses", "near_misses"], ["best_distance", "distance"]]:
		if float(r[pair[1]]) > float(data[pair[0]]):
			data[pair[0]] = r[pair[1]]
			broken.append(pair[0])
	add_cash(int(r["currency"]))
	var h: Array = data["history"]
	h.push_front({"score": r["score"], "time": r["time"], "heat": r["max_heat"], "car": car_id})
	while h.size() > 10:
		h.pop_back()
	save()
	return broken


func challenge_done(id: String) -> bool:
	return bool(data["challenges"].get(id, false))


func complete_challenge(id: String, reward: int) -> void:
	if challenge_done(id):
		return
	data["challenges"][id] = true
	add_cash(reward)
	save()
