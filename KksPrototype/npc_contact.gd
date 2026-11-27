extends RefCounted

const Pose := preload("res://npc_pose.gd")
const Card := preload("res://card_model.gd")
const ContactSurface := preload("res://npc_contact_surface.gd")
const MARK_LIMIT := 16

# Offsets are in the unposed skeleton axes. anchor() converts them to bone space.
const ZONES := {
	"crown": ["Crown", "cf_j_head", Vector3(0, 0.17, -0.025), Vector3.UP, 0.091],
	"cheek_l": ["Left cheek", "cf_j_head", Vector3(-0.055, 0.040, -0.073), Vector3(-0.45, 0, -0.89), 0.035],
	"cheek_r": ["Right cheek", "cf_j_head", Vector3(0.055, 0.040, -0.073), Vector3(0.45, 0, -0.89), 0.035],
	"chin": ["Chin", "cf_J_ChinTip_Base", Vector3(0, -0.007, -0.007), Vector3(0, -0.20, -0.98), 0.029],
	"lips": ["Lips", "cf_J_MouthLow", Vector3(0, 0.007, -0.012), Vector3.FORWARD, 0.025],
	"hand_l": ["Left hand", "cf_j_hand_L", Vector3(-0.045, 0, 0), Vector3.ZERO, 0.053],
	"hand_r": ["Right hand", "cf_j_hand_R", Vector3(0.045, 0, 0), Vector3.ZERO, 0.053],
	"chest_l": ["Left chest", "cf_j_bust03_L", Vector3(0, 0, -0.028), Vector3.FORWARD, 0.064],
	"chest_r": ["Right chest", "cf_j_bust03_R", Vector3(0, 0, -0.028), Vector3.FORWARD, 0.064],
	"belly": ["Abdomen", "cf_j_spine02", Vector3(0, -0.045, -0.083), Vector3.FORWARD, 0.071],
	"hip_l": ["Left thigh", "cf_j_thigh00_L", Vector3(-0.034, -0.155, -0.046), Vector3(-0.65, 0, -0.76), 0.077],
	"hip_r": ["Right thigh", "cf_j_thigh00_R", Vector3(0.034, -0.155, -0.046), Vector3(0.65, 0, -0.76), 0.077],
	"inner_l": ["Left inner thigh", "cf_j_thigh00_L", Vector3(0.036, -0.145, -0.057), Vector3(0.58, 0, -0.82), 0.048],
	"inner_r": ["Right inner thigh", "cf_j_thigh00_R", Vector3(-0.036, -0.145, -0.057), Vector3(-0.58, 0, -0.82), 0.048],
	"lap": ["Groin", "cf_j_hips", Vector3(0, -0.178, -0.058), Vector3.FORWARD, 0.046],
	"seat_l": ["Left buttock", "cf_j_hips", Vector3(-0.086, -0.111, 0.112), Vector3(0, 0, 1), 0.071],
	"seat_r": ["Right buttock", "cf_j_hips", Vector3(0.086, -0.111, 0.112), Vector3(0, 0, 1), 0.071],
	"foot_l": ["Left foot", "cf_j_foot_L", Vector3(0, -0.018, -0.061), Vector3.ZERO, 0.058],
	"foot_r": ["Right foot", "cf_j_foot_R", Vector3(0, -0.018, -0.061), Vector3.ZERO, 0.058],
	"leg_l": ["Left lower leg", "cf_j_leg01_L", Vector3(-0.022, -0.12, 0.043), Vector3(0, 0, 1), 0.060],
	"leg_r": ["Right lower leg", "cf_j_leg01_R", Vector3(0.022, -0.12, 0.043), Vector3(0, 0, 1), 0.060],
	"flank_l": ["Left side", "cf_j_spine01", Vector3(-0.118, 0.032, -0.020), Vector3(-0.95, 0, -0.31), 0.058],
	"flank_r": ["Right side", "cf_j_spine01", Vector3(0.118, 0.032, -0.020), Vector3(0.95, 0, -0.31), 0.058],
}
const PRONE_ZONES := ["crown", "seat_l", "seat_r", "hip_l", "hip_r", "leg_l", "leg_r", "foot_l", "foot_r"]
const SUPINE_ZONES := ["chest_l", "chest_r", "hip_l", "hip_r", "belly", "flank_l", "flank_r"]
const SPREAD_ZONES := ["inner_l", "inner_r", "lap"]
const PAIRED_ZONES := ["cheek", "chest", "flank", "seat", "inner"]
const BLOCKERS := [
	["cf_j_head", Vector3(0, 0.095, 0), 0.095],
	["cf_j_spine03", Vector3(0, 0, 0.006), 0.098],
	["cf_j_spine02", Vector3(0, -0.034, 0.008), 0.089],
	["cf_j_hips", Vector3(0, -0.122, 0.016), 0.108],
]
const LIMBS := [
	["cf_j_arm00_L", "cf_j_forearm01_L", 0.045],
	["cf_j_arm00_R", "cf_j_forearm01_R", 0.045],
	["cf_j_forearm01_L", "cf_j_hand_L", 0.034],
	["cf_j_forearm01_R", "cf_j_hand_R", 0.034],
	["cf_j_leg01_L", "cf_j_leg02_L", 0.058],
	["cf_j_leg01_R", "cf_j_leg02_R", 0.058],
]

var game: Node3D
var state: Dictionary = {}
var drag := Vector2.ZERO
var drag_goal := Vector2.ZERO
var hand_profiles: Dictionary


func _init(owner: Node3D) -> void:
	game = owner
	var data = JSON.parse_string(FileAccess.get_file_as_string("res://Content/aibu_hand_poses.json"))
	hand_profiles = data.get("profiles", {}) if data is Dictionary else {}


func anchor(rig: Skeleton3D, bone: int, offset: Vector3, normal: Vector3) -> Dictionary:
	var rest := rig.get_bone_global_rest(bone)
	var matrix := rig.global_transform * rig.get_bone_global_pose(bone) * rest.affine_inverse()
	return {"point": matrix * (rest.origin + offset), "normal": (matrix.basis * normal).normalized()}


func zone_anchor(rig: Skeleton3D, id: String, kind_posture := "") -> Dictionary:
	var zone: Array = ZONES[id]
	var bone := rig.find_bone(zone[1])
	if bone < 0:
		return {}
	var offset: Vector3 = zone[2]
	var normal: Vector3 = zone[3]
	if id.begins_with("hip"):
		var torso := rig.find_bone("cf_j_spine03")
		var hips := rig.find_bone("cf_j_hips")
		if mini(torso, hips) >= 0:
			var chest := anchor(rig, torso, Vector3.ZERO, Vector3.FORWARD)
			if chest.normal.y < -0.63:
				offset.z = -offset.z
				normal.z = -normal.z
	if id.begins_with("flank") and rear_view(rig):
		offset.z = -offset.z
		normal.z = -normal.z
	if id.begins_with("foot") or id.begins_with("leg"):
		normal = Vector3(0.16 if id.ends_with("r") else -0.16, 0.0, 1.0)
	var result := anchor(rig, bone, offset, normal)
	if id == "lap" and kind_posture == "fours" and rear_view(rig):
		# The standing anchor faces the floor in this pose. Approach the same area from behind.
		var rear := rig.global_basis.z.slide(Vector3.UP).normalized()
		result.point += rear * 0.055
		result.normal = (rear + Vector3.DOWN * 0.24).normalized()
	result.bone = bone
	return result


func rear_view(rig: Skeleton3D) -> bool:
	var to_player: Vector3 = game.room.player.global_position - rig.global_position
	return to_player.dot(rig.global_basis.z) > 0.08


func zone_allowed(entry: Dictionary, id: String, mode: int) -> bool:
	if game.staging.active():
		return game.staging.seated() and mode in [0, 2] and game.staging.allows(id)
	if mode == 1:
		if id == "lips":
			return entry.get("posture", {}).get("kind", "standing") in game.staging.KISS_POSTURES
		return id in ["cheek_l", "cheek_r", "belly", "lap"]
	var posture: String = entry.get("posture", {}).get("kind", "standing")
	if posture in ["behind", "stand_spread"]:
		posture = "standing"
	match posture:
		"lie_stomach":
			return id in PRONE_ZONES
		"lie_back":
			if id in SPREAD_ZONES:
				var pose: Dictionary = entry.posture
				return mode == 0 and pose.get("complete", false) and pose.get("spread_target", 0.0) > 0.0 and pose.get("spread", 0.0) >= 0.82
			return id in SUPINE_ZONES
	if id.begins_with("inner"):
		return false
	if mode == 0 and posture == "fours" and id.begins_with("hand_"):
		return false
	var actor: Node3D = game.actor_for(entry)
	var rear: bool = actor != null and rear_view(actor.get_node("Skeleton"))
	if id.begins_with("seat"):
		return rear and posture in ["standing", "skirt", "fours"]
	if id.begins_with("flank"):
		return mode == 0 and posture in ["standing", "skirt"]
	if rear and posture == "fours":
		if id == "lap":
			return mode == 0
		return id.begins_with("hip") or id.begins_with("foot") or id.begins_with("leg") or id == "crown"
	return not (id.begins_with("foot") or id.begins_with("leg"))


func sphere_entry(origin: Vector3, ray: Vector3, center: Vector3, radius: float) -> float:
	var offset := center - origin
	var depth := ray.dot(offset)
	var discriminant := radius * radius - (offset - ray * depth).length_squared()
	if depth < 0.0 or discriminant < 0.0:
		return INF
	return depth - sqrt(discriminant)


func pick(cursor: Vector2, allowed := {}) -> Dictionary:
	var actor: Node3D = game.actor_for(game.speaking)
	var camera: Camera3D = game.room.camera
	if not actor or not camera:
		return {}
	var rig: Skeleton3D = actor.get_node("Skeleton")
	var origin := camera.project_ray_origin(cursor)
	var ray := camera.project_ray_normal(cursor)
	var scale := rig.global_basis.get_scale().abs().length() / sqrt(3.0)
	var best: Dictionary = {}
	var score := INF
	var embracing: bool = state.get("rear_action", "") == "embrace"
	var posture: String = game.speaking.get("posture", {}).get("kind", "") if game.mode == 0 and allowed.is_empty() else ""
	for id: String in ZONES:
		if not allowed.is_empty():
			if not allowed.has(id):
				continue
		elif embracing:
			if id not in ["chest_l", "chest_r", "belly", "lap"]:
				continue
		elif not zone_allowed(game.speaking, id, game.mode):
			continue
		var at := zone_anchor(rig, id, posture)
		if at.is_empty() or camera.is_position_behind(at.point):
			continue
		var normal: Vector3 = at.normal
		if id != "crown" and normal.dot(ray) > 0.10:
			continue
		var radius: float = ZONES[id][4] * scale
		var depth := sphere_entry(origin, ray, at.point, radius)
		if depth == INF:
			continue
		var center: Vector3 = at.point - origin
		var nearest := center.dot(ray)
		var rank := (center - ray * nearest).length() / radius + (normal.dot(ray) + 1.0) * 0.22
		if rank < score:
			score = rank
			best = {"id": id, "anchor": at, "ray": ray, "origin": origin, "depth": nearest, "entry": depth}
	if best.is_empty():
		return best
	var body: CharacterBody3D = game.body_for(game.speaking)
	var obstacles := PhysicsRayQueryParameters3D.create(origin, best.anchor.point, 3, [body.get_rid(), game.room.player.get_rid()])
	if not game.get_world_3d().direct_space_state.intersect_ray(obstacles).is_empty():
		return {}
	for blocker in BLOCKERS:
		if best.id == "crown" and blocker[0] == "cf_j_head":
			continue
		var bone := rig.find_bone(blocker[0])
		if bone >= 0:
			var obstacle := anchor(rig, bone, blocker[1], Vector3.ZERO)
			var depth := sphere_entry(origin, ray, obstacle.point, blocker[2] * scale)
			if depth + 0.040 < best.entry:
				return {}
	for limb in LIMBS:
		var parent := rig.find_bone(limb[0])
		var child := rig.find_bone(limb[1])
		if mini(parent, child) < 0 or best.anchor.bone in [parent, child]:
			continue
		var a := rig.to_global(rig.get_bone_global_pose(parent).origin)
		var b := rig.to_global(rig.get_bone_global_pose(child).origin)
		for t in [0.25, 0.5, 0.75]:
			if sphere_entry(origin, ray, a.lerp(b, t), float(limb[2]) * scale) + 0.035 < best.entry:
				return {}
	return best


