extends Node3D

const Card := preload("res://card_model.gd")
const Surface := preload("res://npc_contact_surface.gd")
const Preset := preload("res://hand_animation_preset.gd")
const Contact := preload("res://hand_contact_motion.gd")
const Folder := "res://Content/F7/Hands/"
const ASSETS := ["p_handL", "p_handR", "p_fingerL", "p_fingerR"]
const FALLBACK := ["cf_d_bust01_L", "cf_d_bust01_R", "cf_d_kokan", "cf_d_ana", "cf_d_siri01_L", "cf_d_siri01_R"]
# Eye offsets in the posed torso frame. Positive distance means its front.
const PRESETS := [
	Vector3(0.00, 0.27, 0.79), Vector3(0.10, 0.44, 0.36),
	Vector3(0.06, 0.31, -0.83), Vector3(0.07, 0.22, 0.77),
	Vector3(-0.09, 0.26, -0.79), Vector3(0.11, 0.32, -0.86),
	Vector3(0.06, 0.31, -0.81), Vector3(-0.08, 0.25, 0.73),
	Vector3(0.12, 0.34, -0.77), Vector3(-0.12, 0.26, -0.81),
	Vector3(0.18, 0.23, 0.79),
]
const PREFS := "user://animation_lab_pov.cfg"


class Tool:
	var node: Node3D
	var rig: Skeleton3D
	var player: AnimationPlayer
	var wrist: int
	var axis: Basis
	var clips: Dictionary = {}
	var layer := -1
	var skin_points: Surface.SkinPoints

	func sample(requested: int, phase: float) -> bool:
		var clip: Animation = clips.get(requested)
		if requested != layer:
			player.stop(true)
			rig.reset_bone_poses()
			var library := player.get_animation_library("")
			if library.has_animation("Hand"):
				library.remove_animation("Hand")
			if clip:
				clip.loop_mode = Animation.LOOP_NONE
				library.add_animation("Hand", clip)
				player.play("Hand")
				player.pause()
			layer = requested
		if clip:
			player.seek(clip.length * clampf(phase, 0.0, 0.999999), true)
		return clip != null


var items: Array[Tool] = []
var layer_names := {}
var enabled := false
var show_hands := true
var debug := false
var pose_id := 0
var offset := Vector3.ZERO
var angles := Vector3.ZERO
var motion_speed := 1.0
var tool_id := -1
var item_layer := 0
var anchor := ""
var fallback := ""
var running := false
var blend := 0.0
var action_phase := 0.0
var body_weight := 0.0
var duration := 1.0
var authored := false
var target := Transform3D.IDENTITY
var resolved_bone := ""
var area := 0
var patch_parts: Array = []
var surface_query: Surface.SurfaceQuery
var surface_clock := 0.0
var clearance := 0.0
var profile := ConfigFile.new()
var reference: Skeleton3D
var marker: MeshInstance3D
var lines := ImmediateMesh.new()
var editor_preview := {}
var custom_animation := {}
var custom_time := 0.0
var contact_elapsed := 0.0
var mouse_control := false
var drag_input := 0.0
var drag_speed := 0.0
var contact_motion := Contact.new()
var return_time := 0.0
var return_weight := 0.0
var contact_result := {}
var managed_side := -1
var contact_lane := 0.0
var second_editor_preview := {}


func _ready() -> void:
	profile.load(PREFS)
	marker = MeshInstance3D.new()
	marker.mesh = lines
	var ink := StandardMaterial3D.new()
	ink.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	ink.vertex_color_use_as_albedo = true
	ink.no_depth_test = true
	marker.material_override = ink
	add_child(marker)
	marker.hide()


