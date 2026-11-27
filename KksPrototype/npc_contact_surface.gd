extends RefCounted

const PATCH_RADIUS := 0.19
const SAMPLE_SIZE := 0.023
const RAY_START := 0.24
const RAY_END := RAY_START - 1.0


class SurfaceQuery:
	var frame: Basis
	var center: Vector3
	var space := PhysicsServer3D.space_create()
	var body := PhysicsServer3D.body_create()
	var shape := PhysicsServer3D.concave_polygon_shape_create()
	var ray := PhysicsRayQueryParameters3D.new()
	var query: PhysicsDirectSpaceState3D
	var rear := INF
	var foremost := -INF

	func _init() -> void:
		# This space contains only the deformed patch and never participates in simulation.
		PhysicsServer3D.body_set_mode(body, PhysicsServer3D.BODY_MODE_STATIC)
		PhysicsServer3D.body_add_shape(body, shape)
		PhysicsServer3D.body_set_space(body, space)
		query = PhysicsServer3D.space_get_direct_state(space)

	func _notification(what: int) -> void:
		if what == NOTIFICATION_PREDELETE:
			PhysicsServer3D.free_rid(body)
			PhysicsServer3D.free_rid(shape)
			PhysicsServer3D.free_rid(space)


class SkinPoints:
	var count := 0
	var rigid := {}
	var blended_ids := PackedInt32Array()
	var offsets := PackedInt32Array([0])
	var bones := PackedInt32Array()
	var points := PackedVector3Array()
	var weights := PackedFloat32Array()
	var bone_slots := {}
	var deepest := 0

	func append(bindings: Array) -> void:
		if bindings.size() == 1 and bindings[0][2] == 1.0:
			var bind: Array = bindings[0]
			var group: Array = rigid.get_or_add(bind[0], [[], []])
			group[0].append(count)
			group[1].append(bind[1])
		else:
			blended_ids.append(count)
			for bind: Array in bindings:
				bones.append(bone_slots.get_or_add(bind[0], bone_slots.size()))
				points.append(bind[1])
				weights.append(bind[2])
			offsets.append(bones.size())
		count += 1

	func prepare() -> void:
		for group: Array in rigid.values():
			group[0] = PackedInt32Array(group[0])
			group[1] = PackedVector3Array(group[1])

	func project(rig: Skeleton3D, to_world: Transform3D, surface: SurfaceQuery,
			poses: Dictionary) -> PackedVector3Array:
		var result := PackedVector3Array()
		result.resize(count)
		for bone: int in rigid:
			if not poses.has(bone):
				poses[bone] = rig.get_bone_global_pose(bone)
			var pose: Transform3D = poses[bone]
			var group: Array = rigid[bone]
			var ids: PackedInt32Array = group[0]
			var posed := pose * PackedVector3Array(group[1])
			for i in range(ids.size()):
				result[ids[i]] = posed[i]
		var transforms: Array[Transform3D] = []
		transforms.resize(bone_slots.size())
		for bone: int in bone_slots:
			if not poses.has(bone):
				poses[bone] = rig.get_bone_global_pose(bone)
			transforms[bone_slots[bone]] = poses[bone]
		var ids := blended_ids
		var starts := offsets
		var joints := bones
		var bind_points := points
		var bind_weights := weights
		for i in range(ids.size()):
			var point := Vector3.ZERO
			for j in range(starts[i], starts[i + 1]):
				point += (transforms[joints[j]] * bind_points[j]) * bind_weights[j]
			result[ids[i]] = point
		var world := to_world * result
		var frame := surface.frame
		var center := surface.center
		for i in range(count):
			result[i] = frame * (world[i] - center)
		return result


static func influences(part: MeshInstance3D, arrays: Array, vertex: int) -> Array:
	var point: Vector3 = arrays[Mesh.ARRAY_VERTEX][vertex]
	var result := []
	for j in range(4):
		var index := vertex * 4 + j
		var weight: float = arrays[Mesh.ARRAY_WEIGHTS][index]
		if weight > 0.0001:
			var bind: int = arrays[Mesh.ARRAY_BONES][index]
			result.append([part.skin.get_bind_bone(bind), part.skin.get_bind_pose(bind) * point, weight])
	return result


