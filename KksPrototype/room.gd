extends Node3D

const WALK_SPEED := 2.15
const MOUSE_SPEED := 0.003
const ROOM_BAKED := preload("res://room_baked.gdshader")
const ROOM_LIGHTMAP := preload("res://Content/JapaneseStyleRoom_baked.png")
const ROOM_DIRECTION := preload("res://Content/JapaneseStyleRoom_direction.png")
const CardModel := preload("res://card_model.gd")
const LibraryMenu := preload("res://library_menu.gd")
const CharacterEditor := preload("res://character_editor.gd")
const Edit := preload("res://character_edit.gd")
const NpcGameplay := preload("res://npc_gameplay.gd")
const PairPreview := preload("res://pair_preview.gd")
const StudioScenePreview := preload("res://studio_scene_preview.gd")
const AnimationLab := preload("res://animation_lab.gd")
const IDLE_ID := "8f3364877591ae77d0df5a7e"
const WALK_ID := "e717c63c91fc4031f3ce5866"
const DANCE_ID := "c2504dfb989fb63949dc4223"
const DEFAULT_ROOM := "Japanese Style Room (bundled)"

var player := CharacterBody3D.new()
var dancer_body: CharacterBody3D
var player_model: Node3D
var dancer_model: Node3D
var player_anim: AnimationPlayer
var dancer_anim: AnimationPlayer
var inspection_animations: Dictionary = {}
var active_npc_motion := DANCE_ID
var menu: CanvasLayer
var editor: CanvasLayer
var camera := Camera3D.new()
var sky_yaw := 0.0
var pitch := 0.28
var smoke_tick := -1
var smoke_start: Vector3
var smoke_dance: Quaternion
var room_mesh_count := 0
var smoke_walked := false
var smoke_walk_clip := false
var current_room: Node3D
var room_label := DEFAULT_ROOM
var rooms: Array[Dictionary] = []
var room_index := 0
var room_hint: Label
var hud: CanvasLayer
var room_lit := false
var npc_gameplay: Node3D
var pair_preview: CanvasLayer
var studio_preview: CanvasLayer
var animation_lab: CanvasLayer
var character_key: DirectionalLight3D
var room_environment: Environment


func _ready() -> void:
	_init_rooms()
	load_room(0)
	light_room(current_room)
	add_child(player)
	player.collision_layer = 2
	player.collision_mask = 1
	player.position = Vector3(0, 0.19, 1.9)
	player.floor_snap_length = 0.25
	var capsule := CapsuleShape3D.new()
	capsule.radius = 0.30
	capsule.height = 1.72
	add_collision(player, capsule, Vector3.UP * 0.86)

	dancer_body = CharacterBody3D.new()
	dancer_body.floor_snap_length = 0.25
	add_child(dancer_body)
	dancer_body.position = Vector3(0, 0.05, -1.0)
	add_collision(dancer_body, capsule, Vector3.UP * 0.86)
	if not load_card("res://Content/Player.kcs", false) or not load_card("res://Content/Npc.kcs", true):
		push_error("The bundled KKS character files could not be loaded.")
		set_physics_process(false)
		return

	add_child(camera)
	camera.current = true
	camera.fov = 61.0
	camera.near = 0.06
	update_camera(1.0)
	build_hud()
	menu = LibraryMenu.new()
	add_child(menu)
	editor = CharacterEditor.new()
	add_child(editor)
	npc_gameplay = NpcGameplay.new()
	add_child(npc_gameplay)
	pair_preview = PairPreview.new()
	add_child(pair_preview)
	studio_preview = StudioScenePreview.new()
	add_child(studio_preview)
	if "--smoke-f7" in OS.get_cmdline_user_args():
		_check_animation_lab.call_deferred()
	if "--smoke-test" in OS.get_cmdline_user_args():
		smoke_tick = 0
		smoke_start = player.position
		var skeleton: Skeleton3D = dancer_model.get_node("Skeleton")
		smoke_dance = skeleton.get_bone_pose_rotation(skeleton.find_bone("cf_j_arm00_L"))
		for arg in OS.get_cmdline_user_args():
			if arg.begins_with("--smoke-preview=") and DisplayServer.get_name() != "headless":
				save_preview.call_deferred(arg.trim_prefix("--smoke-preview="))
			if arg.begins_with("--smoke-closeup=") and DisplayServer.get_name() != "headless":
				save_closeup.call_deferred(arg.trim_prefix("--smoke-closeup="))
	else:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func _check_animation_lab() -> void:
	var key := InputEventKey.new()
	key.keycode = KEY_F7
	key.pressed = true
	get_viewport().push_input(key)
	if not animation_lab or not animation_lab.is_open() or animation_lab.results.item_count != 150:
		push_error("F7 did not open the packaged catalogue.")
		get_tree().quit(1)
		return
	for index in range(animation_lab.results.item_count):
		var row: Dictionary = animation_lab.results.get_item_metadata(index)
		if int(row.group) != 1 or int(row.id) != 33:
			continue
		animation_lab.results.select(index)
		animation_lab.results.item_selected.emit(index)
		animation_lab.scrub.value = 0.37
		if animation_lab.stage.duration <= 0.0 or not animation_lab.stage.base_animations[0] or not animation_lab.stage.base_animations[1]:
			break
		if DisplayServer.get_name() != "headless":
			await RenderingServer.frame_post_draw
		print("F7 Windows smoke: 150 entries, AnimationInfo_01/33 loaded two tracks at phase ", animation_lab.phase)
		get_tree().quit(0 if _check_packaged_green_hands() else 1)
		return
	push_error("F7 could not play the packaged AnimationInfo_01/33 pair.")
	get_tree().quit(1)


