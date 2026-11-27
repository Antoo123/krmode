extends Node3D

const Card := preload("res://card_model.gd")
const Edit := preload("res://character_edit.gd")
const Library := preload("res://card_library.gd")
const Pose := preload("res://npc_pose.gd")
const GreenHands := preload("res://animation_lab_hands.gd")
const DEFAULT_CARDS := ["res://Content/Player.kcs", "res://Content/Npc.kcs", "res://Content/Npc.kcs"]

var actors: Array[Node3D] = []
var base_animations: Array[Animation] = []
var parameters: Array = []
var placement := Node3D.new()
var camera := Camera3D.new()
var tweaks: Array[Node3D] = []
var duration := 0.0
var overlay: Animation
var overlay_tracks: Array[int] = []
var overlay_bones: Array[int] = []
var overlay_weight := 1.0
var overlay_phase := -1.0
const GREEN_FADE_TIME := 0.3
var green_fade: Array[Transform3D] = []
var green_fade_left := 0.0
var green_reaction := preload("res://animation_lab_reaction.gd").new()
var green_hands := GreenHands.new()
var independent_hands: Control
var focus := Vector3(0.0, 0.9, 0.0)
var distance := 3.4
var yaw := 0.68
var pitch := 0.22
var pov := -1


func _ready() -> void:
	add_child(placement)
	for role in range(3):
		var root := Node3D.new()
		placement.add_child(root)
		tweaks.append(root)
		actors.append(null)
		base_animations.append(null)
		parameters.append([])
		camera.set_cull_mask_value(8 + role, true)
	add_child(camera)
	camera.near = 0.022
	camera.fov = 44.0
	camera.make_current()
	add_child(green_hands)
	var environment := WorldEnvironment.new()
	environment.environment = Environment.new()
	environment.environment.background_mode = Environment.BG_COLOR
	environment.environment.background_color = Color("#283241")
	environment.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.environment.ambient_light_color = Color("#e7ecf4")
	environment.environment.ambient_light_energy = 0.72
	add_child(environment)
	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-52.0, 24.0, 0.0)
	light.light_energy = 0.90
	add_child(light)
	var floor_mesh := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(20.0, 20.0)
	var material := StandardMaterial3D.new()
	material.albedo_color = Color("#364253")
	material.roughness = 0.9
	plane.material = material
	floor_mesh.mesh = plane
	floor_mesh.position.y = -0.015
	add_child(floor_mesh)
	_add_floor_grid()
	update_view()


func _add_floor_grid() -> void:
	var surface := ImmediateMesh.new()
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.vertex_color_use_as_albedo = true
	surface.surface_begin(Mesh.PRIMITIVE_LINES, material)
	for i in range(-14, 15):
		var coordinate := i * 0.5
		var color := Color("#58677b") if i % 2 == 0 else Color("#48576a")
		surface.surface_set_color(color)
		surface.surface_add_vertex(Vector3(coordinate, 0.0, -7.0))
		surface.surface_add_vertex(Vector3(coordinate, 0.0, 7.0))
		surface.surface_add_vertex(Vector3(-7.0, 0.0, coordinate))
		surface.surface_add_vertex(Vector3(7.0, 0.0, coordinate))
	surface.surface_end()
	var grid := MeshInstance3D.new()
	grid.mesh = surface
	add_child(grid)


func set_card(role: int, selection: String, track_path: String) -> String:
	var preset := Library.qa_preset(selection.trim_prefix("qa://")) if selection.begins_with("qa://") else {}
	var file := Library.qa_card(preset) if not preset.is_empty() else selection
	var actor := Card.load_actor(file)
	if not actor:
		return "Карточка или файл KCS недоступны."
	var rig := actor.get_node("Skeleton") as Skeleton3D
	for joint in ["cf_j_hips", "cf_j_head", "cf_j_hand_L", "cf_j_hand_R", "cf_j_foot_L", "cf_j_foot_R"]:
		if rig.find_bone(joint) < 0:
			actor.free()
			return "Скелет несовместим · отсутствует %s." % joint
	if not preset.is_empty():
		Edit.set_clothes(actor, false)
		for child in actor.get_children():
			if child is MeshInstance3D and String(child.name) in preset.get("hide", []):
				child.hide()
		var height := rig.find_bone("cf_n_height")
		if height >= 0:
			var rest := rig.get_bone_rest(height)
			rest.basis = rest.basis.scaled(Vector3.ONE * float(preset.get("scale", 1.0)))
			rig.set_bone_rest(height, rest)
			rig.set_bone_pose_scale(height, rest.basis.get_scale())
	var clip := Card.animation(track_path, rig) if not track_path.is_empty() else null
	if not track_path.is_empty() and not clip:
		actor.free()
		return "Для этой карточки нет совместимых дорожек выбранного клипа."
	if actors[role]:
		actor.position = actors[role].position
		actors[role].free()
	actors[role] = actor
	tweaks[role].add_child(actor)
	for child in actor.get_children():
		if child is MeshInstance3D:
			var name := String(child.name).to_lower()
			if "face" in name or "hitomi" in name or "eyeline" in name or "noseline" in name or "mayuge" in name or "hair" in name or child.get_meta("wardrobe_slot", "") == Edit.HAIR:
				child.layers = 1 << (7 + role)
	_set_track(role, clip)
	actor.visible = clip != null or role < 2
	return ""


