extends RefCounted

const VIEW_LAYER := 4
const SKIN := preload("res://character_surface.gdshader")
const ARM_SHADER := preload("res://character_view_arm.gdshader")
const BONES := ["cf_j_arm00_L", "cf_j_arm00_R", "cf_j_leg01_L", "cf_j_leg01_R"]
const PARTS := ["L", "R", "leg_l", "leg_r"]

var original: Dictionary = {}
var pieces: Dictionary = {}
var root: Node3D
var fill: OmniLight3D
var rig: Skeleton3D
var arm_joints := {}
var arm_materials: Array[ShaderMaterial] = []
var arm_opacity := 1.0


func fade_forearms(enabled: bool) -> void:
	arm_opacity = 0.20 if enabled else 1.0
	for material in arm_materials:
		material.set_shader_parameter("forearm_opacity", arm_opacity)


func show_limbs(actor: Node3D, weights: Dictionary, legs: bool) -> void:
	if not is_instance_valid(root):
		create(actor)
	if not is_instance_valid(root):
		return
	for side: String in pieces:
		var visible: bool = legs if side.begins_with("leg") else float(weights.get(side, 0.0)) > 0.025
		for part: MeshInstance3D in pieces[side]:
			part.visible = visible
	fill.visible = legs or not weights.is_empty()


func create(actor: Node3D) -> void:
	if not actor:
		return
	var skeleton: Skeleton3D = actor.get_node("Skeleton")
	rig = skeleton
	for side in ["L", "R"]:
		var shoulder := rig.find_bone("cf_j_arm00_" + side)
		var elbow := rig.find_bone("cf_j_forearm01_" + side)
		if mini(shoulder, elbow) >= 0:
			arm_joints[side] = Vector2i(shoulder, elbow)
	root = Node3D.new()
	root.name = "InteractionViewLimbs"
	actor.add_child(root)
	var classes := PackedInt32Array()
	classes.resize(skeleton.get_bone_count())
	var hand_bones := PackedByteArray()
	hand_bones.resize(skeleton.get_bone_count())
	for bone in range(skeleton.get_bone_count()):
		var name := String(skeleton.get_bone_name(bone))
		var own := BONES.find(name)
		var parent := skeleton.get_bone_parent(bone)
		classes[bone] = own if own >= 0 else (classes[parent] if parent >= 0 else -1)
		hand_bones[bone] = int(name in ["cf_j_hand_L", "cf_j_hand_R"] or (parent >= 0 and hand_bones[parent] != 0))
	for part in actor.get_children():
		if part is not MeshInstance3D or not part.mesh or not part.skin:
			continue
		original[part] = part.visible
		part.hide()
		if not original[part]:
			continue
		var skin := part.skin as Skin
		var masks := PackedInt32Array()
		masks.resize(skin.get_bind_count())
		for index in range(skin.get_bind_count()):
			var bone := skin.get_bind_bone(index)
			masks[index] = classes[bone] if bone >= 0 and bone < classes.size() else -1
		build_parts(part, masks, hand_bones)
	fill = OmniLight3D.new()
	fill.name = "ViewLimbFill"
	fill.position = Vector3(0.32, 1.47, 0.02)
	fill.omni_range = 1.7
	fill.omni_attenuation = 0.78
	fill.light_energy = 0.14
	fill.light_color = Color("#fff2e7")
	fill.light_cull_mask = VIEW_LAYER
	root.add_child(fill)