func _check_packaged_green_hands() -> bool:
	for index in range(animation_lab.results.item_count):
		var row: Dictionary = animation_lab.results.get_item_metadata(index)
		if int(row.group) != 0 or int(row.id) != 0:
			continue
		animation_lab.results.select(index)
		animation_lab.results.item_selected.emit(index)
		animation_lab.pov_hands.set_pressed_no_signal(true)
		animation_lab._toggle_hands(true)
		animation_lab.zone.select(0)
		animation_lab._fill_actions()
		animation_lab._start_hand()
		var hands: Node3D = animation_lab.stage.green_hands
		var reaction: RefCounted = animation_lab.stage.green_reaction
		var peak := 0.0
		var played_touch := false
		for tick in range(480):
			animation_lab._process(1.0 / 60.0)
			peak = maxf(peak, reaction.hit_offset)
			played_touch = played_touch or animation_lab.contact_state == "M_Touch"
			if animation_lab.contact_state == "M_Idle":
				break
		if hands.running and hands.authored and not hands.resolved_bone.is_empty() and animation_lab.hand_overlay and peak > 0.001 and reaction.face.applied.get("surfaces", 0) >= 3 and played_touch and animation_lab.contact_state == "M_Idle":
			print("F7 Windows smoke: original POV hand reached ", hands.resolved_bone,
				", M_Touch -> M_Idle, HitReaction offset ", peak, " m, facial preset ", reaction.face_id,
				" on ", reaction.face.applied.surfaces, " meshes")
			for position in animation_lab.caress_positions.item_count:
				if animation_lab.caress_positions.get_item_id(position) == 7:
					animation_lab._choose_caress_position(position)
					break
			if int(animation_lab.row.id) == 7 and animation_lab.states.item_count == 14 and animation_lab.tracks[1].begins_with("res://Content/F7/States/"):
				print("F7 Windows smoke: Sitting loaded the packaged Studio KMA and all 14 state entries")
				return true
		break
	push_error("F7 could not play the packaged AnimationInfo_00/00 POV hand contact.")
	return false


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_F7:
		if animation_lab and animation_lab.is_open():
			animation_lab.close()
		elif npc_gameplay and not npc_gameplay.staging.smooth_approach():
			if pair_preview.is_open():
				pair_preview.toggle()
			if studio_preview.is_open():
				studio_preview.toggle()
			if editor.is_open():
				editor.toggle()
			if menu.is_open():
				menu.toggle()
			npc_gameplay.close_dialogue()
			npc_gameplay.contact.end()
			if not animation_lab:
				animation_lab = AnimationLab.new()
				add_child(animation_lab)
			animation_lab.open()
		get_viewport().set_input_as_handled()
		return
	if animation_lab and animation_lab.is_open():
		if event is InputEventKey and event.pressed and not event.echo and event.keycode in [KEY_F5, KEY_F6]:
			animation_lab.close()
		else:
			animation_lab.handle_input(event)
			get_viewport().set_input_as_handled()
			return
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_F6:
		if studio_preview and not npc_gameplay.staging.smooth_approach():
			if pair_preview.is_open():
				pair_preview.toggle()
			if editor.is_open():
				editor.toggle()
			if menu.is_open():
				menu.toggle()
			studio_preview.toggle()
		get_viewport().set_input_as_handled()
		return
	if studio_preview and studio_preview.is_open():
		if event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
			studio_preview.toggle()
		get_viewport().set_input_as_handled()
		return
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_F5:
		if npc_gameplay and npc_gameplay.staging.smooth_approach():
			get_viewport().set_input_as_handled()
			return
		pair_preview.toggle()
		get_viewport().set_input_as_handled()
		return
	if pair_preview.is_open():
		if event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
			pair_preview.toggle()
		return
	if npc_gameplay and npc_gameplay.handle_input(event):
		get_viewport().set_input_as_handled()
		return
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_F2:
		if menu.is_open():
			menu.toggle()
		editor.toggle()
		get_viewport().set_input_as_handled()
		return
	if editor.is_open():
		if editor.camera_input(event):
			get_viewport().set_input_as_handled()
			return
		if event is InputEventMouseButton and event.pressed:
			if event.button_index == MOUSE_BUTTON_WHEEL_UP:
				editor.zoom(-0.18)
			elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
				editor.zoom(0.18)
		if event is InputEventKey and event.pressed and event.keycode in [KEY_ESCAPE, KEY_F1]:
			editor.toggle()
			if event.keycode == KEY_F1:
				menu.toggle()
		return
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_F1:
		menu.toggle()
		get_viewport().set_input_as_handled()
		return
	if menu.is_open():
		if event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
			menu.toggle()
		return
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_F3:
		load_room(room_index + 1)
		get_viewport().set_input_as_handled()
		return
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_F4:
		load_room(room_index - 1)
		get_viewport().set_input_as_handled()
		return
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		sky_yaw -= event.relative.x * MOUSE_SPEED
		pitch = clampf(pitch - event.relative.y * MOUSE_SPEED, -0.12, 1.03)
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_ESCAPE:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func _physics_process(delta: float) -> void:
	if animation_lab and animation_lab.is_open():
		return
	if studio_preview and studio_preview.is_open():
		return
	if pair_preview and pair_preview.is_open():
		update_camera(1.0 - exp(-16.0 * delta))
		return
	var direction := Vector2.ZERO
	if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED and (not editor or not editor.is_open()):
		direction.x = float(Input.is_physical_key_pressed(KEY_D)) - float(Input.is_physical_key_pressed(KEY_A))
		direction.y = float(Input.is_physical_key_pressed(KEY_S)) - float(Input.is_physical_key_pressed(KEY_W))
	if smoke_tick >= 0:
		direction = Vector2.UP if smoke_tick < 150 else Vector2.ZERO
	step_player(direction, delta)
	if npc_gameplay:
		npc_gameplay.tick(delta)
	update_camera(1.0 - exp(-16.0 * delta))
	if smoke_tick >= 0:
		check_smoke()


