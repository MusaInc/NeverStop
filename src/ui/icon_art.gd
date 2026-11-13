class_name IconArt
extends Control
## The NEVER STOP app icon, drawn in code (tools/make_icon.sh bakes it to
## assets/icon_1024.png): your amber getaway car from behind, racing down a
## road into the red / blue glow of the pursuit ahead. Opaque, full bleed,
## no text (iOS rounds the corners; the subject stays inside the safe circle).

const INK := Color("#0B0D12")
const ROAD := Color("#262a33")


func _draw() -> void:
	var s := size.x
	var k := s / 1024.0
	var P := func(x: float, y: float) -> Vector2: return Vector2(x, y) * k
	# Sky: ink to a dusk navy at the horizon.
	var horizon := 455.0
	var steps := 40
	for i in steps:
		var y0 := horizon * i / steps
		var t := float(i) / steps
		draw_rect(Rect2(P.call(0, y0), P.call(1024, horizon / steps + 1)), INK.lerp(Color("#1a2140"), t * t))
	draw_rect(Rect2(P.call(0, horizon), P.call(1024, 1024 - horizon)), Color("#10131b"))
	# Siren glow on the horizon: red left, blue right (the pursuit ahead).
	for i in 36:
		var u := 1.0 - float(i) / 36.0
		var r := 470.0 * u + 30.0
		var a := 0.022 * (1.0 - u) + 0.004
		draw_circle(P.call(300, horizon), r * k, Color(UiStyle.RED, a))
		draw_circle(P.call(724, horizon), r * k, Color(UiStyle.BLUE, a))
	# Light bar flash at the vanishing point.
	draw_rect(Rect2(P.call(452, horizon - 14), P.call(58, 14)), UiStyle.RED)
	draw_rect(Rect2(P.call(514, horizon - 14), P.call(58, 14)), UiStyle.BLUE)
	for i in 10:
		var g := 1.0 - i / 10.0
		draw_circle(P.call(480, horizon - 7), (12 + i * 9) * k, Color(UiStyle.RED, 0.05 * g))
		draw_circle(P.call(544, horizon - 7), (12 + i * 9) * k, Color(UiStyle.BLUE, 0.05 * g))
	# Road in perspective.
	var vp := Vector2(512, horizon)
	draw_colored_polygon(PackedVector2Array([P.call(498, horizon), P.call(526, horizon), P.call(1300, 1024), P.call(-276, 1024)]), ROAD)
	# Edge lines.
	for side: float in [-1.0, 1.0]:
		var top := Vector2(512 + side * 12, horizon)
		var bot := Vector2(512 + side * 700, 1024)
		var n := Vector2(side * 9, 0)
		draw_colored_polygon(PackedVector2Array([P.call(top.x, top.y), P.call(top.x + side * 2, top.y),
			P.call(bot.x + n.x, bot.y), P.call(bot.x - n.x, bot.y)]), Color(0.9, 0.9, 0.86, 0.75))
	# Amber centre dashes, shrinking into the distance.
	var z := 0.0
	for i in 9:
		var t0 := pow(z, 1.0)
		var t1 := t0 + 0.06 * (1.0 - t0 * 0.6)
		var y0 := lerpf(1024.0, horizon, 1.0 - pow(1.0 - t0, 2.2))
		var y1 := lerpf(1024.0, horizon, 1.0 - pow(1.0 - t1, 2.2))
		var w0 := 22.0 * (1.0 - (1024.0 - y0) / (1024.0 - horizon))
		var w1 := 22.0 * (1.0 - (1024.0 - y1) / (1024.0 - horizon))
		draw_colored_polygon(PackedVector2Array([P.call(512 - w0, y0), P.call(512 + w0, y0), P.call(512 + w1, y1),
			P.call(512 - w1, y1)]), UiStyle.AMBER)
		z = t1 + 0.07 * (1.0 - t1)
	_car(P, k)
	# Speed streaks either side.
	for st in [[-1.0, 600.0, 0.5], [-1.0, 700.0, 0.35], [1.0, 640.0, 0.45], [1.0, 760.0, 0.3]]:
		var sd: float = st[0]
		var y: float = st[1]
		var x0 := 512.0 + sd * 330.0
		draw_line(P.call(x0, y), P.call(x0 + sd * 150.0, y + 30.0), Color(1, 1, 1, float(st[2])), 6.0 * k, true)