static func patch(actor: Node3D, point: Vector3, normal: Vector3, baked_meshes: Dictionary,
		garments: Array = ["Top", "Bra"], torso_only := false, radius := PATCH_RADIUS,
		excluded_roots: Array[String] = [], extra_mesh_prefixes: Array[String] = []) -> Array:
	var parts := []
	if DisplayServer.get_name() == "headless":
		return parts
	var arm_bones := PackedByteArray()
	var filter := torso_only or not excluded_roots.is_empty()
	if filter:
		var rig: Skeleton3D = actor.get_node("Skeleton")
		var excluded := {}
		if torso_only:
			excluded[rig.find_bone("cf_j_arm00_L")] = true
			excluded[rig.find_bone("cf_j_arm00_R")] = true
		for name in excluded_roots:
			excluded[rig.find_bone(name)] = true
		arm_bones.resize(rig.get_bone_count())
		for bone in range(rig.get_bone_count()):
			var parent := rig.get_bone_parent(bone)
			arm_bones[bone] = int(excluded.has(bone) or (parent >= 0 and arm_bones[parent] != 0))
	for node in actor.get_children():
		var part := node as MeshInstance3D
		if not part or not part.visible or not part.skin or not part.mesh:
			continue
		var slot: String = part.get_meta("wardrobe_slot", "")
		var mesh_name := String(part.name).to_lower()
		if not mesh_name.begins_with("o_body") and slot not in garments:
			if not extra_mesh_prefixes.any(func(prefix: String): return mesh_name.begins_with(prefix)):
				continue
		var baked: ArrayMesh = baked_meshes.get(part)
		if not baked_meshes.has(part):
			baked = part.bake_mesh_from_current_skeleton_pose()
		if not baked:
			continue
		var center := part.to_local(point)
		var front_axis := (part.global_basis.inverse() * normal).normalized()
		for surface in range(baked.get_surface_count()):
			var posed := baked.surface_get_arrays(surface)
			var vertices: PackedVector3Array = posed[Mesh.ARRAY_VERTEX]
			var indices: PackedInt32Array = posed[Mesh.ARRAY_INDEX]
			var arrays := part.mesh.surface_get_arrays(surface)
			if arrays[Mesh.ARRAY_BONES].size() != vertices.size() * 4:
				continue
			var joints: PackedInt32Array = arrays[Mesh.ARRAY_BONES]
			var weights: PackedFloat32Array = arrays[Mesh.ARRAY_WEIGHTS]
			var arm_vertices := {}
			var groups := {}
			var remap := {}
			var raw_triangles: Array[Vector3i] = []
			for i in range(0, indices.size(), 3):
				var ids := Vector3i(indices[i], indices[i + 1], indices[i + 2])
				var offset := (vertices[ids.x] + vertices[ids.y] + vertices[ids.z]) / 3.0 - center
				if offset.length_squared() > radius * radius or offset.dot(front_axis) < -0.044:
					continue
				if filter:
					for id in [ids.x, ids.y, ids.z]:
						if arm_vertices.has(id):
							continue
						var arm_weight := 0.0
						for component in range(id * 4, id * 4 + 4):
							var bone := part.skin.get_bind_bone(joints[component])
							if bone >= 0 and bone < arm_bones.size() and arm_bones[bone]:
								arm_weight += weights[component]
						arm_vertices[id] = arm_weight > 0.50
					if arm_vertices[ids.x] or arm_vertices[ids.y] or arm_vertices[ids.z]:
						continue
				for id in [ids.x, ids.y, ids.z]:
					if remap.has(id):
						continue
					var position := vertices[id]
					var key := Vector3i((position / SAMPLE_SIZE).floor())
					remap[id] = key
					if not groups.has(key) or position.dot(front_axis) > vertices[groups[key]].dot(front_axis):
						groups[key] = id
				raw_triangles.append(ids)
			var vertex_ids := {}
			var bindings := SkinPoints.new()
			var triangles: Array[Vector3i] = []
			var seen := {}
			for ids in raw_triangles:
				var a: int = groups[remap[ids.x]]
				var b: int = groups[remap[ids.y]]
				var c: int = groups[remap[ids.z]]
				if a == b or b == c or c == a:
					continue
				var sorted := Vector3i(mini(a, mini(b, c)), a + b + c - mini(a, mini(b, c)) - maxi(a, maxi(b, c)), maxi(a, maxi(b, c)))
				if seen.has(sorted):
					continue
				seen[sorted] = true
				for id in [a, b, c]:
					if not vertex_ids.has(id):
						vertex_ids[id] = bindings.count
						bindings.append(influences(part, arrays, id))
				triangles.append(Vector3i(vertex_ids[a], vertex_ids[b], vertex_ids[c]))
			if not triangles.is_empty():
				bindings.prepare()
				parts.append({"part": part, "vertices": bindings, "triangles": triangles})
	return parts


