extends RefCounted

const CARD_LEGACY := 0x3253434B
const CARD_LAYERS := 0x3353434B
const CARD_MASK := 0x3453434B
const CARD_SURFACE := 0x3553434B
const CARD_SCALE := 0x3653434B
const CARD_MAGIC := 0x3753434B
const CARD_NATIVE_BIND := 0x3853434B
const CARD_WORKSPACE := 0x3953434B
const MOTION_MAGIC := 0x31414D4B
const SURFACE := preload("res://character_surface.gdshader")
const DECAL := preload("res://character_decal.gdshader")
const OUTLINE := preload("res://character_outline.gdshader")
const CHARACTER_LAYER := 2
const PORTABLE_MARKER := "KKSROOM1"
const CharacterEdit := preload("res://character_edit.gd")
const PropMaterial := preload("res://studio_prop_material.gd")


static func load_actor(path: String, preserve_studio_visibility := false, workspace_textures: Dictionary = {}) -> Node3D:
	var file := FileAccess.open(path, FileAccess.READ)
	if not file:
		return null
	var actor := Node3D.new()
	var skeleton := read_rig(file, path)
	if not skeleton:
		actor.free()
		return null
	var format: int = skeleton.get_meta("kcs_format")
	skeleton.remove_meta("kcs_format")
	var bone_count := skeleton.get_bone_count()
	actor.add_child(skeleton)
	var skin := Skin.new()
	for i in range(bone_count):
		skin.add_bind(i, skeleton.get_bone_global_rest(i).affine_inverse())

	var textures: Dictionary = {}
	var renderer_count := file.get_32()
	if renderer_count == 0 or renderer_count > 256:
		actor.free()
		return null
	for i in range(renderer_count):
		var renderer := read_renderer(file, textures, format, skeleton, workspace_textures)
		if renderer == null:
			actor.free()
			return null
		var renderer_name := String(renderer.name).to_lower()
		if "shadowcaster" in renderer_name:
			renderer.free()
			continue
		if preserve_studio_visibility:
			renderer.set_meta("studio_renderer_index", i)
			renderer.set_meta("studio_renderer_name", String(renderer.name))
		actor.add_child(renderer)
		renderer.skeleton = NodePath("../Skeleton")
		if renderer.skin == null:
			renderer.skin = skin
		renderer.layers = CHARACTER_LAYER
		var slot := CharacterEdit.classify(String(renderer.name), skeleton) if format != CARD_WORKSPACE else ""
		if not slot.is_empty():
			renderer.set_meta("wardrobe_slot", slot)
			if slot == CharacterEdit.HAIR:
				var root := CharacterEdit.part_root(String(renderer.name), skeleton)
				for section in range(CharacterEdit.HAIR_ROOTS.size()):
					if root.begins_with(CharacterEdit.HAIR_ROOTS[section]):
						renderer.set_meta("hair_section", section)
	var animator := AnimationPlayer.new()
	animator.name = "AnimationPlayer"
	actor.add_child(animator)
	animator.add_animation_library("", AnimationLibrary.new())
	if not preserve_studio_visibility:
		CharacterEdit.update_body_details(actor, CharacterEdit.slots(actor))
	return actor


static func read_rig(file: FileAccess, path: String) -> Skeleton3D:
	if path.get_extension().to_lower() == "png" and not seek_portable_payload(file):
		return null
	var format := file.get_32()
	if format not in [CARD_WORKSPACE, CARD_NATIVE_BIND, CARD_MAGIC, CARD_SCALE, CARD_SURFACE, CARD_MASK, CARD_LAYERS, CARD_LEGACY]:
		return null
	var bone_count := file.get_32()
	if bone_count == 0 or bone_count > 4096:
		return null
	var skeleton := Skeleton3D.new()
	skeleton.name = "Skeleton"
	skeleton.set_meta("kcs_format", format)
	for i in range(bone_count):
		var bone := read_text(file).replace(":", "_").replace("/", "_")
		if bone.is_empty() or skeleton.find_bone(bone) >= 0:
			bone = "KKS_%d_%s" % [i, bone]
		var parent := signed(file.get_32(), 32)
		if parent < -1 or parent >= i:
			skeleton.free()
			return null
		var origin := read_vector(file)
		var rotation := read_quaternion(file)
		var scale := read_vector(file)
		if format >= CARD_NATIVE_BIND:
			# Studio collapses hidden branches with zero scale. A bind pose must be invertible.
			for axis in range(3):
				if scale[axis] == 0.0:
					scale[axis] = 0.0001
		skeleton.add_bone(bone)
		if parent >= 0:
			skeleton.set_bone_parent(i, parent)
		skeleton.set_bone_rest(i, Transform3D(Basis(rotation) * Basis.from_scale(scale), origin))
	skeleton.reset_bone_poses()
	return skeleton


