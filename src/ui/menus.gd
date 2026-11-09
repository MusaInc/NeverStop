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
var _garage_dots: Dots
var _garage_cta: HBoxContainer
var _garage_tab := "performance"
var _cash_labels: Array = []
var _back_to := "title"
var _toast: Label
var _toast_t := 0.0
var _back_to_about := "title"


func setup(p_game: Node) -> void:
	game = p_game
	process_mode = Node.PROCESS_MODE_ALWAYS
	set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	mouse_filter = MOUSE_FILTER_IGNORE
	_theme = _make_theme()
	theme = _theme
	for n in ["title", "garage", "records", "settings", "pause", "results", "help", "about"]:
		var c := Control.new()
		c.name = n
		c.set_anchors_and_offsets_preset(PRESET_FULL_RECT)
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


## Visible buttons' centres as fractions of the viewport, by label (web tests).
func button_centres() -> Dictionary:
	var out := {}
	var vp := get_viewport_rect().size
	for b in find_children("*", "Button", true, false):
		var bt := b as Button
		if bt.is_visible_in_tree() and bt.text != "":
			var c := bt.get_global_rect().get_center()
			out[bt.text] = [c.x / vp.x, c.y / vp.y]
	return out


## Controller / keyboard: B or Esc goes back (or resumes from pause);
## LB / RB or Q / E switch car in the garage.
func _unhandled_input(ev: InputEvent) -> void:
	if not ev.is_pressed() or ev.is_echo():
		return
	if current == "garage" and _garage_box:
		var d := 0
		if ev is InputEventJoypadButton:
			var jb := (ev as InputEventJoypadButton).button_index
			d = -1 if jb == JOY_BUTTON_LEFT_SHOULDER else (1 if jb == JOY_BUTTON_RIGHT_SHOULDER else 0)
		elif ev is InputEventKey:
			var kc := (ev as InputEventKey).physical_keycode
			d = -1 if kc == KEY_Q else (1 if kc == KEY_E else 0)
		if d != 0:
			_garage_pick(d)
			get_viewport().set_input_as_handled()
			return
	if ev.is_action("ui_cancel") or (ev is InputEventJoypadButton and (ev as InputEventJoypadButton).button_index == JOY_BUTTON_B):
		match current:
			"pause":
				game.resume()
			"settings":
				Settings.save()
				show_screen(_back_to)
			"garage", "records", "help", "about":
				show_screen(_back_to)
			_:
				return
		get_viewport().set_input_as_handled()


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
		"help": _build_help()
		"about": _build_about()
	c.visible = true
	_focus_first.call_deferred(c)


func _focus_first(c: Control) -> void:
	for b in c.find_children("*", "Button", true, false):
		if (b as Button).visible and not (b as Button).disabled:
			(b as Button).grab_focus()
			return


