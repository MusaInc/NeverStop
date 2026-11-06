class_name PursuitDirector
extends Node3D
## Runs the whole police response: heat escalation, dispatch, simulation
## tiers, coordinated roles, roadblocks, spike strips, the helicopter and
## the capture (bust) meter.
##
## Fairness rules:
##   * Units only appear out of the camera's view (frustum + occlusion), at
##     least SPAWN_MIN m of road from the player. The exception is a
##     roadblock, which is placed far ahead and announced (HUD + minimap).
##   * Being touched isn't being caught: the bust meter only fills while the
##     player is (nearly) stopped with police around them, or immobilised,
##     and drains the moment they get moving again – a last chance to escape.
## Scalability:
##   * One shared flow field to the player (0.5 s) and one to the predicted
##     intercept point (1.5 s) serve every unit (RoadNet.flow_field).
##   * Tiers A/B/C (see PoliceUnit); physical cars are pooled per kind and
##     capped by the quality preset; distant units are road-graph points.

signal heat_changed(level: int)
signal unit_wrecked(unit: PoliceUnit, by_player: bool)
signal roadblock_spawned(pos: Vector3)
signal roadblock_escaped
signal busted
signal spiked
signal radio(text: String)

const SPAWN_MIN := 170.0
const SPAWN_MAX := 330.0
const PROMOTE_R := 150.0      # C -> car when within this (and out of view)
const DEMOTE_R := 380.0       # car -> C beyond this (out of view)
const TIER_A_R := 90.0
const BUST_R := 9.5

## Heat thresholds (seconds survived) – a starting point; wrecking units and
## escaping roadblocks push the clock forward (heat_bonus).
const HEAT_AT := [0.0, 40.0, 100.0, 180.0, 280.0, 400.0]
const HEAT_STEP_AFTER := 100.0
## Per heat: target physical units, total units en route, roles mix, kinds.
const HEAT_PLAN := {
	1: {"units": 1, "total": 1, "kinds": ["patrol"], "roles": ["pursuer"]},
	2: {"units": 3, "total": 4, "kinds": ["patrol"], "roles": ["pursuer", "pursuer", "interceptor"]},
	3: {"units": 5, "total": 8, "kinds": ["patrol", "patrol", "interceptor"], "roles": ["pursuer", "aggressor", "interceptor", "pursuer"]},
	4: {"units": 7, "total": 14, "kinds": ["patrol", "interceptor", "heavy"], "roles": ["pursuer", "aggressor", "interceptor", "heavy", "blocker"]},
	5: {"units": 10, "total": 22, "kinds": ["interceptor", "patrol", "heavy"], "roles": ["aggressor", "pursuer", "interceptor", "heavy", "blocker"]},
	6: {"units": 13, "total": 34, "kinds": ["interceptor", "heavy", "patrol"], "roles": ["aggressor", "aggressor", "pursuer", "interceptor", "heavy", "blocker"]},
}

var game: Node
var net: RoadNet
var player: Car
var camera: ChaseCamera
var rng := RandomNumberGenerator.new()
var active := false
var time := 0.0
var heat := 1
var heat_bonus := 0.0
var units: Array[PoliceUnit] = []
var pool := {}                 # kind -> Array[Car]
var max_cars := 12
var max_wrecks := 10
var chase_field: RoadNet.Field
var intercept_field: RoadNet.Field
var intercept_point := Vector3.INF
var bust := 0.0                # 0..1
var busted_flag := false
var heli: PoliceHeli
var roadblocks: Array = []     # {pos, dir, units: [ids], spikes: Node, passed, t}
var dispatched := 0            # tier D: units called in so far (for the HUD/radio)
var wrecked_count := 0
var stats := {"wrecked": 0, "roadblocks_escaped": 0, "spiked": 0, "max_units": 0}
var _field_t := 0.0
var _icpt_t := 0.0
var _spawn_t := 1.0
var _rb_t := 30.0
var _next_id := 1
var _ray := PhysicsRayQueryParameters3D.new()
var _player_lane := -1
var _player_s := 0.0
var _player_near := {}


