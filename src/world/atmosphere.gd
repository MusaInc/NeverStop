class_name Atmosphere
extends Node3D
## Sky, sun/moon, fog, weather and tonemapping for the whole game.
##
## Time of day: `hour` (0–24). In a live game it runs through a full day in
## DAY_MINUTES real minutes (Settings.time_of_day = "cycle") or holds a fixed
## hour. The sun rises in the east, crosses the south and sets behind the
## strait in the west; after dusk the same light becomes a cool moon.
## Everything that should react reads shared global shader uniforms:
##   sky_top / sky_horizon (linear)  sun_dir  night (0..1)  wetness  rain
## and the city's lamps read `night` via CityWorld.set_night().
##
## Weather: clear, cloudy, rain, storm, fog. "changing" drifts between them
## every few minutes; every parameter eases (no pops). Rain draws streaks
## round the camera (RainFx), wets streets/roofs/water (wetness rises while it
## rains and dries afterwards), storms add lightning (and a thunder signal).
## Captures and tools get a fixed golden hour, clear (`live` = false), unless
## asked for `--time=<h>` / `--weather=<name>`.

signal thunder(delay: float, strength: float)

const ZENITH := Color(0.11, 0.32, 0.72)
const HORIZON := Color(0.6, 0.75, 0.92)
## The default (captures, tools, first launch): late-afternoon golden hour.
const DEFAULT_HOUR := 16.0
const DAY_MINUTES := 16.0
## Sun direction at DEFAULT_HOUR (kept for callers that want the fixed one).
const SUN_ROT := Vector3(-38.0, -112.0, 0.0)
const WEATHERS := ["clear", "cloudy", "rain", "storm", "fog"]
## Per weather: cloud cover, rain, fog, storm (lightning), cloud darkness.
const WEATHER_PARAMS := {
	"clear": {"cloud": 0.38, "rain": 0.0, "fog": 0.0, "storm": 0.0, "dark": 0.0},
	"cloudy": {"cloud": 0.72, "rain": 0.0, "fog": 0.12, "storm": 0.0, "dark": 0.25},
	"rain": {"cloud": 0.92, "rain": 0.65, "fog": 0.35, "storm": 0.0, "dark": 0.7},
	"storm": {"cloud": 1.0, "rain": 1.0, "fog": 0.45, "storm": 1.0, "dark": 1.0},
	"fog": {"cloud": 0.6, "rain": 0.0, "fog": 1.0, "storm": 0.0, "dark": 0.2},
}

var env: Environment
var sun: DirectionalLight3D
var sky_mat: ShaderMaterial
var rain_fx: RainFx
## Runs the clock and weather changes (main sets it for real play).
var live := false
var hour := DEFAULT_HOUR
var weather := "clear"
## Current (eased) weather parameters and derived values other systems read.
var w := WEATHER_PARAMS["clear"].duplicate()
var wetness := 0.0
var night := 0.0
var _flash := 0.0
var _next_bolt := 8.0
var _weather_left := 240.0
var _rng := RandomNumberGenerator.new()
var _sky_t := 0.0
var _world: Node


static func sun_direction() -> Vector3:
	return Basis.from_euler(SUN_ROT * PI / 180.0) * Vector3.BACK


## Sun elevation and azimuth (degrees) for an hour: up at ~05:30, highest
## (70°) at noon in the south, down at ~18:30 in the west.
static func sun_angles(h: float) -> Vector2:
	var el := 70.0 * sin(PI * (h - 5.5) / 13.0)
	if h < 5.5 or h > 18.5:
		# Below the horizon: keep going down smoothly through the night.
		var t := fposmod(h - 18.5, 24.0) / 11.0  # 0 at dusk, 1 at dawn
		el = -40.0 * sin(PI * t)
	var yaw := -112.0 + (h - DEFAULT_HOUR) * 15.0
	return Vector2(el, yaw)


