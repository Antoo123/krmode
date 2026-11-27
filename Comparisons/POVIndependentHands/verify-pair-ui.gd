extends SceneTree

const Preset := preload("res://hand_animation_preset.gd")

func _initialize() -> void:
	run.call_deferred()

func run() -> void:
	change_scene_to_file("res://room.tscn")
	for i in 3:
		await RenderingServer.frame_post_draw
	var event := InputEventKey.new()
	event.keycode = KEY_F7
	event.pressed = true
	root.push_input(event)
	var lab: CanvasLayer = current_scene.animation_lab
	lab._choose_caress_position(lab.caress_positions.get_item_index(0))
	lab.pov_hands.button_pressed = true
	var editor: VBoxContainer = lab.hand_editor
	editor.open_editor()
	var path := OS.get_cmdline_user_args()[0]
	var saved := Preset.read(path)
	editor._load(saved, "")
	editor.title.text = "POV pair UI verification"
	if not editor.save_preset(true):
		push_error("Editor failed to save pair")
		quit(1)
		return
	var test_path: String = editor.source
	editor.close_editor()
	lab.independent_switch.button_pressed = true
	var controls: Control = lab.independent_hands
	var index := -1
	for i in controls.pair.item_count:
		if controls.pair.get_item_metadata(i) == test_path:
			index = i
			break
	var okay := index > 0
	if okay:
		controls.pair.select(index)
		controls.pair.item_selected.emit(index)
		controls.start_selected()
		for i in 34:
			await process_frame
		var left: Node3D = controls.runners[0]
		var right: Node3D = controls.runners[1]
		okay = left.running and right.running and left.custom_animation.asset == saved.tracks.L.asset and right.custom_animation.asset == saved.tracks.R.asset
		controls.release(1)
		okay = okay and left.running and not right.running
		controls.release_all()
		okay = okay and not left.running and not right.running
	DirAccess.remove_absolute(ProjectSettings.globalize_path(test_path))
	if not okay:
		push_error("Pair selector or release buttons failed")
	quit(int(not okay))
	if okay:
		print("Pair saved in Hand Animation Editor, selected from F7 Pair preset, started together and released independently.")