func setup(p_game: Node, p_net: RoadNet, p_player: Car, p_camera: ChaseCamera) -> void:
	game = p_game
	net = p_net
	player = p_player
	camera = p_camera
	_ray.collision_mask = 1
	var st := get_node_or_null("/root/Settings")
	if st:
		max_cars = st.preset()["cars_near"]
		max_wrecks = maxi(4, max_cars - 2)


func start(p_heat := 1) -> void:
	clear()
	active = true
	time = HEAT_AT[clampi(p_heat - 1, 0, HEAT_AT.size() - 1)]
	heat = p_heat
	heat_bonus = 0.0
	bust = 0.0
	busted_flag = false
	_spawn_t = 2.5
	_rb_t = 25.0
	stats = {"wrecked": 0, "roadblocks_escaped": 0, "spiked": 0, "max_units": 0}
	dispatched = 0
	_refresh_player_lane()
	chase_field = net.flow_field(player.global_position, -player.global_basis.z)
	heat_changed.emit(heat)


func clear() -> void:
	for u in units:
		_release(u)
	units.clear()
	for rb in roadblocks:
		if is_instance_valid(rb["spikes"]):
			rb["spikes"].queue_free()
	roadblocks.clear()
	if heli:
		heli.queue_free()
		heli = null
	active = false


func heat_for_time(t: float) -> int:
	var h := 1
	for i in HEAT_AT.size():
		if t >= HEAT_AT[i]:
			h = i + 1
	if t > HEAT_AT[-1]:
		h = HEAT_AT.size() + int((t - HEAT_AT[-1]) / HEAT_STEP_AFTER)
	return h


func plan() -> Dictionary:
	var h := mini(heat, 6)
	var p: Dictionary = HEAT_PLAN[h].duplicate()
	if heat > 6:
		# Heat 7+: the whole city mobilises.
		p["units"] = 13 + (heat - 6) * 2
		p["total"] = 34 + (heat - 6) * 12
	p["units"] = mini(p["units"], max_cars)
	return p


func physical_count() -> int:
	var n := 0
	for u in units:
		if u.car and u.alive():
			n += 1
	return n


func alive_count() -> int:
	var n := 0
	for u in units:
		if u.alive():
			n += 1
	return n


# ---------------------------------------------------------------- frame
func _physics_process(dt: float) -> void:
	if not active or player == null:
		return
	time += dt
	var h := heat_for_time(time + heat_bonus)
	if h != heat:
		heat = h
		heat_changed.emit(heat)
		radio.emit(_heat_radio(heat))
	_refresh_player_lane()
	_field_t -= dt
	if _field_t <= 0.0:
		_field_t = 0.5
		chase_field = net.flow_field(player.global_position, _player_heading())
	_icpt_t -= dt
	if _icpt_t <= 0.0:
		_icpt_t = 1.5
		_update_intercept()
	_dispatch(dt)
	var space := get_world_3d().direct_space_state
	var pp := player.global_position
	for u in units:
		_update_unit(u, dt, space, pp)
	_tiers(pp)
	_roadblocks_update(dt)
	_heli_update()
	_bust_update(dt, pp)
	_cleanup(pp)
	stats["max_units"] = maxi(stats["max_units"], alive_count())


func _player_heading() -> Vector3:
	var v := player.linear_velocity
	v.y = 0.0
	if v.length() > 3.0:
		return v.normalized()
	var f := -player.global_basis.z
	f.y = 0.0
	return f.normalized()


func _refresh_player_lane() -> void:
	_player_near = net.nearest(player.global_position, _player_heading(), 40.0)
	if not _player_near.is_empty():
		_player_lane = _player_near["lane"]
		_player_s = _player_near["s"]


