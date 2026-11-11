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
var contracts: Contracts
var kit: BattleKit
var repairs: RepairPickups
var arena: Arena                 # set during a battle (Sky Arena / Rooftop Rumble)
var touch_mode := false
## First-run coach: one prompt at a time until the player has done it.
var _coach: Array = []           # [text_touch, text_keys, kind, need]
var _coach_i := -1
var _coach_t := 0.0
var _coach_hold := 0.0
var _coach_steer_l := false
var _coach_steer_r := false
var _done_pop := ""
var _done_pop_t := 0.0
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


## A panel came off the player's car.
func part_gone(name: String) -> void:
	_event(name + " GONE", 0, 1.0)


func notice(text: String) -> void:
	_event(text, 0, 1.0)


func contract_done(c: Dictionary) -> void:
	_done_pop = "CONTRACT COMPLETE  +$%d" % int(c["cash"])
	_done_pop_t = 2.0


func start_coach(on: bool) -> void:
	_coach.clear()
	_coach_i = -1
	if not on:
		return
	if Settings.accelerate != "auto":
		_coach.append(["Hold your right thumb down to drive" if Settings.right_mode == "stick" else "Hold GAS to drive", "Hold W / ↑ (or RT) to drive", "gas", 1.0])
	_coach.append(["Slide your left thumb to steer", "Steer with A / D (or ← →)", "steer", 0.0])
	_coach.append(["Drag the right thumb DOWN to brake · keep it there to reverse" if Settings.right_mode == "stick" else "BRAKE to slow down · hold it when stopped to reverse", "S / ↓ to brake · hold it when stopped to reverse", "brake", 0.35])
	_coach.append(["Drag the right thumb SIDEWAYS through a corner to drift" if Settings.right_mode == "stick" else "Hold DRIFT through a corner to slide", "Hold SPACE through a corner to drift", "drift", 0.5])
	_coach.append(["They will catch you. Survive as long as you can.", "They will catch you. Survive as long as you can.", "wait", 4.0])
	_coach.append(["Contracts (left) pay extra cash. Go!", "Contracts (left) pay extra cash. Go!", "wait", 4.0])
	_coach_i = 0
	_coach_t = 0.0
	_coach_hold = 0.0
	_coach_steer_l = false
	_coach_steer_r = false


func _coach_update(dt: float) -> void:
	if _coach_i < 0 or _coach_i >= _coach.size() or player == null:
		return
	_coach_t += dt
	var step: Array = _coach[_coach_i]
	var ok := false
	match step[2]:
		"gas":
			_coach_hold = _coach_hold + dt if player.throttle > 0.5 else 0.0
			ok = _coach_hold >= float(step[3])
		"steer":
			if player.steer > 0.35:
				_coach_steer_r = true
			if player.steer < -0.35:
				_coach_steer_l = true
			ok = _coach_steer_l and _coach_steer_r
		"brake":
			_coach_hold = _coach_hold + dt if player.brake > 0.5 else 0.0
			ok = _coach_hold >= float(step[3])
		"drift":
			_coach_hold = _coach_hold + dt if player.handbrake else 0.0
			ok = _coach_hold >= float(step[3])
		"wait":
			ok = _coach_t >= float(step[3])
	# Never nag: every prompt gives up after a while.
	if ok or _coach_t > 25.0:
		_coach_i += 1
		_coach_t = 0.0
		_coach_hold = 0.0
		if _coach_i >= _coach.size():
			_coach_i = -1
			SaveData.data["tutorial_done"] = true
			SaveData.save()


func _draw_coach(vp: Vector2) -> void:
	if _coach_i < 0 or _coach_i >= _coach.size():
		return
	var step: Array = _coach[_coach_i]
	var t: String = step[0] if touch_mode else step[1]
	var a := clampf(_coach_t * 3.0, 0.0, 1.0)
	var size := 24
	var w := UiStyle.text_width(t, size, "black")
	var y := vp.y * 0.44
	UiStyle.pill(self, Rect2(vp.x * 0.5 - w * 0.5 - 26, y - 34, w + 52, 48), Color(UiStyle.INK, 0.7 * a))
	draw_rect(Rect2(vp.x * 0.5 - w * 0.5 - 26, y + 12, (w + 52) * float(_coach_i + 1) / _coach.size(), 3), Color(UiStyle.AMBER, a))
	UiStyle.text(self, Vector2(vp.x * 0.5 - w * 0.5, y), t, size, Color(UiStyle.WHITE, a), "black")
	if step[2] == "steer":
		var l := "◀ " + ("✓" if _coach_steer_l else "·") + "      " + ("✓" if _coach_steer_r else "·") + " ▶"
		var lw := UiStyle.text_width(l, 18, "black")
		UiStyle.text(self, Vector2(vp.x * 0.5 - lw * 0.5, y + 40), l, 18, Color(UiStyle.AMBER, a), "black")