func clear_cast() -> void:
	green_reaction.setup(null, -1, "")
	for index in range(actors.size()):
		if actors[index]:
			actors[index].free()
			actors[index] = null
		base_animations[index] = null
		parameters[index] = []
	duration = 0.0
	clear_overlay()


func setup_tracks(paths: Array[String], state: Array, required: Array[bool]) -> String:
	var staged: Array[Animation] = []
	for role in range(3):
		var clip := Card.animation(paths[role], actors[role].get_node("Skeleton")) if actors[role] and not paths[role].is_empty() else null
		staged.append(clip)
		if required[role] and not clip:
			return "Несовместимый KMA или скелет роли %d · %s" % [role + 1, paths[role]]
	duration = 0.0
	clear_overlay()
	for role in range(3):
		parameters[role] = state[role + 2]
		_set_track(role, staged[role])
		if actors[role]:
			actors[role].visible = required[role]
			actors[role].position = Vector3.ZERO
		if staged[role]:
			duration = maxf(duration, staged[role].length / maxf(absf(float(parameters[role][1])), 0.001))
	return ""


func _set_track(role: int, clip: Animation) -> void:
	base_animations[role] = clip
	if role == 1:
		green_fade.clear()
		green_fade_left = 0.0
	if not actors[role]:
		return
	var player := actors[role].get_node("AnimationPlayer") as AnimationPlayer
	player.stop(true)
	actors[role].get_node("Skeleton").reset_bone_poses()
	var library := player.get_animation_library("")
	if library.has_animation("Lab"):
		library.remove_animation("Lab")
	if clip:
		clip.loop_mode = Animation.LOOP_NONE
		library.add_animation("Lab", clip)
		player.play("Lab")
		player.pause()


func switch_green_track(path: String, slot: Array) -> bool:
	if not actors[1]:
		return false
	var rig := actors[1].get_node("Skeleton") as Skeleton3D
	var clip := Card.animation(path, rig)
	if not clip:
		return false
	green_reaction.restore_pose()
	var from := Pose.capture(rig)
	_set_track(1, clip)
	parameters[1] = slot
	duration = clip.length / maxf(absf(float(slot[1])), 0.001)
	green_fade = from
	green_fade_left = GREEN_FADE_TIME
	return true


func stop_pose(required: Array[bool], show_defaults := false) -> void:
	clear_overlay()
	duration = 0.0
	var visible_roles := [true, true, false] if show_defaults else required
	var count := visible_roles.count(true)
	var position_index := 0
	for role in range(3):
		_set_track(role, null)
		if actors[role]:
			actors[role].visible = visible_roles[role]
			if visible_roles[role]:
				actors[role].position = Vector3((position_index - 0.5 * (count - 1)) * 0.95, 0.0, 0.0)
				position_index += 1
	update_view()