## Where the player will be in ~10-14 s if they keep going: walk the graph
## along the player's heading, picking the straightest way at junctions.
func _update_intercept() -> void:
	if _player_lane < 0:
		return
	var ahead := clampf(player.speed * 11.0, 120.0, 420.0)
	var lane := _player_lane
	var s := _player_s
	var d := _player_heading()
	var travelled := 0.0
	var guard := 0
	var p := player.global_position
	while travelled < ahead and guard < 40:
		guard += 1
		var id := net.node_after(lane, s)
		if id < 0:
			break
		var seg := maxf(0.0, net.node_s[id] - s)
		if travelled + seg >= ahead:
			p = net.lane_point(lane, s + (ahead - travelled))
			travelled = ahead
			break
		travelled += seg
		p = net.node_pos[id]
		var oe: PackedInt32Array = net.out_edges[id]
		var best := -1
		var bd := -2.0
		for v in oe:
			var vl := net.node_lane[v]
			var dir := net.lane_dir(vl, net.node_s[v] + 3.0)
			var score := dir.dot(d)
			if score > bd:
				bd = score
				best = v
		if best < 0:
			break
		d = d.lerp(net.lane_dir(net.node_lane[best], net.node_s[best] + 3.0), 0.5).normalized()
		s = net._advance_s(id, best)
		lane = net.node_lane[best]
	intercept_point = p
	intercept_field = net.flow_field(p)


# ---------------------------------------------------------------- dispatch
func _dispatch(dt: float) -> void:
	_spawn_t -= dt
	if _spawn_t > 0.0:
		return
	var p := plan()
	_spawn_t = rng.randf_range(2.0, 4.5) / (1.0 + (heat - 1) * 0.25)
	var alive := alive_count()
	# Units en route (tier C) plus cars: keep the total topped up.
	var want_total: int = p["total"]
	if alive >= want_total:
		return
	var kinds: Array = p["kinds"]
	var roles: Array = p["roles"]
	var role: String = roles[rng.randi() % roles.size()]
	var kind: String = kinds[rng.randi() % kinds.size()]
	if role == "heavy":
		kind = "heavy" if heat >= 4 else "patrol"
	var u := _new_unit(kind, role)
	if u == null:
		return
	dispatched += 1
	if dispatched == 1:
		radio.emit("Unit responding. Suspect vehicle heading %s." % _compass(_player_heading()))


func _new_unit(kind: String, role: String) -> PoliceUnit:
	var spot := _spawn_spot(role)
	if spot.is_empty():
		return null
	var u := PoliceUnit.new()
	u.id = _next_id
	_next_id += 1
	u.kind = kind
	u.role = role
	u.lane = spot["lane"]
	u.s = spot["s"]
	u.pos = net.lane_point(u.lane, u.s)
	u.heading = net.lane_dir(u.lane, u.s)
	u.skill = clampf(rng.randf_range(0.74, 0.92) + heat * 0.01, 0.7, 0.98)
	u.aggression = clampf(rng.randf_range(0.3, 0.8) + heat * 0.04, 0.0, 1.0)
	u.flank = rng.randf_range(-2.5, 2.5)
	u.road_speed = (CarCatalog.police_spec(kind)["top_speed"] as float) * 0.62
	u.tier = PoliceUnit.Tier.C
	u.spawn_time = time
	u.state = "intercept" if role == "interceptor" else "respond"
	units.append(u)
	return u


## A lane point out of view, SPAWN_MIN..SPAWN_MAX m of road from the player
## (interceptors: near the predicted intercept point instead, but never
## closer than SPAWN_MIN to the player and never visible).
func _spawn_spot(role: String) -> Dictionary:
	var pp := player.global_position
	var near_icpt := role == "interceptor" and intercept_point != Vector3.INF and intercept_field != null
	for attempt in 24:
		var ang := rng.randf() * TAU
		var r := rng.randf_range(SPAWN_MIN, SPAWN_MAX)
		var c := pp + Vector3(cos(ang), 0.0, sin(ang)) * r
		if near_icpt:
			c = intercept_point + Vector3(cos(ang), 0.0, sin(ang)) * rng.randf_range(60.0, 160.0)
		var n := net.nearest(c, Vector3.ZERO, 40.0, -1, true)
		if n.is_empty():
			continue
		var p: Vector3 = n["pos"]
		if p.distance_to(pp) < SPAWN_MIN * 0.75:
			continue
		var rd := net.field_distance(chase_field, n["lane"], n["s"]) if chase_field else INF
		if rd == INF or rd < SPAWN_MIN or rd > SPAWN_MAX * 2.2:
			continue
		if _visible(p + Vector3.UP):
			continue
		# A lane that leads toward the player (not straight away).
		var ahead := net.field_distance(chase_field, n["lane"], n["s"] + 20.0)
		if ahead > rd + 5.0:
			continue
		return n
	return {}


