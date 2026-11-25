shader_type spatial;
render_mode unshaded, cull_front, shadows_disabled;

#include "res://studio_vertex_cache.gdshaderinc"

uniform float width = 0.00065;
uniform vec4 ink : source_color = vec4(0.28, 0.20, 0.22, 1.0);

void vertex() {
	studio_vertex(VERTEX_ID, UV, VERTEX, NORMAL);
	VERTEX += NORMAL * width;
}

void fragment() {
	ALBEDO = ink.rgb;
}
