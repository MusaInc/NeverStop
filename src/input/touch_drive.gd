class_name TouchDrive
extends Control
## iPhone driving controls (landscape).
##
##  * Steering (left 45% of the screen), three modes (Settings.steer_mode):
##      "zones"  default: put a thumb down anywhere on the left side and slide
##               it – steering is the horizontal offset from where it landed
##               (analog, small dead zone, full lock at ~85 px). Lift = centre.
##      "buttons" two big ◀ ▶ pads, bottom-left (digital, ramped by DriveInput).
##      "tilt"   tip the phone like a wheel (accelerometer).
##  * Right side, Settings.right_mode:
##      "stick"  default: a smart analog stick. Put the thumb down anywhere on
##               the right half (not on a kit button) – that's GAS. From where
##               it landed: drag DOWN = brake (held at a standstill = reverse),
##               drag UP = gas + NOS, drag SIDEWAYS = drift (handbrake; with no
##               left thumb down it also steers that way). Diagonals combine
##               (up-left = NOS drift). A small tick (haptic) marks each zone.
##      "pedals" the old layout:
##    Pedals under the right thumb: GAS (tall, far right) and
##    BRAKE beside it (held at a standstill = reverse). The thumb can rock
##    from one pedal to the other without lifting. DRIFT (handbrake) and NOS
##    are round buttons above them. In Settings → Accelerate → Auto the GAS
##    pedal is hidden and the car accelerates by itself.
##  * Each touch belongs to the control it started on (index ownership), so
##    sliding a steering thumb across the screen never presses BRAKE.
##  * Workshop gear: JUMP (hydraulics) and DROP (caltrops / mines) appear
##    above the pedals when the car has them fitted; a ring shows recharge.
##  * Pause: top-left chip.
##  * Tablets: the layout is drawn in canvas units, which are physically much
##    bigger on an iPad than on a phone. `ui_k` scales the controls (and the
##    steering travel) back toward phone size in real millimetres, so thumbs
##    don't have to travel twice as far.

signal pause_pressed

var input: DriveInput
var car: Car
var kit: BattleKit
## Control scale: 1 on a phone, smaller on a tablet (see header).
var ui_k := 1.0
var steer_mode := "zones"
var _steer_touch := -1
var _steer_origin := Vector2.ZERO
var _steer_pos := Vector2.ZERO
var _btn_touch := {}           # touch index -> button name
var _pressed := {}             # button -> true
var _rects := {}
const FULL_LOCK_PX := 85.0
const DEAD_PX := 5.0
const PEDALS := ["gas", "brake"]
## Smart stick (canvas px at ui_k = 1).
const STICK_R := 72.0          # full deflection
const BRAKE_PX := 22.0         # drag down this far = brake
const NOS_PX := 30.0           # drag up this far = nitro
const DRIFT_PX := 32.0         # drag sideways this far = drift
var _stick_touch := -1
var _stick_origin := Vector2.ZERO
var _stick_pos := Vector2.ZERO
var _stick_zone := ""          # for the haptic tick on zone changes
## What the stick is doing (also read by the HUD/tests).
var stick := {"gas": 0.0, "brake": 0.0, "nitro": false, "drift": false, "steer": 0.0}


func _ready() -> void:
	set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	mouse_filter = MOUSE_FILTER_IGNORE
	steer_mode = Settings.steer_mode
	ui_k = control_scale(get_viewport_rect().size)


## Physical size of a canvas unit vs. a typical iPhone in landscape (~0.0035
## inch per unit); tablets come out at 0.45-0.65 of that, clamped so buttons
## still end up a little larger in the hand than on a phone.
static func control_scale(vp: Vector2) -> float:
	if OS.has_feature("web") or not OS.has_feature("mobile"):
		return float(OS.get_environment("NS_UI_K")) if OS.get_environment("NS_UI_K") != "" else 1.0
	var dpi := DisplayServer.screen_get_dpi()
	var ss := Vector2(DisplayServer.screen_get_size())
	if dpi <= 0 or ss.y <= 0.0 or vp.y <= 0.0:
		return 1.0
	var inch_per_unit := (ss.y / vp.y) / float(dpi)
	return clampf(0.0035 / inch_per_unit * 1.3, 0.62, 1.0)


