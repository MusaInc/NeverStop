class_name CarCatalog
extends RefCounted
## Every drivable vehicle: handling profile (read by Car), look, price and
## garage stats. Units: m, kg, m/s, m/s² ("engine"/"brake" are accelerations
## at zero speed, so heavier cars don't need retuning), spring/damper per kg.
##
## Handling profiles are deliberately distinct:
##   kestrel  forgiving FWD hatch: grippy front, safe, slow
##   marlin   balanced RWD saloon: the all-rounder
##   brute    muscle: huge torque, loose rear, heavy, drifts on throttle
##   vanta    sports coupe: sharp turn-in, light, nimble
##   halcyon  AWD supercar: fastest, planted, nitro-ready
##   warden   armoured 4x4: slow, enormous mass and durability – a battering ram

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
}

const CARS := {
	"kestrel": {
		"name": "Kestrel", "class": "Street", "price": 0, "body": "kestrel", "wheel": "steel",
		"blurb": "Everybody's first car. Grippy, honest, not very fast.",
		"mass": 1150.0, "size": Vector3(1.78, 1.45, 4.0), "wheelbase": 2.56, "track": 1.5, "wheel_r": 0.31,
		"engine": 6.2, "top_speed": 50.0, "grip": 1.4, "grip_front": 1.05, "grip_rear": 1.08, "drive": "fwd",
		"steer_lock": 36.0, "durability": 0.9, "paint": Color(0.78, 0.77, 0.73), "com_y": 0.45,
	},
	"marlin": {
		"name": "Marlin GT", "class": "Sport Saloon", "price": 2500, "body": "marlin", "wheel": "five",
		"blurb": "Four doors, six cylinders, rear-wheel drive. The all-rounder.",
		"mass": 1480.0, "size": Vector3(1.86, 1.38, 4.78), "wheelbase": 2.86, "track": 1.6, "wheel_r": 0.34,
		"engine": 7.4, "top_speed": 59.0, "grip": 1.42, "drive": "rwd", "durability": 1.05,
		"paint": Color(0.1, 0.22, 0.48),
	},
	"brute": {
		"name": "Brute 8", "class": "Muscle", "price": 6000, "body": "brute", "wheel": "split",
		"blurb": "A V8 with a car attached. Huge torque, loose tail, heavy hitter.",
		"mass": 1720.0, "size": Vector3(1.94, 1.3, 4.88), "wheelbase": 2.88, "track": 1.64, "wheel_r": 0.35,
		"engine": 8.6, "top_speed": 62.0, "grip": 1.36, "grip_rear": 0.93, "slide": 0.86, "hb_grip": 0.48,
		"drive": "rwd", "durability": 1.35, "drift_assist": 0.65, "drift_push": 2.2, "steer_fast": 7.0,
		"paint": Color(0.55, 0.06, 0.04), "nitro": 0.5,
	},
	"vanta": {
		"name": "Vanta S", "class": "Sports", "price": 12000, "body": "vanta", "wheel": "blade",
		"blurb": "Light, sharp and eager. Turns in like it reads your mind.",
		"mass": 1290.0, "size": Vector3(1.9, 1.24, 4.45), "wheelbase": 2.6, "track": 1.62, "wheel_r": 0.34,
		"engine": 8.4, "top_speed": 67.0, "grip": 1.55, "drive": "rwd", "steer_lock": 35.0, "steer_fast": 8.5,
		"steer_rate": 260.0, "yaw_assist": 0.45, "durability": 0.9, "ride": 0.12, "com_y": 0.36,
		"paint": Color(0.92, 0.45, 0.06), "nitro": 0.6,
	},
	"halcyon": {
		"name": "Halcyon R", "class": "Supercar", "price": 25000, "body": "halcyon", "wheel": "mesh",
		"blurb": "Mid-engined, all-wheel drive, faster than the radio can report.",
		"mass": 1420.0, "size": Vector3(2.02, 1.1, 4.6), "wheelbase": 2.7, "track": 1.7, "wheel_r": 0.35,
		"engine": 9.6, "top_speed": 76.0, "grip": 1.62, "drive": "awd", "steer_fast": 7.0, "downforce": 0.02,
		"durability": 0.95, "ride": 0.1, "com_y": 0.32, "paint": Color(0.88, 0.88, 0.9), "nitro": 0.8,
		"nitro_time": 5.0,
	},
	"warden": {
		"name": "Warden", "class": "Armoured 4x4", "price": 18000, "body": "warden", "wheel": "steel",
		"blurb": "Armour plate and a winch bumper. Roadblocks are a suggestion.",
		"mass": 2900.0, "size": Vector3(2.06, 1.8, 4.95), "wheelbase": 2.96, "track": 1.74, "wheel_r": 0.43,
		"susp_len": 0.4, "engine": 6.8, "top_speed": 53.0, "grip": 1.32, "drive": "awd", "steer_lock": 32.0,
		"steer_fast": 6.5, "durability": 2.6, "ride": 0.32, "com_y": 0.62, "anti_roll": 0.8,
		"paint": Color(0.22, 0.26, 0.2), "nitro": 0.4,
	},
}

