uniform int surface_kind = 0;
uniform int impact_mark_count = 0;
uniform float interaction_blush = 0.0;
uniform vec4 impact_marks[16];
uniform bool body_surface = false;
uniform bool first_person_limb = false;
uniform float skin_exposure = 1.0;
uniform bool body_detail = false;
uniform bool native_skin_layers = false;
uniform vec4 skin_layer_parameters = vec4(0.0, 0.5, 0.0, 0.0);
uniform int opacity_mode = 0;
uniform float cutoff = 0.5;
uniform float shadow_extend = 0.48;
uniform vec4 base_tint : source_color = vec4(1.0);
uniform vec4 second_tint : source_color = vec4(1.0);
uniform vec4 third_tint : source_color = vec4(1.0);
uniform vec4 shadow_tint : source_color = vec4(0.84, 0.85, 0.91, 1.0);
uniform vec4 gloss_tint : source_color = vec4(1.0);
uniform vec4 overlay1_tint : source_color = vec4(0.0);
uniform vec4 overlay2_tint : source_color = vec4(0.0);
uniform vec4 overlay3_tint : source_color = vec4(0.0);

uniform sampler2D base_map : source_color, hint_default_white, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D color_mask : hint_default_black, filter_linear_mipmap, repeat_enable;
uniform sampler2D gloss_map : hint_default_black, filter_linear_mipmap, repeat_enable;
uniform sampler2D overlay1_map : source_color, hint_default_transparent, filter_linear_mipmap, repeat_disable;
uniform sampler2D overlay2_map : source_color, hint_default_transparent, filter_linear_mipmap, repeat_disable;
uniform sampler2D overlay3_map : source_color, hint_default_transparent, filter_linear_mipmap, repeat_disable;
uniform sampler2D body_mask : hint_default_white, filter_linear_mipmap, repeat_enable;
uniform sampler2D bottom_mask : hint_default_white, filter_linear_mipmap, repeat_enable;
uniform sampler2D normal_map : hint_normal, filter_linear_mipmap, repeat_enable;
uniform sampler2D detail_normal_map : hint_normal, filter_linear_mipmap, repeat_enable;
uniform sampler2D surface_detail_map : hint_default_white, filter_linear_mipmap, repeat_enable;
uniform sampler2D line_map : hint_default_white, filter_linear_mipmap, repeat_enable;
uniform sampler2D face_normal_map : hint_default_white, filter_linear_mipmap, repeat_enable;
uniform sampler2D ramp_map : hint_default_white, filter_linear, repeat_disable;
uniform sampler2D wet_mask_map : hint_default_black, filter_linear_mipmap, repeat_enable;
uniform sampler2D wet_detail_map : hint_default_black, filter_linear_mipmap, repeat_enable;

uniform bool use_mask = false;
uniform bool use_gloss = false;
uniform bool use_overlay1 = false;
uniform bool use_overlay2 = false;
uniform bool use_overlay3 = false;
uniform bool use_body_mask = false;
uniform bool use_bottom_mask = false;
uniform bool use_normal = false;
uniform bool use_detail_normal = false;
uniform bool use_surface_detail = false;
uniform bool use_line = false;
uniform bool use_face_normal = false;
uniform bool use_ramp = false;
uniform bool use_wet_mask = false;
uniform bool use_wet_detail = false;
uniform float normal_strength = 1.0;
uniform float detail_normal_strength = 0.4;
uniform float face_normal_weight = 0.0;
uniform float specular_weight = 0.0;
uniform float detail_red_lines = 0.0;
uniform float detail_blue_lines = 0.0;
uniform float wetness = 0.0;
uniform vec2 body_mask_weights = vec2(1.0);
uniform vec4 base_uv = vec4(1.0, 1.0, 0.0, 0.0);
uniform vec4 mask_uv = vec4(1.0, 1.0, 0.0, 0.0);
uniform vec4 gloss_uv = vec4(1.0, 1.0, 0.0, 0.0);
uniform vec4 overlay1_uv = vec4(1.0, 1.0, 0.0, 0.0);
uniform vec4 overlay2_uv = vec4(1.0, 1.0, 0.0, 0.0);
uniform vec4 overlay3_uv = vec4(1.0, 1.0, 0.0, 0.0);
uniform vec4 body_mask_uv = vec4(1.0, 1.0, 0.0, 0.0);
uniform vec4 bottom_mask_uv = vec4(1.0, 1.0, 0.0, 0.0);
uniform vec4 normal_uv = vec4(1.0, 1.0, 0.0, 0.0);
uniform vec4 detail_normal_uv = vec4(1.0, 1.0, 0.0, 0.0);
uniform vec4 surface_detail_uv = vec4(1.0, 1.0, 0.0, 0.0);
uniform vec4 line_uv = vec4(1.0, 1.0, 0.0, 0.0);
uniform vec4 face_normal_uv = vec4(1.0, 1.0, 0.0, 0.0);
uniform vec4 ramp_uv = vec4(1.0, 1.0, 0.0, 0.0);
uniform vec4 wet_mask_uv = vec4(1.0, 1.0, 0.0, 0.0);
uniform vec4 wet_detail_uv = vec4(1.0, 1.0, 0.0, 0.0);
varying float face_fill;
varying float material_sheen;
varying vec4 skin_extra_uv;
varying vec2 skin_layer_gate;
#ifdef VIEW_ARM
varying float arm_root_progress;
varying float hand_weight;
uniform float forearm_opacity = 1.0;
#endif