# ---------------------------------------------------------------- theme
func _make_theme() -> Theme:
	# Minimal, Arcade-style: frosted pills, one accent, generous padding.
	var t := Theme.new()
	t.default_font = UiStyle.font("bold")
	t.default_font_size = 20
	var normal := StyleBoxFlat.new()
	normal.bg_color = Color(1, 1, 1, 0.08)
	normal.border_color = Color(1, 1, 1, 0.1)
	normal.set_border_width_all(1)
	normal.set_corner_radius_all(26)
	normal.anti_aliasing = true
	normal.content_margin_left = 22
	normal.content_margin_right = 22
	normal.content_margin_top = 11
	normal.content_margin_bottom = 11
	var hover := normal.duplicate()
	hover.bg_color = Color(1, 1, 1, 0.14)
	var pressed := normal.duplicate()
	pressed.bg_color = Color(UiStyle.WHITE, 0.92)
	var focus := normal.duplicate()
	focus.bg_color = Color(0, 0, 0, 0)
	focus.border_color = Color(UiStyle.WHITE, 0.85)
	focus.set_border_width_all(2)
	var disabled := normal.duplicate()
	disabled.bg_color = Color(1, 1, 1, 0.04)
	disabled.border_color = Color(1, 1, 1, 0.05)
	t.set_stylebox("normal", "Button", normal)
	t.set_stylebox("hover", "Button", hover)
	t.set_stylebox("pressed", "Button", pressed)
	t.set_stylebox("hover_pressed", "Button", pressed)
	t.set_stylebox("focus", "Button", focus)
	t.set_stylebox("disabled", "Button", disabled)
	t.set_color("font_color", "Button", UiStyle.WHITE)
	t.set_color("font_hover_color", "Button", UiStyle.WHITE)
	t.set_color("font_pressed_color", "Button", UiStyle.INK)
	t.set_color("font_hover_pressed_color", "Button", UiStyle.INK)
	t.set_color("font_disabled_color", "Button", Color(1, 1, 1, 0.32))
	t.set_color("font_focus_color", "Button", UiStyle.WHITE)
	t.set_color("font_color", "Label", UiStyle.WHITE)
	t.set_color("font_shadow_color", "Label", Color(0, 0, 0, 0.35))
	t.set_constant("shadow_offset_y", "Label", 1)
	t.set_stylebox("panel", "PanelContainer", UiStyle.glass(20, 0.7))
	var grab := StyleBoxFlat.new()
	grab.bg_color = UiStyle.WHITE
	grab.set_corner_radius_all(6)
	var track := StyleBoxFlat.new()
	track.bg_color = Color(1, 1, 1, 0.14)
	track.set_corner_radius_all(3)
	track.content_margin_top = 3
	track.content_margin_bottom = 3
	t.set_stylebox("slider", "HSlider", track)
	t.set_stylebox("grabber_area", "HSlider", grab)
	t.set_stylebox("grabber_area_highlight", "HSlider", grab)
	var sbar := StyleBoxFlat.new()
	sbar.bg_color = Color(1, 1, 1, 0.18)
	sbar.set_corner_radius_all(3)
	t.set_stylebox("grabber", "VScrollBar", sbar)
	t.set_stylebox("grabber_highlight", "VScrollBar", sbar)
	t.set_stylebox("scroll", "VScrollBar", StyleBoxEmpty.new())
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
		sb.set_corner_radius_all(30)
		sb.anti_aliasing = true
		sb.content_margin_left = 28
		sb.content_margin_right = 28
		sb.content_margin_top = 12
		sb.content_margin_bottom = 12
		b.add_theme_stylebox_override("normal", sb)
		var sh := sb.duplicate()
		sh.bg_color = UiStyle.AMBER.lightened(0.15)
		b.add_theme_stylebox_override("hover", sh)
		b.add_theme_stylebox_override("pressed", sh)
		b.add_theme_stylebox_override("hover_pressed", sh)
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
	m.set_anchors_and_offsets_preset(PRESET_FULL_RECT)
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
	g.set_anchors_and_offsets_preset(PRESET_FULL_RECT)
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
	play.custom_minimum_size = Vector2(440, 64)
	play.size_flags_horizontal = SIZE_SHRINK_BEGIN
	v.add_child(play)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	row.size_flags_horizontal = SIZE_SHRINK_BEGIN
	v.add_child(row)
	for pair in [["Garage", "garage"], ["Records", "records"], ["How to play", "help"], ["Settings", "settings"]]:
		var target: String = pair[1]
		var b := _btn(pair[0], func(): _back_to = "title"; show_screen(target), false, 18)
		b.custom_minimum_size = Vector2(140, 48)
		row.add_child(b)
	var xp := int(SaveData.data.get("xp", 0))
	var rank_row := HBoxContainer.new()
	rank_row.add_theme_constant_override("separation", 12)
	v.add_child(rank_row)
	rank_row.add_child(_label("RANK %d  ·  %s" % [Progression.rank_index(xp) + 1, Progression.rank_name(xp).to_upper()], 16, UiStyle.WHITE, "black"))
	rank_row.add_child(RankBar.make(Progression.rank_progress(xp)))
	var info := HBoxContainer.new()
	info.add_theme_constant_override("separation", 18)
	v.add_child(info)
	if game.daily.get("claimed", false):
		var chip := PanelContainer.new()
		chip.add_theme_stylebox_override("panel", _chip_style(Color(UiStyle.AMBER, 0.16), 14))
		chip.size_flags_horizontal = SIZE_SHRINK_BEGIN
		chip.add_child(_label("Daily bonus · day %d streak · +$%s" % [int(game.daily["day"]), UiStyle.thousands(int(game.daily["reward"]))], 14, UiStyle.AMBER, "black"))
		v.add_child(chip)
	info.add_child(_cash_label(20))
	var best := int(SaveData.data["best_score"])
	if best > 0:
		info.add_child(_label("BEST  %s   ·   %s   ·   HEAT %d" % [UiStyle.thousands(best), UiStyle.time_str(float(SaveData.data["best_time"])), int(SaveData.data["best_heat"])], 16, UiStyle.DIM, "bold"))
	var car_l := _label("CAR  " + str(CarCatalog.CARS[game.car_id]["name"]).to_upper() + "     START  " + str(Progression.STARTS.get(SaveData.data["start"], Progression.STARTS["downtown"])["name"]).to_upper(), 14, UiStyle.DIM, "bold")
	v.add_child(car_l)