## True if a point is on screen and not hidden behind a building.
func _visible(p: Vector3) -> bool:
	var cam := camera.cam
	if cam == null or not cam.is_inside_tree():
		return false
	if not cam.is_position_in_frustum(p):
		return false
	_ray.from = cam.global_position
	_ray.to = p
	_ray.exclude = []
	var hit := get_world_3d().direct_space_state.intersect_ray(_ray)
	return hit.is_empty()


# ---------------------------------------------------------------- units
func _update_unit(u: PoliceUnit, dt: float, space: PhysicsDirectSpaceState3D, pp: Vector3) -> void:
	if u.state == "wrecked":
		u.wrecked_t += dt
		return
	if u.car:
		var c := u.car
		if c.disabled or c.upside_time > 2.5 or (c.health < 0.08):
			_wreck(u)
			return
		# Awareness: line of sight (or the helicopter) refreshes last-seen.
		var d := c.global_position.distance_to(pp)
		var sees := d < 220.0 and (heli != null or _los(c.global_position, pp))
		if sees:
			u.last_seen = pp
			u.seen_t = 0.0
		else:
			u.seen_t += dt
		if d < 12.0:
			u.close_time += dt
		u.think_t -= dt
		var period := 0.0 if u.tier == PoliceUnit.Tier.A else 0.2
		if u.think_t <= 0.0:
			u.think_t = period
			_think(u, d, sees)
		u.driver.update(dt, space)
		u.visual.set_siren(true)
	else:
		_advance_virtual(u, dt)


func _los(a: Vector3, b: Vector3) -> bool:
	_ray.from = a + Vector3.UP * 1.2
	_ray.to = b + Vector3.UP * 1.0
	_ray.exclude = []
	return get_world_3d().direct_space_state.intersect_ray(_ray).is_empty()


## Decisions for a physical unit (every frame at tier A, 5 Hz at B).
func _think(u: PoliceUnit, d: float, sees: bool) -> void:
	var drv := u.driver
	var c := u.car
	var pp := player.global_position
	var pv := player.linear_velocity
	drv.ram = false
	drv.brake_hold = false
	drv.direct_target = Vector3.INF
	drv.lateral_offset = 0.0
	drv.speed_cap = 999.0
	if u.state == "roadblock":
		drv.brake_hold = true
		# A roadblock car rejoins the chase once the player is past it.
		if d > 25.0 and (pp - c.global_position).dot(u.block_dir) > 20.0:
			u.state = "pursue"
		return
	var to_player := pp - c.global_position
	var player_fwd := _player_heading()
	var ahead_of_player := to_player.dot(player_fwd) < -5.0   # unit is in front of the player
	# Close and visible: direct pursuit by role.
	if sees and d < 70.0:
		match u.role:
			"aggressor", "heavy":
				u.state = "ram" if (u.aggression > 0.45 or heat >= 4) else "pursue"
			"interceptor", "blocker":
				u.state = "block" if ahead_of_player and d < 60.0 and player.speed > 8.0 else "pursue"
			_:
				u.state = "ram" if (heat >= 3 and u.aggression > 0.7 and d < 25.0) else "pursue"
	elif u.state in ["pursue", "ram", "block"]:
		u.state = "respond" if u.role != "interceptor" else "intercept"
	match u.state:
		"pursue":
			# Tail the player, offset to one side so a pack spreads across the road.
			var side := Vector3(-player_fwd.z, 0.0, player_fwd.x)
			drv.direct_target = pp - player_fwd * clampf(6.0 + player.speed * 0.12, 5.0, 12.0) + side * u.flank
			drv.direct_vel = pv
			drv.speed_cap = maxf(player.speed + 14.0, 18.0)
			if d < 14.0:
				drv.direct_target = pp
		"ram":
			# PIT: aim at the rear quarter, leading the player's motion.
			var side := Vector3(-player_fwd.z, 0.0, player_fwd.x)
			var q := signf(u.flank) if u.flank != 0.0 else 1.0
			drv.direct_target = pp - player_fwd * 1.6 + side * q * 1.2
			drv.direct_vel = pv
			drv.ram = true
			drv.speed_cap = player.speed + 22.0
		"block":
			# Stop across the player's path.
			drv.direct_target = c.global_position + player_fwd * -2.0
			drv.speed_cap = 4.0
			if c.speed < 6.0:
				drv.brake_hold = true
		"intercept":
			# Fell in behind the player: it's a pursuer now.
			if not ahead_of_player and d < 160.0:
				_route(u, chase_field)
			else:
				_route(u, intercept_field if intercept_field else chase_field)
			if intercept_point != Vector3.INF and c.global_position.distance_to(intercept_point) < 30.0:
				u.state = "block"
		_:
			# Respond: drive the road graph to the player (or where last seen).
			_route(u, chase_field)
	if u.state != "block" and u.state != "roadblock":
		drv.avoid_bias = u.flank