static func seek_portable_payload(file: FileAccess) -> bool:
	if file.get_length() < 24 or file.get_buffer(8).hex_encode() != "89504e470d0a1a0a":
		return false
	file.seek_end(-16)
	var size := file.get_64()
	if file.get_buffer(8).get_string_from_ascii() != PORTABLE_MARKER or size < 4 or size > 134217728:
		return false
	var start := file.get_length() - 16 - size
	if start < 8:
		return false
	file.seek(start)
	return true


static func read_renderer(file: FileAccess, textures: Dictionary, format: int, skeleton: Skeleton3D,
		workspace_textures: Dictionary = {}) -> MeshInstance3D:
	var bone_count := skeleton.get_bone_count()
	var mesh_name := read_text(file)
	var count := file.get_32()
	if count == 0 or count > 500000:
		return null
	var vertices := PackedVector3Array()
	var normals := PackedVector3Array()
	var uv := PackedVector2Array()
	var joints := PackedInt32Array()
	var weights := PackedFloat32Array()
	vertices.resize(count)
	normals.resize(count)
	uv.resize(count)
	joints.resize(count * 4)
	weights.resize(count * 4)
	for i in range(count):
		vertices[i] = read_vector(file)
		normals[i] = read_vector(file)
		uv[i] = Vector2(file.get_float(), file.get_float())
		for j in range(4):
			joints[i * 4 + j] = file.get_32()
			if joints[i * 4 + j] < 0 or joints[i * 4 + j] >= bone_count:
				return null
		for j in range(4):
			weights[i * 4 + j] = file.get_float()
	if format == CARD_SURFACE:
		correct_baked_scale(mesh_name, skeleton, vertices, normals, joints, weights)
	var data := []
	data.resize(Mesh.ARRAY_MAX)
	data[Mesh.ARRAY_VERTEX] = vertices
	data[Mesh.ARRAY_NORMAL] = normals
	data[Mesh.ARRAY_TEX_UV] = uv
	data[Mesh.ARRAY_BONES] = joints
	data[Mesh.ARRAY_WEIGHTS] = weights
	var auxiliary := file.get_8() if format >= CARD_MAGIC else 0
	var native_layers := auxiliary != 0
	var flags := 0
	if format == CARD_WORKSPACE:
		flags = _read_workspace_attributes(file, data, auxiliary, count)
	elif native_layers:
		var uv2 := PackedVector2Array()
		var more_uv := PackedFloat32Array()
		var colors := PackedColorArray()
		uv2.resize(count)
		more_uv.resize(count * 4)
		colors.resize(count)
		for i in range(count):
			uv2[i] = Vector2(file.get_float(), file.get_float())
			for j in range(4):
				more_uv[i * 4 + j] = file.get_float()
			colors[i] = Color(file.get_8() / 255.0, 0.0, file.get_8() / 255.0, 1.0)
		data[Mesh.ARRAY_TEX_UV2] = uv2
		data[Mesh.ARRAY_CUSTOM0] = more_uv
		data[Mesh.ARRAY_COLOR] = colors
		flags = Mesh.ARRAY_CUSTOM_RGBA_FLOAT << Mesh.ARRAY_FORMAT_CUSTOM0_SHIFT
	var section_count := file.get_32()
	if section_count > 64:
		return null
	var mesh := ArrayMesh.new()
	for section in range(section_count):
		var material := PropMaterial.read(file, textures, texture_payload.bind(workspace_textures)) if format == CARD_WORKSPACE else (
			read_material(file, textures, format, mesh_name, native_layers))
		var index_count := file.get_32()
		if index_count > 3000000 or index_count % 3 != 0:
			return null
		var triangles := PackedInt32Array()
		triangles.resize(index_count)
		for i in range(index_count):
			triangles[i] = file.get_32()
			if triangles[i] < 0 or triangles[i] >= count:
				return null
		if triangles.is_empty():
			continue
		orient_triangles(triangles, vertices, normals)
		data[Mesh.ARRAY_INDEX] = triangles
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, data, [], {}, flags)
		mesh.surface_set_material(mesh.get_surface_count() - 1, material)
	var instance := MeshInstance3D.new()
	if format >= CARD_NATIVE_BIND:
		var binds := file.get_32()
		if binds > 4096:
			instance.free()
			return null
		if binds > 0:
			var native_skin := Skin.new()
			for i in range(binds):
				var bone := file.get_32()
				if bone >= bone_count:
					instance.free()
					return null
				var basis := Basis(read_vector(file), read_vector(file), read_vector(file))
				native_skin.add_bind(bone, Transform3D(basis, read_vector(file)))
			instance.skin = native_skin
	instance.name = mesh_name.validate_node_name()
	instance.mesh = mesh
	return instance


