uniform vec4 base_tint : source_color = vec4(1.0);
uniform vec4 tint_2 : source_color = vec4(1.0);
uniform vec4 tint_3 : source_color = vec4(1.0);
uniform vec4 emission_tint : source_color = vec4(0.0);
uniform vec4 shadow_tint : source_color = vec4(1.0);
uniform float cutoff = 0.5;
uniform float shadow_extend = 0.48;
uniform float specular_power = 0.5;
uniform float metallic = 0.0;
uniform float smoothness = 0.35;
uniform float normal_strength = 1.0;
uniform vec4 base_uv = vec4(1.0, 1.0, 0.0, 0.0);
uniform vec4 mask_uv = vec4(1.0, 1.0, 0.0, 0.0);
uniform vec4 normal_uv = vec4(1.0, 1.0, 0.0, 0.0);
uniform vec4 emission_uv = vec4(1.0, 1.0, 0.0, 0.0);
uniform vec4 detail_uv = vec4(1.0, 1.0, 0.0, 0.0);
uniform vec2 base_wrap;
uniform vec2 mask_wrap;
uniform vec2 normal_wrap;
uniform vec2 emission_wrap;
uniform vec2 detail_wrap;
#ifdef STUDIO_GOO
uniform float fresnel_scale;
uniform float fresnel_power;
uniform float fresnel_alpha;
uniform float fresnel_bias;
uniform float goo_shade;
uniform float matcap_alpha;
uniform float alpha_red;
uniform float alpha_green;
uniform vec4 matcap_uv = vec4(1.0, 1.0, 0.0, 0.0);
uniform vec4 alpha_mask_uv = vec4(1.0, 1.0, 0.0, 0.0);
uniform vec2 matcap_wrap;
uniform vec2 alpha_mask_wrap;
#endif
varying vec4 mesh_tint;

vec2 prop_uv(vec2 uv, vec4 transform, vec2 wrapping) {
	vec2 p = uv * transform.xy + transform.zw;
	for (int axis = 0; axis < 2; axis++) {
		float w = wrapping[axis];
		if (w == 0.0 && wrapping[1 - axis] != 0.0) {
			p[axis] = fract(p[axis]);
		} else if (w == 2.0) {
			p[axis] = 1.0 - abs(mod(p[axis], 2.0) - 1.0);
		} else if (w == 3.0) {
			p[axis] = clamp(abs(p[axis]), 0.0, 1.0);
		}
	}
	return p;
}

void vertex() {
	mesh_tint = COLOR;
}

