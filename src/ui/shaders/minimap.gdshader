// Minimap disc: samples the baked city map around the hero, rotated so the
// camera's forward is up, with a soft edge, a thin rim and a gentle vignette.
shader_type canvas_item;

uniform sampler2D map : filter_linear_mipmap, repeat_disable;
uniform vec2 origin = vec2(0.0);      // world x/z of the texture's top-left
uniform vec2 extent = vec2(1.0);      // world size the texture covers
uniform vec2 center = vec2(0.0);      // hero x/z
uniform vec2 forward = vec2(0.0, -1.0);
uniform float radius_m = 100.0;
uniform float opacity = 0.88;

void fragment() {
	vec2 p = UV * 2.0 - 1.0;            // -1..1, y down
	float r = length(p);
	vec2 rgt = vec2(-forward.y, forward.x);
	vec2 w = center + (rgt * p.x - forward * p.y) * radius_m;
	vec2 uv = (w - origin) / extent;
	vec3 c = texture(map, uv).rgb;
	if (uv.x < 0.0 || uv.y < 0.0 || uv.x > 1.0 || uv.y > 1.0) {
		c = vec3(0.13, 0.22, 0.3);
	}
	// Slight vignette toward the rim keeps the centre (the hero) prominent.
	c *= mix(1.0, 0.72, smoothstep(0.55, 1.0, r));
	float px = fwidth(r);
	float disc = 1.0 - smoothstep(1.0 - px * 1.5, 1.0, r);
	float rim = smoothstep(0.93 - px, 0.93, r) * (1.0 - smoothstep(0.985 - px, 0.985, r));
	c = mix(c, vec3(0.96, 0.95, 0.92), rim * 0.55);
	COLOR = vec4(c, disc * opacity);
}
