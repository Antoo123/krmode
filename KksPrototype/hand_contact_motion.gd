extends RefCounted

const Pose := preload("res://npc_pose.gd")
const Surface := preload("res://npc_contact_surface.gd")
const NAMES := {"thigh": "Stroke Thigh", "belly": "Stroke Belly", "hand": "Take Hand"}
const BONES := {"thigh": ["cf_j_thigh00_", "cf_j_leg01_"], "belly": ["cf_j_spine02", "a_n_waist_f"],
	"hand": ["cf_j_hand_", "cf_j_middle01_", "cf_j_index01_", "cf_j_little01_"],
	"side": ["cf_j_spine01"], "foot": ["cf_j_foot_"], "ankle": ["cf_j_leg03_"], "crown": ["cf_j_head"],
	"chest": ["cf_j_bust03_"], "lap": ["cf_j_hips"], "seat": ["cf_j_hips"],
	"chin": ["cf_J_ChinTip_Base"], "cheek": ["cf_j_head"]}

var cache_key := ""
var patch_parts: Array
var query: Surface.SurfaceQuery
var measured := false
var patch_center := Vector3.ZERO
var patch_normal := Vector3.ZERO
var patch_time := -1
var patch_built := -1
var misses := 0


static func bone_name(data: Dictionary) -> String:
	var prefix: String = BONES[data.kind][0]
	return prefix + String(data.side) if prefix.ends_with("_") else prefix


static func weight(preset: Dictionary, time: float) -> float:
	var contact: Dictionary = preset.contact
	return smoothstep(0.0, contact.approach, time) * (1.0 - smoothstep(
		float(preset.duration) - float(contact.release), float(preset.duration), time))


static func held_time(preset: Dictionary, elapsed: float) -> float:
	var contact: Dictionary = preset.contact
	var last := float(preset.duration) - float(contact.release)
	var first := float(contact.approach)
	if elapsed <= last:
		return elapsed
	return first + fposmod(elapsed - first, last - first) if preset.loop else last