func build_parts(source: MeshInstance3D, masks: PackedInt32Array, hand_bones: PackedByteArray) -> void:
	var meshes: Array[ArrayMesh] = []
	for side in PARTS:
		meshes.append(ArrayMesh.new())
	for surface in range(source.mesh.get_surface_count()):
		var arrays: Array = source.mesh.surface_get_arrays(surface)
		var bones: PackedInt32Array = arrays[Mesh.ARRAY_BONES]
		var weights: PackedFloat32Array = arrays[Mesh.ARRAY_WEIGHTS]
		var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
		if bones.is_empty() or indices.is_empty():
			continue
		var vertex_class := PackedInt32Array()
		vertex_class.resize(bones.size() / 4)
		vertex_class.fill(-1)
		for vertex in range(vertex_class.size()):
			var strongest := 0.0
			for influence in range(4):
				var index := vertex * 4 + influence
				if weights[index] > strongest:
					strongest = weights[index]
					vertex_class[vertex] = masks[bones[index]]
		var material: Material = source.get_active_material(surface)
		for limb in range(PARTS.size()):
			var list := PackedInt32Array()
			for at in range(0, indices.size(), 3):
				var a := indices[at]
				var b := indices[at + 1]
				var c := indices[at + 2]
				var count := int(vertex_class[a] == limb) + int(vertex_class[b] == limb) + int(vertex_class[c] == limb)
				if count >= 2:
					list.append(a)
					list.append(b)
					list.append(c)
			if list.is_empty():
				continue
			var limb_arrays := arrays.duplicate()
			limb_arrays[Mesh.ARRAY_INDEX] = list
			var flags: int = source.mesh.surface_get_format(surface) & 0x0FFFF000
			var use_arm_shader: bool = limb < 2 and arm_joints.has(PARTS[limb]) and material is ShaderMaterial and material.shader == SKIN
			if use_arm_shader:
				var joints: Vector2i = arm_joints[PARTS[limb]]
				var shoulder := rig.get_bone_global_rest(joints.x).origin
				var elbow := rig.get_bone_global_rest(joints.y).origin
				var axis := shoulder.direction_to(elbow)
				var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
				var progress := PackedFloat32Array()
				progress.resize(vertices.size() * 2)
				var mesh_to_rig := rig.global_transform.affine_inverse() * source.global_transform
				for vertex in range(vertices.size()):
					var point := mesh_to_rig * vertices[vertex]
					progress[vertex * 2] = (point - shoulder).dot(axis)
					var hand_share := 0.0
					for influence in range(4):
						var index := vertex * 4 + influence
						var bone := source.skin.get_bind_bone(bones[index])
						if bone >= 0 and bone < hand_bones.size() and hand_bones[bone]:
							hand_share += weights[index]
					progress[vertex * 2 + 1] = hand_share
				limb_arrays[Mesh.ARRAY_CUSTOM1] = progress
				flags &= ~(Mesh.ARRAY_FORMAT_CUSTOM_MASK << Mesh.ARRAY_FORMAT_CUSTOM1_SHIFT)
				flags |= Mesh.ARRAY_CUSTOM_RG_FLOAT << Mesh.ARRAY_FORMAT_CUSTOM1_SHIFT
			var mesh := meshes[limb]
			mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, limb_arrays, [], {}, flags)
			var view_material := material
			if material is ShaderMaterial and material.shader == SKIN:
				var customized := material.duplicate() as ShaderMaterial
				customized.set_shader_parameter("first_person_limb", true)
				if use_arm_shader:
					customized.next_pass = null
					customized.shader = ARM_SHADER
					customized.render_priority = 1
					customized.set_shader_parameter("forearm_opacity", arm_opacity)
					arm_materials.append(customized)
				view_material = customized
			mesh.surface_set_material(mesh.get_surface_count() - 1, view_material)
	for limb in range(PARTS.size()):
		if meshes[limb].get_surface_count() == 0:
			continue
		var part := MeshInstance3D.new()
		part.mesh = meshes[limb]
		part.skin = source.skin
		part.skeleton = NodePath("../../Skeleton")
		part.layers = 2 | VIEW_LAYER
		part.transform = source.transform
		part.visible = false
		root.add_child(part)
		if not pieces.has(PARTS[limb]):
			pieces[PARTS[limb]] = []
		pieces[PARTS[limb]].append(part)


func restore() -> void:
	for part in original:
		if is_instance_valid(part):
			part.visible = original[part]
	if is_instance_valid(root):
		root.hide()
		root.queue_free()
	root = null
	original.clear()
	pieces.clear()
	arm_joints.clear()
	arm_materials.clear()
	rig = null