func input(event: InputEvent, mode: int) -> bool:
	if event is InputEventMouseMotion and state.get("held", false):
		drag_goal = (drag_goal + event.relative * 0.0025).limit_length(0.32)
		return true
	if event is not InputEventMouseButton:
		return false
	if event.button_index == MOUSE_BUTTON_MIDDLE:
		if event.pressed and mode == 0 and has_special():
			state.special = not state.special
		elif event.pressed and mode == 2:
			advance_hostile_hold()
		return true
	if event.button_index not in [MOUSE_BUTTON_LEFT, MOUSE_BUTTON_RIGHT]:
		return false
	var side := "L" if event.button_index == MOUSE_BUTTON_LEFT else "R"
	if mode == 1:
		if not event.pressed:
			game.staging.release(event.button_index)
		elif not game.staging.active():
			var mouth := pick(event.position)
			if not mouth.is_empty():
				game.staging.begin(game.speaking, "kiss" if mouth.id == "lips" else "mouth", mouth.id, event.button_index)
		return true
	if not event.pressed:
		release_hand(side)
		return true
	if not state.is_empty():
		if state.get("rear_action", "") == "embrace":
			var selected := pick(event.position)
			if not selected.is_empty():
				state.rear_target = selected.id
				set_surface_contact(state.actor, state.rig, selected)
			return true
		if mode == 0 and state.held and (not state.hands.has(side) or state.hands[side].has("released")):
			add_second_hand(side, event)
		return true
	var target := pick(event.position)
	if not target.is_empty():
		begin(game.speaking, target, mode == 2, side, event.button_index)
	return true


func add_second_hand(side: String, event: InputEventMouseButton) -> void:
	var kind: String = state.id.get_slice("_", 0)
	if kind not in PAIRED_ZONES:
		return
	var occupied := ""
	for other: String in state.hands:
		if other != side and not state.hands[other].has("released"):
			occupied = state.hands[other].id
			break
	var selected := pick(event.position)
	var zone: String = selected.get("id", "")
	if zone.get_slice("_", 0) != kind or zone == occupied:
		var reference: String = occupied if not occupied.is_empty() else state.id
		zone = reference.left(-1) + ("l" if reference.ends_with("r") else "r")
		if kind not in ["cheek", "chest"] and not cursor_on_zone(event.position, zone):
			return
	if not zone_allowed(state.entry, zone, 0):
		return
	var at := zone_anchor(state.rig, zone)
	if at.is_empty():
		return
	var previous: Dictionary = state.hands.get(side, {})
	var next := {"id": zone, "button": event.button_index, "started": state.elapsed}
	if not previous.is_empty() and previous.has("last_point"):
		next.switch_from = previous.last_point
		next.switched_at = state.elapsed
	state.hands[side] = next
	set_surface_contact(state.actor, state.rig, {"id": zone, "anchor": at})
	if kind == "cheek":
		seat_cheek_hands()


func cursor_on_zone(cursor: Vector2, zone: String) -> bool:
	var target := zone_anchor(state.rig, zone)
	var camera: Camera3D = game.room.camera
	if target.is_empty() or camera.is_position_behind(target.point):
		return false
	var origin := camera.project_ray_origin(cursor)
	var ray := camera.project_ray_normal(cursor)
	var radius: float = ZONES[zone][4] * state.rig.global_basis.x.length()
	return target.normal.dot(ray) < 0.35 and sphere_entry(origin, ray, target.point, radius) != INF


func has_special() -> bool:
	return state.get("held", false) and state.get("id", "") in ["chin", "lap"]


func action_hint() -> String:
	if not state.get("held", false):
		return ""
	match state.get("hostile_hold", ""):
		"hair":
			if state.posture in ["kneel", "fours"]:
				return "Drag down: forward fall · Drag up: fall onto back"
		"hand":
			if state.posture in ["kneel", "fours"]:
				return ""
			if not state.has("turn_at"):
				return "Middle Mouse: turn with arm held"
			if rear_options_ready():
				return "Choose 1–3 · Middle Mouse: kick"
	if state.get("rear_action", "") == "embrace":
		return "Click chest, abdomen or groin · E: release"
	return "Middle Mouse: special" if has_special() else ""


func seat_cheek_hands() -> void:
	if not state.hands.has("L") or not state.hands.has("R"):
		return
	var rig: Skeleton3D = state.rig
	var left := zone_anchor(rig, "cheek_l")
	var right := zone_anchor(rig, "cheek_r")
	if left.is_empty() or right.is_empty():
		return
	var across: Vector3 = left.point - right.point
	var facing: Vector3 = Vector3.RIGHT.rotated(Vector3.UP, state.face)
	var first := "cheek_r" if across.dot(facing) >= 0.0 else "cheek_l"
	for side in ["L", "R"]:
		var hand: Dictionary = state.hands[side]
		var next := first if side == "L" else ("cheek_l" if first == "cheek_r" else "cheek_r")
		if hand.id != next and hand.has("last_point"):
			hand.switch_from = hand.last_point
			hand.switched_at = state.elapsed
		hand.id = next
		set_surface_contact(state.actor, rig, {"id": next, "anchor": left if next == "cheek_l" else right})


func camera_target() -> Dictionary:
	if state.is_empty() or not state.has("focus_point"):
		return {}
	return {"point": state.focus_point, "weight": state.get("placement", 0.0)}


func begin(entry: Dictionary, target: Dictionary, strike: bool, requested := "", button := 0) -> bool:
	var actor: Node3D = game.actor_for(entry)
	var player: Node3D = game.room.player_model
	if not actor or not player or not state.is_empty() or not zone_allowed(entry, target.id, 2 if strike else 0):
		return false
	var hostile_hold := ""
	if strike:
		if target.id == "crown":
			hostile_hold = "hair"
		elif String(target.id).begins_with("hand"):
			hostile_hold = "hand"
	if not hostile_hold.is_empty():
		strike = false
		entry.face_speaker = false
	var npc_anim: AnimationPlayer = game.animator_for(entry)
	var player_anim: AnimationPlayer = game.room.player_anim
	var rig: Skeleton3D = actor.get_node("Skeleton")
	var player_rig: Skeleton3D = player.get_node("Skeleton")
	var from: Array[Transform3D] = Pose.capture(player_rig)
	var posture: String = entry.get("posture", {}).get("kind", "standing")
	var fours_lap: bool = not strike and hostile_hold.is_empty() and posture == "fours" and target.id == "lap" and rear_view(rig)
	if fours_lap:
		target = target.duplicate()
		target.anchor = zone_anchor(rig, target.id, posture)
	var point: Vector3 = target.anchor.point
	var right := player_rig.find_bone("cf_j_arm00_R")
	var left := player_rig.find_bone("cf_j_arm00_L")
	if mini(right, left) < 0:
		return false
	var flat := actor.global_position - player.global_position
	flat.y = 0.0
	var yaw: float = atan2(-flat.x, -flat.z)
	var target_from_player := point - player.global_position
	var side := "R" if target_from_player.dot(Vector3.RIGHT.rotated(Vector3.UP, yaw)) >= 0.0 else "L"
	if not requested.is_empty():
		side = requested
	state = {
		"entry": entry, "actor": actor, "rig": rig, "anim": npc_anim, "id": target.id,
		"player": player, "player_rig": player_rig, "player_anim": player_anim,
		"player_pose": from, "npc_pose": Pose.capture(rig), "yaw": player.rotation.y, "face": yaw,
		"elapsed": 0.0, "released": -1.0, "weight": 0.0, "held": not strike, "strike": strike,
		"side": side, "marked": false, "resume": npc_anim.is_playing(), "motion": null,
		"surface": {}, "contact_surfaces": {}, "compression": {}, "hands": {}, "hand_weights": {},
		"special": false, "special_alpha": 0.0, "focus_point": point,
		"hostile_hold": hostile_hold, "posture": posture, "fours_lap": fours_lap,
		"player_origin": game.room.player.global_position,
	}
	state.hands[side] = {"id": target.id, "button": button, "started": 0.0}
	state.seated = game.staging.seated()
	if state.seated:
		state.face = state.yaw
	if not strike and target.id == "lap":
		state.hem_bones = game.skirt_bones(actor)
	if not strike or state.seated:
		set_surface_contact(actor, rig, target)
	var step_point: Vector3 = state.contact_surfaces.get(target.id, {}).get("world", point)
	if strike or (target.id == "lap" and not fours_lap):
		step_point = point
	elif String(target.id).begins_with("flank") or String(target.id).begins_with("seat"):
		step_point = step_point.lerp(actor.global_position, 0.64)
	var spread_contact: bool = state.posture == "lie_back" and target.id in SPREAD_ZONES
	var back_chest: bool = not strike and not state.seated and posture == "lie_back" and String(target.id).begins_with("chest_")
	var offset: Vector3 = step_point - game.room.player.global_position
	offset.y = 0
	if fours_lap:
		var lateral := player.global_basis.x.slide(Vector3.UP).normalized()
		offset += lateral * (-0.21 if side == "L" else 0.21)
	state.step_direction = offset.normalized()
	var height: float = point.y - game.room.player.global_position.y
	var standing_gap := 0.39
	var low := height < 0.44
	var lower_limb := String(target.id).begins_with("foot") or String(target.id).begins_with("leg")
	var floor_contact: bool = state.posture in ["lie_stomach", "fours"] and (
		String(target.id).begins_with("seat") or String(target.id).begins_with("hip")
		or lower_limb)
	floor_contact = floor_contact or spread_contact or fours_lap or back_chest
	state.planted_crouch = (floor_contact or low) and not (strike and lower_limb)
	low = low or floor_contact
	if target.id == "crown" and not strike:
		standing_gap = lerpf(0.31, 0.25, Pose.smooth((height - 1.52) / 0.28))
	elif String(target.id).begins_with("cheek") or target.id in ["chin", "lips"]:
		standing_gap = lerpf(0.39, 0.31, Pose.smooth((height - 1.35) / 0.24))
	if target.id == "lap" and not strike:
		standing_gap = 0.51
	if String(target.id).begins_with("hip") and not strike:
		standing_gap = 0.40
	if String(target.id).begins_with("hand") and not strike and hostile_hold.is_empty() and state.posture == "standing":
		standing_gap = 0.47
	if low:
		standing_gap = 0.29
	if spread_contact:
		standing_gap = 0.36
	if fours_lap:
		standing_gap = 0.35
	state.low_reach = low
	var face_zone: bool = target.id in ["crown", "chin", "lips"] or String(target.id).begins_with("cheek")
	state.toe_rise = clampf((height - 1.48) * 0.46, 0.0, 0.12) if face_zone else 0.0
	state.step_distance = 0.0 if state.seated else clampf(offset.length() - standing_gap, 0.0, 1.45)
	state.approach = 0.40 + float(state.step_distance) * 0.62
	if back_chest:
		place_supine_chest(rig, target.id, point)
	state.body = game.body_for(entry)
	if player_anim.has_animation("Walk") and state.step_distance > 0.12:
		var walk := player_anim.get_animation("Walk").duplicate() as Animation
		game.use_kneeling_legs(walk, player_rig)
		state.walk = walk
	state.crouch_weight = 0.0 if target.id == "lap" else Pose.smooth((1.13 - height) / 0.46)
	if floor_contact:
		state.crouch_weight = maxf(float(state.crouch_weight), 0.87)
	elif String(target.id).begins_with("hip") and not strike:
		state.crouch_weight = maxf(float(state.crouch_weight), 0.60)
	if state.seated:
		state.planted_crouch = false
		state.crouch_weight = 0.0
		state.low_reach = false
	if state.planted_crouch:
		state.crouch_weight = 1.0
		state.crouch = planted_crouch(player_rig, from, 0.46 if height < 0.24 else 0.40)
	elif state.crouch_weight > 0.01:
		var kneel: Dictionary = game.animation_groups.kneel[0]
		if low:
			for clip: Dictionary in game.animation_groups.fours:
				if clip.has("pose_at"):
					kneel = clip
					break
		var folding := Card.animation(game.room.motion_path(kneel.id), player_rig)
		if folding:
			folding.loop_mode = Animation.LOOP_NONE
			game.use_kneeling_legs(folding, player_rig)
			var lower := Pose.sample(folding, player_rig, from, float(kneel.get("pose_at", kneel.end_at)))
			if low:
				var hips := player_rig.find_bone("cf_j_hips")
				if hips >= 0:
					lower[hips].origin.x = from[hips].origin.x
					lower[hips].origin.z = from[hips].origin.z
			state.crouch = lower
	game.room.player.add_collision_exception_with(state.body)
	npc_anim.pause()
	player_anim.pause()
	drag = Vector2.ZERO
	drag_goal = Vector2.ZERO
	if strike:
		if target.has("ray") and not lower_limb:
			state.surface = find_skin_hit(actor, target)
			if not state.surface.is_empty():
				var bone_pose: Transform3D = rig.get_bone_global_pose(target.anchor.bone)
				state.hit_offset = bone_pose.affine_inverse() * rig.to_local(state.surface.world)
		var clips: Array = [] if state.seated or lower_limb or String(target.id).begins_with("seat") else game.animation_groups.get("impact", [])
		if not clips.is_empty():
			var matching := clips.filter(func(candidate: Dictionary): return candidate.get("hand", "R") == side)
			var clip: Dictionary = matching.pick_random() if not matching.is_empty() else {}
			if clip.is_empty():
				return true
			var animation := Card.animation(game.room.motion_path(clip.id), player_rig)
			if animation:
				animation.loop_mode = Animation.LOOP_NONE
				state.motion = animation
				state.motion_rest = Pose.rest(player_rig)
				state.impact_frame = float(clip.get("impact_at", animation.length * 0.6))
	return true


