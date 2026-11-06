extends SceneTree
## Dumps the lane network (island + mainland) as JSON for tools/road_map.py.
##   godot --headless -s res://tools/road_dump.gd -- out.json
func _initialize(): _go.call_deferred()
func _go():
	var out := OS.get_cmdline_user_args()[0] if OS.get_cmdline_user_args().size() > 0 else "build/roads.json"
	var L := CityLayout.new().generate()
	var data := {"lands": []}
	for lay in [L, L.mainland]:
		var tr := Traffic.new()
		tr.layout = lay
		tr.build_network()
		var lanes := []
		for li in tr.lane_count():
			var lp: PackedVector3Array = tr._lane_pts[li]
			var pts := []
			for p in lp:
				pts.append([snappedf(p.x, 0.1), snappedf(p.y, 0.1), snappedf(p.z, 0.1)])
			lanes.append({"pts": pts, "conn": tr.l_next[li] >= 0, "ends": (tr.l_ends[li] as Array).size(), "loop": tr.l_loop[li] == 1})
		var blocks := []
		for b in lay.blocks:
			var poly := []
			for v in b["poly"]:
				poly.append([snappedf(v.x, 0.5), snappedf(v.y, 0.5)])
			blocks.append({"poly": poly, "kind": b["kind"]})
		var coast := []
		for v in lay.coast:
			coast.append([v.x, v.y])
		data["lands"].append({"lanes": lanes, "blocks": blocks, "coast": coast})
		tr.free()
	var f := FileAccess.open(out, FileAccess.WRITE)
	f.store_string(JSON.stringify(data))
	f.close()
	print("ROAD DUMP ", out)
	quit()
