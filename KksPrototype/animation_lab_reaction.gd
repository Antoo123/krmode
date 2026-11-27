extends RefCounted

const Face := preload("res://animation_lab_face.gd")
const Pose := preload("res://npc_pose.gd")
const DATA := "res://Content/F7/Reactions/reactions.json"
const AREA := [1, 1, 2, 2, 2, 2]
const EFFECTOR_BONES := ["cf_j_hips", "cf_j_shoulder_L", "cf_j_shoulder_R",
	"cf_j_thigh00_L", "cf_j_thigh00_R", "cf_j_hand_L", "cf_j_hand_R", "cf_j_foot_L", "cf_j_foot_R"]

var profile := {}
var face := Face.new()
var table := {}
var actor: Node3D
var rig: Skeleton3D
var before := {}
var pose_id := -1
var base_state := "Idle"
var live_state := ""
var zone := -1
var action_id := -1
var motion := ""
var time := 0.0
var elapsed := 0.0
var blend := 0.0
var hold := 0.0
var phase_name := "Idle"
var look_id := -1
var face_id := -1
var face_from := {}
var face_mix := 1.0
var action_drag := -1
var hit_key := ""
var hit := {}
var hit_group := {}
var strengths := {}
var hit_offset := 0.0
var fader := 0.0
var neck_angles := Vector2.ZERO
var eye_angles := Vector2.ZERO
var blink_open := 1.0
var contact_mix := preload("res://pov_contact_reaction.gd").new()


func setup(npc: Node3D, id: int, state: String) -> void:
	if npc == actor and id == pose_id and state == base_state:
		return
	reset()
	if pose_id != id or npc != actor:
		time = 0.0
		neck_angles = Vector2.ZERO
		eye_angles = Vector2.ZERO
	if not npc or id < 0:
		actor = null
		rig = null
		face.surfaces.clear()
		pose_id = -1
		table = {}
		return
	if profile.is_empty():
		var decoded: Variant = JSON.parse_string(FileAccess.get_file_as_string(DATA))
		if not decoded is Dictionary:
			return
		profile = decoded
	if npc != actor:
		face.bind_actor(npc, profile.faces)
	actor = npc
	rig = actor.get_node("Skeleton") as Skeleton3D
	pose_id = id
	table = profile.poses.get(str(id), {})
	base_state = state if not state.is_empty() else "Idle"
	face_id = _idle_face()
	face_from = {face_id: 1.0}


func begin(selected_zone: int, rule: Dictionary, clip: String) -> void:
	if table.is_empty():
		return
	zone = selected_zone
	action_id = int(rule.id)
	action_drag = int(rule.actionDrag)
	motion = clip
	hit_key = "%s/%d" % [base_state, AREA[zone]]
	hit = table.reactions.get(hit_key, {})
	hit_group = {}
	if not hit.is_empty() and not hit.lstParam.is_empty():
		var param: Dictionary = hit.lstParam[(zone % 2) % hit.lstParam.size()]
		hit_group = profile.effectors.get(str(int(param.id)), {})
		hit_group = {"group": hit_group, "ranges": param.lstMinMax}
	elapsed = 0.0


func advance(hands: Node3D, camera_position: Vector3, delta: float,
		contacts: Array[Dictionary] = [], contact_mode := 0) -> void:
	if table.is_empty():
		return
	time += delta
	for contact in contacts:
		if contact.kind in ["foot", "ankle"]:
			contact.foot_curve = _foot_curve(contact)
	contact_mix.advance(rig, contacts, contact_mode, delta)
	var active: bool = zone >= 0 and hands.tool_id >= 0
	hold = float(hands.body_weight) if active else 0.0
	if active and hold > 0.0:
		elapsed += delta
	var touching := active and hold > 0.0
	var ending: bool = zone >= 0 and not hands.running
	var face_target := 1.0 if touching and not ending else 0.0
	blend = move_toward(blend, face_target, delta / (0.15 if face_target > blend else 0.28))
	if ending and not touching and is_zero_approx(blend):
		zone = -1
		motion = ""
		hit_group = {}
		hit = {}
		hit_key = ""
	phase_name = "Idle"
	if zone >= 0:
		if ending:
			phase_name = "Contact End"
		elif touching:
			phase_name = "Contact Start" if elapsed < 0.22 else "Contact Loop"
		else:
			phase_name = "Approach"
	var hand_target: Vector3 = hands.target.origin if touching else camera_position
	_update_look(camera_position, hand_target, delta)
	var target := _idle_face()
	if touching and not ending:
		target = int(profile.short.get("6", target)) if elapsed < 0.25 else int(profile.breath.get(_contact_state(false), target))
	if contact_mix.face_strength > 0.22 and not touching:
		var group := contact_mix.face_group
		if group.is_empty():
			group = "A" if contact_mix.lead_kind in ["foot", "ankle", "thigh"] else "M"
		target = int(profile.short.get("6", target)) if contact_mix.started else int(profile.breath.get(group + "_Idle", target))
		if profile.faces.has(str(contact_mix.face_preset)):
			target = contact_mix.face_preset
	if target != face_id:
		face_from = _face_weights()
		face_id = target
		face_mix = 0.0
	face_mix = move_toward(face_mix, 1.0, delta / 0.15)