#ifdef STUDIO_VERTEX_CACHE
#include "res://studio_vertex_cache.gdshaderinc"
uniform sampler2D studio_matcap : filter_linear, repeat_disable;
uniform float studio_matcap_amount = 0.0;
#endif

void vertex() {
#ifdef STUDIO_VERTEX_CACHE
	studio_vertex(VERTEX_ID, UV, VERTEX, NORMAL);
#endif
#ifdef VIEW_ARM
	vec3 world_point = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	arm_root_progress = CUSTOM1.x;
	hand_weight = CUSTOM1.y;
	float root_weight = 1.0 - smoothstep(0.11, 0.27, arm_root_progress);
	vec3 view_point = (VIEW_MATRIX * vec4(world_point, 1.0)).xyz;
	float lower_edge = -max(-view_point.z, 0.06) / PROJECTION_MATRIX[1][1];
	float down = min(0.0, lower_edge * 1.45 - 0.075 - view_point.y);
	vec3 offset = INV_VIEW_MATRIX[1].xyz * (down * root_weight);
	VERTEX += (inverse(MODEL_MATRIX) * vec4(offset, 0.0)).xyz;
#endif
	skin_extra_uv = CUSTOM0;
	skin_layer_gate = COLOR.rb;
}

vec2 mapped_uv(vec2 uv, vec4 transform) {
	return uv * transform.xy + transform.zw;
}

vec3 with_overlay(vec3 base, vec4 overlay, vec4 tint) {
	return mix(base, overlay.rgb * tint.rgb, overlay.a * tint.a);
}

vec2 unpack_unity_normal(vec4 packed) {
	return vec2(packed.r * packed.a, 1.0 - packed.g) * 2.0 - 1.0;
}

vec3 apply_surface_normal(vec3 n, vec3 position, vec2 uv, vec2 offsets) {
	vec3 dx = dFdx(position);
	vec3 dy = dFdy(position);
	vec2 uv_dx = dFdx(uv);
	vec2 uv_dy = dFdy(uv);
	float determinant = uv_dx.x * uv_dy.y - uv_dx.y * uv_dy.x;
	if (abs(determinant) < 0.00000001) {
		return n;
	}
	vec3 tangent = (dx * uv_dy.y - dy * uv_dx.y) * sign(determinant);
	vec3 bitangent = (dy * uv_dx.x - dx * uv_dy.x) * sign(determinant);
	tangent -= n * dot(n, tangent);
	bitangent -= n * dot(n, bitangent);
	if (length(tangent) < 0.000001 || length(bitangent) < 0.000001) {
		return n;
	}
	return normalize(n + normalize(tangent) * offsets.x + normalize(bitangent) * offsets.y);
}

