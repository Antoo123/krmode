extends SceneTree

func _initialize() -> void:
	run.call_deferred()

func press(code: Key) -> void:
	var input := InputEventKey.new()
	input.keycode = code
	input.pressed = true
	root.push_input(input)

func run() -> void:
	change_scene_to_file("res://room.tscn")
	for i in 8:
		await RenderingServer.frame_post_draw
	var room: Node3D = current_scene
	var game: Node3D = room.npc_gameplay
	game.open_dialogue(game.entries[0])
	game.mode_panel.get_child(1).pressed.emit()
	if game.green.active() or game.mode != 1:
		quit(7)
		return
	game.mode_panel.get_child(2).pressed.emit()
	if game.green.active() or game.mode != 2:
		quit(8)
		return
	game.mode_panel.get_child(0).pressed.emit()
	if not game.green.active():
		quit(1)
		return
	press(KEY_F5)
	if not room.pair_preview.is_open() or game.green.active() or game.dialogue.visible:
		quit(2)
		return
	for item in room.pair_preview.list.item_count:
		room.pair_preview.play_row(item)
		if room.pair_preview.tracks.size() == 2:
			break
	if room.pair_preview.tracks.size() != 2:
		quit(3)
		return
	await RenderingServer.frame_post_draw
	press(KEY_F6)
	if not room.studio_preview.is_open() or room.studio_preview.motions.is_empty():
		quit(4)
		return
	await RenderingServer.frame_post_draw
	press(KEY_F7)
	if not room.animation_lab or not room.animation_lab.is_open():
		quit(5)
		return
	print("F5 exited gameplay Green and loaded a pair; F6 opened a Studio scene; F7 opened the test lab.")
	quit()
