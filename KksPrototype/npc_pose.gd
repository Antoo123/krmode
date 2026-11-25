extends RefCounted


static func capture(skeleton: Skeleton3D) -> Array[Transform3D]:
	var pose: Array[Transform3D] = []
	for bone in range(skeleton.get_bone_count()):
		pose.append(skeleton.get_bone_pose(bone))
	return pose


static func rest(skeleton: Skeleton3D) -> Array[Transform3D]:
	var pose: Array[Transform3D] = []
	for bone in range(skeleton.get_bone_count()):
		pose.append(skeleton.get_bone_rest(bone))
	return pose


static func smooth(value: float) -> float:
	var x := clampf(value, 0.0, 1.0)
	return x * x * (3.0 - 2.0 * x)


static func sample(animation: Animation, skeleton: Skeleton3D, base: Array[Transform3D], time: float) -> Array[Transform3D]:
	var pose: Array[Transform3D] = base.duplicate()
	if not animation:
		return pose
	time = clampf(time, 0.0, animation.length)
	for track in range(animation.get_track_count()):
		var bone := skeleton.find_bone(animation.track_get_path(track).get_subname(0))
		if bone < 0:
			continue
		var transform := pose[bone]
		match animation.track_get_type(track):
			Animation.TYPE_ROTATION_3D:
				transform.basis = Basis(animation.rotation_track_interpolate(track, time)) * Basis.from_scale(transform.basis.get_scale())
			Animation.TYPE_POSITION_3D:
				transform.origin = animation.position_track_interpolate(track, time)
		pose[bone] = transform
	return pose


static func blend(skeleton: Skeleton3D, from: Array[Transform3D], to: Array[Transform3D], weight: float) -> void:
	if weight <= 0.0 or weight >= 1.0:
		var pose := from if weight <= 0.0 else to
		for bone in range(pose.size()):
			skeleton.set_bone_pose(bone, pose[bone])
		return
	for bone in range(from.size()):
		skeleton.set_bone_pose(bone, from[bone].interpolate_with(to[bone], weight))


static func aim(skeleton: Skeleton3D, bone: int, child: int, target: Vector3, weight := 1.0) -> void:
	var origin := skeleton.get_bone_global_pose(bone).origin
	var current := skeleton.get_bone_global_pose(child).origin - origin
	var desired := target - origin
	if current.length_squared() < 0.000001 or desired.length_squared() < 0.000001:
		return
	var parent := skeleton.get_bone_parent(bone)
	var basis := skeleton.get_bone_global_pose(parent).basis.orthonormalized().get_rotation_quaternion()
	var turn := basis.inverse() * Quaternion(current.normalized(), desired.normalized()) * basis
	var previous := skeleton.get_bone_pose_rotation(bone)
	skeleton.set_bone_pose_rotation(bone, previous.slerp((turn * previous).normalized(), weight))


static func reach(skeleton: Skeleton3D, side: String, target: Vector3, weight: float, elbow_hint := Vector3.ZERO) -> void:
	if weight <= 0.0:
		return
	var upper := skeleton.find_bone("cf_j_arm00_" + side)
	var lower := skeleton.find_bone("cf_j_forearm01_" + side)
	var hand := skeleton.find_bone("cf_j_hand_" + side)
	var outward := -1.0 if side == "L" else 1.0
	var pole := elbow_hint if not elbow_hint.is_zero_approx() else Vector3(outward, -0.66, 0.22)
	reach_chain(skeleton, upper, lower, hand, target, weight, pole)


static func reach_chain(skeleton: Skeleton3D, upper: int, lower: int, hand: int,
		target: Vector3, weight: float, hint: Vector3) -> void:
	if upper < 0 or lower < 0 or hand < 0:
		return
	var shoulder := skeleton.get_bone_global_pose(upper).origin
	var elbow := skeleton.get_bone_global_pose(lower).origin
	var wrist := skeleton.get_bone_global_pose(hand).origin
	var upper_length := shoulder.distance_to(elbow)
	var lower_length := elbow.distance_to(wrist)
	var line := target - shoulder
	if line.length_squared() < 0.000001 or minf(upper_length, lower_length) < 0.01:
		return
	var direction := line.normalized()
	var distance := clampf(line.length(), absf(upper_length - lower_length) + 0.002, upper_length + lower_length - 0.004)
	var pole := hint
	pole = (pole - direction * pole.dot(direction)).normalized()
	if pole.is_zero_approx():
		pole = direction.cross(Vector3.FORWARD).normalized()
	var axial := (upper_length * upper_length + distance * distance - lower_length * lower_length) / (2.0 * distance)
	var bend := sqrt(maxf(0.0, upper_length * upper_length - axial * axial))
	var upper_start := skeleton.get_bone_pose_rotation(upper)
	var lower_start := skeleton.get_bone_pose_rotation(lower)
	aim(skeleton, upper, lower, shoulder + direction * axial + pole * bend)
	aim(skeleton, lower, hand, shoulder + direction * distance)
	if weight < 1.0:
		skeleton.set_bone_pose_rotation(upper, upper_start.slerp(skeleton.get_bone_pose_rotation(upper), weight))
		skeleton.set_bone_pose_rotation(lower, lower_start.slerp(skeleton.get_bone_pose_rotation(lower), weight))


