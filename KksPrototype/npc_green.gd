extends Node3D

const Card := preload("res://card_model.gd")
const Library := preload("res://card_library.gd")
const Pose := preload("res://npc_pose.gd")
const Hands := preload("res://animation_lab_hands.gd")
const Contact := preload("res://hand_contact_motion.gd")
const HandsPanel := preload("res://pov_independent_hands.gd")
const Preset := preload("res://hand_animation_preset.gd")
const Reaction := preload("res://animation_lab_reaction.gd")
const CAMERAS := "user://green_gameplay_cameras.cfg"
const Catalog := "res://Content/F7/h_caressing.json"
const Table := "res://Content/green_interactions.json"
const NATIVE := {"native_chest_l": "Left chest", "native_chest_r": "Right chest",
	"native_lap": "Lap", "native_seat_l": "Left buttock", "native_seat_r": "Right buttock"}
const NATIVE_LAYERS := {"chest": 1, "lap": 4, "seat": 10}

# The panel and hand renderers use the same host interface in the room and the lab.
var stage: Node3D
var actors: Array[Node3D] = [null, null]
var camera: Camera3D
var green_hands := Hands.new()
var panel := HandsPanel.new()
var reaction := Reaction.new()
var shell := PanelContainer.new()
var positions := OptionButton.new()
var status := Label.new()
var bindings := ConfigFile.new()
var rows := {}
var rules := {}
var states := {}
var game: Node3D
var rig: Skeleton3D
var animator: AnimationPlayer
var saved_animation: StringName
var saved_time := 0.0
var saved_playing := false
var player_actor: Node3D
var player_was_visible := true
var saved_pose: Array[Transform3D] = []
var rest: Array[Transform3D] = []
var fade_from: Array[Transform3D] = []
var clips := {}
var clip: Animation
var clip_data := {}
var state := ""
var clock := 0.0
var duration := 0.0
var fade := 0.0
var position_id := 0
var leader := -1
var route := {}
var phase := ""
var pointer_hands := [false, false]
var confirmed := [{}, {}]
var session_entry := {}
var failure := ""
var game_positions := {}
var camera_presets := ConfigFile.new()
var frame_root := Transform3D.IDENTITY
var fixed_view := {}
var saved_rotation := Vector3.ZERO
var saved_gaze := false
var lower_body := {}
var hems: Array[int] = []
var skirt_grips := {}
var control := OptionButton.new()
var controlled_hand := OptionButton.new()
var diagnostics := Label.new()
var camera_edit := HFlowContainer.new()
var camera_fields: Array[SpinBox] = []


func setup(owner: Node3D, canvas: CanvasLayer) -> void:
	game = owner
	stage = self
	camera = game.room.camera
	add_child(green_hands)
	var catalog: Variant = JSON.parse_string(FileAccess.get_file_as_string(Catalog))
	var mapping: Variant = JSON.parse_string(FileAccess.get_file_as_string(Table))
	if catalog is Dictionary and mapping is Dictionary:
		rows = catalog.get("positions", {})
		rules = mapping
		game_positions = rules.get("game_positions", {})
	camera_presets.load(CAMERAS)
	# Anchor the panel to the right edge of the room, clear of the dialogue.
	canvas.add_child(shell)
	shell.set_anchors_and_offsets_preset(Control.PRESET_CENTER_RIGHT)
	shell.offset_left = -475.0
	shell.offset_right = -18.0
	shell.offset_top = -210.0
	var layout := VBoxContainer.new()
	shell.add_child(layout)
	var toolbar := HFlowContainer.new()
	layout.add_child(toolbar)
	toolbar.add_child(positions)
	for id: String in game_positions:
		positions.add_item(game_positions[id].label, int(id))
	positions.item_selected.connect(func(index: int): select_position(positions.get_item_id(index)))
	_button(toolbar, "Stop", panel.release_all)
	_button(toolbar, "Restart", restart)
	var controls := HFlowContainer.new()
	layout.add_child(controls)
	for item in ["Automatic", "Mouse Controlled"]:
		control.add_item(item)
	for item in ["Control Left", "Control Right"]:
		controlled_hand.add_item(item)
	control.item_selected.connect(func(_i: int): _update_control())
	controlled_hand.item_selected.connect(func(_i: int): _update_control())
	controls.add_child(control)
	controls.add_child(controlled_hand)
	controlled_hand.disabled = true
	_button(controls, "Diagnostics", func(): diagnostics.visible = not diagnostics.visible)
	layout.add_child(panel)
	panel.setup(self, bindings, NATIVE)
	status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	layout.add_child(status)
	diagnostics.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	layout.add_child(diagnostics)
	diagnostics.hide()
	layout.add_child(camera_edit)
	for field in ["Eye X", "Eye Y", "Eye Z", "Look X", "Look Y", "Look Z"]:
		var value := SpinBox.new()
		value.min_value = -5.0
		value.max_value = 5.0
		value.step = 0.01
		value.prefix = field
		value.value_changed.connect(func(_number: float): _preview_camera())
		camera_edit.add_child(value)
		camera_fields.append(value)
	_button(camera_edit, "Save camera", _save_camera)
	_button(camera_edit, "Reset camera", _reset_camera)
	camera_edit.hide()
	shell.hide()