static func _read_workspace_attributes(file: FileAccess, data: Array, attributes: int, count: int) -> int:
	if attributes & 1:
		var secondary := PackedVector2Array()
		secondary.resize(count)
		for i in range(count):
			secondary[i] = Vector2(file.get_float(), file.get_float())
		data[Mesh.ARRAY_TEX_UV2] = secondary
	var flags := 0
	if attributes & 6:
		var additional := PackedFloat32Array()
		additional.resize(count * 4)
		for layer in range(2):
			if attributes & (2 << layer):
				for i in range(count):
					additional[i * 4 + layer * 2] = file.get_float()
					additional[i * 4 + layer * 2 + 1] = file.get_float()
		data[Mesh.ARRAY_CUSTOM0] = additional
		flags = Mesh.ARRAY_CUSTOM_RGBA_FLOAT << Mesh.ARRAY_FORMAT_CUSTOM0_SHIFT
	if attributes & 8:
		var colors := PackedColorArray()
		colors.resize(count)
		for i in range(count):
			colors[i] = Color8(file.get_8(), file.get_8(), file.get_8(), file.get_8())
		data[Mesh.ARRAY_COLOR] = colors
	return flags


static func correct_baked_scale(mesh_name: String, skeleton: Skeleton3D, vertices: PackedVector3Array,
		normals: PackedVector3Array, joints: PackedInt32Array, weights: PackedFloat32Array) -> void:
	var index := skeleton.find_bone(mesh_name.replace(":", "_").replace("/", "_"))
	if index < 0:
		return
	var rest := skeleton.get_bone_global_rest(index)
	var scale := rest.basis.get_scale()
	if scale.is_equal_approx(Vector3.ONE) or minf(scale.x, minf(scale.y, scale.z)) < 0.0001:
		return
	var skinned := false
	for i in range(joints.size()):
		if weights[i] > 0.0 and joints[i] != index:
			skinned = true
			break
	if not skinned:
		return
	var correction := Transform3D(rest.basis.orthonormalized(), rest.origin) * rest.affine_inverse()
	var normal_basis := correction.basis.inverse().transposed()
	for i in range(vertices.size()):
		vertices[i] = correction * vertices[i]
		normals[i] = (normal_basis * normals[i]).normalized()


static func orient_triangles(triangles: PackedInt32Array, vertices: PackedVector3Array, normals: PackedVector3Array) -> void:
	# ArrayMesh uses clockwise faces. Older card exports can carry the opposite winding after reflecting Z.
	var score := 0
	var stride := 3 * maxi(1, int(triangles.size() / 288.0))
	for i in range(0, triangles.size(), stride):
		var a := triangles[i]
		var b := triangles[i + 1]
		var c := triangles[i + 2]
		var normal := normals[a] + normals[b] + normals[c]
		var facing := (vertices[b] - vertices[a]).cross(vertices[c] - vertices[a]).dot(normal)
		if absf(facing) > 0.000000001:
			score += 1 if facing > 0.0 else -1
	if score <= 0:
		return
	for i in range(0, triangles.size(), 3):
		var next := triangles[i + 1]
		triangles[i + 1] = triangles[i + 2]
		triangles[i + 2] = next