static func align_palm(skeleton: Skeleton3D, side: String, fingers: Vector3, palm: Vector3, weight: float,
		surface_wrist := false, preserve_plane := false) -> void:
	var hand := skeleton.find_bone("cf_j_hand_" + side)
	var middle := skeleton.find_bone("cf_j_middle01_" + side)
	var index := skeleton.find_bone("cf_j_index01_" + side)
	var little := skeleton.find_bone("cf_j_little01_" + side)
	if mini(mini(hand, middle), mini(index, little)) < 0 or fingers.is_zero_approx():
		return
	var elbow := skeleton.find_bone("cf_j_forearm01_" + side)
	if elbow >= 0:
		var wrist := skeleton.get_bone_global_pose(hand).origin
		var forearm := (wrist - skeleton.get_bone_global_pose(elbow).origin).normalized()
		if preserve_plane:
			# Use the forearm to choose a comfortable direction within the contact plane.
			var tangent := forearm.slide(palm)
			fingers = fingers.slide(palm).normalized()
			if tangent.length_squared() > 0.0025:
				var roll := tangent.normalized().signed_angle_to(fingers, palm)
				fingers = tangent.normalized().rotated(palm, clampf(roll, -0.38, 0.38))
		elif surface_wrist:
			var tangent := forearm.slide(palm)
			var span := tangent.length()
			if span > 0.001:
				tangent /= span
				var in_plane := fingers.slide(palm).normalized()
				var roll := tangent.signed_angle_to(in_plane, palm)
				var available := acos(clampf(cos(deg_to_rad(71.0)) / span, 0.0, 1.0))
				var follow := smooth((span - 0.12) / 0.31)
				fingers = tangent.rotated(palm, lerpf(roll, clampf(roll, -available, available), follow))
			fingers = wrist_cone(forearm, fingers, deg_to_rad(79.0))
		else:
			fingers = wrist_cone(forearm, fingers, deg_to_rad(71.0))
	var line := (skeleton.get_bone_global_pose(middle).origin - skeleton.get_bone_global_pose(hand).origin).normalized()
	var span := skeleton.get_bone_global_pose(index).origin - skeleton.get_bone_global_pose(little).origin
	var before := line.cross(span).normalized() * (1.0 if side == "L" else -1.0)
	var after := palm.slide(fingers).normalized()
	if before.is_zero_approx() or after.is_zero_approx():
		return
	var source := Basis(line, before, line.cross(before))
	var goal := Basis(fingers, after, fingers.cross(after))
	var parent := skeleton.get_bone_parent(hand)
	var basis := skeleton.get_bone_global_pose(parent).basis.orthonormalized()
	var delta := (basis.inverse() * goal * source.transposed() * basis).orthonormalized().get_rotation_quaternion()
	if delta.w < 0.0:
		delta = -delta
	var twist_axis := (skeleton.get_bone_global_pose(hand).origin - skeleton.get_bone_global_pose(parent).origin).normalized()
	if not twist_axis.is_zero_approx():
		var prior := skeleton.get_bone_pose_rotation(parent)
		var grandparent := skeleton.get_bone_parent(parent)
		var parent_frame := skeleton.get_bone_global_pose(grandparent).basis.orthonormalized()
		var axis_local := basis.inverse() * twist_axis
		var twist := 2.0 * atan2(Vector3(delta.x, delta.y, delta.z).dot(axis_local), delta.w)
		var shared := clampf(twist * 0.47, -0.75, 0.75) * weight
		var rotation := Quaternion(parent_frame.inverse() * twist_axis, shared)
		skeleton.set_bone_pose_rotation(parent, (rotation * prior).normalized())
		delta = (Quaternion(axis_local, -shared) * delta).normalized()
	var rotation_weight := weight if preserve_plane else minf(1.0, 2.35 / maxf(delta.get_angle(), 0.001)) * weight
	var turn := Quaternion.IDENTITY.slerp(delta, rotation_weight)
	skeleton.set_bone_pose_rotation(hand, (turn * skeleton.get_bone_pose_rotation(hand)).normalized())


static func wrist_cone(axis: Vector3, desired: Vector3, maximum: float) -> Vector3:
	if axis.is_zero_approx() or axis.dot(desired) >= cos(maximum):
		return desired
	var tangent := desired.slide(axis).normalized()
	if tangent.is_zero_approx():
		tangent = Vector3.UP.slide(axis).normalized()
	if tangent.is_zero_approx():
		tangent = Vector3.RIGHT.slide(axis).normalized()
	return (axis * cos(maximum) + tangent * sin(maximum)).normalized()


