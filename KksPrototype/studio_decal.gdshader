shader_type spatial;
render_mode cull_disabled, ambient_light_disabled, specular_disabled, depth_draw_never, shadows_disabled;

#define STUDIO_VERTEX_CACHE
#define CHARACTER_BLEND
#include "res://character_surface.gdshaderinc"
