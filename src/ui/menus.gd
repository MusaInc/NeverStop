class_name Menus
extends Control
## Every menu screen, built in code with one theme:
##   title     NEVER STOP over the live attract chase: PLAY / GARAGE / RECORDS / SETTINGS
##   garage    rotating car preview (its own little studio world), stats,
##             buy / select, upgrades, paint, wheels
##   records   personal bests, lifetime totals, challenges, recent runs
##   settings  graphics, controls, camera, audio, accessibility
##   pause     resume / restart / settings / quit
##   results   BUSTED: the run in numbers, records, challenges, cash; RETRY first
## Works with touch (mouse emulation), mouse, keyboard and gamepad (focus).

var game: Node
var screens := {}
var current := ""
var _theme: Theme
var _results_rows: Array = []
var _count_t := 0.0
var _garage: GarageView
var _garage_sel := 0
var _garage_box: VBoxContainer
var _garage_info: Control
var _cash_labels: Array = []
var _back_to := "title"
var _toast: Label
var _toast_t := 0.0


func setup(p_game: Node) -> void:
	game = p_game
	process_mode = Node.PROCESS_MODE_ALWAYS
	set_anchors_preset(PRESET_FULL_RECT)
	mouse_filter = MOUSE_FILTER_IGNORE
	_theme = _make_theme()
	theme = _theme
	for n in ["title", "garage", "records", "settings", "pause", "results"]:
		var c := Control.new()
		c.name = n
		c.set_anchors_preset(PRESET_FULL_RECT)
		c.mouse_filter = MOUSE_FILTER_IGNORE
		c.visible = false
		add_child(c)
		screens[n] = c
	_toast = Label.new()
	_toast.add_theme_font_size_override("font_size", 20)
	_toast.set_anchors_and_offsets_preset(PRESET_CENTER_BOTTOM)
	_toast.position.y -= 90
	_toast.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_toast.modulate.a = 0.0
	add_child(_toast)
	_build_title()
	var start: String = game.args.get("menu", "")
	if start != "" and screens.has(start):
		show_screen.call_deferred(start)


func toast(t: String) -> void:
	_toast.text = t
	_toast_t = 2.2


func _process(dt: float) -> void:
	_toast_t -= dt
	_toast.modulate.a = clampf(_toast_t * 2.0, 0.0, 1.0)
	_toast.position.x = (get_viewport_rect().size.x - _toast.size.x) * 0.5
	if current == "results":
		_count_t += dt
		for r in _results_rows:
			var k := clampf((_count_t - float(r[3])) / 0.6, 0.0, 1.0)
			(r[0] as Label).text = r[1].call(k)
	for l in _cash_labels:
		if is_instance_valid(l):
			(l as Label).text = "$" + UiStyle.thousands(SaveData.cash())


func show_screen(name: String) -> void:
	for k in screens:
		(screens[k] as Control).visible = false
	if _garage and name != "garage":
		_garage.queue_free()
		_garage = null
	current = name
	if name == "":
		return
	var c: Control = screens[name]
	for ch in c.get_children():
		ch.queue_free()
	match name:
		"title": _build_title()
		"garage": _build_garage()
		"records": _build_records()
		"settings": _build_settings()
		"pause": _build_pause()
	c.visible = true
	_focus_first.call_deferred(c)


func _focus_first(c: Control) -> void:
	for b in c.find_children("*", "Button", true, false):
		if (b as Button).visible and not (b as Button).disabled:
			(b as Button).grab_focus()
			return


