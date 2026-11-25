extends RefCounted

const Pose := preload("res://npc_pose.gd")
const Card := preload("res://card_model.gd")
const KISS_APPROACH := 0.92
const KISS_HOLD_UNTIL := 2.4
const KISS_RETREAT := 0.72
const KISS_POSTURES := ["standing", "behind", "stand_spread", "skirt"]
const MOUTH_APPROACH := 1.06
const MOUTH_RETREAT := 0.82

# Each pose marks a change of intent. Channels are lean, turn, and shoulder lead.
const CHEEK_HOLD := [
	Vector4(0.00, 0.00, 0.00, 0.00), Vector4(0.64, 0.52, 0.78, 0.46),
	Vector4(1.32, 0.82, 0.24, 0.66), Vector4(2.18, -0.48, -0.63, -0.34),
	Vector4(2.79, -0.16, -0.50, -0.17), Vector4(3.46, 0.94, 0.88, -0.27),
	Vector4(4.56, 0.34, 0.54, 0.58), Vector4(5.14, 0.02, -0.38, 0.10),
	Vector4(5.94, -0.38, -0.11, -0.48),
]
const BELLY_HOLD := [
	Vector4(0.00, 0.00, 0.00, 0.00), Vector4(0.82, 0.79, -0.37, 0.73),
	Vector4(1.64, 0.58, 0.44, 0.23), Vector4(2.44, -0.60, 0.30, -0.56),
	Vector4(3.00, -0.51, -0.14, -0.35), Vector4(3.64, 0.97, -0.61, 0.54),
	Vector4(4.57, 0.38, -0.31, 0.79), Vector4(5.17, -0.16, 0.68, 0.25),
	Vector4(5.94, -0.50, 0.10, -0.39),
]
const GROIN_HOLD := [
	Vector4(0.00, 0.00, 0.00, 0.00), Vector4(0.62, 0.74, 0.37, 0.52),
	Vector4(1.36, -0.38, 0.68, 0.24), Vector4(2.40, -0.65, -0.36, -0.62),
	Vector4(3.03, -0.12, -0.59, 0.15), Vector4(3.83, 0.84, -0.15, 0.68),
	Vector4(4.29, 0.52, 0.48, 0.25), Vector4(5.12, 0.24, 0.28, -0.31),
	Vector4(5.94, -0.50, -0.31, -0.54),
]

var game: Node3D
var state: Dictionary = {}


func _init(owner: Node3D) -> void:
	game = owner


func active() -> bool:
	return not state.is_empty()


func seated() -> bool:
	return state.get("kind", "") in ["seat_prone", "seat_supine"]


func kissing() -> bool:
	return state.get("kind", "") == "kiss"


func smooth_approach() -> bool:
	return state.get("kind", "") in ["kiss", "mouth"]


func approach_exit_weight() -> float:
	var duration := KISS_RETREAT if kissing() else MOUTH_RETREAT
	return Pose.smooth((state.time - state.ending) / duration) if state.ending >= 0.0 else 0.0


func begin(entry: Dictionary, kind: String, zone := "", button := 0) -> bool:
	if entry.is_empty() or active() or not game.contact.state.is_empty():
		return false
	var actor: Node3D = game.actor_for(entry)
	var body: CharacterBody3D = game.body_for(entry)
	if not actor or not body:
		return false
	var posture: String = entry.get("posture", {}).get("kind", "standing")
	if (kind == "seat_prone" and posture != "lie_stomach") or (kind == "seat_supine" and posture != "lie_back") or (kind == "shoe" and posture != "fours"):
		return false
	var npc_rig: Skeleton3D = actor.get_node("Skeleton")
	var player: Node3D = game.room.player_model
	var player_rig: Skeleton3D = player.get_node("Skeleton")
	if kind == "kiss" and (posture not in KISS_POSTURES
			or not can_kiss(npc_rig) or not can_kiss(player_rig)):
		return false
	if kind == "mouth" and (not can_kiss(player_rig) or game.contact.zone_anchor(npc_rig, zone).is_empty()):
		return false
	var npc_anim: AnimationPlayer = game.animator_for(entry)
	state = {"kind": kind, "zone": zone, "button": button, "entry": entry, "actor": actor,
		"body": body, "npc": npc_rig, "player": player_rig, "player_model": player,
		"npc_pose": Pose.capture(npc_rig), "player_pose": Pose.capture(player_rig),
		"player_yaw": player.rotation.y, "npc_yaw": actor.rotation.y, "origin": game.room.player.global_position,
		"time": 0.0, "ending": -1.0, "npc_anim": npc_anim, "resume": npc_anim.is_playing(),
		"face": entry.get("face_speaker", false), "surface": {}, "effects": []}
	entry.face_speaker = false
	game.player_view.restore()
	game.room.player.add_collision_exception_with(body)
	game.room.player_anim.pause()
	npc_anim.pause()
	if kind == "kiss":
		prepare_kiss()
	if kind == "mouth":
		prepare_mouth()
	if kind == "shoe":
		var rows: Array = game.animation_groups.get("fours", [])
		if not rows.is_empty():
			state.crawl = Card.animation(game.room.motion_path(rows[0].id), npc_rig)
	if kind == "shoe":
		state.tongue = effect(Vector3(0.035, 0.115, 0.036), Color("#bd5263"), true)
		state.traces = []
		for i in range(3):
			state.traces.append(effect(Vector3(0.011 + i * 0.003, 0.003, 0.019), Color(0.83, 0.93, 0.98, 0.45), false))
	return true


func release(button: int) -> void:
	if active() and not seated() and state.kind == "mouth" and state.button == button and state.ending < 0.0:
		state.ending = state.time


func leave_seat() -> void:
	if seated() and state.ending < 0.0:
		game.contact.release()
		state.ending = state.time


func cancel() -> void:
	if smooth_approach():
		if state.ending < 0.0:
			state.ending = state.time
	else:
		stop()


func stop() -> void:
	if not active():
		return
	if not game.contact.state.is_empty():
		game.contact.end()
	var player: CharacterBody3D = game.room.player
	if is_instance_valid(state.body):
		player.remove_collision_exception_with(state.body)
	if is_instance_valid(state.player_model) and game.room.player_model == state.player_model:
		if not smooth_approach():
			player.global_position = state.origin
		player.velocity = Vector3.ZERO
		state.player_model.rotation.y = state.player_yaw
		Pose.blend(state.player, state.player_pose, state.player_pose, 1.0)
		if smooth_approach() and game.dialogue.visible and game.room.player_anim.has_animation("ConversationIdle"):
			game.room.player_anim.play("ConversationIdle", 0.20)
		else:
			game.play_rest(game.room.player_anim)
	if is_instance_valid(state.actor):
		game.contact.set_blush(state.actor, 0.0)
		state.actor.rotation.y = state.npc_yaw
		Pose.blend(state.npc, state.npc_pose, state.npc_pose, 1.0)
		state.entry.face_speaker = state.face
		if state.resume and not state.entry.has("posture"):
			state.npc_anim.play()
	if state.has("original_tongue_mesh") and is_instance_valid(state.tongue):
		state.tongue.mesh = state.original_tongue_mesh
	for item: MeshInstance3D in state.effects:
		var receiver = state.player_model if state.kind == "shoe" else state.actor
		if item.get_meta("has_contact", false) and is_instance_valid(receiver):
			item.reparent(receiver, true)
			item.show()
			var material := item.material_override as StandardMaterial3D
			var transparent := material.albedo_color
			transparent.a = 0.0
			var fade := item.create_tween()
			fade.tween_property(material, "albedo_color", transparent, 1.35).set_delay(0.65)
			fade.tween_callback(item.queue_free)
		else:
			item.queue_free()
	state.clear()