func _button(parent: Control, caption: String, callback: Callable) -> void:
	var button := Button.new()
	button.text = caption
	button.pressed.connect(callback)
	parent.add_child(button)


func active() -> bool:
	return shell.visible


func begin(entry: Dictionary) -> bool:
	var npc: Node3D = game.actor_for(entry)
	if active() or not npc or game_positions.is_empty():
		return false
	game.contact.end()
	game.staging.stop()
	game.finish_action(entry)
	actors[1] = npc
	rig = npc.get_node("Skeleton")
	animator = npc.get_node("AnimationPlayer")
	saved_animation = animator.assigned_animation
	saved_playing = animator.is_playing()
	saved_time = animator.current_animation_position if animator.has_animation(saved_animation) else 0.0
	saved_pose = Pose.capture(rig)
	saved_rotation = npc.rotation
	saved_gaze = entry.get("face_speaker", false)
	var toward: Vector3 = (game.room.player.global_position - npc.global_position).slide(Vector3.UP)
	var forward := toward.normalized() if toward.length_squared() > 0.01 else -npc.global_basis.z.normalized()
	frame_root = Transform3D(Basis.looking_at(forward) * Basis(Vector3.UP, PI), npc.global_position)
	rest = Pose.rest(rig)
	animator.pause()
	session_entry = entry
	if not green_hands.load_items():
		end()
		return false
	game.player_view.restore()
	player_actor = game.room.player_model
	player_was_visible = player_actor.visible
	player_actor.hide()
	game.choices.hide()
	bindings.clear()
	bindings.load(Preset.ASSIGNMENTS)
	shell.show()
	panel.activate(true)
	_update_control()
	var posture: String = entry.get("posture", {}).get("kind", "standing")
	var initial := {"fours": 2, "lie_stomach": 2, "lie_back": 1, "skirt": 12, "behind": 13, "kneel": 14}
	select_position(int(entry.get("green_position", initial.get(posture, 0))))
	if duration <= 0.0:
		end()
		return false
	return true


func end() -> void:
	if not active() and not is_instance_valid(rig):
		return
	panel.activate(false)
	for hand in green_hands.items:
		hand.node.hide()
	reaction.setup(null, -1, "")
	if is_instance_valid(rig) and is_instance_valid(animator):
		if animator.has_animation(saved_animation):
			animator.play(saved_animation)
			animator.seek(saved_time, true)
			if not saved_playing:
				animator.pause()
		Pose.blend(rig, saved_pose, saved_pose, 1.0)
		actors[1].rotation = saved_rotation
		session_entry.face_speaker = saved_gaze
	if is_instance_valid(player_actor):
		player_actor.visible = player_was_visible
	player_actor = null
	game.choices.show()
	camera_edit.hide()
	shell.hide()
	actors[1] = null
	animator = null
	rig = null
	session_entry = {}
	clips.clear()
	states.clear()
	clip = null
	duration = 0.0
	state = ""
	leader = -1
	route = {}
	phase = ""
	pointer_hands = [false, false]