class RankBar:
	extends Control
	var k := 0.0
	static func make(p: float) -> RankBar:
		var b := RankBar.new()
		b.k = p
		b.custom_minimum_size = Vector2(200, 20)
		return b
	func _draw() -> void:
		var y := size.y * 0.5
		draw_rect(Rect2(0, y - 3, size.x, 6), Color(1, 1, 1, 0.15))
		draw_rect(Rect2(0, y - 3, size.x * k, 6), UiStyle.AMBER)


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
	bg.set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	c.add_child(bg)
	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	c.add_child(center)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 12)
	center.add_child(v)
	v.add_child(_label("Paused", 40, UiStyle.WHITE, "black"))
	v.add_child(_btn("Resume", func(): game.resume(), true))
	v.add_child(_btn("Restart", func(): game.state = game.State.BUSTED; game.start_run()))
	v.add_child(_btn("Settings", func(): _back_to = "pause"; show_screen("settings")))
	v.add_child(_btn("Quit to menu", func(): game.quit_to_menu()))


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
	v.add_child(_label("Busted", 72, UiStyle.RED, "black"))
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
		["Contracts finished", func(k): return str(int(r.get("contracts", 0) * k))],
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
	if int(r.get("contract_cash", 0)) > 0:
		right.add_child(_label("incl. contracts  +$%s" % UiStyle.thousands(int(r["contract_cash"])), 14, UiStyle.DIM, "bold"))
	var xp := int(SaveData.data.get("xp", 0))
	for rk in r.get("ranks", []):
		right.add_child(_label("▲ RANK UP: %s  +$%s" % [str(rk[0]).to_upper(), UiStyle.thousands(int(rk[1]))], 16, UiStyle.AMBER, "black"))
	var rr := HBoxContainer.new()
	rr.add_theme_constant_override("separation", 8)
	rr.add_child(_label(Progression.rank_name(xp).to_upper(), 13, UiStyle.DIM, "black"))
	var bar := RankBar.make(Progression.rank_progress(xp))
	bar.custom_minimum_size = Vector2(150, 18)
	rr.add_child(bar)
	right.add_child(rr)
	for ch in r.get("challenges", []):
		right.add_child(_label("✓ %s  +$%s" % [ch["name"], UiStyle.thousands(int(ch["reward"]))], 15, UiStyle.BLUE.lightened(0.3), "bold"))
	var gap := Control.new()
	gap.size_flags_vertical = SIZE_EXPAND_FILL
	right.add_child(gap)
	right.add_child(_btn("Retry", func(): game.start_run(), true, 24))
	right.add_child(_btn("Garage", func(): _back_to = "title"; game.quit_to_menu(); show_screen("garage")))
	var row2 := HBoxContainer.new()
	row2.add_theme_constant_override("separation", 8)
	right.add_child(row2)
	var rb := _btn("Records", func(): _back_to = "title"; game.quit_to_menu(); show_screen("records"), false, 16)
	rb.custom_minimum_size = Vector2(116, 46)
	row2.add_child(rb)
	var mb := _btn("Menu", func(): game.quit_to_menu(), false, 16)
	mb.custom_minimum_size = Vector2(116, 46)
	row2.add_child(mb)
	_focus_first.call_deferred(right)


# ---------------------------------------------------------------- about
func _build_about() -> void:
	var c: Control = screens["about"]
	_shade(c, true, 0.92)
	var m := _margin(c, 56, 30, 56, 24)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 10)
	m.add_child(v)
	var head := HBoxContainer.new()
	v.add_child(head)
	var t := _label("About", 34, UiStyle.WHITE, "black")
	t.size_flags_horizontal = SIZE_EXPAND_FILL
	head.add_child(t)
	head.add_child(_btn("‹  Back", func(): _back_to = _back_to_about; show_screen("settings"), false, 16))
	var card := PanelContainer.new()
	card.add_theme_stylebox_override("panel", UiStyle.glass(22, 0.66))
	card.size_flags_horizontal = SIZE_SHRINK_BEGIN
	v.add_child(card)
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 8)
	card.add_child(col)
	col.add_child(_label("NEVER STOP  %s" % ProjectSettings.get_setting("application/config/version", ""), 22, UiStyle.WHITE, "black"))
	col.add_child(_label("A Musa Studios game.", 15, UiStyle.DIM, "semibold"))
	for line in ["Design, code, city, cars, sound and music: Musa Studios (all made in-house, procedurally).",
			"Engine: Godot Engine (MIT licence) · Physics: Jolt Physics (MIT licence).",
			"Typeface: Outfit by the Outfit Project Authors, SIL Open Font Licence 1.1.",
			"Privacy: NEVER STOP collects nothing. No accounts, no ads, no tracking; your progress stays on this device."]:
		var l := _label(line, 15, UiStyle.WHITE, "semibold")
		l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		l.custom_minimum_size.x = 760
		col.add_child(l)
	var lic := ScrollContainer.new()
	lic.custom_minimum_size = Vector2(760, 150)
	lic.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	col.add_child(lic)
	var lt := _label(Engine.get_license_text(), 11, UiStyle.DIM, "semibold")
	lt.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	lt.custom_minimum_size.x = 740
	lic.add_child(lt)