func load_items() -> bool:
	if not items.is_empty():
		return items.size() == ASSETS.size()
	reference = Card.read_rig(FileAccess.open("res://Content/Npc.kcs", FileAccess.READ), "res://Content/Npc.kcs")
	if reference:
		add_child(reference)
	for line in FileAccess.get_file_as_string(Folder + "layers.tsv").split("\n", false):
		var columns := line.strip_edges().split("\t")
		if columns.size() == 4:
			layer_names[columns[0] + ":" + columns[2]] = columns[3]
	for asset: String in ASSETS:
		var model := Card.load_actor(Folder + asset + ".kcs", true)
		if not model:
			return false
		add_child(model)
		model.hide()
		var hand := Tool.new()
		hand.node = model
		hand.rig = model.get_node("Skeleton")
		hand.player = model.get_node("AnimationPlayer")
		var suffix := "_" + asset.right(1)
		hand.wrist = hand.rig.find_bone("cf_j_hand" + suffix)
		var finger := hand.rig.find_bone("cf_j_middle03" + suffix)
		var index := hand.rig.find_bone("cf_j_index01" + suffix)
		var little := hand.rig.find_bone("cf_j_little01" + suffix)
		if mini(mini(hand.wrist, finger), mini(index, little)) < 0:
			model.free()
			return false
		var forward := hand.rig.get_bone_global_rest(finger).origin - hand.rig.get_bone_global_rest(hand.wrist).origin
		var across := hand.rig.get_bone_global_rest(index).origin - hand.rig.get_bone_global_rest(little).origin
		var normal := across.cross(forward) * (-1.0 if suffix == "_L" else 1.0)
		hand.axis = Basis.looking_at(forward, normal)
		hand.skin_points = _skin_points(model)
		items.append(hand)
	return true


func choose_pose(id: int) -> void:
	cancel()
	contact_motion.cache_key = ""
	pose_id = clampi(id, 0, PRESETS.size() - 1)
	var key := "%02d" % pose_id
	var saved_offset: Variant = profile.get_value(key, "offset", Vector3.ZERO)
	var saved_angles: Variant = profile.get_value(key, "angles", Vector3.ZERO)
	offset = saved_offset if saved_offset is Vector3 else Vector3.ZERO
	angles = saved_angles if saved_angles is Vector3 else Vector3.ZERO


func save_camera() -> void:
	var key := "%02d" % pose_id
	profile.set_value(key, "offset", offset)
	profile.set_value(key, "angles", angles)
	profile.save(PREFS)


func reset_camera() -> void:
	offset = Vector3.ZERO
	angles = Vector3.ZERO
	save_camera()


func camera_pose(npc: Node3D) -> Transform3D:
	var rig := npc.get_node("Skeleton") as Skeleton3D
	rig.force_update_all_bone_transforms()
	var chest_id := rig.find_bone("cf_j_spine03")
	var hips_id := rig.find_bone("cf_j_hips")
	var head_id := rig.find_bone("cf_j_head")
	if chest_id < 0:
		chest_id = head_id
	var chest := _bone(rig, chest_id)
	var hips := _bone(rig, hips_id)
	var head := _bone(rig, head_id)
	var up := (head.origin - hips.origin).normalized()
	var chest_rest := rig.get_bone_global_rest(chest_id).basis.orthonormalized()
	var front := (chest.basis.orthonormalized() * chest_rest.inverse()) * Vector3.FORWARD
	var right := front.cross(up).normalized()
	if right.is_zero_approx():
		right = npc.global_basis.x.normalized()
	front = up.cross(right).normalized()
	var rear: bool = PRESETS[pose_id].z < 0.0
	var focus_point := hips.origin.lerp(chest.origin, 0.35 if rear else 0.82)
	var preset: Vector3 = PRESETS[pose_id] + offset
	var eye := focus_point + right * preset.x + Vector3.UP * preset.y + front * preset.z
	var direction := (focus_point - eye).normalized()
	if absf(direction.dot(Vector3.UP)) > 0.97:
		var screen_up := -front.cross(right) if up.dot(Vector3.UP) < 0.8 else right
		return Transform3D(Basis.looking_at(direction, screen_up) * Basis.from_euler(angles * PI / 180.0), eye)
	return Transform3D(Basis.looking_at(direction, Vector3.UP) * Basis.from_euler(angles * PI / 180.0), eye)