func allows(id: String) -> bool:
	if not active():
		return true
	if state.time < 0.78 or state.ending >= 0.0:
		return false
	if state.kind == "seat_prone":
		return id.begins_with("seat")
	if state.kind == "seat_supine":
		return id.begins_with("chest") or id.begins_with("hip") or id == "lap"
	return false


func tick(delta: float) -> void:
	if not active():
		return
	if not is_instance_valid(state.actor) or not is_instance_valid(state.player_model) or game.actor_for(state.entry) != state.actor or game.room.player_model != state.player_model:
		stop()
		return
	state.time += delta
	var time: float = state.time
	if kissing():
		if time >= KISS_HOLD_UNTIL and state.ending < 0.0:
			cancel()
		kiss_tick(delta)
		return
	if state.kind == "mouth":
		if time >= 7.0:
			cancel()
		mouth_tick(delta)
		return
	if seated():
		var settled := Pose.smooth(time / 0.92)
		if state.ending >= 0.0:
			settled *= 1.0 - Pose.smooth((time - state.ending) / 0.68)
			if settled <= 0.0:
				stop()
				if game.dialogue.visible:
					game.rebuild_posture_buttons()
				return
		seat_tick(delta, settled)
		return
	if time >= 5.6 and state.ending < 0.0:
		state.ending = time
	var retreat := 1.0 if state.ending < 0.0 else 1.0 - Pose.smooth((time - state.ending) / 0.48)
	if retreat <= 0.0:
		stop()
		if game.dialogue.visible:
			game.rebuild_posture_buttons()
		return
	shoe_tick(delta, retreat)


func seat_tick(delta: float, weight: float) -> void:
	var npc: Skeleton3D = state.npc
	var rig: Skeleton3D = state.player
	var prone: bool = state.kind == "seat_prone"
	var chest: Vector3 = joint(npc, "cf_j_spine03")
	var hips: Vector3 = joint(npc, "cf_j_hips")
	var direction := Vector3(chest.x - hips.x, 0, chest.z - hips.z).normalized()
	if direction.is_zero_approx():
		direction = Vector3.FORWARD
	var across := direction.cross(Vector3.UP).normalized()
	var center := hips.lerp(chest, 0.53)
	var goal := center + across * (0.13 if prone else 0.03)
	place_player(state.origin.lerp(goal, weight), delta)
	var facing := across if prone else direction
	state.player_model.rotation.y = lerp_angle(state.player_yaw, atan2(-facing.x, -facing.z), weight)
	if not game.contact.state.is_empty():
		return
	Pose.blend(rig, state.player_pose, state.player_pose, 1.0)
	var hip := rig.find_bone("cf_j_hips")
	if hip >= 0:
		var waist := rig.get_bone_global_pose(hip).origin
		var target := rig.to_local(center + Vector3.UP * (0.17 if prone else 0.145))
		game.contact.shift_bone(rig, "cf_j_hips", (target - waist) * weight)
		for side in ["L", "R"]:
			var sign_x := -1.0 if side == "L" else 1.0
			var thigh := rig.find_bone("cf_j_thigh00_" + side)
			var knee := rig.find_bone("cf_j_leg01_" + side)
			var foot := rig.find_bone("cf_j_foot_" + side)
			var goal_foot := center + (across * 0.37 + direction * sign_x * 0.15 if prone else across * sign_x * 0.32 - direction * 0.13)
			goal_foot.y = game.room.player.global_position.y + 0.07
			Pose.reach_chain(rig, thigh, knee, foot, rig.to_local(goal_foot), weight, Vector3(sign_x * 0.6, 0.95, -0.45))


func shoe_tick(delta: float, retreat: float) -> void:
	var npc: Skeleton3D = state.npc
	var player: Skeleton3D = state.player
	var forward: Vector3 = -state.player_model.global_basis.z.normalized()
	var foot := joint(player, "cf_j_foot_R") + forward * 0.08 + Vector3.UP * 0.018
	var mouth: Dictionary = game.contact.zone_anchor(npc, "lips")
	if mouth.is_empty():
		return
	var direction: Vector3 = foot - Vector3(mouth.point)
	direction.y = 0.0
	var approach := Pose.smooth(state.time / 0.34) * Pose.smooth((2.46 - state.time) / 0.54)
	if direction.length() > 0.21 and approach > 0.0:
		var body: CharacterBody3D = state.body
		game.move_body(body, direction.normalized() * 0.44 * approach, delta)
		state.actor.rotation.y = lerp_angle(state.actor.rotation.y, atan2(-direction.x, -direction.z), 0.14)
		var clip: Animation = state.get("crawl")
		if clip:
			var pose := Pose.sample(clip, npc, state.npc_pose, fposmod(state.time * 0.78, maxf(clip.length, 0.01)))
			var hip := npc.find_bone("cf_j_hips")
			if hip >= 0:
				pose[hip] = state.npc_pose[hip]
			Pose.blend(npc, state.npc_pose, pose, approach * 0.82)
	var weight := Pose.smooth((state.time - 1.70) / 0.46) * retreat
	if weight > 0.0:
		aim_mouth(npc, foot, weight, true)
		var gap := npc.to_local(foot) - npc.to_local(joint(npc, "cf_J_MouthLow"))
		game.contact.shift_bone(npc, "cf_j_spine02", gap.limit_length(0.07) * weight)
		mouth_effect(npc, foot, Vector3.UP, weight)


func can_kiss(rig: Skeleton3D) -> bool:
	for bone in ["cf_j_spine01", "cf_j_spine03", "cf_j_neck", "cf_j_head", "cf_J_MouthLow"]:
		if rig.find_bone(bone) < 0:
			return false
	return true