func _foot_curve(contact: Dictionary) -> float:
	var moving := String(contact.style).begins_with("stroke")
	var id := (8 if contact.side == "L" else 10) + int(moving)
	var side := "Left" if contact.side == "L" else "Right"
	var group: Dictionary = profile.effectors.get(str(id), {})
	for point: Dictionary in group.get("points", []):
		if point.name == side + " Foot":
			var elapsed := float(contact.time)
			return clampf(_curve(point.force, elapsed) * smoothstep(0.0, maxf(0.01, point.fade), elapsed), -1.0, 1.0)
	return 0.0


func restore_pose() -> void:
	if is_instance_valid(rig):
		for id: int in before:
			var pose: Transform3D = before[id]
			rig.set_bone_pose_position(id, pose.origin)
			rig.set_bone_pose_rotation(id, pose.basis.orthonormalized().get_rotation_quaternion())
	before.clear()


func reset() -> void:
	contact_mix.reset()
	restore_pose()
	face.reset()
	zone = -1
	action_id = -1
	action_drag = -1
	live_state = ""
	hit_key = ""
	hit = {}
	hit_group = {}
	motion = ""
	phase_name = "Idle"
	elapsed = 0.0
	blend = 0.0
	hold = 0.0
	fader = 0.0
	hit_offset = 0.0
	look_id = -1
	face_id = _idle_face() if not table.is_empty() else -1
	face_from = {face_id: 1.0}
	face_mix = 1.0
	blink_open = 1.0
	neck_angles = Vector2.ZERO
	eye_angles = Vector2.ZERO


func apply() -> void:
	if table.is_empty() or not is_instance_valid(rig):
		return
	_apply_hit()
	var neck := neck_angles + contact_mix.gaze * 0.28
	_rotate("cf_j_neck", neck * 0.4)
	_rotate("cf_j_head", neck * 0.6)
	for side in ["L", "R"]:
		_rotate("cf_J_hitomi_tx_" + side, (eye_angles + contact_mix.gaze * 0.65).limit_length(14.0))
	for bone: String in contact_mix.angles:
		var id := rig.find_bone(bone)
		if id >= 0:
			_save(id)
			var rotation := Quaternion.from_euler(Vector3(contact_mix.angles[bone]) * (PI / 180.0))
			rig.set_bone_pose_rotation(id, (rig.get_bone_pose_rotation(id) * rotation).normalized())
	_apply_cheeks()
	face.apply(profile.faces, face_id, _face_weights(), blink_open)


func _apply_cheeks() -> void:
	var head := rig.find_bone("cf_j_head")
	if head < 0:
		return
	var frame := rig.get_bone_global_pose(head).basis.orthonormalized() * rig.get_bone_global_rest(head).basis.orthonormalized().inverse()
	for side in ["L", "R"]:
		var strength := float(contact_mix.cheek_offsets.get(side, 0.0))
		if strength < 0.001:
			continue
		var axis := -1.0 if side == "L" else 1.0
		for prefix in ["cf_J_CheekLow_s_", "cf_J_CheekUp_s_", "cf_J_CheekUp2_"]:
			var joint := rig.find_bone(prefix + side)
			if joint < 0:
				continue
			var parent := rig.get_bone_parent(joint)
			if parent < 0:
				continue
			var offset := frame * Vector3(axis * 0.0045, 0.0010, -0.0012) * strength
			if prefix != "cf_J_CheekLow_s_":
				offset *= 0.48
			_save(joint)
			rig.set_bone_pose_position(joint, rig.get_bone_pose_position(joint) +
				rig.get_bone_global_pose(parent).basis.inverse() * offset)


