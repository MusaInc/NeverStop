class_name CityInfrastructure
extends RefCounted
## Designed connections and public spaces, using the existing batched kit.

static func bridge_landing(l: CityLayout) -> void:
	var road: PackedVector2Array = l.roads.by_name.diagonal.pts
	var path := PackedVector2Array()
	# First roundabout is the ramp's at-grade destination; use the same cut
	# as Traffic so its lanes meet the roundabout connectors exactly.
	var first: Dictionary = {}
	for rb in l.roads.roundabouts:
		if rb.c.x > 150.0 and rb.c.x < 400.0 and rb.c.y > -140.0:
			first = rb
	if first.is_empty():
		return
	var cut := CityRoads._circle(first.c, float(first.r) + float(first.w) * 0.5 + 0.5, 32)
	var sections := Geometry2D.clip_polyline_with_polygon(road, cut)
	var approach: PackedVector2Array = sections[0]
	path.append(Vector2(56.0, CityLayout.BRIDGE_Z))
	for p in approach:
		if p.x > 60.0:
			path.append(p)
	var flat := RailNetwork._resample_open(path, 6.0)
	var end := flat[-1]
	var finish := l.terrain.road_y(end.x, end.y)
	var total := CityRoads.length_of(flat)
	var travelled := 0.0
	for i in flat.size():
		if i > 0:
			travelled += flat[i].distance_to(flat[i - 1])
		var u := travelled / total
		var y := lerpf(CityLayout.BRIDGE_DECK, finish, smoothstep(0.0, 1.0, u))
		l.bridge_ramp.append(Vector3(flat[i].x, y, flat[i].y))
	var k := l._kit("island_bridge_approach")
	var stone := Color(0.43, 0.44, 0.43)
	var white := Color(0.76, 0.76, 0.70)
	for i in l.bridge_ramp.size() - 1:
		var a := l.bridge_ramp[i]
		var b := l.bridge_ramp[i + 1]
		var d := (b - a).normalized()
		var side := Vector3(-d.z, 0, d.x).normalized()
		var ext := d * 0.08
		l._kbeam(k, a - ext + Vector3.DOWN * 0.65, b + ext + Vector3.DOWN * 0.65, 20.0, 1.3, Color(0.15, 0.16, 0.17))
		for sg: float in [-1.0, 1.0]:
			var o := side * sg * 9.8
			# End barriers before the junction mouth, leaving turning space.
			if i < l.bridge_ramp.size() - 3:
				l._kbeam(k, a + o + Vector3.UP * 0.5, b + o + Vector3.UP * 0.5, 0.35, 1.0, stone)
			l._kbeam(k, a + side * sg * 8.4 + Vector3.UP * 0.025, b + side * sg * 8.4 + Vector3.UP * 0.025, 0.12, 0.02, white, false)
			if i % 2 == 0:
				l._kbeam(k, a + side * sg * 5.1 + Vector3.UP * 0.025, a.lerp(b, 0.5) + side * sg * 5.1 + Vector3.UP * 0.025, 0.12, 0.02, white, false)
		l._kbeam(k, a + Vector3.UP * 0.025, b + Vector3.UP * 0.025, 0.2, 0.02, Color(0.7, 0.6, 0.27), false)
		if i % 6 == 0:
			var g := l.terrain.road_y(a.x, a.z)
			var field := l.roads.field_at(Vector2(a.x, a.z))
			if a.y - g > 3.5 and field.w > 2.5:
				l._kbeam(k, Vector3(a.x, g - 0.4, a.z), a + Vector3.DOWN * 1.8, 1.6, 1.6, stone)
				l._kbeam(k, a - side * 8 + Vector3.DOWN * 1.7, a + side * 8 + Vector3.DOWN * 1.7, 1.6, 1.0, stone)
				l._ksolid(k, a.x - 1.5, a.z - 1.5, a.x + 1.5, a.z + 1.5, g - 0.6, g + 0.2, stone)
		# Lamps have their normal short visibility range and shared mesh.
		if i % 7 == 1:
			for sg: float in [-1.0, 1.0]:
				var p := a + side * sg * 8.9
				l.props.append(["streetlight", Transform3D(Basis(Vector3.UP, atan2(d.x, d.z) + (PI if sg > 0 else 0)), p)])

static func bridge_height(l: CityLayout, x: float) -> float:
	if x <= 56.0 or l.bridge_ramp.is_empty():
		return CityLayout.approach_y(x)
	for i in l.bridge_ramp.size() - 1:
		var a := l.bridge_ramp[i]
		var b := l.bridge_ramp[i + 1]
		if x <= b.x:
			return lerpf(a.y, b.y, clampf((x - a.x) / maxf(0.01, b.x - a.x), 0.0, 1.0))
	return l.bridge_ramp[-1].y

