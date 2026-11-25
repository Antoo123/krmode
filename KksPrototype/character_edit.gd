extends RefCounted

const SLOT_ROOTS := {
	"ct_clothestop": "Top", "ct_clothesbot": "Bottom", "ct_bra": "Bra",
	"ct_shorts": "Underwear", "ct_gloves": "Gloves", "ct_panst": "Tights",
	"ct_socks": "Socks", "ct_shoes_inner": "Shoes", "ct_shoes_outer": "Shoes",
}
const TOP := ["Top", "Bra"]
const BOTTOM := ["Bottom", "Underwear", "Tights"]
const HAIR := "Hair"
const HAIR_ROOTS := ["ct_hairb", "ct_hairf", "ct_hairs", "ct_hairo"]
const UPPER_BODY_DETAILS := ["o_mnpa", "o_mnpb"]
const LOWER_BODY_DETAILS := ["o_dankon", "o_dan_f", "o_gomu", "cm_o_dan00", "cm_o_dan_f"]

static func part_root(mesh_name: String, skeleton: Skeleton3D) -> String:
	for index in range(skeleton.get_bone_count()):
		var name := skeleton.get_bone_name(index)
		if name != mesh_name and not name.ends_with("_" + mesh_name):
			continue
		var ancestor := index
		while ancestor >= 0:
			var part := skeleton.get_bone_name(ancestor).to_lower()
			if SLOT_ROOTS.has(part) or part.begins_with("ct_hair"):
				return part
			ancestor = skeleton.get_bone_parent(ancestor)
	return ""


static func classify(mesh_name: String, skeleton: Skeleton3D) -> String:
	var root := part_root(mesh_name, skeleton)
	if root.begins_with("ct_hair") or mesh_name.to_lower().begins_with("cf_hair"):
		return HAIR
	return SLOT_ROOTS.get(root, "")


static func slots(actor: Node3D) -> Dictionary:
	var result := {}
	for child in actor.get_children():
		if child is MeshInstance3D and child.has_meta("wardrobe_slot"):
			var slot: String = child.get_meta("wardrobe_slot")
			if not result.has(slot):
				result[slot] = []
			result[slot].append(child)
	return result


static func set_clothes(actor: Node3D, visible: bool, slot: String = "") -> bool:
	var garments := slots(actor)
	var changed := false
	for group in garments:
		if group != HAIR and (slot.is_empty() or slot == group):
			for mesh in garments[group]:
				mesh.visible = visible
				changed = true
	if changed:
		update_skin_masks(actor, garments)
	return changed


static func is_dressed(actor: Node3D) -> bool:
	var garments := slots(actor)
	for group in garments:
		if group != HAIR and group_visible(garments, [group]):
			return true
	return false


static func group_visible(garments: Dictionary, groups: Array) -> bool:
	for group in groups:
		for mesh in garments.get(group, []):
			if mesh.visible:
				return true
	return false


static func update_body_details(actor: Node3D, garments: Dictionary) -> void:
	var upper_visible := not group_visible(garments, TOP)
	var lower_visible := not group_visible(garments, BOTTOM)
	for child in actor.get_children():
		if child is not MeshInstance3D:
			continue
		var mesh_name := String(child.name).to_lower()
		if mesh_name in UPPER_BODY_DETAILS:
			child.visible = upper_visible
		elif mesh_name in LOWER_BODY_DETAILS:
			child.visible = lower_visible


static func update_skin_masks(actor: Node3D, garments: Dictionary) -> void:
	update_body_details(actor, garments)
	for child in actor.get_children():
		if child is not MeshInstance3D:
			continue
		for surface in range(child.mesh.get_surface_count()):
			var material := child.get_active_material(surface) as ShaderMaterial
			if not material or (material.get_shader_parameter("use_body_mask") != true and material.get_shader_parameter("use_bottom_mask") != true):
				continue
			var weights := mask_weights(material)
			material.set_meta("outfit_mask", weights)
			var top_slots: Array = material.get_meta("top_mask_slots", TOP)
			var bottom_slots: Array = material.get_meta("bottom_mask_slots", BOTTOM)
			if not group_visible(garments, top_slots):
				weights.x = 0.0
			if not group_visible(garments, bottom_slots):
				weights.y = 0.0
			material.set_shader_parameter("body_mask_weights", weights)