func select_position(id: int) -> void:
	if not active() or not game_positions.has(str(id)):
		return
	var info: Dictionary = game_positions[str(id)]
	panel.cancel()
	confirmed = [{}, {}]
	pointer_hands = [false, false]
	var catalog_id := int(info.catalog)
	green_hands.choose_pose(catalog_id)
	position_id = id
	session_entry.green_position = id
	positions.select(positions.get_item_index(id))
	var direction := -frame_root.basis.z.rotated(Vector3.UP, PI + deg_to_rad(float(info.get("yaw", 0))))
	actors[1].global_rotation.y = atan2(-direction.x, -direction.z)
	states.clear()
	for record: Dictionary in rows[str(catalog_id)].states:
		states[record.state] = record
	_prepare_pose(String(info.get("layer", "")))
	leader = -1
	route = {}
	phase = "Idle"
	reaction.setup(actors[1], catalog_id, "Idle")
	_switch("Idle", "game", true)
	_read_camera()


func _prepare_pose(layer: String) -> void:
	lower_body.clear()
	hems.clear()
	skirt_grips.clear()
	if layer == "skirt":
		hems = game.skirt_bones(actors[1])
		skirt_grips = game.skirt_grip_vertices(actors[1], rig, hems)
	elif layer == "kneel":
		var group: Array = game.animation_groups.get("kneel", [])
		for item: Dictionary in group:
			var motion := Card.animation(_motion_path(String(item.id)), rig)
			if not motion:
				continue
			game.use_kneeling_legs(motion, rig)
			var at := float(item.get("pose_at", item.get("end_at", motion.length)))
			var kneel := Pose.sample(motion, rig, rest, at)
			for joint in [0, rig.find_bone("cf_j_hips"), rig.find_bone("cf_j_root")]:
				if joint >= 0:
					lower_body[joint] = kneel[joint]
			for joint in rig.get_bone_count():
				var bone := String(rig.get_bone_name(joint)).to_lower()
				if ["thigh", "leg0", "foot", "toe"].any(func(part: String): return part in bone):
					lower_body[joint] = kneel[joint]
			break


func _apply_game_pose() -> void:
	for joint: int in lower_body:
		rig.set_bone_pose(joint, lower_body[joint])
	match String(game_positions[str(position_id)].get("layer", "")):
		"skirt":
			if not hems.is_empty():
				game.play_skirt(rig, hems, 1.45, skirt_grips)
		"behind":
			var posed := Pose.capture(rig)
			var adjusted: Array[Transform3D] = game.standing_variant(rig, posed, "behind")
			Pose.blend(rig, posed, adjusted, 1.0)


func restart() -> void:
	select_position(position_id)


func toggle_camera_editor() -> void:
	camera_edit.visible = not camera_edit.visible
	_read_camera()


func _read_camera() -> void:
	var default: Array = game_positions[str(position_id)].camera
	var values: Variant = camera_presets.get_value(str(position_id), "frame", default)
	if not values is Array or values.size() != 6:
		values = default
	for index in 6:
		camera_fields[index].set_value_no_signal(float(values[index]))
	_preview_camera()


func _preview_camera() -> void:
	if not active():
		return
	var eye := frame_root * Vector3(camera_fields[0].value, camera_fields[1].value, camera_fields[2].value)
	var focus := frame_root * Vector3(camera_fields[3].value, camera_fields[4].value, camera_fields[5].value)
	var trace := PhysicsRayQueryParameters3D.create(focus, eye, 1)
	var hit := get_world_3d().direct_space_state.intersect_ray(trace)
	if not hit.is_empty():
		eye = hit.position.move_toward(focus, 0.11)
	if eye.distance_squared_to(focus) > 0.0225:
		fixed_view = {"eye": eye, "focus": focus}


func _save_camera() -> void:
	var values := []
	for field in camera_fields:
		values.append(field.value)
	camera_presets.set_value(str(position_id), "frame", values)
	var error := camera_presets.save(CAMERAS)
	panel.status.text = "Camera saved" if error == OK else error_string(error)


func _reset_camera() -> void:
	var key := str(position_id)
	if camera_presets.has_section_key(key, "frame"):
		camera_presets.erase_section_key(key, "frame")
		camera_presets.save(CAMERAS)
	_read_camera()


func _update_control() -> void:
	var hand := controlled_hand.selected if control.selected == 1 else -1
	controlled_hand.disabled = hand < 0
	for i in 2:
		panel.runners[i].set_mouse_control(i == hand)