func _ready() -> void:
	add_to_group("atmosphere")  # (homes read `night` to warm their lights)
	_rng.randomize()
	var settings := get_node_or_null("/root/Settings")
	var preset: Dictionary = settings.preset() if settings else {"shadows": true, "glow": true}
	sky_mat = ShaderMaterial.new()
	sky_mat.shader = load("res://src/world/shaders/sky.gdshader")
	var sky := Sky.new()
	sky.sky_material = sky_mat
	sky.radiance_size = Sky.RADIANCE_SIZE_64
	sky.process_mode = Sky.PROCESS_MODE_INCREMENTAL

	env = Environment.new()
	env.background_mode = Environment.BG_SKY
	env.sky = sky
	# Warm sun, cool sky fill: lit faces read gold, shaded faces read blue-violet.
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.ambient_light_energy = 0.62
	env.ambient_light_color = Color(0.56, 0.66, 0.9)
	# Half sky, half "bounce": shaded streets read as cool grey stone and
	# asphalt lit by the sunlit facades around them, not a flat blue.
	env.ambient_light_sky_contribution = 0.38
	env.reflected_light_source = Environment.REFLECTION_SOURCE_SKY
	env.tonemap_mode = Environment.TONE_MAPPER_AGX
	env.tonemap_exposure = 1.0
	env.tonemap_white = 8.0
	env.fog_enabled = true
	env.fog_mode = Environment.FOG_MODE_DEPTH
	env.fog_depth_curve = 1.35
	env.fog_sun_scatter = 0.3
	env.fog_aerial_perspective = 0.8
	env.fog_sky_affect = 0.15
	env.glow_enabled = preset.get("glow", true)
	env.glow_intensity = 0.22
	env.glow_bloom = 0.035
	env.glow_hdr_threshold = 1.0
	env.adjustment_enabled = true
	env.adjustment_saturation = 1.07
	env.adjustment_contrast = 1.1
	env.adjustment_color_correction = grade_lut()
	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)

	sun = DirectionalLight3D.new()
	sun.name = "Sun"
	sun.light_angular_distance = 0.85
	sun.shadow_enabled = preset.get("shadows", true)
	sun.shadow_bias = 0.1
	sun.shadow_normal_bias = 0.8
	sun.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_2_SPLITS
	sun.directional_shadow_max_distance = 220.0
	# Reserve the near cascade for the hero and immediate street furniture.
	# Keep roughly 12 m near the camera in the more detailed cascade.
	sun.directional_shadow_split_1 = 0.055
	sun.directional_shadow_blend_splits = false
	add_child(sun)

	rain_fx = RainFx.new()
	rain_fx.name = "Rain"
	add_child(rain_fx)
	_apply(0.0, true)


## Main calls this once settings and command-line overrides are known.
## Set by --time: captures keep that hour (the title camera's shots don't
## replace it).
var fixed_hour := false


func configure(args: Dictionary, world: Node) -> void:
	_world = world
	var capture := args.has("shot") or args.has("cam")
	live = not capture
	if args.has("time"):
		hour = fposmod(float(args["time"]), 24.0)
		live = false
		fixed_hour = true
	if args.has("weather") and args["weather"] in WEATHERS:
		set_weather(args["weather"], true)
	elif live:
		_from_settings(true)
	if live and _settings():
		_settings().changed.connect(func(): _from_settings(false))
	_apply(0.0, true)


## The Settings autoload (looked up, not named: tool scripts run without it).
func _settings() -> Node:
	return get_node_or_null("/root/Settings") if is_inside_tree() else null


func _from_settings(instant: bool) -> void:
	var st := _settings()
	if st == null:
		return
	match st.time_of_day:
		"day":
			hour = 13.0
		"sunset":
			hour = 17.9
		"night":
			hour = 23.0
	if st.weather in WEATHERS:
		set_weather(st.weather, instant)
	elif not weather in WEATHERS or instant:
		set_weather("clear", instant)


func set_weather(name: String, instant := false) -> void:
	weather = name
	_weather_left = _rng.randf_range(150.0, 320.0)
	if instant:
		w = WEATHER_PARAMS[name].duplicate()
		wetness = clampf(w["rain"] * 1.2, 0.0, 1.0)


func _process(dt: float) -> void:
	var st := _settings() if live else null
	if st:
		if st.time_of_day == "cycle":
			hour = fposmod(hour + dt * 24.0 / (DAY_MINUTES * 60.0), 24.0)
		if st.weather == "changing":
			_weather_left -= dt
			if _weather_left <= 0.0:
				set_weather(_next_weather())
	_apply(dt, false)


## Mostly fair: clear and cloudy most of the time, rain now and then, the
## odd storm or fog bank (fog favours the night and early morning).
func _next_weather() -> String:
	var foggy := 0.12 if hour < 9.0 or hour > 21.0 else 0.04
	var opts := {"clear": 0.4, "cloudy": 0.28, "rain": 0.18, "storm": 0.08, "fog": foggy}
	var total := 0.0
	for k in opts:
		total += opts[k] if k != weather else 0.0
	var x := _rng.randf() * total
	for k in opts:
		if k == weather:
			continue
		x -= opts[k]
		if x <= 0.0:
			return k
	return "clear"


