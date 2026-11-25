shader_type spatial;
render_mode cull_disabled, ambient_light_disabled, diffuse_lambert, specular_disabled;

uniform sampler2D base_map : source_color, hint_default_white, filter_linear_mipmap;
uniform sampler2D normal_map : hint_normal, filter_linear_mipmap;
uniform sampler2D glow_map : source_color, hint_default_white, filter_linear_mipmap;
uniform sampler2D lightmap : source_color, filter_linear_mipmap, repeat_disable;
uniform sampler2D direction_map : filter_linear_mipmap, repeat_disable;
uniform vec4 base_tint : source_color = vec4(1.0);
uniform vec3 glow_tint : source_color = vec3(0.0);
uniform float normal_strength = 0.0;

void fragment() {
	vec3 surface = texture(base_map, UV).rgb * base_tint.rgb;
	vec4 encoded = texture(lightmap, UV2);
	vec4 direction = texture(direction_map, UV2);
	vec3 axis = (direction.rgb - 0.5) * vec3(1.0, 1.0, -1.0);
	vec3 world_normal = normalize(mat3(INV_VIEW_MATRIX) * NORMAL);
	float directional = clamp((dot(world_normal, axis) + 0.5) / max(direction.a, 0.08), 0.25, 2.0);
	float multiplier = OUTPUT_IS_SRGB ? 5.0 * encoded.a : 34.49 * pow(encoded.a, 2.2);
	vec3 baked = encoded.rgb * multiplier * directional;
	ALBEDO = surface * 0.33;
	vec3 shaded = surface * (0.12 + 0.74 * baked) + texture(glow_map, UV).rgb * glow_tint;
	EMISSION = min(shaded, vec3(0.78)) + 0.19 * (1.0 - exp(-max(shaded - 0.78, vec3(0.0)) / 0.19));
	NORMAL_MAP = texture(normal_map, UV).rgb;
	NORMAL_MAP_DEPTH = normal_strength;
}
