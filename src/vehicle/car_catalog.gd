class_name CarCatalog
extends RefCounted
## Every drivable vehicle: handling profile (read by Car), look, price, perk,
## upgrade limits and garage stats. Units: m, kg, m/s, m/s² ("engine"/"brake"
## are accelerations at zero speed, so heavier cars don't need retuning),
## spring/damper per kg. Body sizes come from the models themselves
## (BodyDims, written by tools/blender/build_vehicles.py), so the physics
## hull, wheel positions and art always agree.
##
## Ten cars, each good at something different:
##   kestrel   street hatch: forgiving, repairs itself between hits
##   marlin    sport saloon: the all-rounder, near misses pay more
##   scout     rally hatch: long-travel AWD, flies, lands soft, big air pays
##   brute     muscle: torque, loose tail, drift points pay more
##   vanta     sports coupe: sharp and light, longer combo window
##   goliath   lifted pickup: heavy, tall, rams hard
##   warden    armoured 4x4: puncture-proof, very tough
##   halcyon   AWD supercar: fast, planted, quick nitro recharge
##   mammoth   heavy truck: slow, 7 tonnes, flattens police cars
##   stiletto  wedge hypercar: the fastest thing in the city, fragile

const BASE := {
	"mass": 1350.0, "size": Vector3(1.8, 1.3, 4.4), "ride": 0.16, "com_y": 0.42,
	"wheelbase": 2.7, "track": 1.56, "wheel_r": 0.33, "susp_len": 0.32,
	"spring": 34.0, "damper": 2.4, "anti_roll": 0.55,
	"engine": 7.0, "top_speed": 55.0, "brake": 12.0, "gears": 6,
	"grip": 1.35, "grip_front": 1.0, "grip_rear": 1.0, "slide": 0.84, "hb_grip": 0.42,
	"steer_lock": 34.0, "steer_fast": 7.5, "steer_rate": 200.0,
	"yaw_assist": 0.35, "drift_assist": 0.55, "drift_hold": 30.0, "drift_max": 44.0, "drift_push": 1.6,
	"drag": 0.00028, "downforce": 0.01, "air_level": 3.5,
	"durability": 1.0, "drive": "rwd", "nitro": 0.0, "nitro_time": 4.0,
	"body": "marlin", "wheel": "five", "paint": Color(0.7, 0.7, 0.7),
	"price": 0, "class": "Street",
	# Perks (1.0 = none): damage dealt to cars you hit, score multipliers, etc.
	"ram": 1.0, "score_drift": 1.0, "score_air": 1.0, "score_speed": 1.0, "score_near": 1.0,
	"chain_bonus": 0.0, "repair": 0.0, "nitro_regen": 0.02, "puncture_proof": false,
	"engine_sound": "v6",
}