static func anchor(rig: Skeleton3D, data: Dictionary) -> Dictionary:
	var side := String(data.side)
	var bone := rig.find_bone(bone_name(data))
	if bone < 0:
		return {}
	var posed := rig.global_transform * rig.get_bone_global_pose(bone)
	var rest := rig.get_bone_global_rest(bone)
	var axis := posed.basis.orthonormalized() * rest.basis.orthonormalized().inverse()
	var along := axis.y
	var outward := -axis.z
	var point := posed.origin
	var fingers := Vector3.ZERO
	match String(data.kind):
		"thigh":
			var knee := rig.find_bone(BONES.thigh[1] + side)
			if knee < 0:
				return {}
			along = (world_joint(rig, knee) - point).normalized()
			var other := rig.find_bone(BONES.thigh[0] + ("R" if side == "L" else "L"))
			var sideways := (point - world_joint(rig, other)).normalized() if other >= 0 else axis.x * (-1.0 if side == "L" else 1.0)
			outward = (outward * 0.65 + sideways * 0.78).slide(along).normalized()
			point = point.lerp(world_joint(rig, knee), 0.43) + outward * 0.037
			fingers = along
		"belly":
			# cf_j_spine02 provides a moving torso frame. The front waist marker
			# provides a second reference but the ray locates the visible surface.
			var waist := rig.find_bone(BONES.belly[1])
			if waist >= 0:
				var delta := (world_joint(rig, waist) - point).dot(along)
				point += along * clampf(delta * 0.35, -0.055, 0.015)
			point += -along * 0.035 + outward * 0.086
			fingers = along
		"side":
			var sternum := rig.find_bone("cf_j_spine03")
			var hips := rig.find_bone("cf_j_hips")
			if sternum >= 0 and hips >= 0:
				along = (world_joint(rig, sternum) - world_joint(rig, hips)).normalized()
				point = point.lerp(world_joint(rig, sternum), 0.25)
			var marker := rig.find_bone("a_n_waist_" + side)
			outward = axis.x * (-1.0 if side == "L" else 1.0) - axis.z * 0.18
			if marker >= 0:
				var direction := (world_joint(rig, marker) - point).slide(along)
				if direction.length() > 0.025:
					outward = direction
			outward = outward.slide(along).normalized()
			point += outward * 0.098
			fingers = along
		"foot", "ankle":
			var foot := rig.find_bone("cf_j_foot_" + side)
			var toe := rig.find_bone("cf_j_toes_" + side)
			if foot < 0 or toe < 0:
				return {}
			var heel := world_joint(rig, foot)
			var tip := world_joint(rig, toe)
			var foot_frame := (rig.global_basis * rig.get_bone_global_pose(foot).basis).orthonormalized()
			var foot_axis := foot_frame * rig.get_bone_global_rest(foot).basis.orthonormalized().inverse()
			var forward := (tip - heel).normalized()
			outward = foot_axis.y.slide(forward).normalized()
			if data.kind == "foot":
				along = forward
				point = heel.lerp(tip, 0.52) + outward * 0.032
			else:
				var ankle := rig.find_bone("a_n_ankle_" + side)
				if ankle >= 0:
					point = world_joint(rig, ankle).lerp(point, 0.65)
				outward = foot_axis.x * (-1.0 if side == "L" else 1.0)
				along = axis.y.slide(outward).normalized()
				point += outward * 0.027
			fingers = along
		"crown":
			var top := rig.find_bone("a_n_headtop")
			if top >= 0:
				var hint := world_joint(rig, top) - point
				if hint.length() > 0.08 and hint.length() < 0.25:
					point += hint
				else:
					point += axis.y * 0.16
			else:
				point += axis.y * 0.16
			outward = axis.y.normalized()
			along = -axis.z
			fingers = along
		"chin":
			outward = (-axis.y * 0.59 - axis.z * 0.81).normalized()
			along = axis.y
			fingers = axis.y
			point += axis * Vector3(0.0, -0.025, -0.014)
		"cheek":
			var sign_x := -1.0 if side == "L" else 1.0
			var cheek := rig.find_bone("cf_J_CheekLow_s_" + side)
			point += axis * Vector3(sign_x * 0.051, 0.044, -0.071)
			if cheek >= 0:
				var bone_point := world_joint(rig, cheek) + axis * Vector3(sign_x * 0.011, 0, -0.024)
				if bone_point.distance_to(point) < 0.06:
					point = point.lerp(bone_point, 0.72)
			outward = (axis.x * sign_x * 0.5 - axis.z * 0.86).normalized()
			along = axis.y
			fingers = along
		"chest":
			point += outward * 0.028
			fingers = along
		"lap":
			point += axis * Vector3(0.0, -0.16, -0.066)
			fingers = along
		"seat":
			outward = axis.z
			point += axis * Vector3(-0.08 if side == "L" else 0.08, -0.11, 0.105)
			fingers = along
		"hand":
			var shape := palm(rig, side, true)
			if shape.is_empty():
				return {}
			along = shape.forward
			outward = shape.normal
			point = shape.center
			fingers = along
			if point.y < 0.12 and outward.y < -0.40:
				outward = -outward
	if outward.is_zero_approx() or along.is_zero_approx():
		return {}
	var right := along.cross(outward).normalized()
	return {"frame": Transform3D(Basis(right, outward.cross(right), outward), point), "fingers": fingers}


