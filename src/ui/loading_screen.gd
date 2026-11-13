class_name LoadingScreen
extends CanvasLayer
## Start-up cover: the boot splash image (assets/ui/splash.png, drawn exactly
## as the OS / Godot splash draws it, so the hand-over is seamless) plus a
## progress line and a tip while the city is built, then a fade into the title.
## The city build is a few long blocking steps, so `step()` sets the target and
## waits two frames for it to be drawn before the next one starts.

const TIPS := [
	"Drive through a green beacon to fix every dent and panel.",
	"Police come from ahead. Watch the corners, not your mirror.",
	"Near misses and drifts keep your chain alive.",
	"Roadblocks always leave a gap. Find it.",
	"Rams count when you're the faster car.",
	"Busted means boxed in and stopped. Keep moving.",
	"Caltrops and mines are fitted in the Workshop.",
	"Contracts pay cash on top of your score.",
]

var _view: _View
var _k := 0.0
var _target := 0.0
var _status := ""
var _tip := ""
var _fade := -1.0


func _init() -> void:
	layer = 100
	process_mode = Node.PROCESS_MODE_ALWAYS
	_view = _View.new()
	_view.owner_screen = self
	_view.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_view.mouse_filter = Control.MOUSE_FILTER_STOP   # nothing underneath is tappable yet
	add_child(_view)
	_tip = TIPS[randi() % TIPS.size()]


## Set progress (0..1) and the status line; returns once it has been drawn.
func step(k: float, status: String) -> void:
	_target = clampf(k, 0.0, 1.0)
	_status = status
	_k = maxf(_k, lerpf(_k, _target, 0.6))
	_view.queue_redraw()
	await get_tree().process_frame
	await get_tree().process_frame


## Fill the line, hold a few frames (the first frames of the 3-D view compile
## shaders behind the cover), then fade out and free.
func finish() -> void:
	_target = 1.0
	_status = ""
	for i in 4:
		await get_tree().process_frame
	_fade = 0.0
	_view.mouse_filter = Control.MOUSE_FILTER_IGNORE   # the title is live under the fade


func _process(dt: float) -> void:
	_k = move_toward(_k, _target, dt * 1.6)
	if _fade >= 0.0:
		# Zoom through the logo while fading, so it reads as a move into the
		# game rather than two logos cross-fading.
		_fade += dt / 0.4
		var e := smoothstep(0.0, 1.0, _fade)
		_view.pivot_offset = _view.size * 0.5
		_view.scale = Vector2.ONE * (1.0 + 0.18 * e * e)
		_view.modulate.a = 1.0 - e
		if _fade >= 1.0:
			queue_free()
	_view.queue_redraw()


class _View:
	extends Control
	var owner_screen: LoadingScreen
	var _tex: Texture2D

	func _ready() -> void:
		var p := "res://assets/ui/splash.png"
		_tex = load(p) if ResourceLoader.exists(p) else null

	func _draw() -> void:
		var s := size
		draw_rect(Rect2(Vector2.ZERO, s), SplashArt.BG)
		var r := Rect2(Vector2.ZERO, s)
		if _tex:
			# Same placement as the boot splash with fullsize: fit, centred.
			var ts := _tex.get_size()
			var k := minf(s.x / ts.x, s.y / ts.y)
			r = Rect2((s - ts * k) * 0.5, ts * k)
			draw_texture_rect(_tex, r, false)
		var sc := r.size.y / 1080.0
		var w := 520.0 * sc
		var y := r.position.y + r.size.y * 0.80
		var x := r.position.x + (r.size.x - w) * 0.5
		var h := maxf(3.0, 5.0 * sc)
		draw_rect(Rect2(x, y, w, h), Color(1, 1, 1, 0.1))
		var k2 := owner_screen._k
		# Red fills the first half, blue the second (the logo's light bar).
		draw_rect(Rect2(x, y, w * minf(k2, 0.5), h), UiStyle.RED)
		if k2 > 0.5:
			draw_rect(Rect2(x + w * 0.5, y, w * (k2 - 0.5), h), UiStyle.BLUE)
		var f := UiStyle.font("bold")
		var fs := int(maxf(13.0, 26.0 * sc))
		if owner_screen._status != "":
			var t := owner_screen._status.to_upper()
			var tw := f.get_string_size(t, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
			draw_string(f, Vector2(x + (w - tw) * 0.5, y + h + fs * 1.7), t, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, Color(1, 1, 1, 0.45))
		var tf := UiStyle.font("semibold")
		var ts2 := int(maxf(14.0, 30.0 * sc))
		var tip := owner_screen._tip
		var tipw := tf.get_string_size(tip, HORIZONTAL_ALIGNMENT_LEFT, -1, ts2).x
		draw_string(tf, Vector2(r.position.x + (r.size.x - tipw) * 0.5, r.end.y - r.size.y * 0.07), tip,
			HORIZONTAL_ALIGNMENT_LEFT, -1, ts2, Color(UiStyle.AMBER, 0.75))