void fragment() {
	vec4 texel = texture(base_map, mapped_uv(UV, base_uv));
	vec3 pigment = base_tint.rgb;
	if (use_mask) {
		vec4 mask = texture(color_mask, mapped_uv(UV, mask_uv));
		if (surface_kind == 2) {
			// The stock hair shaders use a dye map instead of a base color map.
			pigment = mix(pigment, second_tint.rgb, mask.g);
			pigment = mix(pigment, third_tint.rgb, mask.b);
			pigment *= mix(0.91, 1.02, mask.r);
			texel.a *= mask.a;
		} else {
			float weight = max(1.0, mask.r + mask.g + mask.b);
			vec3 parts = vec3(mask.r, mask.g, mask.b) / weight;
			pigment = (1.0 - parts.r - parts.g - parts.b) +
				base_tint.rgb * parts.r + second_tint.rgb * parts.g + third_tint.rgb * parts.b;
		}
	}
	vec3 color = texel.rgb * pigment;
	if (surface_kind == 1 && !body_surface && !body_detail) {
		color = pow(max(color, vec3(0.0)), vec3(0.74)) * 1.04;
	}
	vec3 detail = use_surface_detail ? texture(surface_detail_map, mapped_uv(UV, surface_detail_uv)).rgb : vec3(0.5);
	face_fill = 0.0;
	if (use_face_normal) {
		face_fill = texture(face_normal_map, mapped_uv(UV, face_normal_uv)).g * face_normal_weight;
	}
	material_sheen = specular_weight * (use_surface_detail ? mix(0.25, 1.0, detail.r) : 1.0);
	if (use_normal || use_detail_normal) {
		vec2 normal_delta = vec2(0.0);
		if (use_normal) {
			normal_delta += unpack_unity_normal(texture(normal_map, mapped_uv(UV, normal_uv))) * normal_strength * (body_surface || body_detail ? 0.41 : 0.24);
		}
		if (use_detail_normal) {
			normal_delta += unpack_unity_normal(texture(detail_normal_map, mapped_uv(UV, detail_normal_uv))) * detail_normal_strength * (body_surface || body_detail ? 0.27 : 0.18);
		}
		NORMAL = apply_surface_normal(normalize(NORMAL), VERTEX, UV, normal_delta);
	}
	if (surface_kind == 2) {
		if (use_overlay1 || use_surface_detail) {
			vec3 strands = use_surface_detail ? detail : texture(overlay1_map, mapped_uv(UV, overlay1_uv)).rgb;
			color *= mix(0.9, 1.05, dot(strands, vec3(0.65, 0.2, 0.15)));
		}
		vec3 gloss = use_gloss ? texture(gloss_map, mapped_uv(UV, gloss_uv)).rgb : vec3(0.0);
		float strand_gloss = smoothstep(0.02, 0.40, max(gloss.r, max(gloss.g, gloss.b)));
		float shine = smoothstep(0.73, 0.95, dot(normalize(NORMAL), normalize(vec3(-0.38, 0.27, 0.88))));
		color = mix(color, max(color, gloss_tint.rgb), strand_gloss * 0.72 + shine * 0.055);
	} else if (use_overlay1 && !body_surface) {
		color = with_overlay(color, texture(overlay1_map, mapped_uv(UV, overlay1_uv)), overlay1_tint);
	}
	if (use_overlay1 && native_skin_layers) {
		vec2 layer_uv = mapped_uv(UV2, overlay1_uv);
		vec2 centered = layer_uv - vec2(0.5);
		float falloff = clamp((length(centered) - 0.06) / 0.06, 0.0, 1.0);
		layer_uv += centered * (1.0 - 1.4 * skin_layer_parameters.y) * falloff;
		vec4 patch = texture(overlay1_map, layer_uv);
		vec3 tinted = mix(patch.rgb * overlay1_tint.rgb,
			patch.r * (overlay1_tint.rgb + patch.g * skin_layer_parameters.w * 0.33),
			clamp(skin_layer_parameters.z, 0.0, 1.0));
		color = mix(color, tinted, patch.a * overlay1_tint.a * skin_layer_parameters.x * skin_layer_gate.x);
	}
	if (use_surface_detail && surface_kind != 2) {
		float detail_ink = max(detail.r * detail_red_lines, detail.b * detail_blue_lines);
		color *= 0.98 + 0.06 * detail.g - 0.10 * clamp(detail_ink, 0.0, 1.0);
	}
	if (use_line) {
		vec3 lines = texture(line_map, mapped_uv(UV, line_uv)).rgb;
		color *= 1.0 - 0.35 * max(lines.r, max(lines.g, lines.b));
	}
	if (wetness > 0.0 && use_wet_mask && use_wet_detail) {
		float wet = texture(wet_mask_map, mapped_uv(UV, wet_mask_uv)).r
			* texture(wet_detail_map, mapped_uv(UV, wet_detail_uv)).r * wetness;
		material_sheen += wet * 0.6;
	}
	if (use_overlay2 && (!body_surface || native_skin_layers)) {
		vec2 layer_uv = native_skin_layers ? skin_extra_uv.xy : UV;
		vec4 patch = texture(overlay2_map, mapped_uv(layer_uv, overlay2_uv));
		patch.a *= native_skin_layers ? skin_layer_gate.y : 1.0;
		color = with_overlay(color, patch, overlay2_tint);
	}
	if (use_overlay3 && (!body_surface || native_skin_layers)) {
		vec2 layer_uv = native_skin_layers ? skin_extra_uv.zw : UV;
		color = with_overlay(color, texture(overlay3_map, mapped_uv(layer_uv, overlay3_uv)), overlay3_tint);
	}
	// KKS skin coverage comes from the clothing mask. The skin map's alpha is not a hole in the mesh.
	float opacity = body_surface ? 1.0 : texel.a * base_tint.a;
	if (use_body_mask || use_bottom_mask) {
		vec2 skin_coverage = use_body_mask ? texture(body_mask, mapped_uv(UV, body_mask_uv)).rg : vec2(1.0);
		if (use_bottom_mask) {
			skin_coverage.y = texture(bottom_mask, mapped_uv(UV, bottom_mask_uv)).g;
		}
		vec2 visible = mix(vec2(1.0), skin_coverage, body_mask_weights);
		opacity *= min(visible.x, visible.y);
	}
#if defined(VIEW_ARM)
	ALPHA = opacity * smoothstep(0.012, 0.063, arm_root_progress)
		* mix(forearm_opacity, 1.0, smoothstep(0.12, 0.74, hand_weight));
	if (ALPHA < 0.015) {
		discard;
	}
#elif defined(CHARACTER_BLEND)
	ALPHA = opacity;
	if (opacity < 0.025) {
		discard;
	}
#else
	if (opacity_mode == 1 && opacity < cutoff) {
		discard;
	}
#endif
	if (body_surface || body_detail) {
		// The body base map needs a separate transfer curve from the layered face map.
		color = pow(max(color, vec3(0.0)), vec3(0.86));
	}
	if (skin_exposure < 0.999) {
		float luma = dot(color, vec3(0.2126, 0.7152, 0.0722));
		color = (vec3(luma) + (color - vec3(luma)) * 1.07) * skin_exposure;
	}
	float redness = 0.0;
	for (int i = 0; i < impact_mark_count; i++) {
		vec4 mark = impact_marks[i];
		float distance_to_hit = distance(UV, mark.xy) / max(mark.z, 0.0001);
		float edge = 1.0 - smoothstep(0.35, 1.0, distance_to_hit);
		redness = max(redness, edge * mark.w);
	}
	color = mix(color, vec3(0.78, 0.075, 0.085), redness);
	if (surface_kind == 1 && !body_surface && !body_detail) {
		color = mix(color, color * vec3(1.03, 0.66, 0.70) + vec3(0.09, 0.0, 0.0), interaction_blush);
	}
#ifdef STUDIO_VERTEX_CACHE
	if (studio_matcap_amount > 0.0) {
		vec2 reflected_uv = vec2(NORMAL.x, -NORMAL.y) * 0.5 + 0.5;
		vec3 reflected_color = pow(texture(studio_matcap, reflected_uv).rgb, vec3(1.0 / 2.2));
		color *= mix(vec3(1.0), reflected_color * studio_matcap_amount, studio_matcap_amount);
	}
#endif
	ALBEDO = color;
	float fill = surface_kind == 0 ? 1.02 : (surface_kind == 2 ? 0.93 : 0.94);
	if (surface_kind == 1) {
		fill = body_surface || body_detail ? 0.77 : 0.84;
	}
	vec3 bounce = surface_kind == 1 ? vec3(1.0, 0.98, 0.97) : vec3(0.96, 0.97, 1.0);
	EMISSION = color * mix(shadow_tint.rgb, bounce, surface_kind == 0 ? 0.90 : 0.76) * fill * (first_person_limb ? 0.87 : 1.0);
}