func _draw_contracts(s: Rect2) -> void:
	if contracts == null or not contracts.running or contracts.active.is_empty():
		return
	var x := s.position.x + (62.0 if touch_mode else 0.0)
	var y := s.position.y + 112.0
	UiStyle.text(self, Vector2(x, y), "CONTRACTS", 11, UiStyle.AMBER, "black")
	y += 8.0
	for c in contracts.active:
		var f: float = c["flash"]
		var r := Rect2(x - 6, y + 2, 214, 34)
		UiStyle.pill(self, r, Color(UiStyle.AMBER, 0.35 * f) if f > 0.0 else Color(UiStyle.INK, 0.85 if Settings.high_contrast_hud else 0.42))
		UiStyle.text(self, Vector2(x + 2, y + 19), str(c["label"]), 13, UiStyle.WHITE, "bold")
		var k: float = c["progress"]
		draw_rect(Rect2(x + 2, y + 26, 160, 4), Color(1, 1, 1, 0.15))
		draw_rect(Rect2(x + 2, y + 26, 160 * k, 4), UiStyle.AMBER)
		UiStyle.text(self, Vector2(x + 170, y + 31), "$%d" % int(c["cash"]), 11, UiStyle.DIM, "bold")
		y += 39.0


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
				elif not m[3]:
					kind = "enroute"  # no car yet: a hollow ring, not a dot
				ms.append([m[0], kind])
			for rb in director.roadblocks:
				if not rb["passed"]:
					ms.append([rb["pos"], "roadblock"])
			if director.heli:
				ms.append([director.heli.global_position, "heli"])
			if arena:
				for c in arena.alive:
					if c != player and is_instance_valid(c):
						ms.append([c.global_position, "rival"])
			if repairs and repairs.active and player:
				var near := repairs.nearest(player.global_position)
				for rp in repairs.positions():
					ms.append([rp, "repair_pin" if rp == near else "repair"])
			minimap.markers = ms
	for e in _events:
		e[3] += dt
	_events = _events.filter(func(e): return e[3] < 2.2)
	_radio_t -= dt
	_warn_t -= dt
	_flash = maxf(0.0, _flash - dt * 1.6)
	_done_pop_t -= dt
	if game and game.state == 1:  # PLAYING
		_coach_update(dt)
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
	if Settings.high_contrast_hud:
		# Solid backing behind every readout (bright skies, glare, low vision).
		var hx := s.position.x + (62.0 if touch_mode else 0.0)
		UiStyle.pill(self, Rect2(hx - 10, s.position.y - 4, 230, 104), Color(0, 0, 0, 0.72))
		UiStyle.pill(self, Rect2(vp.x * 0.5 - 110, s.position.y - 2, 220, 46), Color(0, 0, 0, 0.72))
		UiStyle.pill(self, Rect2(vp.x * 0.5 - 104, s.end.y - 92, 208, 96), Color(0, 0, 0, 0.72))
	_draw_time_heat(s)
	_draw_score(s, vp)
	_draw_speed(s, vp)
	_draw_bust(vp)
	_draw_contracts(s)
	_draw_coach(vp)
	if arena:
		_draw_countdown(vp)
	if _done_pop_t > 0.0:
		var a3 := clampf(_done_pop_t * 2.0, 0.0, 1.0)
		var w3 := UiStyle.text_width(_done_pop, 22, "black")
		var y3 := vp.y * 0.66
		UiStyle.pill(self, Rect2(vp.x * 0.5 - w3 * 0.5 - 20, y3 - 28, w3 + 40, 40), Color(UiStyle.AMBER, 0.9 * a3))
		UiStyle.text(self, Vector2(vp.x * 0.5 - w3 * 0.5, y3), _done_pop, 22, Color(UiStyle.INK, a3), "black")
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
	var x := s.position.x + (62.0 if touch_mode else 0.0)
	var y := s.position.y
	var t: float = score.time if score else 0.0
	UiStyle.text(self, Vector2(x, y + 40), UiStyle.time_str(t), 42, UiStyle.WHITE, "black")
	if arena:
		_draw_battle(x, y + 52)
		return
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