func step_player(direction: Vector2, delta: float) -> void:
	if npc_gameplay and npc_gameplay.staging.smooth_approach():
		return
	if npc_gameplay and npc_gameplay.holds_player_pose():
		direction = Vector2.ZERO
	var motion := Vector3(direction.x, 0, direction.y).limit_length().rotated(Vector3.UP, sky_yaw)
	player.velocity.x = motion.x * WALK_SPEED
	player.velocity.z = motion.z * WALK_SPEED
	if player.is_on_floor():
		player.velocity.y = -0.2
	else:
		player.velocity.y -= 16.0 * delta
	player.move_and_slide()
	if inspection_animations.has(player_anim):
		return
	if npc_gameplay and npc_gameplay.holds_player_pose():
		return
	var clip := "Idle"
	if motion.length_squared() > 0.001:
		player_model.rotation.y = lerp_angle(player_model.rotation.y, atan2(-motion.x, -motion.z), minf(1, delta * 15))
		var velocity := player.get_real_velocity()
		if Vector2(velocity.x, velocity.z).length() > 0.1:
			clip = "Walk"
	if clip == "Idle" and player_anim.assigned_animation == &"ConversationIdle":
		return
	if player_anim.current_animation != clip:
		player_anim.play(clip, 0.16)


func update_camera(weight: float) -> void:
	if pair_preview and pair_preview.is_open():
		var preview_view: Dictionary = pair_preview.camera_view()
		camera.fov = lerpf(camera.fov, 64.0, weight)
		camera.position = camera.position.lerp(preview_view.eye, weight)
		camera.look_at(preview_view.focus)
		return
	var focus := player.position + Vector3.UP * 1.36
	var offset := Vector3(0.57, sin(pitch) * 2.65, cos(pitch) * 2.65).rotated(Vector3.UP, sky_yaw)
	var exclude: Array[RID] = []
	if npc_gameplay:
		var view: Dictionary = npc_gameplay.interaction_view()
		if not view.is_empty():
			character_key.light_energy = 0.80
			var entering := camera.near > 0.04
			camera.near = 0.024
			camera.fov = lerpf(camera.fov, 76.0, weight)
			camera.position = camera.position.lerp(view.eye, 1.0 if entering else weight)
			var heading: Vector3 = view.focus - camera.position
			if heading.length_squared() > 0.002:
				var goal_rotation := Basis.looking_at(heading)
				camera.basis = goal_rotation if entering else camera.basis.slerp(goal_rotation, weight * 0.68).orthonormalized()
			return
	camera.near = 0.06
	if character_key:
		character_key.light_energy = 0.93
	camera.fov = lerpf(camera.fov, 61.0, weight)
	var goal := focus + offset
	var ray := PhysicsRayQueryParameters3D.create(focus, goal, 1, exclude)
	var hit := get_world_3d().direct_space_state.intersect_ray(ray)
	if not hit.is_empty():
		goal = hit.position - offset.normalized() * 0.18
	if npc_gameplay and npc_gameplay.staging.smooth_approach() and not npc_gameplay.dialogue.visible:
		var stage: Dictionary = npc_gameplay.staging.camera_view()
		var retreat: float = npc_gameplay.staging.approach_exit_weight()
		goal = Vector3(stage.eye).lerp(goal, retreat)
		focus = Vector3(stage.focus).lerp(focus, retreat)
		ray.from = focus
	camera.position = camera.position.lerp(goal, weight)
	# Clamp the interpolated position too when turning near a wall.
	ray.to = camera.position
	var swept := get_world_3d().direct_space_state.intersect_ray(ray)
	if not swept.is_empty():
		camera.position = swept.position.move_toward(focus, 0.18)
	var aim := focus + Vector3.UP * 0.08 - camera.position
	if Vector2(aim.x, aim.z).length_squared() > 0.00001:
		camera.look_at(camera.position + aim)


