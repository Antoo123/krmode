extends RefCounted

const Pose := preload("res://npc_pose.gd")
const HIPS := "cf_j_hips"
const WAIST := "cf_j_waist02"
const HEIGHT := "cf_n_height"

var actor: Node3D
var rig: Skeleton3D
var source: Skeleton3D
var bones := PackedInt32Array()
var mapped := PackedInt32Array()
var corrections: Array[Quaternion] = []
var offset_bones := PackedInt32Array()
var offset_sources := PackedInt32Array()
var hips: int
var source_hips: int
var contact_scale := Vector3.ONE
var skipped_accessories := 0


func setup(model: Node3D, source_rig: Skeleton3D, neutral: Skeleton3D, local_motion: PackedStringArray = []) -> bool:
	actor = model
	rig = model.get_node("Skeleton")
	source = source_rig
	_prefer_body_bone_names()
	hips = rig.find_bone(HIPS)
	source_hips = source.find_bone(HIPS)
	for required: String in [HIPS, WAIST, HEIGHT, "cf_j_arm00_R", "cf_j_forearm01_R", "cf_j_hand_R",
			"cf_j_head", "cf_j_foot_L", "cf_j_foot_R", "cf_j_hand_L"]:
		if rig.find_bone(required) < 0 or source.find_bone(required) < 0:
			return false
	var height := rig.get_bone_rest(rig.find_bone(HEIGHT)).basis.get_scale().y
	var source_height := source.get_bone_rest(source.find_bone(HEIGHT)).basis.get_scale().y
	var stature := height / maxf(source_height, 0.01)
	var target_shape := _hip_extent(actor, rig)
	var source_shape := _hip_extent(source.get_parent(), source)
	contact_scale = (target_shape / source_shape).clamp(Vector3(0.8, 1.0, 0.8), Vector3(1.25, 1.0, 1.25)) * stature
	_hide_detached_finger_accessories()
	for joint in range(rig.get_bone_count()):
		var name := String(rig.get_bone_name(joint))
		var face := name.begins_with("cf_J_")
		if not (face or name.begins_with("cf_j_")):
			continue
		var original := source.find_bone(name)
		var bind := neutral.find_bone(name)
		if original < 0 or bind < 0:
			continue
		var parent := rig.get_bone_parent(joint)
		var source_parent := source.get_bone_parent(original)
		if parent < 0 or source_parent < 0 or rig.get_bone_name(parent) != source.get_bone_name(source_parent):
			continue
		bones.append(joint)
		mapped.append(original)
		var from := (source.get_bone_rest(original) if face else neutral.get_bone_rest(bind)).basis.get_rotation_quaternion()
		var to := rig.get_bone_rest(joint).basis.get_rotation_quaternion()
		corrections.append((to * from.inverse()).normalized())
		if face or name in local_motion:
			offset_bones.append(joint)
			offset_sources.append(original)
	return bones.size() >= 50


func _prefer_body_bone_names() -> void:
	var body_branch := PackedByteArray()
	body_branch.resize(rig.get_bone_count())
	for joint in range(rig.get_bone_count()):
		var name := String(rig.get_bone_name(joint))
		var parent := rig.get_bone_parent(joint)
		if name == "p_cf_body_bone" and parent >= 0 and rig.get_bone_name(parent) == "BodyTop":
			body_branch[joint] = 1
		elif parent >= 0 and body_branch[parent] and not name.begins_with("ca_slot"):
			body_branch[joint] = 1
		var duplicate := "KKS_%d_" % joint
		if not body_branch[joint] or not name.begins_with(duplicate):
			continue
		var original := name.trim_prefix(duplicate)
		if not original.to_lower().begins_with("cf_"):
			continue
		var existing := rig.find_bone(original)
		if existing >= 0:
			if body_branch[existing]:
				continue
			rig.set_bone_name(existing, "KKS_%d_%s" % [existing, original])
		rig.set_bone_name(joint, original)


func apply(source_actor: Node3D) -> void:
	actor.transform = source_actor.transform
	for i in range(bones.size()):
		rig.set_bone_pose_rotation(bones[i], (corrections[i] * source.get_bone_pose_rotation(mapped[i])).normalized())
	for i in range(offset_bones.size()):
		var joint := offset_bones[i]
		var driven := offset_sources[i]
		rig.set_bone_pose_position(joint, rig.get_bone_rest(joint).origin
			+ source.get_bone_pose_position(driven) - source.get_bone_rest(driven).origin)
	var reference := source_actor.transform * source.get_bone_global_pose(source_hips).origin
	actor.position += reference - actor.transform * rig.get_bone_global_pose(hips).origin


