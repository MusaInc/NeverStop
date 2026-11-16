extends Control
## Minimal mobile HUD and room browser for the ENet prototype.
var session: LcsSession
var panel: PanelContainer
var message: Label
var room: LineEdit
var port: SpinBox
var nickname: LineEdit
var vehicle: OptionButton
var count: SpinBox
var bots: CheckBox
var feed := ""
var feed_seconds := 0.0
var show_full_map := false
var map_baker: Minimap
var menu_open := false
var displayed_status := ""
var map_button: Button
var menu_button: Button
var font := preload("res://assets/fonts/outfit_bold.ttf")
var title_font := preload("res://assets/fonts/outfit_black.ttf")
const WHITE := Color(0.94, 0.96, 0.98)
const CYAN := Color(0.25, 0.9, 0.95)
const INK := Color(0.025, 0.04, 0.065, 0.94)

func _ready() -> void:
	set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	mouse_filter = MOUSE_FILTER_IGNORE
	var theme := Theme.new()
	theme.default_font = font
	theme.default_font_size = 18
	self.theme = theme
	_build_lobby()
	map_button = Button.new()
	map_button.text = "MAP"
	map_button.position = Vector2(22, 80)
	map_button.size = Vector2(74, 42)
	map_button.pressed.connect(func(): show_full_map = not show_full_map)
	add_child(map_button)
	menu_button = Button.new()
	menu_button.text = "ROOM"
	menu_button.position = Vector2(104, 80)
	menu_button.size = Vector2(82, 42)
	menu_button.pressed.connect(toggle_menu)
	add_child(menu_button)
	if DisplayServer.get_name() != "headless":
		map_baker = Minimap.new()
		map_baker.visible = false
		add_child(map_baker)
		map_baker.bake.call_deferred(session.layout)

func _label(text: String, size := 18) -> Label:
	var label := Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", size)
	return label

func _button(text: String, action: Callable, parent: Node) -> Button:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size.y = 46
	b.pressed.connect(action)
	parent.add_child(b)
	return b

func _build_lobby() -> void:
	panel = PanelContainer.new()
	panel.set_anchors_and_offsets_preset(PRESET_CENTER)
	panel.offset_left = -290
	panel.offset_right = 290
	panel.offset_top = -295
	panel.offset_bottom = 295
	var style := StyleBoxFlat.new()
	style.bg_color = INK
	style.set_corner_radius_all(18)
	style.content_margin_left = 24
	style.content_margin_right = 24
	style.content_margin_top = 18
	style.content_margin_bottom = 18
	panel.add_theme_stylebox_override("panel", style)
	add_child(panel)
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 9)
	panel.add_child(column)
	column.add_child(_label("NEVER STOP   /   ONLINE PROTOTYPE", 13))
	var title := _label("LAST CAR STANDING", 32)
	title.add_theme_color_override("font_color", CYAN)
	column.add_child(title)
	column.add_child(_label("Ram. Survive. Eliminate to recover +35 HP.", 16))
	var identity := HBoxContainer.new()
	column.add_child(identity)
	nickname = LineEdit.new()
	nickname.text = "Driver"
	nickname.placeholder_text = "Driver name"
	nickname.max_length = 20
	nickname.size_flags_horizontal = SIZE_EXPAND_FILL
	identity.add_child(nickname)
	vehicle = OptionButton.new()
	for c in LcsRules.CLASSES:
		vehicle.add_item(c.capitalize())
	identity.add_child(vehicle)
	var connect_row := HBoxContainer.new()
	column.add_child(connect_row)
	room = LineEdit.new()
	room.text = "127.0.0.1"
	room.placeholder_text = "Server address"
	room.size_flags_horizontal = SIZE_EXPAND_FILL
	connect_row.add_child(room)
	port = SpinBox.new()
	port.min_value = 1
	port.max_value = 65535
	port.value = LcsSession.PORT
	connect_row.add_child(port)
	_button("JOIN ROOM", func():
		session.join_server(room.text, int(port.value), nickname.text, LcsRules.CLASSES[vehicle.selected]), column)
	var host_row := HBoxContainer.new()
	column.add_child(host_row)
	host_row.add_child(_label("Lobby size"))
	count = SpinBox.new()
	count.min_value = 2
	count.max_value = 100
	count.value = 10
	host_row.add_child(count)
	bots = CheckBox.new()
	bots.text = "Fill with named bots"
	bots.button_pressed = true
	host_row.add_child(bots)
	_button("HOST ROOM", func():
		session.target_size = int(count.value)
		session.fill_bots = bots.button_pressed
		session.player_label = nickname.text
		session.player_class = LcsRules.CLASSES[vehicle.selected]
		session.host(int(port.value)), column)
	_button("START WITH CURRENT PLAYERS / BOT FILL", func(): session.begin_match(), column)
	message = _label("", 15)
	message.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	message.custom_minimum_size.y = 42
	column.add_child(message)
	var bottom := HBoxContainer.new()
	column.add_child(bottom)
	_button("SPECTATE NEXT", func(): session.next_spectator(); menu_open = false, bottom)
	_button("RETURN TO NEVER STOP", session.leave, bottom)