func check_smoke() -> void:
	smoke_tick += 1
	smoke_walked = smoke_walked or (smoke_start.z - player.position.z > 2.0)
	smoke_walk_clip = smoke_walk_clip or player_anim.current_animation == "Walk"
	if smoke_tick != 180:
		return
	var skeleton: Skeleton3D = dancer_model.get_node("Skeleton")
	var arm := skeleton.get_bone_pose_rotation(skeleton.find_bone("cf_j_arm00_L"))
	var dancing := dancer_anim.current_animation == "NPC" and arm.angle_to(smoke_dance) > 0.05
	var cards := player_model.get_child_count() > 12 and dancer_model.get_child_count() > 12
	var clipped := player.position.z > dancer_body.position.z + 0.45 and player.position.z < dancer_body.position.z + 0.85
	menu.toggle()
	menu.search.text = "Arms Hip Hop"
	menu.filter()
	var selected: bool = menu.matches.any(func(row: Dictionary): return row.id == DANCE_ID)
	var browser: bool = menu.is_open() and selected and menu.catalog.size() > 30000
	menu.toggle()
	var test_card := "res://Content/Npc.kcs"
	var test_motion := IDLE_ID
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--smoke-card="):
			test_card = argument.trim_prefix("--smoke-card=")
		if argument.begins_with("--smoke-motion="):
			test_motion = argument.trim_prefix("--smoke-motion=")
	var swapped := load_card(test_card, true) and play_npc_motion(test_motion)
	var skin := Edit.skin_material(dancer_model)
	var body: bool = skin != null and skin.get_shader_parameter("body_surface") == true and skin.get_shader_parameter("base_map") != null
	if "--smoke-wardrobe" in OS.get_cmdline_user_args():
		editor.toggle()
		editor.zoom(-0.18)
		swapped = swapped and editor.preview_distance < 2.15
		var face := dancer_model.get_node_or_null("cf_O_face")
		for hair in [false, true]:
			editor.wardrobe.show_for_actor(dancer_model, hair)
			editor.wardrobe.category.select(1 if hair else 0)
			editor.wardrobe.refresh()
			swapped = swapped and editor.wardrobe.results.item_count > 0
			swapped = swapped and editor.wardrobe.category.item_count == (4 if hair else 8)
			if editor.wardrobe.results.item_count > 0:
				editor.wardrobe.results.select(0)
				editor.wardrobe.apply_selected()
				swapped = swapped and editor.wardrobe.summary.text == "Item applied."
			editor.wardrobe.hide()
		swapped = swapped and face != null and face == dancer_model.get_node_or_null("cf_O_face")
		for category_id in [106, 110]:
			editor.wardrobe.show_for_actor(dancer_model, false)
			editor.wardrobe.category.select(editor.wardrobe.category.get_item_index(category_id))
			editor.wardrobe.refresh()
			swapped = swapped and editor.wardrobe.results.item_count > 0
			if editor.wardrobe.results.item_count > 0:
				editor.wardrobe.results.select(0)
				editor.wardrobe.apply_selected()
				swapped = swapped and editor.wardrobe.summary.text == "Item applied."
			editor.wardrobe.hide()
		body = body and Edit.set_clothes(dancer_model, false, "Bottom")
		body = body and Edit.group_visible(Edit.slots(dancer_model), ["Tights"])
		if skin:
			var mask_after_hiding: Vector2 = skin.get_shader_parameter("body_mask_weights")
			body = body and is_zero_approx(mask_after_hiding.y)
		body = body and Edit.set_clothes(dancer_model, true, "Bottom")
		editor.toggle()
	var passed := cards and browser and swapped and body and room_mesh_count >= 8 and smoke_walked and smoke_walk_clip and clipped and dancing and player.is_on_floor() and player_anim.current_animation == "Idle"
	var anatomy := true
	if "--smoke-anatomy" in OS.get_cmdline_user_args():
		anatomy = check_anatomy_profiles()
	var room_meshes := room_mesh_count
	var grounded := player.is_on_floor()
	var idle := player_anim.current_animation == "Idle"
	var interactions := true
	if "--smoke-npc" in OS.get_cmdline_user_args():
		interactions = await check_npc_gameplay()
	var report := "Smoke: room_meshes=%s cards=%s catalog=%s switch=%s body=%s movement=%s walk=%s collision=%s grounded=%s idle=%s dance=%s anatomy=%s interactions=%s" % [
		room_meshes, cards, browser, swapped, body, smoke_walked, smoke_walk_clip, clipped, grounded, idle, dancing, anatomy, interactions]
	print(report)
	get_tree().quit(0 if passed and anatomy and interactions else 1)