static func replace_hair(actor: Node3D, donor: Node3D, section: int = -1) -> bool:
	var donor_hair: Array = slots(donor).get(HAIR, [])
	if section >= 0:
		donor_hair = donor_hair.filter(func(part: Node): return part.get_meta("hair_section", -1) == section)
	var source: Skeleton3D = donor.get_node("Skeleton")
	var target: Skeleton3D = actor.get_node("Skeleton")
	var head := target.find_bone("cf_J_FaceUp_ty")
	var donor_head := source.find_bone("cf_J_FaceUp_ty")
	if donor_hair.is_empty() or head < 0 or donor_head < 0:
		return false
	var attachment := Skin.new()
	var bind := source.get_bone_global_rest(donor_head).affine_inverse()
	for i in range(source.get_bone_count()):
		attachment.add_bind(head, bind)
	for hair in slots(actor).get(HAIR, []):
		if section < 0 or hair.get_meta("hair_section", -1) == section:
			remove_part(actor, hair)
	for original in donor_hair:
		add_part(actor, original, HAIR, attachment)
	return true


static func replace_outfit(actor: Node3D, donor: Node3D) -> bool:
	var source: Skeleton3D = donor.get_node("Skeleton")
	var target: Skeleton3D = actor.get_node("Skeleton")
	if source.get_bone_name(0).left(4).to_lower() != target.get_bone_name(0).left(4).to_lower():
		return false
	var garments := slots(donor)
	garments.erase(HAIR)
	if garments.is_empty():
		return false
	var bind := remap_skin(source, target)
	var previous := slots(actor)
	previous.erase(HAIR)
	for pieces in previous.values():
		for piece in pieces:
			remove_part(actor, piece)
	for slot in garments:
		for piece in garments[slot]:
			add_part(actor, piece, slot, bind)
	copy_body_mask(actor, donor)
	update_skin_masks(actor, slots(actor))
	return true


static func remap_skin(source: Skeleton3D, target: Skeleton3D) -> Skin:
	var bind := Skin.new()
	for i in range(source.get_bone_count()):
		var ancestor := i
		var mapped := target.find_bone(source.get_bone_name(ancestor))
		while mapped < 0 and source.get_bone_parent(ancestor) >= 0:
			ancestor = source.get_bone_parent(ancestor)
			mapped = target.find_bone(source.get_bone_name(ancestor))
		bind.add_bind(maxi(0, mapped), source.get_bone_global_rest(ancestor).affine_inverse())
	return bind


static func replace_piece(actor: Node3D, donor: Node3D, category: int) -> bool:
	if category < 105:
		return replace_hair(actor, donor, category - 101)
	var source: Skeleton3D = donor.get_node("Skeleton")
	var target: Skeleton3D = actor.get_node("Skeleton")
	if source.get_bone_name(0).left(4).to_lower() != target.get_bone_name(0).left(4).to_lower():
		return false
	var available := slots(donor)
	available.erase(HAIR)
	if available.size() != 1:
		return false
	var slot: String = available.keys()[0]
	for previous in slots(actor).get(slot, []):
		remove_part(actor, previous)
	var bind := remap_skin(source, target)
	for part in available[slot]:
		add_part(actor, part, slot, bind)
	if category in [105, 106]:
		copy_body_mask(actor, donor, category)
	update_skin_masks(actor, slots(actor))
	return true