static func hand_samples(actor: Node3D, rig: Skeleton3D, side: String, spacing := 0.008) -> SkinPoints:
	var result := SkinPoints.new()
	var wrist := rig.find_bone("cf_j_hand_" + side)
	if wrist < 0:
		return result
	var arm := rig.find_bone("cf_j_forearm01_" + side)
	var hand_bones := PackedByteArray()
	hand_bones.resize(rig.get_bone_count())
	for bone in range(rig.get_bone_count()):
		var parent := rig.get_bone_parent(bone)
		hand_bones[bone] = int(bone == wrist or (parent >= 0 and hand_bones[parent] != 0))
	var wrist_rest := rig.get_bone_global_rest(wrist).origin
	for node in actor.get_children():
		var part := node as MeshInstance3D
		if not part or not part.skin or not part.mesh or not String(part.name).to_lower().begins_with("o_body"):
			continue
		for surface in range(part.mesh.get_surface_count()):
			var arrays := part.mesh.surface_get_arrays(surface)
			var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
			var joints: PackedInt32Array = arrays[Mesh.ARRAY_BONES]
			var weights: PackedFloat32Array = arrays[Mesh.ARRAY_WEIGHTS]
			if joints.size() != vertices.size() * 4:
				continue
			var cells := {}
			for id in range(vertices.size()):
				if vertices[id].distance_squared_to(wrist_rest) > 0.18 * 0.18:
					continue
				var total := 0.0
				for j in range(4):
					var index := id * 4 + j
					var bone := part.skin.get_bind_bone(joints[index])
					if bone >= 0 and (hand_bones[bone] or (bone == arm and vertices[id].distance_squared_to(wrist_rest) < 0.0025)):
						total += weights[index]
				if total < 0.50:
					continue
				var cell := Vector3i((vertices[id] / spacing).floor())
				if not cells.has(cell):
					cells[cell] = true
					result.append(influences(part, arrays, id))
	result.prepare()
	return result


static func profile(patch_parts: Array, npc: Skeleton3D, point: Vector3, normal: Vector3,
		result: SurfaceQuery) -> SurfaceQuery:
	var across := normal.cross(Vector3.UP).normalized()
	if across.is_zero_approx():
		across = normal.cross(Vector3.RIGHT).normalized()
	result.frame = Basis(across, normal.cross(across), normal).transposed()
	result.center = point
	result.rear = INF
	result.foremost = -INF
	var faces := PackedVector3Array()
	var poses := {}
	for mesh: Dictionary in patch_parts:
		var part: MeshInstance3D = mesh.part
		if not is_instance_valid(part) or not part.visible:
			continue
		var bindings: SkinPoints = mesh.vertices
		var vertices := bindings.project(npc, part.global_transform, result, poses)
		for ids: Vector3i in mesh.triangles:
			var a := vertices[ids.x]
			var b := vertices[ids.y]
			var c := vertices[ids.z]
			var foremost := maxf(a.z, maxf(b.z, c.z))
			if foremost < -0.095:
				continue
			if is_zero_approx((b - a).cross(c - a).z):
				continue
			faces.append(a)
			faces.append(b)
			faces.append(c)
			result.rear = minf(result.rear, minf(a.z, minf(b.z, c.z)))
			result.foremost = maxf(result.foremost, foremost)
	if not faces.is_empty():
		PhysicsServer3D.shape_set_data(result.shape, {"faces": faces, "backface_collision": true})
	return result


static func front(profile: SurfaceQuery, sample: Vector3, minimum := -INF) -> float:
	if minimum >= profile.foremost:
		return minimum
	var end := minf(RAY_END, profile.rear - 0.001)
	profile.ray.from = Vector3(sample.x, sample.y, RAY_START)
	profile.ray.to = Vector3(sample.x, sample.y, end)
	var hit := profile.query.intersect_ray(profile.ray)
	return maxf(minimum, hit.position.z) if not hit.is_empty() else minimum


static func touch_surface(profile: SurfaceQuery, point: Vector3, normal: Vector3,
		tolerance: float) -> Dictionary:
	if not is_finite(profile.foremost):
		return {}
	var sample := profile.frame * (point - profile.center)
	profile.ray.from = Vector3(sample.x, sample.y, RAY_START)
	profile.ray.to = Vector3(sample.x, sample.y, minf(RAY_END, profile.rear - 0.001))
	var hit := profile.query.intersect_ray(profile.ray)
	if hit.is_empty():
		return {}
	var offset: float = hit.position.z - sample.z
	if absf(offset) > tolerance:
		return {}
	var outward := (profile.frame.transposed() * Vector3(hit.normal)).normalized()
	return {"point": point + normal * offset, "normal": outward}


static func hand_depth(profile: SurfaceQuery, hand: SkinPoints, player: Skeleton3D) -> float:
	var samples := hand.project(player, player.global_transform, profile, {})
	if samples.is_empty():
		return -INF
	# Seed the bound with the last winning sample, evaluated against the current pose.
	var seed_index := hand.deepest
	var seed := samples[seed_index]
	var correction := front(profile, seed) - seed.z
	var maximum := profile.foremost
	var ray := profile.ray
	var query := profile.query
	# A unit segment preserves the parallel tolerance of the previous unit ray.
	var end := minf(RAY_END, profile.rear - 0.001)
	for i in range(samples.size()):
		if i == seed_index:
			continue
		var sample := samples[i]
		var limit := correction + sample.z
		if limit >= maximum:
			continue
		ray.from = Vector3(sample.x, sample.y, RAY_START)
		ray.to = Vector3(sample.x, sample.y, end)
		var hit := query.intersect_ray(ray)
		if not hit.is_empty() and hit.position.z > limit:
			correction = hit.position.z - sample.z
			hand.deepest = i
	return correction