func prepare_kiss() -> void:
	var npc: Skeleton3D = state.npc
	var player: Skeleton3D = state.player
	state.npc_lip = kiss_lip_offset(npc)
	state.player_lip = kiss_lip_offset(player)
	var direction: Vector3 = state.actor.global_position - state.origin
	direction.y = 0.0
	direction = direction.normalized() if direction.length_squared() > 0.01 else -player.global_basis.z.normalized()
	var yaw := atan2(-direction.x, -direction.z)
	state.kiss_yaw = yaw + deg_to_rad(6.0)
	state.partner_yaw = yaw + PI - deg_to_rad(6.0)
	state.player_model.rotation.y = state.kiss_yaw
	state.actor.rotation.y = state.partner_yaw
	var height := kiss_lip(player, state.player_lip).y - kiss_lip(npc, state.npc_lip).y
	var pitch := clampf(-height * 0.66, -0.19, 0.19)
	var face := (direction + Vector3.UP * pitch).normalized()
	kiss_pose(player, face, state.player_pose, 15.0 + clampf(height * 24.0, 0.0, 7.0), true)
	kiss_pose(npc, -face, state.npc_pose, 15.0 + clampf(-height * 24.0, 0.0, 7.0),
		not state.entry.get("posture", {}).get("kind", "") in ["behind", "skirt"])
	state.player_contact = Pose.capture(player)
	state.npc_contact = Pose.capture(npc)
	# Bend the taller character's knees after the lean and head turns establish lip height.
	height = kiss_lip(player, state.player_lip).y - kiss_lip(npc, state.npc_lip).y
	state.player_drop = maxf(height, 0.0)
	state.npc_drop = maxf(-height, 0.0)
	if height > 0.002:
		state.player_contact = game.contact.planted_crouch(player, state.player_contact,
			clampf(height / player.global_basis.y.length(), 0.0, 0.49), minf(height * 0.38, 0.095))
		Pose.blend(player, state.player_pose, state.player_contact, 1.0)
	elif height < -0.002:
		state.npc_contact = game.contact.planted_crouch(npc, state.npc_contact,
			clampf(-height / npc.global_basis.y.length(), 0.0, 0.49), minf(-height * 0.38, 0.095))
		Pose.blend(npc, state.npc_pose, state.npc_contact, 1.0)
	var correction := kiss_lip(npc, state.npc_lip) - kiss_lip(player, state.player_lip)
	# Leave a small clearance at the skin surface. Opposite head rolls separate the noses.
	correction -= direction * 0.004
	correction.y = 0.0
	state.kiss_goal = Vector3(state.origin) + correction
	state.landed_feet = kiss_feet(player)
	var across := direction.cross(Vector3.UP)
	for side: String in state.landed_feet:
		var foot: Transform3D = state.landed_feet[side]
		var outward := -1.0 if side == "L" else 1.0
		foot.origin += across * outward * clampf(height * 0.32, 0.0, 0.065)
		foot.origin -= direction * clampf(height * 0.52, 0.0, 0.105)
		state.landed_feet[side] = foot
	state.player_model.rotation.y = state.player_yaw
	state.actor.rotation.y = state.npc_yaw
	Pose.blend(player, state.player_pose, state.player_pose, 1.0)
	Pose.blend(npc, state.npc_pose, state.npc_pose, 1.0)
	state.start_feet = kiss_feet(player)
	state.npc_feet = kiss_feet(npc)


func kiss_lip_offset(rig: Skeleton3D) -> Vector3:
	var bone := rig.find_bone("cf_J_MouthLow")
	var anchor: Dictionary = game.contact.zone_anchor(rig, "lips")
	var point: Vector3 = anchor.point
	var normal: Vector3 = anchor.normal
	# Measure only the face at the lip landmark. Accessories cannot move this target.
	if DisplayServer.get_name() != "headless":
		for child in rig.get_parent().get_children():
			var part := child as MeshInstance3D
			if not part or part.name.to_lower() != "cf_o_face" or not part.skin:
				continue
			var skin := part.bake_mesh_from_current_skeleton_pose()
			if not skin:
				break
			var start := part.to_local(point + normal * 0.032)
			var ray := (part.global_basis.inverse() * -normal).normalized()
			var closest := 0.060
			for surface in range(skin.get_surface_count()):
				var arrays := skin.surface_get_arrays(surface)
				var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
				var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
				for i in range(0, indices.size(), 3):
					var hit = Geometry3D.ray_intersects_triangle(start, ray, vertices[indices[i]],
						vertices[indices[i + 1]], vertices[indices[i + 2]])
					if hit != null:
						var distance := start.distance_to(hit)
						if distance < closest:
							closest = distance
							point = part.to_global(hit)
			break
	return rig.get_bone_global_pose(bone).affine_inverse() * rig.to_local(point)


func kiss_lip(rig: Skeleton3D, offset: Vector3) -> Vector3:
	return rig.to_global(rig.get_bone_global_pose(rig.find_bone("cf_J_MouthLow")) * offset)


func kiss_pose(rig: Skeleton3D, face: Vector3, rest: Array[Transform3D], lean: float, move_hands: bool) -> void:
	var lower := rig.find_bone("cf_j_spine01")
	var chest := rig.find_bone("cf_j_spine03")
	var neck := rig.find_bone("cf_j_neck")
	var head := rig.find_bone("cf_j_head")
	var forward := (rig.global_basis.inverse() * face).normalized()
	var up := (rig.global_basis.inverse() * Vector3.UP).normalized()
	var side := forward.cross(up).normalized()
	var bend := Quaternion(side, deg_to_rad(-lean))
	kiss_turn(rig, lower, Quaternion.IDENTITY.slerp(bend, 0.64))
	kiss_turn(rig, chest, Quaternion.IDENTITY.slerp(bend, 0.36))
	var upright := side.cross(forward).rotated(forward, deg_to_rad(24.0))
	var desired := Basis.looking_at(forward, upright)
	var head_rest := rig.get_bone_global_rest(head).basis.orthonormalized()
	var current := rig.get_bone_global_pose(head).basis.orthonormalized() * head_rest.inverse()
	var turn := (desired * current.inverse()).get_rotation_quaternion()
	kiss_turn(rig, neck, Quaternion.IDENTITY.slerp(turn, 0.46))
	current = rig.get_bone_global_pose(head).basis.orthonormalized() * head_rest.inverse()
	kiss_turn(rig, head, (desired * current.inverse()).get_rotation_quaternion())
	if not move_hands:
		return
	for hand_side in ["L", "R"]:
		var hand := rig.find_bone("cf_j_hand_" + hand_side)
		if hand < 0:
			continue
		var sign_x := -1.0 if hand_side == "L" else 1.0
		var wrist := rig.get_bone_global_pose(hand).origin
		var lead := 1.0 if hand_side == "R" else 0.55
		Pose.reach(rig, hand_side, wrist + forward * (0.083 * lead) + up * (0.042 * lead)
			+ Vector3.RIGHT * sign_x * 0.028, 1.0, Vector3(sign_x * 0.38, -0.40, 0.75))
		rig.set_bone_pose_rotation(hand, rest[hand].basis.get_rotation_quaternion()
			* Quaternion(Vector3.UP, sign_x * deg_to_rad(7.0)))