# ---------------------------------------------------------------- theme
func _make_theme() -> Theme:
	var t := Theme.new()
	t.default_font = UiStyle.font("bold")
	t.default_font_size = 20
	var normal := StyleBoxFlat.new()
	normal.bg_color = Color(0.04, 0.05, 0.07, 0.72)
	normal.border_color = Color(1, 1, 1, 0.12)
	normal.set_border_width_all(1)
	normal.set_corner_radius_all(6)
	normal.content_margin_left = 22
	normal.content_margin_right = 22
	normal.content_margin_top = 12
	normal.content_margin_bottom = 12
	var hover := normal.duplicate()
	hover.bg_color = Color(0.1, 0.11, 0.14, 0.85)
	hover.border_color = Color(UiStyle.AMBER, 0.8)
	var pressed := normal.duplicate()
	pressed.bg_color = Color(UiStyle.AMBER, 0.95)
	var focus := normal.duplicate()
	focus.bg_color = Color(0, 0, 0, 0)
	focus.border_color = UiStyle.AMBER
	focus.set_border_width_all(2)
	var disabled := normal.duplicate()
	disabled.bg_color = Color(0.04, 0.05, 0.07, 0.4)
	t.set_stylebox("normal", "Button", normal)
	t.set_stylebox("hover", "Button", hover)
	t.set_stylebox("pressed", "Button", pressed)
	t.set_stylebox("focus", "Button", focus)
	t.set_stylebox("disabled", "Button", disabled)
	t.set_color("font_color", "Button", UiStyle.WHITE)
	t.set_color("font_hover_color", "Button", UiStyle.WHITE)
	t.set_color("font_pressed_color", "Button", UiStyle.INK)
	t.set_color("font_disabled_color", "Button", Color(1, 1, 1, 0.35))
	t.set_color("font_focus_color", "Button", UiStyle.WHITE)
	t.set_color("font_color", "Label", UiStyle.WHITE)
	t.set_color("font_shadow_color", "Label", Color(0, 0, 0, 0.5))
	t.set_constant("shadow_offset_y", "Label", 2)
	var panel := StyleBoxFlat.new()
	panel.bg_color = Color(0.03, 0.035, 0.05, 0.86)
	panel.set_corner_radius_all(10)
	panel.border_color = Color(1, 1, 1, 0.07)
	panel.set_border_width_all(1)
	panel.content_margin_left = 24
	panel.content_margin_right = 24
	panel.content_margin_top = 18
	panel.content_margin_bottom = 18
	t.set_stylebox("panel", "PanelContainer", panel)
	var grab := StyleBoxFlat.new()
	grab.bg_color = UiStyle.AMBER
	grab.set_corner_radius_all(4)
	var track := StyleBoxFlat.new()
	track.bg_color = Color(1, 1, 1, 0.15)
	track.content_margin_top = 3
	track.content_margin_bottom = 3
	t.set_stylebox("slider", "HSlider", track)
	t.set_stylebox("grabber_area", "HSlider", grab)
	t.set_stylebox("grabber_area_highlight", "HSlider", grab)
	return t


func _btn(text: String, cb: Callable, primary := false, size := 22) -> Button:
	var b := Button.new()
	b.text = text
	b.focus_mode = Control.FOCUS_ALL
	b.add_theme_font_size_override("font_size", size)
	b.custom_minimum_size = Vector2(240, 54)
	if primary:
		var sb := StyleBoxFlat.new()
		sb.bg_color = UiStyle.AMBER
		sb.set_corner_radius_all(6)
		sb.content_margin_left = 28
		sb.content_margin_right = 28
		sb.content_margin_top = 12
		sb.content_margin_bottom = 12
		b.add_theme_stylebox_override("normal", sb)
		var sh := sb.duplicate()
		sh.bg_color = UiStyle.AMBER.lightened(0.15)
		b.add_theme_stylebox_override("hover", sh)
		b.add_theme_color_override("font_color", UiStyle.INK)
		b.add_theme_color_override("font_hover_color", UiStyle.INK)
		b.add_theme_color_override("font_focus_color", UiStyle.INK)
		b.add_theme_font_override("font", UiStyle.font("black"))
	b.pressed.connect(func():
		if game.has_method("ui_click"):
			game.ui_click()
		cb.call())
	return b


func _label(text: String, size := 18, col := UiStyle.WHITE, weight := "bold") -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_font_override("font", UiStyle.font(weight))
	l.add_theme_color_override("font_color", col)
	return l


func _margin(c: Control, l: int, t: int, r: int, b: int) -> MarginContainer:
	var m := MarginContainer.new()
	m.set_anchors_preset(PRESET_FULL_RECT)
	m.add_theme_constant_override("margin_left", l)
	m.add_theme_constant_override("margin_top", t)
	m.add_theme_constant_override("margin_right", r)
	m.add_theme_constant_override("margin_bottom", b)
	m.mouse_filter = MOUSE_FILTER_IGNORE
	c.add_child(m)
	return m


func _cash_label(size := 22) -> Label:
	var l := _label("$0", size, UiStyle.AMBER, "black")
	_cash_labels.append(l)
	return l


func _shade(c: Control, from_left := true, a := 0.75) -> void:
	var g := TextureRect.new()
	var grad := Gradient.new()
	grad.set_color(0, Color(0.02, 0.025, 0.035, a))
	grad.set_color(1, Color(0.02, 0.025, 0.035, 0.0))
	var gt := GradientTexture2D.new()
	gt.gradient = grad
	gt.fill_from = Vector2(0, 0) if from_left else Vector2(0, 1)
	gt.fill_to = Vector2(0.75, 0) if from_left else Vector2(0, 0.2)
	g.texture = gt
	g.set_anchors_preset(PRESET_FULL_RECT)
	g.stretch_mode = TextureRect.STRETCH_SCALE
	g.mouse_filter = MOUSE_FILTER_IGNORE
	c.add_child(g)


