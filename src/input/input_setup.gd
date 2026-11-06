extends Node
## Registers keyboard and gamepad bindings in code. Touch input is handled by
## TouchDrive, which writes into DriveInput directly (no fake key presses).

const BINDINGS := {
	"accelerate": [[KEY_W, KEY_UP], JOY_AXIS_TRIGGER_RIGHT, 1.0],
	"brake": [[KEY_S, KEY_DOWN], JOY_AXIS_TRIGGER_LEFT, 1.0],
	"steer_left": [[KEY_A, KEY_LEFT], JOY_AXIS_LEFT_X, -1.0],
	"steer_right": [[KEY_D, KEY_RIGHT], JOY_AXIS_LEFT_X, 1.0],
	"handbrake": [[KEY_SPACE], JOY_BUTTON_A],
	"nitro": [[KEY_SHIFT], JOY_BUTTON_X],
	"recover": [[KEY_R], JOY_BUTTON_Y],
	"camera": [[KEY_C], JOY_BUTTON_RIGHT_SHOULDER],
	"pause": [[KEY_ESCAPE, KEY_P], JOY_BUTTON_START],
	"toggle_debug": [[KEY_F3], JOY_BUTTON_BACK],
}


func _ready() -> void:
	for action in BINDINGS:
		if not InputMap.has_action(action):
			InputMap.add_action(action, 0.12)
		var b: Array = BINDINGS[action]
		for k in b[0]:
			var key := InputEventKey.new()
			key.physical_keycode = k
			InputMap.action_add_event(action, key)
		if b.size() == 3:
			var axis := InputEventJoypadMotion.new()
			axis.axis = b[1]
			axis.axis_value = b[2]
			InputMap.action_add_event(action, axis)
		else:
			var btn := InputEventJoypadButton.new()
			btn.button_index = b[1]
			InputMap.action_add_event(action, btn)
	# Menus are GUI controls (mouse events): let taps emulate the mouse.
	if DisplayServer.is_touchscreen_available():
		Input.emulate_mouse_from_touch = true
