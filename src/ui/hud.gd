class_name Hud
extends Control
## In-run HUD. Only what you need while driving, in the corners, inside the
## device's safe area:
##   top-left   survival time, heat bars, units in pursuit
##   top-centre score and chain multiplier, event call-outs, radio line
##   top-right  minimap (police dots, roadblocks, helicopter)
##   bottom-centre speed, gear, damage and nitro
##   centre     bust meter (only while it's filling), roadblock warning
## Drawn immediate-mode (one control, no node soup).

var game: Node
var player: Car
var director: PursuitDirector
var score: ScoreKeeper
var minimap: Minimap
var touch_mode := false
var _events: Array = []          # [text, points, chain, age]
var _radio := ""
var _radio_t := 0.0
var _warn := ""
var _warn_t := 0.0
var _flash := 0.0
var _flash_col := UiStyle.RED
var _heat_pulse := 0.0
var _shown_score := 0.0
var _safe := Rect2()
var perf := false
var _perf_t := 0.0
var _perf_text := ""


func _ready() -> void:
	set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	mouse_filter = MOUSE_FILTER_IGNORE
	minimap = Minimap.new()
	minimap.size = Vector2(168, 168)
	add_child(minimap)
	perf = Settings.show_perf


func bind(p_game: Node, p_player: Car, p_director: PursuitDirector, p_score: ScoreKeeper) -> void:
	game = p_game
	player = p_player
	director = p_director
	score = p_score
	minimap.player = player
	score.event.connect(func(label, pts, chain): _event(label, pts, chain))
	score.chain_broken.connect(func(): _event("CHAIN BROKEN", 0, 1.0))
	director.radio.connect(func(t): _radio = t; _radio_t = 5.5)
	director.heat_changed.connect(func(h):
		_heat_pulse = 1.0
		if h > 1:
			_warning("HEAT %d" % h))
	director.roadblock_spawned.connect(func(_p): _warning("ROADBLOCK AHEAD"))
	director.spiked.connect(func(): _warning("TYRES SPIKED"); flash(UiStyle.RED))


func flash(c: Color, amount := 0.35) -> void:
	_flash = maxf(_flash, amount)
	_flash_col = c


func _event(label: String, pts: int, chain: float) -> void:
	_events.push_front([label, pts, chain, 0.0])
	while _events.size() > 4:
		_events.pop_back()


func _warning(t: String) -> void:
	_warn = t
	_warn_t = 2.6


func _process(dt: float) -> void:
	_safe = _safe_rect()
	if minimap:
		minimap.position = Vector2(_safe.end.x - minimap.size.x - 6.0, _safe.position.y + 6.0)
		if director:
			var ms: Array = []
			for m in director.unit_markers():
				var kind: String = m[1]
				if m[2] == "wrecked":
					kind = "wreck"
				ms.append([m[0], kind])
			for rb in director.roadblocks:
				if not rb["passed"]:
					ms.append([rb["pos"], "roadblock"])
			if director.heli:
				ms.append([director.heli.global_position, "heli"])
			minimap.markers = ms
	for e in _events:
		e[3] += dt
	_events = _events.filter(func(e): return e[3] < 2.2)
	_radio_t -= dt
	_warn_t -= dt
	_flash = maxf(0.0, _flash - dt * 1.6)
	_heat_pulse = maxf(0.0, _heat_pulse - dt * 0.8)
	if score:
		_shown_score = lerpf(_shown_score, score.score, 1.0 - exp(-10.0 * dt))
	if perf:
		_perf_t -= dt
		if _perf_t <= 0.0:
			_perf_t = 0.5
			_perf_text = "%d fps  %.1f ms  draws %d  cops %d/%d  " % [Engine.get_frames_per_second(),
				Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0,
				Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME),
				director.physical_count() if director else 0, director.alive_count() if director else 0]
	queue_redraw()


func _safe_rect() -> Rect2:
	var vp := get_viewport_rect().size
	var r := Rect2(Vector2(16, 12), vp - Vector2(32, 24))
	if OS.has_feature("mobile"):
		var sa := DisplayServer.get_display_safe_area()
		var ss := DisplayServer.screen_get_size()
		if ss.x > 0 and ss.y > 0:
			var k := vp / Vector2(ss)
			var p := Vector2(sa.position) * k
			var e := Vector2(sa.end) * k
			r = Rect2(p + Vector2(10, 8), (e - p) - Vector2(20, 16))
	return r