func _face_weights() -> Dictionary:
	if face_mix >= 1.0:
		return {face_id: 1.0}
	var amount := smoothstep(0.0, 1.0, face_mix)
	var weights := {}
	for key: int in face_from:
		var value := float(face_from[key]) * (1.0 - amount)
		if value > 0.0001:
			weights[key] = value
	weights[face_id] = weights.get(face_id, 0.0) + amount
	return weights


func _idle_face() -> int:
	return int(profile.breath.get(base_state, profile.breath.Idle))


func _contact_state(start: bool) -> String:
	if base_state.begins_with("A_") or base_state.begins_with("M_") or base_state.begins_with("S_"):
		return base_state.left(2) + ("Touch" if start else "Idle")
	if action_drag < 0:
		return base_state
	return "M_Touch" if start else "M_Idle"


func _update_look(camera_position: Vector3, hand_target: Vector3, delta: float) -> void:
	var look_state := base_state
	if not live_state.is_empty():
		look_state = live_state
	elif blend > 0.0 and zone >= 0:
		look_state = _contact_state(elapsed < 0.22)
	var row: Dictionary = table.look.get(look_state, {})
	if row.is_empty() or not is_instance_valid(rig):
		return
	look_id = int(row.idEyeNeckNoVoice) if int(row.idEyeNeckNoVoice) >= 0 else int(row.idEyeNecks[0])
	var preset: Dictionary = profile.look.get(str(look_id), {})
	if preset.is_empty():
		return
	var head := rig.find_bone("cf_j_head")
	if head < 0:
		return
	var frame := rig.global_transform * rig.get_bone_global_pose(head)
	frame.basis = frame.basis.orthonormalized()
	var neck := Vector2.ZERO
	var eyes := Vector2.ZERO
	# Animation-dependent behaviour keeps the neck track. A tracked target in
	# POV is the camera, or the hand when the source requests a fixed target.
	match int(preset.behaviour):
		1, 2, 4, 5, 6, 7, 8:
			neck = _angles(frame, camera_position if int(preset.targetNeck) <= 1 else hand_target, row.rangeNeck)
		9, 10, 11:
			neck = Vector2.ZERO
	match int(preset.behaviour):
		1, 2, 4, 5, 6, 7, 10:
			eyes = _angles(frame, camera_position if int(preset.targetEye) <= 1 else hand_target, row.rangeFace)
		3, 8, 11:
			eyes = -_angles(frame, camera_position, row.rangeFace) * 0.45
	neck = neck.limit_length(30.0 if live_state.is_empty() else 10.0)
	neck_angles = neck_angles.lerp(neck * float(preset.rateNeck) * blend, 1.0 - exp(-10.0 * delta))
	eyes = (eyes * float(preset.rateEye) - neck_angles).limit_length(13.0)
	eye_angles = eye_angles.lerp(eyes * blend, 1.0 - exp(-14.0 * delta))
	var selected: Dictionary = profile.faces.get(str(face_id), {})
	var blink := fposmod(time, 4.0)
	blink_open = 1.0
	if selected.get("eyesblink", false):
		blink_open -= smoothstep(0.0, 0.085, blink) * (1.0 - smoothstep(0.09, 0.19, blink))


func _angles(frame: Transform3D, point: Vector3, limits: Dictionary) -> Vector2:
	var local := frame.affine_inverse() * point
	var yaw := rad_to_deg(atan2(-local.x, -local.z))
	var pitch := rad_to_deg(atan2(local.y, Vector2(local.x, local.z).length()))
	return Vector2(clampf(yaw, limits.left, limits.right), clampf(pitch, -float(limits.down), -float(limits.up)))