func kiss_turn(rig: Skeleton3D, bone: int, turn: Quaternion) -> void:
	var parent := rig.get_bone_global_pose(rig.get_bone_parent(bone)).basis.orthonormalized().get_rotation_quaternion()
	rig.set_bone_pose_rotation(bone, (parent.inverse() * turn * parent * rig.get_bone_pose_rotation(bone)).normalized())


func kiss_feet(rig: Skeleton3D) -> Dictionary:
	var feet := {}
	for side in ["L", "R"]:
		var foot := rig.find_bone("cf_j_foot_" + side)
		if foot >= 0:
			feet[side] = rig.global_transform * rig.get_bone_global_pose(foot)
	return feet


func kiss_foot(rig: Skeleton3D, side: String, world: Transform3D, drop: float) -> void:
	var thigh := rig.find_bone("cf_j_thigh00_" + side)
	var knee := rig.find_bone("cf_j_leg01_" + side)
	var foot := rig.find_bone("cf_j_foot_" + side)
	var local := rig.global_transform.affine_inverse() * world
	var outward := (0.32 + clampf(drop * 8.0, 0.0, 1.25)) * (-1.0 if side == "L" else 1.0)
	Pose.reach_chain(rig, thigh, knee, foot, local.origin, 1.0, Vector3(outward, 0.0, -1.0))
	var ankle := rig.get_bone_global_pose(foot)
	ankle.basis = local.basis
	rig.set_bone_global_pose(foot, ankle)


func kiss_tick(delta: float) -> void:
	var player: Skeleton3D = state.player
	var npc: Skeleton3D = state.npc
	var progress := minf(float(state.time) / KISS_APPROACH, 1.0)
	var retreating: bool = state.ending >= 0.0
	var exit := 0.0
	if retreating:
		var reached := minf(float(state.ending) / KISS_APPROACH, 1.0)
		exit = clampf((state.time - state.ending) / KISS_RETREAT, 0.0, 1.0)
		progress = reached * (1.0 - exit)
	var advance := Pose.smooth(progress)
	var lean := Pose.smooth((progress - 0.18) / 0.82)
	var goal: Vector3 = Vector3(state.origin).lerp(state.kiss_goal, advance)
	var body: CharacterBody3D = game.room.player
	body.velocity.y = -0.2 if body.is_on_floor() else body.velocity.y - 16.0 * delta
	place_player(goal, delta)
	state.player_model.rotation.y = lerp_angle(state.player_yaw, state.kiss_yaw, advance)
	state.actor.rotation.y = lerp_angle(state.npc_yaw, state.partner_yaw, lean)
	Pose.blend(player, state.player_pose, state.player_contact, lean)
	Pose.blend(npc, state.npc_pose, state.npc_contact, lean)
	var blocked: Vector3 = body.global_position - goal
	blocked.y = 0.0
	if progress > 0.0 and blocked.length_squared() < 0.012:
		var travel: Vector3 = state.kiss_goal - state.origin
		for side: String in state.start_feet:
			var first := clampf(progress / 0.58, 0.0, 1.0)
			var last := clampf((progress - 0.74) / 0.26, 0.0, 1.0)
			var second := clampf((progress - 0.25) / 0.68, 0.0, 1.0)
			var step := 0.62 * Pose.smooth(first) + 0.38 * Pose.smooth(last) if side == "L" else Pose.smooth(second)
			var lift := sin(PI * first) + 0.6 * sin(PI * last) if side == "L" else sin(PI * second)
			var landed: Transform3D = state.landed_feet[side]
			landed.origin += travel
			var foot: Transform3D = state.start_feet[side].interpolate_with(landed, step)
			foot.origin += Vector3.UP * lift * minf(travel.length() * 0.085, 0.055)
			kiss_foot(player, side, foot, state.player_drop * lean)
		for side: String in state.npc_feet:
			kiss_foot(npc, side, state.npc_feet[side], state.npc_drop * lean)
	elif not retreating and advance > 0.86:
		cancel()
	game.contact.set_blush(state.actor, lean * 0.27)
	if exit >= 1.0:
		stop()
		if game.dialogue.visible:
			game.rebuild_posture_buttons()


func prepare_mouth() -> void:
	var npc: Skeleton3D = state.npc
	var rig: Skeleton3D = state.player
	var target: Dictionary = game.contact.zone_anchor(npc, state.zone)
	var point: Vector3 = target.point
	var normal: Vector3 = target.normal
	var cheek: bool = state.zone.begins_with("cheek")
	var fabric := [] if cheek else ["Top", "Bra", "Bottom", "Underwear", "Tights"]
	var hit: Dictionary = game.contact.find_skin_hit(state.actor,
		{"origin": point + normal * 0.24, "ray": -normal, "depth": 0.24, "anchor": target}, fabric)
	if not hit.is_empty():
		var range_limit := 0.056 if cheek else 0.145
		if point.distance_to(hit.world) <= range_limit:
			var bone := npc.global_transform * npc.get_bone_global_pose(target.bone)
			state.mouth_surface = {"offset": bone.affine_inverse() * Vector3(hit.world),
				"normal": bone.basis.transposed() * Vector3(hit.normal), "part": hit.part,
				"triangle": game.contact.bind_contact_triangle(hit, state.actor, npc)}
	var surface: Dictionary = mouth_surface(npc)
	point = surface.point
	normal = surface.normal
	var away: Vector3 = target.normal
	away.y = 0.0
	if away.is_zero_approx():
		away = Vector3(state.origin) - point
		away.y = 0.0
	away = away.normalized() if not away.is_zero_approx() else Vector3.BACK
	var toward := -away
	state.start_feet = kiss_feet(rig)
	state.mouth_lip = kiss_lip_offset(rig)
	prepare_tongue(rig)
	state.mouth_yaw = atan2(away.x, away.z)
	state.player_model.rotation.y = state.mouth_yaw
	var scale := rig.global_basis.y.length()
	var height := kiss_lip(rig, state.mouth_lip).y - point.y
	var lean := clampf(height * 36.0 + (17.0 if cheek else 13.0), 12.0, 42.0)
	var pitch := 0.12 if cheek else (0.64 if state.zone == "belly" else 0.24)
	var face := (toward + Vector3.UP * pitch).normalized()
	var measured_out := Vector3(normal.x, 0.0, normal.z).normalized()
	if measured_out.dot(away) > 0.42:
		face = face.lerp(-measured_out, 0.30).normalized()
	orient_mouth(rig, face, lean)
	var clearance := (0.034 if state.zone == "belly" else 0.028) * scale
	var lip_goal := point + away * clearance
	var drop := kiss_lip(rig, state.mouth_lip).y - lip_goal.y
	var player_contact := Pose.capture(rig)
	state.npc_contact = state.npc_pose
	if drop < -0.005 and state.entry.get("posture", {}).get("kind", "standing") in KISS_POSTURES:
		state.npc_contact = game.contact.planted_crouch(npc, state.npc_pose,
			minf(-drop / npc.global_basis.y.length(), 0.23), 0.0)
		Pose.blend(npc, state.npc_pose, state.npc_contact, 1.0)
		surface = mouth_surface(npc)
		lip_goal = Vector3(surface.point) + away * clearance
		drop = kiss_lip(rig, state.mouth_lip).y - lip_goal.y
	var back := clampf(drop * 0.25, 0.0, 0.19)
	if drop > 0.005:
		player_contact = game.contact.planted_crouch(rig, player_contact, minf(drop / scale, 0.79), back)
		Pose.blend(rig, state.player_pose, player_contact, 1.0)
	state.player_contact = player_contact
	state.mouth_drop = maxf(drop, 0.0)
	var slide := lip_goal - kiss_lip(rig, state.mouth_lip)
	slide.y = 0.0
	state.mouth_goal = Vector3(state.origin) + slide
	state.landed_feet = kiss_feet(rig)
	state.mouth_knees = {}
	if not cheek and drop / scale > 0.44:
		prepare_mouth_knees(rig)
	for side: String in state.landed_feet:
		var foot: Transform3D = state.landed_feet[side]
		var outward := -1.0 if side == "L" else 1.0
		foot.origin += slide
		if not state.mouth_knees.has(side):
			foot.origin -= toward * back * (1.2 if side == "L" else 0.72)
			foot.origin += toward.cross(Vector3.UP) * outward * clampf(drop * 0.15, 0.0, 0.095)
		state.landed_feet[side] = foot
	state.player_model.rotation.y = state.player_yaw
	Pose.blend(rig, state.player_pose, state.player_pose, 1.0)
	Pose.blend(npc, state.npc_pose, state.npc_pose, 1.0)