static func copy_body_mask(actor: Node3D, donor: Node3D, category: int = -1) -> void:
	var source := skin_material(donor)
	var target := skin_material(actor)
	if not target:
		return
	var source_weights := mask_weights(source)
	var previous := mask_weights(target)
	if category == 106:
		set_bottom_mask(target, source)
		target.set_meta("bottom_mask_slots", ["Bottom"])
		previous.y = source_weights.y
	else:
		if category == 105 and target.get_shader_parameter("use_bottom_mask") != true:
			set_bottom_mask(target, target)
		elif category == -1:
			target.set_shader_parameter("use_bottom_mask", false)
			target.set_meta("bottom_mask_slots", BOTTOM)
		target.set_meta("top_mask_slots", ["Top"] if category == 105 else TOP)
		for property in ["body_mask", "body_mask_uv", "use_body_mask"]:
			target.set_shader_parameter(property, source.get_shader_parameter(property) if source else null)
		previous.x = source_weights.x
		if category == -1:
			previous.y = source_weights.y
	target.set_shader_parameter("opacity_mode", 1 if target.get_shader_parameter("use_body_mask") == true or target.get_shader_parameter("use_bottom_mask") == true else 0)
	target.set_meta("outfit_mask", previous)
	target.set_shader_parameter("body_mask_weights", previous)


static func mask_weights(material: ShaderMaterial) -> Vector2:
	if material:
		var value: Variant = material.get_meta("outfit_mask", material.get_shader_parameter("body_mask_weights"))
		if value is Vector2:
			return value
	return Vector2.ONE


static func set_bottom_mask(target: ShaderMaterial, source: ShaderMaterial) -> void:
	var valid: bool = source != null and source.get_shader_parameter("use_body_mask") == true
	target.set_shader_parameter("bottom_mask", source.get_shader_parameter("body_mask") if valid else null)
	target.set_shader_parameter("bottom_mask_uv", source.get_shader_parameter("body_mask_uv") if valid else null)
	target.set_shader_parameter("use_bottom_mask", true)


static func skin_material(actor: Node3D) -> ShaderMaterial:
	for part in actor.get_children():
		if part is MeshInstance3D and String(part.name).begins_with("o_body"):
			return part.get_active_material(0) as ShaderMaterial
	return null


static func grade_npc_skin(actor: Node3D) -> void:
	for part in actor.get_children():
		if part is not MeshInstance3D or not part.mesh:
			continue
		for surface in range(part.mesh.get_surface_count()):
			var material := part.get_active_material(surface) as ShaderMaterial
			if material and material.get_shader_parameter("surface_kind") == 1:
				material.set_shader_parameter("skin_exposure", 0.95)


static func clear_bottom_coverage(actor: Node3D) -> void:
	var material := skin_material(actor)
	if not material:
		return
	var weights := mask_weights(material)
	weights.y = 0.0
	material.set_meta("outfit_mask", weights)
	material.set_shader_parameter("body_mask_weights", weights)
	material.set_shader_parameter("use_bottom_mask", false)


static func fit_default_skirt(actor: Node3D) -> void:
	for part: MeshInstance3D in slots(actor).get("Bottom", []):
		var fitted := ArrayMesh.new()
		for surface in range(part.mesh.get_surface_count()):
			var data := part.mesh.surface_get_arrays(surface)
			var vertices: PackedVector3Array = data[Mesh.ARRAY_VERTEX]
			for i in range(vertices.size()):
				var point := vertices[i]
				var rear := smoothstep(0.008, 0.09, point.z)
				var hips := 1.0 - smoothstep(0.90, 1.03, point.y)
				point.z += 0.046 * rear * hips
				vertices[i] = point
			data[Mesh.ARRAY_VERTEX] = vertices
			var flags: int = part.mesh.surface_get_format(surface) & 0x0FFFF000
			fitted.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, data, [], {}, flags)
			fitted.surface_set_material(fitted.get_surface_count() - 1, part.get_active_material(surface))
		part.mesh = fitted


static func remove_part(actor: Node3D, part: Node) -> void:
	actor.remove_child(part)
	part.queue_free()


static func add_part(actor: Node3D, original: MeshInstance3D, slot: String, skin: Skin) -> void:
	var part := MeshInstance3D.new()
	part.name = original.name
	part.mesh = original.mesh
	part.skin = skin
	part.skeleton = NodePath("../Skeleton")
	part.layers = original.layers
	part.set_meta("wardrobe_slot", slot)
	if original.has_meta("hair_section"):
		part.set_meta("hair_section", original.get_meta("hair_section"))
	actor.add_child(part)