# ---------------------------------------------------------------- how to play
func _build_help() -> void:
	var c: Control = screens["help"]
	_shade(c, true, 0.92)
	var m := _margin(c, 56, 30, 56, 24)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 10)
	m.add_child(v)
	var head := HBoxContainer.new()
	v.add_child(head)
	var t := _label("How to play", 34, UiStyle.WHITE, "black")
	t.size_flags_horizontal = SIZE_EXPAND_FILL
	head.add_child(t)
	head.add_child(_btn("‹  Back", func(): show_screen(_back_to), false, 16))
	var cols := HBoxContainer.new()
	cols.add_theme_constant_override("separation", 40)
	v.add_child(cols)
	var left := VBoxContainer.new()
	left.custom_minimum_size.x = 520
	cols.add_child(left)
	left.add_child(_label("CONTROLS", 14, UiStyle.AMBER, "black"))
	var gas := "GAS pedal (right)" if Settings.accelerate != "auto" else "automatic"
	for row in [["", "Touch", "Keys", "Pad"], ["Accelerate", gas, "W / ↑", "RT"],
			["Steer", "slide left thumb", "A D / ← →", "stick"], ["Brake / reverse", "BRAKE pedal", "S / ↓", "LT"],
			["Drift", "DRIFT", "Space", "A"], ["Nitro", "NOS", "Shift", "X"], ["Recover", "automatic", "R", "Y"],
			["Pause", "II", "Esc", "Start"]]:
		var hb := HBoxContainer.new()
		for i in 4:
			var l := _label(str(row[i]), 15, UiStyle.DIM if i == 0 or row[0] == "" else UiStyle.WHITE, "black" if row[0] == "" else "semibold")
			l.custom_minimum_size.x = [130, 170, 110, 80][i]
			hb.add_child(l)
		left.add_child(hb)
	var right := VBoxContainer.new()
	right.size_flags_horizontal = SIZE_EXPAND_FILL
	cols.add_child(right)
	right.add_child(_label("THE CHASE", 14, UiStyle.AMBER, "black"))
	for line in ["The police will catch you. Survive as long as you can.",
			"Heat rises every minute: interceptors, PIT rammers, heavies, roadblocks, spikes, a helicopter.",
			"You're only busted when you're boxed in or wrecked – keep moving.",
			"Near misses, drifts, air, flat-out runs and wrecked cops build your CHAIN multiplier.",
			"Contracts (top-left) pay extra cash. Finish one and a harder one appears.",
			"Every point is career XP: rank up for cash bonuses.",
			"Spend cash in the GARAGE on cars, upgrades, paint and wheels."]:
		var l2 := _label("·  " + line, 15, UiStyle.WHITE, "semibold")
		l2.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		l2.custom_minimum_size.x = 440
		right.add_child(l2)


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
	var t := _label("Records", 34, UiStyle.WHITE, "black")
	t.size_flags_horizontal = SIZE_EXPAND_FILL
	head.add_child(t)
	head.add_child(_btn("‹  Back", func(): show_screen(_back_to), false, 16))
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
	for pair in [["Rank", Progression.rank_name(int(d.get("xp", 0)))], ["Career XP", UiStyle.thousands(int(d.get("xp", 0)))],
			["Contracts", str(int(d.get("total_contracts", 0)))], ["Chases", str(int(d["runs"]))], ["Time on the run", UiStyle.time_str(float(d["total_time"]))],
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
	var t := _label("Settings", 34, UiStyle.WHITE, "black")
	t.size_flags_horizontal = SIZE_EXPAND_FILL
	head.add_child(t)
	head.add_child(_btn("Done", func(): Settings.save(); show_screen(_back_to), true, 16))
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = SIZE_EXPAND_FILL
	scroll.custom_minimum_size = Vector2(0, 420)
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
	_choice(grid, "Accelerate", ["Gas pedal", "Auto"], ["pedal", "auto"].find(Settings.accelerate),
		func(i): Settings.accelerate = ["pedal", "auto"][i])
	_slider(grid, "Steering sensitivity", 0.5, 1.6, Settings.steer_sensitivity, func(x): Settings.steer_sensitivity = x)
	_choice(grid, "Camera", ["Near", "Normal", "Far"], Settings.camera_distance, func(i): Settings.camera_distance = i; game.camera.distance_setting = i)
	_choice(grid, "Time of day", ["Cycle", "Day", "Sunset", "Night"], ["cycle", "day", "sunset", "night"].find(Settings.time_of_day),
		func(i): Settings.time_of_day = ["cycle", "day", "sunset", "night"][i]; Settings.apply())
	_slider(grid, "Music", 0.0, 1.0, Settings.music_volume, func(x): Settings.music_volume = x; Settings.apply())
	_slider(grid, "Sound effects", 0.0, 1.0, Settings.sfx_volume, func(x): Settings.sfx_volume = x; Settings.apply())
	_toggle(grid, "Vibration", Settings.haptics, func(b): Settings.haptics = b)
	_toggle(grid, "Reduce motion (no shake, calmer FOV)", Settings.reduce_motion, func(b): Settings.reduce_motion = b; game.camera.reduce_motion = b)
	_toggle(grid, "High-contrast HUD", Settings.high_contrast_hud, func(b): Settings.high_contrast_hud = b)
	_toggle(grid, "Show performance", Settings.show_perf, func(b): Settings.show_perf = b; game.hud.perf = b)
	grid.add_child(_label("Tutorial", 18, UiStyle.DIM, "semibold"))
	var tut := _btn("Replay on next chase", func():
		SaveData.data["tutorial_done"] = false
		SaveData.save()
		toast("The tutorial runs on your next chase."), false, 15)
	tut.size_flags_horizontal = SIZE_SHRINK_BEGIN
	grid.add_child(tut)
	grid.add_child(_label("Progress", 18, UiStyle.DIM, "semibold"))
	var reset := _btn("Reset everything", func(): pass, false, 15)
	reset.name = "Reset"
	reset.size_flags_horizontal = SIZE_SHRINK_BEGIN
	# Two taps: the first arms it, the second (within 4 s) wipes the profile.
	reset.pressed.connect(func():
		if reset.get_meta("armed", 0.0) > Time.get_ticks_msec() / 1000.0:
			SaveData.reset_profile()
			game.select_car("kestrel")
			reset.text = "Reset everything"
			reset.set_meta("armed", 0.0)
			toast("Progress reset.")
		else:
			reset.text = "Tap again to erase all progress"
			reset.set_meta("armed", Time.get_ticks_msec() / 1000.0 + 4.0))
	grid.add_child(reset)
	grid.add_child(_label("About", 18, UiStyle.DIM, "semibold"))
	var ab := _btn("Credits & licences", func(): _back_to_about = _back_to; show_screen("about"), false, 15)
	ab.size_flags_horizontal = SIZE_SHRINK_BEGIN
	grid.add_child(ab)


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
	b.size_flags_horizontal = SIZE_SHRINK_BEGIN
	b.toggled.connect(func(on): b.text = "ON" if on else "OFF"; cb.call(on))
	grid.add_child(b)


# ---------------------------------------------------------------- garage
func _build_garage() -> void:
	var c: Control = screens["garage"]
	_garage = GarageView.new()
	_garage.set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	_garage.mouse_filter = MOUSE_FILTER_PASS
	c.add_child(_garage)
	_shade(c, true, 0.78)
	_garage_sel = maxi(0, CarCatalog.ORDER.find(game.car_id))
	var m := _margin(c, 40, 22, 40, 22)
	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 12)
	root.mouse_filter = MOUSE_FILTER_IGNORE
	m.add_child(root)
	# Top bar: back, title, cash.
	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 14)
	root.add_child(head)
	var back := _btn("‹  Back", func(): show_screen(_back_to), false, 16)
	back.name = "Back"
	back.custom_minimum_size = Vector2(108, 44)
	head.add_child(back)
	var t := _label("Garage", 30, UiStyle.WHITE, "black")
	t.size_flags_horizontal = SIZE_EXPAND_FILL
	head.add_child(t)
	var cash_box := PanelContainer.new()
	cash_box.add_theme_stylebox_override("panel", _chip_style(Color(1, 1, 1, 0.08)))
	cash_box.add_child(_cash_label(20))
	head.add_child(cash_box)
	var body := HBoxContainer.new()
	body.size_flags_vertical = SIZE_EXPAND_FILL
	body.add_theme_constant_override("separation", 16)
	body.mouse_filter = MOUSE_FILTER_IGNORE
	root.add_child(body)
	# Left: details card that scrolls if it must.
	var card := PanelContainer.new()
	card.add_theme_stylebox_override("panel", UiStyle.glass(22, 0.66))
	card.custom_minimum_size.x = 470
	card.size_flags_vertical = SIZE_EXPAND_FILL
	body.add_child(card)
	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	card.add_child(scroll)
	_garage_box = VBoxContainer.new()
	_garage_box.size_flags_horizontal = SIZE_EXPAND_FILL
	_garage_box.add_theme_constant_override("separation", 10)
	scroll.add_child(_garage_box)
	# Right: the turntable shows through; the switcher and the main action
	# sit underneath the car.
	var right := VBoxContainer.new()
	right.size_flags_horizontal = SIZE_EXPAND_FILL
	right.mouse_filter = MOUSE_FILTER_IGNORE
	body.add_child(right)
	var gap := Control.new()
	gap.size_flags_vertical = SIZE_EXPAND_FILL
	gap.mouse_filter = MOUSE_FILTER_IGNORE
	right.add_child(gap)
	var nav := HBoxContainer.new()
	nav.alignment = BoxContainer.ALIGNMENT_CENTER
	nav.add_theme_constant_override("separation", 14)
	right.add_child(nav)
	var prev := _btn("‹", func(): _garage_pick(-1), false, 26)
	prev.name = "Prev"
	prev.custom_minimum_size = Vector2(56, 52)
	nav.add_child(prev)
	_garage_dots = Dots.new()
	_garage_dots.custom_minimum_size = Vector2(170, 52)
	nav.add_child(_garage_dots)
	var nxt := _btn("›", func(): _garage_pick(1), false, 26)
	nxt.name = "Next"
	nxt.custom_minimum_size = Vector2(56, 52)
	nav.add_child(nxt)
	_garage_cta = HBoxContainer.new()
	_garage_cta.alignment = BoxContainer.ALIGNMENT_CENTER
	right.add_child(_garage_cta)
	_garage_refresh()


