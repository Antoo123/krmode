extends RefCounted

const MORPHS := "res://Content/F7/Reactions/face_morphs.json.gz"
static var sources: Array
var surfaces: Array[Dictionary] = []
var applied := {}
var last_weights := {}
var last_blink := -1.0


func bind_actor(actor: Node3D, presets: Dictionary) -> void:
	surfaces.clear()
	applied.clear()
	last_weights.clear()
	if sources.is_empty():
		var file := FileAccess.open(MORPHS, FileAccess.READ)
		if not file:
			return
		var decoded := file.get_buffer(file.get_length()).decompress_dynamic(24 * 1024 * 1024, FileAccess.COMPRESSION_GZIP)
		var parsed: Variant = JSON.parse_string(decoded.get_string_from_utf8())
		if not parsed is Array:
			return
		sources = parsed
	var rig := actor.get_node("Skeleton") as Skeleton3D
	for child in actor.get_children():
		if child is MeshInstance3D and child.mesh is ArrayMesh and child.mesh.get_surface_count():
			var data: Array = child.mesh.surface_get_arrays(0)
			for source: Dictionary in sources:
				if child.name != source.name or not matches(data, source):
					continue
				var shapes := _build_shapes(child, rig, data, source, presets)
				if not shapes.is_empty():
					surfaces.append({"node": child, "source": source, "shapes": shapes})
				break


static func matches(data: Array, source: Dictionary) -> bool:
	var uv: PackedVector2Array = data[Mesh.ARRAY_TEX_UV]
	if uv.size() != int(source.vertices):
		return false
	for sample: Array in source.uv:
		if uv[int(sample[0])].distance_squared_to(Vector2(sample[1], 1.0 - float(sample[2]))) > 0.00000003:
			return false
	return true


func _build_shapes(node: MeshInstance3D, rig: Skeleton3D, data: Array, source: Dictionary,
		presets: Dictionary) -> Dictionary:
	if node.has_meta("f7_shapes"):
		return node.get_meta("f7_shapes")
	var needed := {}
	for preset: Dictionary in presets.values():
		for target in [_weights(source, preset, 0.0), _weights(source, preset, 1.0)]:
			for key: int in target:
				needed[key] = true
	var original_weights := _weights(source, {"eye": 0, "mouth": 0, "eyebrow": 0, "openMinMouth": 0.0}, 1.0)
	for id: int in original_weights:
		needed[id] = true
	var original := node.mesh as ArrayMesh
	var mesh := ArrayMesh.new()
	mesh.blend_shape_mode = Mesh.BLEND_SHAPE_MODE_RELATIVE
	var count: int = source.vertices
	var bind: Array[Basis] = []
	var native_bind := node.skin and node.skin.get_bind_count() != rig.get_bone_count()
	if not native_bind:
		for entry: Array in source.binds:
			var id := rig.find_bone(entry[0])
			if id < 0:
				return {}
			bind.append(rig.get_bone_global_rest(id).basis * Basis(
				Vector3(entry[1], entry[2], entry[3]), Vector3(entry[4], entry[5], entry[6]),
				Vector3(entry[7], entry[8], entry[9])))
	var deltas: Array[Array] = []
	var shape_indices := {}
	for id: int in needed:
		var shape: Array = source.shapes[id]
		var delta := PackedVector3Array()
		delta.resize(count)
		var sparse: Array = shape[1]
		for at in range(0, sparse.size(), 4):
			var vertex := int(sparse[at])
			var d := Vector3(sparse[at + 1], sparse[at + 2], sparse[at + 3])
			if native_bind:
				delta[vertex] = d
			else:
				var total := Vector3.ZERO
				if source.weights == null:
					total = bind[0] * d
				else:
					var weights: Array = source.weights[vertex]
					for j in weights.size():
						var weight := float(weights[j])
						if weight > 0.0:
							total += (bind[int(source.indices[vertex][j])] * d) * weight
				delta[vertex] = total
		var entry := []
		entry.resize(Mesh.ARRAY_MAX)
		entry[Mesh.ARRAY_VERTEX] = delta
		var normals := PackedVector3Array()
		normals.resize(count)
		entry[Mesh.ARRAY_NORMAL] = normals
		shape_indices[id] = deltas.size()
		deltas.append(entry)
		mesh.add_blend_shape(StringName(shape[0]))
	for index in original.get_surface_count():
		var arrays: Array = original.surface_get_arrays(index)
		var format := original.surface_get_format(index)
		mesh.add_surface_from_arrays(original.surface_get_primitive_type(index), arrays, deltas, {}, format)
		mesh.surface_set_material(index, original.surface_get_material(index))
	node.mesh = mesh
	var mapping := {"indices": shape_indices, "base": original_weights}
	node.set_meta("f7_shapes", mapping)
	return mapping


func apply(presets: Dictionary, face_id: int, expression: Dictionary, blink_open: float) -> void:
	if last_weights == expression and is_equal_approx(last_blink, blink_open) and applied.get("face_id", -1) == face_id:
		return
	last_weights = expression
	last_blink = blink_open
	var selected: Dictionary = presets.get(str(face_id), {})
	var eye_open := 0.0
	var mouth_open := 0.0
	for id: int in expression:
		var preset: Dictionary = presets[str(id)]
		eye_open += float(preset.openMaxEye) * float(expression[id]) * blink_open
		mouth_open += float(preset.openMinMouth) * float(expression[id])
	var max_delta := 0.0
	for entry: Dictionary in surfaces:
		var node := entry.node as MeshInstance3D
		if not is_instance_valid(node):
			continue
		var targets := {}
		for id: int in expression:
			var weights := _weights(entry.source, presets[str(id)], blink_open)
			for shape: int in weights:
				targets[shape] = targets.get(shape, 0.0) + float(weights[shape]) * float(expression[id])
		var indices: Dictionary = entry.shapes.indices
		var baseline: Dictionary = entry.shapes.base
		for id: int in indices:
			var weight := float(targets.get(id, 0.0)) - float(baseline.get(id, 0.0))
			node.set_blend_shape_value(indices[id], weight)
			max_delta = maxf(max_delta, absf(node.get_blend_shape_value(indices[id])))
	applied = {
		"surfaces": surfaces.size(), "face_id": face_id, "eyebrow": selected.eyebrow,
		"eye": selected.eye, "eye_open": eye_open,
		"mouth": selected.mouth, "mouth_open": mouth_open,
		"morph_weight": max_delta,
	}


func reset() -> void:
	for entry: Dictionary in surfaces:
		if is_instance_valid(entry.node):
			for index: int in entry.shapes.indices.values():
				entry.node.set_blend_shape_value(index, 0.0)
	applied.clear()
	last_weights.clear()


static func _weights(source: Dictionary, preset: Dictionary, blink_open: float) -> Dictionary:
	var weights := {}
	for channel: String in source.patterns:
		var patterns: Array = source.patterns[channel]
		var pattern := int(preset[channel])
		if pattern >= patterns.size():
			continue
		var pair: Array = patterns[pattern]
		var openness := float(preset.openMinMouth) if channel == "mouth" else blink_open
		if channel == "eye":
			openness *= float(preset.get("openMaxEye", 1.0))
		for i in range(2):
			var shape := int(pair[i])
			if shape >= 0:
				var weight := openness if i == 1 else 1.0 - openness
				weights[shape] = float(weights.get(shape, 0.0)) + weight
	return weights
