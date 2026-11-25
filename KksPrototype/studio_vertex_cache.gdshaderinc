uniform sampler2D studio_vertices : filter_nearest, repeat_disable;
uniform int studio_rows;
uniform int studio_last_frame;
uniform float studio_sample;
uniform bool studio_use_displacement = false;
uniform sampler2D studio_displacement : filter_linear, repeat_enable;
uniform vec4 studio_displacement_uv = vec4(1.0, 1.0, 0.0, 0.0);
uniform vec2 studio_displacement_scale = vec2(0.0);
uniform vec3 studio_clock = vec3(0.0, 0.0, 1.0);

void studio_vertex(int vertex, vec2 uv, inout vec3 position, inout vec3 normal) {
	int first = min(int(studio_sample), studio_last_frame - 1);
	float weight = studio_sample - float(first);
	ivec2 pair = ivec2((vertex % 256) * 2, vertex / 256 + first * studio_rows);
	ivec2 next_pair = pair + ivec2(0, studio_rows);
	position = mix(texelFetch(studio_vertices, pair, 0).xyz, texelFetch(studio_vertices, next_pair, 0).xyz, weight);
	pair.x += 1;
	next_pair.x += 1;
	normal = normalize(mix(texelFetch(studio_vertices, pair, 0).xyz, texelFetch(studio_vertices, next_pair, 0).xyz, weight));
	if (studio_use_displacement) {
		vec2 point = uv * studio_displacement_uv.xy + studio_displacement_uv.zw + studio_clock.xy;
		vec4 height = textureLod(studio_displacement, point, 0.0);
		float centered = 2.0 * pow(height.r, 1.0 / 2.2) - 1.0;
		float strength = 0.01 * studio_displacement_scale.x * studio_clock.z;
		position += normal * strength * (centered * height.a + studio_displacement_scale.y);
	}
}
