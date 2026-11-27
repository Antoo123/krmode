extends Node3D

const Card := preload("res://card_model.gd")
const Edit := preload("res://character_edit.gd")
const Pose := preload("res://npc_pose.gd")
const Contact := preload("res://npc_contact.gd")
const Staging := preload("res://npc_staging.gd")
const Limbs := preload("res://player_view_limbs.gd")
const WALK_SPEED := 1.75
const TALK_RANGE := 1.85
const ENTER_TIME := 0.38
const EXIT_TIME := 0.50
const HUG_GAP := 0.38
const HUG_APPROACH_GAP := 0.63

var room: Node3D
var data: Dictionary
var animation_groups: Dictionary
var entries: Array[Dictionary] = []
var area := ""
var doorway: Node3D
var doorway_label: Label3D
var prompt: Label
var dialogue: PanelContainer
var dialogue_title: Label
var mode_panel: HBoxContainer
var rear_choices: HBoxContainer
var mode_hint: Label
var mode := 0
var contact: Contact
var staging: Staging
var green := preload("res://npc_green.gd").new()
var green_button: Button
var pending_contact: Array[InputEventMouseButton] = []
var look_height := 0.0
var player_view := Limbs.new()
var answer: Label
var choices: VBoxContainer
var speaking: Dictionary = {}
var previous_mouse := Input.MOUSE_MODE_CAPTURED
var hug_owner: Dictionary = {}
var slap_marks: Dictionary = {}
var slap_state: Dictionary = {}


func slap_head_bone(skeleton: Skeleton3D) -> int:
	for name in ["cf_j_head", "cf_J_Head", "cf_j_face", "cf_j_neck", "cf_J_Neck"]:
		var bone := skeleton.find_bone(name)
		if bone >= 0:
			return bone
	return -1


func _ready() -> void:
	room = get_parent()
	contact = Contact.new(self)
	staging = Staging.new(self)
	data = JSON.parse_string(FileAccess.get_file_as_string("res://Content/dialogue.json"))
	var animations: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://Content/important_animations.json"))
	animation_groups = animations["groups"]
	var canvas := CanvasLayer.new()
	add_child(canvas)
	add_child(green)
	green.setup(self, canvas)
	prompt = Label.new()
	canvas.add_child(prompt)
	prompt.set_anchors_and_offsets_preset(Control.PRESET_CENTER_BOTTOM)
	prompt.offset_left = -250
	prompt.offset_right = 250
	prompt.offset_top = -62
	prompt.offset_bottom = -30
	prompt.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	prompt.add_theme_color_override("font_shadow_color", Color.BLACK)
	prompt.add_theme_constant_override("shadow_offset_x", 2)
	prompt.add_theme_constant_override("shadow_offset_y", 2)
	prompt.mouse_filter = Control.MOUSE_FILTER_IGNORE

	dialogue = PanelContainer.new()
	dialogue.offset_left = 24
	dialogue.offset_top = 64
	dialogue.offset_right = 248
	var content := VBoxContainer.new()
	content.add_theme_constant_override("separation", 8)
	dialogue.add_child(content)
	dialogue_title = Label.new()
	dialogue_title.add_theme_font_size_override("font_size", 21)
	content.add_child(dialogue_title)
	answer = Label.new()
	answer.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	answer.custom_minimum_size = Vector2(205, 45)
	content.add_child(answer)
	choices = VBoxContainer.new()
	content.add_child(choices)
	var close := Button.new()
	close.text = "Close [E]"
	close.pressed.connect(close_dialogue)
	content.add_child(close)
	green_button = Button.new()
	green_button.text = "Green animations"
	green_button.pressed.connect(_open_green)
	content.add_child(green_button)
	var fade := CheckButton.new()
	fade.text = "Fade Forearms"
	fade.tooltip_text = "20% opacity on the forearms, opaque hands"
	fade.toggled.connect(player_view.fade_forearms)
	content.add_child(fade)
	canvas.add_child(dialogue)
	dialogue.hide()

	mode_panel = HBoxContainer.new()
	canvas.add_child(mode_panel)
	mode_panel.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT)
	mode_panel.offset_left = -192
	mode_panel.offset_right = -24
	mode_panel.offset_top = 24
	var modes := ButtonGroup.new()
	var labels: Array[String] = ["Kind", "Neutral", "Hostile"]
	var colors: Array[Color] = [Color("#53da8d"), Color("#f4ce59"), Color("#ff6671")]
	for index in range(3):
		var button := Button.new()
		button.custom_minimum_size = Vector2(51, 41)
		button.text = "●"
		button.tooltip_text = labels[index]
		button.add_theme_font_size_override("font_size", 23)
		var selected := StyleBoxFlat.new()
		selected.bg_color = Color("#202730")
		selected.border_color = colors[index]
		selected.set_border_width_all(2)
		selected.set_corner_radius_all(6)
		button.add_theme_stylebox_override("pressed", selected)
		button.add_theme_stylebox_override("hover_pressed", selected)
		button.toggle_mode = true
		button.button_group = modes
		button.button_pressed = index == 0
		for theme in ["font_color", "font_hover_color", "font_pressed_color", "font_focus_color"]:
			button.add_theme_color_override(theme, colors[index])
		button.pressed.connect(func():
			if green.active() and index != 0:
				green.end()
			mode = index
			green_button.visible = mode == 0
			contact.release()
			if dialogue.visible:
				if mode == 0:
					_ensure_green()
				elif not speaking.has("posture") and not speaking.get("conversation_ready", false):
					set_posture(speaking, {"type": "standing"})
					speaking.conversation_ready = true
			if staging.active() and not staging.seated():
				staging.cancel()
			show_mode_hint())
		mode_panel.add_child(button)
	mode_panel.hide()
	rear_choices = HBoxContainer.new()
	canvas.add_child(rear_choices)
	rear_choices.set_anchors_and_offsets_preset(Control.PRESET_CENTER_TOP)
	rear_choices.offset_left = -185
	rear_choices.offset_right = 185
	rear_choices.offset_top = 72
	for option in [["1  Hold & touch", "hold"], ["2  Rear embrace", "embrace"], ["3  Push", "push"]]:
		var rear_button := Button.new()
		rear_button.text = option[0]
		rear_button.add_theme_font_size_override("font_size", 14)
		rear_button.pressed.connect(contact.choose_rear_action.bind(option[1]))
		rear_choices.add_child(rear_button)
	rear_choices.hide()
	mode_hint = Label.new()
	canvas.add_child(mode_hint)
	mode_hint.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_RIGHT)
	mode_hint.offset_left = -700
	mode_hint.offset_right = -24
	mode_hint.offset_top = -68
	mode_hint.offset_bottom = -18
	mode_hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	mode_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	mode_hint.add_theme_color_override("font_shadow_color", Color.BLACK)
	mode_hint.add_theme_constant_override("shadow_offset_x", 2)
	mode_hint.add_theme_constant_override("shadow_offset_y", 2)
	mode_hint.mouse_filter = Control.MOUSE_FILTER_IGNORE
	mode_hint.hide()

	doorway = Node3D.new()
	add_child(doorway)
	var marker := MeshInstance3D.new()
	var cylinder := CylinderMesh.new()
	cylinder.top_radius = 0.42
	cylinder.bottom_radius = 0.42
	cylinder.height = 0.018
	marker.mesh = cylinder
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.albedo_color = Color(0.25, 0.76, 1.0, 0.58)
	marker.material_override = material
	doorway.add_child(marker)
	doorway_label = Label3D.new()
	doorway_label.position.y = 1.75
	doorway_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	doorway_label.pixel_size = 0.004
	doorway.add_child(doorway_label)
	for definition in data["npcs"]:
		entries.append({"definition": definition, "primary": definition.get("primary", false),
			"follows": false})
	set_area("room")


func vector(values: Array) -> Vector3:
	return Vector3(values[0], values[1], values[2])


func set_area(value: String) -> void:
	close_dialogue(true)
	contact.end()
	for entry in entries:
		finish_action(entry)
	area = value
	doorway.visible = data["areas"].has(area)
	if doorway.visible:
		var configuration: Dictionary = data["areas"][area]
		doorway.position = vector(configuration["exit_position"])
		doorway_label.text = configuration["exit_label"]
	for entry in entries:
		if entry.primary:
			continue
		if area == "park" and not entry.has("body"):
			spawn(entry)
		if entry.has("body"):
			var body: CharacterBody3D = entry.body
			body.visible = area == "park" or (area == "room" and entry.follows)
			body.collision_layer = 1 if body.visible else 0
			if body.visible:
				body.position = vector(entry.definition.position) if area == "park" else Vector3(1.75, 0.16, 1.65)
				body.velocity = Vector3.ZERO


func spawn(entry: Dictionary) -> void:
	var file: String = room.local_asset_path(entry.definition.card)
	var actor := Card.load_actor(file)
	if not actor:
		push_warning("NPC card unavailable: " + file)
		return
	Edit.grade_npc_skin(actor)
	var body := CharacterBody3D.new()
	body.floor_snap_length = 0.22
	var capsule := CapsuleShape3D.new()
	capsule.height = 1.65
	capsule.radius = 0.24
	room.add_collision(body, capsule, Vector3.UP * 0.82)
	add_child(body)
	body.add_child(actor)
	actor.set_meta("interaction_card", file)
	entry.body = body
	entry.actor = actor
	entry.animator = actor.get_node("AnimationPlayer")
	ensure_locomotion(entry.animator)
	entry.animator.play("Idle")


func actor_for(entry: Dictionary) -> Node3D:
	return room.dancer_model if entry.primary else entry.get("actor")


func body_for(entry: Dictionary) -> CharacterBody3D:
	return room.dancer_body if entry.primary else entry.get("body")


func animator_for(entry: Dictionary) -> AnimationPlayer:
	var actor := actor_for(entry)
	return actor.get_node("AnimationPlayer") if actor else null


func ensure_locomotion(animator: AnimationPlayer) -> void:
	var skeleton: Skeleton3D = animator.get_node("../Skeleton")
	var library := animator.get_animation_library("")
	for pair in [["Idle", room.IDLE_ID], ["Walk", room.WALK_ID]]:
		if not animator.has_animation(pair[0]):
			var animation := Card.animation(room.motion_path(pair[1]), skeleton)
			if animation:
				library.add_animation(pair[0], animation)


func idle_pose(animator: AnimationPlayer, skeleton: Skeleton3D, base: Array[Transform3D]) -> Array[Transform3D]:
	if not animator.has_animation("ConversationIdle"):
		var idle := Card.animation(room.motion_path(animation_groups.idle[0].id), skeleton)
		if idle:
			animator.get_animation_library("").add_animation("ConversationIdle", idle)
	var clip := &"ConversationIdle" if animator.has_animation("ConversationIdle") else &"Idle"
	return Pose.sample(animator.get_animation(clip), skeleton, base, 0.0)


func holds_player_pose() -> bool:
	if green.active():
		return true
	if staging and staging.active():
		return true
	if contact and not contact.state.is_empty():
		return true
	if not hug_owner.is_empty() and hug_owner.action.get("partner") == room.player_anim:
		return true
	return player_in_slap()


func player_in_slap() -> bool:
	for entry in entries:
		if entry.get("action", {}).has("player_skeleton"):
			return true
	return false


func current_interaction() -> Dictionary:
	var closest: Dictionary = {}
	var limit := TALK_RANGE
	var origin: Vector3 = room.player.global_position
	if doorway.visible:
		var distance := doorway.global_position.distance_to(origin)
		if distance < 1.22:
			closest = {"exit": true}
			limit = distance
	for entry in entries:
		var body := body_for(entry)
		if not body or not body.visible:
			continue
		var distance := origin.distance_to(body.global_position)
		if distance >= limit:
			continue
		var ray := PhysicsRayQueryParameters3D.create(origin + Vector3.UP, body.global_position + Vector3.UP,
			1, [room.player.get_rid(), body.get_rid()])
		if not room.get_world_3d().direct_space_state.intersect_ray(ray).is_empty():
			continue
		closest = entry
		limit = distance
	return closest