static func public_spaces(l: CityLayout) -> void:
	# Riverside seating bays sit between the viaduct and the quay edge.
	# Leave the bridge crossing, lighthouse and the corners unobstructed.
	if not l.is_mainland:
		for z in range(-520, 521, 56):
			if absf(z - CityLayout.BRIDGE_Z) < 55 or absf(z - SetPieces.LIGHTHOUSE_AT.y) < 22:
				continue
			var p := Vector3(37.5, l.ground_y(37.5, z), z)
			if l.is_water(p):
				continue
			var crossing := false
			for dz: float in [-14.0, 0.0, 14.0]:
				if l.roads.on_road(Vector2(p.x + 2.3, p.z + dz)):
					crossing = true
			if crossing:
				continue
			garden(l, p + Vector3(2.3, 0, 0), Vector2(2.5, 7.0), false)
			furniture(l, "bench", p + Vector3(0, 0, -5.5), PI * 0.5)
			furniture(l, "bin", p + Vector3(0, 0, 5.5), 0)
			l.props.append(["streetlight", Transform3D(Basis(Vector3.UP, PI * 0.5), p + Vector3(0, 0, 11))])
	# Turn genuinely empty block interiors into courtyard gardens. Test the
	# whole envelope against buildings, roads and existing props; no random
	# filling of streets, station platforms, landmarks or apartment entrances.
	var grid := l._building_grid()
	var count := 0
	for block in l.blocks:
		if block.kind != "block" or count >= 24:
			continue
		var c := CityRoads._centroid(block.poly)
		var p := Vector3(c.x, l.ground_y(c.x, c.y), c.y)
		var clear := true
		for dx: float in [-8.0, 0.0, 8.0]:
			for dz: float in [-8.0, 0.0, 8.0]:
				var q := c + Vector2(dx, dz)
				if not Geometry2D.is_point_in_polygon(q, block.poly) or l.roads.on_road(q) or absf(l.ground_y(q.x, q.y) - p.y) > 0.35:
					clear = false
		for gx in range(-1, 2):
			for gz in range(-1, 2):
				var cell := Vector2i(floori(c.x / 50), floori(c.y / 50)) + Vector2i(gx, gz)
				for b in grid.get(cell, []):
					if CityLayout.inside(b, p + Vector3.UP, 10.0, 2.0):
						clear = false
		for prop in l.props:
			if (prop[1].origin as Vector3).distance_to(p) < 9.0:
				clear = false
		if not clear:
			continue
		garden(l, p, Vector2(8, 8), true)
		furniture(l, "bench", p + Vector3(0, 0, 6), PI)
		furniture(l, "bench", p + Vector3(0, 0, -6), 0)
		furniture(l, "bin", p + Vector3(5, 0, 6), 0)
		count += 1

static func garden(l: CityLayout, p: Vector3, size: Vector2, tree: bool) -> void:
	var name := "gardens_%d_%d" % [floori(p.x / CityLayout.CHUNK), floori(p.z / CityLayout.CHUNK)]
	var k: Dictionary = {}
	for structure in l.structures:
		if structure.get("name", "") == name:
			k = structure
			break
	if k.is_empty():
		k = l._kit(name)
	var x := size.x * 0.5
	var z := size.y * 0.5
	l._ksolid(k, p.x - x, p.z - z, p.x + x, p.z + z, p.y - 0.1, p.y + 0.35, Color(0.34, 0.36, 0.32))
	l._ksolid(k, p.x - x + 0.2, p.z - z + 0.2, p.x + x - 0.2, p.z + z - 0.2, p.y + 0.35, p.y + 0.39, Color(0.23, 0.32, 0.20), false)
	l.public_gardens.append(p)
	if tree:
		l.props.append(["tree", Transform3D(Basis().scaled(Vector3.ONE * 0.85), p + Vector3.UP * 0.39)])
	else:
		for dz: float in [-2.0, 2.0]:
			l.props.append(["tree", Transform3D(Basis().scaled(Vector3.ONE * 0.48), p + Vector3(0, 0.39, dz))])

static func furniture(l: CityLayout, kind: String, p: Vector3, yaw: float) -> void:
	l.public_furniture.append([kind, Transform3D(Basis(Vector3.UP, yaw), p)])

