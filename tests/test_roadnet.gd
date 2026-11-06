extends Node
## Road graph: built over both lands, connected, and routes reach targets.

static var net: RoadNet
static var layout: CityLayout


func _net() -> RoadNet:
	if net == null:
		layout = CityLayout.new().generate()
		var t0 := Time.get_ticks_msec()
		net = RoadNet.new().build(layout)
		print("        · RoadNet: %d lanes, %d nodes in %d ms" % [net.lanes.size(), net.node_count(), Time.get_ticks_msec() - t0])
	return net


func _g(x: float, z: float) -> Vector3:
	return Vector3(x, layout.ground_y(x, z), z)


func test_graph_is_strongly_connected_enough(t) -> void:
	var n := _net()
	var t0 := Time.get_ticks_msec()
	var f := n.flow_field(_g(560, -170))
	t.note("flow field in %d ms" % (Time.get_ticks_msec() - t0))
	var reach := 0
	for d in f.dist:
		if d < INF:
			reach += 1
	var frac := float(reach) / n.node_count()
	t.note("%.1f%% of nodes can reach the CBD" % (frac * 100.0))
	t.check(frac > 0.97, "almost every node routes to the city centre")


func test_mainland_reachable_over_the_bridge(t) -> void:
	var n := _net()
	var f := n.flow_field(_g(-900, 100))  # Westbank
	var from := n.nearest(_g(700, 300))
	var d := n.field_distance(f, from["lane"], from["s"])
	t.note("island -> Westbank by road: %.0f m" % d)
	t.check(d < INF and d < 4000.0, "a route crosses the bridge")
	var f2 := n.flow_field(_g(700, 300))
	var back := n.nearest(_g(-900, 100))
	t.check(n.field_distance(f2, back["lane"], back["s"]) < INF, "and back")


func test_route_points_lead_to_target(t) -> void:
	var n := _net()
	var target: Vector3 = n.nearest(_g(800, 200), Vector3.ZERO, 300.0)["pos"]
	var f := n.flow_field(target)
	var start := n.nearest(_g(400, -400))
	var pts := n.route(f, start["lane"], start["s"], 5000.0)
	t.check(pts.size() > 10, "route has points")
	t.check(pts[-1].distance_to(target) < 60.0, "route ends near target (%.0f m)" % pts[-1].distance_to(target))
	var maxgap := 0.0
	for i in pts.size() - 1:
		maxgap = maxf(maxgap, pts[i].distance_to(pts[i + 1]))
	t.check(maxgap < 30.0, "route is continuous (max gap %.1f m)" % maxgap)
