extends RefCounted

var angles: Dictionary = {}
var cheek_offsets := {}
var gaze := Vector2.ZERO
var face_strength := 0.0
var lead_kind := ""
var face_group := ""
var face_preset := -1
var started := false


func reset() -> void:
	angles.clear()
	cheek_offsets.clear()
	gaze = Vector2.ZERO
	face_strength = 0.0
	lead_kind = ""
	face_group = ""
	face_preset = -1
	started = false


func advance(rig: Skeleton3D, contacts: Array[Dictionary], mode: int, delta: float) -> void:
	var targets := {}
	var cheeks := {}
	var weights := {}
	var look_at := Vector3.ZERO
	var look_weight := 0.0
	var best := 0.0
	started = false
	var primary := ""
	for contact in contacts:
		var kind: String = contact.kind
		var side: String = contact.side
		var sign_x := -1.0 if side == "L" else 1.0
		var weight := clampf(contact.amount, 0.0, 1.5)
		var activity: float = clampf(contact.speed * contact.amplitude, 0.25, 2.0)
		var pulse := sin(float(contact.time) * TAU * 0.95) * 0.30 * activity
		var onset := exp(-float(contact.time) * 4.0)
		var priority: float = weight * (1.28 if kind == "crown" else (1.10 if kind in ["foot", "ankle"] else 1.0))
		if priority > best:
			best = priority
			primary = kind
			face_group = String(contact.get("face_group", ""))
			started = onset > 0.53
			var presets: Array = contact.get("face_presets", [])
			face_preset = int(presets[0 if started else 1]) if presets.size() == 2 else -1
		look_at += Vector3(contact.point) * priority
		look_weight += priority
		var travel: Vector3 = contact.get("travel", Vector3.ZERO)
		if kind == "cheek" and mode != 2:
			var stretch := clampf(absf(travel.x) / 0.019, 0.0, 1.0)
			cheeks[side] = maxf(float(cheeks.get(side, 0.0)), stretch * clampf(weight, 0.0, 1.0))
		if mode == 1:
			continue
		match kind:
			"chin":
				var lift := clampf(travel.y / 0.036, 0.0, 1.15)
				for pair in [["cf_j_neck", 3.1], ["cf_j_head", 7.7]]:
					var id := rig.find_bone(pair[0])
					if id >= 0:
						var axis := rig.get_bone_global_rest(id).basis.orthonormalized().inverse().x
						_add(targets, weights, pair[0], axis * lift * float(pair[1]), weight)
			"cheek":
				_add(targets, weights, "cf_j_head", Vector3(0, sign_x * 1.3, sign_x * 1.1) * (0.2 + absf(travel.x) * 20.0), weight)
			"crown":
				_add(targets, weights, "cf_j_head", Vector3(-2.8 * onset, 0, sign_x * (2.0 + pulse)), weight)
			"side", "belly", "thigh":
				_add(targets, weights, "cf_j_spine01", Vector3(0.8 * onset, 0, sign_x * (1.5 + pulse)), weight)
				if kind == "side":
					_add(targets, weights, "cf_j_shoulder_" + side, Vector3(-1.5 * onset, 0, sign_x * (1.5 + pulse)), weight)
			"foot", "ankle":
				var original := float(contact.get("foot_curve", 0.0))
				_add(targets, weights, "cf_j_foot_" + side, Vector3(original * 2.8 + pulse, 0, -sign_x * original * 1.3), weight)
			"chest", "lap", "seat":
				var bone := "cf_j_spine03" if kind == "chest" else "cf_j_spine01"
				_add(targets, weights, bone, Vector3(1.5 * onset, 0, sign_x * pulse), weight)
			"hand":
				_add(targets, weights, "cf_j_shoulder_" + side, Vector3(0, sign_x * (1.0 + pulse), sign_x * 0.65 * onset), weight)
	for bone: String in angles.keys():
		if not targets.has(bone):
			targets[bone] = Vector3.ZERO
			weights[bone] = 1.0
	var damping := 1.0 - exp(-10.0 * delta)
	for side in ["L", "R"]:
		cheek_offsets[side] = lerpf(float(cheek_offsets.get(side, 0.0)), float(cheeks.get(side, 0.0)), damping)
	for bone: String in targets:
		var target: Vector3 = (Vector3(targets[bone]) / maxf(1.0, weights[bone])).limit_length(8.5 if bone == "cf_j_head" else 5.0)
		var value: Vector3 = Vector3(angles.get(bone, Vector3.ZERO)).lerp(target, damping)
		if value.length_squared() < 0.00001 and target.is_zero_approx():
			angles.erase(bone)
		else:
			angles[bone] = value
	var desired := Vector2.ZERO
	var head := rig.find_bone("cf_j_head") if is_instance_valid(rig) else -1
	if mode != 2 and look_weight > 0.0 and head >= 0:
		var frame := rig.global_transform * rig.get_bone_global_pose(head)
		var local := frame.affine_inverse() * (look_at / look_weight)
		if primary == "crown" and local.length() < 0.27:
			desired = Vector2(0, -4.0)
		else:
			desired = Vector2(rad_to_deg(atan2(-local.x, absf(local.z) + 0.12)),
				rad_to_deg(atan2(local.y, Vector2(local.x, local.z).length() + 0.05))).limit_length(12.0)
		desired *= clampf(look_weight, 0.0, 1.0)
	gaze = gaze.lerp(desired, 1.0 - exp(-12.0 * delta))
	face_strength = move_toward(face_strength, clampf(best, 0.0, 1.0) if mode != 2 else 0.0, delta * 4.2)
	if not primary.is_empty():
		lead_kind = primary


func _add(targets: Dictionary, weights: Dictionary, bone: String, amount: Vector3, strength: float) -> void:
	targets[bone] = Vector3(targets.get(bone, Vector3.ZERO)) + amount * strength
	weights[bone] = float(weights.get(bone, 0.0)) + strength