func _draw() -> void:
	if player == null:
		return
	var vp := get_viewport_rect().size
	var s := _safe
	# Screen flash (damage, spike strip, bust).
	if _flash > 0.0:
		draw_rect(Rect2(Vector2.ZERO, vp), Color(_flash_col, _flash * 0.35))
	_draw_time_heat(s)
	_draw_score(s, vp)
	_draw_speed(s, vp)
	_draw_bust(vp)
	if _warn_t > 0.0:
		var a := clampf(_warn_t * 2.0, 0.0, 1.0)
		var w := UiStyle.text_width(_warn, 34, "black")
		var y := vp.y * 0.3
		UiStyle.pill(self, Rect2(vp.x * 0.5 - w * 0.5 - 28, y - 36, w + 56, 50), Color(0.5, 0.03, 0.05, 0.72 * a))
		UiStyle.text(self, Vector2(vp.x * 0.5 - w * 0.5, y), _warn, 34, Color(UiStyle.WHITE, a), "black")
	if _radio_t > 0.0 and _radio != "":
		var a2 := clampf(_radio_t, 0.0, 1.0)
		var line := "DISPATCH  " + _radio
		var w2 := UiStyle.text_width(line, 15, "semibold")
		UiStyle.text(self, Vector2(vp.x * 0.5 - w2 * 0.5, s.position.y + 108), line, 15, Color(0.75, 0.85, 1.0, 0.9 * a2), "semibold")
	if perf:
		UiStyle.text(self, Vector2(s.position.x, s.end.y - 4), _perf_text, 13, UiStyle.DIM, "semibold")


func _draw_time_heat(s: Rect2) -> void:
	var x := s.position.x + (54.0 if touch_mode else 0.0)
	var y := s.position.y
	var t: float = score.time if score else 0.0
	UiStyle.text(self, Vector2(x, y + 40), UiStyle.time_str(t), 42, UiStyle.WHITE, "black")
	# Heat: six bars, blue to red; beyond 6 the number keeps climbing.
	var h: int = director.heat if director else 1
	var bx := x
	var by := y + 52
	UiStyle.text(self, Vector2(bx, by + 13), "HEAT", 12, UiStyle.DIM, "bold")
	bx += 40
	for i in 6:
		var on := i < h
		var col := UiStyle.BLUE.lerp(UiStyle.RED, i / 5.0)
		if not on:
			col = Color(1, 1, 1, 0.14)
		var hh := 8.0 + i * 2.0
		var pulse := _heat_pulse * (1.0 if i == mini(h, 6) - 1 else 0.0)
		draw_rect(Rect2(bx + i * 11, by + 16 - hh - pulse * 4.0, 8, hh + pulse * 4.0), col)
	if h > 6:
		UiStyle.text(self, Vector2(bx + 70, by + 15), "%d" % h, 18, UiStyle.RED, "black")
	if director and director.active:
		var n := director.alive_count()
		UiStyle.text(self, Vector2(x, by + 36), "%d UNITS IN PURSUIT" % n, 12, Color(0.75, 0.85, 1.0, 0.8), "bold")