func prepare_mouth_knees(rig: Skeleton3D) -> void:
	# Fit the bent legs to the same floor level as the standing feet.
	for side: String in state.landed_feet:
		var thigh := rig.find_bone("cf_j_thigh00_" + side)
		var knee := rig.find_bone("cf_j_leg01_" + side)
		var ankle := rig.find_bone("cf_j_foot_" + side)
		if mini(thigh, mini(knee, ankle)) < 0:
			continue
		var hip := rig.get_bone_global_pose(thigh).origin
		var joint_knee := rig.get_bone_global_pose(knee).origin
		var joint_ankle := rig.get_bone_global_pose(ankle).origin
		var sole: Transform3D = state.landed_feet[side]
		var ground := rig.to_local(sole.origin).y
		var upper := hip.distance_to(joint_knee)
		var lower := joint_knee.distance_to(joint_ankle)
		var low := minf(ground + 0.033, hip.y)
		var drop := hip.y - low
		if drop > upper * 0.94:
			continue
		var spread := minf(0.20, sqrt(maxf(0.0, upper * upper - drop * drop)) * 0.46)
		var outward := -1.0 if side == "L" else 1.0
		var forward := sqrt(maxf(0.0, upper * upper - drop * drop - spread * spread))
		var knee_goal := hip + Vector3(spread * outward, -drop, -forward)
		var rise := minf(0.115, lower * 0.32)
		var ankle_goal := knee_goal + Vector3(0.0, rise, sqrt(lower * lower - rise * rise))
		var profile := rig.get_bone_global_rest(ankle).basis.rotated(Vector3.RIGHT, deg_to_rad(-70.0))
		state.mouth_knees[side] = knee_goal
		state.landed_feet[side] = rig.global_transform * Transform3D(profile, ankle_goal)


func mouth_foot(rig: Skeleton3D, side: String, world: Transform3D, weight: float) -> void:
	if not state.mouth_knees.has(side):
		kiss_foot(rig, side, world, state.mouth_drop * weight)
		return
	var thigh := rig.find_bone("cf_j_thigh00_" + side)
	var knee := rig.find_bone("cf_j_leg01_" + side)
	var foot := rig.find_bone("cf_j_foot_" + side)
	var local := rig.global_transform.affine_inverse() * world
	var outward := -0.45 if side == "L" else 0.45
	var pole := (Vector3(state.mouth_knees[side]) - rig.get_bone_global_pose(thigh).origin).normalized()
	var direction := Vector3(outward, 0.0, -1.0).lerp(pole, Pose.smooth(weight))
	Pose.reach_chain(rig, thigh, knee, foot, local.origin, 1.0, direction)
	var ankle := rig.get_bone_global_pose(foot)
	ankle.basis = local.basis
	rig.set_bone_global_pose(foot, ankle)


func mouth_surface(npc: Skeleton3D) -> Dictionary:
	var target: Dictionary = game.contact.zone_anchor(npc, state.zone)
	if state.has("mouth_surface"):
		return game.contact.surface_pose(npc, target, state.mouth_surface)
	return target


func orient_mouth(rig: Skeleton3D, direction: Vector3, lean: float) -> void:
	var forward := (rig.global_basis.inverse() * direction).normalized()
	var horizontal := Vector3(forward.x, 0.0, forward.z).normalized()
	var bend := Quaternion(horizontal.cross(Vector3.UP), deg_to_rad(-lean))
	kiss_turn(rig, rig.find_bone("cf_j_spine01"), Quaternion.IDENTITY.slerp(bend, 0.63))
	kiss_turn(rig, rig.find_bone("cf_j_spine03"), Quaternion.IDENTITY.slerp(bend, 0.37))
	var head := rig.find_bone("cf_j_head")
	var neck := rig.find_bone("cf_j_neck")
	var rest := rig.get_bone_global_rest(head).basis.orthonormalized()
	var desired := Basis.looking_at(forward)
	var current := rig.get_bone_global_pose(head).basis.orthonormalized() * rest.inverse()
	var turn := (desired * current.inverse()).get_rotation_quaternion()
	kiss_turn(rig, neck, Quaternion.IDENTITY.slerp(turn, 0.47))
	current = rig.get_bone_global_pose(head).basis.orthonormalized() * rest.inverse()
	kiss_turn(rig, head, (desired * current.inverse()).get_rotation_quaternion())


func prepare_tongue(rig: Skeleton3D) -> void:
	var tongue := rig.get_parent().get_node_or_null("o_tang") as MeshInstance3D
	var base := rig.find_bone("cf_j_tang_01")
	var tip := rig.find_bone("cf_j_tang_05")
	if not tongue or not tongue.mesh or mini(base, tip) < 0:
		return
	var bounds := tongue.get_aabb()
	var point := bounds.get_center()
	point.z = bounds.position.z
	state.tongue = tongue
	state.tongue_base = base
	state.tongue_tip = tip
	state.tongue_point = rig.get_bone_global_rest(tip).affine_inverse() * rig.to_local(tongue.to_global(point))
	var posed_mesh := bind_tongue_mesh(rig, tongue, base, tip)
	if posed_mesh:
		state.original_tongue_mesh = tongue.mesh
		tongue.mesh = posed_mesh