# ---------------------------------------------------------------- title
func _build_title() -> void:
	var c: Control = screens["title"]
	_shade(c, true, 0.82)
	var m := _margin(c, 64, 48, 64, 40)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 10)
	m.add_child(v)
	var studio := _label("MUSA STUDIOS PRESENTS", 14, UiStyle.DIM, "bold")
	v.add_child(studio)
	var logo := TitleLogo.new()
	logo.custom_minimum_size = Vector2(520, 130)
	v.add_child(logo)
	var tag := _label("The police will catch you. Make them work for it.", 18, UiStyle.DIM, "semibold")
	v.add_child(tag)
	var sp := Control.new()
	sp.custom_minimum_size.y = 18
	v.add_child(sp)
	var play := _btn("PLAY", func(): game.start_run(), true, 28)
	play.custom_minimum_size = Vector2(300, 64)
	v.add_child(play)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	v.add_child(row)
	for pair in [["GARAGE", "garage"], ["RECORDS", "records"], ["SETTINGS", "settings"]]:
		var target: String = pair[1]
		var b := _btn(pair[0], func(): _back_to = "title"; show_screen(target), false, 18)
		b.custom_minimum_size = Vector2(140, 48)
		row.add_child(b)
	var info := HBoxContainer.new()
	info.add_theme_constant_override("separation", 18)
	v.add_child(info)
	info.add_child(_cash_label(20))
	var best := int(SaveData.data["best_score"])
	if best > 0:
		info.add_child(_label("BEST  %s   ·   %s   ·   HEAT %d" % [UiStyle.thousands(best), UiStyle.time_str(float(SaveData.data["best_time"])), int(SaveData.data["best_heat"])], 16, UiStyle.DIM, "bold"))
	var car_l := _label("CAR  " + str(CarCatalog.CARS[game.car_id]["name"]).to_upper() + "     START  " + str(Progression.STARTS.get(SaveData.data["start"], Progression.STARTS["downtown"])["name"]).to_upper(), 14, UiStyle.DIM, "bold")
	v.add_child(car_l)


class TitleLogo:
	extends Control
	func _process(_dt: float) -> void:
		queue_redraw()
	func _draw() -> void:
		var t := Time.get_ticks_msec() / 1000.0
		var f := UiStyle.font("black")
		var s := 96
		# Siren light sweeping across the letters.
		var ph := fmod(t * 1.3, 2.0)
		var col := UiStyle.RED if ph < 1.0 else UiStyle.BLUE
		var glow := 0.5 + 0.5 * sin(t * 12.0)
		draw_string(f, Vector2(4, 100), "NEVER", HORIZONTAL_ALIGNMENT_LEFT, -1, s, Color(col, 0.25 * glow))
		draw_string(f, Vector2(0, 96), "NEVER", HORIZONTAL_ALIGNMENT_LEFT, -1, s, UiStyle.WHITE)
		var w := f.get_string_size("NEVER ", HORIZONTAL_ALIGNMENT_LEFT, -1, s).x
		draw_string(f, Vector2(w, 96), "STOP", HORIZONTAL_ALIGNMENT_LEFT, -1, s, UiStyle.AMBER)
		var w2 := f.get_string_size("NEVER STOP", HORIZONTAL_ALIGNMENT_LEFT, -1, s).x
		draw_rect(Rect2(0, 112, w2 * 0.5, 5), Color(UiStyle.RED, 0.4 + 0.6 * (1.0 if ph < 1.0 else 0.2)))
		draw_rect(Rect2(w2 * 0.5, 112, w2 * 0.5, 5), Color(UiStyle.BLUE, 0.4 + 0.6 * (1.0 if ph >= 1.0 else 0.2)))


# ---------------------------------------------------------------- pause
func _build_pause() -> void:
	var c: Control = screens["pause"]
	var bg := ColorRect.new()
	bg.color = Color(0.01, 0.015, 0.02, 0.6)
	bg.set_anchors_preset(PRESET_FULL_RECT)
	c.add_child(bg)
	var center := CenterContainer.new()
	center.set_anchors_preset(PRESET_FULL_RECT)
	c.add_child(center)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 12)
	center.add_child(v)
	v.add_child(_label("PAUSED", 44, UiStyle.WHITE, "black"))
	v.add_child(_btn("RESUME", func(): game.resume(), true))
	v.add_child(_btn("RESTART", func(): game.state = game.State.BUSTED; game.start_run()))
	v.add_child(_btn("SETTINGS", func(): _back_to = "pause"; show_screen("settings")))
	v.add_child(_btn("QUIT TO MENU", func(): game.quit_to_menu()))