func place_supine_chest(rig: Skeleton3D, zone: String, point: Vector3) -> void:
	var across := rig.global_basis.x.slide(Vector3.UP).normalized()
	var outward := across * (-1.0 if zone.ends_with("_l") else 1.0)
	var origin: Vector3 = state.player_origin
	# Walk around the legs before kneeling alongside the torso.
	var finish := point + outward * 0.29
	finish.y = origin.y
	var outside := origin + outward * maxf(0.0, (finish - origin).dot(outward))
	state.chest_side_step = outside
	state.chest_finish = finish
	var first := origin.distance_to(outside)
	var second := outside.distance_to(finish)
	state.step_distance = first + second
	state.chest_corner = first / maxf(0.01, first + second)
	state.approach = 0.52 + float(state.step_distance) * 0.65
	var toward := point - finish
	state.face = atan2(-toward.x, -toward.z)


func planted_crouch(rig: Skeleton3D, standing: Array[Transform3D], drop: float,
		back_shift := 0.105) -> Array[Transform3D]:
	var feet := {}
	for side in ["L", "R"]:
		var foot := rig.find_bone("cf_j_foot_" + side)
		if foot >= 0:
			feet[side] = rig.get_bone_global_pose(foot)
	shift_bone(rig, "cf_j_hips", Vector3(0, -drop, back_shift))
	for side: String in feet:
		var thigh := rig.find_bone("cf_j_thigh00_" + side)
		var knee := rig.find_bone("cf_j_leg01_" + side)
		var foot := rig.find_bone("cf_j_foot_" + side)
		var sole: Transform3D = feet[side]
		var lateral := -0.32 if sole.origin.x < 0.0 else 0.32
		Pose.reach_chain(rig, thigh, knee, foot, sole.origin, 1.0, Vector3(lateral, 0.0, -1.0))
		var current := rig.get_bone_global_pose(foot)
		current.basis = sole.basis
		rig.set_bone_global_pose(foot, current)
	var pose := Pose.capture(rig)
	Pose.blend(rig, standing, standing, 1.0)
	return pose


func release_hand(side: String) -> void:
	if state.is_empty() or state.strike or not state.hands.has(side):
		return
	if state.has("rear_action") or state.has("turn_at"):
		if not state.has("rear_action"):
			state.rear_choice_until = state.elapsed + 4.0
		return
	var hand: Dictionary = state.hands[side]
	if not hand.has("released"):
		hand.released = state.elapsed
		hand.release_weight = float(state.hand_weights.get(side, 0.0))
	for other: Dictionary in state.hands.values():
		if not other.has("released"):
			return
	release()


func release() -> void:
	if state.get("held", false):
		state.held = false
		state.special = false
		state.released = state.elapsed
		state.release_weight = state.weight
		state.release_placement = state.get("placement", 0.0)
		for side: String in state.hands:
			var hand: Dictionary = state.hands[side]
			if not hand.has("released"):
				hand.released = state.elapsed
				hand.release_weight = float(state.hand_weights.get(side, 0.0))


func end() -> void:
	if state.is_empty():
		return
	if is_instance_valid(state.actor):
		set_blush(state.actor, 0.0)
	if is_instance_valid(state.body):
		game.room.player.remove_collision_exception_with(state.body)
	if is_instance_valid(state.rig) and not state.get("keep_posture", false):
		Pose.blend(state.rig, state.npc_pose, state.npc_pose, 1.0)
		if state.resume and is_instance_valid(state.anim):
			state.anim.play()
	if is_instance_valid(state.player_rig) and state.player == game.room.player_model:
		Pose.blend(state.player_rig, state.player_pose, state.player_pose, 1.0)
		state.player.rotation.y = state.yaw
		game.play_rest(state.player_anim)
	state = {}
	drag = Vector2.ZERO


func tick(delta: float) -> void:
	if state.is_empty():
		return
	if not is_instance_valid(state.actor) or not is_instance_valid(state.player) or game.actor_for(state.entry) != state.actor or game.room.player_model != state.player:
		end()
		return
	if state.has("kick"):
		tick_staged_kick(delta)
		return
	if state.held:
		for side: String in state.hands:
			var hand: Dictionary = state.hands[side]
			if hand.button and not Input.is_mouse_button_pressed(hand.button):
				release_hand(side)
	drag = drag.move_toward(drag_goal, 0.62 * delta)
	state.special_alpha = move_toward(float(state.special_alpha), 1.0 if state.special else 0.0, delta * 2.4)
	var rig: Skeleton3D = state.rig
	var player: Node3D = state.player
	var player_rig: Skeleton3D = state.player_rig
	var npc_pose: Array[Transform3D] = state.npc_pose
	var player_pose: Array[Transform3D] = state.player_pose
	state.elapsed += delta
	if state.has("rear_choice_until") and not state.has("rear_action") and state.elapsed >= state.rear_choice_until:
		state.erase("rear_choice_until")
		release()
	var t: float = state.elapsed
	var approach: float = state.approach
	var placement := Pose.smooth(t / approach)
	var strength := Pose.smooth((t - approach * 0.27) / (approach * 0.73))
	if state.has("chest_finish"):
		strength = Pose.smooth((t - approach * 0.52) / (approach * 0.48))
	if state.strike:
		t -= maxf(0.0, approach - 0.55)
		placement *= Pose.smooth((1.40 - t) / 0.45)
		strength = Pose.smooth((t - 0.46) / 0.24) * Pose.smooth((1.12 - t) / 0.41)
	elif state.released >= 0.0:
		var retreat := Pose.smooth((0.49 - (t - state.released)) / 0.49)
		placement = retreat * state.release_placement
		strength = retreat * state.release_weight
	var desired: Vector3 = state.player_origin + state.step_direction * float(state.step_distance) * placement
	if state.has("chest_finish"):
		var corner: float = state.chest_corner
		var outside: Vector3 = state.chest_side_step
		if placement < corner:
			desired = Vector3(state.player_origin).lerp(outside, Pose.smooth(placement / corner))
		else:
			desired = outside.lerp(state.chest_finish, Pose.smooth((placement - corner) / maxf(0.01, 1.0 - corner)))
	var body: CharacterBody3D = game.room.player
	var diff := desired - body.global_position
	diff.y = 0.0
	body.velocity.x = diff.x / delta
	body.velocity.z = diff.z / delta
	body.move_and_slide()
	state.weight = strength
	state.placement = placement
	state.camera_crouch = float(state.crouch_weight) * placement * (1.28 if state.low_reach else 1.0)
	state.camera_rise = float(state.toe_rise) * strength
	player.rotation.y = lerp_angle(state.yaw, state.face, placement)
	Pose.blend(rig, npc_pose, npc_pose, 1.0)
	Pose.blend(player_rig, player_pose, player_pose, 1.0)
	if state.strike and state.motion and t > 0.0:
		var keyed := Pose.sample(state.motion, player_rig, state.motion_rest,
			clampf(t / 0.70, 0.0, 1.0) * state.impact_frame + maxf(0.0, t - 0.70))
		Pose.blend(player_rig, player_pose, keyed, Pose.smooth(t / 0.35) * Pose.smooth((1.37 - t) / 0.42))
	if state.has("crouch"):
		Pose.blend(player_rig, Pose.capture(player_rig), state.crouch, float(state.crouch_weight) * placement)
	if state.has("walk"):
		var speed := clampf(diff.length() / delta, 0.0, 2.0)
		state.gait = float(state.get("gait", 0.0)) + speed * delta
		var walk: Animation = state.walk
		var current := Pose.capture(player_rig)
		var next := Pose.sample(walk, player_rig, current, fposmod(state.gait, walk.length))
		Pose.blend(player_rig, current, next, speed * (1.0 - strength) * 0.32)
	if state.camera_rise > 0.0:
		shift_bone(player_rig, player_rig.get_bone_name(0), Vector3.UP * float(state.camera_rise))
	var kind_posture: String = state.posture if not state.strike and state.hostile_hold.is_empty() else ""
	var at := zone_anchor(rig, state.id, kind_posture)
	if at.is_empty():
		end()
		return
	if state.low_reach:
		var waist := player_rig.find_bone("cf_j_spine01")
		var chest := player_rig.find_bone("cf_j_spine03")
		if mini(waist, chest) >= 0:
			var chest_point := player_rig.get_bone_global_pose(chest).origin
			var fours_reach: bool = state.posture == "fours" and uses_surface_hand(state.id) and not state.strike
			var lean := Vector3(0.0, -0.10, -0.16) if fours_reach else Vector3(0.0, -0.15, -0.24)
			Pose.aim(player_rig, waist, chest, chest_point + lean, strength)
	if state.strike:
		strike_pose(rig, player_rig, at, t, strength)
	elif not state.hostile_hold.is_empty():
		hostile_pose(rig, player_rig, at, t, strength, delta)
	else:
		react_expression(rig, strength * 0.57, false, state.posture in ["standing", "stand_spread"])
		gentle_pose(rig, player_rig, at, t, strength, delta)
	if state.is_empty():
		return
	var is_hit: bool = state.get("marked", false)
	var mood := 0.0 if state.strike and not is_hit else (0.78 if is_hit else strength * 0.57)
	if is_hit:
		mood *= Pose.smooth((1.42 - t) / 0.50)
	if state.strike or not state.hostile_hold.is_empty():
		react_expression(rig, mood, is_hit)
	set_blush(state.actor, mood * (0.15 if is_hit else 0.54))
	if (state.strike and t >= 1.42) or (state.released >= 0.0 and t - state.released >= 0.52):
		if state.strike and not state.marked:
			game.answer.text = "Out of reach."
		end()