func start_action(npc: Node3D, id: int, layer: int, parent: String, zone: int, custom := {}) -> String:
	if id < 0 or id >= items.size():
		return "Для этого инструмента нет модели в стенде."
	var rig := npc.get_node("Skeleton") as Skeleton3D
	var backup: String = FALLBACK[clampi(zone, 0, FALLBACK.size() - 1)]
	if custom.has("contact"):
		parent = Contact.bone_name(custom.contact)
	elif not custom.is_empty():
		parent = custom.bone
	if rig.find_bone(parent) < 0 and not _can_rebase(rig, parent, backup):
		return "Точка HandCtrl недоступна · " + parent
	cancel()
	custom_animation = custom
	tool_id = id
	item_layer = layer
	anchor = parent
	fallback = backup
	area = zone
	running = true
	var clip := _clip(items[id], id, layer)
	authored = clip != null
	duration = maxf(0.1, clip.length) if clip else 1.0
	rig.force_update_all_bone_transforms()
	target = _target(rig)
	var slots: Array = ["Top", "Bra"] if area < 2 else ["Top", "Bottom", "Underwear", "Tights"]
	if custom.is_empty():
		patch_parts = Surface.patch(npc, target.origin, _outward(rig), {}, slots, area < 2, 0.24)
	if not patch_parts.is_empty() and not surface_query:
		surface_query = Surface.SurfaceQuery.new()
	surface_clock = 0.06
	return ""


func release() -> void:
	if custom_animation.has("contact") and running:
		return_weight = blend
	running = false


func cancel() -> void:
	running = false
	blend = 0.0
	body_weight = 0.0
	action_phase = 0.0
	tool_id = -1
	resolved_bone = ""
	patch_parts.clear()
	clearance = 0.0
	custom_animation = {}
	custom_time = 0.0
	contact_elapsed = 0.0
	drag_input = 0.0
	drag_speed = 0.0
	return_time = 0.0
	return_weight = 0.0
	contact_result = {}


func set_mouse_control(active: bool) -> void:
	if active == mouse_control:
		return
	mouse_control = active
	drag_input = 0.0
	drag_speed = 0.0
	if active and running and custom_animation.has("contact"):
		custom_time = Contact.held_time(custom_animation, custom_time)


func push_mouse_motion(motion: float) -> void:
	if mouse_control and blend >= 0.94:
		drag_input = clampf(drag_input + motion, -64.0, 64.0)


func tick(delta: float) -> void:
	if custom_animation.has("contact"):
		var data: Dictionary = custom_animation.contact
		var step := delta * motion_speed * float(data.speed)
		if running:
			contact_elapsed += delta
			var approach := float(data.approach)
			if mouse_control and blend >= 0.999:
				var limit := 2.2 * motion_speed
				var desired := clampf(drag_input * 0.006 * float(data.speed) / maxf(delta, 0.001), -limit, limit)
				drag_speed = lerpf(drag_speed, desired, 1.0 - exp(-18.0 * delta))
				var last := float(custom_animation.duration) - float(data.release)
				custom_time = clampf(custom_time + drag_speed * delta, approach, last)
			else:
				custom_time += step
				if mouse_control:
					custom_time = minf(custom_time, approach)
			drag_input = 0.0
			action_phase = Contact.held_time(custom_animation, custom_time) / float(custom_animation.duration)
			blend = smoothstep(0.0, approach, custom_time)
		else:
			return_time += step
			blend = return_weight * (1.0 - smoothstep(0.0, data.release, return_time))
			if return_time >= float(data.release):
				cancel()
		return
	blend = move_toward(blend, 1.0 if running else 0.0, delta * motion_speed * 2.5)
	body_weight = smoothstep(0.78, 1.0, blend)
	if running and blend >= 0.999:
		action_phase = fposmod(action_phase + delta * motion_speed / duration, 1.0)
		if not custom_animation.is_empty():
			custom_time += delta * motion_speed
	surface_clock += delta
	if not running and is_zero_approx(blend):
		cancel()