func check_npc_gameplay() -> bool:
	var game := npc_gameplay
	Edit.set_clothes(dancer_model, true)
	var event := InputEventKey.new()
	event.keycode = KEY_E
	event.pressed = true
	player.position = dancer_body.position + Vector3(0, 0.12, 1.18)
	await get_tree().physics_frame
	var talk: bool = game.handle_input(event) and game.dialogue.visible and Input.mouse_mode == Input.MOUSE_MODE_VISIBLE
	if not talk:
		return false
	var entry: Dictionary = game.speaking
	var panel_ok: bool = game.choices.get_child_count() == 8 and game.mode_panel.get_child_count() == 3
	var poses := true
	for kind in ["kneel", "fours", "lie_stomach", "lie_back", "skirt"]:
		poses = game.set_posture(entry, {"type": kind}) and poses
		var settle_frames := 164 if kind == "kneel" else (94 if kind == "lie_back" else 78)
		for frame in range(settle_frames):
			await get_tree().physics_frame
		poses = poses and entry.get("posture", {}).get("kind") == kind and entry.posture.complete
	var turning: bool = game.set_posture(entry, {"type": "turn"})
	var initial_yaw := dancer_model.rotation.y
	game.close_dialogue()
	for frame in range(63):
		await get_tree().physics_frame
	poses = poses and turning and absf(absf(angle_difference(initial_yaw, dancer_model.rotation.y)) - PI) < 0.04
	poses = poses and entry.get("posture", {}).get("kind") == "skirt"
	poses = game.set_posture(entry, {"type": "standing"}) and poses
	for frame in range(104):
		await get_tree().physics_frame
	poses = poses and not entry.has("posture")
	game.open_dialogue(entry)
	var rig: Skeleton3D = dancer_model.get_node("Skeleton")
	var green_target: Dictionary = game.contact.zone_anchor(rig, "crown")
	var touched: bool = game.contact.begin(entry, {"id": "crown", "anchor": green_target}, false)
	var head := rig.find_bone("cf_j_head")
	var rest_head := rig.get_bone_pose_rotation(head)
	game.contact.drag_goal = Vector2(0.30, 0.15)
	for frame in range(34):
		await get_tree().physics_frame
	touched = touched and not rest_head.is_equal_approx(rig.get_bone_pose_rotation(head))
	game.contact.release()
	for frame in range(35):
		await get_tree().physics_frame
	touched = touched and game.contact.state.is_empty() and rest_head.is_equal_approx(rig.get_bone_pose_rotation(head))
	var red_target: Dictionary = game.contact.zone_anchor(rig, "cheek_r")
	var marked: bool = game.contact.begin(entry, {"id": "cheek_r", "anchor": red_target}, true)
	for frame in range(120):
		await get_tree().physics_frame
	game.close_dialogue()
	marked = marked and not entry.get("marks", []).is_empty()
	player.position = game.doorway.position + Vector3.UP * 0.14
	await get_tree().physics_frame
	var park: bool = game.handle_input(event) and game.area == "park"
	for frame in range(20):
		await get_tree().physics_frame
	var more_npcs: bool = game.entries.filter(func(npc: Dictionary): return npc.has("actor")).size() >= 2
	var park_floor := player.is_on_floor()
	player.position = game.doorway.position + Vector3.UP * 0.14
	await get_tree().physics_frame
	var returned: bool = game.handle_input(event) and game.area == "room"
	marked = marked and not entry.get("marks", []).is_empty()
	print("NPC smoke: dialogue=%s panel=%s poses=%s touch=%s mark=%s park=%s extra_npcs=%s floor=%s return=%s" %
		[talk, panel_ok, poses, touched, marked, park, more_npcs, park_floor, returned])
	return talk and panel_ok and poses and touched and marked and park and more_npcs and park_floor and returned