func _draw_countdown(vp: Vector2) -> void:
	var c := arena.countdown
	var go := arena.time < 0.8 and c <= 0.0 and arena.running
	if c <= 0.0 and not go:
		return
	var txt := "GO!" if go else str(ceili(c))
	var f := (1.0 - fmod(c, 1.0)) if not go else arena.time / 0.8
	var size := int(120 + 40 * (1.0 - f))
	var a := clampf(1.6 - f * 1.2, 0.0, 1.0) if go else clampf(2.0 - f * 1.4, 0.0, 1.0)
	var w := UiStyle.text_width(txt, size, "black")
	var y := vp.y * 0.45 + size * 0.35
	UiStyle.text(self, Vector2(vp.x * 0.5 - w * 0.5 + 4, y + 4), txt, size, Color(0, 0, 0, 0.5 * a), "black")
	UiStyle.text(self, Vector2(vp.x * 0.5 - w * 0.5, y), txt, size, Color(UiStyle.AMBER if go else UiStyle.WHITE, a), "black")
	if not go:
		var sub := str(game.MODE_NAMES.get(game.mode, "")).to_upper() + "  ·  LAST CAR STANDING WINS"
		var sw := UiStyle.text_width(sub, 22, "black")
		UiStyle.text(self, Vector2(vp.x * 0.5 - sw * 0.5, vp.y * 0.45 + 110), sub, 22, Color(UiStyle.WHITE, 0.9), "black")


## Battle: cars still up there (a pip each, the player's gold), and our knockouts.
func _draw_battle(x: float, y: float) -> void:
	var n := arena.alive.size()
	UiStyle.text(self, Vector2(x, y + 14), "CARS LEFT", 12, UiStyle.DIM, "bold")
	UiStyle.text(self, Vector2(x + 76, y + 16), "%d" % n, 20, UiStyle.WHITE, "black")
	for i in Arena.N_CARS:
		var on := i < n
		var col := Color(1, 1, 1, 0.14)
		if on:
			col = UiStyle.GOLD if i == 0 and player in arena.alive else UiStyle.AMBER.lerp(UiStyle.RED, 0.5)
		draw_rect(Rect2(x + i * 13, y + 24, 9, 9), col)
	var ko := arena.knockouts(player)
	UiStyle.text(self, Vector2(x, y + 52), "KNOCKOUTS  %d" % ko, 13, Color(UiStyle.AMBER, 0.9), "black")


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
	# Damage: a bar that drains (the engine never dies, the bodywork does),
	# a top-down diagram of the panels, and the way to the nearest repair.
	var bw := 180.0
	var bx := cx - bw * 0.5
	var bar_y := by - 22
	draw_rect(Rect2(bx, bar_y, bw, 5), Color(1, 1, 1, 0.14))
	var hcol := UiStyle.WHITE.lerp(UiStyle.AMBER, clampf((0.8 - player.health) * 2.5, 0.0, 1.0)).lerp(UiStyle.RED, clampf((0.45 - player.health) * 3.0, 0.0, 1.0))
	draw_rect(Rect2(bx, bar_y, bw * player.health, 5), hcol)
	var lost := player.parts_lost()
	var lbl := "BODY" if player.health > 0.45 else "HEAVY DAMAGE"
	if lost > 0:
		lbl = "%s · %d PANEL%s OFF" % [lbl, lost, "" if lost == 1 else "S"]
	if player.puncture > 0.0:
		lbl = "TYRES SHREDDED"
	UiStyle.text(self, Vector2(bx, bar_y + 18), lbl, 11, Color(hcol, 0.8), "bold")
	_draw_car_diagram(Vector2(bx - 40, by - 66))
	if repairs and repairs.active and (player.health < 0.9 or lost > 0 or player.puncture > 0.0):
		var rp := repairs.nearest(player.global_position)
		if rp != Vector3.INF:
			var dist := player.global_position.distance_to(rp)
			var rt := "REPAIR  %d m" % int(dist)
			var rw := UiStyle.text_width(rt, 13, "black")
			var ry := bar_y + 40
			var a := 0.65 + 0.35 * sin(Time.get_ticks_msec() * 0.006) if player.health < 0.5 else 0.85
			UiStyle.text(self, Vector2(cx - rw * 0.5 + 10, ry), rt, 13, Color(UiStyle.GREEN, a), "black")
			# Arrow toward it, relative to where the camera looks.
			if minimap and minimap.camera:
				var to := rp - player.global_position
				var yaw: float = minimap.camera.view_yaw()
				var f := Vector2(-sin(yaw), -cos(yaw))
				var r := Vector2(-f.y, f.x)
				var d2 := Vector2(to.x, to.z)
				var ang := atan2(d2.dot(r), d2.dot(f))
				var ac := Vector2(cx - rw * 0.5 - 4, ry - 5)
				var pts := PackedVector2Array([Vector2(0, -7), Vector2(5, 5), Vector2(0, 2), Vector2(-5, 5)])
				for i in pts.size():
					pts[i] = ac + pts[i].rotated(ang)
				draw_colored_polygon(pts, Color(UiStyle.GREEN, a))
	if kit and not touch_mode:
		_draw_kit_keys(s)
	if float(player.spec.get("nitro", 0.0)) > 0.0:
		var nx := bx + bw - 60
		UiStyle.text(self, Vector2(nx - 4, bar_y + 18), "NITRO", 11, UiStyle.BLUE, "bold")
		draw_rect(Rect2(nx + 36, bar_y + 10, 28, 4), Color(1, 1, 1, 0.14))
		draw_rect(Rect2(nx + 36, bar_y + 10, 28 * player.nitro_amount, 4), UiStyle.BLUE)