void light() {
	float wrap = dot(normalize(NORMAL), LIGHT);
	float border = mix(0.36, -0.12, shadow_extend);
	float band = smoothstep(border - 0.055, border + 0.052, wrap);
	if (use_ramp) {
		vec3 ramp = texture(ramp_map, mapped_uv(vec2(clamp(wrap * 0.5 + 0.5, 0.0, 1.0), 0.5), ramp_uv)).rgb;
		band = mix(band, dot(ramp, vec3(0.299, 0.587, 0.114)), 0.65);
	}
	band = mix(band, max(band, 0.55), clamp(face_fill, 0.0, 1.0));
	float strength = surface_kind == 1 || surface_kind == 3 ? 0.12 : 0.26;
	vec3 tint = mix(shadow_tint.rgb, vec3(1.0), band);
	float sheen = pow(max(dot(normalize(NORMAL), normalize(VIEW + LIGHT)), 0.0), 22.0) * material_sheen;
	float shape = first_person_limb ? 1.32 : 1.0;
	if (surface_kind == 1) {
		float wrapped = smoothstep(-0.48, 0.88, wrap);
		float soft_band = mix(wrapped, band, 0.29);
		vec3 skin_tint = mix(vec3(0.94, 0.75, 0.72), vec3(1.0, 0.97, 0.94), soft_band);
		float skin_light = 0.075 + soft_band * (body_surface || body_detail ? 0.62 : 0.44);
		DIFFUSE_LIGHT += (skin_tint * skin_light + sheen * 0.17) * LIGHT_COLOR * ATTENUATION / PI;
	} else {
		DIFFUSE_LIGHT += (tint * (0.06 + band * strength * shape) + sheen * 0.14 * shape) * LIGHT_COLOR * ATTENUATION / PI;
	}
}
