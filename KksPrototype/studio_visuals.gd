extends RefCounted

const MAGIC := 0x3156534b
const SKIN_EFFECTS := 0x314d534b
const ROW_VERTICES := 256
const TEXEL_PAIR_BYTES := 16
const Card := preload("res://card_model.gd")
const SURFACE := preload("res://studio_surface.gdshader")
const DECAL := preload("res://studio_decal.gdshader")
const OUTLINE := preload("res://studio_outline.gdshader")


class Track:
	var mesh: MeshInstance3D
	var visible_at: PackedByteArray
	var materials: Array[ShaderMaterial]


class SkinEffect:
	var materials: Array[ShaderMaterial]
	var clock := PackedVector3Array()


var tracks: Array[Track]
var effects: Array[SkinEffect]
var frame_scale := 1.0


static func load_cache(path: String, actor: Node3D, motion_frames: int, reflection_scale: float) -> RefCounted:
	var compressed := FileAccess.get_file_as_bytes(path)
	var data := StreamPeerBuffer.new()
	data.data_array = compressed.decompress_dynamic(384 * 1024 * 1024, FileAccess.COMPRESSION_GZIP)
	if data.get_available_bytes() < 12 or data.get_u32() != MAGIC:
		return null
	var frames := data.get_u32()
	if frames < 1 or frames > motion_frames:
		return null
	var count := data.get_u32()
	var meshes := {}
	for node in actor.get_children():
		if node is MeshInstance3D and node.has_meta("studio_renderer_index"):
			meshes[node.get_meta("studio_renderer_index")] = node
	if count > meshes.size():
		return null
	var visual := new()
	visual.frame_scale = float(frames - 1) / maxi(motion_frames - 1, 1)
	var tracked_meshes := {}
	for index in range(count):
		if data.get_available_bytes() < 12 + frames:
			return null
		var mesh_index := data.get_u32()
		var vertices := data.get_u32()
		var rows := data.get_u32()
		var mesh: MeshInstance3D = meshes.get(mesh_index)
		if not mesh or mesh.mesh.get_surface_count() == 0 or mesh.mesh.surface_get_array_len(0) != vertices:
			return null
		if rows != ceili(float(vertices) / ROW_VERTICES) or rows * frames > 8192:
			return null
		meshes.erase(mesh_index)
		var flags: PackedByteArray = data.get_data(frames)[1]
		var size := rows * frames * ROW_VERTICES * TEXEL_PAIR_BYTES
		if data.get_available_bytes() < size:
			return null
		var pixels: PackedByteArray = data.get_data(size)[1]
		var atlas := ImageTexture.create_from_image(Image.create_from_data(ROW_VERTICES * 2, rows * frames, false, Image.FORMAT_RGBAH, pixels))
		var track := Track.new()
		track.mesh = mesh
		track.visible_at = flags
		if mesh.skin:
			mesh.set_meta("studio_source_skin", mesh.skin)
		mesh.skeleton = NodePath()
		mesh.skin = null
		mesh.extra_cull_margin = 2.0
		for surface in range(mesh.mesh.get_surface_count()):
			var source: ShaderMaterial = mesh.mesh.surface_get_material(surface)
			var replacement := _material(source, DECAL if source.shader == Card.DECAL else SURFACE, atlas, rows, frames)
			track.materials.append(replacement)
			if source.next_pass is ShaderMaterial:
				var outline := _material(source.next_pass, OUTLINE, atlas, rows, frames)
				replacement.next_pass = outline
				track.materials.append(outline)
			mesh.set_surface_override_material(surface, replacement)
		visual.tracks.append(track)
		tracked_meshes[mesh_index] = mesh
	if data.get_available_bytes() > 0 and not visual._read_effects(data, tracked_meshes, frames, reflection_scale):
		return null
	return visual if data.get_available_bytes() == 0 else null


func _read_effects(data: StreamPeerBuffer, meshes: Dictionary, frames: int, reflection_scale: float) -> bool:
	if data.get_available_bytes() < 8 or data.get_u32() != SKIN_EFFECTS:
		return false
	var count := data.get_u32()
	var textures := {}
	for index in range(count):
		if data.get_available_bytes() < 28 + frames * 12:
			return false
		var mesh: MeshInstance3D = meshes.get(data.get_u32())
		var surface := data.get_u32()
		if not mesh or surface >= mesh.mesh.get_surface_count():
			return false
		var material: ShaderMaterial = mesh.get_surface_override_material(surface)
		var multiplier := data.get_float()
		var bias := data.get_float()
		var reflect_amount := data.get_float()
		var effect := SkinEffect.new()
		effect.materials.append(material)
		if material.next_pass is ShaderMaterial:
			effect.materials.append(material.next_pass)
		for frame in range(frames):
			effect.clock.append(Vector3(data.get_float(), data.get_float(), data.get_float()))
		var displacement := _read_map(data, textures)
		var reflection := _read_map(data, textures)
		if displacement.has("texture"):
			for target: ShaderMaterial in effect.materials:
				target.set_shader_parameter("studio_displacement", displacement.texture)
				target.set_shader_parameter("studio_displacement_uv", displacement.uv)
				target.set_shader_parameter("studio_displacement_scale", Vector2(multiplier, bias))
				target.set_shader_parameter("studio_use_displacement", true)
		if reflection.has("texture"):
			material.set_shader_parameter("studio_matcap", reflection.texture)
			material.set_shader_parameter("studio_matcap_amount", reflect_amount * reflection_scale)
		effects.append(effect)
	return true


func _read_map(data: StreamPeerBuffer, textures: Dictionary) -> Dictionary:
	if data.get_available_bytes() < 4:
		return {}
	var id := data.get_32()
	if id < 0 or data.get_available_bytes() < 20:
		return {}
	var size := data.get_u32()
	if size > 16 * 1024 * 1024 or data.get_available_bytes() < size + 16:
		data.seek(data.get_size())
		return {}
	if size > 0:
		var image := Image.new()
		if image.load_png_from_buffer(data.get_data(size)[1]) == OK:
			textures[id] = ImageTexture.create_from_image(image)
	var uv := Vector4(data.get_float(), data.get_float(), data.get_float(), data.get_float())
	return {"texture": textures[id], "uv": uv} if textures.has(id) else {}


static func _material(source: ShaderMaterial, shader: Shader, atlas: Texture2D, rows: int, frames: int) -> ShaderMaterial:
	var material := ShaderMaterial.new()
	material.shader = shader
	material.render_priority = source.render_priority
	for uniform in source.shader.get_shader_uniform_list():
		material.set_shader_parameter(uniform.name, source.get_shader_parameter(uniform.name))
	material.set_shader_parameter("studio_vertices", atlas)
	material.set_shader_parameter("studio_rows", rows)
	material.set_shader_parameter("studio_last_frame", frames - 1)
	return material


func seek(frame: float) -> void:
	frame *= frame_scale
	var nearest := roundi(frame)
	for track: Track in tracks:
		track.mesh.visible = track.visible_at[nearest] != 0
		if track.mesh.visible:
			for material: ShaderMaterial in track.materials:
				material.set_shader_parameter("studio_sample", frame)
	for effect: SkinEffect in effects:
		var first := floori(frame)
		var following := mini(first + 1, effect.clock.size() - 1)
		var value := effect.clock[first].lerp(effect.clock[following], frame - first)
		for material: ShaderMaterial in effect.materials:
			material.set_shader_parameter("studio_clock", value)