func steer_full_px() -> float:
	return FULL_LOCK_PX * ui_k


func _has_jump() -> bool:
	return kit != null and kit.has_jump()


func _has_drop() -> bool:
	return kit != null and kit.has_drop()


func _pedal_mode() -> bool:
	return Settings.accelerate != "auto" and not _stick_mode()


func _stick_mode() -> bool:
	return Settings.right_mode == "stick"


func stick_r() -> float:
	return STICK_R * ui_k


## Where the stick's resting hint sits (and where tests press it).
func stick_home() -> Vector2:
	var sa := _safe(get_viewport_rect().size)
	return Vector2(sa.end.x - 128.0 * ui_k, sa.end.y - 118.0 * ui_k)


func _layout() -> void:
	var vp := get_viewport_rect().size
	var sa := _safe(vp)
	var k := ui_k
	var gw := 112.0 * k
	var gh := 176.0 * k
	if _stick_mode():
		var off := Rect2(-1000, -1000, 1, 1)
		for b in ["gas", "brake", "drift", "nitro"]:
			_rects[b] = off
		# Kit buttons up the right edge, clear of the stick's travel.
		var h := stick_home()
		_rects["jump"] = Rect2(sa.end.x - 80 * k, h.y - stick_r() - 104 * k, 76 * k, 76 * k)
		_rects["drop"] = Rect2(sa.end.x - 80 * k, _rects["jump"].position.y - 90 * k, 76 * k, 76 * k)
	elif _pedal_mode():
		_rects["gas"] = Rect2(sa.end.x - gw - 4, sa.end.y - gh - 4, gw, gh)
		_rects["brake"] = Rect2(_rects["gas"].position.x - 108 * k - 14 * k, sa.end.y - 124 * k - 4, 108 * k, 124 * k)
		_rects["drift"] = Rect2(_rects["brake"].position.x - 96 * k - 16 * k, sa.end.y - 96 * k - 8, 96 * k, 96 * k)
		_rects["nitro"] = Rect2(sa.end.x - 92 * k - 14 * k, _rects["gas"].position.y - 92 * k - 14 * k, 92 * k, 92 * k)
		# Workshop gear sits over BRAKE / DRIFT (thumb reaches up, not across).
		_rects["jump"] = Rect2(_rects["brake"].position.x + 8 * k, _rects["brake"].position.y - 84 * k - 14 * k, 84 * k, 84 * k)
		_rects["drop"] = Rect2(_rects["drift"].position.x + 6 * k, _rects["drift"].position.y - 80 * k - 14 * k, 80 * k, 80 * k)
	else:
		var r := 62.0 * k
		_rects["gas"] = Rect2(-1000, -1000, 1, 1)
		_rects["brake"] = Rect2(sa.end.x - r * 2.0 - 8, sa.end.y - r * 2.0 - 8, r * 2.0, r * 2.0)
		_rects["drift"] = Rect2(sa.end.x - r * 4.0 - 26 * k, sa.end.y - r * 1.6 - 8, r * 1.6, r * 1.6)
		_rects["nitro"] = Rect2(sa.end.x - r * 1.6 - 16 * k, sa.end.y - r * 3.8 - 18 * k, r * 1.4, r * 1.4)
		_rects["jump"] = Rect2(_rects["drift"].position.x - r * 0.1, _rects["drift"].position.y - r * 1.4 - 14 * k, r * 1.4, r * 1.4)
		_rects["drop"] = Rect2(_rects["drift"].position.x - r * 1.6 - 14 * k, sa.end.y - r * 1.4 - 8, r * 1.4, r * 1.4)
	_rects["pause"] = Rect2(sa.position.x, sa.position.y, 46, 46)
	_rects["left"] = Rect2(sa.position.x + 4, sa.end.y - 130 * k, 120 * k, 120 * k)
	_rects["right"] = Rect2(sa.position.x + 136 * k, sa.end.y - 130 * k, 120 * k, 120 * k)


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
			if hit == "jump" or hit == "drop":
				if hit == "jump":
					input.touch_jump = true
				else:
					input.touch_drop = true
				_btn_touch[t.index] = hit
				_pressed[hit] = true
				get_viewport().set_input_as_handled()
				return
			if hit != "":
				_btn_touch[t.index] = hit
				_pressed[hit] = true
			elif _stick_mode() and t.position.x >= get_viewport_rect().size.x * 0.5 and _stick_touch < 0:
				_stick_touch = t.index
				_stick_origin = t.position
				_stick_pos = t.position
				_stick_zone = ""
			elif t.position.x < get_viewport_rect().size.x * 0.45 and _steer_touch < 0 and steer_mode == "zones":
				_steer_touch = t.index
				_steer_origin = t.position
				_steer_pos = t.position
			get_viewport().set_input_as_handled()
		else:
			if _btn_touch.has(t.index):
				_release(_btn_touch[t.index], t.index)
				_btn_touch.erase(t.index)
			if t.index == _steer_touch:
				_steer_touch = -1
			if t.index == _stick_touch:
				_stick_touch = -1
		_apply()
	elif ev is InputEventScreenDrag:
		var d := ev as InputEventScreenDrag
		if d.index == _stick_touch:
			_stick_pos = d.position
			# The origin follows a thumb that wanders well past full travel,
			# so dragging back always responds at once.
			var so := _stick_pos - _stick_origin
			if so.length() > stick_r() * 1.35:
				_stick_origin = _stick_pos - so.normalized() * stick_r() * 1.35
		elif d.index == _steer_touch:
			_steer_pos = d.position
			# Let the origin follow a thumb that drifts too far (no dead strip).
			var off := _steer_pos.x - _steer_origin.x
			if absf(off) > steer_full_px() * 1.3:
				_steer_origin.x = _steer_pos.x - signf(off) * steer_full_px() * 1.3
		elif _btn_touch.has(d.index):
			var cur: String = _btn_touch[d.index]
			var hit := _button_at(d.position)
			var swap := false
			# Rocking the right thumb between GAS and BRAKE, or sliding
			# between ◀ and ▶, switches without lifting.
			if cur in PEDALS and hit in PEDALS and hit != cur:
				swap = true
			elif steer_mode == "buttons" and cur in ["left", "right"] and hit in ["left", "right"] and hit != cur:
				swap = true
			if swap:
				_release(cur, d.index)
				_btn_touch[d.index] = hit
				_pressed[hit] = true
		_apply()