func toggle_menu() -> void:
	menu_open = not menu_open

func elimination(event: Dictionary) -> void:
	var roster: Dictionary = session.rules.players if session.is_host() else session.roster
	var name := str(roster.get(int(event.victim), {}).get("name", "Competitor"))
	if int(event.killer) == session.local_id:
		feed = "ELIMINATED %s    +%d HP" % [name, int(round(event.heal))]
	elif int(event.victim) == session.local_id:
		feed = "ELIMINATED · SPECTATING    %d REMAIN" % int(event.left)
	else:
		feed = "%s eliminated · %d remain" % [name, int(event.left)]
	feed_seconds = 4.0

func _safe_rect() -> Rect2:
	if OS.has_feature("mobile"):
		var safe := DisplayServer.get_display_safe_area()
		var screen := DisplayServer.screen_get_size()
		if screen.x > 0 and screen.y > 0:
			var k := size / Vector2(screen)
			return Rect2(Vector2(safe.position) * k, Vector2(safe.size) * k)
	return Rect2(Vector2.ZERO, size)

func _process(dt: float) -> void:
	var safe := _safe_rect()
	map_button.position = safe.position + Vector2(22, 80)
	menu_button.position = safe.position + Vector2(104, 80)
	feed_seconds = maxf(0, feed_seconds - dt)
	panel.visible = session.status == "waiting" or menu_open
	message.text = session.ui_message
	if session.connected and session.status == "waiting":
		message.text += "\n%d / %d joined · starts in %ds" % [session.roster.size(), session.target_size, maxi(0, int(ceil(session.queue_seconds - session.queue_elapsed)))]
	if session.status != displayed_status:
		displayed_status = session.status
		if displayed_status != "waiting":
			menu_open = false
	if session.touch:
		session.touch.visible = (DisplayServer.is_touchscreen_available() or session.args.has("touch")) and session.status == "active" and not menu_open and session.cars.has(session.local_id) and not session.cars[session.local_id].disabled
	queue_redraw()

func _text(text: String, at: Vector2, size_px := 20, color := WHITE, width := -1.0) -> void:
	draw_string(font, at, text, HORIZONTAL_ALIGNMENT_LEFT, width, size_px, color)

