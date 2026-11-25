shader_type spatial;
render_mode cull_disabled, ambient_light_disabled, specular_disabled, depth_prepass_alpha;

#define VIEW_ARM
#include "res://character_surface.gdshaderinc"