# ---------------------------------------------------------------- results
func show_results(r: Dictionary) -> void:
	show_screen("")
	current = "results"
	var c: Control = screens["results"]
	for ch in c.get_children():
		ch.queue_free()
	c.visible = true
	_shade(c, true, 0.88)
	var m := _margin(c, 64, 36, 64, 30)
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 40)
	m.add_child(h)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 6)
	v.size_flags_horizontal = SIZE_EXPAND_FILL
	h.add_child(v)
	v.add_child(_label("BUSTED", 76, UiStyle.RED, "black"))
	_results_rows.clear()
	_count_t = 0.0
	var rows := [
		["Survived", func(k): return UiStyle.time_str(float(r["time"]) * k)],
		["Police vehicles wrecked", func(k): return str(int(r["police_wrecked"] * k))],
		["Near misses", func(k): return str(int(r["near_misses"] * k))],
		["Roadblocks escaped", func(k): return str(int(r["roadblocks"] * k))],
		["Distance travelled", func(k): return "%.1f km" % (r["distance"] / 1000.0 * k)],
		["Top speed", func(k): return "%d km/h" % int(r["top_speed"] * 3.6 * k)],
		["Highest heat", func(k): return str(maxi(1, int(round(r["max_heat"] * k))))],
	]
	var i := 0
	for row in rows:
		var hb := HBoxContainer.new()
		hb.custom_minimum_size.x = 460
		var name_l := _label(row[0], 19, UiStyle.DIM, "semibold")
		name_l.size_flags_horizontal = SIZE_EXPAND_FILL
		hb.add_child(name_l)
		var val := _label("", 22, UiStyle.WHITE, "black")
		hb.add_child(val)
		v.add_child(hb)
		_results_rows.append([val, row[1], 0, 0.25 + i * 0.12])
		i += 1
	var sep := Control.new()
	sep.custom_minimum_size.y = 6
	v.add_child(sep)
	var fs := HBoxContainer.new()
	fs.custom_minimum_size.x = 460
	var fl := _label("FINAL SCORE", 22, UiStyle.AMBER, "black")
	fl.size_flags_horizontal = SIZE_EXPAND_FILL
	fs.add_child(fl)
	var fv := _label("", 40, UiStyle.AMBER, "black")
	fs.add_child(fv)
	v.add_child(fs)
	_results_rows.append([fv, func(k): return UiStyle.thousands(int(r["score"] * k)), 0, 1.2])
	# Right column: records, challenges, cash, buttons.
	var right := VBoxContainer.new()
	right.add_theme_constant_override("separation", 10)
	right.custom_minimum_size.x = 300
	h.add_child(right)
	var top := Control.new()
	top.custom_minimum_size.y = 40
	right.add_child(top)
	var earned := _label("+$%s" % UiStyle.thousands(int(r["currency"])), 30, UiStyle.AMBER, "black")
	right.add_child(earned)
	right.add_child(_cash_label(16))
	var names := {"best_score": "NEW BEST SCORE", "best_time": "LONGEST CHASE", "best_heat": "HIGHEST HEAT",
		"best_wrecked": "MOST COPS WRECKED", "best_near_misses": "MOST NEAR MISSES", "best_distance": "FURTHEST DRIVE"}
	for rec in r.get("records", []):
		if SaveData.data["runs"] > 1 or rec == "best_score":
			right.add_child(_label("★ " + str(names.get(rec, rec)), 16, UiStyle.AMBER, "bold"))
	for ch in r.get("challenges", []):
		right.add_child(_label("✓ %s  +$%s" % [ch["name"], UiStyle.thousands(int(ch["reward"]))], 15, UiStyle.BLUE.lightened(0.3), "bold"))
	var gap := Control.new()
	gap.size_flags_vertical = SIZE_EXPAND_FILL
	right.add_child(gap)
	right.add_child(_btn("RETRY", func(): game.start_run(), true, 26))
	right.add_child(_btn("CHANGE CAR", func(): _back_to = "title"; game.quit_to_menu(); show_screen("garage")))
	var row2 := HBoxContainer.new()
	row2.add_theme_constant_override("separation", 8)
	right.add_child(row2)
	var rb := _btn("RECORDS", func(): _back_to = "title"; game.quit_to_menu(); show_screen("records"), false, 16)
	rb.custom_minimum_size = Vector2(116, 46)
	row2.add_child(rb)
	var mb := _btn("MENU", func(): game.quit_to_menu(), false, 16)
	mb.custom_minimum_size = Vector2(116, 46)
	row2.add_child(mb)
	_focus_first.call_deferred(right)