func _chip_style(col: Color, radius := 18) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = col
	sb.set_corner_radius_all(radius)
	sb.anti_aliasing = true
	sb.content_margin_left = 14
	sb.content_margin_right = 14
	sb.content_margin_top = 6
	sb.content_margin_bottom = 6
	return sb


func _garage_pick(d: int) -> void:
	_garage_sel = posmod(_garage_sel + d, CarCatalog.ORDER.size())
	_garage_refresh()


func _caps(text: String, col := UiStyle.DIM) -> Label:
	return _label(text.to_upper(), 12, col, "black")


func _garage_refresh() -> void:
	for ch in _garage_box.get_children():
		ch.queue_free()
	for ch in _garage_cta.get_children():
		ch.queue_free()
	var id: String = CarCatalog.ORDER[_garage_sel]
	var info: Dictionary = CarCatalog.CARS[id]
	var owned := SaveData.owns(id)
	var spec := SaveData.car_spec(id)
	if _garage:
		_garage.show_car(spec)
	_garage_dots.count = CarCatalog.ORDER.size()
	_garage_dots.index = _garage_sel
	_garage_dots.owned = CarCatalog.ORDER.map(func(k): return SaveData.owns(k))
	_garage_dots.queue_redraw()
	# --- the main action, under the car
	if not owned:
		var price := int(info["price"])
		var buy := _btn("Buy  ·  $" + UiStyle.thousands(price), func():
			if SaveData.spend(price):
				SaveData.data["owned"].append(id)
				SaveData.data["car"] = id
				SaveData.save()
				game.select_car(id)
				toast("%s is yours." % info["name"])
				_garage_refresh()
			else:
				toast("Not enough cash yet – keep running."), true, 20)
		buy.name = "Buy"
		buy.custom_minimum_size = Vector2(300, 56)
		buy.disabled = SaveData.cash() < price
		_garage_cta.add_child(buy)
		if SaveData.cash() < price:
			_garage_cta.add_child(_label("  $%s to go" % UiStyle.thousands(price - SaveData.cash()), 15, UiStyle.DIM, "bold"))
	elif game.car_id != id:
		var drive := _btn("Drive this", func():
			SaveData.data["car"] = id
			SaveData.save()
			game.select_car(id)
			toast("%s selected." % info["name"])
			_garage_refresh(), true, 20)
		drive.name = "Drive"
		drive.custom_minimum_size = Vector2(300, 56)
		_garage_cta.add_child(drive)
	else:
		var sel := PanelContainer.new()
		sel.add_theme_stylebox_override("panel", _chip_style(Color(1, 1, 1, 0.1), 28))
		var sl := _label("✓  Selected", 18, UiStyle.WHITE, "black")
		sl.custom_minimum_size = Vector2(270, 40)
		sl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		sl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		sel.add_child(sl)
		_garage_cta.add_child(sel)
	# --- identity
	var drive_s: String = {"fwd": "FWD", "rwd": "RWD", "awd": "AWD"}[spec["drive"]]
	_garage_box.add_child(_caps("%s  ·  %s  ·  %d km/h" % [info["class"], drive_s, int(spec["top_speed"] * 3.6)], UiStyle.AMBER))
	_garage_box.add_child(_label(str(info["name"]), 40, UiStyle.WHITE, "black"))
	var blurb := _label(info["blurb"], 15, UiStyle.DIM, "semibold")
	blurb.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	blurb.custom_minimum_size.x = 420
	_garage_box.add_child(blurb)
	if info.has("perk"):
		var parts := str(info["perk"]).split("·", true, 1)
		var chip := PanelContainer.new()
		chip.add_theme_stylebox_override("panel", _chip_style(Color(UiStyle.AMBER, 0.14), 12))
		chip.size_flags_horizontal = SIZE_SHRINK_BEGIN
		var pl := _label(("★  " + parts[0].strip_edges() + ("  –  " + parts[1].strip_edges() if parts.size() > 1 else "")), 13, UiStyle.AMBER, "bold")
		pl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		pl.custom_minimum_size.x = 380
		chip.add_child(pl)
		_garage_box.add_child(chip)
	# --- tabs
	var tabs := HBoxContainer.new()
	tabs.add_theme_constant_override("separation", 6)
	_garage_box.add_child(tabs)
	for pair in [["performance", "Performance"], ["style", "Style"], ["start", "Start"]]:
		var key: String = pair[0]
		var tb := _btn(pair[1], func(): _garage_tab = key; _garage_refresh(), false, 15)
		tb.name = "Tab" + pair[1]
		tb.custom_minimum_size = Vector2(128, 40)
		if _garage_tab == key:
			var on := _chip_style(UiStyle.WHITE, 20)
			tb.add_theme_stylebox_override("normal", on)
			tb.add_theme_stylebox_override("hover", on)
			tb.add_theme_color_override("font_color", UiStyle.INK)
			tb.add_theme_color_override("font_hover_color", UiStyle.INK)
			tb.add_theme_color_override("font_focus_color", UiStyle.INK)
		tabs.add_child(tb)
	match _garage_tab:
		"style":
			_garage_style(id, spec)
		"start":
			_garage_start()
		_:
			_garage_performance(id, spec, owned)