## Compact switchback stairs in a clear pavement plot, joined to the
## adjacent platform by an elevated walkway. Smooth collision ramps
## share the visible stair flights, avoiding dozens of collision shapes.
static func station_access(l: CityLayout, k: Dictionary, c: Vector3, d: Vector3, side: Vector3) -> void:
	var at := Vector3.INF
	var grid := l._building_grid()
	for distance: float in [18.0, 24.0, 30.0, 38.0]:
		for sign_side: float in [-1.0, 1.0]:
			for along: float in [0.0, -24.0, 24.0]:
				var p := c + side * sign_side * distance + d * along
				p.y = l.ground_y(p.x, p.z)
				var clear := not l.is_water(p)
				for dx: float in [-3.0, 0.0, 3.0]:
					for dz: float in [-5.0, 0.0, 5.0]:
						var q := p + side * dx + d * dz
						if l.roads.on_road(Vector2(q.x, q.z)) or absf(l.ground_y(q.x, q.z) - p.y) > 0.45:
							clear = false
				for gx in range(-1, 2):
					for gz in range(-1, 2):
						for b in grid.get(Vector2i(floori(p.x / 50), floori(p.z / 50)) + Vector2i(gx, gz), []):
							if CityLayout.inside(b, p + Vector3.UP * 2, 6.5, 2.0):
								clear = false
				if clear:
					at = p
					break
			if at != Vector3.INF:
				break
		if at != Vector3.INF:
			break
	if at == Vector3.INF:
		return  # avoid inventing a tower in traffic or through an existing building
	var top := c.y + 1.0
	var flights := maxi(2, ceili((top - at.y) / 1.5))
	var rise := (top - at.y) / flights
	var steel := Color(0.24, 0.29, 0.29)
	var stone := Color(0.47, 0.47, 0.43)
	# Four full-height columns and a roof make the structure legible from afar.
	for sx: float in [-2.1, 2.1]:
		for sz: float in [-4.4, 4.4]:
			var p := at + side * sx + d * sz
			l._kbeam(k, p - Vector3.UP * 0.2, Vector3(p.x, top + 2.8, p.z), 0.24, 0.24, steel)
	for f in flights:
		var sg := 1.0 if f % 2 == 0 else -1.0
		var a := at + side * sg * 1.0 - d * sg * 3.2 + Vector3.UP * (rise * f)
		var b := at + side * sg * 1.0 + d * sg * 3.2 + Vector3.UP * (rise * (f + 1))
		l._kbeam(k, a + Vector3.DOWN * 0.12, b + Vector3.DOWN * 0.12, 1.7, 0.24, stone)
		for step in 9:
			var p := a.lerp(b, float(step + 1) / 9)
			l._kbeam(k, p - d * 0.36, p + d * 0.36, 1.7, 0.1, stone, false)
		var landing := b + d * sg * 0.6 - side * sg
		l._kbeam(k, landing - side * 2, landing + side * 2, 1.2, 0.2, stone)
		l._kbeam(k, a + side * sg * 0.85 + Vector3.UP, b + side * sg * 0.85 + Vector3.UP, 0.08, 0.08, steel, false)
	var upper := Vector3(at.x, top, at.z)
	var sg := signf((at - c).dot(side))
	var platform := c + side * sg * 6.0 + Vector3.UP
	l._kbeam(k, upper + Vector3.DOWN * 0.15, platform + Vector3.DOWN * 0.15, 2.2, 0.3, stone)
	for offset: float in [-1.0, 1.0]:
		l._kbeam(k, upper + d * offset + Vector3.UP, platform + d * offset + Vector3.UP, 0.08, 0.08, steel, false)
	l._kbeam(k, upper - d * 4.7 + Vector3.UP * 2.8, upper + d * 4.7 + Vector3.UP * 2.8, 4.6, 0.18, steel)
	furniture(l, "sign_post", at + d * 5.5, 0)