func solve(actor: Node3D, hand_rig: Skeleton3D, hand_side: String, preset: Dictionary, local: Transform3D,
		home: Transform3D, amount: float, hand_points: Surface.SkinPoints, model: Node3D) -> Dictionary:
	var rig := actor.get_node("Skeleton") as Skeleton3D
	var data: Dictionary = preset.contact
	var hit := anchor(rig, data)
	var hand := palm(hand_rig, hand_side, false)
	if hit.is_empty() or hand.is_empty():
		return {}
	var frame: Transform3D = hit.frame
	var facial: bool = data.kind in ["chin", "cheek"]
	var probe_x := clampf(local.origin.x, -0.016, 0.016) if facial else local.origin.x
	var probe_y := clampf(local.origin.y, -0.010, 0.003) if data.kind == "chin" else (clampf(local.origin.y, -0.012, 0.012) if facial else local.origin.y)
	var place := frame * Vector3(probe_x, probe_y, 0.0)
	var normal := frame.basis.z
	var rotation := frame.basis * local.basis.orthonormalized() * frame.basis.inverse()
	measured = false
	if data.kind != "hand" and amount > 0.34:
		_refresh_patch(actor, rig, frame, data)
		if query and not patch_parts.is_empty():
			var tolerance := 0.055 if facial else (0.16 if data.kind in ["foot", "ankle"] else 0.13)
			var surface := _nearby_surface(place, frame, tolerance, data.kind in ["side", "foot", "ankle", "crown", "chest", "lap", "seat"])
			if not surface.is_empty():
				place = surface.point
				var raw: Vector3 = surface.normal
				if raw.dot(normal) < 0.0:
					raw = -raw
				if raw.dot(normal) > 0.55:
					normal = normal.lerp(raw, 0.58).normalized()
				measured = true
		if measured:
			misses = 0
		else:
			misses += 1
	if not measured:
		match String(data.kind):
			"thigh", "side", "chest", "lap", "seat":
				place += normal * 0.032
			"foot", "ankle":
				place += normal * 0.026
			"crown":
				place += normal * 0.040
			"chin", "cheek":
				place += normal * 0.007
	var forward: Vector3 = hit.fingers
	forward = forward.slide(normal).normalized()
	if forward.is_zero_approx():
		forward = frame.basis.y
	var facing := Basis.looking_at(forward, -normal) * Basis.looking_at(hand.forward, hand.normal).inverse()
	facing = rotation * facing
	var gap := 0.016 if data.kind == "hand" else 0.004
	var attachment: Vector3 = hand.center
	var tips: Array[Vector3] = []
	if facial:
		var first := hand_rig.find_bone("cf_j_index04_" + hand_side)
		var second := hand_rig.find_bone(("cf_j_middle04_" if data.kind == "chin" else "cf_j_thumb04_") + hand_side)
		if first >= 0 and second >= 0:
			tips = [hand_rig.get_bone_global_pose(first).origin, hand_rig.get_bone_global_pose(second).origin]
			attachment = tips[0].lerp(tips[1], 0.5)
		gap = 0.006 if data.kind == "chin" else 0.011
	var goal := Transform3D(facing, place + normal * (gap + local.origin.z) - facing * attachment)
	if measured and amount > 0.60:
		model.global_transform = goal
		var depth := Surface.hand_depth(query, hand_points, hand_rig)
		if is_finite(depth):
			goal.origin += patch_normal * clampf(depth + 0.002, 0.0, 0.036)
	var world := home.interpolate_with(goal, amount)
	if data.kind in ["side", "foot", "ankle", "crown", "chest", "lap", "seat"]:
		world.origin += normal * sin(PI * amount) * (0.09 if data.kind == "crown" else 0.065)
	return {"world": world, "goal": goal, "anchor": frame,
		"point": place, "normal": normal, "surface": measured,
		"travel": local.origin, "tips": [world * tips[0], world * tips[1]] if tips.size() == 2 else []}


func _nearby_surface(place: Vector3, frame: Transform3D, tolerance: float, search: bool) -> Dictionary:
	var direct := Surface.touch_surface(query, place, patch_normal, tolerance)
	if not direct.is_empty() or not search:
		return direct
	for step in [0.014, 0.029, 0.044]:
		var best := {}
		var distance := INF
		for axis in [frame.basis.y, -frame.basis.y, frame.basis.x, -frame.basis.x]:
			var probe: Vector3 = place + Vector3(axis) * float(step)
			var hit := Surface.touch_surface(query, probe, patch_normal, tolerance)
			if not hit.is_empty():
				var offset: float = Vector3(hit.point).distance_squared_to(place)
				if offset < distance:
					best = hit
					distance = offset
		if not best.is_empty():
			return best
	return {}