func bind_tongue_mesh(rig: Skeleton3D, tongue: MeshInstance3D, base: int, tip: int) -> ArrayMesh:
	var cavity := rig.find_bone("cf_J_MouthCavity")
	if cavity < 0 or not tongue.skin:
		return null
	var chain: Array[int] = []
	var bone := tip
	while bone >= 0:
		chain.push_front(bone)
		if bone == base:
			break
		bone = rig.get_bone_parent(bone)
	if chain.size() < 2 or chain[0] != base:
		return null
	var binds: Array[int] = []
	for joint: int in chain:
		var index := -1
		for slot in range(tongue.skin.get_bind_count()):
			if tongue.skin.get_bind_bone(slot) == joint:
				index = slot
				break
		if index < 0:
			return null
		binds.append(index)
	var start := rig.get_bone_global_rest(base).origin
	var axis := start.direction_to(rig.get_bone_global_rest(tip).origin)
	var depths := PackedFloat32Array()
	for joint: int in chain:
		var depth := (rig.get_bone_global_rest(joint).origin - start).dot(axis)
		if not depths.is_empty() and depth <= depths[-1]:
			return null
		depths.append(depth)
	var source := tongue.mesh as ArrayMesh
	if not source or source.get_blend_shape_count() > 0:
		return null
	var result := ArrayMesh.new()
	var to_rig := rig.global_transform.affine_inverse() * tongue.global_transform
	for surface in range(source.get_surface_count()):
		var arrays := source.surface_get_arrays(surface)
		var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var joints: PackedInt32Array = arrays[Mesh.ARRAY_BONES]
		var weights: PackedFloat32Array = arrays[Mesh.ARRAY_WEIGHTS]
		if joints.size() != vertices.size() * 4 or weights.size() != joints.size():
			return null
		# Current cards bind the entire tongue to the cavity. Leave authored tongue weights alone.
		for i in range(joints.size()):
			if weights[i] > 0.0001 and tongue.skin.get_bind_bone(joints[i]) != cavity:
				return null
		for i in range(vertices.size()):
			var depth := (to_rig * vertices[i] - start).dot(axis)
			var next := 1
			while next < depths.size() - 1 and depth > depths[next]:
				next += 1
			var weight := clampf(inverse_lerp(depths[next - 1], depths[next], depth), 0.0, 1.0)
			var offset := i * 4
			joints[offset] = binds[next - 1]
			joints[offset + 1] = binds[next]
			weights[offset] = 1.0 - weight
			weights[offset + 1] = weight
			weights[offset + 2] = 0.0
			weights[offset + 3] = 0.0
		arrays[Mesh.ARRAY_BONES] = joints
		arrays[Mesh.ARRAY_WEIGHTS] = weights
		result.add_surface_from_arrays(source.surface_get_primitive_type(surface), arrays, [], {},
			source.surface_get_format(surface))
		result.surface_set_material(surface, source.surface_get_material(surface))
	return result


func move_tongue(rig: Skeleton3D, surface: Dictionary, amount: float) -> void:
	var lip := kiss_lip(rig, state.mouth_lip)
	var point: Vector3 = surface.point
	var normal: Vector3 = surface.normal
	state.lip_clearance = lip.distance_to(point)
	if not state.has("tongue") or not state.has("mouth_surface") or amount <= 0.0:
		return
	amount *= 1.0 - Pose.smooth((state.lip_clearance - 0.045) / 0.034)
	if amount <= 0.0:
		return
	var head := rig.find_bone("cf_j_head")
	var up := rig.get_bone_global_pose(head).basis.y.normalized()
	game.contact.shift_bone(rig, "cf_J_MouthLow", -up * (0.008 * amount))
	game.contact.shift_bone(rig, "cf_J_ChinLow", -up * (0.005 * amount))
	var curl := sin(float(state.time) * 4.1)
	var tip: int = state.tongue_tip
	var rotation := rig.get_bone_pose_rotation(tip)
	rig.set_bone_pose_rotation(tip, rotation * Quaternion(Vector3.RIGHT, (0.10 + 0.08 * curl) * amount))
	var hint := rig.to_global(rig.get_bone_global_pose(tip) * Vector3(state.tongue_point))
	var tangent := normal.cross(Vector3.UP).normalized()
	var goal := point + normal * (0.003 + (1.0 - curl) * 0.003) + tangent * (0.004 * curl)
	var offset := (rig.global_basis.inverse() * (goal - hint)).limit_length(0.079) * amount
	game.contact.shift_bone(rig, rig.get_bone_name(state.tongue_base), offset)
	state.tongue_gap = rig.to_global(rig.get_bone_global_pose(tip) * Vector3(state.tongue_point)).distance_to(point)


func turn_mouth_joint(rig: Skeleton3D, name: String, degrees: Vector3) -> void:
	if degrees.is_zero_approx():
		return
	var bone := rig.find_bone(name)
	if bone < 0:
		return
	var frame := rig.get_bone_global_pose(bone).basis.orthonormalized()
	frame *= rig.get_bone_global_rest(bone).basis.orthonormalized().inverse()
	var turn := Basis.from_euler(degrees * (PI / 180.0))
	kiss_turn(rig, bone, (frame * turn * frame.inverse()).get_rotation_quaternion())


func sample_mouth_hold(poses: Array, time: float) -> Vector3:
	for i in range(1, poses.size()):
		var right: Vector4 = poses[i]
		if time > right.x:
			continue
		var left: Vector4 = poses[i - 1]
		var before: Vector4 = poses[maxi(0, i - 2)]
		var after: Vector4 = poses[mini(poses.size() - 1, i + 1)]
		var span := right.x - left.x
		var t := clampf((time - left.x) / span, 0.0, 1.0)
		var position := Vector3.ZERO
		for axis in range(3):
			var channel := axis + 1
			var slope := (right[channel] - left[channel]) / span
			var incoming := (left[channel] - before[channel]) / maxf(left.x - before.x, 0.001)
			var outgoing := (after[channel] - right[channel]) / maxf(after.x - right.x, 0.001)
			# Carry momentum through a key while the channel still travels in the same direction.
			# At a reversal the tangent goes to zero, keeping the pose within the authored range.
			var lead := 2.0 * incoming * slope / (incoming + slope) if incoming * slope > 0.0 else 0.0
			var trail := 2.0 * outgoing * slope / (outgoing + slope) if outgoing * slope > 0.0 else 0.0
			position[axis] = lerpf(left[channel], right[channel], Pose.smooth(t))
			position[axis] += span * t * (1.0 - t) * ((1.0 - t) * lead - t * trail)
		return position
	var last: Vector4 = poses[-1]
	return Vector3(last.y, last.z, last.w)


