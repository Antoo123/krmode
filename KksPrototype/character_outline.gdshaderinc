uniform float width = 0.00065;
uniform vec4 ink : source_color = vec4(0.28, 0.20, 0.22, 1.0);
uniform vec4 corrected_ink : source_color = vec4(0.28, 0.20, 0.22, 1.0);
uniform bool previous_render = false;
uniform bool hair_outline = false;
uniform bool clip_outline = false;
uniform float cutoff = 0.5;
uniform float tint_alpha = 1.0;
uniform sampler2D base_map : source_color, hint_default_white, filter_linear_mipmap, repeat_enable;
uniform sampler2D color_mask : hint_default_white, filter_linear_mipmap, repeat_enable;
uniform vec4 base_uv = vec4(1.0, 1.0, 0.0, 0.0);
uniform vec4 mask_uv = vec4(1.0, 1.0, 0.0, 0.0);

void vertex() {
#ifdef STUDIO_VERTEX_CACHE
	studio_vertex(VERTEX_ID, UV, VERTEX, NORMAL);
#endif
	VERTEX += normalize(NORMAL) * width;
}

void fragment() {
	if (!previous_render && clip_outline) {
		float opacity = texture(base_map, UV * base_uv.xy + base_uv.zw).a * tint_alpha;
		if (hair_outline) {
			opacity *= texture(color_mask, UV * mask_uv.xy + mask_uv.zw).a;
		}
		if (opacity < cutoff) {
			discard;
		}
	}
	ALBEDO = previous_render ? ink.rgb : corrected_ink.rgb;
}