func check_anatomy_profiles() -> bool:
	var result := true
	for npc in [true, false]:
		editor.toggle(npc)
		var animator := dancer_anim if npc else player_anim
		result = result and not animator.is_playing() and animator.assigned_animation == &"Idle"
		var before: Node3D = editor.current_actor()
		var part := "o_body_a" if npc else "o_dankon"
		var original := before.get_node_or_null(part) as MeshInstance3D
		Edit.set_clothes(before, false)
		editor.show_anatomy()
		if editor.anatomy_choices.item_count > 1 and original:
			editor.anatomy_choices.select(1)
			editor.apply_anatomy()
			var actor: Node3D = editor.current_actor()
			var replacement := actor.get_node_or_null(part) as MeshInstance3D
			result = result and actor != before and replacement != null and not Edit.is_dressed(actor)
			animator = dancer_anim if npc else player_anim
			result = result and not animator.is_playing() and animator.assigned_animation == &"Idle"
			if replacement:
				result = result and replacement.mesh.surface_get_array_len(0) != original.mesh.surface_get_array_len(0)
			editor.anatomy_choices.select(0)
			editor.apply_anatomy()
			result = result and replacement != editor.current_actor().get_node_or_null(part)
		else:
			result = false
		editor.toggle()
		animator = dancer_anim if npc else player_anim
		result = result and animator.is_playing() and animator.assigned_animation == (&"NPC" if npc else &"Idle")
	return result


func save_preview(path: String) -> void:
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(path)


func save_closeup(path: String) -> void:
	var portrait := Camera3D.new()
	add_child(portrait)
	var focus := dancer_body.position + Vector3.UP * 1.34
	portrait.position = focus + Vector3(0.09, 0.04, 0.96)
	portrait.fov = 39.0
	portrait.near = 0.05
	portrait.look_at(focus)
	portrait.make_current()
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(path)
	camera.make_current()
	portrait.queue_free()


func load_card(path: String, is_npc: bool) -> bool:
	var actor := CardModel.load_actor(path)
	if not actor:
		return false
	if is_npc and path == "res://Content/Npc.kcs":
		for item in [["DefaultSkirt", 106], ["DefaultUnderwear", 108]]:
			var donor := CardModel.load_actor("res://Content/%s.kcs" % item[0])
			if donor:
				var applied := Edit.replace_piece(actor, donor, item[1])
				if applied and item[1] == 106:
					# This rigged skirt moves away from the skin during the lift.
					Edit.clear_bottom_coverage(actor)
					Edit.fit_default_skirt(actor)
				donor.free()
	actor.set_meta("interaction_card", path)
	var animation: AnimationPlayer = actor.get_node("AnimationPlayer")
	var skeleton: Skeleton3D = actor.get_node("Skeleton")
	var library := animation.get_animation_library("")
	var previous := dancer_model if is_npc else player_model
	var keep_undressed := previous != null and not Edit.is_dressed(previous) and Edit.slots(previous).keys().any(
		func(slot: String): return slot != Edit.HAIR)
	if is_npc:
		Edit.grade_npc_skin(actor)
		var clip := CardModel.animation(motion_path(active_npc_motion), skeleton)
		if not clip:
			clip = CardModel.animation(motion_path(DANCE_ID), skeleton)
		if not clip:
			actor.free()
			return false
		library.add_animation("NPC", clip)
		var stand := CardModel.animation(motion_path(IDLE_ID), skeleton)
		if stand:
			library.add_animation("Idle", stand)
		actor.rotation.y = dancer_model.rotation.y if dancer_model else PI
		if dancer_model:
			inspection_animations.erase(dancer_anim)
			dancer_model.queue_free()
		dancer_body.add_child(actor)
		dancer_model = actor
		dancer_anim = animation
		dancer_anim.play("NPC")
	else:
		var idle := CardModel.animation(motion_path(IDLE_ID), skeleton)
		var walk := CardModel.animation(motion_path(WALK_ID), skeleton)
		if not idle or not walk:
			actor.free()
			return false
		library.add_animation("Idle", idle)
		library.add_animation("Walk", walk)
		if player_model:
			actor.rotation.y = player_model.rotation.y
			inspection_animations.erase(player_anim)
			player_model.queue_free()
		player.add_child(actor)
		player_model = actor
		player_anim = animation
		player_anim.play("Idle")
	if editor and editor.is_open():
		hold_inspection_pose(animation)
	if keep_undressed:
		Edit.set_clothes(actor, false)
	return true


func set_inspection_mode(active: bool) -> void:
	hud.visible = not active
	if active:
		hold_inspection_pose(player_anim)
		hold_inspection_pose(dancer_anim)
		return
	for animation: AnimationPlayer in inspection_animations:
		var saved: Array = inspection_animations[animation]
		var skeleton: Skeleton3D = animation.get_node("../Skeleton")
		animation.stop()
		skeleton.reset_bone_poses()
		if saved[0] != &"":
			animation.play(saved[0])
			animation.seek(saved[1], true)
			if not saved[2]:
				animation.pause()
	inspection_animations.clear()