func draw(npc: Node3D, eye: Transform3D) -> void:
	marker.visible = enabled and debug and tool_id >= 0
	if not enabled or not npc or items.size() != ASSETS.size():
		for item in items:
			item.node.hide()
		return
	var rig := npc.get_node("Skeleton") as Skeleton3D
	rig.force_update_all_bone_transforms()
	if tool_id >= 0:
		target = _target(rig)
		if resolved_bone.is_empty():
			cancel()
	var edited := int(editor_preview.get("id", -1))
	var active_side := (edited if edited >= 0 else tool_id) % 2 if edited >= 0 or tool_id >= 0 else -1
	for id in range(items.size()):
		if managed_side >= 0 and id % 2 != managed_side:
			continue
		var hand := items[id]
		if id == int(second_editor_preview.get("id", -1)):
			hand.node.visible = true
			hand.node.global_transform = second_editor_preview.world
			continue
		var active := tool_id == id
		var idle := id <= 1 and id != active_side
		if id == edited:
			hand.node.visible = true
			if not editor_preview.get("sampled", false):
				_sample_fingers(hand, id, editor_preview.layer, editor_preview.time, editor_preview.rate)
			hand.node.global_transform = editor_preview.world
			continue
		hand.node.visible = show_hands and (idle or active)
		if not idle and not active:
			continue
		if active and custom_animation.has("contact"):
			var time := Contact.held_time(custom_animation, custom_time)
			var local := Preset.adjustment(custom_animation, pose_id) * Preset.contact_key(
				custom_animation, Preset.sample(custom_animation, time))
			var lane := contact_lane * smoothstep(0.25, 0.8, blend)
			if custom_animation.contact.kind in ["foot", "ankle"]:
				local.origin.y += lane
			else:
				local.origin.x += lane
				local.basis = Basis(Vector3.FORWARD, lane * 4.8) * local.basis
			contact_result = evaluate_contact(npc, id, custom_animation, local, time, blend)
			if not contact_result.is_empty():
				hand.node.global_transform = contact_result.world
				target = contact_result.anchor
			continue
		var layer := item_layer if active and authored else 0
		var phase := action_phase if active else 0.0
		if active and not custom_animation.is_empty():
			_sample_fingers(hand, id, custom_animation.finger_layer, custom_time, custom_animation.finger_speed)
		else:
			_clip(hand, id, layer)
			hand.sample(layer, phase)
		hand.rig.force_update_all_bone_transforms()
		var origin := _home(hand, id, eye)
		if active:
			var goal := target
			if not custom_animation.is_empty():
				var length := float(custom_animation.duration)
				var time := fposmod(custom_time, length) if custom_animation.loop else minf(custom_time, length)
				goal.basis = goal.basis.orthonormalized()
				goal *= Preset.adjustment(custom_animation, pose_id) * Preset.sample(custom_animation, time)
			elif not authored:
				# An explicit fallback for missing item tracks. The socket stays fixed.
				goal.basis *= Basis(Vector3.FORWARD, sin(phase * TAU) * 0.085)
			if not patch_parts.is_empty():
				var outward := _outward(rig)
				if surface_clock >= 0.05:
					surface_clock = 0.0
					hand.node.global_transform = goal
					var profile := Surface.profile(patch_parts, rig, goal.origin, outward, surface_query)
					clearance = clampf(Surface.hand_depth(profile, hand.skin_points, hand.rig) + 0.002, 0.0, 0.055)
				goal.origin += outward * clearance
			origin = origin.interpolate_with(goal, smoothstep(0.0, 1.0, blend))
		hand.node.global_transform = origin
	if marker.visible and tool_id >= 0:
		_draw_target(items[tool_id])


func _home(hand: Tool, id: int, eye: Transform3D) -> Transform3D:
	var sign_x := -1.0 if id % 2 == 0 else 1.0
	var basis := eye.basis * Basis.looking_at(Vector3(-0.18 * sign_x, 0.62, -0.75), Vector3.UP) * hand.axis.inverse()
	var origin := eye * Vector3(0.17 * sign_x, -0.158, -0.405) - basis * hand.rig.get_bone_global_pose(hand.wrist).origin
	return Transform3D(basis, origin)


func evaluate_contact(npc: Node3D, id: int, preset: Dictionary, local: Transform3D, time: float, amount: float, solver: RefCounted = null) -> Dictionary:
	var hand := items[id]
	_sample_fingers(hand, id, preset.finger_layer, time, preset.finger_speed)
	if preset.contact.kind in ["chin", "cheek"] and int(preset.finger_layer) < 0:
		hand.rig.reset_bone_poses()
		var late := float(preset.duration) - float(preset.contact.release)
		var strength := clampf(inverse_lerp(float(preset.contact.approach), late, time), 0.0, 1.0)
		Contact.shape_fingers(hand.rig, ASSETS[id].right(1), preset.contact.kind, strength)
	hand.rig.force_update_all_bone_transforms()
	var eye: Camera3D = get_parent().camera
	var active_solver := solver if solver else contact_motion
	return active_solver.solve(npc, hand.rig, ASSETS[id].right(1), preset, local,
		_home(hand, id, eye.global_transform), amount, hand.skin_points, hand.node)


