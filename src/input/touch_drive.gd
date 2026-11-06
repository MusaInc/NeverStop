class_name TouchDrive
extends Control
## iPhone driving controls (landscape). The car accelerates by itself.
##
##  * Steering (left 45% of the screen), three modes (Settings.steer_mode):
##      "zones"  default: put a thumb down anywhere on the left side and slide
##               it – steering is the horizontal offset from where it landed
##               (analog, full lock at ~80 px). Lift = centre.
##      "buttons" two big ◀ ▶ pads, bottom-left (digital, ramped by DriveInput).
##      "tilt"   tip the phone like a wheel (accelerometer).
##  * Right side: BRAKE (hold; held at a standstill = reverse), DRIFT
##    (handbrake), NITRO when the car has it.
##  * Each touch belongs to the control it started on (index ownership), so
##    sliding a steering thumb across the screen never presses BRAKE.
##  * Pause: top-left chip.

signal pause_pressed

var input: DriveInput
var car: Car
var steer_mode := "zones"
var _steer_touch := -1
var _steer_origin := Vector2.ZERO
var _steer_pos := Vector2.ZERO
var _btn_touch := {}           # touch index -> button name
var _pressed := {}             # button -> true
var _rects := {}
const FULL_LOCK_PX := 80.0


func _ready() -> void:
	set_anchors_preset(PRESET_FULL_RECT)
	mouse_filter = MOUSE_FILTER_IGNORE
	steer_mode = Settings.steer_mode


func _layout() -> void:
	var vp := get_viewport_rect().size
	var sa := _safe(vp)
	var r := 62.0
	_rects["brake"] = Rect2(sa.end.x - r * 2.0 - 8, sa.end.y - r * 2.0 - 8, r * 2.0, r * 2.0)
	_rects["drift"] = Rect2(sa.end.x - r * 4.0 - 26, sa.end.y - r * 1.6 - 8, r * 1.6, r * 1.6)
	_rects["nitro"] = Rect2(sa.end.x - r * 1.6 - 16, sa.end.y - r * 3.8 - 18, r * 1.4, r * 1.4)
	_rects["pause"] = Rect2(sa.position.x, sa.position.y, 46, 46)
	_rects["left"] = Rect2(sa.position.x + 4, sa.end.y - 130, 120, 120)
	_rects["right"] = Rect2(sa.position.x + 136, sa.end.y - 130, 120, 120)


func _safe(vp: Vector2) -> Rect2:
	var r := Rect2(Vector2(14, 10), vp - Vector2(28, 20))
	if OS.has_feature("mobile"):
		var sa := DisplayServer.get_display_safe_area()
		var ss := DisplayServer.screen_get_size()
		if ss.x > 0:
			var k := vp / Vector2(ss)
			r = Rect2(Vector2(sa.position) * k + Vector2(8, 6), Vector2(sa.size) * k - Vector2(16, 12))
	return r


func _has_nitro() -> bool:
	return car != null and float(car.spec.get("nitro", 0.0)) > 0.0


func _input(ev: InputEvent) -> void:
	if not visible or input == null:
		return
	_layout()
	if ev is InputEventScreenTouch:
		var t := ev as InputEventScreenTouch
		if t.pressed:
			var hit := _button_at(t.position)
			if hit == "pause":
				pause_pressed.emit()
				get_viewport().set_input_as_handled()
				return
			if hit != "":
				_btn_touch[t.index] = hit
				_pressed[hit] = true
			elif t.position.x < get_viewport_rect().size.x * 0.45 and _steer_touch < 0 and steer_mode == "zones":
				_steer_touch = t.index
				_steer_origin = t.position
				_steer_pos = t.position
			get_viewport().set_input_as_handled()
		else:
			if _btn_touch.has(t.index):
				_pressed.erase(_btn_touch[t.index])
				_btn_touch.erase(t.index)
			if t.index == _steer_touch:
				_steer_touch = -1
		_apply()
	elif ev is InputEventScreenDrag:
		var d := ev as InputEventScreenDrag
		if d.index == _steer_touch:
			_steer_pos = d.position
			# Let the origin follow a thumb that drifts too far (no dead strip).
			var off := _steer_pos.x - _steer_origin.x
			if absf(off) > FULL_LOCK_PX * 1.4:
				_steer_origin.x = _steer_pos.x - signf(off) * FULL_LOCK_PX * 1.4
		elif _btn_touch.has(d.index) and steer_mode == "buttons":
			# Sliding between ◀ and ▶ switches direction without lifting.
			var hit := _button_at(d.position)
			if (hit == "left" or hit == "right") and hit != _btn_touch[d.index]:
				_pressed.erase(_btn_touch[d.index])
				_btn_touch[d.index] = hit
				_pressed[hit] = true
		_apply()


