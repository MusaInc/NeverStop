extends SceneTree
var clients: Array = []
var wall_start := 0
func _initialize() -> void:
	_run.call_deferred()
func _run() -> void:
	var script := load("res://tests/lcs_load_client.gd")
	for i in 100:
		var branch := Node.new()
		branch.name = "LoadClient%d" % i
		root.add_child(branch)
		var api := SceneMultiplayer.new()
		set_multiplayer(api, branch.get_path())
		var client: Node = script.new()
		client.name = "LastCarStanding"
		branch.add_child(client)
		client.join_server("127.0.0.1", 27976, "Load %03d" % i, LcsRules.CLASSES[i % 4])
		clients.append(client)
	wall_start = Time.get_ticks_msec()
	while Time.get_ticks_msec() - wall_start < 22000:
		await process_frame
	var admitted := 0
	var receiving := 0
	var active := 0
	var total_bytes := 0
	var total_packets := 0
	for c in clients:
		admitted += int(c.local_id > 0)
		receiving += int(c.received_packets > 0)
		active += int(c.status == "active")
		total_bytes += c.received_bytes
		total_packets += c.received_packets
	var result := {"clients": 100, "admitted": admitted, "receiving": receiving, "active": active,
		"snapshot_payload_bytes": total_bytes, "snapshot_packets": total_packets, "wall_seconds": 22}
	print("LCS_LOAD ", JSON.stringify(result))
	var file := FileAccess.open("res://build/lcs-network/load.json", FileAccess.WRITE)
	file.store_string(JSON.stringify(result, "  "))
	quit(0 if admitted == 100 and receiving == 100 and active == 100 else 1)
