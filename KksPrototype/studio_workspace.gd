extends Node3D

const Card := preload("res://card_model.gd")
const PropMaterial := preload("res://studio_prop_material.gd")
const KWP1 := 0x3150574b
const KWP2 := 0x3250574b


class PoseTrack:
	var joint: int
	var keys := PackedInt32Array()
	var position := PackedVector3Array()
	var rotation: Array[Quaternion] = []
	var scale := PackedVector3Array()

	func evaluate(frame: float) -> Array:
		var i := maxi(0, keys.bsearch(frame, false) - 1)
		var next := mini(i + 1, keys.size() - 1)
		var blend := clampf((frame - keys[i]) / (keys[next] - keys[i]), 0.0, 1.0) if i != next else 0.0
		return [position[i].lerp(position[next], blend), rotation[i].slerp(rotation[next], blend),
			scale[i].lerp(scale[next], blend)]


class TintTrack:
	var material: ShaderMaterial
	var parameter: String
	var keys := PackedInt32Array()
	var colors := PackedColorArray()

	func seek(frame: float) -> void:
		var i := maxi(0, keys.bsearch(frame, false) - 1)
		var next := mini(i + 1, keys.size() - 1)
		var blend := clampf((frame - keys[i]) / (keys[next] - keys[i]), 0.0, 1.0) if i != next else 0.0
		var value := colors[i].lerp(colors[next], blend)
		match parameter:
			"cutoff":
				material.set_shader_parameter(parameter, value.r)
			"base_uv":
				material.set_shader_parameter(parameter, Vector4(value.r, value.g, value.b, value.a))
			_:
				material.set_shader_parameter(parameter, value)


class Item:
	var key: int
	var node: Node3D
	var rig: Skeleton3D
	var anchor: int
	var bone: String
	var bone_index: int
	var axes: int
	var anchor_states := PackedInt32Array()
	var poses: Array[PoseTrack] = []
	var meshes: Array[MeshInstance3D] = []
	var visibility: Array[PackedInt32Array] = []
	var tints: Array[TintTrack] = []
	var authored := Transform3D.IDENTITY
	var world_pose := Transform3D.IDENTITY
	var visible := false
	var override_hidden := false
	var binding_warning := ""


var entries: Array = []
var warnings := PackedStringArray()
var items := {}
var animated: Array[Item] = []
var anchored: Array[Item] = []
var frames := 0
var duration := 0.0
var active_rebind := false
var body_tracks := {}
var models := {}
var legacy_rows := {}


static func load_workspace(folder: String) -> Node3D:
	var path := folder.path_join("workspace.json")
	if not FileAccess.file_exists(path):
		return null
	var data: Variant = JSON.parse_string(FileAccess.get_file_as_string(path).trim_prefix("\ufeff"))
	if not data is Dictionary or int(data.get("version", 0)) != 1 or int(data.get("frames", 0)) < 1:
		return null
	var result := new()
	result.name = "StudioWorkspace"
	result.entries = data.get("entries", [])
	result.frames = int(data.frames)
	result.duration = float(data.get("duration", 0.0))
	result.warnings = PackedStringArray(data.get("warnings", []))
	var shared_textures := {}
	for row: Dictionary in result.entries:
		if not String(row.get("track", "")).is_empty():
			result._load_item(folder, row, shared_textures)
		result._load_body_tracks(row)
		if not row.get("legacyRendererNames", []).is_empty():
			result.legacy_rows[int(row.key)] = row
	result._order_prop_materials()
	result.seek(0.0, {})
	result.models.clear()
	return result


func _order_prop_materials() -> void:
	var materials := {}
	var queues: Array[int] = [3000]
	for item: Item in items.values():
		for mesh: MeshInstance3D in item.meshes:
			for surface in range(mesh.mesh.get_surface_count()):
				var material := mesh.get_active_material(surface)
				if material == null or materials.has(material) or not material.has_meta("studio_prop_queue"):
					continue
				var queue := int(material.get_meta("studio_prop_queue"))
				materials[material] = queue
				if queue not in queues:
					queues.append(queue)
	queues.sort()
	var center := queues.find(3000)
	for material: Material in materials:
		var queue: int = materials[material]
		material.render_priority = clampi(queues.bsearch(queue) - center, -127, 127)