func _button_at(p: Vector2) -> String:
	var order := ["pause", "brake", "drift"]
	if _has_nitro():
		order.append("nitro")
	if steer_mode == "buttons":
		order.append_array(["left", "right"])
	for k in order:
		if (_rects[k] as Rect2).grow(10.0).has_point(p):
			return k
	return ""


func _apply() -> void:
	input.touch_active = true
	var steer := 0.0
	if steer_mode == "zones" and _steer_touch >= 0:
		steer = clampf((_steer_pos.x - _steer_origin.x) / FULL_LOCK_PX, -1.0, 1.0)
	elif steer_mode == "buttons":
		steer = (1.0 if _pressed.has("right") else 0.0) - (1.0 if _pressed.has("left") else 0.0)
	if steer_mode != "tilt":
		input.touch_steer = steer
	input.touch_brake = 1.0 if _pressed.has("brake") else 0.0
	input.touch_handbrake = _pressed.has("drift")
	input.touch_nitro = _pressed.has("nitro")


func _process(_dt: float) -> void:
	if steer_mode == "tilt" and input and visible:
		var g := Input.get_accelerometer()
		# Landscape: tilting the phone like a wheel rolls gravity into y.
		if g.length() > 0.1:
			input.touch_steer = clampf(-g.y / 4.0, -1.0, 1.0)
			input.touch_active = true
	queue_redraw()


func release_all() -> void:
	_btn_touch.clear()
	_pressed.clear()
	_steer_touch = -1
	if input:
		input.touch_steer = 0.0
		input.touch_brake = 0.0
		input.touch_handbrake = false
		input.touch_nitro = false


func _draw() -> void:
	_layout()
	_round(_rects["pause"], "II", false, 16)
	_round(_rects["brake"], "BRAKE", _pressed.has("brake"), 17)
	_round(_rects["drift"], "DRIFT", _pressed.has("drift"), 15)
	if _has_nitro():
		_round(_rects["nitro"], "NOS", _pressed.has("nitro"), 15, UiStyle.BLUE)
	if steer_mode == "buttons":
		_round(_rects["left"], "◀", _pressed.has("left"), 30)
		_round(_rects["right"], "▶", _pressed.has("right"), 30)
	elif steer_mode == "zones" and _steer_touch >= 0:
		# The steering slider under the thumb.
		var o := _steer_origin
		draw_line(o + Vector2(-FULL_LOCK_PX, 0), o + Vector2(FULL_LOCK_PX, 0), Color(1, 1, 1, 0.25), 4.0, true)
		draw_circle(o, 5.0, Color(1, 1, 1, 0.35))
		var k := clampf(_steer_pos.x - o.x, -FULL_LOCK_PX, FULL_LOCK_PX)
		draw_circle(o + Vector2(k, 0), 22.0, Color(1, 1, 1, 0.22))
		draw_arc(o + Vector2(k, 0), 22.0, 0, TAU, 32, Color(1, 1, 1, 0.6), 2.0, true)


func _round(r: Rect2, label: String, on: bool, size: int, accent := UiStyle.AMBER) -> void:
	var c := r.get_center()
	var rad := r.size.x * 0.5
	draw_circle(c, rad, Color(accent, 0.85) if on else Color(0.04, 0.05, 0.07, 0.42))
	draw_arc(c, rad, 0, TAU, 40, Color(1, 1, 1, 0.5 if not on else 0.0), 2.0, true)
	var w := UiStyle.text_width(label, size, "black")
	UiStyle.text(self, c + Vector2(-w * 0.5, size * 0.36), label, size, UiStyle.INK if on else Color(1, 1, 1, 0.85), "black")