func _rotate(name: String, angles: Vector2) -> void:
	var id := rig.find_bone(name)
	if id >= 0 and angles.length_squared() > 0.00001:
		_save(id)
		var delta := Quaternion.from_euler(Vector3(deg_to_rad(angles.y), deg_to_rad(angles.x), 0.0))
		rig.set_bone_pose_rotation(id, (rig.get_bone_pose_rotation(id) * delta).normalized())


func _apply_hit() -> void:
	hit_offset = 0.0
	fader = 0.0
	strengths.clear()
	if hit_group.is_empty() or elapsed <= 0.0 or hold <= 0.0:
		return
	var points: Array = hit_group.group.get("points", [])
	var ranges: Array = hit_group.ranges
	for index in mini(points.size(), ranges.size()):
		var point: Dictionary = points[index]
		var limit: Dictionary = ranges[index]
		var force := _vector(limit.min).lerp(_vector(limit.max), 0.8).normalized()
		var weight := float(hit.weight) * smoothstep(0.0, maxf(point.fade, 0.001), elapsed) * hold
		var offset := (force * _curve(point.force, elapsed) + Vector3.UP * _curve(point.up, elapsed)) * weight
		for link: Array in point.links:
			var id := int(link[0])
			strengths[id] = strengths.get(id, Vector3.ZERO) + offset * float(link[1])
		if offset.length_squared() > 0.00000001:
			fader = maxf(fader, weight)
	for id: int in strengths:
		var offset: Vector3 = strengths[id]
		hit_offset = maxf(hit_offset, offset.length())
	if hit_offset <= 0.00001:
		return
	_apply_effectors()


func _apply_effectors() -> void:
	var endpoints := {}
	for id in range(5, 9):
		if not id in hit.lstReleaseEffector:
			var bone := rig.find_bone(EFFECTOR_BONES[id])
			if bone >= 0:
				endpoints[id] = rig.get_bone_global_pose(bone).origin + strengths.get(id, Vector3.ZERO)
	for id in range(5):
		var offset: Vector3 = strengths.get(id, Vector3.ZERO)
		var bone := rig.find_bone(EFFECTOR_BONES[id])
		if bone >= 0 and not offset.is_zero_approx():
			_save(bone)
			var parent := rig.get_bone_parent(bone)
			rig.set_bone_pose_position(bone, rig.get_bone_pose_position(bone)
				+ rig.get_bone_global_pose(parent).basis.inverse() * offset)
	for id: int in endpoints:
		var side := "L" if id % 2 == 1 else "R"
		var names := ["cf_j_arm00_", "cf_j_forearm01_"] if id < 7 else ["cf_j_thigh00_", "cf_j_leg01_"]
		_reach(names[0] + side, names[1] + side, EFFECTOR_BONES[id], endpoints[id])


func _reach(upper: String, lower: String, end: String, target: Vector3) -> void:
	var a := rig.find_bone(upper)
	var b := rig.find_bone(lower)
	var c := rig.find_bone(end)
	if mini(a, mini(b, c)) < 0:
		return
	var from := rig.get_bone_global_pose(a).origin
	var tip := rig.get_bone_global_pose(c).origin
	if tip.distance_squared_to(target) < 0.00000001:
		return
	var hint := rig.get_bone_global_pose(b).origin - (from + tip) * 0.5
	_save(a)
	_save(b)
	Pose.reach_chain(rig, a, b, c, target, 1.0, hint)


func _save(id: int) -> void:
	if not before.has(id):
		before[id] = rig.get_bone_pose(id)


static func _vector(value: Dictionary) -> Vector3:
	return Vector3(value.x, value.y, -float(value.z))


static func _curve(keys: Array, time_sec: float) -> float:
	if keys.is_empty() or time_sec >= float(keys[-1][0]):
		return 0.0
	for index in range(1, keys.size()):
		var b: Array = keys[index]
		if time_sec <= float(b[0]):
			var a: Array = keys[index - 1]
			var span := float(b[0]) - float(a[0])
			var t := clampf((time_sec - float(a[0])) / span, 0.0, 1.0)
			return cubic_interpolate(float(a[1]), float(b[1]),
				float(b[1]) - 2.0 * span * float(a[3]), float(a[1]) + 2.0 * span * float(b[2]), t)
	return 0.0