func _draw_score(s: Rect2, vp: Vector2) -> void:
	if score == null:
		return
	var cx := vp.x * 0.5
	var txt := UiStyle.thousands(int(_shown_score))
	var w := UiStyle.text_width(txt, 34, "black")
	UiStyle.text(self, Vector2(cx - w * 0.5, s.position.y + 34), txt, 34, UiStyle.WHITE, "black")
	if score.chain > 1.01:
		var ct := "x%.1f" % score.chain
		var cw := UiStyle.text_width(ct, 22, "black")
		var r := Rect2(cx + w * 0.5 + 12, s.position.y + 10, cw + 18, 30)
		UiStyle.pill(self, r, Color(UiStyle.AMBER, 0.95))
		UiStyle.text(self, r.position + Vector2(9, 23), ct, 22, UiStyle.INK, "black")
		# Chain timer.
		var k := clampf(score.chain_t / ScoreKeeper.CHAIN_WINDOW, 0.0, 1.0)
		draw_rect(Rect2(r.position.x, r.end.y + 3, r.size.x * k, 3), UiStyle.AMBER)
	# Event call-outs.
	var y := s.position.y + 64
	for e in _events:
		var age: float = e[3]
		var a := clampf(1.0 - (age - 1.6) / 0.6, 0.0, 1.0)
		var pop := 1.0 + maxf(0.0, 0.25 - age) * 1.6
		var size := int(20 * pop) if e == _events[0] else 16
		var label: String = e[0]
		var line := label if int(e[1]) <= 0 else "%s  +%s" % [label, UiStyle.thousands(int(e[1]))]
		var lw := UiStyle.text_width(line, size, "black")
		var col := UiStyle.AMBER if int(e[1]) > 0 else UiStyle.RED
		UiStyle.text(self, Vector2(cx - lw * 0.5, y + size), line, size, Color(col, a), "black")
		y += size + 6


func _draw_speed(s: Rect2, vp: Vector2) -> void:
	var cx := vp.x * 0.5
	var by := s.end.y
	var kmh := int(round(player.speed * 3.6))
	var t := str(kmh)
	var w := UiStyle.text_width(t, 54, "black")
	UiStyle.text(self, Vector2(cx - w * 0.5, by - 34), t, 54, UiStyle.WHITE, "black")
	UiStyle.text(self, Vector2(cx + w * 0.5 + 6, by - 36), "KM/H", 12, UiStyle.DIM, "bold")
	UiStyle.text(self, Vector2(cx + w * 0.5 + 6, by - 52), "G%d" % player.gear, 12, UiStyle.DIM, "bold")
	# Damage: a bar that drains, with the worst side named once it matters.
	var bw := 180.0
	var bx := cx - bw * 0.5
	var bar_y := by - 22
	draw_rect(Rect2(bx, bar_y, bw, 5), Color(1, 1, 1, 0.14))
	var hcol := UiStyle.WHITE.lerp(UiStyle.AMBER, clampf((0.8 - player.health) * 2.5, 0.0, 1.0)).lerp(UiStyle.RED, clampf((0.45 - player.health) * 3.0, 0.0, 1.0))
	draw_rect(Rect2(bx, bar_y, bw * player.health, 5), hcol)
	var lbl := "VEHICLE" if player.health > 0.45 else ("ENGINE FAILING" if player.health < 0.2 else "HEAVY DAMAGE")
	if player.puncture > 0.0:
		lbl = "TYRES SHREDDED"
	UiStyle.text(self, Vector2(bx, bar_y + 18), lbl, 11, Color(hcol, 0.8), "bold")
	if float(player.spec.get("nitro", 0.0)) > 0.0:
		var nx := bx + bw - 60
		UiStyle.text(self, Vector2(nx - 4, bar_y + 18), "NITRO", 11, UiStyle.BLUE, "bold")
		draw_rect(Rect2(nx + 36, bar_y + 10, 28, 4), Color(1, 1, 1, 0.14))
		draw_rect(Rect2(nx + 36, bar_y + 10, 28 * player.nitro_amount, 4), UiStyle.BLUE)


func _draw_bust(vp: Vector2) -> void:
	if director == null or director.bust <= 0.01:
		return
	var c := vp * Vector2(0.5, 0.56)
	var b := director.bust
	var r := 46.0
	draw_arc(c, r, 0, TAU, 48, Color(0, 0, 0, 0.45), 9.0, true)
	draw_arc(c, r, -PI / 2, -PI / 2 + TAU * b, 48, UiStyle.RED.lerp(UiStyle.WHITE, 0.5 * sin(Time.get_ticks_msec() * 0.02) + 0.5), 7.0, true)
	var t := "BUSTED" if b > 0.98 else "GET OUT!"
	var w := UiStyle.text_width(t, 22, "black")
	UiStyle.text(self, c + Vector2(-w * 0.5, 8), t, 22, UiStyle.WHITE, "black")
