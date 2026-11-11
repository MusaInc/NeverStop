extends Node
## Player settings + graphics quality presets (user://settings.cfg).

signal changed

const PATH := "user://settings.cfg"

enum Quality { LOW, MEDIUM, HIGH }

## view_distance: city chunk streaming; props/traffic: density scales (the
## world's parked cars and street furniture); cars_near: how many vehicles get
## full physics before the pursuit downgrades the farthest to a lighter tier.
const PRESETS := {
	Quality.LOW: {
		"fps": 30, "render_scale": 0.8, "shadows": false, "view_distance": 650.0, "fsr": true, "shadow_map": 2048,
		"msaa": Viewport.MSAA_DISABLED, "fog": true, "props": 0.5, "traffic": 0.5, "glow": false,
		"civilians": 14, "cars_near": 12, "debris": 24, "lights": 2,
	},
	Quality.MEDIUM: {
		"fps": 60, "render_scale": 1.0, "shadows": true, "view_distance": 900.0, "fsr": false, "shadow_map": 4096,
		"msaa": Viewport.MSAA_4X, "fog": true, "props": 0.8, "traffic": 0.75, "glow": true,
		"civilians": 22, "cars_near": 18, "debris": 48, "lights": 4,
	},
	Quality.HIGH: {
		"fps": 60, "render_scale": 1.0, "shadows": true, "view_distance": 1200.0, "fsr": false, "shadow_map": 4096,
		"msaa": Viewport.MSAA_4X, "fog": true, "props": 1.0, "traffic": 1.0, "glow": true,
		"civilians": 30, "cars_near": 24, "debris": 80, "lights": 6,
	},
}

const VERSION := 1
var quality: int = Quality.MEDIUM
var haptics := true
var show_perf := false
## Steering: "zones" (hold left/right halves of the left side), "wheel"
## (drag a virtual wheel), "tilt" (accelerometer).
var steer_mode := "zones"
var steer_sensitivity := 1.0
## "pedal": press GAS to go (default). "auto": the car accelerates by itself.
var accelerate := "pedal"
## Right thumb: "stick" (smart analog – press = gas, drag up = NOS, down =
## brake/reverse, sideways = drift) or "pedals" (GAS / BRAKE / DRIFT / NOS).
var right_mode := "stick"
## Camera distance: 0 near, 1 normal, 2 far.
var camera_distance := 1
var music_volume := 0.5
var sfx_volume := 1.0
var look := "clean"
## Sky: "cycle", or fixed "day" / "sunset" / "night".
var time_of_day := "cycle"
var weather := "changing"
var reduce_motion := false   # accessibility: no shake, no slow-mo FOV punches
var high_contrast_hud := false


func _ready() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(PATH) == OK:
		quality = cfg.get_value("gfx", "quality", quality)
		show_perf = cfg.get_value("gfx", "show_perf", show_perf)
		time_of_day = cfg.get_value("gfx", "time_of_day", time_of_day)
		weather = cfg.get_value("gfx", "weather", weather)
		haptics = cfg.get_value("input", "haptics", haptics)
		steer_mode = cfg.get_value("input", "steer_mode", steer_mode)
		steer_sensitivity = cfg.get_value("input", "steer_sensitivity", steer_sensitivity)
		accelerate = cfg.get_value("input", "accelerate", accelerate)
		right_mode = cfg.get_value("input", "right_mode", right_mode)
		camera_distance = cfg.get_value("input", "camera_distance", camera_distance)
		music_volume = cfg.get_value("audio", "music", music_volume)
		sfx_volume = cfg.get_value("audio", "sfx", sfx_volume)
		reduce_motion = cfg.get_value("access", "reduce_motion", reduce_motion)
		high_contrast_hud = cfg.get_value("access", "high_contrast_hud", high_contrast_hud)
	apply()


func preset() -> Dictionary:
	return PRESETS[quality]


func apply() -> void:
	var p := preset()
	Engine.max_fps = p["fps"]
	var vp := get_viewport()
	if vp:
		# Full resolution on Medium/High (the old 85 % + bilinear upscale was
		# what made phones look soft); Low upscales with FSR, not bilinear.
		vp.scaling_3d_scale = p["render_scale"]
		vp.scaling_3d_mode = Viewport.SCALING_3D_MODE_FSR if p.get("fsr", false) and p["render_scale"] < 1.0 \
			else Viewport.SCALING_3D_MODE_BILINEAR
		vp.msaa_3d = p["msaa"]
		# Sharper anisotropic filtering of textures seen at grazing angles (roads).
		vp.anisotropic_filtering_level = Viewport.ANISOTROPY_8X if quality != Quality.LOW else Viewport.ANISOTROPY_2X
		RenderingServer.directional_shadow_atlas_set_size(int(p.get("shadow_map", 2048)), true)
	changed.emit()


func save() -> void:
	var cfg := ConfigFile.new()
	cfg.set_value("gfx", "quality", quality)
	cfg.set_value("gfx", "show_perf", show_perf)
	cfg.set_value("gfx", "time_of_day", time_of_day)
	cfg.set_value("gfx", "weather", weather)
	cfg.set_value("input", "haptics", haptics)
	cfg.set_value("input", "steer_mode", steer_mode)
	cfg.set_value("input", "steer_sensitivity", steer_sensitivity)
	cfg.set_value("input", "accelerate", accelerate)
	cfg.set_value("input", "right_mode", right_mode)
	cfg.set_value("input", "camera_distance", camera_distance)
	cfg.set_value("audio", "music", music_volume)
	cfg.set_value("audio", "sfx", sfx_volume)
	cfg.set_value("access", "reduce_motion", reduce_motion)
	cfg.set_value("access", "high_contrast_hud", high_contrast_hud)
	cfg.set_value("meta", "version", VERSION)
	cfg.save(PATH)
	apply()


func haptic(ms: int, amplitude: float = 0.5) -> void:
	if haptics and OS.has_feature("mobile"):
		Input.vibrate_handheld(ms, amplitude)