## Upgrades: each row is the stat it improves, the bar shows the next level
## as a ghost, and one button buys it.
func _garage_performance(id: String, spec: Dictionary, owned: bool) -> void:
	var ups := SaveData.upgrades(id)
	var caps := CarCatalog.upgrade_caps(id)
	var now := CarCatalog.stats(spec)
	var rows := {"engine": ["Engine", "accel", "Acceleration & top speed"], "grip": ["Tyres", "handling", "Grip & cornering"],
		"armour": ["Armour", "durability", "Takes more hits"], "nitro": ["Nitro", "nitro", "Bigger, longer boost"]}
	if not owned:
		_garage_box.add_child(_label("Buy this car to upgrade it.", 14, UiStyle.DIM, "semibold"))
	for k in CarCatalog.UPGRADE_KEYS:
		var r: Array = rows[k]
		var cap: int = caps[k]
		var lvl := mini(int(ups.get(k, 0)), cap)
		var maxed := lvl >= cap
		var price := 0 if maxed else CarCatalog.upgrade_price(id, k, lvl)
		var nxt_ups := ups.duplicate()
		nxt_ups[k] = lvl + 1
		var nxt_spec := CarCatalog.spec(id, nxt_ups)
		var cur_v := _stat_of(spec, now, r[1])
		var nxt_v := _stat_of(nxt_spec, CarCatalog.stats(nxt_spec), r[1]) if not maxed else cur_v
		var row := PanelContainer.new()
		row.add_theme_stylebox_override("panel", _chip_style(Color(1, 1, 1, 0.05), 16))
		_garage_box.add_child(row)
		var h := HBoxContainer.new()
		h.add_theme_constant_override("separation", 12)
		row.add_child(h)
		var col := VBoxContainer.new()
		col.add_theme_constant_override("separation", 3)
		col.size_flags_horizontal = SIZE_EXPAND_FILL
		h.add_child(col)
		var top := HBoxContainer.new()
		top.add_theme_constant_override("separation", 10)
		col.add_child(top)
		top.add_child(_label(r[0], 17, UiStyle.WHITE, "black"))
		top.add_child(Pips.make(lvl, cap))
		col.add_child(UpgradeBar.make(cur_v, nxt_v))
		col.add_child(_label(r[2], 12, UiStyle.DIM, "semibold"))
		var key: String = k
		var b := _btn("Max" if maxed else "$" + UiStyle.thousands(price), func():
			if SaveData.spend(price):
				var cs := SaveData.car_state(id)
				cs["upgrades"][key] = lvl + 1
				SaveData.save()
				if game.car_id == id:
					game.select_car(id)
				toast("%s level %d" % [rows[key][0], lvl + 1])
				_garage_refresh()
			else:
				toast("Not enough cash."), not maxed and owned and SaveData.cash() >= price, 15)
		b.name = "Up" + r[0]
		b.custom_minimum_size = Vector2(104, 44)
		b.size_flags_vertical = SIZE_SHRINK_CENTER
		b.disabled = maxed or not owned or SaveData.cash() < price
		h.add_child(b)