const CARS := {
	"kestrel": {
		"name": "Kestrel", "class": "Street Hatch", "price": 0, "body": "kestrel", "wheel": "steel", "engine_sound": "i4",
		"blurb": "Everybody's first car. Grippy, honest, not very fast.",
		"perk": "PATCH-UP · slowly repairs itself between hits",
		"mass": 1150.0, "engine": 6.2, "top_speed": 50.0, "grip": 1.4, "grip_front": 1.05, "grip_rear": 1.08, "drive": "fwd",
		"steer_lock": 36.0, "durability": 0.9, "paint": Color(0.78, 0.77, 0.73), "com_y": 0.45,
		"repair": 0.012, "caps": {"engine": 3, "grip": 3, "armour": 3, "nitro": 3}, "up_cost": 0.8,
	},
	"marlin": {
		"name": "Marlin GT", "class": "Sport Saloon", "price": 2500, "body": "marlin", "wheel": "five", "engine_sound": "v6",
		"blurb": "Four doors, six cylinders, rear-wheel drive. The all-rounder.",
		"perk": "SMOOTH OPERATOR · near misses pay 1.5×",
		"mass": 1480.0, "engine": 7.4, "top_speed": 59.0, "grip": 1.42, "drive": "rwd", "durability": 1.05,
		"paint": Color(0.1, 0.22, 0.48), "score_near": 1.5, "caps": {"engine": 4, "grip": 4, "armour": 3, "nitro": 3},
	},
	"scout": {
		"name": "Scout RS", "class": "Rally Hatch", "price": 5000, "body": "scout", "wheel": "turbine", "engine_sound": "f6",
		"blurb": "Long-travel suspension, all-wheel drive and a roof scoop. Built for the air.",
		"perk": "BIG AIR · jumps pay 2×, extra air control",
		"mass": 1260.0, "engine": 7.7, "top_speed": 58.0, "grip": 1.46, "drive": "awd", "susp_len": 0.4,
		"spring": 30.0, "damper": 2.7, "air_level": 6.5, "durability": 1.15, "drift_assist": 0.7, "slide": 0.88,
		"steer_lock": 37.0, "com_y": 0.5, "nitro": 0.45, "paint": Color(0.9, 0.42, 0.05), "paint2": Color(0.95, 0.95, 0.95),
		"score_air": 2.0, "caps": {"engine": 4, "grip": 5, "armour": 3, "nitro": 4},
	},
	"brute": {
		"name": "Brute 8", "class": "Muscle", "price": 7500, "body": "brute", "wheel": "deep", "engine_sound": "v8",
		"blurb": "A V8 with a car attached. Huge torque, loose tail, heavy hitter.",
		"perk": "SMOKE SHOW · drifts pay 1.6×",
		"mass": 1720.0, "engine": 8.6, "top_speed": 62.0, "grip": 1.36, "grip_rear": 0.93, "slide": 0.86, "hb_grip": 0.48,
		"drive": "rwd", "durability": 1.35, "drift_assist": 0.65, "drift_push": 2.2, "steer_fast": 7.0,
		"paint": Color(0.55, 0.06, 0.04), "paint2": Color(0.95, 0.95, 0.92), "nitro": 0.75, "ram": 1.2,
		"score_drift": 1.6, "caps": {"engine": 5, "grip": 3, "armour": 4, "nitro": 4},
	},
	"vanta": {
		"name": "Vanta S", "class": "Sports Coupé", "price": 12000, "body": "vanta", "wheel": "blade", "engine_sound": "f6",
		"blurb": "Light, sharp and eager. Turns in like it reads your mind.",
		"perk": "IN THE ZONE · combo window lasts 1.5 s longer",
		"mass": 1290.0, "engine": 8.4, "top_speed": 67.0, "grip": 1.55, "drive": "rwd", "steer_lock": 35.0, "steer_fast": 8.5,
		"steer_rate": 260.0, "yaw_assist": 0.45, "durability": 0.9, "com_y": 0.36,
		"paint": Color(0.92, 0.45, 0.06), "nitro": 0.6, "chain_bonus": 1.5,
		"caps": {"engine": 4, "grip": 5, "armour": 2, "nitro": 4}, "up_cost": 1.2,
	},
	"goliath": {
		"name": "Goliath", "class": "Lifted Pickup", "price": 15000, "body": "goliath", "wheel": "offroad", "engine_sound": "v8",
		"blurb": "Two and a half tonnes on 35-inch tyres. Police cars are speed bumps.",
		"perk": "CRUSHER · rams do 1.8× damage",
		"mass": 2650.0, "engine": 6.6, "top_speed": 55.0, "grip": 1.32, "drive": "awd", "susp_len": 0.46, "spring": 30.0,
		"damper": 2.8, "durability": 2.3, "com_y": 0.78, "anti_roll": 0.95, "steer_lock": 33.0, "steer_fast": 6.2,
		"air_level": 2.6, "nitro": 0.5, "paint": Color(0.08, 0.2, 0.36), "ram": 1.8,
		"caps": {"engine": 4, "grip": 3, "armour": 5, "nitro": 3}, "up_cost": 1.2,
	},
	"warden": {
		"name": "Warden", "class": "Armoured 4x4", "price": 18000, "body": "warden", "wheel": "offroad", "engine_sound": "diesel",
		"blurb": "Armour plate, a bull bar and run-flat tyres. Roadblocks are a suggestion.",
		"perk": "RUN-FLATS · spike strips can't stop it; rams 1.5×",
		"mass": 2900.0, "engine": 6.8, "top_speed": 53.0, "grip": 1.32, "drive": "awd", "steer_lock": 32.0,
		"susp_len": 0.4, "steer_fast": 6.5, "durability": 2.8, "com_y": 0.62, "anti_roll": 0.8,
		"paint": Color(0.22, 0.26, 0.2), "nitro": 0.4, "ram": 1.5, "puncture_proof": true,
		"caps": {"engine": 3, "grip": 3, "armour": 5, "nitro": 3}, "up_cost": 1.2,
	},
	"halcyon": {
		"name": "Halcyon R", "class": "Supercar", "price": 25000, "body": "halcyon", "wheel": "mesh", "engine_sound": "v10",
		"blurb": "Mid-engined, all-wheel drive, faster than the radio can report.",
		"perk": "LAUNCH CONTROL · nitro recharges 2.5× faster",
		"mass": 1420.0, "engine": 9.6, "top_speed": 76.0, "grip": 1.62, "drive": "awd", "steer_fast": 7.0, "downforce": 0.02,
		"durability": 0.95, "com_y": 0.32, "paint": Color(0.88, 0.88, 0.9), "nitro": 0.8,
		"nitro_time": 5.0, "nitro_regen": 0.05, "caps": {"engine": 5, "grip": 4, "armour": 2, "nitro": 5}, "up_cost": 1.5,
	},
	"mammoth": {
		"name": "Mammoth", "class": "Heavy Truck", "price": 30000, "body": "mammoth", "wheel": "steel", "engine_sound": "diesel",
		"blurb": "Seven tonnes of cab-over truck. Slow to get going. Impossible to stop.",
		"perk": "UNSTOPPABLE · rams do 3× damage; shrugs off hits",
		"mass": 6800.0, "engine": 4.5, "top_speed": 45.0, "brake": 9.5, "grip": 1.24, "drive": "awd", "susp_len": 0.42,
		"spring": 36.0, "damper": 2.9, "durability": 4.5, "com_y": 0.95, "anti_roll": 1.0, "steer_lock": 31.0,
		"steer_fast": 5.2, "yaw_assist": 0.3, "drift_assist": 0.35, "air_level": 1.6, "nitro": 0.3,
		"paint": Color(0.85, 0.7, 0.1), "paint2": Color(0.9, 0.9, 0.88), "ram": 3.0,
		"caps": {"engine": 5, "grip": 3, "armour": 5, "nitro": 2}, "up_cost": 1.3,
	},
	"stiletto": {
		"name": "Stiletto", "class": "Hypercar", "price": 45000, "body": "stiletto", "wheel": "blade", "engine_sound": "v10",
		"blurb": "A carbon wedge with a V12 behind your head. Nothing in the city catches it - if you keep it off the walls.",
		"perk": "FLAT OUT · speed points pay 2×, bigger nitro tank",
		"mass": 1380.0, "engine": 10.4, "top_speed": 81.0, "grip": 1.68, "drive": "awd", "steer_fast": 7.2,
		"downforce": 0.028, "drag": 0.0002, "durability": 0.75, "com_y": 0.3, "nitro": 1.0, "nitro_time": 6.0,
		"paint": Color(0.6, 0.85, 0.12), "score_speed": 2.0, "caps": {"engine": 5, "grip": 5, "armour": 1, "nitro": 5},
		"up_cost": 1.8,
	},
}