## Finishing the open ground: every plaza gets a planted square (a grid of
## tree planters with benches and bins, lamps between them; a fountain and
## kiosks in the big ones) and every park a tree-lined edge with lamps and
## benches plus denser tree clusters. Runs LAST (after the rail line and
## every other prop) so existing props keep their order in each chunk, and
## keeps clear of roads, buildings, kit structures, other props and the
## rail line (`rail_lines`: PackedVector3Array centre lines).
static func open_ground(l: CityLayout, rail_lines: Array) -> void:
	var occ := {}   # 3 m cells already taken
	var mark := func(p: Vector2, r: float) -> void:
		for gx in range(floori((p.x - r) / 3.0), floori((p.x + r) / 3.0) + 1):
			for gz in range(floori((p.y - r) / 3.0), floori((p.y + r) / 3.0) + 1):
				occ[Vector2i(gx, gz)] = true
	for pr in l.props:
		var o: Vector3 = (pr[1] as Transform3D).origin
		mark.call(Vector2(o.x, o.z), 1.5)
	for it in l.public_furniture:
		var o: Vector3 = (it[1] as Transform3D).origin
		mark.call(Vector2(o.x, o.z), 1.5)
	var kit_rects: Array = []
	for s in l.structures:
		if s.get("type", "") == "kit":
			for so in s["solids"]:
				kit_rects.append(Rect2(so[0], so[1], so[2] - so[0], so[3] - so[1]).grow(2.0))
	var rail2: Array = []
	for pts: PackedVector3Array in rail_lines:
		var p2 := PackedVector2Array()
		for v in pts:
			p2.append(Vector2(v.x, v.z))
		rail2.append(p2)
	# Big bare squares (the railway terminus, the strip under the viaduct)
	# get real buildings on what the rail line leaves free, like any block.
	var built_on := 0
	for blk in l.blocks:
		if blk["kind"] != "plaza" or CityRoads._area(blk["poly"]) < 6000.0:
			continue
		var pieces: Array = [blk["poly"]]
		var holes: Array = []   # inside a loop's band: free ground again
		var bands: Array = []
		for p2: PackedVector2Array in rail2:
			for band in Geometry2D.offset_polyline(p2, 11.0):
				if Geometry2D.is_polygon_clockwise(band):
					var h := band.duplicate()
					h.reverse()
					holes.append(h)
					continue
				bands.append(band)
				var next: Array = []
				for pc: PackedVector2Array in pieces:
					for q in Geometry2D.clip_polygons(pc, band):
						if not Geometry2D.is_polygon_clockwise(q):
							next.append(q)
				pieces = next
		for h: PackedVector2Array in holes:
			for q in Geometry2D.intersect_polygons(blk["poly"], h):
				if not Geometry2D.is_polygon_clockwise(q):
					pieces.append(q)
		# Station stairs and walkways (kit solids) stay clear too.
		for kr: Rect2 in kit_rects:
			var kq := PackedVector2Array([kr.position, Vector2(kr.end.x, kr.position.y), kr.end, Vector2(kr.position.x, kr.end.y)])
			var next2: Array = []
			for pc: PackedVector2Array in pieces:
				for q in Geometry2D.clip_polygons(pc, kq):
					if not Geometry2D.is_polygon_clockwise(q):
						next2.append(q)
			pieces = next2
		var c0 := CityRoads._centroid(blk["poly"])
		var brng := RandomNumberGenerator.new()
		brng.seed = hash(Vector2i(int(c0.x), int(c0.y))) ^ 0xb10c
		# The terminus is reserved only to keep streets out of the loop
		# while it's laid; with the line in place its free ground is
		# ordinary building land (the viaduct strip stays reserved: the
		# bridge deck runs over it).
		var lifted := l.reserved.filter(func(r): return r == RailNetwork.TERMINUS)
		for r in lifted:
			l.reserved.erase(r)
		var b0 := l.buildings.size()
		var p0 := l.props.size()
		for pc: PackedVector2Array in pieces:
			if CityRoads._area(pc) < 1500.0:
				continue
			l._fill_block(pc, blk["district"], brng, l._frame_angle(pc), CityRoads._centroid(pc))
		l.reserved.append_array(lifted)
		# A clipped piece keeps the band as a hole the lot packer can't
		# see: drop any new building on the line (or on another one),
		# and whatever was put on its roof.
		var kept_quads: Array = []
		var dropped: Array = []
		var keep_b: Array = []
		for bi in range(b0, l.buildings.size()):
			var q := footprint(l.buildings[bi])
			var bad := q.is_empty()
			for band: PackedVector2Array in bands:
				if bad:
					break
				if not Geometry2D.intersect_polygons(q, band).is_empty():
					var in_hole := false
					for h: PackedVector2Array in holes:
						if Geometry2D.clip_polygons(q, h).is_empty():
							in_hole = true
					bad = not in_hole
			for kq: PackedVector2Array in kept_quads:
				if not bad and not Geometry2D.intersect_polygons(Geometry2D.offset_polygon(q, -0.3)[0], kq).is_empty():
					bad = true
			if bad:
				dropped.append(q)
			else:
				kept_quads.append(q)
				keep_b.append(l.buildings[bi])
		l.buildings.resize(b0)
		l.buildings.append_array(keep_b)
		var keep_p: Array = []
		for pi in range(p0, l.props.size()):
			var o: Vector3 = (l.props[pi][1] as Transform3D).origin
			var on_dropped := false
			for dq: PackedVector2Array in dropped:
				if Geometry2D.is_point_in_polygon(Vector2(o.x, o.z), Geometry2D.offset_polygon(dq, 1.0)[0]):
					on_dropped = true
			if not on_dropped:
				keep_p.append(l.props[pi])
		l.props.resize(p0)
		l.props.append_array(keep_p)
		built_on += keep_b.size()
	var piece_rects: Array = []
	if l.pieces and not l.is_mainland:
		piece_rects = l.pieces.rects().values()
		built_on += _fill_piece_blocks(l, piece_rects, kit_rects)
	var grid := l._building_grid()
	var free := func(q: Vector2, r: float, inner: PackedVector2Array) -> bool:
		if not Geometry2D.is_point_in_polygon(q, inner) or l.roads.on_road(q) or l.is_water(Vector3(q.x, 0, q.y)):
			return false
		for gx in range(floori((q.x - r) / 3.0), floori((q.x + r) / 3.0) + 1):
			for gz in range(floori((q.y - r) / 3.0), floori((q.y + r) / 3.0) + 1):
				if occ.has(Vector2i(gx, gz)):
					return false
		for kr: Rect2 in kit_rects:
			if kr.grow(r).has_point(q):
				return false
		for pr: Rect2 in piece_rects:
			if pr.grow(r + 2.0).has_point(q):
				return false  # (never a planter on the pitch or in the gasholder)
		for p2: PackedVector2Array in rail2:
			for k in p2.size() - 1:
				if Geometry2D.get_closest_point_to_segment(q, p2[k], p2[k + 1]).distance_to(q) < 9.0 + r:
					return false
		var y := l.ground_y(q.x, q.y)
		# Under the bridge approach only where the deck is well overhead.
		if l.is_mainland and absf(q.y - CityLayout.BRIDGE_Z) < 16.0 + r and q.x > CityLayout.APPROACH_END - 4.0 \
				and q.x < CityLayout.FAR_SHORE and l.approach_y(q.x) - y < 12.0:
			return false
		var cell := Vector2i(floori(q.x / 50), floori(q.y / 50))
		for gx in range(-1, 2):
			for gz in range(-1, 2):
				for b in grid.get(cell + Vector2i(gx, gz), []):
					if CityLayout.inside(b, Vector3(q.x, y + 1.0, q.y), r + 1.5, 2.0):
						return false
		# Level enough for a planter or a bench.
		for d: Vector2 in [Vector2(r, 0), Vector2(-r, 0), Vector2(0, r), Vector2(0, -r)]:
			if absf(l.ground_y(q.x + d.x, q.y + d.y) - y) > 0.45:
				return false
		return true
	var at := func(q: Vector2) -> Vector3:
		return Vector3(q.x, l.ground_y(q.x, q.y), q.y)
	var squares := 0
	var parks := 0
	for blk in l.blocks:
		var kind: String = blk["kind"]
		if kind not in ["plaza", "park", "piece"]:
			continue
		var poly: PackedVector2Array = blk["poly"]
		var area := CityRoads._area(poly)
		if area < 260.0:
			continue
		var c := CityRoads._centroid(poly)
		var rng := RandomNumberGenerator.new()
		rng.seed = hash(Vector2i(int(c.x), int(c.y))) ^ 0x51a2a
		var ang := l._frame_angle(poly)
		var ax := Vector2(cos(ang), sin(ang))
		var az := Vector2(-ax.y, ax.x)
		var bb := CityLayout._bbox(poly)
		var span := bb.size.length() * 0.5 + 4.0
		if kind == "piece":
			# The set piece's forecourt: a tree-lined green round it.
			for pr: Rect2 in piece_rects:
				if not Geometry2D.is_point_in_polygon(pr.get_center(), poly):
					continue
				var ring := pr.grow(7.0)
				var corners := [ring.position, Vector2(ring.end.x, ring.position.y), ring.end, Vector2(ring.position.x, ring.end.y)]
				var ins0 := Geometry2D.offset_polygon(poly, -3.0)
				if ins0.is_empty():
					break
				for e in 4:
					var a: Vector2 = corners[e]
					var b: Vector2 = corners[(e + 1) % 4]
					var L := a.distance_to(b)
					var d := (b - a) / L
					var t := 4.0
					var k := 0
					while t < L - 3.0:
						var q := a + d * t
						if k % 3 == 2:
							if free.call(q, 1.0, ins0[0]):
								l.props.append(["streetlight", Transform3D(Basis(Vector3.UP, atan2(d.x, d.y)), at.call(q))])
								mark.call(q, 1.2)
						elif free.call(q, 1.8, ins0[0]):
							l.props.append(["tree", Transform3D(Basis(Vector3.UP, rng.randf() * TAU).scaled(
								Vector3.ONE * rng.randf_range(0.9, 1.25)), at.call(q))])
							mark.call(q, 2.4)
							var bq := q - Vector2(d.y, -d.x) * 2.2
							if k % 3 == 1 and free.call(bq, 1.0, ins0[0]):
								furniture(l, "bench", at.call(bq), atan2(d.x, d.y) + PI * 0.5)
								mark.call(bq, 1.0)
						t += 8.0
						k += 1
			kind = "plaza"  # …and the rest of its paving is dressed like a square
		if kind == "plaza":
			var ins := Geometry2D.offset_polygon(poly, -3.0)
			if ins.is_empty():
				continue
			var inner: PackedVector2Array = ins[0]
			# A fountain at the heart of a big square.
			var big := area > 3500.0
			if big and free.call(c, 6.5, inner):
				fountain(l, at.call(c))
				mark.call(c, 7.5)
				for k in 4:
					var d := (ax if k % 2 == 0 else az) * (1.0 if k < 2 else -1.0)
					var q := c + d * 9.5
					if free.call(q, 1.2, inner):
						furniture(l, "bench", at.call(q), atan2(d.x, d.y))
						mark.call(q, 1.2)
			# Planters and lamps on a 10 m grid along the square's frame.
			var step := 10.0
			var n := int(span / step) + 1
			for i in range(-n, n + 1):
				for j in range(-n, n + 1):
					var q := c + ax * (i * step + step * 0.5) + az * (j * step + step * 0.5)
					if (i + j) % 2 == 0:
						if not free.call(q, 2.2, inner):
							continue
						garden(l, at.call(q), Vector2(2.8, 2.8), true)
						mark.call(q, 2.2)
						var bq := q + az * 2.6
						if free.call(bq, 1.0, inner):
							furniture(l, "bench", at.call(bq), ang + PI)
							mark.call(bq, 1.0)
						if rng.randf() < 0.35:
							var cq := q - ax * 2.4
							if free.call(cq, 0.6, inner):
								furniture(l, "bin", at.call(cq), 0.0)
								mark.call(cq, 0.6)
					else:
						if free.call(q, 1.0, inner):
							l.props.append(["streetlight", Transform3D(Basis(Vector3.UP, ang), at.call(q))])
							mark.call(q, 1.2)
			# Kiosks round the edge of the big squares.
			if big:
				var placed := 0
				for k in 24:
					if placed >= 2:
						break
					var q := Vector2(rng.randf_range(bb.position.x, bb.end.x), rng.randf_range(bb.position.y, bb.end.y))
					if free.call(q, 3.2, inner):
						kiosk(l, at.call(q), ang, rng)
						mark.call(q, 3.5)
						placed += 1
			squares += 1
		else:
			var ins := Geometry2D.offset_polygon(poly, -3.0)
			if ins.is_empty():
				continue
			var inner: PackedVector2Array = ins[0]
			# A tree row just inside the edge, lamps and benches between.
			var ring := CityRoads._simplify(CityLayout._closed(Geometry2D.offset_polygon(poly, -3.6)[0] if not Geometry2D.offset_polygon(poly, -3.6).is_empty() else poly), 1.5)
			var t := 0.0
			for e in ring.size() - 1:
				var a: Vector2 = ring[e]
				var b: Vector2 = ring[e + 1]
				var L := a.distance_to(b)
				var d := (b - a) / maxf(L, 0.001)
				while t < L:
					var q := a + d * t
					var slot := int(t / 9.0) % 4
					if slot == 3:
						if free.call(q, 1.0, inner):
							l.props.append(["streetlight", Transform3D(Basis(Vector3.UP, atan2(d.x, d.y)), at.call(q))])
							mark.call(q, 1.2)
					elif slot == 1:
						var bq := q - Vector2(d.y, -d.x) * 1.4
						if free.call(bq, 1.0, inner):
							furniture(l, "bench", at.call(bq), atan2(d.x, d.y) + PI * 0.5)
							mark.call(bq, 1.0)
					elif free.call(q, 1.8, inner):
						l.props.append(["tree", Transform3D(Basis().scaled(Vector3.ONE * rng.randf_range(0.85, 1.15)), at.call(q))])
						mark.call(q, 2.4)
					t += 9.0
				t -= L
			# Clumps of trees inside, about one per 190 m².
			var want := int(area / 190.0)
			var tries := want * 4
			var clump := c
			while want > 0 and tries > 0:
				tries -= 1
				if rng.randf() < 0.25:
					clump = Vector2(rng.randf_range(bb.position.x, bb.end.x), rng.randf_range(bb.position.y, bb.end.y))
				var q := clump + Vector2(rng.randf_range(-9, 9), rng.randf_range(-9, 9))
				if free.call(q, 2.0, inner):
					var s := rng.randf_range(0.8, 1.4)
					l.props.append(["tree", Transform3D(Basis(Vector3.UP, rng.randf() * TAU).scaled(Vector3.ONE * s), at.call(q))])
					mark.call(q, 2.6)
					want -= 1
			parks += 1
	print("OpenGround: %d squares, %d parks dressed, %d buildings on bare squares%s" % [squares, parks, built_on,
		" (mainland)" if l.is_mainland else ""])