func _input(event: InputEvent) -> void:
	if mode == 0 and green.active() and event is InputEventMouseButton and not event.pressed:
		if event.button_index in [MOUSE_BUTTON_LEFT, MOUSE_BUTTON_RIGHT]:
			pending_contact.append(event)


func handle_input(event: InputEvent) -> bool:
	if dialogue.visible:
		if event is InputEventKey and event.pressed and not event.echo and event.keycode in [KEY_ESCAPE, KEY_E]:
			close_dialogue()
			return true
		if event is InputEventKey and event.pressed and not event.echo and rear_choices.visible:
			var options := {KEY_1: "hold", KEY_2: "embrace", KEY_3: "push"}
			if options.has(event.keycode):
				contact.choose_rear_action(options[event.keycode])
				return true
		if mode == 0:
			if event is InputEventMouseMotion:
				if green.active():
					green.mouse_motion(event.relative)
				return true
			if event is InputEventMouseButton:
				if event.pressed and event.button_index in [MOUSE_BUTTON_LEFT, MOUSE_BUTTON_RIGHT]:
					pending_contact.append(event)
				return true
		if event is InputEventMouseButton and event.pressed and event.button_index in [MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN]:
			look_height = clampf(look_height + (0.12 if event.button_index == MOUSE_BUTTON_WHEEL_UP else -0.12), -0.50, 0.39)
			return true
		if event is InputEventMouseButton:
			pending_contact.append(event)
			return true
		return staging.smooth_approach() or contact.input(event, mode)
	if staging.smooth_approach():
		return true
	if event is not InputEventKey or not event.pressed or event.echo or event.keycode != KEY_E:
		return false
	if room.menu.is_open() or room.editor.is_open():
		return false
	var target := current_interaction()
	if target.is_empty():
		return false
	if target.get("exit", false):
		travel("park" if area == "room" else "room")
	else:
		open_dialogue(target)
	return true


func travel(destination: String) -> bool:
	var index: int = room.rooms.find_custom(func(entry: Dictionary): return entry.get("area") == destination)
	if index < 0 or not room.load_room(index):
		return false
	var configuration: Dictionary = data["areas"][destination]
	room.player.position = vector(configuration["player_spawn"])
	room.player.velocity = Vector3.ZERO
	room.dancer_body.position = vector(configuration["npc_spawn"])
	room.dancer_body.velocity = Vector3.ZERO
	room.camera.position = room.player.position + Vector3(0.57, 2.05, 2.6)
	room.update_camera(1.0)
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	return true


func open_dialogue(entry: Dictionary) -> void:
	if dialogue.visible:
		return
	speaking = entry
	previous_mouse = Input.mouse_mode
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	room.hud.hide()
	var turn_to_speaker: bool = not entry.get("facing_locked", false)
	look_height = 0.0
	player_view.show_limbs(room.player_model, {}, false)
	dialogue_title.text = entry.definition.name
	if mode != 0 and not entry.has("posture") and not entry.get("conversation_ready", false):
		set_posture(entry, {"type": "standing"})
		entry.conversation_ready = true
	if contact.state.is_empty():
		var player_anim: AnimationPlayer = room.player_anim
		var player_rig: Skeleton3D = room.player_model.get_node("Skeleton")
		idle_pose(player_anim, player_rig, Pose.rest(player_rig))
		if player_anim.has_animation("ConversationIdle"):
			player_anim.play("ConversationIdle", 0.28)
	entry.face_speaker = turn_to_speaker
	answer.text = data["greeting"]
	rebuild_posture_buttons()
	dialogue.show()
	mode_panel.show()
	mode_hint.show()
	green_button.visible = mode == 0
	if mode == 0:
		_ensure_green()
	show_mode_hint()


func _ensure_green() -> void:
	if not green.active() and not speaking.is_empty() and not green.begin(speaking):
		answer.text = "Green animation is unavailable for this card."


func _open_green() -> void:
	if mode == 0 and dialogue.visible and not speaking.is_empty():
		_ensure_green()
		if green.active():
			green.toggle_camera_editor()


func close_dialogue(immediate := false) -> void:
	if green.active():
		green.end()
	if immediate:
		staging.stop()
	if not dialogue.visible:
		return
	contact.release()
	staging.cancel()
	pending_contact.clear()
	dialogue.hide()
	player_view.restore()
	mode_panel.hide()
	rear_choices.hide()
	mode_hint.hide()
	speaking = {}
	Input.set_default_cursor_shape(Input.CURSOR_ARROW)
	room.hud.show()
	Input.mouse_mode = previous_mouse


func show_mode_hint(zone := "") -> void:
	var hints := [
		"Hold left or right mouse for that hand",
		"Click lips to kiss · hold a highlighted zone",
		"Click to strike · Hold hair or hand to grab",
	]
	if green.active():
		mode_hint.text = "Green: hold left or right mouse over the NPC, or select an action."
		return
	var gesture: String = contact.action_hint()
	var suffix := "  ·  " + gesture if not gesture.is_empty() else "  ·  Scroll to look up / down"
	mode_hint.text = (zone + "  ·  " if not zone.is_empty() else "") + hints[mode] + suffix


func rebuild_posture_buttons() -> void:
	for child in choices.get_children():
		choices.remove_child(child)
		child.queue_free()
	for action: Dictionary in data.postures:
		if action.type == "standing" and speaking.get("posture", {}).get("kind", "standing") == "standing":
			continue
		var button := Button.new()
		button.text = action.label
		if action.type == "skirt":
			if speaking.get("posture", {}).get("kind") == "skirt":
				button.text = "Lower Skirt"
			else:
				button.disabled = skirt_bones(actor_for(speaking)).is_empty()
				button.tooltip_text = "This outfit needs a rigged hem."
		button.pressed.connect(func():
			if set_posture(speaking, action):
				rebuild_posture_buttons())
		choices.add_child(button)
	var lying: Dictionary = speaking.get("posture", {})
	var current: String = lying.get("kind", "standing")
	if current in ["standing", "behind", "stand_spread", "skirt"]:
		posture_command("Hands Behind Your Back", "behind")
		posture_command("Spread Your Legs", "stand_spread")
	if current == "fours" and lying.get("complete", false):
		scene_command("Lick My Shoes", "shoe")
	if current in ["lie_stomach", "lie_back"] and lying.get("complete", false):
		if staging.seated():
			scene_command("Stand Up", "stop")
		else:
			scene_command("Sit Sideways on Back" if current == "lie_stomach" else "Sit on Abdomen",
				"seat_prone" if current == "lie_stomach" else "seat_supine")
	if lying.get("kind", "") == "lie_back":
		var legs := Button.new()
		legs.text = "Bring Legs Together" if lying.get("spread_target", 0.0) > 0.0 else "Spread Legs"
		legs.disabled = not lying.get("complete", false)
		legs.pressed.connect(func():
			if not lying.get("complete", false):
				return
			var closing: bool = lying.get("spread_target", 0.0) > 0.0
			if not contact.state.is_empty():
				if not closing:
					return
				contact.release()
			lying.spread_target = 0.0 if closing else 1.0
			rebuild_posture_buttons())
		choices.add_child(legs)


func posture_command(label: String, kind: String) -> void:
	var button := Button.new()
	button.text = label
	button.pressed.connect(func():
		if set_posture(speaking, {"type": kind}):
			rebuild_posture_buttons())
	choices.add_child(button)


func scene_command(label: String, kind: String) -> void:
	var button := Button.new()
	button.text = label
	button.pressed.connect(func():
		if kind == "stop":
			staging.leave_seat()
		else:
			staging.begin(speaking, kind)
		rebuild_posture_buttons())
	choices.add_child(button)


func set_posture(entry: Dictionary, command: Dictionary, from_contact := false) -> bool:
	if green.active() and entry == speaking and not from_contact:
		var positions_by_command := {"standing": 0, "turn": 11, "lie_back": 1, "fours": 2,
			"lie_stomach": 2, "skirt": 12, "behind": 13, "kneel": 14}
		if positions_by_command.has(command.type):
			green.select_position(positions_by_command[command.type])
			return true
		return false
	if staging.smooth_approach() or (not from_contact and not contact.state.is_empty()) or entry.is_empty():
		return false
	var actor := actor_for(entry)
	var animator := animator_for(entry)
	var rig: Skeleton3D = actor.get_node("Skeleton")
	var kind: String = command.type
	staging.stop()
	entry.face_speaker = false
	if kind == "turn":
		entry.turn = {"start": actor.rotation.y, "time": 0.0}
		var current: Dictionary = entry.get("posture", {})
		if current.is_empty() or (current.get("complete", false) and current.kind == "skirt"):
			entry.turn.pose = Pose.capture(rig)
			entry.turn.resume = animator.is_playing()
			entry.turn.feet = {}
			for side in ["L", "R"]:
				var foot := rig.find_bone("cf_j_foot_" + side)
				if foot >= 0:
					entry.turn.feet[side] = rig.to_global(rig.get_bone_global_pose(foot).origin)
			animator.pause()
		entry.facing_locked = true
		return true
	var prior: Dictionary = entry.get("posture", {})
	if kind == "skirt" and prior.get("kind") == "skirt":
		kind = "standing"
	if prior.get("kind") == kind:
		return true
	var base := Pose.rest(rig)
	var neutral := idle_pose(animator, rig, base)
	var finish := neutral.duplicate()
	var hems: Array[int] = []
	var grips := {}
	var movement: Animation
	var end_at := 0.0
	var movement_base := base
	var lower_pose := kind in ["lie_back", "lie_stomach"]
	var fall_back: bool = kind == "lie_back" and command.get("fall", false)
	if kind in ["kneel", "fours"] or lower_pose:
		var group := "fall_back" if fall_back else kind
		var clips: Array = animation_groups.get(group, [])
		if clips.is_empty():
			return false
		var clip: Dictionary = clips[0]
		var configured := clips.find_custom(func(candidate: Dictionary): return candidate.has("pose_at"))
		if configured >= 0:
			clip = clips[configured]
		movement = Card.animation(room.motion_path(clip.id), rig)
		if not movement:
			answer.text = "That pose is unavailable for this character."
			return false
		movement.loop_mode = Animation.LOOP_NONE
		end_at = minf(movement.length, float(clip.get("pose_at", clip.get("end_at", movement.length))))
		if kind == "kneel":
			use_kneeling_legs(movement, rig)
			movement_base = neutral
		finish = Pose.sample(movement, rig, movement_base, end_at)
		if fall_back:
			dampen_fall_travel(rig, finish)
		if kind == "lie_back":
			finish = relaxed_supine(rig, finish)
		if kind == "fours":
			# Remove locomotion drift from this imported crawl frame.
			var hips := rig.find_bone("cf_j_hips")
			if hips >= 0:
				var settled: Transform3D = finish[hips]
				settled.origin.x = neutral[hips].origin.x
				settled.origin.z = neutral[hips].origin.z
				finish[hips] = settled
			finish = support_on_palms(rig, finish, neutral)
	elif kind == "skirt":
		hems = skirt_bones(actor)
		if hems.is_empty():
			return false
		grips = skirt_grip_vertices(actor, rig, hems)
	elif kind in ["behind", "stand_spread"]:
		finish = standing_variant(rig, finish, kind)
	animator.pause()
	entry.animator = animator
	entry.posture = {
		"kind": kind, "rig": rig, "elapsed": 0.0, "start": Pose.capture(rig), "final": finish,
		"hems": hems, "grips": grips, "motion": movement if (kind == "kneel" and prior.is_empty()) or fall_back else null,
		"motion_base": movement_base, "end_at": end_at, "complete": false,
		"fall": fall_back, "start_at": 0.88 if fall_back and prior.get("kind") in ["kneel", "fours"] else 0.0,
		"duration": 0.87 if lower_pose else 0.0,
		"prior": prior if kind == "standing" else {},
	}
	if kind == "lie_back" and not fall_back:
		entry.posture.duration = 1.36
		entry.posture.seated = supine_seated_pose(rig, finish)
	elif kind == "standing" and prior.get("kind", "") == "lie_back":
		entry.posture.duration = 1.58
		entry.posture.seated = supine_seated_pose(rig, prior.final)
	answer.text = command.get("reply", "Okay.")
	return true