func seek(phase: float) -> void:
	green_reaction.restore_pose()
	if not green_fade.is_empty():
		actors[1].get_node("Skeleton").reset_bone_poses()
		if green_fade_left <= 0.0:
			green_fade.clear()
	if overlay and actors[1] and overlay_phase >= 0.0:
		var body_rig := actors[1].get_node("Skeleton") as Skeleton3D
		for joint in overlay_bones:
			var rest := body_rig.get_bone_rest(joint)
			body_rig.set_bone_pose_position(joint, rest.origin)
			body_rig.set_bone_pose_rotation(joint, rest.basis.get_rotation_quaternion())
	for role in range(3):
		var clip := base_animations[role]
		if not clip:
			continue
		var normalized := 1.0 - phase if float(parameters[role][1]) < 0.0 else phase
		var offset := float(parameters[role][2])
		if not is_zero_approx(offset):
			normalized = fposmod(normalized + offset, 1.0) if bool(parameters[role][3]) else clampf(normalized + offset, 0.0, 1.0)
		actors[role].get_node("AnimationPlayer").seek(normalized * clip.length, true)
	if green_fade_left > 0.0:
		var rig := actors[1].get_node("Skeleton") as Skeleton3D
		var alpha := 1.0 - green_fade_left / GREEN_FADE_TIME
		Pose.blend(rig, green_fade, Pose.capture(rig), alpha)
	if overlay and actors[1]:
		var rig := actors[1].get_node("Skeleton") as Skeleton3D
		var time := (phase if overlay_phase < 0.0 else overlay_phase) * overlay.length
		for index in range(overlay_tracks.size()):
			var track := overlay_tracks[index]
			var joint := overlay_bones[index]
			match overlay.track_get_type(track):
				Animation.TYPE_POSITION_3D:
					rig.set_bone_pose_position(joint, rig.get_bone_pose_position(joint).lerp(
						overlay.position_track_interpolate(track, time), overlay_weight))
				Animation.TYPE_ROTATION_3D:
					rig.set_bone_pose_rotation(joint, rig.get_bone_pose_rotation(joint).slerp(
						overlay.rotation_track_interpolate(track, time), overlay_weight))
	green_reaction.apply()
	update_view()


func set_overlay(path: String, mask: Array) -> bool:
	clear_overlay()
	if not actors[1] or path.is_empty():
		return false
	var rig := actors[1].get_node("Skeleton") as Skeleton3D
	var clip := Card.animation(path, rig)
	if not clip:
		return false
	for track in range(clip.get_track_count()):
		var bone := String(clip.track_get_path(track).get_subname(0))
		if bone in mask:
			overlay_tracks.append(track)
			overlay_bones.append(rig.find_bone(bone))
	if overlay_tracks.is_empty():
		return false
	overlay = clip
	return true


func clear_overlay() -> void:
	green_reaction.restore_pose()
	if overlay and actors[1]:
		actors[1].get_node("Skeleton").reset_bone_poses()
	overlay = null
	overlay_weight = 1.0
	overlay_phase = -1.0
	overlay_tracks.clear()
	overlay_bones.clear()


func set_placement(offset: Array) -> void:
	var position_values: Array = offset[0]
	var rotation_values: Array = offset[1]
	placement.position = Vector3(position_values[0], position_values[1], -float(position_values[2]))
	placement.rotation_degrees = Vector3(-float(rotation_values[0]), -float(rotation_values[1]), rotation_values[2])


func reset_view() -> void:
	focus = placement.position + Vector3.UP * 0.9
	distance = 3.4
	yaw = 0.68
	pitch = 0.22
	update_view()


func update_view() -> void:
	var green_view := green_hands.enabled and is_instance_valid(actors[1]) and actors[1].visible
	if not green_view and green_hands.visible:
		green_hands.hide()
	elif green_view and not green_hands.visible:
		green_hands.show()
	for role in range(3):
		camera.set_cull_mask_value(role + 8, green_view or role != pov)
	if green_view:
		if independent_hands and independent_hands.visible:
			camera.global_transform = independent_hands.view_camera(actors[1], green_hands)
			independent_hands.draw_hands(actors[1], camera.global_transform)
		else:
			camera.global_transform = green_hands.view_camera(actors[1])
			green_hands.draw(actors[1], camera.global_transform)
		return
	if pov >= 0 and actors[pov] and actors[pov].visible:
		var rig := actors[pov].get_node("Skeleton") as Skeleton3D
		rig.force_update_all_bone_transforms()
		var head := rig.global_transform * rig.get_bone_global_pose(rig.find_bone("cf_j_head"))
		var forward := -head.basis.z.normalized()
		var up := head.basis.y.normalized()
		camera.global_position = head.origin + forward * 0.075 + up * 0.045
		camera.look_at(camera.global_position + forward, up)
		return
	camera.position = focus + orbit_offset()
	camera.look_at(focus)


func orbit_offset() -> Vector3:
	return distance * Vector3(sin(yaw) * cos(pitch), sin(pitch), cos(yaw) * cos(pitch))