func hold_inspection_pose(animation: AnimationPlayer) -> void:
	inspection_animations[animation] = [animation.assigned_animation, animation.current_animation_position, animation.is_playing()]
	var skeleton: Skeleton3D = animation.get_node("../Skeleton")
	animation.stop()
	skeleton.reset_bone_poses()
	if animation.has_animation("Idle"):
		animation.play("Idle")
		animation.seek(0.0, true)
		animation.pause()


func motion_path(id: String) -> String:
	var local := "user://Motions/%s.kma" % id
	if FileAccess.file_exists(local):
		return local
	var external := OS.get_executable_path().get_base_dir().path_join("Motions").path_join(id + ".kma")
	return external if FileAccess.file_exists(external) else "res://Content/Motions/%s.kma" % id


func play_npc_motion(id: String) -> bool:
	var skeleton: Skeleton3D = dancer_model.get_node("Skeleton")
	var clip := CardModel.animation(motion_path(id), skeleton)
	if not clip:
		return false
	if npc_gameplay:
		var entry: Dictionary = npc_gameplay.entries[0]
		npc_gameplay.finish_action(entry)
		entry.erase("posture")
		entry.erase("conversation_ready")
	var library := dancer_anim.get_animation_library("")
	dancer_anim.stop()
	skeleton.reset_bone_poses()
	library.remove_animation("NPC")
	library.add_animation("NPC", clip)
	active_npc_motion = id
	dancer_anim.play("NPC")
	return true


func _init_rooms() -> void:
	rooms.clear()
	rooms.append({"label": DEFAULT_ROOM, "path": "res://Content/JapaneseStyleRoom.glb", "area": "room"})
	rooms.append({"label": "Koikatsu Park", "path": "res://Content/Park.glb", "area": "park"})
	var roots: Array[String] = []
	roots.append(OS.get_executable_path().get_base_dir().path_join("Rooms"))
	roots.append(ProjectSettings.globalize_path("res://../Build/KKS/Rooms").simplify_path())
	var seen := {"park.glb": true}
	for root in roots:
		if not DirAccess.dir_exists_absolute(root):
			continue
		for name in DirAccess.get_files_at(root):
			if not name.ends_with(".glb"):
				continue
			if seen.has(name):
				continue
			seen[name] = true
			rooms.append({"label": name.trim_suffix(".glb"), "path": root.path_join(name), "builtin": false})


func load_room(index: int) -> bool:
	if rooms.is_empty():
		return false
	var selected := posmod(index, rooms.size())
	var entry: Dictionary = rooms[selected]
	var node: Node = _load_room_scene(entry.path)
	if node == null:
		push_error("Could not load room: " + entry.path)
		return false
	if current_room:
		remove_child(current_room)
		current_room.queue_free()
	current_room = node
	room_index = selected
	add_child(current_room)
	room_label = entry.label
	setup_room(current_room)
	if room_environment:
		room_environment.background_color = Color("#93c6ec") if entry.get("area") == "park" else Color("#4b4f5a")
		room_environment.ambient_light_energy = 0.63 if entry.get("area") == "park" else 0.53
	if npc_gameplay:
		npc_gameplay.set_area(entry.get("area", ""))
	_update_room_hint()
	return true


func local_asset_path(relative: String) -> String:
	if OS.has_feature("editor"):
		return ProjectSettings.globalize_path("res://../Build/KKS/").simplify_path().path_join(relative)
	return OS.get_executable_path().get_base_dir().path_join(relative)


func _load_room_scene(path: String) -> Node:
	if path.begins_with("res://"):
		var packed: PackedScene = load(path)
		return packed.instantiate() if packed else null
	var gltf := GLTFDocument.new()
	var state := GLTFState.new()
	if gltf.append_from_file(path, state) != OK:
		return null
	return gltf.generate_scene(state)


func setup_room(room: Node3D) -> void:
	room_mesh_count = 0
	for child in room.find_children("*", "MeshInstance3D", true, false):
		var mesh := child as MeshInstance3D
		var mesh_name := str(mesh.name)
		# These two meshes serve the original Unity lighting rather than the room geometry.
		var night_sky := room_label == "Koikatsu Park" and mesh_name in ["m00_o_box1_", "m00_o_sky_star1"]
		if "shadow" in mesh_name or "balckback" in mesh_name or night_sky:
			mesh.hide()
			continue
		room_mesh_count += 1
		if room_label == DEFAULT_ROOM:
			apply_baked_materials(mesh)
		var floor := "yuka" in mesh_name or (room_label == "Koikatsu Park" and
			(mesh_name.begins_with("o_kouen_road_") or "sibahu" in mesh_name or "ikegaki" in mesh_name))
		if (floor or "wall" in mesh_name or "kabe" in mesh_name) and not "alfa" in mesh_name:
			var collider := StaticBody3D.new()
			mesh.add_child(collider)
			var surface_shape := mesh.mesh.create_trimesh_shape()
			surface_shape.backface_collision = true
			add_collision(collider, surface_shape, Vector3.ZERO)