func _route(u: PoliceUnit, f: RoadNet.Field) -> void:
	var c := u.car
	u.route_t -= 0.2
	if u.route_t > 0.0 and u.driver.remaining() > 12 and u.driver.off_route() < 12.0:
		return
	u.route_t = 1.0
	var near := net.nearest(c.global_position, -c.global_basis.z, 30.0)
	if near.is_empty():
		u.driver.direct_target = player.global_position
		return
	u.driver.set_path(net.route(f, near["lane"], near["s"], 160.0 + c.speed * 3.0))


## Tier C: move along the road graph toward the player at road speed.
func _advance_virtual(u: PoliceUnit, dt: float) -> void:
	var f := intercept_field if (u.state == "intercept" and intercept_field) else chase_field
	if f == null or u.lane < 0:
		return
	var step := u.road_speed * dt
	u.s += step
	if u.s >= net.lane_len[u.lane] - 0.5 or net.node_after(u.lane, u.s) >= 0:
		var id := net.node_after(u.lane, u.s)
		if id >= 0 and net.node_s[id] <= u.s + 0.01:
			var best := -1
			var bd := INF
			var oe: PackedInt32Array = net.out_edges[id]
			var oc: PackedFloat32Array = net.out_cost[id]
			for k in oe.size():
				var dd := f.dist[oe[k]] + oc[k]
				if dd < bd:
					bd = dd
					best = oe[k]
			if best >= 0:
				u.s = net._advance_s(id, best)
				u.lane = net.node_lane[best]
	if net.lane_loop[u.lane] == 1:
		u.s = fposmod(u.s, net.lane_len[u.lane])
	u.pos = net.lane_point(u.lane, u.s)
	u.heading = net.lane_dir(u.lane, u.s)


## Promote / demote between road-graph points and physical cars.
func _tiers(pp: Vector3) -> void:
	var cars := physical_count()
	var p := plan()
	var want_cars: int = p["units"]
	# Candidates for promotion: nearest virtual units first.
	var virt: Array = []
	for u in units:
		if not u.alive():
			continue
		if u.car:
			var d := u.car.global_position.distance_to(pp)
			u.tier = PoliceUnit.Tier.A if d < TIER_A_R else PoliceUnit.Tier.B
			if d > DEMOTE_R and not _visible(u.car.global_position + Vector3.UP) and u.state != "roadblock":
				_demote(u)
				cars -= 1
		else:
			virt.append(u)
	virt.sort_custom(func(a, b): return a.pos.distance_squared_to(pp) < b.pos.distance_squared_to(pp))
	for u: PoliceUnit in virt:
		if cars >= want_cars:
			break
		var d := u.pos.distance_to(pp)
		if d < PROMOTE_R or (d < SPAWN_MAX and cars < mini(want_cars, 2)):
			if not _visible(u.pos + Vector3.UP) and d > 45.0 and _clear(u.pos):
				_promote(u)
				cars += 1