func react_expression(rig: Skeleton3D, amount: float, sad: bool, move_spine := true) -> void:
	if amount <= 0.001:
		return
	var lift := -0.012 if sad else 0.008
	for side in ["L", "R"]:
		shift_bone(rig, "cf_J_Mouth_" + side, Vector3.UP * lift * amount)
		shift_bone(rig, "cf_J_CheekUp_s_" + side, Vector3.UP * (0.006 if sad else 0.012) * amount)
	if move_spine:
		var pulse := sin(float(state.get("elapsed", 0.0)) * (15.5 if sad else 5.8))
		shift_bone(rig, "cf_j_spine03", Vector3(0, 0.004 * pulse, 0.003 * pulse) * amount)


func set_blush(actor: Node3D, amount: float) -> void:
	for part in actor.get_children():
		if part is not MeshInstance3D or part.name.to_lower() != "cf_o_face" or not part.mesh:
			continue
		for i in range(part.mesh.get_surface_count()):
			var material := part.get_active_material(i) as ShaderMaterial
			if material:
				material.set_shader_parameter("interaction_blush", amount)


func advance_hostile_hold() -> void:
	if not state.get("held", false) or state.get("hostile_hold") != "hand" or state.weight < 0.70 or state.has("rear_action"):
		return
	if state.posture in ["kneel", "fours"]:
		return
	if not state.has("turn_at"):
		state.turn_at = state.elapsed
		state.turn_from = state.actor.rotation.y
		state.entry.face_speaker = false
		state.entry.facing_locked = true
		game.answer.text = "Stop!"
		return
	if state.elapsed - state.turn_at < 0.66:
		return
	var clips: Array = game.animation_groups.get("staged_kick", [])
	if clips.is_empty():
		return
	var step: Dictionary = clips[0]
	var rig: Skeleton3D = state.player_rig
	var clip := Card.animation(game.room.motion_path(step.id), rig)
	if not clip:
		return
	clip.loop_mode = Animation.LOOP_NONE
	game.use_kneeling_legs(clip, rig)
	state.held = false
	state.kick = {"time": 0.0, "clip": clip, "impact_frame": float(step.impact_at),
		"from": Pose.capture(rig), "npc_from": Pose.capture(state.rig), "hit": false,
		"position": game.room.player.global_position}


func rear_options_ready() -> bool:
	return (
		state.get("held", false) and state.get("hostile_hold", "") == "hand"
		and not state.has("rear_action") and state.has("turn_at") and state.elapsed - state.turn_at >= 0.66
	)


func choose_rear_action(choice: String) -> void:
	if not rear_options_ready() or choice not in ["hold", "embrace", "push"]:
		return
	state.rear_action = choice
	state.erase("rear_choice_until")
	state.rear_started = state.elapsed
	state.rear_target = "belly"
	if choice == "embrace":
		var target := zone_anchor(state.rig, state.rear_target)
		if not target.is_empty():
			set_surface_contact(state.actor, state.rig, {"id": state.rear_target, "anchor": target})


func tick_staged_kick(delta: float) -> void:
	var kick: Dictionary = state.kick
	var rig: Skeleton3D = state.player_rig
	kick.time += delta
	var time: float = kick.time
	var clip: Animation = kick.clip
	var at: float = clampf(time / 0.43, 0.0, 1.0) * float(kick.impact_frame) + maxf(0.0, time - 0.43) * 1.42
	var keyed := Pose.sample(clip, rig, state.player_pose, at)
	var hips := rig.find_bone("cf_j_hips")
	if hips >= 0:
		var origin := keyed[hips].origin
		var reference: Transform3D = state.player_pose[hips]
		keyed[hips].origin = Vector3(reference.origin.x, origin.y, reference.origin.z)
	var ease := Pose.smooth(time / 0.22) * Pose.smooth((1.15 - time) / 0.35)
	Pose.blend(rig, kick.from, keyed, ease)
	if time > 0.78:
		Pose.blend(rig, Pose.capture(rig), state.player_pose, Pose.smooth((time - 0.78) / 0.40))
	var release_arm := Pose.smooth((0.30 - time) / 0.30)
	state.hand_weights = {state.side: release_arm}
	state.show_legs = ease > 0.03
	state.camera_crouch = 0.0
	var foot := rig.find_bone("cf_j_foot_R")
	if foot >= 0:
		var foot_point := rig.to_global(rig.get_bone_global_pose(foot).origin)
		var body: CharacterBody3D = state.body
		state.focus_point = foot_point.lerp(body.global_position + Vector3.UP * 0.95, 0.56)
	if not kick.hit:
		var npc_rig: Skeleton3D = state.rig
		Pose.blend(npc_rig, state.npc_pose, kick.npc_from, release_arm)
		if time >= 0.43:
			kick.hit = true
			state.keep_posture = game.set_posture(state.entry, {"type": "lie_back", "fall": true, "reply": "Ow!"}, true)
			if game.dialogue.visible:
				game.rebuild_posture_buttons()
	var origin: Vector3 = kick.position
	var home: Vector3 = state.player_origin
	var player_body: CharacterBody3D = game.room.player
	var move := (origin.lerp(home, Pose.smooth((time - 0.48) / 0.72)) - player_body.global_position) / delta
	player_body.velocity.x = move.x
	player_body.velocity.z = move.z
	player_body.move_and_slide()
	if time >= 1.23:
		end()


func hostile_pose(rig: Skeleton3D, player_rig: Skeleton3D, at: Dictionary, time: float, strength: float, delta: float) -> void:
	var side: String = state.side
	var point: Vector3 = at.point
	var normal: Vector3
	var fingers := Vector3.UP
	if state.hostile_hold == "hair":
		if state.held and state.posture in ["kneel", "fours"] and strength > 0.82 and absf(drag.y) >= 0.255:
			var entry: Dictionary = state.entry
			var forward := drag.y > 0.0
			var next := "fours" if state.posture == "kneel" else "lie_stomach"
			if not forward:
				next = "lie_back"
			end()
			game.set_posture(entry, {"type": next, "fall": not forward, "reply": "Ow!"})
			if game.dialogue.visible:
				game.rebuild_posture_buttons()
			return
		gentle_pose(rig, player_rig, at, time, strength, delta)
		return
	else:
		if state.has("turn_at"):
			var actor: Node3D = state.actor
			var turn := Pose.smooth((float(state.elapsed) - float(state.turn_at)) / 0.66)
			var direction := -1.0 if side == "L" else 1.0
			actor.rotation.y = float(state.turn_from) + PI * direction * turn
			var npc_side := String(state.id).right(1).to_upper()
			var sign_x := -1.0 if npc_side == "L" else 1.0
			var hips := rig.find_bone("cf_j_hips")
			if hips >= 0:
				var waist := anchor(rig, hips, Vector3(sign_x * 0.10, 0.025, 0.16), Vector3.BACK)
				var unwind := 1.0
				if state.get("rear_action", "") in ["embrace", "push"]:
					unwind = 1.0 - Pose.smooth((time - float(state.rear_started)) / 0.30)
				Pose.reach(rig, npc_side, rig.to_local(waist.point), turn * strength * unwind,
					Vector3(sign_x * 0.8, -0.30, 0.42))
			at = zone_anchor(rig, state.id)
			point = at.point
		if state.has("rear_action"):
			rear_pose(rig, player_rig, point, strength, delta)
			return
		normal = (state.player.global_position + Vector3.UP - point).normalized()
	guide_hand(player_rig, side, state.id, point, normal, fingers, strength, 0.0)
	state.hand_weights = {side: strength}
	state.focus_point = point


func rear_pose(rig: Skeleton3D, player_rig: Skeleton3D, wrist: Vector3, weight: float, delta: float) -> void:
	var time: float = state.elapsed - state.rear_started
	var reach := Pose.smooth(time / 0.31) * weight
	var held: String = state.side
	var free := "L" if held == "R" else "R"
	var same_side := "l" if state.id.ends_with("l") else "r"
	var root: Node3D = state.actor
	var forward := -root.global_basis.z.normalized()
	var across := root.global_basis.x.normalized()
	if state.rear_action == "push":
		var upper := rig.find_bone("cf_j_spine03")
		if upper >= 0:
			var back := anchor(rig, upper, Vector3(0, 0.0, 0.12), Vector3.BACK)
			var press := reach * Pose.smooth((0.80 - time) / 0.36)
			for side in ["L", "R"]:
				var point: Vector3 = back.point + across * (-0.105 if side == "L" else 0.105)
				guide_hand(player_rig, side, "belly", point, back.normal, Vector3.UP, press, 0.0)
			state.focus_point = back.point
			state.hand_weights = {"L": press, "R": press}
			var step := Pose.smooth((time - 0.26) / 0.18) * Pose.smooth((0.83 - time) / 0.30)
			var body: CharacterBody3D = state.body
			game.move_body(body, forward * step * 0.92, delta)
			var waist := rig.find_bone("cf_j_spine01")
			if waist >= 0:
				var chest := rig.get_bone_global_pose(upper).origin
				Pose.aim(rig, waist, upper, chest + Vector3.FORWARD * 0.15, step)
		if time > 0.88:
			release()
			state.erase("rear_action")
		return
	if state.rear_action == "hold":
		guide_hand(player_rig, held, state.id, wrist, -forward, Vector3.UP, weight, 0.0)
		var zone := "seat_" + ("r" if same_side == "l" else "l")
		var seat := zone_anchor(rig, zone)
		if not seat.is_empty():
			var direction := surface_down(rig, zone, seat.normal)
			var point: Vector3 = seat.point + direction * (0.016 + sin(time * 4.1) * 0.014)
			guide_hand(player_rig, free, zone, point, seat.normal, direction, reach, 0.0)
			state.focus_point = point
	else:
		var zone: String = state.rear_target
		var target := zone_anchor(rig, zone)
		var support := zone_anchor(rig, "flank_" + same_side)
		if not support.is_empty():
			guide_hand(player_rig, held, "belly", support.point, support.normal, Vector3.UP, reach, 0.0)
		if not target.is_empty():
			var point: Vector3 = target.point
			var fabric: Dictionary = state.contact_surfaces.get(zone, {})
			if not fabric.is_empty():
				point = rig.to_global(rig.get_bone_global_pose(target.bone) * fabric.offset)
			var direction := surface_down(rig, zone, target.normal)
			point += direction * clampf(drag.y * 0.07, -0.023, 0.023)
			guide_hand(player_rig, free, zone, point, target.normal, direction, reach, 0.0)
			state.focus_point = point
	state.hand_weights = {held: weight, free: reach}


func react(rig: Skeleton3D, bone: int, movement: Vector2, weight: float) -> void:
	if bone < 0 or weight <= 0.0:
		return
	var parent := rig.get_bone_parent(bone)
	if parent < 0:
		return
	var axes := rig.get_bone_global_pose(parent).basis.orthonormalized().inverse()
	var turn := Quaternion(axes * Vector3.UP, movement.x * weight)
	turn *= Quaternion(axes * Vector3.RIGHT, movement.y * weight)
	rig.set_bone_pose_rotation(bone, (turn * rig.get_bone_pose_rotation(bone)).normalized())


