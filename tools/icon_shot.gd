extends SceneTree
## Renders the app icon from the game's own models (needs a renderer:
##   xvfb-run godot --rendering-method mobile -s res://tools/icon_shot.gd -- assets/icon_1024.png)
func _initialize() -> void:
	_go.call_deferred()


func _go() -> void:
	var out: String = OS.get_cmdline_user_args()[0] if OS.get_cmdline_user_args().size() > 0 else "assets/icon_1024.png"
	var vp := SubViewport.new()
	vp.size = Vector2i(1024, 1024)
	vp.own_world_3d = true
	vp.msaa_3d = Viewport.MSAA_8X
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(vp)
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.02, 0.022, 0.035)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.25, 0.27, 0.35)
	env.ambient_light_energy = 0.5
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	env.glow_enabled = true
	env.glow_intensity = 0.9
	env.glow_bloom = 0.15
	env.fog_enabled = true
	env.fog_light_color = Color(0.05, 0.05, 0.09)
	env.fog_density = 0.03
	var we := WorldEnvironment.new()
	we.environment = env
	vp.add_child(we)
	var key := DirectionalLight3D.new()
	key.rotation_degrees = Vector3(-35, 150, 0)
	key.light_energy = 0.9
	key.shadow_enabled = true
	vp.add_child(key)
	for l in [[Vector3(-4, 2.5, -2), Color(1.0, 0.12, 0.12), 16.0], [Vector3(4, 2.5, -2), Color(0.15, 0.35, 1.0), 16.0],
			[Vector3(0, 4, 5), Color(1.0, 0.85, 0.6), 4.0]]:
		var o := OmniLight3D.new()
		o.position = l[0]
		o.light_color = l[1]
		o.light_energy = l[2]
		o.omni_range = 12.0
		vp.add_child(o)
	var floor := MeshInstance3D.new()
	var pm := PlaneMesh.new()
	pm.size = Vector2(60, 60)
	floor.mesh = pm
	var fm := StandardMaterial3D.new()
	fm.albedo_color = Color(0.05, 0.05, 0.06)
	fm.roughness = 0.15
	fm.metallic = 0.6
	floor.material_override = fm
	vp.add_child(floor)
	var hero := _car(vp, CarCatalog.spec("halcyon"), Vector3(0.3, 0, 0.8), deg_to_rad(-152))
	hero.spec["paint"] = Color(0.95, 0.55, 0.05)
	(hero.visual as CarVisual).set_paint(Color(0.95, 0.5, 0.04))
	var cop := _car(vp, CarCatalog.police_spec("interceptor"), Vector3(-2.6, 0, -4.6), deg_to_rad(-158))
	(cop.visual as CarVisual).set_siren(true)
	var cop2 := _car(vp, CarCatalog.police_spec("patrol"), Vector3(2.4, 0, -7.5), deg_to_rad(-140))
	(cop2.visual as CarVisual).set_siren(true)
	var cam := Camera3D.new()
	cam.fov = 36.0
	vp.add_child(cam)
	cam.position = Vector3(3.3, 1.05, 6.0)
	cam.look_at(Vector3(-0.5, 0.55, -1.8), Vector3.UP)
	cam.current = true
	for i in 30:
		await process_frame
	await RenderingServer.frame_post_draw
	var img := vp.get_texture().get_image()
	img.save_png(out)
	var small := img.duplicate()
	small.resize(256, 256, Image.INTERPOLATE_LANCZOS)
	small.save_png(out.get_base_dir().path_join("icon.png"))
	print("ICON ", out)
	quit()


func _car(vp: Node, spec: Dictionary, at: Vector3, yaw: float) -> Car:
	var c := Car.new()
	c.setup(spec, "player")
	c.freeze = true
	vp.add_child(c)
	var v := CarVisual.new()
	c.add_child(v)
	v.setup(c)
	c.visual = v
	for i in 4:
		c.wheel_comp_visual[i] = 0.08
	c.position = at
	c.rotation.y = yaw
	return c
