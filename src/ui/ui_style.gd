class_name UiStyle
extends RefCounted
## NEVER STOP's look: Outfit (assets/fonts, OFL) on a near-black asphalt ink,
## with the pursuit's two lights – siren red and siren blue – as accents and
## a hot amber for calls to action and score. Typography does the work:
## big tabular numbers, tracked-out caps for labels, very little chrome.

const AMBER := Color("#FFB020")   # primary: buttons, score, chain
const RED := Color("#FF3D47")     # siren red: danger, bust, damage
const BLUE := Color("#3D7DFF")    # siren blue: police, heat
const WHITE := Color("#F4F5F7")
const DIM := Color(0.96, 0.96, 0.97, 0.55)
const INK := Color("#0B0D12")     # asphalt ink: panels, type on amber
const PANEL := Color(0.043, 0.051, 0.07, 0.62)
## Kept for the copied minimap code.
const GOLD := AMBER
const TEAL := BLUE
const WEB := WHITE
const EMBER := RED

static var _fonts := {}


## weight: "semibold", "bold" or "black".
static func font(weight := "bold") -> Font:
	if not _fonts.has(weight):
		var path := "res://assets/fonts/outfit_%s.ttf" % weight
		_fonts[weight] = load(path) if ResourceLoader.exists(path) else ThemeDB.fallback_font
	return _fonts[weight]


## A slanted ink panel with a hairline edge (wide) or a rounded chip.
static func pill(ci: CanvasItem, rect: Rect2, col := PANEL) -> void:
	if rect.size.x < rect.size.y * 1.6:
		var sb := StyleBoxFlat.new()
		sb.bg_color = col
		sb.set_corner_radius_all(int(rect.size.y * 0.3))
		sb.anti_aliasing = true
		ci.draw_style_box(sb, rect)
		return
	var k := minf(rect.size.y * 0.3, 12.0)
	var p := rect.position
	var e := rect.end
	var pts := PackedVector2Array([Vector2(p.x + k, p.y), Vector2(e.x, p.y), Vector2(e.x - k, e.y), Vector2(p.x, e.y)])
	ci.draw_colored_polygon(pts, col)
	pts.append(pts[0])
	ci.draw_polyline(pts, Color(WHITE, 0.08), 1.0, true)


## Draws text with a soft shadow for readability over the 3-D scene.
static func text(ci: CanvasItem, pos: Vector2, s: String, size: int, col := WHITE, weight := "bold",
		align := HORIZONTAL_ALIGNMENT_LEFT, width := -1.0) -> void:
	var f := font(weight)
	ci.draw_string(f, pos + Vector2(0, 2), s, align, width, size, Color(0, 0, 0, 0.45 * col.a))
	ci.draw_string(f, pos, s, align, width, size, col)


static func text_width(s: String, size: int, weight := "bold") -> float:
	return font(weight).get_string_size(s, HORIZONTAL_ALIGNMENT_LEFT, -1, size).x


static func time_str(t: float) -> String:
	var m := int(t) / 60
	var sec := int(t) % 60
	return "%02d:%02d" % [m, sec]


static func thousands(n: int) -> String:
	var s := str(absi(n))
	var out := ""
	while s.length() > 3:
		out = "," + s.substr(s.length() - 3) + out
		s = s.substr(0, s.length() - 3)
	return ("-" if n < 0 else "") + s + out