func strike_pose(rig: Skeleton3D, player_rig: Skeleton3D, at: Dictionary, t: float, strength: float) -> void:
	var id: String = state.id
	var point: Vector3 = at.point
	if state.has("hit_offset"):
		point = rig.to_global(rig.get_bone_global_pose(at.bone) * state.hit_offset)
	state.focus_point = point
	var normal: Vector3 = at.normal
	var seated: bool = state.get("seated", false)
	if seated:
		var fabric: Dictionary = state.contact_surfaces.get(id, {})
		if not fabric.is_empty():
			var surface := surface_pose(rig, at, fabric)
			point = surface.point
			normal = surface.normal
		var waist := player_rig.find_bone("cf_j_spine01")
		var chest := player_rig.find_bone("cf_j_spine03")
		if mini(waist, chest) >= 0:
			var from := player_rig.get_bone_global_pose(waist).origin
			var toward := (player_rig.to_local(point) - from).normalized()
			Pose.aim(player_rig, waist, chest, from + (toward + Vector3.UP * 0.28).normalized(), strength * 0.73)
			if game.staging.state.kind == "seat_supine":
				shift_bone(player_rig, "cf_j_spine01", toward * strength * 0.07)
	var side: String = state.side
	state.hand_weights = {side: maxf(strength, Pose.smooth(t / 0.28) * Pose.smooth((1.39 - t) / 0.32) * 0.6)}
	var low_limb := id.begins_with("foot") or id.begins_with("leg")
	if id.begins_with("seat") or low_limb or seated:
		var windup := Pose.smooth((t - 0.14) / 0.26) * Pose.smooth((0.69 - t) / 0.25)
		var axis := player_rig.global_basis.x.normalized()
		var sign_x := -1.0 if side == "L" else 1.0
		var slap := point + normal * (0.014 + (0.09 if seated else 0.14) * windup) + axis * (0.10 * windup * sign_x)
		var hand_weight := maxf(strength, windup * 0.8)
		guide_hand(player_rig, side, id, slap, normal, surface_down(rig, id, normal), hand_weight, 0.0, false)
	else:
		var impact := player_rig.to_local(point + normal * 0.055)
		if id.begins_with("cheek") and state.toe_rise > 0.01:
			extend_reach(player_rig, side, impact, strength)
		Pose.reach(player_rig, side, impact, strength)
	var hand := player_rig.find_bone("cf_j_hand_" + side)
	if state.marked:
		var dt := t - float(state.hit_time)
		var recoil := Pose.smooth(dt / 0.10) * Pose.smooth((0.53 - dt) / 0.43)
		if id.begins_with("cheek"):
			var sign_x := 1.0 if id.ends_with("r") else -1.0
			react(rig, at.bone, Vector2(0.32 * sign_x, -0.034), recoil)
			var parent := rig.get_bone_parent(at.bone)
			var axis := rig.get_bone_global_pose(parent).basis.orthonormalized().inverse() * Vector3.FORWARD
			var local := rig.get_bone_pose_rotation(at.bone)
			rig.set_bone_pose_rotation(at.bone, (Quaternion(axis, -0.09 * sign_x * recoil) * local).normalized())
		else:
			react(rig, at.bone, Vector2(0.13, 0.13), recoil)
	elif t >= 0.70 and hand >= 0:
		var palm_hit := low_limb or seated or id.begins_with("seat")
		var reached := player_rig.to_global(Pose.contact_landmark(player_rig, side, "palm")) if palm_hit else player_rig.to_global(player_rig.get_bone_global_pose(hand).origin)
		if reached.distance_to(point) < 0.14:
			add_mark(state.entry, state.actor, rig, id, at)
			state.marked = true
			state.hit_time = t
			game.answer.text = "Ow!"


func extend_reach(rig: Skeleton3D, side: String, impact: Vector3, weight: float) -> void:
	var shoulder := rig.find_bone("cf_j_arm00_" + side)
	var elbow := rig.find_bone("cf_j_forearm01_" + side)
	var wrist := rig.find_bone("cf_j_hand_" + side)
	if mini(shoulder, mini(elbow, wrist)) < 0:
		return
	var start := rig.get_bone_global_pose(shoulder).origin
	var middle := rig.get_bone_global_pose(elbow).origin
	var end_point := rig.get_bone_global_pose(wrist).origin
	var available := start.distance_to(middle) + middle.distance_to(end_point) - 0.022
	var missing := clampf(start.distance_to(impact) - available, 0.0, 0.105)
	shift_bone(rig, "cf_j_spine01", start.direction_to(impact) * missing * weight)


func gentle_pose(rig: Skeleton3D, player_rig: Skeleton3D, at: Dictionary, time: float, strength: float, delta: float) -> void:
	var id: String = state.id
	var head := rig.find_bone("cf_j_head")
	var special := float(state.special_alpha) * strength
	var settled := Pose.smooth((time - float(state.approach)) / 0.55) * strength
	var breath := sin(time * 1.72 + 0.36 * sin(time * 0.87))
	var neck := rig.find_bone("cf_j_neck")
	var standing: bool = state.posture in ["standing", "stand_spread"]
	if standing:
		react(rig, rig.find_bone("cf_j_spine03"), Vector2(drag.x * 0.035, 0.012 * breath - drag.y * 0.026), settled)
	if not state.posture in ["lie_stomach", "lie_back", "fours"] or id == "crown":
		react(rig, neck, Vector2(drag.x * 0.095, 0.018 * breath - drag.y * 0.040), settled)
	if (id == "lap" and not state.fours_lap) or id == "crown":
		var spine := player_rig.find_bone("cf_j_spine01")
		var chest := player_rig.find_bone("cf_j_spine03")
		if mini(spine, chest) >= 0:
			var lean := 0.11 if id == "crown" else 0.21
			var aim := player_rig.get_bone_global_pose(chest).origin + Vector3.FORWARD * lean
			Pose.aim(player_rig, spine, chest, aim, strength)
		if id == "crown":
			shift_bone(player_rig, "cf_j_arm00_" + String(state.side), Vector3.UP * strength * 0.05)
	if id == "crown" or id == "chin" or id == "lips":
		react(rig, head, drag * (0.88 if id == "chin" else 0.72), strength)
	if id == "chin" and special > 0.0:
		var opening := special * (0.011 + 0.002 * sin(time * 5.4))
		shift_bone(rig, "cf_J_MouthLow", Vector3.DOWN * opening)
		shift_bone(rig, "cf_J_ChinLow", Vector3.DOWN * opening * 0.46)
		shift_bone(rig, "cf_J_Mouthup", Vector3.UP * opening * 0.18)
		var purse := (0.0025 + 0.0015 * sin(time * 5.4)) * special
		shift_bone(rig, "cf_J_Mouth_L", Vector3(purse, 0, -purse))
		shift_bone(rig, "cf_J_Mouth_R", Vector3(-purse, 0, -purse))
	if id == "lap" and special > 0.0:
		shift_waistband(rig, special)
	var weights := {}
	var targets: Vector3 = Vector3.ZERO
	var total := 0.0
	# Finish all receiver deformations before either hand samples the final surface.
	for side: String in state.hands:
		var grab: Dictionary = state.hands[side]
		var zone: String = grab.id
		var weight := gentle_hand_weight(grab, time, strength)
		if weight <= 0.0:
			continue
		if zone.begins_with("chest"):
			chest_spring(rig, zone, delta, weight)
		elif zone.begins_with("cheek"):
			var sign_x := -1.0 if zone.ends_with("l") else 1.0
			var pull := drag.x
			var stretch := Vector3(sign_x * (0.006 + pull * 0.047), drag.y * -0.020, -0.004) * weight
			for name in ["cf_J_CheekUp_s_", "cf_J_CheekLow_s_"]:
				shift_bone(rig, name + zone.right(1).to_upper(), stretch)
	for side: String in state.hands:
		var grab: Dictionary = state.hands[side]
		var zone: String = grab.id
		var weight := gentle_hand_weight(grab, time, strength)
		if weight <= 0.0:
			continue
		var target := zone_anchor(rig, zone, state.posture if not state.seated else "")
		if target.is_empty():
			continue
		var surface_hand := uses_surface_hand(zone)
		if surface_hand and zone.begins_with("foot_"):
			target = fours_foot_surface(rig, target)
		var point: Vector3 = target.point
		var normal: Vector3 = target.normal
		var standing_touch: bool = state.posture == "standing" and not state.seated and state.hostile_hold.is_empty()
		var fabric: Dictionary = state.contact_surfaces.get(zone, {})
		var patch: Array = state.get("kind_surface_patches", {}).get(zone, [])
		# The first ray can hit the NPC's arm. The flank patch contains only the torso.
		var flank_patch := standing_touch and zone.begins_with("flank_") and not patch.is_empty()
		if not fabric.is_empty() and not flank_patch:
			var skin_point := point
			var surface := surface_pose(rig, target, fabric)
			point = surface.point
			normal = normal.lerp(surface.normal, 0.65).normalized()
			if zone == "lap":
				point = point.lerp(skin_point, special * 0.25)
		var direction := Vector3.UP
		if normal.is_zero_approx():
			normal = (state.player.global_position + Vector3.UP - point).normalized()
		if standing_touch and zone.begins_with("hand"):
			var hand := offered_hand(rig, zone, point, time, weight)
			if not hand.is_empty():
				point = hand.point
				normal = hand.normal
				direction = hand.fingers
		elif standing_touch and zone.begins_with("flank"):
			var npc_side := zone.right(1).to_upper()
			var upper := rig.find_bone("cf_j_arm00_" + npc_side)
			var lower := rig.find_bone("cf_j_forearm01_" + npc_side)
			if mini(upper, lower) >= 0:
				var elbow := rig.get_bone_global_pose(lower).origin
				var space := rig.global_basis.inverse() * normal
				var away := Vector3.FORWARD if rear_view(rig) else Vector3.BACK
				Pose.aim(rig, upper, lower, elbow + space * 0.045 + away * 0.15, weight * 0.86)
			direction = surface_down(rig, zone, normal)
			var cycle := time * 3.5 + sin(time * 1.21) * 0.24
			var lateral := direction.cross(normal).normalized()
			var eased := Pose.smooth((time - float(state.approach)) / 0.42)
			point += direction * ((0.5 - 0.5 * cos(cycle)) * 0.037 + drag.y * 0.065) * eased
			point += lateral * (sin(cycle) * 0.014 + drag.x * 0.052) * eased
		elif standing_touch and zone == "belly":
			var up := Vector3.UP.slide(normal).normalized()
			var across := up.cross(normal).normalized()
			var cycle := time * 3.0 + sin(time * 1.14) * 0.22
			var stroke := Pose.smooth((time - float(state.approach)) / 0.42)
			point += (across * (sin(cycle) * 0.036 + drag.x * 0.075)
				+ up * ((1.0 - cos(cycle)) * 0.010 + drag.y * 0.068)) * stroke
			direction = up * 0.65 + across * (-0.72 if side == "R" else 0.72)
		elif zone == "crown":
			var side_x := 1.0 if side == "R" else -1.0
			direction = (-state.player.global_basis.z - state.player.global_basis.x * side_x * 0.65).normalized()
			point += state.player.global_basis.x * (side_x * 0.015 + drag.x * 0.044)
		elif zone == "chin":
			var across: Vector3 = state.player.global_basis.x.normalized() * (-1.0 if side == "R" else 1.0)
			direction = (-normal * 0.70 + across * 0.64).normalized()
			point += Vector3.DOWN * 0.020 + normal * 0.014
			if special > 0.0:
				var lips := zone_anchor(rig, "lips")
				if not lips.is_empty():
					point = point.lerp(lips.point - normal * 0.008, special)
					direction = direction.lerp(-normal, special).normalized()
		elif zone.begins_with("cheek"):
			var outward: Vector3 = rig.global_basis.x.normalized() * (1.0 if zone.ends_with("r") else -1.0)
			direction = (-outward * 0.96 + Vector3.UP * 0.26).normalized()
			point += Vector3.DOWN * 0.017 + outward * (0.002 + drag.x * 0.026)
		elif zone == "lips":
			direction = -normal
			point += normal * 0.011
		elif zone.begins_with("hip") or zone.begins_with("inner") or zone == "lap" or zone.begins_with("foot") or zone.begins_with("leg") or zone.begins_with("seat") or zone.begins_with("flank"):
			direction = surface_down(rig, zone, normal)
			if surface_hand and zone == "lap":
				direction = anchor(rig, target.bone, Vector3.ZERO, Vector3.DOWN).normal
				direction = direction.slide(normal).normalized()
			elif surface_hand and zone.begins_with("foot_"):
				direction = anchor(rig, target.bone, Vector3.ZERO, Vector3.FORWARD).normal
				direction = direction.slide(normal).normalized()
			var extent := 0.071 if zone.begins_with("flank") else (0.022 if zone == "lap" or zone.begins_with("foot") else 0.042)
			var phase := fposmod(time * 0.75, 1.0)
			var stroke := (0.5 - 0.5 * cos(phase * TAU)) * extent * 0.65
			point += direction * (stroke + clampf(drag.y, -0.3, 0.3) * extent)
			if zone == "lap" and special > 0.0:
				point += Vector3.UP * special * 0.025 - normal * special * 0.016
			if standing_touch and zone == "seat_r":
				direction = (direction * 0.35 - rig.global_basis.x.normalized()).slide(normal).normalized()
		elif zone.begins_with("chest"):
			var across: Vector3 = rig.global_basis.x.normalized()
			var up := Vector3.UP.slide(Vector3(target.normal)).normalized()
			if up.is_zero_approx():
				up = rig.global_basis.y.slide(Vector3(target.normal)).normalized()
			direction = (up * 0.92 + across * (-0.27 if zone.ends_with("r") else 0.27)).normalized()
			if state.has("chest_finish"):
				direction = -rig.global_basis.z
			if state.get("chest_patches", {}).has(zone):
				normal = target.normal
				point = target.point
			point += direction.slide(normal) * clampf(-drag.y * 0.065, -0.018, 0.018)
		else:
			direction = Vector3.UP
			point += Vector3.UP * drag.y * 0.035
		if grab.has("switch_from"):
			var before: Vector3 = grab.switch_from
			point = before.lerp(point, Pose.smooth((time - float(grab.switched_at)) / 0.26))
		var profile: ContactSurface.SurfaceQuery
		var mesh_axis := normal
		if (standing_touch or surface_hand) and not patch.is_empty():
			if not state.has("kind_surface_query"):
				state.kind_surface_query = ContactSurface.SurfaceQuery.new()
			profile = ContactSurface.profile(patch, rig, target.point, normal, state.kind_surface_query)
			var thigh := zone.begins_with("hip")
			var surface := ContactSurface.touch_surface(profile, point, normal, 0.04 if thigh else 0.085)
			if not surface.is_empty():
				if not thigh:
					point = surface.point
				var follow := 0.30 if thigh else (0.88 if surface_hand else 0.42)
				var desired := normal.lerp(surface.normal, follow).normalized()
				var previous: Vector3 = grab.get("surface_normal", normal)
				normal = previous.lerp(desired, 1.0 - exp(-delta * 21.0)).normalized()
				grab.surface_normal = normal
			if thigh:
				profile = null
		grab.last_point = point
		guide_hand(player_rig, side, zone, point, normal, direction, weight, special, true, standing_touch,
			profile, mesh_axis, surface_hand)
		weights[side] = weight
		targets += point * weight
		total += weight
	state.hand_weights = weights
	state.focus_point = targets / total if total > 0.001 else at.point