## A button stays down while any other finger still holds it.
func _release(name: String, index: int) -> void:
	for i in _btn_touch:
		if i != index and _btn_touch[i] == name:
			return
	_pressed.erase(name)


func _button_at(p: Vector2) -> String:
	var order := ["pause"]
	if _pedal_mode():
		order.append("gas")
	order.append_array(["brake", "drift"])
	if _has_nitro():
		order.append("nitro")
	if _has_jump():
		order.append("jump")
	if _has_drop():
		order.append("drop")
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
		var off := _steer_pos.x - _steer_origin.x
		var mag := maxf(absf(off) - DEAD_PX * ui_k, 0.0) / (steer_full_px() - DEAD_PX * ui_k)
		steer = clampf(signf(off) * mag, -1.0, 1.0)
	elif steer_mode == "buttons":
		steer = (1.0 if _pressed.has("right") else 0.0) - (1.0 if _pressed.has("left") else 0.0)
	if _stick_mode():
		_read_stick()
		# Sideways on the stick steers too when the left thumb is free.
		if steer_mode != "tilt" and _steer_touch < 0 and not (_pressed.has("left") or _pressed.has("right")):
			steer = stick["steer"]
		input.touch_gas = stick["gas"]
		input.touch_brake = stick["brake"]
		input.touch_handbrake = stick["drift"]
		input.touch_nitro = stick["nitro"]
	else:
		input.touch_gas = 1.0 if _pressed.has("gas") else 0.0
		input.touch_brake = 1.0 if _pressed.has("brake") else 0.0
		input.touch_handbrake = _pressed.has("drift")
		input.touch_nitro = _pressed.has("nitro")
	if steer_mode != "tilt":
		input.touch_steer = steer


