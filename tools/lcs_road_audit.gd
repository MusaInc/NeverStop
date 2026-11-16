extends SceneTree
func _initialize() -> void:
	var layout := LcsRoadSites.city_layout()
	var net := RoadNet.new().build(layout)
	var sites := LcsRoadSites.new()
	sites.build(net, layout)
	print("SITE_COUNT ", sites.sites.size())
	var bridge := net.nearest(Vector3(-200, 24, -17), Vector3.ZERO, 100)
	print("BRIDGE ", bridge)
	var origin := net.node_after(bridge.lane, bridge.s)
	var fwd := LcsRoadSites.reachable(origin, net.out_edges)
	var back := LcsRoadSites.reachable(origin, net.in_edges)
	for lane in net.lanes.size():
		var p := net.lane_point(lane, net.lane_len[lane] * 0.5)
		if p.x > -430 and p.x < 50:
			print("SPAN lane=", lane, " mid=", p, " nodes=", net.lane_nodes[lane])
			for n in net.lane_nodes[lane]:
				print("  NODE ", n, " s=", net.node_s[n], " f=", fwd.has(n), " b=", back.has(n))
	print("CATEGORIES ", sites.categories.keys().map(func(k): return [k, sites.categories[k].size()]))
	quit()