func standing_variant(rig: Skeleton3D, base: Array[Transform3D], kind: String) -> Array[Transform3D]:
	var original := Pose.capture(rig)
	Pose.blend(rig, base, base, 1.0)
	var hips := rig.find_bone("cf_j_hips")
	if hips >= 0:
		var waist := rig.get_bone_global_pose(hips).origin
		for side in ["L", "R"]:
			var x := -1.0 if side == "L" else 1.0
			if kind == "behind":
				var point := waist + Vector3(-x * 0.040, 0.03, 0.18)
				Pose.plant_hand(rig, side, point, Vector3(x * -0.72, -0.52, 0), Vector3.FORWARD,
					1.0, Vector3(x * 0.79, -0.43, 0.49), "palm")
			else:
				var thigh := rig.find_bone("cf_j_thigh00_" + side)
				var knee := rig.find_bone("cf_j_leg01_" + side)
				var foot := rig.find_bone("cf_j_foot_" + side)
				if mini(thigh, mini(knee, foot)) < 0:
					continue
				var heel := rig.get_bone_global_pose(foot).origin
				var sign_x := signf(rig.get_bone_global_pose(thigh).origin.x - waist.x)
				heel.x += sign_x * 0.145
				Pose.reach_chain(rig, thigh, knee, foot, heel, 1.0, Vector3(sign_x * 0.28, 0, -1))
	var result := Pose.capture(rig)
	Pose.blend(rig, original, original, 1.0)
	return result


func relaxed_supine(rig: Skeleton3D, pose: Array[Transform3D]) -> Array[Transform3D]:
	var original := Pose.capture(rig)
	Pose.blend(rig, pose, pose, 1.0)
	var spine := rig.find_bone("cf_j_spine03")
	var hips := rig.find_bone("cf_j_hips")
	if mini(spine, hips) < 0:
		Pose.blend(rig, original, original, 1.0)
		return pose
	var floor_y := rig_floor_height(rig)
	var root := hips
	while rig.get_bone_parent(root) >= 0:
		root = rig.get_bone_parent(root)
	var pelvis_height := rig.get_bone_global_pose(hips).origin.y
	rig.set_bone_pose_position(root, rig.get_bone_pose_position(root) + Vector3.UP * (floor_y + 0.122 - pelvis_height))
	var chest := rig.get_bone_global_pose(spine).origin
	var waist := rig.get_bone_global_pose(hips).origin
	var down_body := (waist - chest).slide(Vector3.UP).normalized()
	if down_body.is_zero_approx():
		down_body = Vector3.BACK
	for side in ["L", "R"]:
		var shoulder := rig.find_bone("cf_j_arm00_" + side)
		if shoulder < 0:
			continue
		var arm := rig.get_bone_global_pose(shoulder).origin
		var lateral := Vector3.RIGHT * signf(arm.x - chest.x)
		var target := arm + down_body * (0.39 if side == "L" else 0.44) + lateral * 0.105
		target.y = floor_y + 0.046
		Pose.plant_hand(rig, side, target, (down_body + lateral * 0.13).normalized(),
			Vector3.UP, 1.0, lateral * 0.61 + Vector3.DOWN * 0.75, "palm")
		var thigh := rig.find_bone("cf_j_thigh00_" + side)
		var knee := rig.find_bone("cf_j_leg01_" + side)
		var foot := rig.find_bone("cf_j_foot_" + side)
		if mini(thigh, mini(knee, foot)) >= 0:
			var heel := rig.get_bone_global_pose(foot).origin
			heel.y = floor_y + 0.061
			Pose.reach_chain(rig, thigh, knee, foot, heel, 1.0, Vector3.UP + lateral * 0.08)
	var result := Pose.capture(rig)
	Pose.blend(rig, original, original, 1.0)
	return result


func rig_floor_height(rig: Skeleton3D) -> float:
	var actor: Node3D = rig.get_parent()
	var body := actor.get_parent() as CollisionObject3D
	var excluded: Array[RID] = [room.player.get_rid()]
	if body:
		excluded.append(body.get_rid())
	var origin := actor.global_position
	var ray := PhysicsRayQueryParameters3D.create(origin + Vector3.UP * 0.38,
		origin - Vector3.UP * 0.68, 1, excluded)
	var hit := room.get_world_3d().direct_space_state.intersect_ray(ray)
	return rig.to_local(hit.position).y if not hit.is_empty() else 0.0


func supine_seated_pose(rig: Skeleton3D, lying: Array[Transform3D]) -> Array[Transform3D]:
	var original := Pose.capture(rig)
	Pose.blend(rig, lying, lying, 1.0)
	var hips := rig.find_bone("cf_j_hips")
	var lower := rig.find_bone("cf_j_spine01")
	var upper := rig.find_bone("cf_j_spine03")
	var floor_y := rig_floor_height(rig)
	if mini(hips, mini(lower, upper)) >= 0:
		var waist := rig.get_bone_global_pose(hips).origin
		var chest := rig.get_bone_global_pose(upper).origin
		var back := (chest - waist).slide(Vector3.UP).normalized()
		Pose.aim(rig, hips, lower, waist + Vector3.UP * 0.38 + back * 0.20, 0.82)
		Pose.aim(rig, lower, upper, waist + Vector3.UP * 0.43 + back * 0.24, 0.82)
		for side in ["L", "R"]:
			var thigh := rig.find_bone("cf_j_thigh00_" + side)
			var knee := rig.find_bone("cf_j_leg01_" + side)
			var foot := rig.find_bone("cf_j_foot_" + side)
			var shoulder := rig.find_bone("cf_j_arm00_" + side)
			if mini(thigh, mini(knee, mini(foot, shoulder))) < 0:
				continue
			var base := rig.get_bone_global_pose(thigh).origin
			var lateral := Vector3.RIGHT * signf(base.x - waist.x)
			var heel := base - back * 0.40 + lateral * 0.09
			heel.y = floor_y + 0.065
			Pose.reach_chain(rig, thigh, knee, foot, heel, 1.0, Vector3.UP)
			var hand := waist + back * 0.22 + lateral * 0.26
			hand.y = floor_y + 0.046
			Pose.plant_hand(rig, side, hand, -back, Vector3.DOWN, 1.0, lateral + back, "palm")
	var result := Pose.capture(rig)
	Pose.blend(rig, original, original, 1.0)
	return result


func dampen_fall_travel(rig: Skeleton3D, pose: Array[Transform3D]) -> void:
	var hips := rig.find_bone("cf_j_hips")
	if hips < 0:
		return
	var transform := pose[hips]
	var neutral := rig.get_bone_rest(hips).origin
	transform.origin.x = lerpf(neutral.x, transform.origin.x, 0.42)
	transform.origin.z = lerpf(neutral.z, transform.origin.z, 0.42)
	pose[hips] = transform


func support_on_palms(rig: Skeleton3D, pose: Array[Transform3D], neutral: Array[Transform3D]) -> Array[Transform3D]:
	var before := Pose.capture(rig)
	Pose.blend(rig, pose, pose, 1.0)
	var waist := rig.find_bone("cf_j_spine01")
	var chest := rig.find_bone("cf_j_spine03")
	if mini(waist, chest) >= 0:
		var upper := rig.get_bone_global_pose(chest).origin
		Pose.aim(rig, waist, chest, upper + Vector3.UP * 0.10)
	for side in ["L", "R"]:
		var sign_x := -1.0 if side == "L" else 1.0
		var shoulder := rig.find_bone("cf_j_arm00_" + side)
		var hand := rig.find_bone("cf_j_hand_" + side)
		var finger := rig.find_bone("cf_j_middle02_" + side)
		if mini(shoulder, mini(hand, finger)) < 0:
			continue
		var wrist := rig.get_bone_global_pose(shoulder).origin + Vector3(sign_x * 0.03, 0, -0.13)
		wrist.y = 0.052
		Pose.reach(rig, side, wrist, 1.0, Vector3(sign_x * 0.34, 0.1, 0.75))
		for digit in ["thumb", "index", "middle", "ring", "little"]:
			for segment in [1, 2, 3]:
				var bone := rig.find_bone("cf_j_%s0%d_%s" % [digit, segment, side])
				if bone >= 0:
					rig.set_bone_pose(bone, neutral[bone])
		Pose.aim(rig, hand, finger, wrist + Vector3(0, -0.018, -0.081))
	var result := Pose.capture(rig)
	Pose.blend(rig, before, before, 1.0)
	return result


func tick_posture(entry: Dictionary, actor: Node3D, delta: float) -> void:
	if entry.has("turn"):
		entry.turn.time += delta
		actor.rotation.y = float(entry.turn.start) + PI * Pose.smooth(float(entry.turn.time) / 0.96)
		if entry.turn.has("pose"):
			step_turn(actor, entry.turn)
			if entry.turn.time >= 0.96 and entry.turn.resume:
				animator_for(entry).play()
			if entry.turn.time >= 0.96:
				entry.erase("turn")
			return
		if entry.turn.time >= 0.96:
			entry.erase("turn")
	if not entry.has("posture"):
		return
	var pose: Dictionary = entry.posture
	var rig: Skeleton3D = pose.rig
	pose.elapsed += delta
	var time: float = pose.elapsed
	if pose.complete:
		Pose.blend(rig, pose.held, pose.held, 1.0)
		if pose.kind == "lie_back" and pose.has("spread_target"):
			if contact.state.is_empty() or float(pose.spread_target) > 0.0:
				pose.spread = move_toward(float(pose.get("spread", 0.0)), float(pose.spread_target), delta * 1.9)
			spread_supine_legs(rig, Pose.smooth(pose.spread))
		return
	if pose.motion:
		var sample_time := minf(pose.end_at, float(pose.start_at) + maxf(0.0, time - ENTER_TIME))
		var authored: Array[Transform3D] = Pose.sample(pose.motion, rig, pose.motion_base, sample_time)
		if pose.fall:
			dampen_fall_travel(rig, authored)
		Pose.blend(rig, pose.start, authored, Pose.smooth(time / ENTER_TIME))
		if pose.kind == "kneel":
			steady_knee_hands(rig, Pose.smooth((time - 0.48) / 0.55) * Pose.smooth((pose.end_at + ENTER_TIME - time) / 0.55))
		if pose.fall and sample_time >= pose.end_at:
			var landing := Pose.capture(rig)
			var settle := Pose.smooth((time - pose.end_at + pose.start_at - ENTER_TIME) / 0.28)
			Pose.blend(rig, landing, pose.final, settle)
			if settle < 1.0:
				return
		elif sample_time < pose.end_at or time < ENTER_TIME:
			return
	elif pose.prior.get("kind") == "kneel" and pose.prior.motion:
		var previous: Dictionary = pose.prior
		var inverse := (1.0 - Pose.smooth(time / 1.7)) * float(previous.end_at)
		if time < 1.7:
			var authored: Array[Transform3D] = Pose.sample(previous.motion, rig, previous.motion_base, inverse)
			Pose.blend(rig, authored, authored, 1.0)
			steady_knee_hands(rig, Pose.smooth(time / 0.26) * Pose.smooth((1.42 - time) / 0.58))
			return
		var last: Array[Transform3D] = Pose.sample(previous.motion, rig, previous.motion_base, 0.0)
		Pose.blend(rig, last, pose.final, Pose.smooth((time - 1.7) / 0.42))
		if time < 2.12:
			return
	elif pose.prior.get("kind") == "skirt" and pose.prior.complete:
		Pose.blend(rig, pose.final, pose.final, 1.0)
		play_skirt(rig, pose.prior.hems, 1.18 + minf(1.62, time), pose.prior.grips)
		if time < 1.62:
			return
	else:
		var fade: float = pose.duration if pose.duration > 0.0 else (0.82 if pose.kind in ["fours", "standing"] else ENTER_TIME)
		if pose.has("seated"):
			var split := fade * (0.56 if pose.kind == "lie_back" else 0.47)
			if time < split:
				Pose.blend(rig, pose.start, pose.seated, Pose.smooth(time / split))
			else:
				Pose.blend(rig, pose.seated, pose.final, Pose.smooth((time - split) / (fade - split)))
		else:
			Pose.blend(rig, pose.start, pose.final, Pose.smooth(time / fade))
		if pose.kind == "fours" or pose.kind == "lie_stomach":
			var start := 0.29 if pose.kind == "fours" else 0.46
			settle_floor_hands(rig, pose.final, Pose.smooth((time / fade - start) / (1.0 - start)))
		if pose.kind == "skirt":
			play_skirt(rig, pose.hems, minf(time, 1.18), pose.grips)
			if time < 1.18:
				return
		elif time < fade:
			return
	if pose.kind == "standing":
		entry.erase("posture")
		play_rest(animator_for(entry))
		if dialogue.visible and speaking == entry:
			rebuild_posture_buttons()
	else:
		pose.held = Pose.capture(rig)
		pose.complete = true
		if pose.kind in ["lie_back", "lie_stomach", "fours"] and dialogue.visible and speaking == entry:
			rebuild_posture_buttons()