func legacy_meshes(actor_key: int, actor: Node3D) -> Array[MeshInstance3D]:
	var duplicates: Array[MeshInstance3D] = []
	if not legacy_rows.has(actor_key):
		return duplicates
	var row: Dictionary = legacy_rows[actor_key]
	var names: Array = row.legacyRendererNames
	var owners: Array = row.legacyRendererOwners
	var meshes := {}
	for child in actor.get_children():
		if child.has_meta("studio_renderer_index"):
			meshes[int(child.get_meta("studio_renderer_index"))] = child
	var matching_layout := names.size() == meshes.size() and names.size() == owners.size()
	if matching_layout:
		for index in range(names.size()):
			if not meshes.has(index) or meshes[index].get_meta("studio_renderer_name") != String(names[index]).validate_node_name():
				matching_layout = false
				break
	if not matching_layout:
		warnings.append("Старый кеш роли #%d отличается от Workspace. Нужен Reimport Scene." % actor_key)
		# Preserve the working character cache until the user rebuilds it.
		for owner in owners:
			if int(owner) != actor_key:
				set_item_hidden(int(owner), true)
		return duplicates
	for index in range(owners.size()):
		var owner := int(owners[index])
		if owner != actor_key and items.has(owner) and items[owner].node:
			duplicates.append(meshes[index])
	return duplicates


func _load_body_tracks(row: Dictionary) -> void:
	var names: Array = row.get("bodyNames", [])
	var offsets := PackedInt32Array(row.get("bodyOffsets", []))
	var changes := PackedInt32Array(row.get("bodyChanges", []))
	if names.is_empty() or offsets.size() != names.size() + 1 or offsets[-1] != changes.size():
		return
	var tracks := {}
	for index in range(names.size()):
		if offsets[index] < 0 or offsets[index] >= offsets[index + 1]:
			return
		var name := String(names[index]).to_lower()
		if not tracks.has(name):
			tracks[name] = []
		tracks[name].append(changes.slice(offsets[index], offsets[index + 1]))
	body_tracks[int(row.key)] = tracks


func _load_item(folder: String, row: Dictionary, shared_textures: Dictionary) -> void:
	var item := Item.new()
	item.key = int(row.key)
	item.anchor = int(row.get("anchorKey", -1))
	item.bone = String(row.get("anchorBone", ""))
	item.bone_index = int(row.get("anchorBoneIndex", -1))
	item.axes = int(row.get("anchorAxes", 0))
	item.anchor_states = PackedInt32Array(row.get("anchorStates", []))
	var model := String(row.get("model", "")).get_file()
	if not model.is_empty():
		item.node = models[model].duplicate(0) if models.has(model) else Card.load_actor(folder.path_join(model), true, shared_textures)
		if not item.node:
			warnings.append("Item #%d could not be loaded." % item.key)
			return
		item.node.name = "Item_%d" % item.key
		item.rig = item.node.get_node("Skeleton")
		for child in item.node.get_children():
			if child is MeshInstance3D:
				if models.has(model):
					for surface in range(child.mesh.get_surface_count()):
						child.set_surface_override_material(surface, null)
				item.meshes.append(child)
	var data := FileAccess.open(folder.path_join(String(row.track).get_file()), FileAccess.READ)
	if not _read_tracks(item, data):
		if item.node:
			item.node.free()
		warnings.append("Item #%d has an incompatible workspace track." % item.key)
		return
	items[item.key] = item
	if item.node:
		add_child(item.node)
		if not models.has(model):
			models[model] = item.node
	_evaluate(item, 0.0)
	if item.anchor >= 0:
		anchored.append(item)
	if (item.poses.any(func(track: PoseTrack) -> bool: return track.keys[-1] > track.keys[0])
			or item.visibility.any(func(changes: PackedInt32Array) -> bool: return (changes[-1] >> 1) > (changes[0] >> 1))
			or item.tints.any(func(track: TintTrack) -> bool: return track.keys[-1] > track.keys[0])):
		animated.append(item)