static func read_material(file: FileAccess, textures: Dictionary, format: int, mesh_name: String, native_layers: bool) -> ShaderMaterial:
	var material := ShaderMaterial.new()
	var lower := mesh_name.to_lower()
	var body_surface := lower.begins_with("o_body")
	var body_detail := lower in CharacterEdit.UPPER_BODY_DETAILS or lower in CharacterEdit.LOWER_BODY_DETAILS
	if format == CARD_LEGACY:
		var color := read_color(file)
		var cutout := file.get_8() != 0
		var kind := 0
		if "hair" in lower:
			kind = 2
		elif "face" in lower or "body" in lower:
			kind = 1
		elif "hitomi" in lower or "eyeline" in lower or "noseline" in lower or "mayuge" in lower:
			kind = 3
		material.shader = DECAL if kind == 3 and cutout else SURFACE
		material.set_shader_parameter("surface_kind", kind)
		material.set_shader_parameter("body_surface", kind == 1 and body_surface)
		material.set_shader_parameter("body_detail", kind == 1 and body_detail)
		material.set_shader_parameter("base_tint", color)
		material.set_shader_parameter("opacity_mode", int(cutout))
		material.set_shader_parameter("cutoff", 0.38)
		var texture := read_texture(file, textures)
		if texture:
			material.set_shader_parameter("base_map", texture)
		add_outline(material, kind, 2000, color)
		return material

	var kind := file.get_8()
	if body_surface:
		kind = 1
	var opacity := file.get_8()
	var queue := file.get_32()
	var cutoff := file.get_float()
	var extend := file.get_float()
	var color := read_color(file)
	if opacity == 0 and mesh_name.to_lower().begins_with("o_emblem_"):
		opacity = 2
	material.shader = DECAL if opacity == 2 else SURFACE
	material.set_shader_parameter("surface_kind", kind)
	material.set_shader_parameter("body_surface", kind == 1 and body_surface)
	material.set_shader_parameter("body_detail", kind == 1 and body_detail)
	material.set_shader_parameter("opacity_mode", opacity)
	material.set_shader_parameter("cutoff", cutoff)
	material.set_shader_parameter("shadow_extend", extend)
	material.set_shader_parameter("base_tint", color)
	for name in ["second_tint", "third_tint", "shadow_tint", "gloss_tint", "overlay1_tint", "overlay2_tint", "overlay3_tint"]:
		material.set_shader_parameter(name, read_color(file))
	if opacity == 2:
		material.render_priority = clampi(queue - 2900, -127, 127)
	read_map(material, file, textures, "base_map", "base_uv")
	read_map(material, file, textures, "color_mask", "mask_uv", "use_mask")
	read_map(material, file, textures, "gloss_map", "gloss_uv", "use_gloss")
	for slot in range(1, 4):
		read_map(material, file, textures, "overlay%d_map" % slot, "overlay%d_uv" % slot, "use_overlay%d" % slot)
	if format in [CARD_NATIVE_BIND, CARD_MAGIC, CARD_SCALE, CARD_SURFACE, CARD_MASK]:
		material.set_shader_parameter("body_mask_weights", Vector2(file.get_float(), file.get_float()))
		read_map(material, file, textures, "body_mask", "body_mask_uv", "use_body_mask")
	if format in [CARD_NATIVE_BIND, CARD_MAGIC, CARD_SCALE, CARD_SURFACE]:
		for property in ["normal_strength", "detail_normal_strength", "face_normal_weight", "specular_weight",
				"detail_red_lines", "detail_blue_lines", "wetness"]:
			material.set_shader_parameter(property, file.get_float())
		for slot in ["normal", "detail_normal", "surface_detail", "line", "face_normal", "ramp", "wet_mask", "wet_detail"]:
			read_map(material, file, textures, slot + "_map", slot + "_uv", "use_" + slot)
	if native_layers:
		material.set_shader_parameter("native_skin_layers", true)
		material.set_shader_parameter("skin_layer_parameters", Vector4(file.get_float(), file.get_float(), file.get_float(), file.get_float()))
	if material.get_shader_parameter("use_body_mask") != true:
		add_outline(material, kind, queue, color)
	return material


static func add_outline(material: ShaderMaterial, kind: int, queue: int, tint: Color) -> void:
	if kind == 3 or queue >= 2700 or material.shader == DECAL:
		return
	var outline := ShaderMaterial.new()
	outline.shader = OUTLINE
	outline.set_shader_parameter("ink", Color("#a57b78") if kind == 1 else tint.darkened(0.63).lerp(Color("#59414b"), 0.62))
	outline.set_shader_parameter("width", 0.00062 if kind == 1 else 0.00072)
	material.next_pass = outline


