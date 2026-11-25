extends RefCounted

const CHANNELS := ["base_tint", "tint_2", "tint_3", "emission_tint", "cutoff", "base_uv"]
const MAPS := ["base", "mask", "normal", "emission", "detail", "matcap", "alpha_mask"]
const SOURCE := preload("res://studio_prop_surface.gdshaderinc")
static var shaders: Dictionary = {}


static func read(file: FileAccess, textures: Dictionary, read_texture: Callable) -> ShaderMaterial:
	var source := file.get_buffer(file.get_32()).get_string_from_utf8()
	var queue := file.get_32()
	var blend := file.get_8()
	var cull := file.get_8()
	var flags := file.get_8()
	var material := ShaderMaterial.new()
	var values := {}
	for channel: String in CHANNELS:
		var value := _read_channels(file)
		match channel:
			"cutoff":
				values[channel] = value.r
			"base_uv":
				values[channel] = Vector4(value.r, value.g, value.b, value.a)
			_:
				values[channel] = value
	values["metallic"] = file.get_float()
	values["smoothness"] = file.get_float()
	values["normal_strength"] = file.get_float()
	values["shadow_tint"] = _read_channels(file)
	values["shadow_extend"] = file.get_float()
	values["specular_power"] = file.get_float()
	var declarations := ""
	var defines := ""
	if flags & 16:
		for parameter: String in ["fresnel_scale", "fresnel_power", "fresnel_alpha", "fresnel_bias",
				"goo_shade", "matcap_alpha", "alpha_red", "alpha_green"]:
			values[parameter] = file.get_float()
		defines += "#define STUDIO_GOO\n"
	for slot: String in MAPS:
		var filter := file.get_8()
		var wrap := Vector2i(file.get_8(), file.get_8())
		var index := file.get_32()
		if index == 0xffffffff:
			continue
		var texture: Texture2D = read_texture.call(file, textures, index)
		var transform := _read_channels(file)
		if not texture:
			continue
		var sampling: String = ["filter_nearest", "filter_linear", "filter_linear_mipmap"][mini(filter, 2)]
		var color := ", source_color" if slot in ["base", "emission", "matcap"] else ""
		var repeat := "repeat_enable" if wrap == Vector2i.ZERO else "repeat_disable"
		declarations += "uniform sampler2D %s_map : %s, %s%s;\n" % [slot, sampling, repeat, color]
		defines += "#define MAP_%s\n" % slot.to_upper()
		values[slot + "_map"] = texture
		values[slot + "_wrap"] = Vector2(wrap)
		if slot != "base":
			values[slot + "_uv"] = Vector4(transform.r, transform.g, transform.b, transform.a)
	if flags & 4:
		defines += "#define VERTEX_TINT\n"
	if flags & 8 and not flags & 2:
		defines += "#define STUDIO_TOON\n"
	material.shader = _shader(blend, cull, flags, declarations, defines)
	for property: String in values:
		material.set_shader_parameter(property, values[property])
	material.set_meta("studio_prop_blend", blend)
	material.set_meta("studio_prop_shader", source)
	material.set_meta("studio_prop_queue", queue)
	material.set_meta("studio_prop_variant", [cull, flags, declarations, defines])
	material.render_priority = clampi(queue - 3000, -127, 127)
	return material


static func enable_animated_alpha(material: ShaderMaterial) -> void:
	if material.get_meta("studio_prop_blend", 0) != 0:
		return
	var variant: Array = material.get_meta("studio_prop_variant")
	material.shader = _shader(2, variant[0], variant[1], variant[2], variant[3])


static func _read_channels(file: FileAccess) -> Color:
	return Color(file.get_float(), file.get_float(), file.get_float(), file.get_float())


static func _shader(blend: int, cull: int, flags: int, declarations: String, defines: String) -> Shader:
	var modes := PackedStringArray([["cull_disabled", "cull_front", "cull_back"][clampi(cull, 0, 2)]])
	if flags & 2:
		modes.append("unshaded")
	elif flags & 8:
		modes.append("ambient_light_disabled")
	if flags & 32:
		modes.append("depth_test_disabled")
	if blend >= 2:
		modes.append(["blend_mix", "blend_add", "blend_sub", "blend_mul", "blend_premul_alpha"][clampi(blend - 2, 0, 4)])
		modes.append("depth_draw_always" if flags & 1 else "depth_draw_never")
		modes.append("shadows_disabled")
		defines += "#define STUDIO_BLEND\n"
		if blend == 6:
			defines += "#define STUDIO_PREMULTIPLY\n"
	elif blend == 1:
		defines += "#define STUDIO_CUTOUT\n"
	if blend < 2 and not flags & 1:
		modes.append("depth_draw_never")
	var code := "shader_type spatial;\nrender_mode " + ", ".join(modes) + ";\n"
	code += declarations + defines + SOURCE.code
	if not shaders.has(code):
		var shader := Shader.new()
		shader.code = code
		shaders[code] = shader
	return shaders[code]
