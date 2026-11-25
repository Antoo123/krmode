shader_type canvas_item;
render_mode unshaded;

uniform sampler2D scene_image : hint_screen_texture, filter_nearest, repeat_disable;
uniform sampler2D color_grade : filter_linear, repeat_disable;

void fragment() {
	vec3 source = clamp(texture(scene_image, SCREEN_UV).rgb, vec3(0.0), vec3(1.0));
	vec3 cell = source * 31.0;
	float slice = floor(cell.b);
	vec2 first = vec2((32.0 * slice + cell.r + 0.5) / 1024.0, (31.5 - cell.g) / 32.0);
	vec2 second = vec2(first.x + 1.0 / 32.0, first.y);
	COLOR = vec4(mix(texture(color_grade, first).rgb, texture(color_grade, second).rgb, fract(cell.b)), 1.0);
}
