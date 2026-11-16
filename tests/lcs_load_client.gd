extends "res://src/lcs/session.gd"
## Lightweight protocol clients for wire load only. No city, physics or renderer.
var received_bytes := 0
var received_packets := 0
var last_server_tick := -1
var seq := 0
var timer := 0.0
func _ready() -> void:
	multiplayer.connected_to_server.connect(_client_connected)
	multiplayer.connection_failed.connect(_lost_connection)
	multiplayer.server_disconnected.connect(_lost_connection)
func _physics_process(dt: float) -> void:
	if not connected or local_id == 0:
		return
	timer += dt
	if timer >= 0.05:
		timer = 0.0
		seq += 1
		submit_input.rpc_id(1, seq, 1.0, 0.0, sin(seq * 0.01) * 0.15, false, false, 0)
func _process(_dt: float) -> void:
	pass
@rpc("authority", "call_remote", "unreliable_ordered", 2)
func snapshot(server_tick: int, rows: Array, zone: Dictionary, match_state: String, at: float, _ack: int) -> void:
	received_packets += 1
	received_bytes += var_to_bytes([server_tick, rows, zone, match_state, at, _ack]).size()
	last_server_tick = server_tick
	status = match_state
	clock = at

@rpc("authority", "call_remote", "reliable", 0)
func props_removed(_positions: PackedVector3Array) -> void:
	pass # Protocol load clients deliberately have no city or presentation nodes.