void fragment() {
	vec4 texel = vec4(1.0);
	#ifdef MAP_BASE
	texel = texture(base_map, prop_uv(UV, base_uv, base_wrap));
	#endif
	vec3 pigment = base_tint.rgb;
	#ifdef MAP_MASK
	vec3 parts = texture(mask_map, prop_uv(UV, mask_uv, mask_wrap)).rgb;
	parts /= max(1.0, parts.r + parts.g + parts.b);
	pigment = vec3(1.0 - parts.r - parts.g - parts.b) +
		base_tint.rgb * parts.r + tint_2.rgb * parts.g + tint_3.rgb * parts.b;
	#endif
	vec4 color = vec4(texel.rgb * pigment, texel.a * base_tint.a);
	#ifdef STUDIO_GOO
	float facing = clamp(dot(normalize(NORMAL), VIEW), 0.0, 1.0);
	float fresnel = clamp((fresnel_scale * pow(1.0 - facing, fresnel_power) + fresnel_bias) * fresnel_alpha, 0.0, 1.0);
	vec3 cap = vec3(1.0);
	#ifdef MAP_MATCAP
	vec3 reflected = reflect(-VIEW, normalize(NORMAL));
	float projection = max(0.0001, 2.0 * length(reflected + vec3(0.0, 0.0, 1.0)));
	vec2 cap_uv = vec2(reflected.x, -reflected.y) / projection + 0.5;
	cap = texture(matcap_map, prop_uv(cap_uv, matcap_uv, matcap_wrap)).rgb;
	#endif
	color.rgb = clamp(pigment + fresnel - (1.0 - fresnel) * goo_shade + cap * matcap_alpha, vec3(0.0), vec3(1.0));
	color.a = clamp(base_tint.a + fresnel, 0.0, 1.0);
	#ifdef MAP_ALPHA_MASK
	vec2 mask = texture(alpha_mask_map, prop_uv(UV, alpha_mask_uv, alpha_mask_wrap)).rg;
	color.a *= 1.0 - clamp(dot(1.0 - mask, vec2(alpha_red, alpha_green)), 0.0, 1.0);
	#endif
	if (color.a < cutoff) {
		discard;
	}
	#endif
	#ifdef VERTEX_TINT
	color *= mesh_tint;
	#endif
	#ifdef STUDIO_CUTOUT
	if (color.a < cutoff) {
		discard;
	}
	#endif
	#ifdef STUDIO_BLEND
	if (color.a < 0.001) {
		discard;
	}
	ALPHA = color.a;
	#endif
	ALBEDO = color.rgb;
	#ifdef STUDIO_PREMULTIPLY
	PREMUL_ALPHA_FACTOR = color.a;
	#endif
	METALLIC = metallic;
	ROUGHNESS = clamp(1.0 - smoothness, 0.045, 1.0);
	SPECULAR = specular_power;
	EMISSION = emission_tint.rgb;
	#ifdef MAP_EMISSION
	EMISSION *= texture(emission_map, prop_uv(UV, emission_uv, emission_wrap)).rgb;
	#endif
	#ifdef STUDIO_TOON
	EMISSION += color.rgb * mix(shadow_tint.rgb, vec3(1.0), 0.8) * 1.1;
	#endif
	#ifdef MAP_DETAIL
	vec3 detail = texture(detail_map, prop_uv(UV, detail_uv, detail_wrap)).rgb;
	ROUGHNESS = mix(ROUGHNESS, clamp(1.0 - detail.g, 0.045, 1.0), 0.35);
	#endif
	#ifdef MAP_NORMAL
	vec2 n_uv = prop_uv(UV, normal_uv, normal_wrap);
	vec4 n = texture(normal_map, n_uv);
	vec2 slope = (vec2(n.r * n.a, 1.0 - n.g) * 2.0 - 1.0) * normal_strength;
	vec3 dx = dFdx(VERTEX);
	vec3 dy = dFdy(VERTEX);
	vec2 ux = dFdx(n_uv);
	vec2 uy = dFdy(n_uv);
	float determinant = ux.x * uy.y - ux.y * uy.x;
	if (abs(determinant) > 0.00000001) {
		vec3 tangent = (dx * uy.y - dy * ux.y) * sign(determinant);
		vec3 bitangent = (dy * ux.x - dx * uy.x) * sign(determinant);
		tangent -= NORMAL * dot(NORMAL, tangent);
		bitangent -= NORMAL * dot(NORMAL, bitangent);
		if (length(tangent) > 0.000001 && length(bitangent) > 0.000001) {
			NORMAL = normalize(NORMAL + normalize(tangent) * slope.x + normalize(bitangent) * slope.y);
		}
	}
	#endif
}

#ifdef STUDIO_TOON
void light() {
	float diffuse = smoothstep(0.25 - shadow_extend * 0.25, 0.45, dot(NORMAL, LIGHT));
	DIFFUSE_LIGHT += mix(shadow_tint.rgb * 0.04, vec3(0.24), diffuse) * ATTENUATION * LIGHT_COLOR / PI;
	vec3 half_angle = normalize(LIGHT + VIEW);
	float highlight = pow(max(0.0, dot(NORMAL, half_angle)), mix(8.0, 128.0, 1.0 - ROUGHNESS));
	SPECULAR_LIGHT += specular_power * highlight * ATTENUATION * LIGHT_COLOR / PI;
}
#endif