func _refresh_patch(actor: Node3D, rig: Skeleton3D, frame: Transform3D, data: Dictionary) -> void:
	var key := "%d/%s/%s" % [actor.get_instance_id(), data.kind, data.side]
	var now := Time.get_ticks_msec()
	if cache_key != key or (misses > 2 and now - patch_built >= 140):
		cache_key = key
		var kind: String = data.kind
		var torso := kind in ["belly", "side", "thigh", "chest", "lap", "seat"]
		var slots := ["Bottom", "Top", "Tights", "Socks", "Underwear", "Bra"]
		var included: Array[String] = []
		var excluded: Array[String] = []
		var radius := 0.31
		if kind in ["belly", "side"]:
			excluded.assign(["cf_j_thigh00_L", "cf_j_thigh00_R"])
		elif kind in ["foot", "ankle"]:
			slots = ["Shoes", "Socks", "Tights"]
			excluded.append("cf_j_thigh00_" + ("R" if data.side == "L" else "L"))
			radius = 0.18
		elif kind in ["chin", "cheek"]:
			slots = []
			included.assign(["cf_o_face"])
			radius = 0.095
		elif kind == "crown":
			slots = ["Hair"]
			included.assign(["cf_o_face"])
			radius = 0.21
		patch_parts = Surface.patch(actor, frame.origin - frame.basis.z * 0.025, frame.basis.z,
			{}, slots, torso, radius, excluded, included)
		patch_time = -1
		patch_built = now
		misses = 0
	if patch_parts.is_empty():
		return
	if not query:
		query = Surface.SurfaceQuery.new()
	if patch_time < 0 or now - patch_time >= 24 or frame.origin.distance_to(patch_center) > 0.015 or frame.basis.z.dot(patch_normal) < 0.985:
		patch_center = frame.origin
		patch_normal = frame.basis.z
		patch_time = now
		Surface.profile(patch_parts, rig, patch_center, patch_normal, query)


static func shape_fingers(rig: Skeleton3D, side: String, kind: String, amount: float) -> void:
	var hand := palm(rig, side, false)
	if hand.is_empty():
		return
	var palm_normal: Vector3 = hand.normal
	var curls := {"index": 4.0, "middle": 7.0, "ring": 42.0, "little": 50.0, "thumb": 13.0}
	if kind == "cheek":
		curls.merge({"index": 18.0 + 20.0 * amount, "middle": 58.0, "thumb": 11.0 + 10.0 * amount}, true)
	for finger: String in curls:
		for segment in range(1, 4):
			var joint := rig.find_bone("cf_j_%s%02d_%s" % [finger, segment, side])
			var next := rig.find_bone("cf_j_%s%02d_%s" % [finger, segment + 1, side])
			if joint < 0 or next < 0:
				continue
			var frame := rig.get_bone_global_pose(joint)
			var along := frame.origin.direction_to(rig.get_bone_global_pose(next).origin)
			var axis := along.cross(palm_normal).normalized()
			if not axis.is_zero_approx():
				var local := frame.basis.orthonormalized().inverse() * axis
				var angle := deg_to_rad(float(curls[finger]) * (1.0 if segment < 3 else 0.55))
				rig.set_bone_pose_rotation(joint, rig.get_bone_pose_rotation(joint) * Quaternion(local, angle))
	if kind == "cheek":
		var index := rig.find_bone("cf_j_index04_" + side)
		var thumb := rig.find_bone("cf_j_thumb02_" + side)
		var tip := rig.find_bone("cf_j_thumb04_" + side)
		if mini(index, mini(thumb, tip)) >= 0:
			var point := rig.get_bone_global_pose(index).origin
			var from := rig.get_bone_global_pose(tip).origin
			var target := point + point.direction_to(from) * lerpf(0.029, 0.017, amount)
			Pose.aim(rig, thumb, tip, target, 0.42 + amount * 0.40)


static func palm(rig: Skeleton3D, side: String, world: bool) -> Dictionary:
	var joints: Array[Vector3] = []
	for prefix: String in BONES.hand:
		var id := rig.find_bone(prefix + side)
		if id < 0:
			return {}
		joints.append(world_joint(rig, id) if world else rig.get_bone_global_pose(id).origin)
	var forward := (joints[1] - joints[0]).normalized()
	var normal := forward.cross(joints[2] - joints[3]).normalized() * (1.0 if side == "L" else -1.0)
	if normal.is_zero_approx():
		return {}
	return {"center": joints[0].lerp(joints[1], 0.64), "forward": forward, "normal": normal}


static func world_joint(rig: Skeleton3D, id: int) -> Vector3:
	return rig.global_transform * rig.get_bone_global_pose(id).origin
