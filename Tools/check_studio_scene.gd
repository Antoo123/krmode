extends SceneTree

const CAPTURE_TIMES := [0.0, 0.25, 0.5, 0.75, 1.0]


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var destination := OS.get_cmdline_user_args()[0]
	var room: Node3D = load("res://room.tscn").instantiate()
	root.add_child(room)
	await process_frame
	_key(KEY_F6)
	await process_frame
	var viewer: CanvasLayer = room.studio_preview
	if not viewer.is_open() or viewer.motions.size() != 2 or not viewer.playing:
		_fail("F6 did not launch and autoplay the two-actor scene. " + (viewer.status.text if viewer.is_open() else ""))
		return
	viewer._stop()
	var initial := []
	for motion in viewer.motions:
		initial.append(_joints(motion))
	var movement := [0.0, 0.0]
	var largest_step := [0.0, 0.0]
	var previous := initial.duplicate()
	for frame in range(viewer.frames):
		viewer._seek(viewer.duration * frame / (viewer.frames - 1.0))
		for actor in range(2):
			var points := _joints(viewer.motions[actor])
			if points.size() < 7:
				_fail("Missing body landmarks.")
				return
			for i in range(points.size()):
				if not points[i].is_finite():
					_fail("Non-finite bone position.")
					return
				movement[actor] = maxf(movement[actor], points[i].distance_to(initial[actor][i]))
				largest_step[actor] = maxf(largest_step[actor], points[i].distance_to(previous[actor][i]))
			previous[actor] = points
	if minf(movement[0], movement[1]) < 0.01:
		_fail("Both characters must move from their original poses.")
		return
	if DisplayServer.get_name() != "headless":
		if "--benchmark-preview" in OS.get_cmdline_user_args():
			for arg: String in OS.get_cmdline_user_args():
				if arg.begins_with("--legacy-manifest="):
					var original: int = viewer.scenes.find(viewer.current_path)
					viewer.scenes.append(arg.trim_prefix("--legacy-manifest="))
					viewer._load_scene(viewer.scenes.size() - 1)
					await _benchmark(viewer, "Legacy")
					viewer._load_scene(original)
			await _benchmark(viewer, "Current")
		if "--full-cycle" in OS.get_cmdline_user_args():
			viewer.views.select(4)
			viewer._view_preset(4)
			var started := Time.get_ticks_usec()
			for frame in range(viewer.frames + 1):
				viewer._seek(viewer.duration * (frame % viewer.frames) / (viewer.frames - 1.0))
				await process_frame
				await RenderingServer.frame_post_draw
				var path := destination.path_join("godot-cycle-%03d.png" % frame)
				if viewer.viewport.get_texture().get_image().save_png(path) != OK:
					_fail("Could not write " + path)
					return
			print("Cycle with frame readback and PNG (ms): ", (Time.get_ticks_usec() - started) / 1000.0)
		for view in [0, 1, 3, 4]:
			viewer._seek(0.0)
			viewer.views.select(view)
			viewer._view_preset(view)
			for fraction: float in CAPTURE_TIMES:
				viewer._seek(viewer.duration * fraction)
				await process_frame
				await RenderingServer.frame_post_draw
				var image: Image = root.get_texture().get_image()
				var path := destination.path_join("godot-%d-%03d.png" % [view, roundi(fraction * 100)])
				if image.save_png(path) != OK:
					_fail("Could not write " + path)
					return
	viewer.speed = 0.25
	viewer._restart()
	await process_frame
	await process_frame
	if not viewer.playing or viewer.time <= 0.0:
		_fail("Restart did not resume playback.")
		return
	viewer._toggle_play()
	var paused: float = viewer.time
	await process_frame
	if viewer.time != paused or viewer.playing:
		_fail("Pause did not hold playback.")
		return
	_key(KEY_F6)
	await process_frame
	if viewer.is_open():
		_fail("F6 did not close.")
		return
	print("F6 visual smoke passed. Actor displacement (m): ", movement, " maximum sample step (m): ", largest_step)
	quit()


func _benchmark(viewer: CanvasLayer, label: String) -> void:
	viewer._restart()
	for frame in range(30):
		await RenderingServer.frame_post_draw
	var started := Time.get_ticks_usec()
	for frame in range(120):
		await RenderingServer.frame_post_draw
	print(label, " preview FPS (120 rendered frames): ", 120000000.0 / (Time.get_ticks_usec() - started))
	viewer._stop()


func _joints(motion: RefCounted) -> PackedVector3Array:
	var result := PackedVector3Array()
	var rig: Skeleton3D = motion.skeleton
	rig.force_update_all_bone_transforms()
	for name: String in ["cf_j_hips", "cf_j_head", "cf_j_hand_L", "cf_j_hand_R", "cf_j_foot_L", "cf_j_foot_R", "cf_j_forearm01_L", "cf_j_forearm01_R"]:
		var joint := rig.find_bone(name)
		if joint >= 0:
			result.append(rig.to_global(rig.get_bone_global_pose(joint).origin))
	return result


func _key(code: Key) -> void:
	var key := InputEventKey.new()
	key.keycode = code
	key.pressed = true
	root.push_input(key)
	key = key.duplicate()
	key.pressed = false
	root.push_input(key)


func _fail(message: String) -> void:
	push_error(message)
	quit(1)