func frame_contact_camera(npc: Node3D, original: Transform3D, data: Dictionary) -> Transform3D:
	var rig := npc.get_node("Skeleton") as Skeleton3D
	var anchored := Contact.anchor(rig, data)
	if anchored.is_empty():
		return original
	var frame: Transform3D = anchored.frame
	var focus := frame.origin + Vector3.UP * 0.04
	var eye := original.origin
	if data.kind != "hand":
		var side := frame.basis.x
		var outward := frame.basis.z
		if outward.y < -0.5:
			side = side.slide(Vector3.UP).normalized()
			outward = (side + outward * 0.30).normalized()
		if data.kind in ["foot", "ankle"]:
			var horizontal := (original.origin - focus).slide(Vector3.UP).normalized()
			if horizontal.is_zero_approx():
				horizontal = original.basis.z.slide(Vector3.UP).normalized()
			eye = focus + horizontal * clampf(0.83 + offset.z, 0.62, 1.65)
			eye += Vector3.UP * clampf(0.32 + offset.y, 0.18, 0.85)
			eye += Vector3.UP.cross(horizontal) * clampf(offset.x, -0.32, 0.32)
		else:
			eye = focus + outward * clampf(0.77 + offset.z, 0.28, 2.0)
			eye += Vector3.UP * (0.24 + offset.y) + side * (0.06 + offset.x)
			if data.kind == "crown":
				eye += (original.origin - focus).slide(outward).normalized() * 0.34
		eye.y = maxf(eye.y, 0.16)
	var direction := (focus - eye).normalized()
	var up := Vector3.UP if absf(direction.dot(Vector3.UP)) < 0.96 else frame.basis.x
	if absf(up.dot(direction)) > 0.98:
		up = Vector3.FORWARD
	return Transform3D(Basis.looking_at(direction, up) * Basis.from_euler(angles * (PI / 180.0)), eye)


func editor_contact_camera(npc: Node3D, contact: Dictionary) -> Transform3D:
	var original := camera_pose(npc)
	if not second_editor_preview.has("contact"):
		return frame_contact_camera(npc, original, contact)
	var rig: Skeleton3D = npc.get_node("Skeleton")
	var first := Contact.anchor(rig, contact)
	var second := Contact.anchor(rig, second_editor_preview.contact)
	if first.is_empty() or second.is_empty():
		return frame_contact_camera(npc, original, contact)
	var point: Vector3 = first.frame.origin
	var other: Vector3 = second.frame.origin
	var focus := point.lerp(other, 0.5)
	var eye := focus + focus.direction_to(original.origin) * maxf(1.12, point.distance_to(other) * 1.8)
	if eye.distance_squared_to(focus) < 0.001:
		return original
	var direction := eye.direction_to(focus)
	var up := Vector3.UP if absf(direction.dot(Vector3.UP)) < 0.96 else Vector3.FORWARD
	return Transform3D(Basis.looking_at(direction, up), eye)


func view_camera(npc: Node3D) -> Transform3D:
	var original := camera_pose(npc)
	if editor_preview.has("contact"):
		return editor_contact_camera(npc, editor_preview.contact)
	if custom_animation.has("contact"):
		return original.interpolate_with(frame_contact_camera(npc, original, custom_animation.contact), blend)
	return original


func start_contact_preset(npc: Node3D, preset: Dictionary) -> String:
	var id := ASSETS.find(preset.asset)
	var rig := npc.get_node("Skeleton") as Skeleton3D
	if id < 0 or Contact.anchor(rig, preset.contact).is_empty():
		return "Для пресета недоступна модель кисти или точка контакта."
	var bone := Contact.bone_name(preset.contact)
	return start_action(npc, id, preset.finger_layer, bone, preset.zone, preset)