# ---------------------------------------------------------------- records
func _build_records() -> void:
	var c: Control = screens["records"]
	_shade(c, true, 0.9)
	var m := _margin(c, 56, 30, 56, 24)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 12)
	m.add_child(v)
	var head := HBoxContainer.new()
	v.add_child(head)
	var t := _label("RECORDS", 40, UiStyle.WHITE, "black")
	t.size_flags_horizontal = SIZE_EXPAND_FILL
	head.add_child(t)
	head.add_child(_btn("BACK", func(): show_screen(_back_to), false, 16))
	var cols := HBoxContainer.new()
	cols.add_theme_constant_override("separation", 30)
	cols.size_flags_vertical = SIZE_EXPAND_FILL
	v.add_child(cols)
	var d: Dictionary = SaveData.data
	var bests := VBoxContainer.new()
	bests.custom_minimum_size.x = 330
	cols.add_child(bests)
	bests.add_child(_label("PERSONAL BESTS", 14, UiStyle.AMBER, "black"))
	for pair in [["Score", UiStyle.thousands(int(d["best_score"]))], ["Longest chase", UiStyle.time_str(float(d["best_time"]))],
			["Highest heat", str(int(d["best_heat"]))], ["Cops wrecked", str(int(d["best_wrecked"]))],
			["Near misses", str(int(d["best_near_misses"]))], ["Distance", "%.1f km" % (float(d["best_distance"]) / 1000.0)]]:
		bests.add_child(_row(pair[0], pair[1]))
	bests.add_child(_label(" ", 8))
	bests.add_child(_label("LIFETIME", 14, UiStyle.AMBER, "black"))
	for pair in [["Chases", str(int(d["runs"]))], ["Time on the run", UiStyle.time_str(float(d["total_time"]))],
			["Distance", "%.1f km" % (float(d["total_distance"]) / 1000.0)], ["Cops wrecked", str(int(d["total_wrecked"]))],
			["Roadblocks escaped", str(int(d["total_roadblocks"]))], ["Cash earned", "$" + UiStyle.thousands(int(d["cash_earned"]))]]:
		bests.add_child(_row(pair[0], pair[1]))
	var ch := VBoxContainer.new()
	ch.size_flags_horizontal = SIZE_EXPAND_FILL
	cols.add_child(ch)
	var done := 0
	for cc in Progression.CHALLENGES:
		if SaveData.challenge_done(cc["id"]):
			done += 1
	ch.add_child(_label("CHALLENGES  %d / %d" % [done, Progression.CHALLENGES.size()], 14, UiStyle.AMBER, "black"))
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	ch.add_child(scroll)
	var list := VBoxContainer.new()
	list.size_flags_horizontal = SIZE_EXPAND_FILL
	scroll.add_child(list)
	for cc in Progression.CHALLENGES:
		var ok := SaveData.challenge_done(cc["id"])
		var hb := HBoxContainer.new()
		var nl := _label(("✓  " if ok else "·  ") + str(cc["name"]) + "  —  " + str(cc["desc"]), 15, UiStyle.WHITE if ok else UiStyle.DIM, "semibold")
		nl.size_flags_horizontal = SIZE_EXPAND_FILL
		hb.add_child(nl)
		hb.add_child(_label("$" + UiStyle.thousands(int(cc["reward"])), 15, UiStyle.AMBER if not ok else UiStyle.DIM, "bold"))
		list.add_child(hb)


func _row(a: String, b: String) -> HBoxContainer:
	var hb := HBoxContainer.new()
	var l := _label(a, 16, UiStyle.DIM, "semibold")
	l.size_flags_horizontal = SIZE_EXPAND_FILL
	hb.add_child(l)
	hb.add_child(_label(b, 17, UiStyle.WHITE, "black"))
	return hb