## Police units (Car specs + AI/pursuit data).
const POLICE := {
	"patrol": {
		"name": "Patrol", "body": "police_patrol", "wheel": "steel", "livery": [Color(0.06, 0.08, 0.14), Color(0.92, 0.94, 0.96)],
		"mass": 1520.0, "engine": 7.0, "top_speed": 54.0, "grip": 1.36, "drive": "rwd", "durability": 1.1, "engine_sound": "v6",
	},
	"interceptor": {
		"name": "Interceptor", "body": "police_interceptor", "wheel": "blade", "livery": [Color(0.04, 0.045, 0.05), Color(0.75, 0.95, 0.15)],
		"mass": 1350.0, "engine": 8.6, "top_speed": 68.0, "grip": 1.5, "drive": "rwd", "durability": 1.0, "com_y": 0.36,
		"engine_sound": "f6",
	},
	"heavy": {
		"name": "Heavy Unit", "body": "police_heavy", "wheel": "offroad", "livery": [Color(0.1, 0.11, 0.13), Color(0.92, 0.94, 0.96)],
		"mass": 2600.0, "engine": 7.4, "top_speed": 56.0, "grip": 1.34, "drive": "awd", "durability": 2.2,
		"susp_len": 0.4, "com_y": 0.62, "anti_roll": 0.8, "ram": 1.3, "engine_sound": "diesel",
	},
}