## Police units (Car specs + AI/pursuit data).
const POLICE := {
	"patrol": {
		"name": "Patrol", "body": "police_patrol", "wheel": "steel", "livery": [Color(0.06, 0.08, 0.14), Color(0.92, 0.94, 0.96)],
		"mass": 1520.0, "size": Vector3(1.86, 1.38, 4.78), "wheelbase": 2.86, "track": 1.6, "wheel_r": 0.34,
		"engine": 7.0, "top_speed": 54.0, "grip": 1.36, "drive": "rwd", "durability": 1.1,
	},
	"interceptor": {
		"name": "Interceptor", "body": "police_interceptor", "wheel": "blade", "livery": [Color(0.04, 0.045, 0.05), Color(0.75, 0.95, 0.15)],
		"mass": 1350.0, "size": Vector3(1.9, 1.24, 4.45), "wheelbase": 2.6, "track": 1.62, "wheel_r": 0.34,
		"engine": 8.6, "top_speed": 68.0, "grip": 1.5, "drive": "rwd", "durability": 1.0, "ride": 0.12, "com_y": 0.36,
	},
	"heavy": {
		"name": "Heavy Unit", "body": "police_heavy", "wheel": "steel", "livery": [Color(0.1, 0.11, 0.13), Color(0.92, 0.94, 0.96)],
		"mass": 2600.0, "size": Vector3(2.06, 1.8, 4.95), "wheelbase": 2.96, "track": 1.74, "wheel_r": 0.43,
		"susp_len": 0.4, "engine": 7.4, "top_speed": 56.0, "grip": 1.34, "drive": "awd", "durability": 2.2,
		"ride": 0.32, "com_y": 0.62, "anti_roll": 0.8,
	},
}

## Garage upgrades: level 0..3 each, price per level.
const UPGRADES := {
	"engine": {"name": "Engine", "prices": [800, 2000, 4500], "per_level": 0.06},
	"grip": {"name": "Tyres", "prices": [600, 1600, 3600], "per_level": 0.04},
	"armour": {"name": "Armour", "prices": [700, 1800, 4000], "per_level": 0.15},
	"nitro": {"name": "Nitro", "prices": [1200, 2600, 5200], "per_level": 0.25},
}

const PAINTS := [
	["Arctic", Color(0.88, 0.88, 0.86), 0], ["Graphite", Color(0.16, 0.17, 0.19), 0],
	["Signal Red", Color(0.62, 0.05, 0.04), 300], ["Deep Blue", Color(0.08, 0.18, 0.45), 300],
	["Solar", Color(0.95, 0.52, 0.06), 500], ["Acid", Color(0.6, 0.85, 0.12), 500],
	["Racing Green", Color(0.06, 0.24, 0.14), 500], ["Violet", Color(0.34, 0.12, 0.5), 800],
	["Gold", Color(0.78, 0.6, 0.22), 1500], ["Midnight", Color(0.03, 0.035, 0.06), 1500],
]
const WHEELS := [["steel", "Steel", 0], ["five", "Five-Spoke", 400], ["split", "Split", 700],
	["blade", "Blade", 900], ["mesh", "Mesh", 1200]]

const ORDER := ["kestrel", "marlin", "brute", "vanta", "warden", "halcyon"]


static func spec(id: String, upgrades := {}) -> Dictionary:
	var s := BASE.duplicate()
	s.merge(CARS.get(id, CARS["kestrel"]), true)
	s["id"] = id
	var e := int(upgrades.get("engine", 0))
	s["engine"] *= 1.0 + UPGRADES["engine"]["per_level"] * e
	s["top_speed"] *= 1.0 + UPGRADES["engine"]["per_level"] * 0.5 * e
	s["grip"] *= 1.0 + UPGRADES["grip"]["per_level"] * int(upgrades.get("grip", 0))
	s["durability"] *= 1.0 + UPGRADES["armour"]["per_level"] * int(upgrades.get("armour", 0))
	var n := int(upgrades.get("nitro", 0))
	if n > 0:
		s["nitro"] = maxf(s["nitro"], 0.35) + UPGRADES["nitro"]["per_level"] * n
		s["nitro_time"] += n * 0.8
	return s


static func police_spec(kind: String) -> Dictionary:
	var s := BASE.duplicate()
	s.merge(POLICE[kind], true)
	s["id"] = "police_" + kind
	s["paint"] = (POLICE[kind]["livery"] as Array)[0]
	s["paint2"] = (POLICE[kind]["livery"] as Array)[1]
	return s


## Garage bars (0..1) from the handling profile.
static func stats(s: Dictionary) -> Dictionary:
	return {
		"speed": clampf(inverse_lerp(45.0, 80.0, s["top_speed"]), 0.05, 1.0),
		"accel": clampf(inverse_lerp(5.0, 10.5, s["engine"]), 0.05, 1.0),
		"handling": clampf(inverse_lerp(1.2, 1.75, s["grip"] * (s["grip_rear"] + s["grip_front"]) * 0.5), 0.05, 1.0),
		"durability": clampf(inverse_lerp(0.6, 3.0, s["durability"]), 0.05, 1.0),
	}