func _clear(p: Vector3) -> bool:
	var q := PhysicsShapeQueryParameters3D.new()
	var b := BoxShape3D.new()
	b.size = Vector3(3.0, 1.6, 6.0)
	q.shape = b
	q.transform = Transform3D(Basis(), p + Vector3.UP * 1.1)
	q.collision_mask = 1 | (1 << 2)
	return get_world_3d().direct_space_state.intersect_shape(q, 1).is_empty()


func _promote(u: PoliceUnit) -> void:
	var car := _take_car(u.kind)
	u.car = car
	var dir := u.heading
	car.place(Transform3D(Basis.looking_at(dir, Vector3.UP), u.pos + Vector3.UP * 0.4), dir * u.road_speed * 0.7)
	car.reset_damage()
	u.visual = car.visual as CarVisual
	u.visual.reset_dents()
	u.visual.set_siren(true)
	u.driver = AIDriver.new(car)
	u.driver.skill = u.skill
	u.tier = PoliceUnit.Tier.B
	u.route_t = 0.0
	u.think_t = 0.0
	if u.role == "interceptor":
		u.state = "intercept"


func _demote(u: PoliceUnit) -> void:
	var near := net.nearest(u.car.global_position, -u.car.global_basis.z, 40.0, -1, true)
	if not near.is_empty():
		u.lane = near["lane"]
		u.s = near["s"]
	u.pos = u.car.global_position
	_return_car(u)
	u.tier = PoliceUnit.Tier.C


func _take_car(kind: String) -> Car:
	var list: Array = pool.get(kind, [])
	var car: Car
	if not list.is_empty():
		car = list.pop_back()
		car.visible = true
		car.process_mode = Node.PROCESS_MODE_INHERIT
		car.freeze = false
	else:
		car = Car.new()
		car.setup(CarCatalog.police_spec(kind), "police")
		car.name = "Police_%s_%d" % [kind, _next_id]
		add_child(car)
		var v := CarVisual.new()
		car.add_child(v)
		v.setup(car)
		car.visual = v
		car.impact.connect(_on_police_impact.bind(car))
	return car


func _return_car(u: PoliceUnit) -> void:
	if u.car == null:
		return
	var car := u.car
	u.car = null
	u.visual = null
	u.driver = null
	car.visual.set_beacon_lights(false)
	car.freeze = true
	car.visible = false
	car.process_mode = Node.PROCESS_MODE_DISABLED
	car.global_position = Vector3(0, -500, 0)
	if not pool.has(car.spec["id"].trim_prefix("police_")):
		pool[car.spec["id"].trim_prefix("police_")] = []
	pool[car.spec["id"].trim_prefix("police_")].append(car)


func _release(u: PoliceUnit) -> void:
	_return_car(u)


func _wreck(u: PoliceUnit) -> void:
	u.state = "wrecked"
	u.wrecked_t = 0.0
	u.car.disabled = true
	u.visual.set_siren(false)
	u.visual.set_beacon_lights(false)
	if not u.counted_wreck:
		u.counted_wreck = true
		stats["wrecked"] += 1
		wrecked_count += 1
		heat_bonus += 6.0
		unit_wrecked.emit(u, true)
		if stats["wrecked"] in [1, 5, 10, 25, 50]:
			radio.emit("We've lost %d units! Requesting backup." % stats["wrecked"] if stats["wrecked"] > 1 else "Unit down! Unit down!")