func offered_hand(rig: Skeleton3D, zone: String, fallback: Vector3, time: float, weight: float) -> Dictionary:
	var side := zone.right(1).to_upper()
	var wrist := rig.find_bone("cf_j_hand_" + side)
	var middle := rig.find_bone("cf_j_middle01_" + side)
	var index := rig.find_bone("cf_j_index01_" + side)
	var little := rig.find_bone("cf_j_little01_" + side)
	var elbow := rig.find_bone("cf_j_forearm01_" + side)
	if mini(mini(wrist, middle), mini(index, mini(little, elbow))) < 0:
		return {}
	var to_player := (Vector3(state.player.global_position) - fallback).slide(Vector3.UP).normalized()
	var offer := Pose.smooth((time - float(state.approach) * 0.45) / 0.50) * weight
	var lift := (Vector3.UP * (0.070 + sin(time * 3.1) * 0.012 + drag.y * 0.065)
		+ to_player * (0.073 + drag.x * 0.055))
	var start := rig.get_bone_global_pose(wrist).origin
	Pose.reach(rig, side, start + rig.global_basis.inverse() * lift, offer,
		Vector3(-0.48 if side == "L" else 0.48, -0.9, 0.31))
	var posed_wrist := rig.get_bone_global_pose(wrist).origin
	var posed_elbow := rig.get_bone_global_pose(elbow).origin
	var palm_out := (to_player + Vector3.UP * 0.32).normalized()
	var finger_axis := (rig.global_basis * (posed_wrist - posed_elbow)).slide(palm_out).normalized()
	var inverse := rig.global_basis.inverse()
	Pose.align_palm(rig, side, (inverse * finger_axis).normalized(), (inverse * palm_out).normalized(), offer * 0.72)
	shape_fingers(rig, side, "hold", offer, 0.42)
	var origin := rig.to_global(rig.get_bone_global_pose(wrist).origin)
	var knuckle := rig.to_global(rig.get_bone_global_pose(middle).origin)
	var span := rig.global_basis * (rig.get_bone_global_pose(index).origin - rig.get_bone_global_pose(little).origin)
	var fingers := origin.direction_to(knuckle)
	var normal := fingers.cross(span).normalized() * (1.0 if side == "L" else -1.0)
	normal = palm_out.lerp(normal, 0.58).normalized()
	var across := span.normalized()
	return {"point": origin.lerp(knuckle, 0.67), "normal": normal,
		"fingers": (across * 0.66 - fingers * 0.52).normalized()}


func gentle_hand_weight(grab: Dictionary, time: float, strength: float) -> float:
	if grab.has("released"):
		return float(grab.release_weight) * Pose.smooth((0.49 + float(grab.released) - time) / 0.49)
	return strength * Pose.smooth((time - float(grab.started)) / 0.36)


func surface_down(rig: Skeleton3D, zone: String, normal: Vector3) -> Vector3:
	var direction := Vector3.DOWN
	var side := zone.right(1).to_upper()
	var first := -1
	var last := -1
	if zone.begins_with("hip") or zone.begins_with("inner"):
		first = rig.find_bone("cf_j_thigh00_" + side)
		last = rig.find_bone("cf_j_leg01_" + side)
	elif zone.begins_with("foot") or zone.begins_with("leg"):
		first = rig.find_bone("cf_j_leg01_" + side)
		last = rig.find_bone("cf_j_foot_" + side)
	elif zone.begins_with("seat") or zone.begins_with("flank"):
		first = rig.find_bone("cf_j_spine03")
		last = rig.find_bone("cf_j_hips")
	if mini(first, last) >= 0:
		direction = rig.global_basis * (rig.get_bone_global_pose(last).origin - rig.get_bone_global_pose(first).origin)
	var tangent := direction.slide(normal.normalized())
	if tangent.length_squared() <= 0.0001:
		tangent = (-rig.global_basis.z).slide(normal.normalized())
	return tangent.normalized()


func uses_surface_hand(zone: String) -> bool:
	if state.seated:
		return false
	return (state.posture == "fours" and (state.fours_lap or zone.begins_with("seat_") or zone.begins_with("foot_"))) or (
		state.posture == "lie_back" and (zone == "lap" or zone.begins_with("chest_"))) or (
		state.posture == "standing" and (zone.begins_with("flank_") or zone.begins_with("seat_")))


func fours_foot_surface(rig: Skeleton3D, target: Dictionary) -> Dictionary:
	var bone: int = target.bone
	var surface := anchor(rig, bone, Vector3(0.0, -0.020, -0.104), Vector3.UP)
	var observer := Vector3(state.player_origin) + Vector3.UP * 0.65
	var toward := Vector3(surface.point).direction_to(observer)
	surface.normal = (toward + Vector3.UP * 0.42).normalized()
	surface.bone = bone
	return surface


func guide_hand(rig: Skeleton3D, side: String, zone: String, point: Vector3, normal: Vector3,
		direction: Vector3, weight: float, special: float, use_authored := true, standing_touch := false,
		body_surface: ContactSurface.SurfaceQuery = null, mesh_axis := Vector3.ZERO, surface_hand := false) -> void:
	var tactile := zone == "chin" and special > 0.02
	var fingertip := tactile or zone == "lips"
	var support := zone == "chin" and not tactile
	var plane := Vector3.UP if support else normal
	var fingers := direction if fingertip else direction.slide(plane).normalized()
	if fingers.length_squared() < 0.005:
		var tangent := Vector3.FORWARD if absf(plane.y) > 0.9 else Vector3.UP
		fingers = tangent.slide(plane).normalized()
	var palm := Vector3.UP if support else -normal
	if fingertip:
		palm = (-Vector3.UP).slide(fingers).normalized()
	var outward := -1.0 if side == "L" else 1.0
	var elbow := Vector3(outward * 0.55, -0.75, 0.22)
	if zone == "lap" or zone.begins_with("flank") or zone.begins_with("seat"):
		elbow = Vector3(outward * 0.82, -0.52, 0.16)
	if standing_touch:
		if zone == "crown":
			elbow = Vector3(outward * 0.54, -0.90, 0.42)
		elif support:
			var forward := -rig.global_basis.z
			fingers = (fingers * 0.78 + forward.slide(Vector3.UP).normalized() * 0.48).normalized()
			palm = (Vector3.UP - normal * 0.19).slide(fingers).normalized()
			elbow = Vector3(outward * 0.24, -0.92, 0.37)
		elif zone == "belly" or zone.begins_with("hip") or zone.begins_with("seat") or zone.begins_with("flank"):
			var shoulder := rig.find_bone("cf_j_arm00_" + side)
			if shoulder >= 0:
				var toward := (point - rig.to_global(rig.get_bone_global_pose(shoulder).origin)).slide(plane).normalized()
				if not toward.is_zero_approx():
					fingers = fingers.lerp(toward, 0.38).normalized()
			if zone.begins_with("hip"):
				elbow = Vector3(outward * 0.49, -0.82, 0.25)
			else:
				elbow = Vector3(outward * 0.60, -0.72, 0.30)
		elif zone.begins_with("hand"):
			elbow = Vector3(outward * 0.54, -0.73, 0.29)
	if surface_hand and not standing_touch:
		elbow = Vector3(outward * 0.68, 0.30, 0.70)
		if state.posture == "fours" and zone == "lap":
			elbow.y = -0.45
	elif surface_hand and zone.begins_with("seat_"):
		elbow = Vector3(outward * 0.86, -0.34, 0.43)
	var grip := "palm"
	if fingertip:
		grip = "tip"
	elif support:
		grip = "support"
	elif zone.begins_with("cheek"):
		grip = "pinch"
	var chest_patch: Array = state.get("chest_patches", {}).get(zone, [])
	var chest_surface: ContactSurface.SurfaceQuery
	var chest_axis := normal
	if not chest_patch.is_empty():
		if not state.has("chest_surface_query"):
			state.chest_surface_query = ContactSurface.SurfaceQuery.new()
		chest_surface = ContactSurface.profile(chest_patch, state.rig, point, normal, state.chest_surface_query)
		if surface_hand:
			var hit := ContactSurface.touch_surface(chest_surface, point, normal, 0.085)
			if not hit.is_empty():
				point = hit.point
				normal = normal.lerp(hit.normal, 0.55).normalized()
				palm = -normal
				state.hands[side].last_point = point
		else:
			var front := ContactSurface.front(chest_surface, Vector3.ZERO)
			if front > -INF:
				point += normal * front
	var clearance := lerpf(0.026, 0.012, special) if zone == "lap" else 0.014
	if zone.begins_with("hip") or zone.begins_with("inner"):
		clearance = 0.017
	elif zone.begins_with("chest"):
		clearance = 0.010 if chest_surface else 0.027
	elif zone.begins_with("flank"):
		clearance = 0.024
	elif fingertip:
		clearance = lerpf(0.012, 0.001, special)
	if surface_hand and not standing_touch:
		clearance = 0.018 + (0.12 if state.has("chest_finish") else 0.050) * sin(weight * PI)
	var local_fingers := (rig.global_basis.inverse() * fingers).normalized()
	var local_palm := (rig.global_basis.inverse() * palm).normalized()
	var style := "touch"
	var pressure := 0.55
	if zone.begins_with("chest"):
		style = "cup"
		pressure += absf(drag.x) * 0.85
	elif zone.begins_with("cheek"):
		style = "pinch"
	elif support:
		style = "support"
	elif fingertip:
		style = "point"
		pressure = 0.76 if tactile else 0.55
	elif zone == "crown" and state.get("hostile_hold") == "hair":
		style = "grip"
	elif zone.begins_with("hand"):
		style = "grip" if not standing_touch else "hold"
		pressure = 0.77 + 0.15 * drag.length() if standing_touch else pressure
	shape_fingers(rig, side, style, weight, pressure)
	var profile := "chest" if zone.begins_with("chest") else ("seat" if zone.begins_with("seat") else zone)
	if use_authored and hand_profiles.has(profile):
		apply_authored_fingers(rig, side, profile, weight, special)
	var contact_point := rig.to_local(point + normal * clearance)
	var tangent_elbow: bool = surface_hand and (zone.begins_with("foot_") or
		(standing_touch and zone.begins_with("seat_")) or (state.posture == "lie_back" and zone == "lap"))
	if tangent_elbow:
		var hand := rig.find_bone("cf_j_hand_" + side)
		if hand >= 0:
			var span := rig.get_bone_global_pose(hand).origin.distance_to(Pose.contact_landmark(rig, side, grip))
			elbow = Pose.surface_elbow(rig, side, contact_point - local_fingers * span, local_palm, elbow)
	var needs_reach: bool = state.get("seated", false) or (state.get("planted_crouch", false)
		and (zone in SPREAD_ZONES or surface_hand))
	if needs_reach and state.hands.size() == 1:
		var hand := rig.find_bone("cf_j_hand_" + side)
		if hand >= 0:
			var wrist := rig.get_bone_global_pose(hand).origin
			var span := wrist.distance_to(Pose.contact_landmark(rig, side, grip))
			extend_reach(rig, side, contact_point - local_fingers * span, weight)
	if zone == "crown" and state.get("posture", "standing") == "standing":
		var shoulder := rig.find_bone("cf_j_arm00_" + side)
		var forearm := rig.find_bone("cf_j_forearm01_" + side)
		var hand := rig.find_bone("cf_j_hand_" + side)
		if mini(shoulder, mini(forearm, hand)) >= 0:
			var origin := rig.get_bone_global_pose(shoulder).origin
			var elbow_position := rig.get_bone_global_pose(forearm).origin
			var wrist := rig.get_bone_global_pose(hand).origin
			var span := Pose.contact_landmark(rig, side, grip).distance_to(wrist)
			var wrist_target := contact_point - local_fingers * span
			var reach := origin.distance_to(elbow_position) + elbow_position.distance_to(wrist) - 0.018
			var shortfall := clampf(origin.distance_to(wrist_target) - reach, 0.0, 0.065)
			shift_bone(rig, "cf_j_arm00_" + side, origin.direction_to(wrist_target) * shortfall * weight)
	var surface_wrist := standing_touch and (zone == "belly" or zone.begins_with("flank") or zone.begins_with("seat"))
	Pose.plant_hand(rig, side, contact_point, local_fingers, local_palm, weight, elbow, grip, surface_wrist, surface_hand)
	if chest_surface:
		clear_hand_surface(rig, side, chest_axis, elbow, chest_surface, weight)
	elif body_surface and weight > 0.25:
		clear_hand_surface(rig, side, mesh_axis, elbow, body_surface, weight, standing_touch or not surface_hand,
			zone == "belly" or zone.begins_with("flank"))
	elif zone.begins_with("chest") and weight > 0.25:
		var penetration := hand_plane_depth(rig, side, point, normal)
		if penetration > 0.0:
			var correction := rig.global_basis.inverse() * (normal * minf(penetration + 0.008, 0.09))
			Pose.plant_hand(rig, side, contact_point + correction, local_fingers, local_palm, weight, elbow, grip)
	if support or grip == "pinch":
		var seated := Pose.smooth((weight - 0.46) / 0.54)
		var digits := ["index", "middle"] if support else ["index", "thumb"]
		var width := local_fingers.cross(local_palm).normalized() * 0.009
		seat_finger(rig, side, digits[0], contact_point + width, seated)
		seat_finger(rig, side, digits[1], contact_point - width, seated)