func animate_mouth_hold(rig: Skeleton3D, npc: Skeleton3D, base: Dictionary,
		age: float, amount: float) -> Dictionary:
	var cheek: bool = state.zone.begins_with("cheek")
	var low: bool = state.zone == "lap"
	var side := -1.0 if state.zone.ends_with("_l") else 1.0
	var poses := CHEEK_HOLD if cheek else (GROIN_HOLD if low else BELLY_HOLD)
	var lead := sample_mouth_hold(poses, age)
	var shoulders_follow := sample_mouth_hold(poses, age - 0.10)
	var reaction := sample_mouth_hold(poses, age - (0.16 if cheek else 0.24))
	var settle := sample_mouth_hold(poses, age - 0.34)
	var lip := kiss_lip(rig, state.mouth_lip)
	var head := rig.find_bone("cf_j_head")
	var neck := rig.find_bone("cf_j_neck")
	var head_start := rig.get_bone_global_pose(head).basis.orthonormalized()

	var posture: String = state.entry.get("posture", {}).get("kind", "standing")
	var supported := posture in ["fours", "lie_stomach", "lie_back"]
	var torso := 0.0 if supported else (0.57 if posture == "kneel" else 1.0)
	var shoulders := torso if posture not in ["skirt", "behind"] else 0.0
	var lateral := side * reaction.y
	var shoulder_lag := side * settle.z
	var hands: Dictionary = {}
	if shoulders > 0.0:
		for arm in ["L", "R"]:
			var hand := npc.find_bone("cf_j_hand_" + arm)
			if hand >= 0:
				hands[arm] = npc.get_bone_global_pose(hand).origin
	# Reactions start above the hips. Floor and hand supports keep their existing poses.
	var waist := Vector3(-2.0 * settle.x, 1.25 * lateral, 2.4 * lateral)
	var chest := Vector3(-3.5 * reaction.x, 1.2 * lateral, -1.15 * shoulder_lag)
	if low:
		chest.x *= 0.68
		chest.z += 2.1 * lateral
	turn_mouth_joint(npc, "cf_j_spine01", waist * (amount * shoulders))
	turn_mouth_joint(npc, "cf_j_spine03", chest * (amount * shoulders))
	var neck_pitch := (1.65 if cheek else -3.6) * reaction.x
	turn_mouth_joint(npc, "cf_j_neck", Vector3(neck_pitch, -2.6 * lateral, 2.25 * lateral) * amount)
	turn_mouth_joint(npc, "cf_j_head", Vector3(-1.4 * settle.x, -2.1 * lateral, 1.6 * shoulder_lag) * amount)
	turn_mouth_joint(npc, "cf_j_shoulder_L", Vector3(2.4 * settle.z, -0.8 * lateral,
		1.7 * reaction.z) * (amount * shoulders))
	turn_mouth_joint(npc, "cf_j_shoulder_R", Vector3(-1.0 * settle.z, -0.8 * lateral,
		-1.5 * reaction.z) * (amount * shoulders))
	# Let the shoulders react while the hanging arms swing around the outfit.
	for arm: String in hands:
		var upper := npc.find_bone("cf_j_arm00_" + arm)
		if upper < 0:
			continue
		var outward := -1.0 if arm == "L" else 1.0
		var space := (0.018 if cheek else 0.046) + 0.008 * settle.z * outward
		var wrist := Vector3(hands[arm]) + Vector3(outward * space, 0.0, -0.016 * reaction.x) * amount
		Pose.aim(npc, upper, npc.find_bone("cf_j_hand_" + arm), wrist, shoulders)

	var at := mouth_surface(npc)
	# Carry the original lip clearance in the moving surface frame, including its normal.
	var surface_turn := Quaternion(Vector3(base.normal), Vector3(at.normal))
	var lip_goal: Vector3 = Vector3(at.point) + surface_turn * (lip - Vector3(base.point))
	var lateral_player := side * lead.y
	var weight_shift := (2.4 if cheek else 4.4) * lead.x
	var bend := Vector3(weight_shift, 1.45 * lateral_player, 3.15 * lateral_player)
	var counter := Vector3(-0.28 * weight_shift + 4.2 * lead.z, 2.1 * lateral_player, -1.05 * lateral_player)
	turn_mouth_joint(rig, "cf_j_spine01", bend * amount)
	turn_mouth_joint(rig, "cf_j_spine03", counter * amount)
	var shoulder := shoulders_follow.z * amount
	turn_mouth_joint(rig, "cf_j_shoulder_L", Vector3(5.5 * shoulder, -1.2 * lateral_player * amount, (3.3 + side) * shoulder))
	turn_mouth_joint(rig, "cf_j_shoulder_R", Vector3(-3.8 * shoulder, -1.2 * lateral_player * amount, -(3.3 - side) * shoulder))

	var frame := rig.global_basis.orthonormalized()
	var follow := frame.inverse() * Basis(surface_turn) * frame
	var nod := Vector3((2.8 if cheek else 3.8) * lead.x, 3.15 * lateral_player, 2.65 * lateral_player)
	var aim := follow * head_start * Basis.from_euler(nod * (amount * PI / 180.0))
	var current := rig.get_bone_global_pose(head).basis.orthonormalized()
	var adjustment := (aim * current.inverse()).get_rotation_quaternion()
	kiss_turn(rig, neck, Quaternion.IDENTITY.slerp(adjustment, 0.58))
	current = rig.get_bone_global_pose(head).basis.orthonormalized()
	kiss_turn(rig, head, (aim * current.inverse()).get_rotation_quaternion())
	var remaining := (rig.global_basis.inverse() * (lip_goal - kiss_lip(rig, state.mouth_lip))).limit_length(0.047)
	game.contact.shift_bone(rig, "cf_j_spine03", remaining * 0.64)
	game.contact.shift_bone(rig, "cf_j_neck", remaining * 0.36)
	return at


func mouth_tick(delta: float) -> void:
	var npc: Skeleton3D = state.npc
	var rig: Skeleton3D = state.player
	var time: float = state.time
	var exit := 0.0
	if state.ending >= 0.0:
		time = state.ending
		exit = clampf((state.time - state.ending) / MOUTH_RETREAT, 0.0, 1.0)
	var progress := minf(time / MOUTH_APPROACH, 1.0) * (1.0 - exit)
	var weight := Pose.smooth(progress)
	var posed := Pose.smooth((progress - 0.17) / 0.83)
	var goal := Vector3(state.origin).lerp(state.mouth_goal, weight)
	var body: CharacterBody3D = game.room.player
	body.velocity.y = -0.2 if body.is_on_floor() else body.velocity.y - 16.0 * delta
	place_player(goal, delta)
	state.player_model.rotation.y = lerp_angle(state.player_yaw, state.mouth_yaw, weight)
	Pose.blend(rig, state.player_pose, state.player_contact, posed)
	Pose.blend(npc, state.npc_pose, state.npc_contact, posed)
	var blocked := Vector2(body.global_position.x - goal.x, body.global_position.z - goal.z)
	if progress > 0.0 and blocked.length_squared() < 0.012:
		for side: String in state.start_feet:
			var first := clampf(progress / 0.62, 0.0, 1.0)
			var last := clampf((progress - 0.79) / 0.21, 0.0, 1.0)
			var second := clampf((progress - 0.27) / 0.68, 0.0, 1.0)
			var step := 0.70 * Pose.smooth(first) + 0.30 * Pose.smooth(last) if side == "L" else Pose.smooth(second)
			var lift := sin(PI * first) + 0.54 * sin(PI * last) if side == "L" else sin(PI * second)
			var foot: Transform3D = state.start_feet[side].interpolate_with(state.landed_feet[side], step)
			foot.origin.y += lift * 0.038
			mouth_foot(rig, side, foot, posed)
	elif state.ending < 0.0 and weight > 0.86:
		cancel()
	var surface := mouth_surface(npc)
	var hold := Pose.smooth((time - MOUTH_APPROACH) / 0.47) * (1.0 - Pose.smooth(exit / 0.40))
	if hold > 0.0 and blocked.length_squared() < 0.012:
		surface = animate_mouth_hold(rig, npc, surface, state.time - MOUTH_APPROACH, hold)
	var tongue := Pose.smooth((progress - 0.83) / 0.17) * (1.0 - Pose.smooth(exit / 0.22))
	move_tongue(rig, surface, tongue)
	game.contact.set_blush(state.actor, posed * 0.15)
	if exit >= 1.0:
		stop()
		if game.dialogue.visible:
			game.rebuild_posture_buttons()