func _car(P: Callable, k: float) -> void:
	var amber := UiStyle.AMBER
	var dark := amber.darkened(0.35)
	var cx := 512.0
	# Shadow.
	draw_colored_polygon(_ellipse(P.call(cx, 905), 330 * k, 34 * k), Color(0, 0, 0, 0.55))
	# Tyres.
	for sd: float in [-1.0, 1.0]:
		draw_rect(Rect2(P.call(cx + sd * 238 - 50, 790), P.call(100, 118)), Color("#08090c"))
	# Lower body: wide, low, slightly tapered, rounded shoulders.
	# Wide rear haunches over the wheels.
	var body := PackedVector2Array([P.call(cx - 300, 860), P.call(cx - 322, 770), P.call(cx - 318, 690), P.call(cx - 290, 652),
		P.call(cx - 240, 640), P.call(cx + 240, 640), P.call(cx + 290, 652), P.call(cx + 318, 690), P.call(cx + 322, 770),
		P.call(cx + 300, 860)])
	draw_colored_polygon(body, amber)
	# Cabin + rear window.
	# Low, steeply raked fastback cabin.
	var cabin := PackedVector2Array([P.call(cx - 236, 648), P.call(cx - 150, 548), P.call(cx - 118, 538), P.call(cx + 118, 538),
		P.call(cx + 150, 548), P.call(cx + 236, 648)])
	draw_colored_polygon(cabin, dark)
	var glass := PackedVector2Array([P.call(cx - 204, 638), P.call(cx - 132, 562), P.call(cx + 132, 562), P.call(cx + 204, 638)])
	draw_colored_polygon(glass, Color("#141a2e"))
	# Siren glow reflected in the glass: red / blue streak.
	draw_colored_polygon(PackedVector2Array([P.call(cx - 120, 572), P.call(cx - 50, 572), P.call(cx - 90, 630), P.call(cx - 170, 630)]),
		Color(UiStyle.RED, 0.35))
	draw_colored_polygon(PackedVector2Array([P.call(cx + 40, 572), P.call(cx + 110, 572), P.call(cx + 160, 630), P.call(cx + 80, 630)]),
		Color(UiStyle.BLUE, 0.4))
	# Racing stripes up the boot and over the roof (no taxi ever had these).
	for sd: float in [-1.0, 1.0]:
		var a := cx + sd * 22.0
		var b := cx + sd * 64.0
		draw_rect(Rect2(P.call(minf(a, b), 640), P.call(42, 160)), Color("#15171c"))
		draw_colored_polygon(PackedVector2Array([P.call(a, 648), P.call(b, 648), P.call(cx + sd * 50.0, 538), P.call(cx + sd * 18.0, 538)]),
			Color("#15171c"))
	# Spoiler on stalks.
	for sd: float in [-1.0, 1.0]:
		draw_rect(Rect2(P.call(cx + sd * 200 - 8, 622), P.call(16, 24)), Color("#16181d"))
	draw_rect(Rect2(P.call(cx - 300, 606), P.call(600, 20)), Color("#16181d"))
	# Shoulder highlight.
	draw_rect(Rect2(P.call(cx - 290, 662), P.call(580, 8)), amber.lightened(0.35))
	# Tail lights (glowing bar).
	for i in 8:
		var g := 1.0 - i / 8.0
		draw_rect(Rect2(P.call(cx - 290 - i * 6, 700 - i * 5), P.call(580 + i * 12, 34 + i * 10)), Color(UiStyle.RED, 0.05 * g))
	draw_rect(Rect2(P.call(cx - 290, 700), P.call(580, 34)), Color("#2a0a0d"))
	for sd: float in [-1.0, 1.0]:
		var x0 := cx + sd * 290.0
		var x1 := cx + sd * 150.0
		draw_rect(Rect2(P.call(minf(x0, x1), 704), P.call(absf(x1 - x0), 26)), Color("#ff2d3d"))
	draw_rect(Rect2(P.call(cx - 150, 712), P.call(300, 10)), Color("#ff2d3d", 0.75))
	# Bumper, diffuser, plate, exhausts.
	draw_rect(Rect2(P.call(cx - 300, 800), P.call(600, 60)), Color("#16181d"))
	draw_rect(Rect2(P.call(cx - 62, 752), P.call(124, 36)), Color("#eceef2"))
	for sd: float in [-1.0, 1.0]:
		draw_circle(P.call(cx + sd * 120, 832), 16 * k, Color("#3a3d44"))
		draw_circle(P.call(cx + sd * 120, 832), 9 * k, Color("#ffb347"))


func _ellipse(c: Vector2, rx: float, ry: float) -> PackedVector2Array:
	var pts := PackedVector2Array()
	for i in 32:
		var a := TAU * i / 32.0
		pts.append(c + Vector2(cos(a) * rx, sin(a) * ry))
	return pts