func mouse_motion(relative: Vector2) -> void:
	if control.selected != 1:
		return
	var runner: Node3D = panel.runners[controlled_hand.selected]
	if not runner.running:
		return
	var kind: String = runner.custom_animation.contact.kind
	var amount := -relative.y
	if kind == "cheek":
		var target: String = runner.custom_animation.contact.side
		var at: Transform3D = runner.contact_result.get("anchor", Transform3D.IDENTITY)
		if not runner.contact_result.is_empty():
			var outward := at.basis.x * (1.0 if target == "L" else -1.0)
			var direction := camera.unproject_position(at.origin + outward * 0.08) - camera.unproject_position(at.origin)
			amount = relative.dot(direction.normalized()) if not direction.is_zero_approx() else relative.x
	elif kind != "chin" and runner.contact_result.has("anchor"):
		var at: Transform3D = runner.contact_result.anchor
		var first := camera.unproject_position(at.origin)
		var last := camera.unproject_position(at.origin + at.basis.y * 0.10)
		var axis := (last - first).normalized()
		if not axis.is_zero_approx():
			amount = relative.dot(axis)
	runner.push_mouse_motion(amount)


func _rule(action: String) -> Dictionary:
	var action_rules: Dictionary = rules.get("actions", {})
	var override: Dictionary = rules.get("positions", {}).get(str(position_id), {}).get(action, {})
	var result: Dictionary = action_rules.get(action, {}).duplicate()
	result.merge(override, true)
	return result


func native_preset(action: String, side: String) -> Dictionary:
	var rule := _rule(action)
	var target := "R" if action.ends_with("_r") else "L"
	var data := {"kind": rule.zone, "side": target, "approach": 0.39, "release": 0.34,
		"amplitude": 1.0, "speed": 1.0}
	var value := Preset.create("p_hand" + side, 0, Contact.bone_name(data))
	value.name = action
	value.action = action
	value.contact = data
	value.duration = 2.20
	value.finger_layer = NATIVE_LAYERS[rule.zone]
	for index in 4:
		var point := Vector3(0.0, 0.018 * sin(index * TAU / 3.0), 0.0)
		value.keys.append(Preset.frame(lerpf(0.39, 1.86, index / 3.0), Transform3D(Basis.IDENTITY, point)))
	return value


func _motion_path(key: String) -> String:
	var file := key + ".kma"
	var paths := ["user://Motions".path_join(file),
		Library.directory().get_base_dir().get_base_dir().path_join("Motions").path_join(file),
		"res://Content/F7/States".path_join(file), "res://Content/Motions".path_join(file)]
	for path: String in paths:
		if FileAccess.file_exists(path):
			return path
	return ""


func _switch(next: String, source: String, restart_clip := false) -> bool:
	if not restart_clip and next == state:
		return true
	var record: Dictionary = states.get(next, {})
	var selected: Variant = record.get(source)
	if selected == null and source == "game":
		selected = record.get("studio")
	if not selected is Dictionary:
		failure = "Unavailable: " + next
		return false
	var key := String(selected.kma)
	if not clips.has(key):
		var path := _motion_path(key)
		clips[key] = Card.animation(path, rig) if not path.is_empty() else null
	var motion: Animation = clips[key]
	if not motion or motion.get_track_count() == 0:
		failure = "Missing KMA: " + key
		return false
	reaction.restore_pose()
	fade_from = Pose.capture(rig)
	fade = 0.0
	clip = motion
	clip_data = selected
	duration = clip.length / maxf(absf(float(selected.speed)), 0.001)
	state = next
	clock = 0.0
	reaction.live_state = next
	failure = ""
	return true


func _update_body() -> void:
	var chosen := -1
	var priority := 0
	var candidate := {}
	for i in 2:
		var runner: Node3D = panel.runners[i]
		if not runner.running:
			confirmed[i] = {}
			continue
		if runner.blend < 0.94:
			continue
		if runner.contact_result.get("surface", false):
			confirmed[i] = runner.custom_animation
		if confirmed[i] != runner.custom_animation:
			continue
		var rule := _rule(String(runner.custom_animation.get("action", runner.custom_animation.name)))
		var ranking := int(rule.get("priority", 0)) if rule.has("contact") and rule.has("loop") and rule.has("source") else 0
		if ranking > priority or (ranking == priority and ranking > 0 and i == leader):
			chosen = i
			priority = ranking
			candidate = rule
	if chosen >= 0:
		if route == candidate:
			leader = chosen
		elif _switch(candidate.contact, candidate.source):
			leader = chosen
			route = candidate
			phase = "Contact"
	if leader < 0:
		return
	if phase == "Contact" and clock < duration:
		return
	if chosen < 0:
		if _switch(route.get("release", "Idle"), route.source) or _switch("Idle", "game"):
			leader = -1
			route = {}
			phase = "Release"
	elif phase == "Contact" and _switch(route.loop, route.source):
		phase = "Loop"