static func keep_contact(source_a: Skeleton3D, source_b: Skeleton3D, target_a: Skeleton3D,
		target_b: Skeleton3D, contact_scale: Vector3, rule: Dictionary) -> void:
	var anchor := String(rule.get("anchor", ""))
	var tip_name := String(rule.get("tip", ""))
	var upper_name := String(rule.get("upper", ""))
	var bend_name := String(rule.get("bend", ""))
	var a := source_a.find_bone(anchor)
	var b := source_b.find_bone(tip_name)
	var ta := target_a.find_bone(anchor)
	var tb := target_b.find_bone(tip_name)
	if mini(mini(a, b), mini(ta, tb)) < 0:
		return
	var old_surface := _joint_world(source_a, a)
	var new_surface := _joint_world(target_a, ta)
	var wrist := _joint_world(source_b, b).origin
	var old_point := wrist
	var new_wrist := _joint_world(target_b, tb).origin
	var new_point := new_wrist
	var probe := String(rule.get("probe", ""))
	if not probe.is_empty():
		var source_probe := source_b.find_bone(probe)
		var target_probe := target_b.find_bone(probe)
		if mini(source_probe, target_probe) >= 0:
			old_point = _joint_world(source_b, source_probe).origin
			new_point = _joint_world(target_b, target_probe).origin
	var relative := old_surface.affine_inverse() * old_point
	var distance := old_point.distance_to(old_surface.origin)
	var near_distance := float(rule.get("near", 0.25))
	var far_distance := maxf(near_distance + 0.001, float(rule.get("far", 0.52)))
	var contact := (1.0 - smoothstep(near_distance, far_distance, distance)) * float(rule.get("weight", 1.0))
	if contact <= 0.0:
		return
	var desired_point := new_surface * (relative * contact_scale)
	var shift := maxf(0.0, float(rule.get("shift", 0.045)))
	if target_b == source_b:
		var receiver: Node3D = target_a.get_parent()
		receiver.global_position += ((old_point - desired_point) * contact).limit_length(shift)
		return
	if rule.get("move_root", false):
		var mover: Node3D = target_b.get_parent()
		mover.global_position += ((desired_point - new_point) * contact).limit_length(shift)
		return
	var goal := target_b.to_local(desired_point - (new_point - new_wrist))
	var upper := target_b.find_bone(upper_name)
	var lower := target_b.find_bone(bend_name)
	var source_elbow := source_b.find_bone(bend_name)
	var source_upper := source_b.find_bone(upper_name)
	if mini(mini(upper, lower), mini(source_elbow, source_upper)) < 0:
		return
	var elbow := target_b.global_basis.inverse() * (_joint_world(source_b, source_elbow).origin - _joint_world(source_b, source_upper).origin)
	var wrist_rotation := target_b.get_bone_global_pose(tb).basis.orthonormalized().get_rotation_quaternion()
	Pose.reach_chain(target_b, upper, lower, tb, goal, contact, elbow)
	var parent := target_b.get_bone_parent(tb)
	var new_parent := target_b.get_bone_global_pose(parent).basis.orthonormalized().get_rotation_quaternion()
	target_b.set_bone_pose_rotation(tb, (new_parent.inverse() * wrist_rotation).normalized())


func preserve_landmarks(lying_role: bool) -> void:
	for side: String in ["L", "R"]:
		_preserve_endpoint("cf_j_thigh00_" + side, "cf_j_leg01_" + side, "cf_j_foot_" + side, 0.85 if lying_role else 0.75)
		if lying_role or side == "L":
			_preserve_endpoint("cf_j_arm00_" + side, "cf_j_forearm01_" + side, "cf_j_hand_" + side, 0.85)


func _preserve_endpoint(start: String, bend: String, end: String, amount: float) -> void:
	var upper := rig.find_bone(start)
	var middle := rig.find_bone(bend)
	var tip := rig.find_bone(end)
	var source_upper := source.find_bone(start)
	var source_middle := source.find_bone(bend)
	var source_tip := source.find_bone(end)
	if mini(mini(upper, middle), mini(source_upper, source_middle)) < 0 or mini(tip, source_tip) < 0:
		return
	var goal := rig.to_local(_joint_world(source, source_tip).origin)
	var pole := rig.global_basis.inverse() * (_joint_world(source, source_middle).origin - _joint_world(source, source_upper).origin)
	var orientation := rig.get_bone_global_pose(tip).basis.orthonormalized().get_rotation_quaternion()
	Pose.reach_chain(rig, upper, middle, tip, goal, amount, pole)
	var parent := rig.get_bone_parent(tip)
	var parent_rotation := rig.get_bone_global_pose(parent).basis.orthonormalized().get_rotation_quaternion()
	rig.set_bone_pose_rotation(tip, (parent_rotation.inverse() * orientation).normalized())


static func _joint_world(rig_node: Skeleton3D, joint: int) -> Transform3D:
	var pose := rig_node.global_transform * rig_node.get_bone_global_pose(joint)
	return pose.orthonormalized()


static func _hip_extent(model: Node3D, skeleton: Skeleton3D) -> Vector3:
	var body := model.get_node_or_null("o_body_a") as MeshInstance3D
	if body and body.mesh and body.mesh.get_surface_count() > 0:
		var skin: Skin = body.get_meta("studio_source_skin", body.skin)
		if skin:
			var waist := skeleton.find_bone(WAIST)
			for i in range(skin.get_bind_count()):
				if skin.get_bind_bone(i) != waist:
					continue
				var bind := skin.get_bind_pose(i)
				var vertices: PackedVector3Array = body.mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
				var radius := Vector3(0.04, 1.0, 0.04)
				for vertex in vertices:
					var local := bind * vertex
					if absf(local.y) < 0.095 and absf(local.x) < 0.28:
						radius.x = maxf(radius.x, absf(local.x))
						radius.z = maxf(radius.z, absf(local.z))
				if radius.x > 0.06:
					return radius
				break
	var left := skeleton.find_bone("cf_j_thigh00_L")
	var right := skeleton.find_bone("cf_j_thigh00_R")
	var width := 0.165
	if mini(left, right) >= 0:
		width = skeleton.get_bone_rest(left).origin.distance_to(skeleton.get_bone_rest(right).origin)
	return Vector3(maxf(width * 0.85, 0.04), 1.0, maxf(width * 0.68, 0.04))


func _hide_detached_finger_accessories() -> void:
	var claws := actor.get_node_or_null("claws") as MeshInstance3D
	if not claws or not claws.visible or not claws.mesh:
		return
	var bounds := claws.mesh.get_aabb()
	# Older captures can bake both sets of claws in one thin column away from the hands.
	if bounds.size.x < 0.06 and bounds.size.y > 0.4 and absf(bounds.position.x) > 0.25:
		claws.hide()
		skipped_accessories = 1