# ---------------------------------------------------------------- settings
func _build_settings() -> void:
	var c: Control = screens["settings"]
	_shade(c, true, 0.9)
	var m := _margin(c, 56, 30, 56, 24)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 10)
	m.add_child(v)
	var head := HBoxContainer.new()
	v.add_child(head)
	var t := _label("SETTINGS", 40, UiStyle.WHITE, "black")
	t.size_flags_horizontal = SIZE_EXPAND_FILL
	head.add_child(t)
	head.add_child(_btn("DONE", func(): Settings.save(); show_screen(_back_to), true, 16))
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	v.add_child(scroll)
	var grid := GridContainer.new()
	grid.columns = 2
	grid.add_theme_constant_override("h_separation", 30)
	grid.add_theme_constant_override("v_separation", 8)
	grid.size_flags_horizontal = SIZE_EXPAND_FILL
	scroll.add_child(grid)
	_choice(grid, "Graphics", ["Low", "Medium", "High"], Settings.quality, func(i): Settings.quality = i; Settings.apply(); toast("Applies fully on the next chase"))
	_choice(grid, "Steering", ["Slide", "Buttons", "Tilt"], ["zones", "buttons", "tilt"].find(Settings.steer_mode),
		func(i): Settings.steer_mode = ["zones", "buttons", "tilt"][i]; game.touch.steer_mode = Settings.steer_mode)
	_slider(grid, "Steering sensitivity", 0.5, 1.6, Settings.steer_sensitivity, func(x): Settings.steer_sensitivity = x)
	_choice(grid, "Camera", ["Near", "Normal", "Far"], Settings.camera_distance, func(i): Settings.camera_distance = i; game.camera.distance_setting = i)
	_choice(grid, "Time of day", ["Cycle", "Day", "Sunset", "Night"], ["cycle", "day", "sunset", "night"].find(Settings.time_of_day),
		func(i): Settings.time_of_day = ["cycle", "day", "sunset", "night"][i]; Settings.apply())
	_slider(grid, "Music", 0.0, 1.0, Settings.music_volume, func(x): Settings.music_volume = x; Settings.apply())
	_slider(grid, "Sound effects", 0.0, 1.0, Settings.sfx_volume, func(x): Settings.sfx_volume = x; Settings.apply())
	_toggle(grid, "Vibration", Settings.haptics, func(b): Settings.haptics = b)
	_toggle(grid, "Reduce motion (no shake, calmer FOV)", Settings.reduce_motion, func(b): Settings.reduce_motion = b; game.camera.reduce_motion = b)
	_toggle(grid, "Show performance", Settings.show_perf, func(b): Settings.show_perf = b; game.hud.perf = b)


func _choice(grid: GridContainer, name: String, opts: Array, idx: int, cb: Callable) -> void:
	grid.add_child(_label(name, 18, UiStyle.DIM, "semibold"))
	var hb := HBoxContainer.new()
	hb.add_theme_constant_override("separation", 6)
	grid.add_child(hb)
	var buttons: Array = []
	for i in opts.size():
		var b := Button.new()
		b.text = opts[i]
		b.toggle_mode = true
		b.button_pressed = i == idx
		b.custom_minimum_size = Vector2(110, 44)
		b.add_theme_font_size_override("font_size", 16)
		buttons.append(b)
		hb.add_child(b)
		var k := i
		b.pressed.connect(func():
			for o in buttons:
				o.button_pressed = o == b
			cb.call(k))


func _slider(grid: GridContainer, name: String, lo: float, hi: float, val: float, cb: Callable) -> void:
	grid.add_child(_label(name, 18, UiStyle.DIM, "semibold"))
	var s := HSlider.new()
	s.min_value = lo
	s.max_value = hi
	s.step = 0.05
	s.value = val
	s.custom_minimum_size = Vector2(340, 40)
	s.value_changed.connect(cb)
	grid.add_child(s)


func _toggle(grid: GridContainer, name: String, val: bool, cb: Callable) -> void:
	grid.add_child(_label(name, 18, UiStyle.DIM, "semibold"))
	var b := Button.new()
	b.toggle_mode = true
	b.button_pressed = val
	b.text = "ON" if val else "OFF"
	b.custom_minimum_size = Vector2(110, 44)
	b.toggled.connect(func(on): b.text = "ON" if on else "OFF"; cb.call(on))
	grid.add_child(b)