## Civilian traffic models: body, share of traffic, paint choices.
const CIVILIANS := {
	"civ_compact": {"share": 0.22, "mass": 1050.0, "engine_sound": "i4"},
	"civ_sedan": {"share": 0.24, "mass": 1400.0},
	"civ_taxi": {"share": 0.1, "mass": 1450.0, "paints": [Color(0.95, 0.72, 0.08)]},
	"civ_suv": {"share": 0.16, "mass": 1900.0, "com_y": 0.6, "engine_sound": "diesel"},
	"civ_van": {"share": 0.12, "mass": 2300.0, "com_y": 0.75, "engine_sound": "diesel"},
	"civ_box": {"share": 0.1, "mass": 5200.0, "com_y": 0.9, "anti_roll": 1.0, "engine_sound": "diesel"},
	"civ_bus": {"share": 0.06, "mass": 9000.0, "com_y": 0.9, "anti_roll": 1.0, "engine_sound": "diesel",
		"paints": [Color(0.75, 0.1, 0.08), Color(0.1, 0.35, 0.6), Color(0.15, 0.45, 0.25)]},
}

## Garage upgrades: up to 5 levels each (each car has its own limits), price per level.
const UPGRADES := {
	"engine": {"name": "Engine", "prices": [800, 2000, 4500, 8000, 13000], "per_level": 0.06},
	"grip": {"name": "Tyres", "prices": [600, 1600, 3600, 6500, 10000], "per_level": 0.04},
	"armour": {"name": "Armour", "prices": [700, 1800, 4000, 7000, 11000], "per_level": 0.15},
	"nitro": {"name": "Nitro", "prices": [1200, 2600, 5200, 8500, 12500], "per_level": 0.25},
}
const UPGRADE_KEYS := ["engine", "grip", "armour", "nitro"]

const PAINTS := [
	["Arctic", Color(0.88, 0.88, 0.86), 0], ["Graphite", Color(0.16, 0.17, 0.19), 0],
	["Signal Red", Color(0.62, 0.05, 0.04), 300], ["Deep Blue", Color(0.08, 0.18, 0.45), 300],
	["Solar", Color(0.95, 0.52, 0.06), 500], ["Acid", Color(0.6, 0.85, 0.12), 500],
	["Racing Green", Color(0.06, 0.24, 0.14), 500], ["Violet", Color(0.34, 0.12, 0.5), 800],
	["Gold", Color(0.78, 0.6, 0.22), 1500], ["Midnight", Color(0.03, 0.035, 0.06), 1500],
	["Hot Pink", Color(0.85, 0.12, 0.45), 1200], ["Teal", Color(0.05, 0.45, 0.48), 1200],
]
const WHEELS := [["steel", "Steel", 0], ["five", "Five-Spoke", 400], ["split", "Split", 700],
	["deep", "Deep Dish", 800], ["blade", "Blade", 900], ["turbine", "Turbine", 1000], ["mesh", "Mesh", 1200],
	["offroad", "Off-Road", 1100]]

const ORDER := ["kestrel", "marlin", "scout", "brute", "vanta", "goliath", "warden", "halcyon", "mammoth", "stiletto"]


static func spec(id: String, upgrades := {}) -> Dictionary:
	var s := BASE.duplicate()
	s.merge(CARS.get(id, CARS["kestrel"]), true)
	s["id"] = id
	_fit_body(s)
	var caps := upgrade_caps(id)
	var e := mini(int(upgrades.get("engine", 0)), caps["engine"])
	s["engine"] *= 1.0 + UPGRADES["engine"]["per_level"] * e
	s["top_speed"] *= 1.0 + UPGRADES["engine"]["per_level"] * 0.5 * e
	s["grip"] *= 1.0 + UPGRADES["grip"]["per_level"] * mini(int(upgrades.get("grip", 0)), caps["grip"])
	s["durability"] *= 1.0 + UPGRADES["armour"]["per_level"] * mini(int(upgrades.get("armour", 0)), caps["armour"])
	var n := mini(int(upgrades.get("nitro", 0)), caps["nitro"])
	if n > 0:
		s["nitro"] = maxf(s["nitro"], 0.35) + UPGRADES["nitro"]["per_level"] * n
		s["nitro_time"] += n * 0.8
	return s


