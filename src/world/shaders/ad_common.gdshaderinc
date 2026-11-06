// Shared by ad_screen.gdshader and ad_glow.gdshader: which advert a screen
// shows at a given moment. Every screen runs the same 12-advert rotation
// (ORDER) from its own offset, so the two shaders always agree and the
// placer (AdScreens) can keep neighbouring screens apart: offsets that differ
// by 2 or more (mod 12) never show the same advert at once.
//   UV2.x = kind + 8 * offset   kind: 0 bezel, 1 screen, 2 market ticker,
//                                3 news ticker, 4 steelwork
//   UV2.y = screen aspect (width / height)
//   COLOR.r = phase (0..1 of a slot), COLOR.g = brightness

uniform sampler2D atlas : source_color, filter_linear_mipmap_anisotropic, repeat_disable;
uniform vec4 wide_rect[12];   // atlas rects (normalised)
uniform vec4 tall_rect[12];
uniform float slot_time = 9.0;
uniform float fade_time = 1.1;

// A fixed running order that alternates loud and quiet campaigns.
const int ORDER[12] = {0, 7, 4, 9, 1, 10, 2, 6, 11, 3, 8, 5};

int ad_at(float off, float slot) {
	return ORDER[int(mod(off + slot, 12.0))];
}

vec4 ad_rect(int i, float aspect) {
	return aspect >= 1.0 ? wide_rect[i] : tall_rect[i];
}

// Screen UV -> UV inside the advert's cell: cropped to cover the screen,
// except on very tall strips / very wide bands, where cropping would cut the
// type – there the advert fits across and its plain top/bottom (sides)
// continue to the screen's ends (clamped sampling).
vec2 ad_cover(vec2 uv, float aspect) {
	float cell = aspect >= 1.0 ? 2.0 : 0.5;
	if (aspect > cell) {
		if (aspect > 4.2) {
			uv.x = 0.5 + (uv.x - 0.5) * aspect / cell;  // fit the height
		} else {
			uv.y = 0.5 + (uv.y - 0.5) * cell / aspect;
		}
	} else {
		if (aspect < 0.34) {
			uv.y = 0.5 + (uv.y - 0.5) * cell / aspect;  // fit the width
		} else {
			uv.x = 0.5 + (uv.x - 0.5) * aspect / cell;
		}
	}
	return uv;
}
