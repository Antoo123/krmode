extends RefCounted


static func run(room: Node3D, output: String) -> bool:
	var tree := room.get_tree()
	var game: Node3D = room.npc_gameplay
	var green: Node3D = game.green
	room.player.position = room.dancer_body.position + Vector3(0.0, 0.10, 1.10)
	for i in 12:
		await tree.physics_frame
	var talk := InputEventKey.new()
	talk.pressed = true
	talk.keycode = KEY_E
	room.get_viewport().push_input(talk)
	if not game.dialogue.visible or room.animation_lab:
		push_error("Green smoke requires normal NPC dialogue.")
		return false
	if not green.active() or green.positions.item_count != 7:
		push_error("Green entry failed: " + green.failure)
		return false
	var count := 0
	for index in green.positions.item_count:
		green.positions.select(index)
		green.positions.item_selected.emit(index)
		if green.state != "Idle" or not green.failure.is_empty() or green.camera_view().is_empty():
			push_error("No original Idle or camera in Green position " + str(index))
			return false
		for name in ["native_chest_l", "native_lap", "native_seat_l"]:
			var rule: Dictionary = green._rule(name)
			for step in ["contact", "loop", "release"]:
				if not green._switch(rule[step], rule.source, true):
					push_error(green.failure)
					return false
				count += 1
	green.select_position(0)
	for i in 24:
		await tree.physics_frame
	var panel: Control = green.panel
	var right: Dictionary = panel.controls[1]
	right.zone.select(3)
	right.zone.item_selected.emit(3)
	right.speed.value = 1.3
	panel.controls[0].start.pressed.emit()
	right.start.pressed.emit()
	var touch := false
	var loop := false
	var face := false
	var left_hand: Node3D = panel.runners[0]
	var right_hand: Node3D = panel.runners[1]
	for i in 320:
		await tree.physics_frame
		touch = touch or green.state == "M_Touch"
		loop = loop or green.state == "M_Idle"
		face = face or (green.reaction.contact_mix.face_strength > 0.3 and green.reaction.face.applied.get("surfaces", 0) >= 3)
		if touch and loop and face:
			break
	if not (touch and loop and face and left_hand.running and right_hand.running and left_hand.custom_time < right_hand.custom_time):
		push_error("Green contact failed: touch=%s loop=%s face=%s left=%s right=%s" % [touch, loop, face, left_hand.running, right_hand.running])
		return false
	if DisplayServer.get_name() != "headless":
		await RenderingServer.frame_post_draw
		if room.get_viewport().get_texture().get_image().save_png(output) != OK:
			push_error("Could not save the Green smoke screenshot.")
			return false
	panel.release(0)
	for i in 29:
		await tree.physics_frame
	if not right_hand.running or left_hand.tool_id >= 0:
		push_error("Left release affected right hand.")
		return false
	panel.release_all()
	for i in 55:
		await tree.physics_frame
	if green.state != "Idle" or right_hand.tool_id >= 0:
		push_error("Green did not return to Idle.")
		return false
	green.control.select(1)
	green.controlled_hand.select(0)
	green._update_control()
	var chin: Dictionary = panel.preset_for("chin_lift", "L")
	var cheek: Dictionary = panel.preset_for("touch_cheek", "R")
	if not String(panel.start(0, chin)).is_empty() or not String(panel.start(1, cheek)).is_empty():
		push_error("The packaged face contacts could not start.")
		return false
	for i in 30:
		await tree.physics_frame
	var initial: float = left_hand.custom_time
	var fixed: Transform3D = room.camera.global_transform
	for i in 50:
		green.mouse_motion(Vector2(0, -11))
		await tree.physics_frame
	var forward: float = left_hand.custom_time
	if forward < initial + 0.30 or left_hand.contact_result.get("tips", []).size() != 2 or right_hand.contact_result.get("tips", []).size() != 2:
		push_error("The packaged mouse and finger contacts did not advance.")
		return false
	if not left_hand.contact_result.get("surface", false) or not right_hand.contact_result.get("surface", false):
		push_error("A packaged facial contact missed the face.")
		return false
	if fixed.origin.distance_to(room.camera.global_position) > 0.01 or fixed.basis.z.distance_to(room.camera.global_basis.z) > 0.01:
		push_error("Mouse motion moved the gameplay camera.")
		return false
	if DisplayServer.get_name() != "headless":
		await RenderingServer.frame_post_draw
		var face_path := output.get_basename() + "-face.png"
		if room.get_viewport().get_texture().get_image().save_png(face_path) != OK:
			return false
	for i in 36:
		green.mouse_motion(Vector2(0, 12))
		await tree.physics_frame
	if left_hand.custom_time > forward - 0.25 or not right_hand.running:
		push_error("The packaged mouse direction did not reverse independently.")
		return false
	green.restart()
	var catalog := preload("res://card_library.gd")
	var card := catalog.directory().get_base_dir().path_join("Friendly-portable.png")
	if not room.load_card(card, true):
		push_error("The packaged card swap failed.")
		return false
	for i in 20:
		await tree.physics_frame
	if not green.active() or green.actors[1] != room.dancer_model:
		push_error("Green did not bind the replacement NPC.")
		return false
	print("Green mouse: static camera, reversed chin gesture, two facial contacts and card swap.")
	game.close_dialogue()
	if green.active() or not room.player_model.visible:
		push_error("Green did not return control to the ordinary room.")
		return false
	print("Windows Green: %d original references, 7 positions, Idle -> M_Touch -> M_Idle -> Idle, face morphs, distinct hand speeds and independent release." % count)
	return true