func _read_tracks(item: Item, data: FileAccess) -> bool:
	if not data or data.get_length() < 20:
		return false
	var magic := data.get_32()
	if magic != KWP1 and magic != KWP2:
		return false
	var bones := data.get_32()
	if bones != (item.rig.get_bone_count() if item.rig else 1):
		return false
	var count := data.get_32()
	if count < 1 or count > bones:
		return false
	for index in range(count):
		var track := PoseTrack.new()
		track.joint = data.get_32()
		var samples := data.get_32()
		if track.joint >= bones or (index == 0 and track.joint != 0) or not _fits(data, samples, 44):
			return false
		for frame in range(samples):
			track.keys.append(data.get_32())
			track.position.append(Card.read_vector(data))
			track.rotation.append(Card.read_quaternion(data))
			track.scale.append(Card.read_vector(data))
		item.poses.append(track)
	var meshes := data.get_32()
	if meshes != item.meshes.size():
		return false
	for index in range(meshes):
		var samples := data.get_32()
		if not _fits(data, samples, 4):
			return false
		var states := PackedInt32Array()
		for frame in range(samples):
			states.append(data.get_32())
		item.visibility.append(states)
	var tints := data.get_32()
	var channels := PropMaterial.CHANNELS if magic == KWP2 else ["base_tint"]
	if tints > meshes * 64 * channels.size():
		return false
	var overrides := {}
	for index in range(tints):
		var mesh := data.get_32()
		var surface := data.get_32()
		var channel := data.get_32() if magic == KWP2 else 0
		var samples := data.get_32()
		if mesh >= meshes or channel >= channels.size() or not _fits(data, samples, 20):
			return false
		var track := TintTrack.new()
		track.parameter = channels[channel]
		var fades := false
		for frame in range(samples):
			track.keys.append(data.get_32())
			var value := Card.read_color(data)
			track.colors.append(value)
			fades = fades or value.a < 0.99
		if surface >= item.meshes[mesh].mesh.get_surface_count():
			continue
		var slot := Vector2i(mesh, surface)
		var original := item.meshes[mesh].get_active_material(surface) as ShaderMaterial
		track.material = overrides.get(slot, original)
		if track.material:
			if not overrides.has(slot):
				track.material = track.material.duplicate()
			if channel == 0 and fades:
				if magic == KWP2:
					PropMaterial.enable_animated_alpha(track.material)
				elif track.material.shader != Card.DECAL:
					track.material = _transparent_material(track.material)
			overrides[slot] = track.material
			item.meshes[mesh].set_surface_override_material(surface, track.material)
			item.tints.append(track)
	return data.get_position() == data.get_length()


func _transparent_material(source: ShaderMaterial) -> ShaderMaterial:
	var material := ShaderMaterial.new()
	material.shader = Card.DECAL
	for uniform in source.shader.get_shader_uniform_list():
		material.set_shader_parameter(uniform.name, source.get_shader_parameter(uniform.name))
	return material


func _fits(data: FileAccess, samples: int, stride: int) -> bool:
	return samples >= 1 and samples <= frames + 1 and data.get_position() + samples * stride <= data.get_length()


func _evaluate(item: Item, frame: float) -> void:
	for track: PoseTrack in item.poses:
		var pose := track.evaluate(frame)
		if track.joint == 0:
			item.authored = Transform3D(Basis(pose[1]) * Basis.from_scale(pose[2]), pose[0])
		elif item.rig:
			item.rig.set_bone_pose_position(track.joint, pose[0])
			item.rig.set_bone_pose_rotation(track.joint, pose[1])
			item.rig.set_bone_pose_scale(track.joint, pose[2])
	_place(item, item.authored)
	item.visible = false
	for index in range(item.visibility.size()):
		var states := item.visibility[index]
		var state := maxi(0, states.bsearch(int(frame) * 2 + 1, false) - 1)
		var shown := bool(states[state] & 1)
		item.visible = item.visible or shown
		item.meshes[index].visible = shown
	for tint in item.tints:
		tint.seek(frame)