# ---------------------------------------------------------------- garage
func _build_garage() -> void:
	var c: Control = screens["garage"]
	_garage = GarageView.new()
	_garage.set_anchors_preset(PRESET_FULL_RECT)
	_garage.mouse_filter = MOUSE_FILTER_PASS
	c.add_child(_garage)
	_shade(c, true, 0.7)
	_garage_sel = maxi(0, CarCatalog.ORDER.find(game.car_id))
	var m := _margin(c, 48, 26, 48, 22)
	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 8)
	m.add_child(root)
	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 14)
	root.add_child(head)
	var t := _label("GARAGE", 36, UiStyle.WHITE, "black")
	t.size_flags_horizontal = SIZE_EXPAND_FILL
	head.add_child(t)
	head.add_child(_cash_label(24))
	head.add_child(_btn("BACK", func(): show_screen(_back_to), false, 16))
	var body := HBoxContainer.new()
	body.size_flags_vertical = SIZE_EXPAND_FILL
	root.add_child(body)
	_garage_box = VBoxContainer.new()
	_garage_box.custom_minimum_size.x = 380
	_garage_box.add_theme_constant_override("separation", 8)
	body.add_child(_garage_box)
	var nav := HBoxContainer.new()
	nav.add_theme_constant_override("separation", 10)
	root.add_child(nav)
	var prev := _btn("◀", func(): _garage_pick(-1), false, 22)
	prev.custom_minimum_size = Vector2(64, 50)
	nav.add_child(prev)
	var nxt := _btn("▶", func(): _garage_pick(1), false, 22)
	nxt.custom_minimum_size = Vector2(64, 50)
	nav.add_child(nxt)
	_garage_refresh()


func _garage_pick(d: int) -> void:
	_garage_sel = posmod(_garage_sel + d, CarCatalog.ORDER.size())
	_garage_refresh()