func aim_mouth(rig: Skeleton3D, point: Vector3, weight: float, open: bool) -> void:
	var lower := rig.find_bone("cf_j_spine01")
	var spine := rig.find_bone("cf_j_spine03")
	var head := rig.find_bone("cf_j_head")
	var lip := rig.find_bone("cf_J_MouthLow")
	if mini(spine, mini(head, lip)) < 0:
		return
	var target := rig.to_local(point)
	if lower >= 0:
		var base := rig.get_bone_global_pose(lower).origin
		var down: float = rig.get_bone_global_pose(head).origin.y - target.y
		if down > 0.12:
			var toward := (target - base).normalized()
			var chest := rig.get_bone_global_pose(spine).origin
			Pose.aim(rig, lower, spine, chest.lerp(base + (toward + Vector3.UP * 0.28).normalized() * 0.3, 0.77), weight * 0.88)
	var head_point := rig.get_bone_global_pose(head).origin
	var mouth_point := rig.get_bone_global_pose(lip).origin
	var offset := (target - mouth_point).limit_length(0.22) * weight
	game.contact.shift_bone(rig, "cf_j_spine02", offset * 0.72)
	Pose.aim(rig, head, lip, head_point + offset + (target - head_point).normalized() * 0.14, weight * 0.83)
	if open:
		game.contact.shift_bone(rig, "cf_J_MouthLow", Vector3.DOWN * weight * 0.024)
		game.contact.shift_bone(rig, "cf_J_ChinLow", Vector3.DOWN * weight * 0.015)


func mouth_effect(rig: Skeleton3D, point: Vector3, normal: Vector3, weight: float) -> void:
	var lip := joint(rig, "cf_J_MouthLow")
	var away := point - lip
	var pulse := 0.52 + 0.48 * sin(float(state.time) * 7.4)
	var tongue: MeshInstance3D = state.tongue
	tongue.visible = weight > 0.53 and away.length() < 0.155
	if tongue.visible and not away.is_zero_approx():
		var extension := away.limit_length(0.102) * (0.53 + pulse * 0.47)
		tongue.global_position = lip + extension * 0.5
		tongue.global_basis = Basis(Quaternion(Vector3.UP, extension.normalized())) * Basis.from_scale(Vector3(0.035, extension.length(), 0.036))
	for i in range(state.traces.size()):
		var trace: MeshInstance3D = state.traces[i]
		var tangent := normal.cross(Vector3.UP).normalized()
		trace.visible = tongue.visible and weight > 0.80 and absf(pulse) < 0.95
		if trace.visible:
			trace.set_meta("has_contact", true)
		trace.global_position = point + normal * 0.006 + tangent * (float(i) - 1.0) * 0.012 + Vector3.DOWN * float(i) * 0.009
		var orientation := Basis(Quaternion(Vector3.UP, normal.normalized())) if not normal.is_zero_approx() else Basis.IDENTITY
		trace.global_basis = orientation * Basis.from_scale(trace.get_meta("dimensions"))


func place_player(goal: Vector3, delta: float) -> void:
	var body: CharacterBody3D = game.room.player
	body.add_collision_exception_with(state.body)
	var distance := goal - body.global_position
	body.velocity.x = distance.x / delta
	body.velocity.z = distance.z / delta
	body.move_and_slide()


func joint(rig: Skeleton3D, name: String) -> Vector3:
	var bone := rig.find_bone(name)
	return rig.to_global(rig.get_bone_global_pose(bone).origin) if bone >= 0 else rig.global_position


func effect(dimensions: Vector3, color: Color, tongue: bool) -> MeshInstance3D:
	var ball := SphereMesh.new()
	ball.radius = 0.5
	ball.height = 1.0
	ball.radial_segments = 12
	ball.rings = 5
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.roughness = 0.25 if tongue else 0.12
	if not tongue:
		material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	var node := MeshInstance3D.new()
	game.room.add_child(node)
	node.mesh = ball
	node.material_override = material
	node.scale = dimensions
	node.set_meta("dimensions", dimensions)
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	node.hide()
	state.effects.append(node)
	return node


func camera_view() -> Dictionary:
	if not active():
		return {}
	var a := joint(state.npc, "cf_j_spine03")
	var b := joint(state.player, "cf_j_spine03")
	var focus := a.lerp(b, 0.50)
	var side_distance := 1.88
	var rise := 0.75
	if state.kind == "kiss":
		focus += Vector3.UP * 0.05
		side_distance = 1.68
		rise = 0.18
	elif state.kind == "mouth":
		var goal := mouth_surface(state.npc)
		if not goal.is_empty():
			focus = Vector3(goal.point).lerp(joint(state.player, "cf_J_MouthLow"), 0.48).lerp(focus, 0.33)
			side_distance = 1.48
			rise = 0.20
	if state.kind == "shoe":
		focus = joint(state.npc, "cf_j_head").lerp(joint(state.player, "cf_j_foot_R"), 0.43) + Vector3.UP * 0.36
	var axis: Vector3 = state.player_model.global_basis.x.normalized()
	var along := 0.10 if smooth_approach() else 0.43
	var eye: Vector3 = focus + axis * side_distance + Vector3.UP * rise + state.player_model.global_basis.z.normalized() * along
	var query := PhysicsRayQueryParameters3D.create(focus, eye, 1, [state.body.get_rid(), game.room.player.get_rid()])
	var hit: Dictionary = game.room.get_world_3d().direct_space_state.intersect_ray(query)
	if not hit.is_empty():
		eye = hit.position.move_toward(focus, 0.13)
	return {"eye": eye, "focus": focus}