func spread_supine_legs(rig: Skeleton3D, weight: float) -> void:
	if weight <= 0.0:
		return
	var pelvis := rig.find_bone("cf_j_hips")
	if pelvis < 0:
		return
	var center := rig.get_bone_global_pose(pelvis).origin
	for side in ["L", "R"]:
		var thigh := rig.find_bone("cf_j_thigh00_" + side)
		var knee := rig.find_bone("cf_j_leg01_" + side)
		var foot := rig.find_bone("cf_j_foot_" + side)
		if mini(thigh, mini(knee, foot)) < 0:
			continue
		var leg := rig.get_bone_global_pose(thigh).origin
		var heel := rig.get_bone_global_pose(foot).origin
		var side_x := signf(leg.x - center.x)
		var lateral := Vector3.RIGHT * side_x
		var target := heel
		target.x = center.x + side_x * (0.24 + absf(leg.x - center.x))
		Pose.reach_chain(rig, thigh, knee, foot, heel.lerp(target, weight), weight, Vector3.UP + lateral * 0.48)


func step_turn(actor: Node3D, turn: Dictionary) -> void:
	var rig: Skeleton3D = actor.get_node("Skeleton")
	Pose.blend(rig, turn.pose, turn.pose, 1.0)
	var pivot := actor.global_position
	for side: String in turn.feet:
		var origin: Vector3 = turn.feet[side]
		var time: float = turn.time
		var phase := clampf(time / 0.31, 0.0, 1.0)
		var angle := 0.0
		if side == "L":
			var last := clampf((time - 0.65) / 0.31, 0.0, 1.0)
			angle = PI * (0.47 * Pose.smooth(phase) + 0.53 * Pose.smooth(last))
			phase = last if time >= 0.65 else phase
		else:
			phase = clampf((time - 0.31) / 0.34, 0.0, 1.0)
			angle = PI * Pose.smooth(phase)
		var point := pivot + (origin - pivot).rotated(Vector3.UP, angle)
		point.y += sin(phase * PI) * 0.052
		var upper := rig.find_bone("cf_j_thigh00_" + side)
		var knee := rig.find_bone("cf_j_leg01_" + side)
		var foot := rig.find_bone("cf_j_foot_" + side)
		Pose.reach_chain(rig, upper, knee, foot, rig.to_local(point), 1.0, Vector3.FORWARD)


func steady_knee_hands(rig: Skeleton3D, weight: float) -> void:
	if weight <= 0.0:
		return
	for side in ["L", "R"]:
		var knee := rig.find_bone("cf_j_leg01_" + side)
		if knee >= 0:
			var sign_x := -1.0 if side == "L" else 1.0
			var point := rig.get_bone_global_pose(knee).origin + Vector3(sign_x * 0.028, 0.12, 0.012)
			Pose.plant_hand(rig, side, point, Vector3.FORWARD, Vector3.DOWN, weight * 0.55,
				Vector3(sign_x * 0.78, -0.20, 0.42), "palm")


func settle_floor_hands(rig: Skeleton3D, final: Array[Transform3D], weight: float) -> void:
	if weight <= 0.0 or weight >= 1.0:
		return
	for side in ["L", "R"]:
		var hand := rig.find_bone("cf_j_hand_" + side)
		var upper := rig.find_bone("cf_j_arm00_" + side)
		if mini(hand, upper) < 0:
			continue
		var absolute := final[hand]
		var parent := rig.get_bone_parent(hand)
		while parent >= 0:
			absolute = final[parent] * absolute
			parent = rig.get_bone_parent(parent)
		var goal := rig.get_bone_global_pose(hand).origin.lerp(absolute.origin, weight)
		var outward := -1.0 if side == "L" else 1.0
		Pose.reach(rig, side, goal, weight, Vector3(outward * 0.5, 0.2, 0.6))


func interaction_view() -> Dictionary:
	if not dialogue.visible or speaking.is_empty():
		return {}
	if green.active():
		return green.camera_view()
	var stage_camera := staging.camera_view()
	if not stage_camera.is_empty():
		return stage_camera
	var actor := actor_for(speaking)
	if not actor:
		return {}
	var rig: Skeleton3D = actor.get_node("Skeleton")
	var hips := rig.find_bone("cf_j_hips")
	var head := slap_head_bone(rig)
	var a := rig.to_global(rig.get_bone_global_pose(hips).origin) if hips >= 0 else actor.global_position + Vector3.UP
	var b := rig.to_global(rig.get_bone_global_pose(head).origin) if head >= 0 else a + Vector3.UP * 0.4
	var focus := a.lerp(b, 0.34)
	if contact.state.get("rear_action", "") == "embrace":
		var angle: Vector3 = -actor.global_basis.z.normalized()
		var eye_point := b + angle * 1.03 + actor.global_basis.x.normalized() * 0.34 + Vector3.UP * 0.11
		var target := b.lerp(a, 0.37)
		var ray := PhysicsRayQueryParameters3D.create(target, eye_point, 1, [body_for(speaking).get_rid()])
		var hit := room.get_world_3d().direct_space_state.intersect_ray(ray)
		if not hit.is_empty():
			eye_point = hit.position.move_toward(target, 0.10)
		return {"eye": eye_point, "focus": target + Vector3.UP * look_height}
	var player: Node3D = room.player_model
	var eye: Vector3 = player.global_position + Vector3.UP * (1.50 * player.global_basis.y.length())
	var stance: float = contact.state.get("camera_crouch", 0.0)
	eye.y -= stance * 0.51
	eye.y += float(contact.state.get("camera_rise", 0.0))
	var gesture := contact.camera_target()
	if not gesture.is_empty():
		var weight: float = gesture.weight
		var direction := eye.direction_to(gesture.point)
		var low: bool = contact.state.get("low_reach", false)
		var active_kick: bool = contact.state.has("kick")
		var waist_contact: bool = contact.state.get("id", "") == "lap"
		var hands: Dictionary = contact.state.get("hand_weights", {})
		var bias := (float(hands.get("L", 0.0)) - float(hands.get("R", 0.0))) * 0.065
		eye += player.global_basis.x.normalized() * bias
		eye -= direction * weight * (0.17 if low else 0.045)
		if contact.state.get("planted_crouch", false):
			eye += -player.global_basis.z.normalized() * weight * 0.23
		focus = focus.lerp(gesture.point, weight * (0.83 if low or active_kick else 0.56))
		if waist_contact:
			eye -= Vector3.UP * weight * 0.10 + direction * weight * 0.06
		if low:
			focus -= direction * (0.10 * weight)
	focus.y += look_height
	return {"eye": eye, "focus": focus}


func perform(entry: Dictionary, action: Dictionary) -> bool:
	answer.text = action.get("reply", "Okay.")
	var kind: String = action.get("type", "clip")
	if kind == "follow":
		entry.follows = not entry.follows
		answer.text = "Okay, I will follow you." if entry.follows else "I will stay here."
		return true
	if kind == "turn":
		# After a full turn the NPC faces away — spank becomes possible from the front.
		entry.was_turned = true
	var actor := actor_for(entry)
	var animator := animator_for(entry)
	if not actor or not animator:
		return false
	if not hug_owner.is_empty():
		answer.text = "One moment."
		return false
	var skeleton: Skeleton3D = animator.get_node("../Skeleton")
	var animation: Animation
	var speed := 1.0
	var end_at := INF
	if kind in ["clip", "kneel"]:
		var options: Array = action.get("groups", [])
		var group: Array = animation_groups.get(options.pick_random(), []) if not options.is_empty() else []
		var candidates := group.filter(func(clip: Dictionary): return clip.get("dialogue", true))
		if not candidates.is_empty():
			var clip: Dictionary = candidates.pick_random()
			animation = Card.animation(room.motion_path(clip.id), skeleton)
			speed = maxf(0.1, float(clip.get("speed", 1.0)))
			end_at = float(clip.get("end_at", INF))
		if not animation:
			answer.text = "The clip is unavailable."
			return false
		animation.loop_mode = Animation.LOOP_NONE
	var hems: Array[int] = []
	if kind == "skirt":
		if entry.get("skirt_up", false):
			# The skirt is being held up — lower it back down.
			entry.skirt_up = false
			finish_action(entry)
			answer.text = "Skirt lowered."
			return true
		hems = skirt_bones(actor)
		if hems.is_empty():
			answer.text = "This outfit needs a rigged hem."
			return false
		entry.skirt_up = true
	if kind == "mouth" and skeleton.find_bone("cf_J_MouthLow") < 0:
		answer.text = "This model is missing the mouth joint."
		return false
	var strike_kinds := ["slap", "spank", "thigh", "chest", "face_punch", "stomach_punch"]
	if kind in strike_kinds or kind in TOUCH_TARGETS:
		var player_skeleton: Skeleton3D = room.player_model.get_node("Skeleton")
		if not prepare_strike(entry, actor, skeleton, kind, player_skeleton, answer):
			return false
	ensure_locomotion(animator)
	var base := Pose.rest(skeleton)
	var state := {
		"kind": kind, "elapsed": 0.0, "start": Pose.capture(skeleton), "base": base,
		"idle": idle_pose(animator, skeleton, base), "yaw": actor.rotation.y, "skeleton": skeleton,
		"hems": hems, "animation": animation, "speed": speed, "approach_yaw": actor.rotation.y
	}
	if not slap_state.is_empty():
		state.merge(slap_state)
		slap_state = {}
	if entry.get("face_speaker", false) and kind not in ["hug", "turn"]:
		var offset: Vector3 = room.player.global_position - actor.global_position
		if Vector2(offset.x, offset.z).length_squared() > 0.01:
			state.face_yaw = atan2(-offset.x, -offset.z)
	entry.face_speaker = false
	if animation:
		if kind == "kneel":
			use_kneeling_legs(animation, skeleton)
			state.base = state.idle
		state.duration = clampf(minf(animation.length, end_at) / speed, 0.4, 8.0)
		state.last = Pose.sample(animation, skeleton, state.base, state.duration * speed)
	if kind == "hug":
		ensure_locomotion(room.player_anim)
		state.walk = animator.get_animation("Walk")
	animator.pause()
	entry.animator = animator
	entry.action = state
	return true


func use_kneeling_legs(animation: Animation, skeleton: Skeleton3D) -> void:
	# Preserve the authored hips and legs while the head and arms stay relaxed.
	var chest := skeleton.find_bone("cf_j_spine01")
	if chest < 0:
		return
	for track in range(animation.get_track_count() - 1, -1, -1):
		var bone := skeleton.find_bone(animation.track_get_path(track).get_subname(0))
		while bone >= 0 and bone != chest:
			bone = skeleton.get_bone_parent(bone)
		if bone == chest:
			animation.remove_track(track)


func adjust_kneel(skeleton: Skeleton3D, weight: float, time: float) -> void:
	# Softer kneeling posture: straighter spine, calm breathing sway, head lifted a touch.
	if weight <= 0.0:
		return
	var breathe := 0.5 + 0.5 * sin(time * 1.6)
	var names := ["cf_j_spine01", "cf_j_spine02", "cf_j_neck"]
	for bone_name in names:
		var bone := skeleton.find_bone(bone_name)
		if bone < 0:
			continue
		var pose := skeleton.get_bone_pose(bone)
		var lift := Basis(Vector3.RIGHT, -0.06 * weight) if bone_name != "cf_j_neck" else Basis(Vector3.RIGHT, -0.10 * weight)
		var sway := Basis(Vector3.FORWARD, 0.02 * weight * breathe)
		pose.basis = lift * sway * pose.basis
		skeleton.set_bone_pose(bone, pose)


