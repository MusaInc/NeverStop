shader_type canvas_item;
// GlassSheet (Musa shared foundation; from WorldState's glass.gdshader):
// the screen behind, blurred via the mip chain, a touch more saturated,
// under a tint. The panel's style
// box is only the shape (its alpha = coverage, rounded + anti-aliased).

uniform sampler2D scr : hint_screen_texture, filter_linear_mipmap, repeat_disable;
uniform vec4 tint : source_color = vec4(0.06, 0.06, 0.09, 0.5);
uniform float blur = 3.4;
uniform float sat = 1.35;

void fragment() {
	float cov = COLOR.a;
	vec3 b = textureLod(scr, SCREEN_UV, blur).rgb;
	float l = dot(b, vec3(0.299, 0.587, 0.114));
	b = mix(vec3(l), b, sat);
	vec3 c = mix(b, tint.rgb, tint.a);
	COLOR = vec4(c, cov);
}