func _garage_refresh() -> void:
	for ch in _garage_box.get_children():
		ch.queue_free()
	var id: String = CarCatalog.ORDER[_garage_sel]
	var info: Dictionary = CarCatalog.CARS[id]
	var owned := SaveData.owns(id)
	var spec := SaveData.car_spec(id)
	if _garage:
		_garage.show_car(spec)
	_garage_box.add_child(_label(str(info["class"]).to_upper(), 14, UiStyle.AMBER, "black"))
	_garage_box.add_child(_label(str(info["name"]).to_upper(), 38, UiStyle.WHITE, "black"))
	var blurb := _label(info["blurb"], 15, UiStyle.DIM, "semibold")
	blurb.autowrap_mode = TextServer.AUTOWRAP_WORD
	blurb.custom_minimum_size.x = 360
	_garage_box.add_child(blurb)
	var st := CarCatalog.stats(spec)
	for k in ["speed", "accel", "handling", "durability"]:
		_garage_box.add_child(StatBar.make(k.to_upper(), st[k]))
	var drive: String = {"fwd": "Front-wheel drive", "rwd": "Rear-wheel drive", "awd": "All-wheel drive"}[spec["drive"]]
	_garage_box.add_child(_label("%s  ·  %d km/h  ·  %d kg" % [drive, int(spec["top_speed"] * 3.6), int(spec["mass"])], 13, UiStyle.DIM, "bold"))
	if not owned:
		var price := int(info["price"])
		var buy := _btn("BUY  $" + UiStyle.thousands(price), func():
			if SaveData.spend(price):
				SaveData.data["owned"].append(id)
				SaveData.data["car"] = id
				SaveData.save()
				game.select_car(id)
				toast("%s is yours." % info["name"])
				_garage_refresh()
			else:
				toast("Not enough cash yet: keep running."), true, 20)
		buy.disabled = SaveData.cash() < price
		_garage_box.add_child(buy)
		return
	if game.car_id != id:
		_garage_box.add_child(_btn("DRIVE THIS", func():
			SaveData.data["car"] = id
			SaveData.save()
			game.select_car(id)
			_garage_refresh(), true, 20))
	else:
		_garage_box.add_child(_label("SELECTED", 16, UiStyle.AMBER, "black"))
	# Upgrades.
	var ups := SaveData.upgrades(id)
	var ug := GridContainer.new()
	ug.columns = 2
	ug.add_theme_constant_override("h_separation", 8)
	ug.add_theme_constant_override("v_separation", 6)
	_garage_box.add_child(ug)
	for k in ["engine", "grip", "armour", "nitro"]:
		var lvl := int(ups.get(k, 0))
		var u: Dictionary = CarCatalog.UPGRADES[k]
		var maxed := lvl >= 3
		var price := 0 if maxed else int(u["prices"][lvl])
		var label := "%s  %s" % [u["name"].to_upper(), "●".repeat(lvl) + "○".repeat(3 - lvl)]
		label += "" if maxed else "   $" + UiStyle.thousands(price)
		var key: String = k
		var b := _btn(label, func():
			if SaveData.spend(price):
				var cs := SaveData.car_state(id)
				cs["upgrades"][key] = lvl + 1
				SaveData.save()
				if game.car_id == id:
					game.select_car(id)
				_garage_refresh()
			else:
				toast("Not enough cash."), false, 14)
		b.custom_minimum_size = Vector2(186, 42)
		b.disabled = maxed or SaveData.cash() < price
		ug.add_child(b)
	# Paint and wheels.
	var paints := HBoxContainer.new()
	paints.add_theme_constant_override("separation", 4)
	_garage_box.add_child(paints)
	for pi in CarCatalog.PAINTS.size():
		var p: Array = CarCatalog.PAINTS[pi]
		var sw := Button.new()
		sw.custom_minimum_size = Vector2(30, 30)
		var sb := StyleBoxFlat.new()
		sb.bg_color = p[1]
		sb.set_corner_radius_all(15)
		var cs := SaveData.car_state(id)
		var cur := int(cs.get("paint", -1)) == pi
		sb.border_color = UiStyle.AMBER if cur else Color(1, 1, 1, 0.3)
		sb.set_border_width_all(3 if cur else 1)
		sw.add_theme_stylebox_override("normal", sb)
		sw.add_theme_stylebox_override("hover", sb)
		sw.add_theme_stylebox_override("pressed", sb)
		var owned_p: bool = pi in SaveData.data["paints"] or int(p[2]) == 0
		sw.tooltip_text = "%s%s" % [p[0], "" if owned_p else "  $" + str(p[2])]
		var idx := pi
		sw.pressed.connect(func():
			var price: int = CarCatalog.PAINTS[idx][2]
			var have: bool = idx in SaveData.data["paints"] or price == 0
			if not have:
				if not SaveData.spend(price):
					toast("%s costs $%s." % [CarCatalog.PAINTS[idx][0], UiStyle.thousands(price)])
					return
				SaveData.data["paints"].append(idx)
			SaveData.car_state(id)["paint"] = idx
			SaveData.save()
			if game.car_id == id:
				game.select_car(id)
			toast(CarCatalog.PAINTS[idx][0])
			_garage_refresh())
		paints.add_child(sw)
	var wheels := HBoxContainer.new()
	wheels.add_theme_constant_override("separation", 4)
	_garage_box.add_child(wheels)
	for w in CarCatalog.WHEELS:
		var wid: String = w[0]
		var price: int = w[2]
		var have: bool = wid in SaveData.data["wheels"] or price == 0
		var cur: bool = spec["wheel"] == wid
		var b := _btn(str(w[1]) + ("" if have else " $%d" % price), func():
			if not (wid in SaveData.data["wheels"] or price == 0):
				if not SaveData.spend(price):
					toast("Not enough cash.")
					return
				SaveData.data["wheels"].append(wid)
			SaveData.car_state(id)["wheel"] = wid
			SaveData.save()
			if game.car_id == id:
				game.select_car(id)
			_garage_refresh(), cur, 12)
		b.custom_minimum_size = Vector2(70, 36)
		wheels.add_child(b)
	# Starting location.
	var starts := HBoxContainer.new()
	starts.add_theme_constant_override("separation", 4)
	_garage_box.add_child(starts)
	for sid in Progression.STARTS:
		var sp: Dictionary = Progression.STARTS[sid]
		var have: bool = sid in SaveData.data["starts"]
		var cur: bool = SaveData.data["start"] == sid
		var key: String = sid
		var b := _btn(str(sp["name"]) + ("" if have else " $" + UiStyle.thousands(int(sp["price"]))), func():
			if not (key in SaveData.data["starts"]):
				if not SaveData.spend(int(Progression.STARTS[key]["price"])):
					toast("Not enough cash.")
					return
				SaveData.data["starts"].append(key)
			SaveData.data["start"] = key
			SaveData.save()
			toast("Next chase starts in %s." % Progression.STARTS[key]["name"])
			_garage_refresh(), cur, 11)
		b.custom_minimum_size = Vector2(68, 34)
		starts.add_child(b)


class StatBar:
	extends Control
	var label := ""
	var value := 0.0
	var shown := 0.0
	static func make(l: String, v: float) -> StatBar:
		var s := StatBar.new()
		s.label = l
		s.value = v
		s.custom_minimum_size = Vector2(360, 24)
		return s
	func _process(dt: float) -> void:
		shown = lerpf(shown, value, 1.0 - exp(-8.0 * dt))
		queue_redraw()
	func _draw() -> void:
		UiStyle.text(self, Vector2(0, 16), label, 12, UiStyle.DIM, "bold")
		draw_rect(Rect2(110, 8, 240, 6), Color(1, 1, 1, 0.12))
		draw_rect(Rect2(110, 8, 240 * shown, 6), UiStyle.AMBER)
