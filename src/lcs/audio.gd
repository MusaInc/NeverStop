extends AudioDirector
## Reuse the driving/crash mix; storm phase and survivor count drive music.
var session: Node
func _process(dt: float) -> void:
	super._process(dt)
	if session == null or player == null:
		return
	menu_mode = session.status != "active"
	var tension := 0.0
	if not menu_mode and not session.circle.is_empty():
		tension = clampf((float(session.circle.phase) - 1.0) / 5.0, 0, 1)
		var alive := 0
		for p in session.roster.values():
			alive += int(p.alive)
		if alive <= 5:
			tension = maxf(tension, 0.8)
	_intensity = move_toward(_intensity, tension, dt * 0.3)
	_music_int.volume_db = linear_to_db(maxf(_intensity * 0.8, 0.0001))
	_music_peak.volume_db = linear_to_db(maxf((tension - 0.7) * 2.0, 0.0001))