func _apply(dt: float, instant: bool) -> void:
	# Ease the weather towards its target (~25 s for most of the change).
	var target: Dictionary = WEATHER_PARAMS.get(weather, WEATHER_PARAMS["clear"])
	var k := 1.0 if instant else 1.0 - exp(-dt / 9.0)
	for key in w:
		w[key] = lerpf(w[key], target[key], k)
	# Streets soak in a minute of rain and take a few minutes to dry.
	var wet_to := clampf(float(w["rain"]) * 1.3, 0.0, 1.0)
	if not instant:
		var rate := 1.0 / 45.0 if wet_to > wetness else 1.0 / 200.0
		wetness = move_toward(wetness, wet_to, rate * dt)
	# Lightning: a bright double flicker every 6–20 s in a storm.
	if float(w["storm"]) > 0.5 and live:
		_next_bolt -= dt
		if _next_bolt <= 0.0:
			_next_bolt = _rng.randf_range(6.0, 20.0)
			_flash = 1.0
			thunder.emit(_rng.randf_range(0.6, 3.0), _rng.randf_range(0.5, 1.0))
	_flash = maxf(_flash - dt * 3.2, 0.0)
	var fl := _flash * (0.6 + 0.4 * sin(_flash * 40.0)) if _flash > 0.0 else 0.0

	var ang := sun_angles(hour)
	var el := ang.x
	var overcast := smoothstep(0.55, 1.0, float(w["cloud"]))
	var fog := float(w["fog"])
	night = 1.0 - smoothstep(-8.0, 3.0, el)
	var lamps := maxf(night, overcast * 0.35 * float(w["dark"]))

	# --- light: the sun above -3°, the moon below.
	var day_light := smoothstep(-3.0, 8.0, el)
	if el > -3.0:
		sun.rotation_degrees = Vector3(-maxf(el, 1.5), ang.y, 0.0)
		sun.light_color = _ramp(el, [[0.0, Color(1.0, 0.5, 0.26)], [8.0, Color(1.0, 0.72, 0.48)],
			[25.0, Color(1.0, 0.8, 0.58)], [60.0, Color(1.0, 0.9, 0.76)]])
		sun.light_energy = lerpf(0.0, 1.0, day_light) * _rampf(el, [[0.0, 1.3], [10.0, 1.8], [25.0, 2.1], [60.0, 2.25]])
		sky_mat.set_shader_parameter("sun_glow", 1.0)
		sky_mat.set_shader_parameter("disc_size", 0.9993)
		sky_mat.set_shader_parameter("disc_k", 6.0)
		sky_mat.set_shader_parameter("sun_tint", sun.light_color)
	else:
		# Moon: high in the south-east, cool and dim.
		sun.rotation_degrees = Vector3(-42.0, 150.0, 0.0)
		sun.light_color = Color(0.7, 0.76, 0.95)
		sun.light_energy = 0.45 * smoothstep(-3.0, -12.0, el)
		sky_mat.set_shader_parameter("sun_glow", 0.25)
		sky_mat.set_shader_parameter("disc_size", 0.99955)
		sky_mat.set_shader_parameter("disc_k", 2.2)
		sky_mat.set_shader_parameter("sun_tint", Color(0.8, 0.85, 1.0))
	sun.light_energy *= 1.0 - 0.8 * overcast
	sun.shadow_opacity = 1.0 - 0.7 * overcast

	# --- sky colours by sun height, greyed by cloud.
	var zen := _ramp(el, [[-18.0, Color(0.012, 0.02, 0.05)], [-6.0, Color(0.07, 0.1, 0.25)],
		[0.0, Color(0.15, 0.22, 0.45)], [8.0, Color(0.17, 0.32, 0.62)], [25.0, ZENITH], [60.0, Color(0.13, 0.37, 0.78)]])
	var hor := _ramp(el, [[-18.0, Color(0.04, 0.06, 0.1)], [-6.0, Color(0.36, 0.3, 0.4)],
		[0.0, Color(0.95, 0.6, 0.42)], [8.0, Color(0.88, 0.78, 0.72)], [25.0, HORIZON], [60.0, Color(0.6, 0.76, 0.93)]])
	var haze := _ramp(el, [[-18.0, Color(0.05, 0.06, 0.1)], [-6.0, Color(0.5, 0.3, 0.32)],
		[0.0, Color(1.0, 0.5, 0.25)], [8.0, Color(1.0, 0.62, 0.38)], [25.0, Color(1.0, 0.66, 0.42)],
		[60.0, Color(0.95, 0.85, 0.75)]])
	var grey := 0.3 + 0.55 * day_light
	var grey_c := Color(grey * 0.92, grey * 0.95, grey) * lerpf(1.0, 0.7, float(w["dark"]))
	zen = zen.lerp(grey_c * 0.85, overcast * 0.8)
	hor = hor.lerp(grey_c, overcast * 0.75)
	haze = haze.lerp(grey_c, overcast * 0.85)
	zen = zen.lerp(Color(0.8, 0.85, 1.0), fl * 0.6)
	hor = hor.lerp(Color(0.8, 0.85, 1.0), fl * 0.6)
	# The sky shader is radiance-mapped: update it a few times a second, not
	# every frame (it changes slowly), except for lightning.
	_sky_t -= dt
	if _sky_t <= 0.0 or instant or fl > 0.0:
		_sky_t = 0.25
		sky_mat.set_shader_parameter("zenith", zen)
		sky_mat.set_shader_parameter("horizon", hor)
		sky_mat.set_shader_parameter("haze", haze)
		sky_mat.set_shader_parameter("ground", hor.darkened(0.6))
		var cl := _ramp(el, [[-12.0, Color(0.1, 0.12, 0.18)], [-3.0, Color(0.55, 0.38, 0.4)],
			[3.0, Color(1.0, 0.62, 0.45)], [15.0, Color(1.0, 0.86, 0.72)], [40.0, Color(1.0, 0.97, 0.94)]])
		var cs := _ramp(el, [[-12.0, Color(0.04, 0.05, 0.08)], [-3.0, Color(0.25, 0.22, 0.3)],
			[10.0, Color(0.56, 0.55, 0.64)], [40.0, Color(0.66, 0.68, 0.74)]])
		sky_mat.set_shader_parameter("cloud_lit", cl.lerp(grey_c, overcast * 0.6))
		sky_mat.set_shader_parameter("cloud_shade", cs.lerp(grey_c * 0.6, overcast * 0.6))
		sky_mat.set_shader_parameter("cloud_cover", w["cloud"])
		sky_mat.set_shader_parameter("cloud_dark", w["dark"])
		sky_mat.set_shader_parameter("stars", night * (1.0 - overcast) * (1.0 - fog))
		sky_mat.set_shader_parameter("flash", fl)

	# --- ambient, exposure, fog.
	env.ambient_light_energy = _rampf(el, [[-15.0, 0.5], [-4.0, 0.5], [2.0, 0.5], [20.0, 0.56]]) \
		* (1.0 + 0.25 * overcast) + fl * 2.0
	# The non-sky share: light bounced off sunlit stone (warm-neutral by day,
	# dusky at sunset, moonlit blue at night).
	env.ambient_light_color = _ramp(el, [[-10.0, Color(0.42, 0.47, 0.64)], [2.0, Color(0.7, 0.6, 0.62)],
		[15.0, Color(0.72, 0.73, 0.82)], [40.0, Color(0.72, 0.75, 0.85)]]).lerp(Color(0.74, 0.75, 0.78), overcast * 0.6)
	env.tonemap_exposure = lerpf(1.0, 1.5, night) * lerpf(1.0, 1.12, overcast)
	# Depth fog only: a clear near field, subtle blue-grey middle distance,
	# and skyline silhouettes merging with the horizon. Rooftop views get a
	# modest visibility lift; no volume textures, raymarching or extra lights.
	var cam := get_viewport().get_camera_3d() if is_inside_tree() else null
	var alt := clampf((cam.global_position.y - 40.0) / 200.0, 0.0, 1.0) if cam else 0.0
	# Blue aerial perspective: distance fades buildings gradually into the
	# atmosphere (which also takes their contrast), near things stay crisp.
	env.fog_depth_begin = lerpf(70.0, 12.0, fog) * (1.0 + 0.8 * alt * (1.0 - fog))
	env.fog_depth_end = lerpf(1600.0, 520.0, fog) * (1.0 + 0.35 * alt * (1.0 - fog))
	env.fog_density = lerpf(0.82, 0.97, fog) * (1.0 - 0.12 * alt * (1.0 - fog))
	env.fog_light_color = hor.lerp(Color(0.52, 0.66, 0.86), 0.5 * day_light).lerp(grey_c * 1.05, overcast * 0.5)
	env.fog_light_energy = lerpf(1.0, 0.55, night)
	env.fog_sun_scatter = 0.3 * day_light * (1.0 - overcast)
	# Soft bloom: by day only the brightest sunlit glass and sky blooms.
	env.glow_intensity = lerpf(0.34, 0.42, night)
	env.glow_hdr_threshold = lerpf(1.05, 1.0, night)

	# --- shared shader inputs.
	var top_l := zen.srgb_to_linear()
	var hor_l := hor.srgb_to_linear()
	RenderingServer.global_shader_parameter_set("sky_top", Vector3(top_l.r, top_l.g, top_l.b))
	RenderingServer.global_shader_parameter_set("sky_horizon", Vector3(hor_l.r, hor_l.g, hor_l.b))
	RenderingServer.global_shader_parameter_set("sun_dir", sun.global_basis * Vector3.BACK)
	RenderingServer.global_shader_parameter_set("night", lamps)
	RenderingServer.global_shader_parameter_set("wetness", wetness)
	RenderingServer.global_shader_parameter_set("rain", w["rain"])
	if _world and _world.has_method("set_night"):
		_world.set_night(lamps)
	rain_fx.set_rain(float(w["rain"]), hor_l, lamps)