func finish_action(entry: Dictionary) -> void:
	var state: Dictionary = entry.get("action", {})
	if state.is_empty():
		return
	if state.has("player_skeleton"):
		# Restore the player skeleton and resume its idle clip.
		var player_skeleton: Skeleton3D = state.player_skeleton
		var player_start: Array[Transform3D] = state.player_start
		Pose.blend(player_skeleton, player_start, player_start, 1.0)
		room.player_anim.play("Idle", 0.25)
		if state.has("player_yaw"):
			room.player_model.rotation.y = state.player_yaw
	if hug_owner == entry:
		hug_owner = {}
		var contact_body: CharacterBody3D = state.contact_body
		if is_instance_valid(contact_body):
			room.player.remove_collision_exception_with(contact_body)
		var partner: AnimationPlayer = state.partner
		if is_instance_valid(partner) and partner == room.player_anim:
			play_rest(partner)
	entry.erase("action")
	var animator := animator_for(entry)
	if animator and animator == entry.animator:
		play_rest(animator)


func play_rest(animator: AnimationPlayer) -> void:
	if animator.has_animation("ConversationIdle"):
		animator.play("ConversationIdle")
		animator.seek(0.0, true)
		animator.pause()
	else:
		animator.play("Idle", 0.25)


func play_action(entry: Dictionary, actor: Node3D, body: CharacterBody3D, delta: float) -> void:
	var state: Dictionary = entry.action
	var skeleton: Skeleton3D = state.skeleton
	state.elapsed += delta
	var time: float = state.elapsed
	if state.has("face_yaw") and time < ENTER_TIME + delta:
		actor.rotation.y = lerp_angle(state.yaw, state.face_yaw, Pose.smooth(time / ENTER_TIME))
	if state.animation:
		var kneeling: bool = state.kind == "kneel"
		var end: float = ENTER_TIME + state.duration + (0.65 if kneeling else 0.12)
		var rise := 0.0
		if kneeling:
			rise = clampf(state.duration * 0.85, 0.85, 1.85)
		if time < end:
			var sample_time := maxf(0., time - ENTER_TIME) * float(state.speed)
			var pose: Array[Transform3D] = state.last
			if time < ENTER_TIME + state.duration:
				pose = Pose.sample(state.animation, skeleton, state.base, sample_time)
			Pose.blend(skeleton, state.start, pose, Pose.smooth(time / ENTER_TIME))
			if kneeling:
				# Softer kneel: straighter back, gentle sway, head slightly up.
				adjust_kneel(skeleton, Pose.smooth(time / ENTER_TIME), time)
		elif time < end + rise:
			var from_end := 1.0 - Pose.smooth((time - end) / rise)
			var pose := Pose.sample(state.animation, skeleton, state.base, state.duration * state.speed * from_end)
			Pose.blend(skeleton, pose, pose, 1.0)
		else:
			var origin: Array[Transform3D] = state.last
			if kneeling:
				origin = Pose.sample(state.animation, skeleton, state.base, 0.0)
			Pose.blend(skeleton, origin, state.idle, Pose.smooth((time - end - rise) / EXIT_TIME))
			if time >= end + rise + EXIT_TIME:
				finish_action(entry)
		return
	if state.kind == "hug":
		play_hug(entry, actor, body, delta)
		return
	Pose.blend(skeleton, state.start, state.idle, Pose.smooth(time / ENTER_TIME))
	var strike_kinds := ["slap", "spank", "thigh", "chest", "face_punch", "stomach_punch"]
	Pose.blend(skeleton, state.start, state.idle, Pose.smooth(time / ENTER_TIME))
	var limit := 1.72
	if state.kind in strike_kinds:
		limit = 2.15 if int(state.get("slap_variant", 0)) == 1 else 1.55
		if state.kind in ["face_punch", "stomach_punch"]:
			limit += 0.9
	elif state.kind in TOUCH_TARGETS:
		limit = float(TOUCH_TARGETS[state.kind]["dur"]) + 0.25
	match state.kind:
		"turn":
			actor.rotation.y = state.yaw + PI * Pose.smooth((time - 0.14) / 0.92)
		"mouth":
			var jaw := skeleton.find_bone("cf_J_MouthLow")
			var weight := Pose.smooth((time - 0.22) / 0.30) * Pose.smooth((1.68 - time) / 0.42)
			skeleton.set_bone_pose_position(jaw, skeleton.get_bone_pose_position(jaw) + Vector3.DOWN * 0.017 * weight)
		"skirt":
			if entry.get("skirt_up", false):
				# Held skirt: freeze the lift pose until the player lowers it.
				play_skirt(skeleton, state.hems, 1.18)
			else:
				play_skirt(skeleton, state.hems, time)
		_:
			if state.kind in strike_kinds:
				play_strike(entry, actor, skeleton, state, time)
			elif state.kind in TOUCH_TARGETS:
				play_touch(entry, actor, skeleton, state, time)
	if state.kind == "skirt" and entry.get("skirt_up", false):
		return  # Held skirt stays up until the player lowers it.
	if time >= (2.85 if state.kind == "skirt" else limit):
		finish_action(entry)


func play_strike(entry: Dictionary, actor: Node3D, skeleton: Skeleton3D, state: Dictionary, time: float) -> void:
	if state.kind == "slap":
		play_slap(entry, actor, skeleton, state, time)
	else:
		play_targeted_strike(entry, actor, skeleton, state, time)


# Gentle interactions: a point on the NPC body and how long the contact holds.
const TOUCH_TARGETS := {
	"hand_hold": {"height": 0.98, "reach": 0.30, "dur": 2.6},
	"face_grab": {"height": 1.50, "reach": 0.15, "dur": 2.1},
	"chin_lift": {"height": 1.49, "reach": 0.12, "dur": 2.2},
	"finger_suck": {"height": 1.40, "reach": 0.10, "dur": 2.6},
	"head_pat": {"height": 1.70, "reach": 0.05, "dur": 2.5},
	"hair_grab": {"height": 1.64, "reach": 0.03, "dur": 1.9},
	"kiss_forehead": {"height": 1.64, "reach": 0.0, "dur": 2.3},
	"cheek_pinch": {"height": 1.46, "reach": 0.14, "dur": 1.8},
}


func play_touch(entry: Dictionary, actor: Node3D, skeleton: Skeleton3D, state: Dictionary, time: float) -> void:
	var kind: String = state.get("strike_kind", "head_pat")
	var conf: Dictionary = TOUCH_TARGETS.get(kind, TOUCH_TARGETS["head_pat"])
	var dur := float(conf["dur"])
	var player_skeleton: Skeleton3D = state.player_skeleton
	var player_start: Array[Transform3D] = state.player_start
	var side: String = "L" if int(state.get("slap_variant", 0)) == 2 else "R"
	var hand := player_skeleton.find_bone("cf_j_hand_" + side)
	var player_head := player_skeleton.find_bone("cf_j_head")
	var npc_hips := skeleton.find_bone("cf_j_hips")
	var head := int(state.get("head_bone", -1))
	if head < 0:
		head = slap_head_bone(skeleton)
	# Per-frame reset so phases compose cleanly.
	Pose.blend(player_skeleton, player_start, player_start, 1.0)
	var to_npc: Vector3 = actor.global_position - room.player.global_position
	to_npc.y = 0.0
	if to_npc.length_squared() > 0.0001:
		var face: float = atan2(-to_npc.x, -to_npc.z)
		if not state.has("player_yaw"):
			state.player_yaw = room.player_model.rotation.y
		var turn := Pose.smooth((time - 0.04) / 0.30) * Pose.smooth((dur - 0.35 - time) / 0.45)
		room.player_model.rotation.y = lerp_angle(state.player_yaw, face, turn)
	var fwd: Vector3 = to_npc.normalized() if to_npc.length_squared() > 0.0001 else -room.player_model.global_transform.basis.z
	fwd.y = 0.0
	fwd = fwd.normalized()
	var right: Vector3 = fwd.cross(Vector3.UP).normalized()
	if right.length_squared() < 0.5:
		right = Vector3.RIGHT.rotated(Vector3.UP, room.player_model.rotation.y)
	var lateral: Vector3 = right * (-1.0 if side == "L" else 1.0)
	var own_head: Vector3 = room.player.global_position + Vector3.UP * 1.55
	if player_head >= 0:
		own_head = player_skeleton.to_global(player_skeleton.get_bone_global_pose(player_head).origin)
	var rest_hand: Vector3 = own_head
	if hand >= 0:
		rest_hand = player_skeleton.to_global(player_skeleton.get_bone_global_pose(hand).origin)
	var npc_base: Vector3 = actor.global_position
	if npc_hips >= 0:
		npc_base = skeleton.to_global(skeleton.get_bone_global_pose(npc_hips).origin) - Vector3.UP * 0.9
	var target: Vector3 = npc_base + Vector3.UP * float(conf["height"])
	var toward_player: Vector3 = room.player.global_position - actor.global_position
	toward_player.y = 0.0
	if toward_player.length_squared() > 0.0001:
		target += toward_player.normalized() * float(conf["reach"])
	# Smooth approach, a held contact, then a smooth release.
	var hold := Pose.smooth((time - 0.06) / 0.44) * Pose.smooth((dur - 0.55 - time) / 0.50)
	if kind == "head_pat":
		# Circular stroking motion over the top of the head.
		var circle := time * 5.2
		target += right * 0.055 * sin(circle) * hold + fwd * 0.03 * cos(circle) * hold
	elif kind == "cheek_pinch":
		target += lateral * 0.10
	elif kind == "face_grab":
		target += lateral * 0.06
	if kind == "kiss_forehead":
		# The player leans in with both hands on the NPC's shoulders.
		for anchor in ["L", "R"]:
			var sign_x := -1.0 if anchor == "L" else 1.0
			var shoulder: Vector3 = npc_base + Vector3.UP * 1.42 + right * sign_x * 0.19 + fwd * 0.10
			Pose.reach(player_skeleton, anchor, player_skeleton.to_local(shoulder), hold)
		var spine := player_skeleton.find_bone("cf_j_spine01")
		var chest := player_skeleton.find_bone("cf_j_spine03")
		if spine >= 0 and chest >= 0:
			Pose.aim(player_skeleton, spine, chest, target + fwd * 0.30, hold * 0.7)
	elif hand >= 0:
		var target_pos: Vector3 = rest_hand.lerp(target, hold)
		Pose.reach(player_skeleton, side, player_skeleton.to_local(target_pos), hold)
	touch_npc(skeleton, kind, hold, time, state, fwd, lateral, target)