func _on_police_impact(strength: float, at: Vector3, n: Vector3, other: Object, car: Car) -> void:
	if strength > 6.0:
		car.visual.dent(at, -n, clampf(strength / 70.0, 0.03, 0.22))
		var fx := get_node_or_null("../Fx")
		if fx and strength > 8.0 and other != player:
			fx.impact(at, n, strength * 0.7, car.spec["paint"])
	if other == player:
		for u in units:
			if u.car == car:
				u.hit_player_t = time


func _cleanup(pp: Vector3) -> void:
	# Wrecks stay where they died (pile-ups!) until well out of view, and
	# the oldest go first when there are too many.
	var wrecks: Array = []
	for u in units:
		if u.state == "wrecked" and u.car:
			wrecks.append(u)
	wrecks.sort_custom(func(a, b): return a.wrecked_t > b.wrecked_t)
	for i in wrecks.size():
		var u: PoliceUnit = wrecks[i]
		var far := u.car.global_position.distance_to(pp) > 160.0 and not _visible(u.car.global_position + Vector3.UP)
		if far or (i < wrecks.size() - max_wrecks and u.wrecked_t > 4.0):
			_return_car(u)
	var keep: Array[PoliceUnit] = []
	for u in units:
		if u.state == "wrecked" and u.car == null:
			continue
		keep.append(u)
	units = keep
	# Cars past the physics budget near a wreck pile: still fine (wrecks are cheap).


# ---------------------------------------------------------------- roadblocks
func _roadblocks_update(dt: float) -> void:
	if heat >= 3:
		_rb_t -= dt
		if _rb_t <= 0.0:
			_rb_t = rng.randf_range(32.0, 48.0) / (1.0 + (heat - 3) * 0.15)
			_spawn_roadblock()
	var pp := player.global_position
	var keep: Array = []
	for rb in roadblocks:
		var past: bool = (pp - (rb["pos"] as Vector3)).dot(rb["dir"]) > 15.0 and pp.distance_to(rb["pos"]) < 60.0
		if past and not rb["passed"]:
			rb["passed"] = true
			stats["roadblocks_escaped"] += 1
			heat_bonus += 8.0
			roadblock_escaped.emit()
			radio.emit("Suspect is through the roadblock!")
		rb["t"] += dt
		var gone: bool = rb["passed"] and pp.distance_to(rb["pos"]) > 200.0
		if rb["t"] > 90.0 and pp.distance_to(rb["pos"]) > 250.0:
			gone = true
		if gone:
			if is_instance_valid(rb["spikes"]):
				(rb["spikes"] as Node).queue_free()
			continue
		keep.append(rb)
	roadblocks = keep