func apply_baked_materials(instance: MeshInstance3D) -> void:
	for surface in range(instance.mesh.get_surface_count()):
		var arrays := instance.mesh.surface_get_arrays(surface)
		var uv2: Variant = arrays[Mesh.ARRAY_TEX_UV2]
		var original := instance.get_active_material(surface) as StandardMaterial3D
		if not uv2 or not original or original.transparency != BaseMaterial3D.TRANSPARENCY_DISABLED:
			continue
		var material := ShaderMaterial.new()
		material.shader = ROOM_BAKED
		material.set_shader_parameter("lightmap", ROOM_LIGHTMAP)
		material.set_shader_parameter("direction_map", ROOM_DIRECTION)
		material.set_shader_parameter("base_tint", original.albedo_color)
		if original.albedo_texture:
			material.set_shader_parameter("base_map", original.albedo_texture)
		if original.normal_enabled and original.normal_texture:
			material.set_shader_parameter("normal_map", original.normal_texture)
			material.set_shader_parameter("normal_strength", original.normal_scale)
		if original.emission_enabled:
			material.set_shader_parameter("glow_tint", Vector3(original.emission.r, original.emission.g, original.emission.b))
			if original.emission_texture:
				material.set_shader_parameter("glow_map", original.emission_texture)
		instance.set_surface_override_material(surface, material)


func light_room(room: Node3D) -> void:
	var world := WorldEnvironment.new()
	var environment := Environment.new()
	room_environment = environment
	environment.background_mode = Environment.BG_COLOR
	environment.background_color = Color("#4b4f5a")
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.ambient_light_color = Color("#e1e5ef")
	environment.ambient_light_energy = 0.53
	world.environment = environment
	add_child(world)
	var sun := DirectionalLight3D.new()
	var source := room.find_child("SunLightJapaneseStyleRoom", true, false) as Node3D if room else null
	if source:
		sun.rotation = source.global_rotation
	else:
		sun.rotation_degrees = Vector3(-46, -24, 0)
	sun.light_color = Color("#fff7ee")
	sun.light_energy = 0.38
	sun.light_specular = 0.1
	sun.light_cull_mask = 1
	sun.shadow_caster_mask = 1 | CardModel.CHARACTER_LAYER
	sun.shadow_enabled = true
	sun.shadow_opacity = 0.58
	sun.shadow_blur = 1.65
	sun.directional_shadow_max_distance = 10.0
	add_child(sun)

	var key := DirectionalLight3D.new()
	character_key = key
	key.rotation_degrees = Vector3(-24, -21, 0)
	key.light_color = Color("#fffdfb")
	key.light_energy = 0.93
	key.light_specular = 0.0
	key.light_cull_mask = CardModel.CHARACTER_LAYER
	add_child(key)


func build_hud() -> void:
	hud = CanvasLayer.new()
	add_child(hud)
	var panel := PanelContainer.new()
	panel.position = Vector2(24, 24)
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var background := StyleBoxFlat.new()
	background.bg_color = Color(0.12, 0.10, 0.15, 0.88)
	background.corner_radius_top_left = 12
	background.corner_radius_top_right = 12
	background.corner_radius_bottom_left = 12
	background.corner_radius_bottom_right = 12
	background.content_margin_left = 18
	background.content_margin_right = 18
	background.content_margin_top = 11
	background.content_margin_bottom = 11
	panel.add_theme_stylebox_override("panel", background)
	hud.add_child(panel)
	var hints := VBoxContainer.new()
	hints.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.add_child(hints)
	var label := Label.new()
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.text = "WASD  Move     Mouse  Look     F1  Animations     F2  Character     F5  Pair Preview     F6  Studio Scenes     F7  Animation Lab"
	label.add_theme_font_size_override("font_size", 17)
	label.add_theme_color_override("font_color", Color("#fff3e1"))
	hints.add_child(label)
	room_hint = Label.new()
	room_hint.mouse_filter = Control.MOUSE_FILTER_IGNORE
	room_hint.text = "Room: %s    F3/F4  Next/Previous" % room_label
	room_hint.add_theme_font_size_override("font_size", 15)
	room_hint.add_theme_color_override("font_color", Color("#ffe9c7"))
	hints.add_child(room_hint)


func _update_room_hint() -> void:
	if room_hint:
		room_hint.text = "Room: %s    F3/F4  Next/Previous" % room_label


func add_collision(parent: CollisionObject3D, shape: Shape3D, at: Vector3) -> void:
	var collider := CollisionShape3D.new()
	collider.shape = shape
	collider.position = at
	parent.add_child(collider)
