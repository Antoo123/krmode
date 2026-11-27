extends SceneTree

var errors := 0
var room: Node3D
var game: Node3D
var green: Node3D
var output: String

func _initialize() -> void:
	run.call_deferred()

func check(ok: bool, detail: String) -> void:
	if not ok:
		errors += 1
		printerr("FAIL ", detail)

func frames(count: int) -> void:
	for i in count:
		await physics_frame
		await RenderingServer.frame_post_draw

func picture(tag: String) -> void:
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png(output.path_join(tag + ".png"))

func run() -> void:
	output = OS.get_cmdline_user_args()[0]
	change_scene_to_file("res://room.tscn")
	await frames(4)
	room = current_scene
	game = room.npc_gameplay
	green = game.green
	room.player.position = room.dancer_body.position + Vector3(0, 0.1, 1.10)
	await frames(8)
	var key := InputEventKey.new()
	key.pressed = true
	key.keycode = KEY_E
	root.push_input(key)
	await frames(3)
	check(game.dialogue.visible and room.animation_lab == null, "normal NPC dialogue")
	game.green_button.pressed.emit()
	await frames(25)
	if not green.active():
		printerr("FAIL Green start ", game.answer.text, " ", green.failure)
		quit(1)
		return
	var panel: Control = green.panel
	var tracks_ok := 0
	for id in 11:
		green.select_position(id)
		await frames(4)
		check(green.position_id == id and green.state == "Idle" and green.clip != null and green.failure.is_empty(), "idle position %d" % id)
		for native in ["native_chest_l", "native_lap", "native_seat_r"]:
			var rule: Dictionary = green._rule(native)
			for step in ["contact", "loop", "release"]:
				if green._switch(rule[step], rule.source, true):
					tracks_ok += 1
				else:
					check(false, "%d %s %s %s" % [id, native, step, green.failure])
		green.restart()
	print("Verified exact state references on 11 positions: ", tracks_ok)
	green.select_position(0)
	await frames(24)
	await picture("idle")
	var left: Node3D = panel.runners[0]
	var right: Node3D = panel.runners[1]
	check(panel.start(0, panel.preset_for("native_chest_l", "L")).is_empty(), "left native start")
	check(panel.start(1, panel.preset_for("pat_head", "R")).is_empty(), "right additive start")
	var touched := false
	var looped := false
	var face := false
	var body := false
	var rig: Skeleton3D = green.rig
	var joint := rig.find_bone("cf_j_spine03")
	var start := rig.get_bone_pose_rotation(joint)
	for i in 260:
		await physics_frame
		if green.state == "M_Touch" and not touched:
			touched = true
			await picture("contact")
		if green.state == "M_Idle" and not looped:
			looped = true
			await picture("loop")
		face = face or (green.reaction.face.applied.get("surfaces", 0) > 0 and green.reaction.contact_mix.face_strength > 0.3)
		body = body or (green.state == "M_Touch" and rig.get_bone_pose_rotation(joint).angle_to(start) > 0.02)
		if looped and face:
			break
	check(touched and looped and face and body and left.running and right.running, "full native body, face and simultaneous hands")
	print("Native sequence touch=", touched, " loop=", looped, " face=", face, " body=", body, " measured=", left.contact_result.get("surface", false))
	panel.release(0)
	await frames(25)
	check(right.running and not left.running, "left independent release")
	panel.release_all()
	await frames(35)
	check(green.state == "Idle" and left.tool_id < 0 and right.tool_id < 0, "release returned to idle")
	await picture("release")
	green.select_position(0)
	await frames(22)
	var cursor := Vector2(-1, -1)
	for offset in [Vector2.ZERO, Vector2(0, 6), Vector2(0, -6), Vector2(8, 0)]:
		var crown: Dictionary = game.contact.zone_anchor(green.rig, "crown")
		var point: Vector2 = room.camera.unproject_position(crown.point) + Vector2(offset)
		if green.pick(point).get("id", "") == "crown":
			cursor = point
			break
	check(cursor.x >= 0.0, "aimed crown")
	if cursor.x >= 0.0:
		var click := InputEventMouseButton.new()
		click.position = cursor
		click.button_index = MOUSE_BUTTON_LEFT
		click.pressed = true
		game.handle_input(click)
		await frames(3)
		check(left.running and String(left.custom_animation.get("action", "")) == "pat_head", "normal left click starts mapped contact")
		var up := click.duplicate() as InputEventMouseButton
		up.pressed = false
		game.handle_input(up)
		await frames(3)
		check(not left.running, "normal left click release")
	green.restart()
	for id: String in preload("res://pov_hand_actions.gd").ACTIONS:
		var preset: Dictionary = panel.preset_for(id, "R")
		var choice: String = panel.start(1, preset)
		await frames(2)
		check(choice.is_empty() and right.running, "gameplay action " + id)
		green.restart()
	print("All 17 custom gameplay actions started in the room; normal pointer checked.")
	green.select_position(3)
	await frames(24)
	panel.controls[0].speed.value = 0.6
	panel.controls[1].speed.value = 1.4
	panel.start(0, panel.preset_for("hold_head", "L"))
	panel.start(1, panel.preset_for("hold_right_foot", "R"))
	await frames(50)
	check(left.custom_time < right.custom_time and left.running and right.running, "distinct speed seated")
	await picture("chair-two-hands")
	green.restart()
	check(left.tool_id < 0 and right.tool_id < 0 and green.state == "Idle", "restart")
	game.mode_panel.get_child(1).pressed.emit()
	await frames(12)
	check(game.mode == 1 and not green.active() and not game.green_button.visible, "Yellow after Green")
	game.mode_panel.get_child(2).pressed.emit()
	check(game.mode == 2 and not green.active(), "Red after Green")
	game.mode_panel.get_child(0).pressed.emit()
	game.green_button.pressed.emit()
	await frames(15)
	var card := preload("res://card_library.gd").directory().get_base_dir().path_join("Friendly-portable.png")
	check(room.load_card(card, true), "swap card")
	await frames(10)
	check(not green.active(), "swap stopped old session")
	game.green_button.pressed.emit()
	await frames(20)
	check(green.active() and green.actors[1] == room.dancer_model, "new card enters Green")
	game.close_dialogue()
	check(not green.active() and room.animation_lab == null, "closed regular gameplay")
	print("Green gameplay errors: ", errors)
	quit(int(errors > 0))