func clear_hand_surface(rig: Skeleton3D, side: String, normal: Vector3,
		elbow: Vector3, surface: ContactSurface.SurfaceQuery, weight: float,
		outward_only := false, sparse := false) -> void:
	var sample_key := "body_hand_samples" if outward_only else "chest_hand_samples"
	var samples: Dictionary = state.get_or_add(sample_key, {})
	if not samples.has(side):
		samples[side] = ContactSurface.hand_samples(state.player, rig, side, 0.016 if sparse else 0.008)
	var hand := rig.find_bone("cf_j_hand_" + side)
	if hand < 0:
		return
	var outward := rig.global_basis.inverse() * normal
	var depth := ContactSurface.hand_depth(surface, samples[side], rig)
	var margin := 0.006 if sparse else 0.0025
	for attempt in range(2):
		if not is_finite(depth):
			break
		var move := clampf(depth + margin, -0.034, 0.14)
		if outward_only:
			move = clampf(move, 0.0, 0.055) * Pose.smooth((weight - 0.25) / 0.75)
		if move < 0.0:
			move *= Pose.smooth((weight - 0.75) / 0.25)
		if absf(move) < 0.001:
			break
		var pose := rig.get_bone_global_pose(hand)
		Pose.reach(rig, side, pose.origin + outward * move, 1.0, elbow)
		pose.origin = rig.get_bone_global_pose(hand).origin
		rig.set_bone_global_pose(hand, pose)
		depth = ContactSurface.hand_depth(surface, samples[side], rig)
	state.hands[side].mesh_depth = maxf(0.0, depth)
	state.hands[side].mesh_clearance = maxf(0.0, -depth) if is_finite(depth) else -1.0


func hand_plane_depth(rig: Skeleton3D, side: String, point: Vector3, normal: Vector3) -> float:
	var depth := 0.0
	for name in ["hand", "index02", "middle02", "ring02", "little02"]:
		var bone := rig.find_bone("cf_j_" + name + "_" + side)
		if bone >= 0:
			var world := rig.to_global(rig.get_bone_global_pose(bone).origin)
			depth = maxf(depth, -(world - point).dot(normal))
	return depth


func apply_authored_fingers(rig: Skeleton3D, side: String, profile: String, strength: float, special: float) -> void:
	var variants: Array = hand_profiles[profile][side]
	var neutral: Dictionary = variants[0]
	var active: Dictionary = variants[1]
	var amount := clampf(maxf(drag.length() * 3.1, special), 0.0, 1.0)
	var timeline := fposmod(float(state.elapsed) * 3.6, 8.0)
	var phase := 4.0 - absf(timeline - 4.0)
	var sample := mini(floori(phase), 3)
	var blend := phase - sample
	for name: String in neutral:
		var bone := rig.find_bone(name)
		if bone < 0:
			continue
		var from := finger_sample(neutral[name], sample, blend)
		var to := finger_sample(active[name], sample, blend)
		var rest := rig.get_bone_rest(bone).basis.get_rotation_quaternion()
		var pose := rig.get_bone_pose_rotation(bone)
		rig.set_bone_pose_rotation(bone, pose.slerp(rest * from.slerp(to, amount), strength * 0.88))


func finger_sample(keys: Array, sample: int, blend: float) -> Quaternion:
	var a: Array = keys[sample]
	var b: Array = keys[sample + 1]
	return Quaternion(a[0], a[1], a[2], a[3]).normalized().slerp(
		Quaternion(b[0], b[1], b[2], b[3]).normalized(), blend)


func seat_finger(rig: Skeleton3D, side: String, digit: String, point: Vector3, weight: float) -> void:
	var joint := rig.find_bone("cf_j_" + digit + "02_" + side)
	var tip := rig.find_bone("cf_j_" + digit + "03_" + side)
	if mini(joint, tip) < 0:
		return
	var origin := rig.get_bone_global_pose(joint).origin
	var current := (rig.get_bone_global_pose(tip).origin - origin).normalized()
	var desired := (point - origin).normalized()
	if current.is_zero_approx() or desired.is_zero_approx():
		return
	var aligned := Pose.wrist_cone(current, desired, deg_to_rad(19.0))
	Pose.aim(rig, joint, tip, origin + aligned, weight)


func shift_bone(rig: Skeleton3D, name: String, offset: Vector3) -> void:
	var bone := rig.find_bone(name)
	if bone < 0:
		return
	var parent := rig.get_bone_parent(bone)
	if parent >= 0:
		offset = rig.get_bone_global_pose(parent).basis.inverse() * offset
	rig.set_bone_pose_position(bone, rig.get_bone_pose_position(bone) + offset)


func shift_waistband(rig: Skeleton3D, weight: float) -> void:
	var hips := rig.find_bone("cf_j_hips")
	if hips < 0:
		return
	var center := rig.get_bone_global_rest(hips).origin
	for bone: int in state.get("hem_bones", []):
		var joint := String(rig.get_bone_name(bone))
		if not joint.ends_with("_00"):
			continue
		var position := rig.get_bone_global_rest(bone).origin - center
		var front := Pose.smooth((0.01 - position.z) / 0.075)
		shift_bone(rig, joint, Vector3(0, 0.018, -0.025) * weight * front)


func chest_spring(rig: Skeleton3D, zone: String, delta: float, weight: float) -> void:
	var spring: Vector2 = state.compression.get(zone, Vector2.ZERO)
	var aim := (0.012 + absf(drag.x) * 0.023) * weight
	spring.y += ((aim - spring.x) * 104.0 - spring.y * 14.0) * delta
	spring.x += spring.y * delta
	state.compression[zone] = spring
	var side := zone.right(1).to_upper()
	for segment in ["02", "03"]:
		for prefix in ["cf_d_bust", "cf_j_bust"]:
			var offset := Vector3(drag.x * 0.013 * weight, -absf(drag.y) * 0.012 * weight, spring.x) * 0.61
			shift_bone(rig, prefix + segment + "_" + side, offset)


func shape_fingers(rig: Skeleton3D, side: String, style: String, weight: float, pressure: float) -> void:
	var wrist := rig.find_bone("cf_j_hand_" + side)
	var index := rig.find_bone("cf_j_index01_" + side)
	var middle := rig.find_bone("cf_j_middle01_" + side)
	var little := rig.find_bone("cf_j_little01_" + side)
	if mini(mini(wrist, index), mini(middle, little)) < 0:
		return
	var forward := (rig.get_bone_global_pose(middle).origin - rig.get_bone_global_pose(wrist).origin).normalized()
	var across := rig.get_bone_global_pose(index).origin - rig.get_bone_global_pose(little).origin
	var palm := forward.cross(across).normalized() * (1.0 if side == "L" else -1.0)
	var profiles := {
		"touch": Vector3(13, 20, 10), "cup": Vector3(28, 43, 24), "pinch": Vector3(24, 38, 22),
		"support": Vector3(21, 30, 16), "point": Vector3(48, 63, 37), "grip": Vector3(37, 56, 31),
		"hold": Vector3(30, 42, 22),
	}
	var angles: Vector3 = profiles[style]
	for digit in ["index", "middle", "ring", "little"]:
		for joint in [1, 2, 3]:
			var bone := rig.find_bone("cf_j_%s0%d_%s" % [digit, joint, side])
			var child := rig.find_bone("cf_j_%s0%d_%s" % [digit, joint + 1, side])
			if mini(bone, child) < 0:
				continue
			var straight := rig.get_bone_rest(bone).basis.orthonormalized().get_rotation_quaternion()
			var current := rig.get_bone_pose_rotation(bone)
			rig.set_bone_pose_rotation(bone, current.slerp(straight, weight))
			var from := rig.get_bone_global_pose(bone).origin
			var to := rig.get_bone_global_pose(child).origin
			var axis := (to - from).normalized().cross(palm).normalized()
			var amount := angles[joint - 1] * pressure
			if digit == "index" and style == "point":
				amount = 3.0
			elif digit == "little":
				amount *= 1.12
			if not axis.is_zero_approx():
				var parent := rig.get_bone_parent(bone)
				var local := rig.get_bone_global_pose(parent).basis.orthonormalized().inverse() * axis
				var bend := Quaternion(local, deg_to_rad(amount) * weight)
				rig.set_bone_pose_rotation(bone, (bend * rig.get_bone_pose_rotation(bone)).normalized())
	var thumb := rig.find_bone("cf_j_thumb02_" + side)
	var tip := rig.find_bone("cf_j_thumb03_" + side)
	if style in ["support", "pinch", "cup", "grip", "hold"] and mini(thumb, tip) >= 0:
		var pad := rig.get_bone_global_pose(index).origin
		var endpoint := rig.get_bone_global_pose(tip).origin
		Pose.aim(rig, thumb, tip, endpoint.lerp(pad, 0.18), weight * pressure)