## Stick offset -> controls. Axes are independent so diagonals combine.
func _read_stick() -> void:
	stick = {"gas": 0.0, "brake": 0.0, "nitro": false, "drift": false, "steer": 0.0}
	if _stick_touch < 0:
		_stick_zone = ""
		return
	var o := _stick_pos - _stick_origin
	var r := stick_r()
	var k := ui_k
	if o.y > BRAKE_PX * k:
		# Brake builds with the drag: a light touch scrubs speed, a full pull stops.
		stick["brake"] = clampf(0.45 + 0.55 * (o.y - BRAKE_PX * k) / (r - BRAKE_PX * k), 0.45, 1.0)
	else:
		stick["gas"] = 1.0
		stick["nitro"] = -o.y > NOS_PX * k and _has_nitro()
	if absf(o.x) > DRIFT_PX * k:
		stick["drift"] = true
	stick["steer"] = clampf(o.x / r, -1.0, 1.0) if absf(o.x) > 8.0 * k else 0.0
	var zone := ("B" if stick["brake"] > 0.0 else ("N" if stick["nitro"] else "G")) + ("D" if stick["drift"] else "")
	if zone != _stick_zone:
		if _stick_zone != "":
			Settings.haptic(12, 0.35)
		_stick_zone = zone


func _process(_dt: float) -> void:
	if steer_mode == "tilt" and input and visible:
		var g := Input.get_accelerometer()
		# Landscape: tilting the phone like a wheel rolls gravity into y.
		if g.length() > 0.1:
			var raw := clampf(-g.y / 4.0, -1.0, 1.0)
			# A small dead zone so holding the phone "straight" is straight.
			input.touch_steer = signf(raw) * maxf(absf(raw) - 0.05, 0.0) / 0.95
			input.touch_active = true
	queue_redraw()


## Button centres as viewport fractions (web tests).
func button_centres() -> Dictionary:
	_layout()
	var vp := get_viewport_rect().size
	var out := {}
	for k in _rects:
		var c := (_rects[k] as Rect2).get_center()
		out[k] = [c.x / vp.x, c.y / vp.y]
	if _stick_mode():
		var h := stick_home()
		out["stick"] = [h.x / vp.x, h.y / vp.y]
		out["stick_r"] = stick_r() / vp.y
	return out


func release_all() -> void:
	ui_k = control_scale(get_viewport_rect().size)
	_btn_touch.clear()
	_pressed.clear()
	_steer_touch = -1
	_stick_touch = -1
	stick = {"gas": 0.0, "brake": 0.0, "nitro": false, "drift": false, "steer": 0.0}
	if input:
		input.touch_steer = 0.0
		input.touch_gas = 0.0
		input.touch_brake = 0.0
		input.touch_handbrake = false
		input.touch_nitro = false