func seek(seconds: float, rigs: Dictionary, replacements: Dictionary = {}) -> void:
	var frame := clampf(seconds / duration, 0.0, 1.0) * (frames - 1) if duration > 0.0 else 0.0
	for item in animated:
		_evaluate(item, frame)
	for key in replacements:
		_apply_body_details(key, replacements[key], int(frame))
	if rigs.is_empty():
		if active_rebind:
			for item in anchored:
				_place(item, item.authored)
		active_rebind = false
		return
	active_rebind = true
	var evaluated := {}
	var processing := {}
	var updated := {}
	for item in anchored:
		if rigs.has(item.anchor) and not updated.has(item.anchor):
			var pair: Array = rigs[item.anchor]
			pair[0].force_update_all_bone_transforms()
			pair[1].force_update_all_bone_transforms()
			updated[item.anchor] = true
	for item in anchored:
		_rebind(item, int(frame), rigs, evaluated, processing)


func _apply_body_details(key: int, model: Node3D, frame: int) -> void:
	if model.has_meta("studio_qa_preset"):
		return
	var tracks: Dictionary = body_tracks.get(key, {})
	if tracks.is_empty():
		return
	for part in model.get_children():
		if not part is MeshInstance3D:
			continue
		var name := String(part.name).to_lower()
		if not tracks.has(name):
			continue
		if not part.has_meta("workspace_body_visible"):
			part.set_meta("workspace_body_visible", part.visible)
		var authored := false
		for changes: PackedInt32Array in tracks[name]:
			var index := maxi(0, changes.bsearch(frame * 2 + 1, false) - 1)
			authored = authored or bool(changes[index] & 1)
		part.visible = authored and part.get_meta("workspace_body_visible")


func _rebind(item: Item, frame: int, rigs: Dictionary, evaluated: Dictionary, processing: Dictionary) -> void:
	if evaluated.has(item.key) or processing.has(item.key):
		return
	if not item.anchor_states.is_empty():
		var state := maxi(0, item.anchor_states.bsearch(frame * 2 + 1, false) - 1)
		if not item.anchor_states[state] & 1:
			_place(item, item.authored)
			evaluated[item.key] = true
			return
	processing[item.key] = true
	var original := Transform3D.IDENTITY
	var replacement := Transform3D.IDENTITY
	if rigs.has(item.anchor):
		var pair: Array = rigs[item.anchor]
		var source: Skeleton3D = pair[0]
		var target: Skeleton3D = pair[1]
		var a := source.find_bone(item.bone) if not item.bone.is_empty() else 0
		if item.bone_index >= 0 and item.bone_index < source.get_bone_count():
			a = item.bone_index
		var b := target.find_bone(item.bone) if not item.bone.is_empty() else 0
		if a >= 0 and b >= 0:
			original = source.global_transform * source.get_bone_global_pose(a)
			replacement = target.global_transform * target.get_bone_global_pose(b)
			item.binding_warning = ""
		else:
			item.binding_warning = "Нет соответствующей кости у сменной модели · " + item.bone
	elif items.has(item.anchor) and not processing.has(item.anchor):
		var parent: Item = items[item.anchor]
		_rebind(parent, frame, rigs, evaluated, processing)
		original = parent.authored
		replacement = parent.world_pose
	var transformed := item.authored
	if original != replacement and absf(original.basis.determinant()) > 0.000001:
		var delta := replacement * original.affine_inverse()
		if item.axes & 1:
			transformed.origin = delta * item.authored.origin
		if item.axes & 2:
			transformed.basis = delta.basis.orthonormalized() * transformed.basis
		if item.axes & 4:
			transformed.basis = transformed.basis * Basis.from_scale(delta.basis.get_scale())
	_place(item, transformed)
	processing.erase(item.key)
	evaluated[item.key] = true


func _place(item: Item, pose: Transform3D) -> void:
	item.world_pose = pose
	if item.node:
		item.node.transform = pose


func set_item_hidden(key: int, hidden: bool) -> void:
	if items.has(key):
		var item: Item = items[key]
		item.override_hidden = hidden
		if item.node:
			item.node.visible = not hidden
