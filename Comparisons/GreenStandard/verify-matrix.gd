extends SceneTree

const Actions := preload("res://pov_hand_actions.gd")

func _initialize() -> void:
	run.call_deferred()

func run() -> void:
	change_scene_to_file("res://room.tscn")
	for tick in 8:
		await RenderingServer.frame_post_draw
	var room: Node3D = current_scene
	var game: Node3D = room.npc_gameplay
	game.open_dialogue(game.entries[0])
	var green: Node3D = game.green
	if not green.active():
		quit(1)
		return
	room.set_physics_process(false)
	var lines := PackedStringArray(["position,action,start,mesh,body_state,additive,face,source,rule"])
	var actions := Actions.ACTIONS.keys()
	actions.append_array(green.NATIVE.keys())
	var errors := 0
	for at in green.positions.item_count:
		var id: int = green.positions.get_item_id(at)
		green.select_position(id)
		for frame in 20:
			green.tick(1.0 / 60.0)
		room.update_camera(1.0)
		for action: String in actions:
			var panel: Control = green.panel
			panel.cancel()
			var issue: String = panel.start(0, panel.preset_for(action, "L"))
			errors += int(not issue.is_empty())
			var runner: Node3D = panel.runners[0]
			var measured := false
			var actual := ""
			var reacted := false
			for tick in 40:
				green.tick(1.0 / 60.0)
				panel.draw_hands(green.actors[1], room.camera.global_transform)
				if tick % 10 == 0:
					await RenderingServer.frame_post_draw
				measured = measured or bool(runner.contact_result.get("surface", false))
				actual = green.state
				reacted = reacted or (runner.blend >= 0.94 and not green.reaction.contact_mix.angles.is_empty())
			var rule: Dictionary = green._rule(action)
			lines.append("%s,%s,%s,%s,%s,%s,%s,%s,%s" % [green.positions.get_item_text(at), action,
				issue if not issue.is_empty() else "OK", measured, actual, reacted,
				green.reaction.face.applied.get("face_id", -1), rule.get("source", ""), rule.get("reaction", "")])
			green.restart()
		print("Checked ", green.positions.get_item_text(at))
	var file := FileAccess.open(OS.get_cmdline_user_args()[0], FileAccess.WRITE)
	file.store_string("\n".join(lines) + "\n")
	file.close()
	print(lines.size()-1, " branches; start errors ", errors)
	quit(int(errors > 0))