func _target(rig: Skeleton3D) -> Transform3D:
	var result := contact_frame(rig, anchor, area)
	resolved_bone = result[1] if not result.is_empty() else ""
	return result[0] if not result.is_empty() else Transform3D.IDENTITY


func contact_frame(rig: Skeleton3D, bone: String, zone: int) -> Array:
	var joint := rig.find_bone(bone)
	if joint >= 0:
		return [_bone(rig, joint), bone]
	var backup: String = FALLBACK[clampi(zone, 0, FALLBACK.size() - 1)]
	if _can_rebase(rig, bone, backup):
		var native_rest := reference.get_bone_global_rest(reference.find_bone(bone))
		var backup_rest := reference.get_bone_global_rest(reference.find_bone(backup))
		return [_bone(rig, rig.find_bone(backup)) * backup_rest.affine_inverse() * native_rest, backup]
	return []


func _can_rebase(rig: Skeleton3D, native: String, backup: String) -> bool:
	return reference and rig.find_bone(backup) >= 0 and reference.find_bone(backup) >= 0 and reference.find_bone(native) >= 0


func _outward(rig: Skeleton3D) -> Vector3:
	var pivot := rig.find_bone("cf_j_spine03") if area < 2 else rig.find_bone("cf_j_hips")
	if pivot < 0:
		pivot = rig.find_bone("cf_j_hips")
	var front := (_bone(rig, pivot).basis.orthonormalized() *
		rig.get_bone_global_rest(pivot).basis.orthonormalized().inverse()) * Vector3.FORWARD
	return front if area < 3 else -front


func _skin_points(model: Node3D) -> Surface.SkinPoints:
	var samples := Surface.SkinPoints.new()
	var cells := {}
	for child in model.get_children():
		if child is not MeshInstance3D or not child.skin:
			continue
		for surface in range(child.mesh.get_surface_count()):
			var arrays: Array = child.mesh.surface_get_arrays(surface)
			var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
			for index in range(vertices.size()):
				var cell := Vector3i((vertices[index] / 0.011).floor())
				if cells.has(cell):
					continue
				cells[cell] = true
				samples.append(Surface.influences(child, arrays, index))
	samples.prepare()
	return samples


func _draw_target(hand: Tool) -> void:
	lines.clear_surfaces()
	lines.surface_begin(Mesh.PRIMITIVE_LINES)
	for axis in range(3):
		lines.surface_set_color([Color.SALMON, Color.SPRING_GREEN, Color.SKY_BLUE][axis])
		lines.surface_add_vertex(target.origin)
		lines.surface_add_vertex(target.origin + target.basis[axis].normalized() * 0.095)
	lines.surface_set_color(Color.GOLD)
	lines.surface_add_vertex(target.origin)
	lines.surface_add_vertex(hand.node.global_transform * hand.rig.get_bone_global_pose(hand.wrist).origin)
	lines.surface_end()


func _clip(hand: Tool, id: int, layer: int) -> Animation:
	if not hand.clips.has(layer):
		var path: String = Folder + ASSETS[id] + "-%02d.kma" % layer
		hand.clips[layer] = Card.animation(path, hand.rig) if FileAccess.file_exists(path) else null
	return hand.clips[layer]


func item_label(id: int, layer: int) -> String:
	return layer_names.get(ASSETS[id] + ":" + str(layer), str(layer))


func finger_layers(id: int) -> Array[int]:
	var result: Array[int] = []
	for key: String in layer_names:
		if key.begins_with(ASSETS[id] + ":"):
			result.append(int(key.get_slice(":", 1)))
	result.sort()
	return result


func finger_length(id: int, layer: int) -> float:
	var clip := _clip(items[id], id, layer)
	return clip.length if clip else 1.0


func _sample_fingers(hand: Tool, id: int, layer: int, time: float, rate: float) -> void:
	var clip := _clip(hand, id, layer)
	hand.sample(layer, fposmod(time * rate, clip.length) / clip.length if clip else 0.0)


static func _bone(rig: Skeleton3D, id: int) -> Transform3D:
	return rig.global_transform * rig.get_bone_global_pose(id)