static func read_map(material: ShaderMaterial, file: FileAccess, textures: Dictionary,
		sampler: String, uv: String, enabled: String = "") -> void:
	var texture_id := signed(file.get_32(), 32)
	if texture_id < 0:
		return
	var texture := texture_payload(file, textures, texture_id)
	var transform := read_color(file)
	if texture:
		material.set_shader_parameter(sampler, texture)
		material.set_shader_parameter(uv, Vector4(transform.r, transform.g, transform.b, transform.a))
		if not enabled.is_empty():
			material.set_shader_parameter(enabled, true)


static func read_texture(file: FileAccess, textures: Dictionary) -> Texture2D:
	var texture_id := signed(file.get_32(), 32)
	return texture_payload(file, textures, texture_id) if texture_id >= 0 else null


static func texture_payload(file: FileAccess, textures: Dictionary, texture_id: int, shared: Variant = null) -> Texture2D:
	var size := file.get_32()
	if size > 0:
		var bytes := file.get_buffer(mini(size, 33554432))
		if size > bytes.size():
			file.seek(file.get_position() + size - bytes.size())
		else:
			var digest := ""
			if shared is Dictionary:
				var hashing := HashingContext.new()
				hashing.start(HashingContext.HASH_SHA256)
				hashing.update(bytes)
				digest = hashing.finish().hex_encode()
				if shared.has(digest):
					textures[texture_id] = shared[digest]
					return textures[texture_id]
			var image := Image.new()
			if image.load_png_from_buffer(bytes) == OK:
				image.generate_mipmaps()
				textures[texture_id] = ImageTexture.create_from_image(image)
				if shared is Dictionary:
					shared[digest] = textures[texture_id]
	return textures.get(texture_id)


static func read_color(file: FileAccess) -> Color:
	return Color(file.get_float(), file.get_float(), file.get_float(), file.get_float())


static func animation(path: String, skeleton: Skeleton3D) -> Animation:
	var file := FileAccess.open(path, FileAccess.READ)
	if not file or file.get_32() != MOTION_MAGIC:
		return null
	var clip := Animation.new()
	clip.length = file.get_float()
	clip.loop_mode = Animation.LOOP_LINEAR
	var frames := file.get_32()
	var track_count := file.get_32()
	if frames < 2 or frames > 1801 or track_count > 4096:
		return null
	for i in range(track_count):
		var bone := read_text(file)
		var move := file.get_8() != 0
		var joint := skeleton.find_bone(bone)
		if joint < 0:
			file.seek(file.get_position() + frames * (20 if move else 8))
			continue
		var rest := skeleton.get_bone_rest(joint)
		var neutral := rest.basis.get_rotation_quaternion()
		var rotation := clip.add_track(Animation.TYPE_ROTATION_3D)
		var path_to_bone := NodePath("Skeleton:" + bone)
		clip.track_set_path(rotation, path_to_bone)
		var position := -1
		if move:
			position = clip.add_track(Animation.TYPE_POSITION_3D)
			clip.track_set_path(position, path_to_bone)
		for frame in range(frames):
			var at := clip.length * frame / (frames - 1.0)
			var x := signed(file.get_16(), 16)
			var y := signed(file.get_16(), 16)
			var z := signed(file.get_16(), 16)
			var w := signed(file.get_16(), 16)
			var delta := Quaternion(x, y, z, w).normalized()
			clip.rotation_track_insert_key(rotation, at, (neutral * delta).normalized())
			if move:
				clip.position_track_insert_key(position, at, rest.origin + read_vector(file))
	return clip if clip.get_track_count() > 0 else null


static func read_text(file: FileAccess) -> String:
	var size := file.get_32()
	return file.get_buffer(size).get_string_from_utf8() if size <= 4096 else ""


static func read_vector(file: FileAccess) -> Vector3:
	var x := file.get_float()
	var y := file.get_float()
	var z := file.get_float()
	return Vector3(x, y, z)


static func read_quaternion(file: FileAccess) -> Quaternion:
	var xyz := read_vector(file)
	return Quaternion(xyz.x, xyz.y, xyz.z, file.get_float()).normalized()


static func signed(value: int, bits: int) -> int:
	return value - (1 << bits) if value & (1 << (bits - 1)) else value
