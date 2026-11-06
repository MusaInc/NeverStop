class_name UiStyle
extends RefCounted
## Shared HUD / controls / menu look: Outfit (assets/fonts, OFL) and the
## brand palette (docs/BRAND.md). Fonts fall back to the engine font if the
## files are missing.

const GOLD := Color("#FFC93C")   # Signal Gold: primary, calls to action
const EMBER := Color("#FF4D3D")  # hero suit, warnings
const TEAL := Color("#5CF2D0")   # Web Teal: tokens, highlights
const WEB := Color("#F7F3EA")    # Web White: text, the web line
const DUSK := Color("#43286F")   # panels, sky
const INK := Color("#110D26")    # Night Ink: type on gold, silhouettes
const PANEL := Color(0.067, 0.051, 0.149, 0.55)

static var _fonts := {}


## weight: "semibold", "bold" or "black".
static func font(weight := "bold") -> Font:
	if not _fonts.has(weight):
		var path := "res://assets/fonts/outfit_%s.ttf" % weight
		_fonts[weight] = load(path) if ResourceLoader.exists(path) else ThemeDB.fallback_font
	return _fonts[weight]


## The HUD's one panel shape: a slanted Night Ink tag with a hairline edge
## (wide panels), or a rounded chip (small/square ones). Near-black panel
## colours are drawn in Night Ink, so every panel shares one tint.
static func pill(ci: CanvasItem, rect: Rect2, col := PANEL) -> void:
	if col.r < 0.12 and col.g < 0.12 and col.b < 0.12:
		col = Color(INK, maxf(col.a, 0.42))
	if rect.size.x < rect.size.y * 1.6:
		var sb := StyleBoxFlat.new()
		sb.bg_color = col
		sb.set_corner_radius_all(int(rect.size.y * 0.3))
		sb.anti_aliasing = true
		ci.draw_style_box(sb, rect)
		return
	var k := minf(rect.size.y * 0.24, 10.0)  # slant
	var p := rect.position
	var e := rect.end
	var pts := PackedVector2Array([Vector2(p.x + k, p.y), Vector2(e.x, p.y), Vector2(e.x - k, e.y), Vector2(p.x, e.y)])
	ci.draw_colored_polygon(pts, col)
	if col.a < 0.7 and rect.size.y > 14.0:
		pts.append(pts[0])
		ci.draw_polyline(pts, Color(WEB, 0.14), 1.5, true)