func tick(delta: float) -> void:
	if not active():
		return
	if game.mode != 0 or not game.dialogue.visible or game.speaking != session_entry or game.actor_for(session_entry) != actors[1]:
		end()
		return
	panel.advance(delta)
	_update_body()
	if not clip:
		status.text = failure
		return
	clock += delta
	fade = minf(1.0, fade + delta / 0.30)
	reaction.restore_pose()
	var normalized := clock / duration
	var looping: bool = clip_data.loop and phase != "Contact"
	if not looping:
		normalized = clampf(normalized, 0.0, 1.0)
	if float(clip_data.speed) < 0.0:
		normalized = 1.0 - normalized
	normalized += float(clip_data.offset)
	var at := (fposmod(normalized, 1.0) if looping else clampf(normalized, 0.0, 1.0)) * clip.length
	var pose := Pose.sample(clip, rig, rest, at)
	Pose.blend(rig, fade_from, pose, Pose.smooth(fade))
	_apply_game_pose()
	rig.force_update_all_bone_transforms()
	var contacts := panel.reaction_contacts()
	for contact in contacts:
		var mapping := _rule(String(contact.style))
		contact.face_group = mapping.get("face", "")
		contact.face_presets = mapping.get("face_presets", [])
		contact.kind = mapping.get("reaction", contact.kind)
	reaction.advance(green_hands, camera.global_position, delta, contacts, panel.reaction_mode.selected)
	reaction.apply()
	rig.force_update_all_bone_transforms()
	if phase == "Release":
		if state == "Idle" and fade >= 1.0:
			phase = "Idle"
		elif state != "Idle" and clock >= duration:
			_switch("Idle", "game")
	var display_phase := phase
	for runner in panel.runners:
		if runner.tool_id >= 0 and phase == "Idle":
			var kind: String = runner.custom_animation.contact.kind
			display_phase = ("%s surface" % kind.capitalize()) if runner.contact_result.get("surface", false) else "Approach"
			break
	var caption := "%s | %s | %s" % [display_phase, state, clip_data.clip]
	if not failure.is_empty():
		caption += " | " + failure
	status.text = caption
	if diagnostics.visible:
		var runner: Node3D = panel.runners[controlled_hand.selected]
		diagnostics.text = "%s | %s | %.0f%% | %.2f s/s | %s | %s | %s" % [
			"L" if controlled_hand.selected == 0 else "R", runner.custom_animation.get("name", "-"),
			runner.action_phase * 100.0, runner.drag_speed,
			"forward" if runner.drag_speed > 0.02 else ("back" if runner.drag_speed < -0.02 else "still"),
			str(runner.contact_result.get("point", "-")), reaction.contact_mix.lead_kind]


func camera_view() -> Dictionary:
	return fixed_view


func pick(position: Vector2) -> Dictionary:
	return game.contact.pick(position, rules.get("pointer_actions", {}))


func pointer(event: InputEventMouseButton) -> bool:
	if event.button_index not in [MOUSE_BUTTON_LEFT, MOUSE_BUTTON_RIGHT]:
		return false
	var i := int(event.button_index == MOUSE_BUTTON_RIGHT)
	if not event.pressed:
		if pointer_hands[i]:
			panel.release(i)
			pointer_hands[i] = false
		return true
	var target := pick(event.position)
	var action := String(rules.get("pointer_actions", {}).get(target.get("id", ""), ""))
	if action.is_empty():
		return true
	var preset := panel.preset_for(action, "R" if i else "L")
	if preset.is_empty():
		return true
	var target_id := String(target.id)
	if target_id.ends_with("_l") or target_id.ends_with("_r"):
		var target_side := target_id.right(1).to_upper()
		if preset.contact.kind == "cheek" and preset.contact.side != target_side:
			for key: Dictionary in preset.keys:
				key.position[0] = -float(key.position[0])
		preset.contact.side = target_side
	pointer_hands[i] = panel.start(i, preset).is_empty()
	return true