## Top-down outline of the car, one block per panel: white when fine,
## amber/red as it wears, an empty outline once it has come off. Armour
## plates show as a frame round the car.
func _draw_car_diagram(at: Vector2) -> void:
	var w := 24.0
	var h := 44.0
	var p := player.parts
	var cols := func(k: String) -> Color:
		var v: float = p.get(k, 1.0)
		if v <= 0.0:
			return Color(1, 1, 1, 0.0)
		return UiStyle.WHITE.lerp(UiStyle.AMBER, clampf((0.75 - v) * 2.5, 0.0, 1.0)).lerp(UiStyle.RED, clampf((0.4 - v) * 3.0, 0.0, 1.0))
	var blocks := {
		"bumper_f": Rect2(3, 0, w - 6, 5), "hood": Rect2(3, 6, w - 6, 9),
		"door_l": Rect2(0, 16, 5, 14), "door_r": Rect2(w - 5, 16, 5, 14),
		"boot": Rect2(3, 31, w - 6, 7), "bumper_r": Rect2(3, 39, w - 6, 5),
	}
	draw_rect(Rect2(at + Vector2(6, 16), Vector2(w - 12, 14)), Color(1, 1, 1, 0.12))
	for k in blocks:
		var r: Rect2 = blocks[k]
		r.position += at
		var c: Color = cols.call(k)
		if c.a > 0.0:
			draw_rect(r, Color(c, 0.85))
		else:
			draw_rect(r, Color(UiStyle.RED, 0.7), false, 1.0)
	if p.has("plate_l"):
		for k in ["plate_l", "plate_rt", "plate_f", "plate_r"]:
			var v: float = p[k]
			var r2: Rect2 = {"plate_l": Rect2(-4, 14, 2, 18), "plate_rt": Rect2(w + 2, 14, 2, 18),
				"plate_f": Rect2(2, -4, w - 4, 2), "plate_r": Rect2(2, h + 2, w - 4, 2)}[k]
			r2.position += at
			draw_rect(r2, Color(0.6, 0.65, 0.7, 0.9) if v > 0.0 else Color(1, 1, 1, 0.12))


## Keyboard / pad: what the Workshop gear is bound to and whether it's ready.
func _draw_kit_keys(s: Rect2) -> void:
	var x := s.end.x - 8
	var y := s.end.y - 8
	var lines: Array = []
	if kit.has_jump():
		var ready := kit.jump_ready()
		lines.append(["E · JUMP", ready >= 1.0, ready])
	if kit.has_drop():
		lines.append(["Q · %s ×%d" % ["CALTROPS" if kit.rear == "caltrops" else "MINES", kit.charges], kit.charges > 0, kit.recharge_k()])
	for l in lines:
		var t: String = l[0]
		var w := UiStyle.text_width(t, 14, "black")
		var r := Rect2(x - w - 24, y - 30, w + 24, 30)
		UiStyle.pill(self, r, Color(0, 0, 0, 0.5))
		if not l[1]:
			draw_rect(Rect2(r.position.x + 10, r.end.y - 5, (r.size.x - 20) * clampf(l[2], 0.0, 1.0), 2), UiStyle.AMBER)
		UiStyle.text(self, r.position + Vector2(12, 21), t, 14, UiStyle.WHITE if l[1] else UiStyle.DIM, "black")
		y -= 36


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