## Sun height → colour, piecewise linear over [[elevation, Color], ...].
static func _ramp(x: float, keys: Array) -> Color:
	if x <= keys[0][0]:
		return keys[0][1]
	for i in keys.size() - 1:
		if x <= keys[i + 1][0]:
			var t := (x - float(keys[i][0])) / (float(keys[i + 1][0]) - float(keys[i][0]))
			return (keys[i][1] as Color).lerp(keys[i + 1][1], t)
	return keys[-1][1]


static func _rampf(x: float, keys: Array) -> float:
	if x <= keys[0][0]:
		return keys[0][1]
	for i in keys.size() - 1:
		if x <= keys[i + 1][0]:
			var t := (x - float(keys[i][0])) / (float(keys[i + 1][0]) - float(keys[i][0]))
			return lerpf(keys[i][1], keys[i + 1][1], t)
	return keys[-1][1]


## CitySwing's grade, as a 3D LUT: cool, slightly lifted shadows, warm
## highlights, a gentle S-curve and richer mid saturation. Built once (17³).
static func grade_lut() -> ImageTexture3D:
	const N := 17
	var layers: Array[Image] = []
	for b in N:
		var img := Image.create(N, N, false, Image.FORMAT_RGB8)
		for g in N:
			for r in N:
				img.set_pixel(r, g, grade(Color(r / (N - 1.0), g / (N - 1.0), b / (N - 1.0))))
		layers.append(img)
	var tex := ImageTexture3D.new()
	tex.create(Image.FORMAT_RGB8, N, N, N, false, layers)
	return tex


static func grade(c: Color) -> Color:
	var l := 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b
	# S-curve on luminance (smoothstep blended 35%), applied as a ratio.
	var s := lerpf(l, l * l * (3.0 - 2.0 * l), 0.35)
	var k := s / maxf(l, 0.0001)
	var o := Color(c.r * k, c.g * k, c.b * k)
	# Split tone: shadows towards blue-violet, highlights towards warm gold.
	var sh := clampf(1.0 - s * 2.2, 0.0, 1.0)
	var hi := clampf((s - 0.55) * 2.2, 0.0, 1.0)
	o += Color(-0.01, 0.0, 0.022) * sh + Color(0.03, 0.012, -0.03) * hi
	# Mid saturation boost (fades out in deep shadow and near-white).
	var ol := 0.2126 * o.r + 0.7152 * o.g + 0.0722 * o.b
	var sat := 1.0 + 0.12 * (1.0 - absf(ol * 2.0 - 1.0))
	o = Color(ol + (o.r - ol) * sat, ol + (o.g - ol) * sat, ol + (o.b - ol) * sat)
	return Color(clampf(o.r, 0.0, 1.0), clampf(o.g, 0.0, 1.0), clampf(o.b, 0.0, 1.0))