## Set-piece blocks (the gasholder, the stadium, the wheel, the container
## yards) are superblocks: the streets route round the piece, and the lot
## packer left most of the land as one bare plaza. Build up what the piece
## doesn't use, like any block: the land minus a 14 m forecourt round the
## piece and 6 m lanes round what already stands, then drop anything that
## still lands on the piece, an existing building or another new one.
## Returns how many buildings were added.
static func _fill_piece_blocks(l: CityLayout, piece_rects: Array, kit_rects: Array) -> int:
	var added := 0
	var quads_all: Array = []
	for b in l.buildings:
		if b.get("kind", "") in ["normal", "landmark", "plain", "frame"]:
			var q := footprint(b)
			if not q.is_empty():
				quads_all.append(q)
	for blk in l.blocks:
		if blk["kind"] != "piece" or CityRoads._area(blk["poly"]) < 20000.0:
			continue
		# The gasholder's superblock (Old Town) only: the stadium, the wheel
		# and the container yards fill their blocks with the piece itself.
		if not Geometry2D.is_point_in_polygon(SetPieces.GASHOLDER_AT, blk["poly"]):
			continue
		var poly: PackedVector2Array = blk["poly"]
		var obst: Array = []      # what the new land must stay clear of
		var hard: Array = []      # what a new building may never touch
		for pr: Rect2 in piece_rects:
			if Geometry2D.is_point_in_polygon(pr.get_center(), poly):
				obst.append(_rq(pr.grow(14.0)))
				hard.append(_rq(pr.grow(8.0)))
		for kr: Rect2 in kit_rects:
			if Geometry2D.is_point_in_polygon(kr.get_center(), poly):
				hard.append(_rq(kr))
		for q: PackedVector2Array in quads_all:
			if Geometry2D.is_point_in_polygon(CityRoads._centroid(q), poly):
				obst.append(Geometry2D.offset_polygon(q, 6.0)[0])
				hard.append(Geometry2D.offset_polygon(q, 3.0)[0])
		var ins := Geometry2D.offset_polygon(poly, -4.0)
		if ins.is_empty():
			continue
		var c0 := CityRoads._centroid(poly)
		var brng := RandomNumberGenerator.new()
		brng.seed = hash(Vector2i(int(c0.x), int(c0.y))) ^ 0x9a5e
		var b0 := l.buildings.size()
		var p0 := l.props.size()
		# A planned grid of lots (34 m cells: ~26 m lots, 8 m lanes between,
		# so the new blocks read as streets of their own), each lot built by
		# the city's normal builder (_make_building: heights, forms, shapes,
		# roofs) where it is clear of the forecourt and what already stands.
		var bb := CityLayout._bbox(ins[0])
		const CELL := 34.0
		var nx := int(bb.size.x / CELL)
		var nz := int(bb.size.y / CELL)
		var ox := bb.position.x + (bb.size.x - nx * CELL) * 0.5
		var oz := bb.position.y + (bb.size.y - nz * CELL) * 0.5
		for gx in nx:
			for gz in nz:
				var w := brng.randf_range(20.0, 27.0)
				var d := brng.randf_range(20.0, 27.0)
				var cx := ox + (gx + 0.5) * CELL + brng.randf_range(-1.5, 1.5)
				var cz := oz + (gz + 0.5) * CELL + brng.randf_range(-1.5, 1.5)
				var r := Rect2(cx - w * 0.5, cz - d * 0.5, w, d)
				var rq := _rq(r)
				var ok := true
				for v in rq:
					if not Geometry2D.is_point_in_polygon(v, ins[0]):
						ok = false
						break
				if ok:
					for oi in obst.size():
						var o: PackedVector2Array = obst[oi]
						if not Geometry2D.intersect_polygons(rq, o).is_empty():
							ok = false
							break
				if ok and l.is_water(Vector3(cx, 0.0, cz)):
					ok = false
				if ok:
					l._make_building(r, blk["district"], brng)
		var keep_b: Array = []
		var kept: Array = []
		var dropped: Array = []
		var i := b0
		while i < l.buildings.size():
			var nb: Dictionary = l.buildings[i]
			var q := footprint(nb)
			var bad := q.is_empty()
			if not bad and nb.get("kind", "") in ["normal", "landmark", "plain", "frame"]:
				var q2: PackedVector2Array = Geometry2D.offset_polygon(q, -0.3)[0]
				for h: PackedVector2Array in hard + kept:
					if not Geometry2D.intersect_polygons(q2, h).is_empty():
						bad = true
						break
				if not bad:
					kept.append(q)
			if bad:
				dropped.append(q)
			else:
				keep_b.append(nb)
			i += 1
		# Roof furniture of a dropped building goes with it (it sits inside its footprint).
		var keep2: Array = []
		for nb in keep_b:
			var q := footprint(nb)
			var on_dropped := false
			if nb.get("kind", "") not in ["normal", "landmark", "plain", "frame"]:
				for dq: PackedVector2Array in dropped:
					if not dq.is_empty() and Geometry2D.is_point_in_polygon(CityRoads._centroid(q), dq):
						on_dropped = true
			if not on_dropped:
				keep2.append(nb)
		l.buildings.resize(b0)
		l.buildings.append_array(keep2)
		var keep_p: Array = []
		for pi in range(p0, l.props.size()):
			var o: Vector3 = (l.props[pi][1] as Transform3D).origin
			var on_dropped := false
			for dq: PackedVector2Array in dropped:
				if not dq.is_empty() and Geometry2D.is_point_in_polygon(Vector2(o.x, o.z), Geometry2D.offset_polygon(dq, 1.0)[0]):
					on_dropped = true
			if not on_dropped:
				keep_p.append(l.props[pi])
		l.props.resize(p0)
		l.props.append_array(keep_p)
		added += kept.size()
	if added > 0:
		print("PieceBlocks: %d buildings round the set pieces" % added)
	return added