static func upgrade_caps(id: String) -> Dictionary:
	var c: Dictionary = CARS.get(id, {}).get("caps", {})
	var out := {}
	for k in UPGRADE_KEYS:
		out[k] = int(c.get(k, 3))
	return out


## Price of the next level of an upgrade on this car.
static func upgrade_price(id: String, key: String, level: int) -> int:
	var prices: Array = UPGRADES[key]["prices"]
	var mult: float = CARS.get(id, {}).get("up_cost", 1.0)
	return int(round(float(prices[mini(level, prices.size() - 1)]) * mult / 50.0) * 50)


static func police_spec(kind: String) -> Dictionary:
	var s := BASE.duplicate()
	s.merge(POLICE[kind], true)
	s["id"] = "police_" + kind
	_fit_body(s)
	s["paint"] = (POLICE[kind]["livery"] as Array)[0]
	s["paint2"] = (POLICE[kind]["livery"] as Array)[1]
	return s


static func civ_spec(body: String, rng: RandomNumberGenerator) -> Dictionary:
	var s := BASE.duplicate()
	s.merge(CIVILIANS[body], true)
	s["id"] = body
	s["body"] = body
	s["wheel"] = "steel"
	s["engine"] = 4.2
	s["top_speed"] = 40.0
	s["durability"] = 1.0
	_fit_body(s)
	var paints: Array = CIVILIANS[body].get("paints", CIV_COLORS)
	s["paint"] = paints[rng.randi() % paints.size()]
	s["paint2"] = CIV_COLORS[rng.randi() % CIV_COLORS.size()].lightened(0.3)
	return s


const CIV_COLORS := [Color(0.8, 0.8, 0.78), Color(0.12, 0.12, 0.13), Color(0.5, 0.06, 0.05), Color(0.14, 0.24, 0.4),
	Color(0.55, 0.57, 0.6), Color(0.72, 0.62, 0.42), Color(0.2, 0.32, 0.26), Color(0.92, 0.9, 0.86), Color(0.35, 0.2, 0.12),
	Color(0.36, 0.42, 0.5), Color(0.6, 0.15, 0.2)]


static func civ_pick(rng: RandomNumberGenerator) -> String:
	var r := rng.randf()
	for k in CIVILIANS:
		r -= float(CIVILIANS[k]["share"])
		if r <= 0.0:
			return k
	return "civ_sedan"


## Size, wheelbase, wheels and ride height from the model's real dimensions.
## Tyres sit flush with the bodywork: the track follows the body's width.
static func _fit_body(s: Dictionary) -> void:
	var d: Dictionary = BodyDims.DIMS.get(str(s["body"]), {})
	if not d.is_empty():
		s["size"] = Vector3(d["W"], float(d["roof"]) - float(d["ride"]) + 0.05, d["L"])
		s["wheelbase"] = d["wb"]
		s["wheel_r"] = d["wheel_r"]
		s["tyre_w"] = d["tyre_w"]
		s["ride"] = d["ride"]
	var tw: float = s.get("tyre_w", 0.26)
	s["track"] = (s["size"] as Vector3).x - tw - 0.05


## Garage bars (0..1) from the handling profile.
static func stats(s: Dictionary) -> Dictionary:
	return {
		"speed": clampf(inverse_lerp(42.0, 90.0, s["top_speed"]), 0.05, 1.0),
		"accel": clampf(inverse_lerp(4.5, 11.0, s["engine"]), 0.05, 1.0),
		"handling": clampf(inverse_lerp(1.15, 1.8, s["grip"] * (s["grip_rear"] + s["grip_front"]) * 0.5), 0.05, 1.0),
		"durability": clampf(inverse_lerp(0.6, 4.8, s["durability"] * pow(s["mass"] / 1400.0, 0.3)), 0.05, 1.0),
	}
