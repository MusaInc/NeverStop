class_name DriveInput
extends Node
## Merges keyboard, gamepad and touch into car controls each physics frame.
## Press to accelerate: GAS pedal (touch), W / Up, or the right trigger.
## Settings → Accelerate → Auto brings back the old always-on throttle.

var car: Car
var enabled := true
var auto_accelerate := false
## Touch writes these (TouchDrive); -1..1 steer, 0..1 the rest.
var touch_steer := 0.0
var touch_gas := 0.0
var touch_brake := 0.0
var touch_handbrake := false
var touch_nitro := false
var touch_active := false
var _steer_smooth := 0.0


func _ready() -> void:
	process_physics_priority = -10  # before the cars read their controls


func _physics_process(dt: float) -> void:
	Prof.begin("input")
	if car == null or not is_instance_valid(car):
		Prof.end("input")
		return
	if not enabled:
		Prof.end("input")
		return  # someone else (autopilot, cinematic) is driving
	var key_steer := Input.get_action_strength("steer_right") - Input.get_action_strength("steer_left")
	var steer := key_steer if absf(key_steer) > absf(touch_steer) else touch_steer
	# Digital keys ramp in (a tap is a small correction, a hold a full turn).
	var digital := absf(key_steer) == 1.0 and not touch_active
	if digital:
		_steer_smooth = move_toward(_steer_smooth, steer, dt * 6.5 if signf(steer) == signf(_steer_smooth) else dt * 10.0)
		steer = _steer_smooth
	else:
		_steer_smooth = steer
	var sens: float = Settings.steer_sensitivity
	steer = clampf(signf(steer) * pow(absf(steer), 1.0 / maxf(sens, 0.3)), -1.0, 1.0)
	var brake := maxf(Input.get_action_strength("brake"), touch_brake)
	var thr := maxf(Input.get_action_strength("accelerate"), touch_gas)
	auto_accelerate = Settings.accelerate == "auto"
	if auto_accelerate:
		thr = maxf(thr, 1.0 if brake < 0.1 else 0.0)
	car.steer = steer
	car.throttle = thr
	car.brake = brake
	car.handbrake = Input.is_action_pressed("handbrake") or touch_handbrake
	car.nitro = Input.is_action_pressed("nitro") or touch_nitro
	Prof.end("input")