func _draw() -> void:
	var safe := _safe_rect()
	var draw_size := safe.size
	draw_set_transform(safe.position)
	if session.status == "waiting":
		draw_rect(Rect2(Vector2.ZERO, draw_size), Color(0.02, 0.03, 0.05, 0.6))
		return
	var entry: Dictionary = session.roster.get(session.local_id, {})
	var hp := 100.0
	var speed := 0.0
	if session.cars.has(session.local_id):
		hp = session.cars[session.local_id].health * 100.0
		speed = session.cars[session.local_id].speed * 3.6
	var roster: Dictionary = session.rules.players if session.is_host() else session.roster
	var left := 0
	for p in roster.values():
		left += int(p.alive)
	var kills := int(roster.get(session.local_id, {}).get("kills", 0))
	var inset := 78.0 if session.touch and session.touch.visible else 18.0
	draw_rect(Rect2(inset, 18, 525, 52), INK)
	_text("%d ALIVE" % left, Vector2(inset + 16, 52), 24)
	_text("%d ELIMS" % kills, Vector2(inset + 158, 52), 20, CYAN)
	_text("%03d km/h" % int(speed), Vector2(inset + 310, 52), 24)
	var h := Vector2(draw_size.x * 0.5 - 150, draw_size.y - 56)
	draw_rect(Rect2(h - Vector2(12, 30), Vector2(324, 65)), INK)
	_text("%d HP" % int(ceil(hp)), h - Vector2(0, 7), 21, CYAN if hp > 30 else Color(1, 0.32, 0.2))
	_text("ELIMINATIONS HEAL +35", h + Vector2(96, -9), 13, Color(0.65, 0.74, 0.8))
	draw_rect(Rect2(h, Vector2(300, 9)), Color(0.2, 0.24, 0.3))
	draw_rect(Rect2(h, Vector2(300 * clampf(hp / 100.0, 0, 1), 9)), CYAN)
	if not session.circle.is_empty():
		var s: Dictionary = session.circle
		_text("STORM %d   %s  %02d:%02d" % [s.phase, "CLOSING" if s.moving else "IN", int(s.countdown) / 60, int(s.countdown) % 60], Vector2(draw_size.x - 360, 45), 19, CYAN)
		if session.cars.has(session.local_id) and LcsStorm.outside(session.cars[session.local_id].global_position, s) and hp > 0:
			draw_rect(Rect2(Vector2.ZERO, draw_size), Color(0.4, 0.08, 0.7, 0.1))
			_text("OUTSIDE SAFE ZONE · %d HP/s" % int(s.dps), Vector2(draw_size.x * 0.5 - 185, 100), 24, Color(1, 0.5, 0.8))
	var map_rect := Rect2(draw_size.x - 264, 66, 240, 160)
	if show_full_map:
		map_rect = Rect2(draw_size.x * 0.12, draw_size.y * 0.12, draw_size.x * 0.76, draw_size.y * 0.76)
	_draw_map(map_rect)
	if session.status == "countdown":
		_text("START IN %d" % maxi(1, int(ceil(5.0 - session.clock))), Vector2(draw_size.x * 0.5 - 125, draw_size.y * 0.43), 42)
	# Nearby competitors are named on screen, including an explicit BOT prefix.
	if session.camera and session.camera.cam and session.status == "active":
		var cam := session.camera.cam
		for id in session.cars:
			var c: Car = session.cars[id]
			if id == session.local_id or c.disabled or c.global_position.distance_squared_to(cam.global_position) > 85.0 * 85.0:
				continue
			var head := c.global_position + Vector3.UP * 2.7
			if not cam.is_position_behind(head):
				var at := cam.unproject_position(head) - safe.position
				var label := str(roster.get(id, {}).get("name", "Driver"))
				_text(label, at - Vector2(30, 0), 14, CYAN)
	if hp <= 0 and session.status == "active":
		_text("ELIMINATED  ·  SPECTATING", Vector2(draw_size.x * 0.5 - 185, draw_size.y * 0.28), 28)
	if session.status == "finished":
		draw_rect(Rect2(0, draw_size.y * 0.3, draw_size.x, 155), INK)
		var name := str(roster.get(session.winner, {}).get("name", "No survivor"))
		_text("LAST CAR STANDING" if session.winner != 0 else "NO SURVIVORS", Vector2(draw_size.x * 0.5 - 215, draw_size.y * 0.3 + 54), 38, CYAN)
		_text(name + (" · VICTORY" if session.winner == session.local_id else ""), Vector2(draw_size.x * 0.5 - 140, draw_size.y * 0.3 + 98), 26)
		_text("Open ROOM to return to NEVER STOP", Vector2(draw_size.x * 0.5 - 165, draw_size.y * 0.3 + 132), 17)
	if feed_seconds > 0:
		_text(feed, Vector2(draw_size.x * 0.5 - 260, 160), 25, CYAN)
	if not session.connected:
		_text(session.ui_message, Vector2(draw_size.x * 0.5 - 240, 205), 22, Color(1, 0.65, 0.2))

func _map_point(pos: Vector2, rect: Rect2) -> Vector2:
	return rect.position + (pos - Minimap.BOUNDS.position) / Minimap.BOUNDS.size * rect.size

func _draw_map(rect: Rect2) -> void:
	draw_rect(rect.grow(3), INK)
	if map_baker and map_baker.map_tex:
		draw_texture_rect(map_baker.map_tex, rect, false)
	else:
		draw_rect(rect, Color(0.04, 0.1, 0.15))
	if not session.circle.is_empty():
		var circle: Dictionary = session.circle
		# Ellipses preserve the world-space circle on the rectangular map.
		for next in [false, true]:
			var center: Vector2 = circle.next_center if next else circle.center
			var radius: float = circle.next_radius if next else circle.radius
			var points := PackedVector2Array()
			for i in 97:
				points.append(_map_point(center + Vector2.from_angle(TAU * i / 96.0) * radius, rect))
			# Clip each segment to map bounds; the initial circle extends beyond the map.
			for i in range(1, points.size()):
				if rect.has_point(points[i - 1]) and rect.has_point(points[i]):
					draw_line(points[i - 1], points[i], CYAN if next else Color(0.65, 0.35, 1), 1.5, true)
	var observer := session.local_id
	var own: Car = session.cars.get(observer)
	if own and own.disabled and session.cars.has(session.spectating):
		observer = session.spectating
		own = session.cars[observer]
	for id in session.cars:
		var c: Car = session.cars[id]
		if c.disabled:
			continue
		# Threat markers are only nearby; no map-wide wallhack.
		if own and id != observer and c.global_position.distance_squared_to(own.global_position) > 240.0 * 240.0:
			continue
		var at := _map_point(Vector2(c.global_position.x, c.global_position.z), rect)
		if rect.has_point(at):
			draw_circle(at, 4 if id == observer else 2.5, WHITE if id == observer else Color(1, 0.3, 0.2))