static func surface_elbow(rig: Skeleton3D, side: String, target: Vector3, palm: Vector3, hint: Vector3) -> Vector3:
	var upper := rig.find_bone("cf_j_arm00_" + side)
	var lower := rig.find_bone("cf_j_forearm01_" + side)
	var hand := rig.find_bone("cf_j_hand_" + side)
	if mini(upper, mini(lower, hand)) < 0:
		return hint
	var shoulder := rig.get_bone_global_pose(upper).origin
	var elbow := rig.get_bone_global_pose(lower).origin
	var wrist := rig.get_bone_global_pose(hand).origin
	var upper_length := shoulder.distance_to(elbow)
	var lower_length := elbow.distance_to(wrist)
	var line := shoulder.direction_to(target)
	var normal := palm.slide(line)
	if normal.length_squared() < 0.01 or minf(upper_length, lower_length) < 0.01 or line.is_zero_approx():
		return hint
	var reach_distance := clampf(shoulder.distance_to(target), absf(upper_length - lower_length) + 0.002,
		upper_length + lower_length - 0.004)
	var axial := (upper_length * upper_length + reach_distance * reach_distance - lower_length * lower_length) / (2.0 * reach_distance)
	var bend := sqrt(maxf(0.0, upper_length * upper_length - axial * axial))
	var depth_step := bend * normal.length()
	if depth_step < 0.005:
		return hint
	var depth_axis := normal.normalized()
	var tangent := hint.slide(line).slide(depth_axis).normalized()
	if tangent.is_zero_approx():
		return hint
	# Keep the elbow outside the surface while bringing the forearm closer to its tangent.
	var depth := ((line * (reach_distance - axial)).dot(palm) - lower_length * 0.36) / depth_step
	var blend := clampf(depth, -0.88, 0.88)
	return (tangent * sqrt(1.0 - blend * blend) + depth_axis * blend).lerp(hint.normalized(), 0.18)


static func contact_landmark(rig: Skeleton3D, side: String, grip: String) -> Vector3:
	var wrist := rig.find_bone("cf_j_hand_" + side)
	if wrist < 0:
		return Vector3.ZERO
	var start := rig.get_bone_global_pose(wrist).origin
	var index := rig.find_bone(("cf_j_index04_" if grip == "tip" else "cf_j_index03_") + side)
	if grip == "tip" and index >= 0:
		return rig.get_bone_global_pose(index).origin
	var thumb := rig.find_bone("cf_j_thumb03_" + side)
	if grip == "pinch" and mini(index, thumb) >= 0:
		return rig.get_bone_global_pose(index).origin.lerp(rig.get_bone_global_pose(thumb).origin, 0.48)
	var knuckle := rig.find_bone("cf_j_middle01_" + side)
	if grip == "support" and knuckle >= 0:
		var pad := rig.find_bone("cf_j_index02_" + side)
		if pad >= 0:
			return rig.get_bone_global_pose(knuckle).origin.lerp(rig.get_bone_global_pose(pad).origin, 0.53)
	return start.lerp(rig.get_bone_global_pose(knuckle).origin, 0.75) if knuckle >= 0 else start


static func plant_hand(rig: Skeleton3D, side: String, target: Vector3, fingers: Vector3, palm: Vector3,
		weight: float, elbow: Vector3, grip: String, surface_wrist := false, preserve_plane := false) -> void:
	var hand := rig.find_bone("cf_j_hand_" + side)
	if hand < 0:
		return
	fingers = fingers.normalized()
	var wrist := rig.get_bone_global_pose(hand).origin
	var span := contact_landmark(rig, side, grip).distance_to(wrist)
	var goal := target - fingers * span
	var shoulder := rig.find_bone("cf_j_arm00_" + side)
	var line := (goal - rig.get_bone_global_pose(shoulder).origin).normalized() if shoulder >= 0 else Vector3.ZERO
	var pole := elbow
	if not preserve_plane and not line.is_zero_approx():
		var tangent := (-fingers).slide(line)
		if tangent.length_squared() > 0.03:
			pole = elbow.lerp(tangent.normalized(), 0.50 if grip == "support" else 0.34)
	reach(rig, side, goal, weight, pole)
	align_palm(rig, side, fingers, palm, weight, surface_wrist, preserve_plane)
	var settle := smooth((weight - 0.45) / 0.55)
	if settle <= 0.0:
		return
	var error := target - contact_landmark(rig, side, grip)
	wrist = rig.get_bone_global_pose(hand).origin
	if error.length_squared() > 0.000004:
		reach(rig, side, wrist + error.limit_length(0.12), settle, pole)
		align_palm(rig, side, fingers, palm, settle, surface_wrist, preserve_plane)