func _draw() -> void:
	_layout()
	_round(_rects["pause"], "II", false, 16)
	if _stick_mode():
		_draw_stick()
	elif _pedal_mode():
		_pedal(_rects["gas"], "GAS", _pressed.has("gas"), UiStyle.AMBER, true)
		_pedal(_rects["brake"], "BRAKE", _pressed.has("brake"), UiStyle.RED, false)
	else:
		_round(_rects["brake"], "BRAKE", _pressed.has("brake"), 17)
	if not _stick_mode():
		_round(_rects["drift"], "DRIFT", _pressed.has("drift"), 15)
	if _has_nitro() and not _stick_mode():
		_round(_rects["nitro"], "NOS", _pressed.has("nitro"), 15, UiStyle.BLUE)
		if car:
			# Tank level round the button.
			var c := (_rects["nitro"] as Rect2).get_center()
			var rad := (_rects["nitro"] as Rect2).size.x * 0.5 + 5.0
			draw_arc(c, rad, -PI / 2, -PI / 2 + TAU * car.nitro_amount, 40, Color(UiStyle.BLUE, 0.85), 3.0, true)
	if _has_jump():
		var jr := kit.jump_ready()
		_round(_rects["jump"], "JUMP", _pressed.has("jump"), 14, UiStyle.AMBER)
		_ring(_rects["jump"], jr, UiStyle.AMBER)
	if _has_drop():
		var lbl := ("SPIKES" if kit.rear == "caltrops" else "MINE") + " %d" % kit.charges
		_round(_rects["drop"], lbl, _pressed.has("drop"), 13, UiStyle.RED)
		_ring(_rects["drop"], kit.recharge_k() if kit.charges < kit.max_charges else 1.0, UiStyle.RED)
	if steer_mode == "buttons":
		_round(_rects["left"], "◀", _pressed.has("left"), 30)
		_round(_rects["right"], "▶", _pressed.has("right"), 30)
	elif steer_mode == "zones" and _steer_touch >= 0:
		# The steering slider under the thumb.
		var o := _steer_origin
		var fl := steer_full_px()
		draw_line(o + Vector2(-fl, 0), o + Vector2(fl, 0), Color(1, 1, 1, 0.25), 4.0, true)
		for sx in [-1.0, 1.0]:
			draw_line(o + Vector2(sx * fl, -10), o + Vector2(sx * fl, 10), Color(1, 1, 1, 0.35), 2.0, true)
		draw_circle(o, 5.0, Color(1, 1, 1, 0.35))
		var k := clampf(_steer_pos.x - o.x, -fl, fl)
		draw_circle(o + Vector2(k, 0), 24.0, Color(1, 1, 1, 0.22))
		draw_arc(o + Vector2(k, 0), 24.0, 0, TAU, 32, Color(1, 1, 1, 0.6), 2.0, true)


## Recharge ring round a round button (full = ready).
func _ring(r: Rect2, k: float, col: Color) -> void:
	var c := r.get_center()
	var rad := r.size.x * 0.5 + 5.0
	draw_arc(c, rad, -PI / 2, -PI / 2 + TAU * clampf(k, 0.0, 1.0), 40, Color(col, 0.85), 3.0, true)


## A pedal: a frosted rounded slab, filled with its colour while pressed.
func _pedal(r: Rect2, label: String, on: bool, accent: Color, tall: bool) -> void:
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(accent, 0.9) if on else Color(1, 1, 1, 0.1)
	sb.set_corner_radius_all(26)
	sb.border_color = Color(1, 1, 1, 0.0 if on else 0.32)
	sb.set_border_width_all(1)
	sb.anti_aliasing = true
	draw_style_box(sb, r)
	# A single chevron says which way the pedal pushes the car.
	var c := r.get_center() + Vector2(0, -12 if tall else -8)
	var k := 11.0
	var col := Color(UiStyle.INK, 0.9) if on else Color(1, 1, 1, 0.75)
	var dir := -1.0 if tall else 1.0
	draw_polyline(PackedVector2Array([c + Vector2(-k, -dir * k * 0.5), c + Vector2(0, dir * k * 0.5), c + Vector2(k, -dir * k * 0.5)]), col, 3.0, true)
	var size := 13
	var w := UiStyle.text_width(label, size, "black")
	UiStyle.text(self, Vector2(r.get_center().x - w * 0.5, r.end.y - 18), label, size, col, "black")


