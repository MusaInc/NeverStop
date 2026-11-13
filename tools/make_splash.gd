extends SceneTree
## Bakes the brand art: assets/ui/splash.png (SplashArt, 1920x1080: boot
## splash, iOS launch screen, loading screen) and assets/icon_1024.png
## (IconArt: the app icon).  tools/make_splash.sh


func _init() -> void:
	await _bake(SplashArt.new(), Vector2i(1920, 1080), "res://assets/ui/splash.png")
	await _bake(IconArt.new(), Vector2i(1024, 1024), "res://assets/icon_1024.png")
	quit()


func _bake(art: Control, sz: Vector2i, path: String) -> void:
	var vp := SubViewport.new()
	vp.size = sz
	vp.transparent_bg = false
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	art.size = Vector2(vp.size)
	vp.add_child(art)
	root.add_child(vp)
	for i in 4:
		await process_frame
	await RenderingServer.frame_post_draw
	var img := vp.get_texture().get_image()
	img.convert(Image.FORMAT_RGB8)
	var out := ProjectSettings.globalize_path(path)
	img.save_png(out)
	print("SPLASH %s %dx%d" % [out, img.get_width(), img.get_height()])
	if path.ends_with("icon_1024.png"):
		# Small copy for the web build's PWA icons.
		var small := img.duplicate() as Image
		small.resize(256, 256, Image.INTERPOLATE_LANCZOS)
		small.save_png(ProjectSettings.globalize_path("res://assets/icon.png"))
	vp.queue_free()