func _stat_of(spec: Dictionary, st: Dictionary, key: String) -> float:
	if key == "nitro":
		return clampf((float(spec.get("nitro", 0.0)) * float(spec.get("nitro_time", 4.0))) / 8.0, 0.0, 1.0)
	return float(st[key])


func _garage_style(id: String, spec: Dictionary) -> void:
	var owned := SaveData.owns(id)
	_garage_box.add_child(_caps("Paint"))
	var paints := HFlowContainer.new()
	paints.add_theme_constant_override("h_separation", 8)
	paints.add_theme_constant_override("v_separation", 8)
	_garage_box.add_child(paints)
	var cs := SaveData.car_state(id)
	for pi in CarCatalog.PAINTS.size():
		var p: Array = CarCatalog.PAINTS[pi]
		var cur := int(cs.get("paint", -1)) == pi
		var have: bool = pi in SaveData.data["paints"] or int(p[2]) == 0
		var sw := Swatch.new()
		sw.col = p[1]
		sw.selected = cur
		sw.locked = not have
		sw.custom_minimum_size = Vector2(40, 40)
		sw.tooltip_text = "%s%s" % [p[0], "" if have else "  $" + str(p[2])]
		var idx := pi
		sw.pressed.connect(func():
			if not owned:
				toast("Buy this car first.")
				return
			var price: int = CarCatalog.PAINTS[idx][2]
			var ok: bool = idx in SaveData.data["paints"] or price == 0
			if not ok:
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
	_garage_box.add_child(_caps("Wheels"))
	var wheels := HFlowContainer.new()
	wheels.add_theme_constant_override("h_separation", 6)
	wheels.add_theme_constant_override("v_separation", 6)
	_garage_box.add_child(wheels)
	for w in CarCatalog.WHEELS:
		var wid: String = w[0]
		var price: int = w[2]
		var have: bool = wid in SaveData.data["wheels"] or price == 0
		var cur: bool = spec["wheel"] == wid
		var b := _btn(str(w[1]) + ("" if have else "  $%d" % price), func():
			if not owned:
				toast("Buy this car first.")
				return
			if not (wid in SaveData.data["wheels"] or price == 0):
				if not SaveData.spend(price):
					toast("Not enough cash.")
					return
				SaveData.data["wheels"].append(wid)
			SaveData.car_state(id)["wheel"] = wid
			SaveData.save()
			if game.car_id == id:
				game.select_car(id)
			_garage_refresh(), cur, 13)
		b.custom_minimum_size = Vector2(84, 38)
		wheels.add_child(b)


func _garage_start() -> void:
	_garage_box.add_child(_caps("Where the next chase starts"))
	for sid in Progression.STARTS:
		var sp: Dictionary = Progression.STARTS[sid]
		var have: bool = sid in SaveData.data["starts"]
		var cur: bool = SaveData.data["start"] == sid
		var key: String = sid
		var label := str(sp["name"]) + ("   ✓" if cur else ("" if have else "   $" + UiStyle.thousands(int(sp["price"]))))
		var b := _btn(label, func():
			if not (key in SaveData.data["starts"]):
				if not SaveData.spend(int(Progression.STARTS[key]["price"])):
					toast("Not enough cash.")
					return
				SaveData.data["starts"].append(key)
			SaveData.data["start"] = key
			SaveData.save()
			toast("Next chase starts in %s." % Progression.STARTS[key]["name"])
			_garage_refresh(), cur, 15)
		b.alignment = HORIZONTAL_ALIGNMENT_LEFT
		b.custom_minimum_size = Vector2(400, 44)
		_garage_box.add_child(b)


class Dots:
	extends Control
	var count := 10
	var index := 0
	var owned: Array = []
	func _draw() -> void:
		var gap := size.x / maxf(count, 1)
		for i in count:
			var c := Vector2(gap * (i + 0.5), size.y * 0.5)
			var mine: bool = i < owned.size() and owned[i]
			if i == index:
				draw_rect(Rect2(c.x - 9, c.y - 3.5, 18, 7), UiStyle.WHITE)
			else:
				draw_circle(c, 3.5, Color(1, 1, 1, 0.55 if mine else 0.2))


class Pips:
	extends Control
	var lvl := 0
	var cap := 3
	static func make(l: int, c: int) -> Pips:
		var p := Pips.new()
		p.lvl = l
		p.cap = c
		p.custom_minimum_size = Vector2(c * 16, 20)
		return p
	func _draw() -> void:
		for i in cap:
			var r := Rect2(i * 16, 7, 12, 6)
			draw_rect(r, UiStyle.AMBER if i < lvl else Color(1, 1, 1, 0.16))


class UpgradeBar:
	extends Control
	var cur := 0.0
	var nxt := 0.0
	var shown := 0.0
	static func make(c: float, n: float) -> UpgradeBar:
		var b := UpgradeBar.new()
		b.cur = c
		b.nxt = n
		b.custom_minimum_size = Vector2(240, 10)
		return b
	func _process(dt: float) -> void:
		shown = lerpf(shown, cur, 1.0 - exp(-8.0 * dt))
		queue_redraw()
	func _draw() -> void:
		var w := size.x
		var y := 2.0
		var sb := StyleBoxFlat.new()
		sb.set_corner_radius_all(3)
		sb.bg_color = Color(1, 1, 1, 0.1)
		draw_style_box(sb, Rect2(0, y, w, 6))
		if nxt > cur + 0.001:
			sb.bg_color = Color(UiStyle.AMBER, 0.35 + 0.2 * sin(Time.get_ticks_msec() * 0.005))
			draw_style_box(sb, Rect2(0, y, w * nxt, 6))
		sb.bg_color = UiStyle.WHITE
		draw_style_box(sb, Rect2(0, y, maxf(w * shown, 6.0), 6))


class Swatch:
	extends Button
	var col := Color.WHITE
	var selected := false
	var locked := false
	func _ready() -> void:
		flat = true
		focus_mode = Control.FOCUS_ALL
	func _draw() -> void:
		var c := size * 0.5
		var r := minf(size.x, size.y) * 0.5 - 4.0
		if selected:
			draw_arc(c, r + 3.0, 0, TAU, 40, UiStyle.WHITE, 2.0, true)
		draw_circle(c, r - (1.0 if selected else 0.0), col)
		if locked:
			draw_circle(c, r, Color(0, 0, 0, 0.45))
			UiStyle.text(self, c + Vector2(-4, 5), "$", 13, Color(1, 1, 1, 0.85), "black")


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
