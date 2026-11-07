extends Node
## Showroom captures in the real game lighting: parks the given cars in a
## row on the bridge deck and photographs each one from a few angles.
##   tools/lineup.sh [ids] [angles]   (run via the main scene: --lineup=<ids> --lineup-out=<dir>)

var game: Node
var ids: Array = []
var out_dir := ""


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_run.call_deferred()


func _spec(id: String) -> Dictionary:
	if id.begins_with("police_"):
		return CarCatalog.police_spec(id.trim_prefix("police_"))
	if id.begins_with("civ_"):
		var rng := RandomNumberGenerator.new()
		rng.seed = hash(id)
		return CarCatalog.civ_spec(id, rng)
	return CarCatalog.spec(id)


func _run() -> void:
	for i in 20:
		await get_tree().process_frame
	var cars: Array = []
	var x0 := -140.0
	for i in ids.size():
		var id: String = ids[i]
		var s := _spec(id)
		var car := Car.new()
		car.setup(s, "player" if not id.begins_with("police") else "police")
		car.freeze = true
		game.add_child(car)
		var v := CarVisual.new()
		car.add_child(v)
		v.setup(car)
		car.visual = v
		v.enable_headlights()
		if id.begins_with("police"):
			v.set_siren(true)
		for w in 4:
			car.wheel_comp_visual[w] = 0.08
		car.global_transform = Transform3D(Basis(Vector3.UP, PI * 0.5), Vector3(x0 - i * 16.0, CityLayout.BRIDGE_DECK, CityLayout.BRIDGE_Z + 6.0))
		cars.append(car)
	if game.player:
		game.player.global_position = Vector3(x0 + 60, CityLayout.BRIDGE_DECK + 0.5, CityLayout.BRIDGE_Z + 5)
		game.player.freeze = true
	var cam := Camera3D.new()
	cam.fov = 38.0
	game.add_child(cam)
	cam.current = true
	if game.camera:
		game.camera.set_process(false)
		game.camera.set_physics_process(false)
	if game.hud:
		game.hud.visible = false
	for i in cars.size():
		var car: Car = cars[i]
		var sz: Vector3 = car.spec["size"]
		var k := maxf(1.0, sz.z / 4.6)
		var c := car.global_position
		var fwd := -car.global_basis.z
		var right := car.global_basis.x
		if right.z > 0.0:
			right = -right  # look from the deck's far side, not through the girder
		var views := {
			"front": c + (fwd * 5.2 + right * 3.4) * k + Vector3.UP * 1.5 * k,
			"rear": c + (-fwd * 5.4 - right * 3.0) * k + Vector3.UP * 1.7 * k,
			"side": c + (right * 7.5) * minf(k, 1.6) + Vector3.UP * 1.0 * k,
		}
		for vn in views:
			cam.global_position = views[vn]
			cam.look_at(c + Vector3.UP * 0.6 * k, Vector3.UP)
			for f in 6:
				await get_tree().process_frame
			var img := get_viewport().get_texture().get_image()
			img.save_png("%s/%s_%s.png" % [out_dir, ids[i], vn])
			print("LINEUP ", ids[i], " ", vn)
	get_tree().quit()