func set_surface_contact(actor: Node3D, rig: Skeleton3D, target: Dictionary) -> void:
	var id: String = target.id
	var slots := []
	if id.begins_with("chest"):
		slots = ["Top", "Bra"]
	elif id.begins_with("hip") or id.begins_with("inner") or id.begins_with("seat") or id == "lap":
		slots = ["Bottom", "Underwear"]
	elif id == "belly" or id.begins_with("flank"):
		slots = ["Top", "Bottom"]
	elif id.begins_with("foot") or id.begins_with("leg"):
		slots = ["Shoes", "Socks"]
	elif id == "crown":
		slots = ["Hair"]
	if slots.is_empty() and id not in ["chin", "lips"] and not id.begins_with("cheek"):
		return
	var at: Dictionary = target.anchor
	if uses_surface_hand(id) and id.begins_with("foot_") and not state.strike and state.hostile_hold.is_empty():
		at = fours_foot_surface(rig, at)
	var normal: Vector3 = at.normal
	var point: Vector3 = at.point
	if normal.is_zero_approx():
		normal = point.direction_to(game.room.camera.global_position)
	var chest_patch: bool = id.begins_with("chest") and not state.strike and state.hostile_hold.is_empty()
	var kind_patch: bool = not state.get("seated", false) and not state.strike and state.hostile_hold.is_empty() and (
		uses_surface_hand(id) or (state.posture == "standing" and (id == "belly" or id.begins_with("flank")
			or id.begins_with("hip") or id.begins_with("seat"))))
	var baked_meshes: Variant = {} if chest_patch or kind_patch else null
	var hit := find_skin_hit(actor, {"origin": point + normal * 0.32, "ray": -normal,
		"depth": 0.32, "anchor": at}, slots, baked_meshes)
	if not hit.is_empty():
		if (id == "chin" or id.begins_with("cheek")) and point.distance_to(hit.world) > 0.055:
			return
		var transform := rig.get_bone_global_pose(at.bone)
		var surface_normal: Vector3 = hit.normal
		var direction := (rig.global_basis * transform.basis).transposed() * surface_normal
		state.contact_surfaces[id] = {"offset": transform.affine_inverse() * rig.to_local(hit.world),
			"normal": direction, "world": hit.world, "triangle": bind_contact_triangle(hit, actor, rig)}
	if chest_patch:
		var patches: Dictionary = state.get_or_add("chest_patches", {})
		patches[id] = ContactSurface.patch(actor, point, normal, baked_meshes)
	elif kind_patch:
		var patches: Dictionary = state.get_or_add("kind_surface_patches", {})
		var torso := id == "belly" or id.begins_with("flank")
		patches[id] = ContactSurface.patch(actor, point, normal, baked_meshes, slots, torso,
			0.15 if torso else ContactSurface.PATCH_RADIUS)


func bind_contact_triangle(hit: Dictionary, actor: Node3D, rig: Skeleton3D) -> Dictionary:
	var part := actor.get_node_or_null(NodePath(hit.part)) as MeshInstance3D
	if not part or not part.mesh or not part.skin:
		return {}
	var arrays := part.mesh.surface_get_arrays(hit.surface)
	var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var joints: PackedInt32Array = arrays[Mesh.ARRAY_BONES]
	var weights: PackedFloat32Array = arrays[Mesh.ARRAY_WEIGHTS]
	if joints.size() != vertices.size() * 4:
		return {}
	var bindings := []
	for index: int in hit.vertices:
		if index >= vertices.size():
			return {}
		var influences := []
		for component in range(4):
			var slot := index * 4 + component
			var joint := joints[slot]
			if joint < 0 or joint >= part.skin.get_bind_count() or weights[slot] <= 0.0:
				continue
			var bone := part.skin.get_bind_bone(joint)
			if bone >= 0 and bone < rig.get_bone_count():
				influences.append([bone, part.skin.get_bind_pose(joint) * vertices[index], weights[slot]])
		if influences.is_empty():
			return {}
		bindings.append(influences)
	return {"part": part, "vertices": bindings, "bary": hit.bary}


func surface_pose(rig: Skeleton3D, target: Dictionary, fabric: Dictionary) -> Dictionary:
	var triangle: Dictionary = fabric.triangle
	var bone := rig.global_transform * rig.get_bone_global_pose(target.bone)
	var normal := (bone.basis.inverse().transposed() * Vector3(fabric.normal)).normalized()
	if not triangle.is_empty() and is_instance_valid(triangle.part) and triangle.part.visible:
		var points: Array[Vector3] = []
		var mesh: MeshInstance3D = triangle.part
		for vertex: Array in triangle.vertices:
			var position := Vector3.ZERO
			for influence: Array in vertex:
				position += (rig.get_bone_global_pose(influence[0]) * Vector3(influence[1])) * float(influence[2])
			points.append(mesh.to_global(position))
		var a := points[0]
		var b := points[1]
		var c := points[2]
		var weights: Vector3 = triangle.bary
		var face := (b - a).cross(c - a).normalized()
		if face.dot(normal) < 0.0:
			face = -face
		var point := a * weights.x + b * weights.y + c * weights.z
		var fallback: Vector3 = bone * Vector3(fabric.offset)
		if point.distance_squared_to(fallback) < 0.0121:
			return {"point": point, "normal": face if not face.is_zero_approx() else normal}
	return {"point": bone * Vector3(fabric.offset), "normal": normal}


func find_skin_hit(actor: Node3D, cursor_hit: Dictionary, garments: Array = [],
		baked_meshes: Variant = null) -> Dictionary:
	var out: Dictionary = {}
	if DisplayServer.get_name() == "headless":
		return out
	var origin: Vector3 = cursor_hit.origin
	var ray: Vector3 = cursor_hit.ray
	var center: Vector3 = cursor_hit.anchor.point
	var tolerance := 0.22 if not garments.is_empty() else 0.145
	var limit := float(cursor_hit.depth) + tolerance
	for part in actor.get_children():
		if part is not MeshInstance3D or not part.visible or not part.skin:
			continue
		var part_name: String = part.name.to_lower()
		var worn: String = part.get_meta("wardrobe_slot", "")
		if not (part_name.begins_with("o_body") or part_name == "cf_o_face" or worn in garments):
			continue
		var skin: ArrayMesh = part.bake_mesh_from_current_skeleton_pose()
		if baked_meshes != null:
			baked_meshes[part] = skin
		if not skin:
			continue
		var local_origin: Vector3 = part.to_local(origin)
		var local_ray: Vector3 = part.global_basis.inverse() * ray
		var local_center: Vector3 = part.to_local(center)
		for surface in range(skin.get_surface_count()):
			var Arrays := skin.surface_get_arrays(surface)
			var vertices: PackedVector3Array = Arrays[Mesh.ARRAY_VERTEX]
			var triangles: PackedInt32Array = Arrays[Mesh.ARRAY_INDEX]
			var uv: PackedVector2Array = Arrays[Mesh.ARRAY_TEX_UV]
			if uv.is_empty():
				continue
			for index in range(0, triangles.size(), 3):
				var a := triangles[index]
				var b := triangles[index + 1]
				var c := triangles[index + 2]
				var va := vertices[a]
				var vb := vertices[b]
				var vc := vertices[c]
				if minf(va.distance_squared_to(local_center), minf(vb.distance_squared_to(local_center),
						vc.distance_squared_to(local_center))) > 0.045:
					continue
				var hit = Geometry3D.ray_intersects_triangle(local_origin, local_ray, va, vb, vc)
				if hit == null:
					continue
				var world: Vector3 = part.to_global(hit)
				var distance := (world - origin).dot(ray)
				if distance >= limit or absf(distance - float(cursor_hit.depth)) > tolerance:
					continue
				var weights := Geometry3D.get_triangle_barycentric_coords(hit, va, vb, vc)
				var u := uv[a] * weights.x + uv[b] * weights.y + uv[c] * weights.z
				var diameter := va.distance_to(vb) + vb.distance_to(vc) + vc.distance_to(va)
				var uv_size := uv[a].distance_to(uv[b]) + uv[b].distance_to(uv[c]) + uv[c].distance_to(uv[a])
				limit = distance
				var global_basis: Basis = part.global_basis
				var face_normal := (global_basis * (vb - va)).cross(global_basis * (vc - va)).normalized()
				if face_normal.dot(ray) > 0.0:
					face_normal = -face_normal
				out = {"part": part.name, "surface": surface, "uv": u, "world": world, "normal": face_normal,
					"vertices": [a, b, c], "bary": weights,
					"radius": clampf(0.055 * uv_size / maxf(diameter, 0.001), 0.012, 0.075)}
	return out


func add_mark(entry: Dictionary, actor: Node3D, _rig: Skeleton3D, id: String, at: Dictionary) -> void:
	var mark: Dictionary = state.surface
	if mark.is_empty():
		var point: Vector3 = at.point
		var normal: Vector3 = at.normal
		if normal.is_zero_approx():
			normal = (state.player.global_position + Vector3.UP - point).normalized()
		mark = find_skin_hit(actor, {"origin": point + normal * 0.23, "ray": -normal,
			"depth": 0.23, "anchor": at})
	if mark.is_empty():
		return
	mark.erase("world")
	mark.id = id
	if not entry.has("marks"):
		entry.marks = []
	var marks: Array = entry.marks
	var prior := marks.find_custom(func(previous: Dictionary):
		return (previous.part == mark.part and previous.surface == mark.surface and
			previous.uv.distance_to(mark.uv) < mark.radius * 0.60))
	if prior >= 0:
		marks[prior].strength = minf(0.82, marks[prior].strength + 0.09)
	elif marks.size() < MARK_LIMIT:
		mark.strength = 0.56
		marks.append(mark)
	apply_marks(entry, actor)


func select_mark_set(entry: Dictionary, actor: Node3D) -> void:
	if not entry.has("mark_sets"):
		entry.mark_sets = {}
	var identification: String = actor.get_meta("interaction_card", "")
	if not entry.mark_sets.has(identification):
		entry.mark_sets[identification] = []
	entry.marks = entry.mark_sets[identification]


func apply_marks(entry: Dictionary, actor: Node3D) -> void:
	for part in actor.get_children():
		if part is not MeshInstance3D:
			continue
		var part_name: String = part.name.to_lower()
		if not (part_name.begins_with("o_body") or part_name == "cf_o_face"):
			continue
		for surface in range(part.mesh.get_surface_count()):
			var material := part.get_active_material(surface) as ShaderMaterial
			if not material:
				continue
			var hits := PackedVector4Array()
			hits.resize(MARK_LIMIT)
			var count := 0
			for mark: Dictionary in entry.get("marks", []):
				if mark.part != part.name or mark.surface != surface:
					continue
				hits[count] = Vector4(mark.uv.x, mark.uv.y, mark.radius, mark.strength)
				count += 1
			material.set_shader_parameter("impact_marks", hits)
			material.set_shader_parameter("impact_mark_count", count)