func touch_npc(skeleton: Skeleton3D, kind: String, weight: float, time: float, state: Dictionary, fwd: Vector3, lateral: Vector3, target: Vector3) -> void:
	if weight <= 0.0:
		return
	var head := int(state.get("head_bone", -1))
	if head < 0:
		head = slap_head_bone(skeleton)
	var side: String = "L" if int(state.get("slap_variant", 0)) == 2 else "R"
	match kind:
		"hand_hold":
			# The NPC's mirroring hand meets the player's hand for a mutual hold.
			var npc_side := "R" if side == "L" else "L"
			Pose.reach(skeleton, npc_side, skeleton.to_local(target), weight)
			if head >= 0:
				var pose := skeleton.get_bone_pose(head)
				pose.basis = pose.basis * Basis(Vector3.RIGHT, -0.08 * weight) * Basis(Vector3.FORWARD, 0.06 * weight)
				skeleton.set_bone_pose(head, pose)
		"face_grab":
			if head >= 0:
				var pose := skeleton.get_bone_pose(head)
				pose.basis = pose.basis * Basis(Vector3.RIGHT, -0.10 * weight) * Basis(Vector3.FORWARD, 0.10 * weight)
				pose.origin += Vector3.UP * 0.004 * weight
				skeleton.set_bone_pose(head, pose)
		"chin_lift":
			# The head tips up to face the player, chin resting in the hand.
			if head >= 0:
				var pose := skeleton.get_bone_pose(head)
				pose.basis = pose.basis * Basis(Vector3.RIGHT, -0.42 * weight)
				pose.origin += Vector3.UP * 0.012 * weight
				skeleton.set_bone_pose(head, pose)
			var neck := skeleton.find_bone("cf_j_neck")
			if neck >= 0:
				var pose2 := skeleton.get_bone_pose(neck)
				pose2.basis = pose2.basis * Basis(Vector3.RIGHT, -0.12 * weight)
				skeleton.set_bone_pose(neck, pose2)
		"finger_suck":
			# Lips part around the finger, the head tilts into the hand.
			var jaw := skeleton.find_bone("cf_J_MouthLow")
			if jaw >= 0:
				skeleton.set_bone_pose_position(jaw, skeleton.get_bone_pose_position(jaw) + Vector3.DOWN * 0.020 * weight)
			if head >= 0:
				var tilt := -1.0 if side == "R" else 1.0
				var pose := skeleton.get_bone_pose(head)
				pose.basis = pose.basis * Basis(Vector3.RIGHT, -0.18 * weight) * Basis(Vector3.FORWARD, 0.10 * weight * tilt)
				pose.origin += Vector3.UP * 0.006 * weight
				skeleton.set_bone_pose(head, pose)
		"head_pat":
			# The head leans into the strokes and follows the hand.
			if head >= 0:
				var pose := skeleton.get_bone_pose(head)
				pose.basis = pose.basis * Basis(Vector3.RIGHT, 0.24 * weight)
				pose.origin += Vector3.UP * (-0.008 * weight) + fwd * 0.012 * weight * (0.5 + 0.5 * sin(time * 5.2))
				skeleton.set_bone_pose(head, pose)
		"hair_grab":
			# The head is pulled back by the hair, chin lifted.
			if head >= 0:
				var pose := skeleton.get_bone_pose(head)
				pose.basis = pose.basis * Basis(Vector3.RIGHT, -0.34 * weight) * Basis(Vector3.FORWARD, 0.14 * weight)
				pose.origin += Vector3.UP * 0.018 * weight + fwd * 0.02 * weight
				skeleton.set_bone_pose(head, pose)
		"kiss_forehead":
			# A small tilt back to receive the kiss.
			if head >= 0:
				var pose := skeleton.get_bone_pose(head)
				pose.basis = pose.basis * Basis(Vector3.RIGHT, -0.14 * weight)
				skeleton.set_bone_pose(head, pose)
		"cheek_pinch":
			# The head turns into the pinch with a tiny jiggle.
			if head >= 0:
				var yaw := -1.0 if side == "R" else 1.0
				var pose := skeleton.get_bone_pose(head)
				pose.basis = pose.basis * Basis(Vector3.UP, 0.30 * weight * yaw) * Basis(Vector3.FORWARD, 0.08 * weight)
				pose.origin += lateral * 0.004 * weight * sin(time * 14.0)
				skeleton.set_bone_pose(head, pose)


const STRIKE_BONES := {
	"slap": ["cf_j_head"],
	"spank": ["cf_j_hand_R", "cf_j_pee_R", "cf_d_siri_R"],
	"thigh": ["cf_j_thigh_R"],
	"chest": ["cf_j_arm00_R"],
	"face_punch": ["cf_j_head"],
	"stomach_punch": ["cf_j_spine02", "cf_j_spine01"],
}


func prepare_strike(entry: Dictionary, actor: Node3D, skeleton: Skeleton3D, kind: String, player_skeleton: Skeleton3D, reply: Label) -> bool:
	var head := slap_head_bone(skeleton)
	if kind in ["slap", "face_punch"] and head < 0:
		reply.text = "This model is missing the head joint."
		return false
	# Random version per kind: 0 fast right, 1 slow theatrical right, 2 left.
	var variant := randi() % 3
	if variant == 2 and player_skeleton.find_bone("cf_j_arm00_L") < 0:
		variant = 0
	if variant != 2 and player_skeleton.find_bone("cf_j_arm00_R") < 0:
		reply.text = "The player model is missing the hand joint."
		return false
	# Spank only from behind (or facing away from the player).
	var to_player: Vector3 = room.player.global_position - actor.global_position
	to_player.y = 0.0
	var facing: Vector3 = -actor.global_transform.basis.z
	facing.y = 0.0
	var behind := facing.dot(to_player.normalized()) < -0.15 if to_player.length_squared() > 0.01 else true
	if kind == "spank" and not behind and not entry.get("was_turned", false):
		reply.text = "Approach from behind or ask the NPC to turn around."
		return false
	slap_state = {
		"player_skeleton": player_skeleton,
		"player_start": Pose.capture(player_skeleton),
		"head_bone": head,
		"slap_variant": variant,
		"strike_kind": kind,
	}
	room.player_anim.pause()
	return true


func play_slap(entry: Dictionary, actor: Node3D, skeleton: Skeleton3D, state: Dictionary, time: float) -> void:
	var player_skeleton: Skeleton3D = state.player_skeleton
	var player_start: Array[Transform3D] = state.player_start
	var variant: int = int(state.get("slap_variant", 0))
	var side: String = "L" if variant == 2 else "R"
	var hand := player_skeleton.find_bone("cf_j_hand_" + side)
	var head := int(state.head_bone)
	var player_head := player_skeleton.find_bone("cf_j_head")
	# Per-variant timing: raise phase -> windup hold -> swing -> impact -> recover -> end.
	var raise_dur := 0.36
	var swing_dur := 0.16
	var recover_dur := 0.55
	var end_at := 1.35
	var windup_out := 0.46
	var windup_up := 0.16
	var windup_back := 0.18
	if variant == 1:
		# Slow theatrical slap: long windup, lazy follow-through.
		raise_dur = 0.62
		swing_dur = 0.24
		recover_dur = 0.85
		end_at = 2.0
		windup_out = 0.56
		windup_up = 0.24
		windup_back = 0.26
	var raise_at := 0.06
	var swing_at := raise_at + raise_dur
	var impact := swing_at + swing_dur
	var recover_dur_local := recover_dur
	# Reset the player skeleton to the captured pose each frame so the phases compose cleanly.
	Pose.blend(player_skeleton, player_start, player_start, 1.0)
	# Bone poses live in their skeleton's local space — convert to world.
	var to_npc: Vector3 = actor.global_position - room.player.global_position
	to_npc.y = 0.0
	# Turn the player model toward the NPC while slapping.
	if to_npc.length_squared() > 0.0001:
		var face: float = atan2(-to_npc.x, -to_npc.z)
		if not state.has("player_yaw"):
			state.player_yaw = room.player_model.rotation.y
		var turn := Pose.smooth((time - 0.04) / 0.30) * Pose.smooth((end_at - 0.35 - time) / 0.45)
		room.player_model.rotation.y = lerp_angle(state.player_yaw, face, turn)
	var fwd: Vector3 = to_npc.normalized() if to_npc.length_squared() > 0.0001 else -room.player_model.global_transform.basis.z
	fwd.y = 0.0
	fwd = fwd.normalized()
	var right: Vector3 = fwd.cross(Vector3.UP).normalized()
	if right.length_squared() < 0.5:
		right = Vector3.RIGHT.rotated(Vector3.UP, room.player_model.rotation.y)
	var side_sign := -1.0 if variant == 2 else 1.0
	var lateral: Vector3 = right * side_sign
	# Anchor points for the swing arc.
	var own_head: Vector3 = room.player.global_position + Vector3.UP * 1.55
	if player_head >= 0:
		own_head = player_skeleton.to_global(player_skeleton.get_bone_global_pose(player_head).origin)
	var rest_hand: Vector3 = own_head
	if hand >= 0:
		rest_hand = player_skeleton.to_global(player_skeleton.get_bone_global_pose(hand).origin)
	var npc_head: Vector3 = actor.global_position + Vector3.UP * 1.52
	var toward_player: Vector3 = room.player.global_position - actor.global_position
	toward_player.y = 0.0
	if head >= 0:
		npc_head = skeleton.to_global(skeleton.get_bone_global_pose(head).origin)
	var cheek := npc_head
	if toward_player.length_squared() > 0.0001:
		cheek = npc_head + toward_player.normalized() * 0.045 + Vector3.UP * 0.02
	# Wind up beside the player's own head, then swing across at the NPC's cheek.
	var back: Vector3 = own_head + lateral * windup_out + Vector3.UP * windup_up - fwd * windup_back
	var mid: Vector3 = back.lerp(cheek, 0.5) + fwd * 0.16 + Vector3.UP * 0.04
	if hand >= 0:
		var target: Vector3
		var weight := 0.0
		if time < swing_at:
			# Raise the hand into the windup position.
			var raise_t := Pose.smooth((time - raise_at) / raise_dur)
			weight = raise_t
			target = rest_hand.lerp(back, raise_t)
		elif time < impact:
			# Fast swing forward along a curved path to the cheek.
			weight = 1.0
			var swing := Pose.smooth((time - swing_at) / swing_dur)
			target = back.lerp(mid, swing).lerp(mid.lerp(cheek, swing), swing)
		else:
			# Recover back to the rest pose.
			weight = 1.0
			var recover := Pose.smooth((time - impact) / recover_dur_local)
			target = cheek.lerp(rest_hand, recover)
		Pose.reach(player_skeleton, side, player_skeleton.to_local(target), weight)
	# NPC flinches: the head snaps in the swing direction, then returns.
	var flinch := Pose.smooth((time - impact) / 0.10) * Pose.smooth((impact + 0.70 - time) / 0.50)
	if head >= 0 and flinch > 0.0:
		# Swing direction at contact, flattened to the ground plane.
		var swing_dir: Vector3 = cheek - back
		swing_dir.y = 0.0
		if swing_dir.length_squared() < 0.0001:
			swing_dir = fwd
		swing_dir = swing_dir.normalized()
		# Turn the head to follow the hand's travel (yaw) plus a small dodge away.
		var yaw_axis := swing_dir.cross(Vector3.UP).normalized()
		var yaw_angle := yaw_axis.y * flinch * 1.05
		var turn := Quaternion(Vector3.UP, yaw_angle)
		var pose := skeleton.get_bone_pose(head)
		pose.basis = Basis(turn) * pose.basis
		pose.origin += Vector3.UP * (-0.015 * flinch) + swing_dir * (0.05 * flinch)
		skeleton.set_bone_pose(head, pose)
	# Show the red mark at impact.
	if time >= impact:
		show_slap_mark(entry, skeleton, head, side_sign)


# Target heights (metres above NPC feet) and flinch axes per strike kind.
const STRIKE_TARGETS := {
	"spank": {"height": 0.82, "reach": 0.10, "punch": false, "knockdown": false, "mark": true},
	"thigh": {"height": 0.48, "reach": 0.11, "punch": false, "knockdown": false, "mark": true},
	"chest": {"height": 1.28, "reach": 0.08, "punch": false, "knockdown": false, "mark": true},
	"face_punch": {"height": 1.55, "reach": 0.05, "punch": true, "knockdown": true, "mark": true},
	"stomach_punch": {"height": 1.02, "reach": 0.07, "punch": true, "knockdown": true, "mark": false},
}