## A roadblock across a straight stretch of the predicted route, 200-300 m
## ahead and out of sight – announced to the player as soon as it's placed.
func _spawn_roadblock() -> void:
	# (Any reason it can't go here: try again in a few seconds.)
	var retry := func(): _rb_t = 3.0
	if intercept_point == Vector3.INF or physical_count() + 3 > max_cars + 2:
		retry.call()
		return
	var near := net.nearest(intercept_point, Vector3.ZERO, 40.0, -1, true)
	if near.is_empty():
		retry.call()
		return
	var lane: int = near["lane"]
	var s: float = near["s"]
	var p := net.lane_point(lane, s)
	if p.distance_to(player.global_position) < 150.0 or _visible(p + Vector3.UP):
		retry.call()
		return
	var dir := net.lane_dir(lane, s)
	# Is it straight here? (a roadblock round a blind bend would be unfair)
	if net.lane_dir(lane, s - 25.0).dot(dir) < 0.92:
		retry.call()
		return
	# Centre it on the road, not the lane: the lane is offset from the middle.
	var right0 := Vector3(-dir.z, 0.0, dir.x)
	var other := net.nearest(p - right0 * 6.0, -dir, 9.0, lane, true)
	if not other.is_empty():
		p = (p + (other["pos"] as Vector3)) * 0.5
	var right := Vector3(-dir.z, 0.0, dir.x)
	var rb := {"pos": p, "dir": dir, "units": [], "spikes": null, "passed": false, "t": 0.0}
	var n := 2 if heat < 5 else 3
	var gap := rng.randi() % (n + 1)  # a gap somewhere – escapable by design
	var slots := [-6.0, 0.0, 6.0] if n == 3 else [-3.5, 3.5]
	for i in slots.size():
		if i == gap and n == 3:
			continue
		var kind := "heavy" if heat >= 4 and i == 1 else "patrol"
		var u := PoliceUnit.new()
		u.id = _next_id
		_next_id += 1
		u.kind = kind
		u.role = "blocker"
		u.state = "roadblock"
		u.block_dir = dir
		var at := p + right * float(slots[i]) * 1.1 + Vector3.UP * 0.4
		var car := _take_car(kind)
		u.car = car
		var yaw_dir := right if i % 2 == 0 else -right
		car.place(Transform3D(Basis.looking_at(yaw_dir.rotated(Vector3.UP, rng.randf_range(-0.3, 0.3)), Vector3.UP), at))
		car.reset_damage()
		u.visual = car.visual as CarVisual
		u.visual.reset_dents()
		u.visual.set_siren(true)
		u.driver = AIDriver.new(car)
		u.driver.brake_hold = true
		u.tier = PoliceUnit.Tier.B
		u.spawn_time = time
		units.append(u)
		(rb["units"] as Array).append(u.id)
	if heat >= 4:
		var sp := SpikeStrip.new()
		sp.player = player
		add_child(sp)
		sp.global_transform = Transform3D(Basis.looking_at(dir, Vector3.UP), p - dir * 14.0 + right * rng.randf_range(-3.0, 3.0))
		sp.spiked.connect(func(): stats["spiked"] += 1; spiked.emit())
		rb["spikes"] = sp
	roadblocks.append(rb)
	roadblock_spawned.emit(p)
	radio.emit("Roadblock set up on the suspect's route!")


# ---------------------------------------------------------------- helicopter
func _heli_update() -> void:
	if heat >= 4 and heli == null:
		heli = PoliceHeli.new()
		heli.target = player
		add_child(heli)
		heli.global_position = player.global_position + Vector3(-200, 90, -200)
		radio.emit("Air support is overhead.")


# ---------------------------------------------------------------- capture
func _bust_update(dt: float, pp: Vector3) -> void:
	if busted_flag:
		return
	var near := 0
	for u in units:
		if u.car and u.alive() and u.car.global_position.distance_to(pp) < BUST_R:
			near += 1
	var slow := player.speed < 3.5
	var rate := 0.0
	if player.disabled:
		rate = 0.45 + near * 0.15
	elif slow and near > 0:
		rate = 0.22 + 0.14 * near
	if rate > 0.0:
		bust = minf(1.0, bust + rate * dt)
	else:
		bust = maxf(0.0, bust - dt * (0.9 if player.speed > 8.0 else 0.35))
	if bust >= 1.0:
		busted_flag = true
		busted.emit()


func nearby_police(p: Vector3, r: float) -> int:
	var n := 0
	for u in units:
		if u.car and u.alive() and u.car.global_position.distance_to(p) < r:
			n += 1
	return n


## For the minimap and audio: [[pos, kind, state], ...]
func unit_markers() -> Array:
	var out: Array = []
	for u in units:
		out.append([u.world_pos(), u.kind, u.state])
	return out


func _heat_radio(h: int) -> String:
	match h:
		2: return "All units: suspect is not stopping. Additional units responding."
		3: return "Pursuit escalated. Interceptors and roadblocks authorised."
		4: return "Heavy units deployed. Air support inbound. Spike strips authorised."
		5: return "Every available unit, converge on the suspect."
		6: return "Citywide alert. Nobody goes home until this car stops."
	return "Heat level %d. The whole city is after you." % h


static func _compass(d: Vector3) -> String:
	var a := fposmod(rad_to_deg(atan2(d.x, -d.z)), 360.0)
	return ["north", "north-east", "east", "south-east", "south", "south-west", "west", "north-west"][int((a + 22.5) / 45.0) % 8]
