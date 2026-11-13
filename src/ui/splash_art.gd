class_name SplashArt
extends Control
## The NEVER STOP brand card: the logo on asphalt ink, a siren glow either
## side. Baked once to assets/ui/splash.png (tools/make_splash.sh) for the
## boot splash and the iOS launch screen; the loading screen shows the same
## PNG so the hand-over from the OS to the game is seamless.

const BG := Color(0.03, 0.035, 0.05)


func _draw() -> void:
	var s := size
	draw_rect(Rect2(Vector2.ZERO, s), BG)
	# Siren glow: soft red left, blue right, low on the horizon.
	# Kept inside the frame (falls to BG at every edge) so letterboxing on
	# iPad / wide iPhones meets the background colour without a seam.
	var steps := 48
	var c := s * 0.5
	var reach := minf(c.y, s.x * 0.27) * 0.94
	for i in steps:
		var k := 1.0 - float(i) / steps
		var r := reach * (0.1 + 0.9 * k)
		var a := 0.006 * (1.0 - k) + 0.0008
		draw_circle(Vector2(s.x * 0.27, c.y), r, Color(UiStyle.RED, a))
		draw_circle(Vector2(s.x * 0.73, c.y), r, Color(UiStyle.BLUE, a))
	var f := UiStyle.font("black")
	var fs := int(s.y * 0.185)
	var w_never := f.get_string_size("NEVER ", HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
	var w := f.get_string_size("NEVER STOP", HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
	var x := (s.x - w) * 0.5
	var base := s.y * 0.5 + fs * 0.32
	draw_string(f, Vector2(x, base), "NEVER", HORIZONTAL_ALIGNMENT_LEFT, -1, fs, UiStyle.WHITE)
	draw_string(f, Vector2(x + w_never, base), "STOP", HORIZONTAL_ALIGNMENT_LEFT, -1, fs, UiStyle.AMBER)
	# Light bar: red | blue.
	var bar_y := base + fs * 0.16
	var bh := maxf(4.0, s.y * 0.009)
	draw_rect(Rect2(x, bar_y, w * 0.5, bh), UiStyle.RED)
	draw_rect(Rect2(x + w * 0.5, bar_y, w * 0.5, bh), UiStyle.BLUE)
	var sf := UiStyle.font("bold")
	var ss := int(s.y * 0.026)
	var studio := "M U S A   S T U D I O S"
	var sw := sf.get_string_size(studio, HORIZONTAL_ALIGNMENT_LEFT, -1, ss).x
	draw_string(sf, Vector2((s.x - sw) * 0.5, base - fs * 0.86), studio, HORIZONTAL_ALIGNMENT_LEFT, -1, ss,
		Color(UiStyle.WHITE, 0.5))