func _round(r: Rect2, label: String, on: bool, size: int, accent := UiStyle.AMBER) -> void:
	var c := r.get_center()
	var rad := r.size.x * 0.5
	draw_circle(c, rad, Color(accent, 0.88) if on else Color(1, 1, 1, 0.1))
	draw_arc(c, rad, 0, TAU, 48, Color(1, 1, 1, 0.0 if on else 0.32), 1.0, true)
	var sz := mini(size, 14)
	var w := UiStyle.text_width(label, sz, "black")
	UiStyle.text(self, c + Vector2(-w * 0.5, sz * 0.36), label, sz, UiStyle.INK if on else Color(1, 1, 1, 0.8), "black")


## The smart stick: a faint compass at rest; under the thumb, a ring with
## the four zones lit as they engage and a knob that follows the drag.
func _draw_stick() -> void:
	var r := stick_r()
	var k := ui_k
	var live := _stick_touch >= 0
	var c := _stick_origin if live else stick_home()
	var a := 1.0 if live else 0.55
	draw_circle(c, r, Color(1, 1, 1, 0.07 * a))
	draw_arc(c, r, 0, TAU, 56, Color(1, 1, 1, 0.3 * a), 1.5, true)
	# Zone arcs: NOS up, BRAKE down, DRIFT either side.
	var zones := [[-PI * 0.5, UiStyle.BLUE, stick["nitro"]], [PI * 0.5, UiStyle.RED, stick["brake"] > 0.0],
		[0.0, UiStyle.AMBER, stick["drift"] and stick["steer"] > 0.0], [PI, UiStyle.AMBER, stick["drift"] and stick["steer"] <= 0.0]]
	if not _has_nitro():
		zones.remove_at(0)
	for z in zones:
		var on: bool = z[2]
		var col: Color = z[1]
		draw_arc(c, r + 4.0, float(z[0]) - 0.5, float(z[0]) + 0.5, 16, Color(col, 0.95 if on else 0.4 * a), 6.0 if on else 3.0, true)
	var fs := maxi(10, int(12 * k))
	var labels := [["NOS", Vector2(0, -r - 16 * k)], ["BRAKE", Vector2(0, r + 24 * k)],
		["DRIFT", Vector2(-r - 30 * k, 4)], ["DRIFT", Vector2(r + 30 * k, 4)]]
	if not _has_nitro():
		labels.remove_at(0)
	for l in labels:
		var w := UiStyle.text_width(l[0], fs, "black")
		UiStyle.text(self, c + l[1] - Vector2(w * 0.5, -fs * 0.36 + 4), l[0], fs, Color(1, 1, 1, 0.7 * a), "black")
	# Nitro tank round the outside.
	if _has_nitro() and car:
		draw_arc(c, r + 12.0, -PI / 2, -PI / 2 + TAU * car.nitro_amount, 48, Color(UiStyle.BLUE, 0.7 * a), 2.5, true)
	var knob := c
	if live:
		var o := _stick_pos - _stick_origin
		knob = c + (o.limit_length(r))
	var kr := 30.0 * k
	var gas_on: bool = stick["gas"] > 0.0
	var kc := UiStyle.RED if stick["brake"] > 0.0 else (UiStyle.BLUE if stick["nitro"] else UiStyle.AMBER)
	draw_circle(knob, kr, Color(kc, 0.85) if live else Color(1, 1, 1, 0.12))
	draw_arc(knob, kr, 0, TAU, 40, Color(1, 1, 1, 0.0 if live else 0.4), 1.5, true)
	var txt := "GAS" if (gas_on or not live) else "BRK"
	if live and stick["nitro"]:
		txt = "NOS"
	var tw := UiStyle.text_width(txt, fs + 1, "black")
	UiStyle.text(self, knob + Vector2(-tw * 0.5, (fs + 1) * 0.36), txt, fs + 1, UiStyle.INK if live else Color(1, 1, 1, 0.75), "black")