static func _rq(r: Rect2) -> PackedVector2Array:
	return PackedVector2Array([r.position, Vector2(r.end.x, r.position.y), r.end, Vector2(r.position.x, r.end.y)])


## A round stone fountain: basin, water, a pedestal and a bowl.
static func fountain(l: CityLayout, p: Vector3) -> void:
	var k := l._kit("fountain_%d_%d" % [int(p.x), int(p.z)])
	var stone := Color(0.62, 0.6, 0.56)
	var ring := func(r: float) -> PackedVector2Array:
		var out := PackedVector2Array()
		for i in 12:
			var a := i * TAU / 12.0
			out.append(Vector2(p.x + cos(a) * r, p.z + sin(a) * r))
		return out
	l._kprism(k, ring.call(5.2), p.y - 0.2, p.y + 0.55, stone)
	l._kprism(k, ring.call(4.7), p.y + 0.55, p.y + 0.6, Color(0.2, 0.36, 0.42))   # the water
	l._kprism(k, ring.call(0.7), p.y + 0.6, p.y + 2.2, stone)
	l._kprism(k, ring.call(1.8), p.y + 2.2, p.y + 2.5, stone)
	l._kprism(k, ring.call(0.35), p.y + 2.5, p.y + 3.4, stone)


## A small street kiosk: a body, a counter hatch and a coloured awning.
static func kiosk(l: CityLayout, p: Vector3, ang: float, rng: RandomNumberGenerator) -> void:
	var k := l._kit("kiosk_%d_%d" % [int(p.x), int(p.z)])
	var cols := [Color(0.72, 0.2, 0.16), Color(0.15, 0.42, 0.36), Color(0.86, 0.6, 0.14), Color(0.2, 0.3, 0.55)]
	var awn: Color = cols[rng.randi() % cols.size()]
	var ax := Vector2(cos(ang), sin(ang))
	var az := Vector2(-ax.y, ax.x)
	var box := func(cx: float, cz: float, hx: float, hz: float) -> PackedVector2Array:
		var c := Vector2(p.x, p.z) + ax * cx + az * cz
		return PackedVector2Array([c - ax * hx - az * hz, c + ax * hx - az * hz, c + ax * hx + az * hz, c - ax * hx + az * hz])
	l._kprism(k, box.call(0, 0, 1.6, 1.3), p.y, p.y + 2.5, Color(0.86, 0.84, 0.78))
	l._kprism(k, box.call(0, 1.32, 1.1, 0.04), p.y + 1.0, p.y + 1.9, Color(0.12, 0.13, 0.15))
	l._kprism(k, box.call(0, 0.3, 1.85, 1.9), p.y + 2.5, p.y + 2.68, awn)


## A building's ground footprint (world polygon of its lowest tier).
static func footprint(b: Dictionary) -> PackedVector2Array:
	var tiers: Array = b["tiers"]
	if tiers.is_empty():
		return PackedVector2Array()
	var t: Array = tiers[0]
	var rot: float = b.get("rot", 0.0)
	var pv: Vector2 = b.get("pivot", Vector2.ZERO)
	var quad := PackedVector2Array()
	for c in [Vector2(t[0], t[1]), Vector2(t[2], t[1]), Vector2(t[2], t[3]), Vector2(t[0], t[3])]:
		quad.append(c if rot == 0.0 else CityLayout.to_world2(c, rot, pv))
	return quad