func play_targeted_strike(entry: Dictionary, actor: Node3D, skeleton: Skeleton3D, state: Dictionary, time: float) -> void:
	var kind: String = state.get("strike_kind", "spank")
	var conf: Dictionary = STRIKE_TARGETS.get(kind, STRIKE_TARGETS["spank"])
	var player_skeleton: Skeleton3D = state.player_skeleton
	var player_start: Array[Transform3D] = state.player_start
	var side: String = "L" if int(state.get("slap_variant", 0)) == 2 else "R"
	var hand := player_skeleton.find_bone("cf_j_hand_" + side)
	var player_head := player_skeleton.find_bone("cf_j_head")
	var npc_hips := skeleton.find_bone("cf_j_hips")
	# Timings: variants 0/2 fast, variant 1 slow theatrical.
	var raise_dur := 0.34
	var swing_dur := 0.15
	var recover_dur := 0.55
	if int(state.get("slap_variant", 0)) == 1:
		raise_dur = 0.62
		swing_dur = 0.24
		recover_dur = 0.8
	var raise_at := 0.06
	var swing_at := raise_at + raise_dur
	var impact := swing_at + swing_dur
	Pose.blend(player_skeleton, player_start, player_start, 1.0)
	var to_npc: Vector3 = actor.global_position - room.player.global_position
	to_npc.y = 0.0
	if to_npc.length_squared() > 0.0001:
		var face: float = atan2(-to_npc.x, -to_npc.z)
		if not state.has("player_yaw"):
			state.player_yaw = room.player_model.rotation.y
		var turn := Pose.smooth((time - 0.04) / 0.30) * Pose.smooth((impact + 0.75 - time) / 0.45)
		room.player_model.rotation.y = lerp_angle(state.player_yaw, face, turn)
	var fwd: Vector3 = to_npc.normalized() if to_npc.length_squared() > 0.0001 else -room.player_model.global_transform.basis.z
	fwd.y = 0.0
	fwd = fwd.normalized()
	var right: Vector3 = fwd.cross(Vector3.UP).normalized()
	if right.length_squared() < 0.5:
		right = Vector3.RIGHT.rotated(Vector3.UP, room.player_model.rotation.y)
	var lateral: Vector3 = right * (-1.0 if side == "L" else 1.0)
	var own_head: Vector3 = room.player.global_position + Vector3.UP * 1.55
	if player_head >= 0:
		own_head = player_skeleton.to_global(player_skeleton.get_bone_global_pose(player_head).origin)
	var rest_hand: Vector3 = own_head
	if hand >= 0:
		rest_hand = player_skeleton.to_global(player_skeleton.get_bone_global_pose(hand).origin)
	# Strike target: a point on the NPC body at the kind's height, toward the player.
	var npc_base: Vector3 = actor.global_position
	if npc_hips >= 0:
		npc_base = skeleton.to_global(skeleton.get_bone_global_pose(npc_hips).origin) - Vector3.UP * 0.9
	var target: Vector3 = npc_base + Vector3.UP * float(conf.height)
	var toward_player: Vector3 = room.player.global_position - actor.global_position
	toward_player.y = 0.0
	if toward_player.length_squared() > 0.0001:
		target += toward_player.normalized() * float(conf.reach)
	# Wind up on the player's striking side, out and back.
	var back: Vector3 = own_head + lateral * 0.40 + Vector3.UP * 0.12 - fwd * 0.22
	if kind == "face_punch":
		back = own_head + lateral * 0.34 - Vector3.UP * 0.10 - fwd * 0.10
	elif kind == "stomach_punch":
		back = own_head + lateral * 0.30 - Vector3.UP * 0.24 - fwd * 0.06
	var mid: Vector3 = back.lerp(target, 0.5) + fwd * 0.12
	if hand >= 0:
		var target_pos: Vector3
		var weight := 0.0
		if time < swing_at:
			var raise_t := Pose.smooth((time - raise_at) / raise_dur)
			weight = raise_t
			target_pos = rest_hand.lerp(back, raise_t)
		elif time < impact:
			weight = 1.0
			var swing := Pose.smooth((time - swing_at) / swing_dur)
			target_pos = back.lerp(mid, swing).lerp(mid.lerp(target, swing), swing)
		else:
			weight = 1.0
			var recover := Pose.smooth((time - impact) / recover_dur)
			target_pos = target.lerp(rest_hand, recover)
		Pose.reach(player_skeleton, side, player_skeleton.to_local(target_pos), weight)
	# NPC flinch: bend at the struck spot; punches knock the NPC down.
	var flinch := Pose.smooth((time - impact) / 0.10) * Pose.smooth((impact + 0.70 - time) / 0.50)
	if flinch > 0.0:
		flinch_npc(skeleton, kind, flinch, state)
	# Knockdown after face / stomach punches: the NPC sinks to the ground.
	var knock := float(conf.knockdown)
	if knock > 0.0 and time > impact:
		var drop := Pose.smooth((time - impact) / 0.55)
		if npc_hips >= 0:
			var pose := skeleton.get_bone_pose(npc_hips)
			pose.origin += Vector3.DOWN * 0.52 * drop + fwd * 0.12 * drop
			pose.basis = pose.basis * Basis(Vector3.RIGHT, drop * (PI * 0.22))
			skeleton.set_bone_pose(npc_hips, pose)
	if time >= impact and bool(conf.mark):
		show_target_mark(entry, skeleton, npc_hips, kind, fwd, lateral)


func flinch_npc(skeleton: Skeleton3D, kind: String, weight: float, state: Dictionary) -> void:
	match kind:
		"spank":
			var hips := skeleton.find_bone("cf_j_hips")
			if hips >= 0:
				var pose := skeleton.get_bone_pose(hips)
				pose.basis = pose.basis * Basis(Vector3.RIGHT, weight * 0.30)
				skeleton.set_bone_pose(hips, pose)
			var spine := skeleton.find_bone("cf_j_spine01")
			if spine >= 0:
				var pose2 := skeleton.get_bone_pose(spine)
				pose2.basis = pose2.basis * Basis(Vector3.RIGHT, weight * 0.18)
				skeleton.set_bone_pose(spine, pose2)
		"thigh":
			var thigh := skeleton.find_bone("cf_j_thigh_R")
			if thigh >= 0:
				var pose := skeleton.get_bone_pose(thigh)
				pose.basis = pose.basis * Basis(Vector3.RIGHT, weight * 0.22)
				skeleton.set_bone_pose(thigh, pose)
		"chest":
			var chest := skeleton.find_bone("cf_j_spine01")
			if chest >= 0:
				var pose := skeleton.get_bone_pose(chest)
				pose.basis = pose.basis * Basis(Vector3.RIGHT, -weight * 0.20)
				skeleton.set_bone_pose(chest, pose)
		"face_punch":
			var head := int(state.get("head_bone", -1))
			if head < 0:
				head = slap_head_bone(skeleton)
			if head >= 0:
				var pose := skeleton.get_bone_pose(head)
				pose.basis = pose.basis * Basis(Vector3.RIGHT, -weight * 0.55) * Basis(Vector3.UP, weight * 0.6)
				skeleton.set_bone_pose(head, pose)
		"stomach_punch":
			var spine := skeleton.find_bone("cf_j_spine02")
			if spine >= 0:
				var pose := skeleton.get_bone_pose(spine)
				pose.basis = pose.basis * Basis(Vector3.RIGHT, weight * 0.45)
				skeleton.set_bone_pose(spine, pose)


func show_target_mark(entry: Dictionary, skeleton: Skeleton3D, hips: int, kind: String, fwd: Vector3, lateral: Vector3) -> void:
	if slap_marks.has(entry) and is_instance_valid(slap_marks[entry]):
		return
	if hips < 0:
		return
	var mesh := SphereMesh.new()
	mesh.radial_segments = 16
	mesh.rings = 10
	mesh.radius = 0.075
	mesh.height = 0.15
	var mark := MeshInstance3D.new()
	mark.name = "SlapMark"
	mark.mesh = mesh
	var material := StandardMaterial3D.new()
	material.albedo_color = Color(0.90, 0.05, 0.08, 0.95)
	material.emission_enabled = true
	material.emission = Color(0.55, 0.02, 0.03)
	material.emission_energy_multiplier = 0.7
	material.roughness = 0.4
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mark.material_override = material
	var actor: Node3D = skeleton.get_parent()
	actor.add_child(mark)
	var hips_pose := skeleton.get_bone_global_pose(hips)
	# Height above the hips per kind.
	var heights := {"spank": 0.0, "thigh": -0.30, "chest": 0.40, "face_punch": 0.70}
	var offset := Vector3.UP * float(heights.get(kind, 0.0)) + fwd * 0.065 + lateral * 0.02
	mark.global_position = skeleton.to_global((hips_pose.origin - skeleton.global_position) + offset)
	mark.scale = Vector3(1.0, 1.2, 1.45)
	slap_marks[entry] = mark
	get_tree().create_timer(20.0).timeout.connect(func() -> void:
		if is_instance_valid(mark):
			mark.queue_free()
			slap_marks.erase(entry))


func show_slap_mark(entry: Dictionary, skeleton: Skeleton3D, head: int, side_sign: float = 1.0) -> void:
	if slap_marks.has(entry) and is_instance_valid(slap_marks[entry]):
		return
	if head < 0:
		return
	var mesh := SphereMesh.new()
	mesh.radial_segments = 16
	mesh.rings = 10
	mesh.radius = 0.085
	mesh.height = 0.17
	var mark := MeshInstance3D.new()
	mark.name = "SlapMark"
	mark.mesh = mesh
	var material := StandardMaterial3D.new()
	material.albedo_color = Color(0.90, 0.05, 0.08, 0.95)
	material.emission_enabled = true
	material.emission = Color(0.55, 0.02, 0.03)
	material.emission_energy_multiplier = 0.7
	material.roughness = 0.4
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mark.material_override = material
	var actor: Node3D = skeleton.get_parent()
	actor.add_child(mark)
	var head_pose := skeleton.get_bone_global_pose(head)
	var rest := skeleton.get_bone_global_rest(head)
	# Big visible palm print on the struck side of the cheek.
	var cheek := rest.origin + rest.basis * Vector3(0.085 * side_sign, -0.04, 0.105)
	mark.global_position = actor.to_global(cheek)
	mark.scale = Vector3(1.0, 1.25, 1.55)
	mark.look_at(mark.global_position + rest.basis * Vector3(side_sign, 0.0, 1.0))
	slap_marks[entry] = mark
	get_tree().create_timer(20.0).timeout.connect(func() -> void:
		if is_instance_valid(mark):
			mark.queue_free()
			slap_marks.erase(entry))


func skirt_grip_vertices(actor: Node3D, rig: Skeleton3D, hems: Array[int]) -> Dictionary:
	var best := {"L": INF, "R": INF}
	var result := {}
	for part: MeshInstance3D in Edit.slots(actor).get("Bottom", []):
		if not part.visible or not part.skin or not part.mesh:
			continue
		var sole := part.mesh.get_aabb().position.y
		for surface in range(part.mesh.get_surface_count()):
			var data := part.mesh.surface_get_arrays(surface)
			var vertices: PackedVector3Array = data[Mesh.ARRAY_VERTEX]
			var joints: PackedInt32Array = data[Mesh.ARRAY_BONES]
			var weights: PackedFloat32Array = data[Mesh.ARRAY_WEIGHTS]
			if joints.size() != vertices.size() * 4:
				continue
			for index in range(vertices.size()):
				var point := vertices[index]
				if absf(point.x) < 0.045 or point.z > 0.035:
					continue
				var side := "L" if point.x < 0.0 else "R"
				var score := pow(absf(point.x) - 0.126, 2.0) + pow(point.z + 0.13, 2.0)
				score += pow(point.y - sole, 2.0) * 0.73
				if score >= float(best[side]):
					continue
				var influence := []
				var weighted_hem := 0.0
				for component in range(4):
					var at := index * 4 + component
					var joint := joints[at]
					var bone := part.skin.get_bind_bone(joint)
					var weight := weights[at]
					if bone < 0 or bone >= rig.get_bone_count() or weight <= 0.0:
						continue
					if bone in hems and not String(rig.get_bone_name(bone)).ends_with("_00"):
						weighted_hem += weight
					influence.append([bone, part.skin.get_bind_pose(joint) * point, weight])
				if weighted_hem > 0.45:
					best[side] = score
					result[side] = influence
	return result


func play_skirt(skeleton: Skeleton3D, hems: Array[int], time: float, grips := {}) -> void:
	var grip := Pose.smooth((time - 0.15) / 0.48) * Pose.smooth((2.76 - time) / 0.47)
	var lift := Pose.smooth((time - 0.65) / 0.48) * Pose.smooth((2.28 - time) / 0.50)
	var hips := skeleton.find_bone("cf_j_hips")
	var center := skeleton.get_bone_global_pose(hips).origin if hips >= 0 else Vector3.UP
	var shifts := {}
	var ends := {}
	for bone in hems:
		var name := String(skeleton.get_bone_name(bone))
		var chain := name.get_slice("_", 3)
		var segment := int(name.get_slice("_", 4))
		if segment > int(ends.get(chain, {}).get("segment", 0)):
			ends[chain] = {"segment": segment, "bone": bone, "point": skeleton.get_bone_global_pose(bone).origin}
	for bone in hems:
		var name := String(skeleton.get_bone_name(bone))
		var segment := int(name.get_slice("_", 4))
		var chain: Dictionary = ends.get(name.get_slice("_", 3), {})
		if segment < 1 or chain.is_empty():
			continue
		var hem: Vector3 = chain.point - center
		var front := Pose.smooth((0.085 - hem.z) / 0.15)
		var amount := minf(0.36, maxf(0.0, 0.015 - hem.y))
		var share := lift * front / float(chain.segment)
		var parent := skeleton.get_bone_parent(bone)
		var basis := skeleton.get_bone_global_pose(parent).basis
		shifts[bone] = basis.inverse() * Vector3(-0.027 * signf(hem.x), amount, -0.083) * share
	for bone: int in shifts:
		skeleton.set_bone_pose_position(bone, skeleton.get_bone_pose_position(bone) + shifts[bone])
	for side in ["L", "R"]:
		var sign_x := -1.0 if side == "L" else 1.0
		var bone := -1
		var closest := INF
		# Choose the same weighted end at every stage of the lift.
		for chain: Dictionary in ends.values():
			var point: Vector3 = chain.point - center
			var distance := Vector2(point.x, point.z).distance_squared_to(Vector2(sign_x * 0.127, -0.115))
			if distance < closest:
				bone = chain.bone
				closest = distance
		if bone >= 0:
			var hem := skeleton.get_bone_global_pose(bone).origin
			if grips.has(side):
				var world_point := Vector3.ZERO
				var total := 0.0
				for influence: Array in grips[side]:
					world_point += (skeleton.get_bone_global_pose(influence[0]) * influence[1]) * influence[2]
					total += influence[2]
				if total > 0.0:
					hem = world_point / total
			Pose.plant_hand(skeleton, side, hem + Vector3(sign_x * 0.012, 0.011, -0.016),
				Vector3(0, -0.77, 0.64), Vector3.BACK, grip, Vector3(sign_x * 0.7, -0.52, 0.2), "pinch")
			if grip > 0.01:
				var thumb := skeleton.find_bone("cf_j_thumb02_" + side)
				var pad := skeleton.find_bone("cf_j_thumb03_" + side)
				if mini(thumb, pad) >= 0:
					var tip := skeleton.get_bone_global_pose(pad).origin
					Pose.aim(skeleton, thumb, pad, tip.lerp(hem, 0.18), grip * 0.6)


func play_hug(entry: Dictionary, actor: Node3D, body: CharacterBody3D, delta: float) -> void:
	var state: Dictionary = entry.action
	var skeleton: Skeleton3D = state.skeleton
	var toward: Vector3 = room.player.global_position - body.global_position
	toward.y = 0.0
	if not state.has("partner"):
		var error := toward.length() - HUG_APPROACH_GAP
		var move := toward.normalized() * minf(1.38, maxf(0.0, error * 6.0))
		move_body(body, move, delta)
		if toward.length_squared() > 0.003:
			actor.rotation.y = lerp_angle(actor.rotation.y, atan2(-toward.x, -toward.z), minf(1.0, 8.0 * delta))
		var time: float = state.elapsed
		var walk: Animation = state.walk
		var walking := Pose.sample(walk, skeleton, state.base, fmod(time * 0.9, walk.length))
		var advance := Pose.smooth(time / ENTER_TIME)
		Pose.blend(skeleton, state.start, walking, advance)
		Pose.blend(skeleton, Pose.capture(skeleton), state.idle, advance * (1.0 - Pose.smooth(error / 0.26)))
		if error > 0.035:
			if time > 3.2:
				state.kind = "release"
				state.start = Pose.capture(skeleton)
				state.elapsed = 0.0
			return
		if not hug_owner.is_empty():
			state.kind = "release"
			state.start = Pose.capture(skeleton)
			state.elapsed = 0.0
			return
		var partner: AnimationPlayer = room.player_anim
		var other: Skeleton3D = room.player_model.get_node("Skeleton")
		state.partner = partner
		state.contact_body = body
		state.contact_start = body.global_position
		state.contact_direction = toward.normalized()
		state.partner_start = Pose.capture(other)
		state.partner_idle = idle_pose(partner, other, Pose.rest(other))
		state.partner_yaw = room.player_model.rotation.y
		state.start = Pose.capture(skeleton)
		state.approach_yaw = actor.rotation.y
		state.yaw = atan2(-toward.x, -toward.z)
		state.elapsed = 0.0
		partner.pause()
		room.player.add_collision_exception_with(body)
		hug_owner = entry
		return
	if not holds_player_pose():
		finish_action(entry)
		return
	var other: Skeleton3D = room.player_model.get_node("Skeleton")
	var time: float = state.elapsed
	var settle := Pose.smooth(time / 0.36)
	var step := Pose.smooth(time / 0.55) * Pose.smooth((1.78 - time) / 0.55)
	var start: Vector3 = state.contact_start
	var contact_direction: Vector3 = state.contact_direction
	var target := start + contact_direction * (start.distance_to(room.player.global_position) - HUG_GAP) * step
	var correction := target - body.global_position
	correction.y = 0.0
	move_body(body, correction / delta, delta)
	actor.rotation.y = lerp_angle(state.approach_yaw, state.yaw, settle)
	room.player_model.rotation.y = lerp_angle(state.partner_yaw, state.yaw + PI, settle)
	Pose.blend(skeleton, state.start, state.idle, settle)
	Pose.blend(other, state.partner_start, state.partner_idle, settle)
	var embrace := Pose.smooth((time - 0.10) / 0.49) * Pose.smooth((1.70 - time) / 0.52)
	lean_into_hug(skeleton, embrace)
	lean_into_hug(other, embrace)
	reach_partner(skeleton, other, embrace, 0.11)
	reach_partner(other, skeleton, embrace, 0.18)
	if time >= 1.80:
		finish_action(entry)


func lean_into_hug(skeleton: Skeleton3D, weight: float) -> void:
	var spine := skeleton.find_bone("cf_j_spine01")
	var chest := skeleton.find_bone("cf_j_spine03")
	if spine >= 0 and chest >= 0:
		var target := skeleton.get_bone_global_pose(chest).origin + Vector3.FORWARD * 0.065
		Pose.aim(skeleton, spine, chest, target, weight)


func reach_partner(skeleton: Skeleton3D, other: Skeleton3D, weight: float, below_shoulder: float) -> void:
	if weight <= 0.0:
		return
	var torso := other.find_bone("cf_j_spine03")
	if torso < 0:
		return
	var center := other.get_bone_global_pose(torso).origin
	for side in ["L", "R"]:
		var outward := -1.0 if side == "L" else 1.0
		var target := other.to_global(center + Vector3(-outward * 0.115, -below_shoulder, 0.066))
		Pose.reach(skeleton, side, skeleton.to_local(target), weight)


func move_body(body: CharacterBody3D, motion: Vector3, delta: float) -> void:
	body.velocity.x = motion.x
	body.velocity.z = motion.z
	body.velocity.y = -0.2 if body.is_on_floor() else body.velocity.y - 13.0 * delta
	body.move_and_slide()


func skirt_bones(actor: Node3D) -> Array[int]:
	var result: Array[int] = []
	var skeleton: Skeleton3D = actor.get_node("Skeleton")
	for part: MeshInstance3D in Edit.slots(actor).get("Bottom", []):
		if not part.visible or not part.skin:
			continue
		for surface in range(part.mesh.get_surface_count()):
			var arrays := part.mesh.surface_get_arrays(surface)
			var indices: PackedInt32Array = arrays[Mesh.ARRAY_BONES]
			var weights: PackedFloat32Array = arrays[Mesh.ARRAY_WEIGHTS]
			var checked := {}
			for i in range(indices.size()):
				if weights[i] <= 0 or checked.has(indices[i]):
					continue
				checked[indices[i]] = true
				var bone := part.skin.get_bind_bone(indices[i])
				if bone >= 0 and skeleton.get_bone_name(bone).to_lower().begins_with("cf_j_sk_") and bone not in result:
					result.append(bone)
	return result


func tick(delta: float) -> void:
	if room.editor.is_open() or room.menu.is_open():
		if green.active():
			green.end()
		prompt.hide()
		return
	var target := current_interaction()
	prompt.visible = not dialogue.visible and not staging.smooth_approach() and not target.is_empty()
	if prompt.visible:
		prompt.text = "E — " + (doorway_label.text if target.get("exit", false) else "Talk · " + target.definition.name)
	for entry in entries:
		var body := body_for(entry)
		var actor := actor_for(entry)
		var animator := animator_for(entry)
		if not body or not body.visible or not animator:
			continue
		if entry.get("animator") != animator:
			finish_action(entry)
			entry.animator = animator
			entry.erase("posture")
			entry.erase("turn")
			entry.erase("facing_locked")
			entry.erase("conversation_ready")
			contact.select_mark_set(entry, actor)
			contact.apply_marks(entry, actor)
		if green.active() and entry == speaking:
			continue
		tick_posture(entry, actor, delta)
		if entry.get("face_speaker", false) and speaking == entry:
			var offset: Vector3 = room.player.global_position - body.global_position
			if Vector2(offset.x, offset.z).length_squared() > 0.01:
				var yaw := atan2(-offset.x, -offset.z)
				actor.rotation.y = lerp_angle(actor.rotation.y, yaw, 1.0 - exp(-10.0 * delta))
		if entry.has("posture") or entry.has("turn"):
			continue
		if entry.has("action"):
			play_action(entry, actor, body, delta)
			continue
		if not entry.follows and not entry.get("moving", false):
			continue
		var toward: Vector3 = room.player.global_position - body.global_position
		toward.y = 0.0
		var moving: bool = entry.follows and not dialogue.visible and toward.length() > 1.35
		var motion := toward.normalized() * WALK_SPEED if moving else Vector3.ZERO
		move_body(body, motion, delta)
		if moving:
			actor.rotation.y = lerp_angle(actor.rotation.y, atan2(-motion.x, -motion.z), minf(1.0, delta * 10.0))
			ensure_locomotion(animator)
			if animator.current_animation != &"Walk":
				animator.play("Walk", 0.24)
		elif entry.get("moving", false):
			var idle := &"ConversationIdle" if animator.has_animation("ConversationIdle") else &"Idle"
			animator.play(idle, 0.30)
		entry.moving = moving
	staging.tick(delta)
	contact.tick(delta)
	rear_choices.visible = dialogue.visible and mode == 2 and contact.rear_options_ready()
	if dialogue.visible:
		if mode == 0 and not green.active():
			_ensure_green()
		if not pending_contact.is_empty():
			var can_begin: bool = speaking.get("posture", {}).get("complete", true) and not speaking.has("turn")
			for event in pending_contact:
				if green.active():
					green.pointer(event)
				elif mode != 0 and (can_begin or not event.pressed):
					contact.input(event, mode)
			pending_contact.clear()
		var show_legs: bool = contact.state.get("show_legs", false) or (
			float(contact.state.get("camera_crouch", 0.0)) > 0.12 and not contact.state.get("planted_crouch", false))
		if green.active():
			green.tick(delta)
		elif staging.active():
			player_view.restore()
		else:
			player_view.show_limbs(room.player_model, contact.state.get("hand_weights", {}), show_legs)
		var mouse := get_viewport().get_mouse_position()
		var over_ui := dialogue.get_global_rect().has_point(mouse) or mode_panel.get_global_rect().has_point(mouse) or (rear_choices.visible and rear_choices.get_global_rect().has_point(mouse)) or (green.active() and green.shell.get_global_rect().has_point(mouse))
		var aimed: Dictionary = {} if over_ui else (green.pick(mouse) if green.active() else contact.pick(mouse))
		var zone_name: String = Contact.ZONES[aimed.id][0] if not aimed.is_empty() else ""
		Input.set_default_cursor_shape(Input.CURSOR_POINTING_HAND if not aimed.is_empty() else Input.CURSOR_ARROW)
		show_mode_hint(zone_name)
	if area == "park" and room.player.position.y < -5.0:
		room.player.position = vector(data["areas"]["park"]["player_spawn"])
		room.player.velocity = Vector3.ZERO
