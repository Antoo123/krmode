extends SceneTree

var failed := false


func _initialize() -> void:
	run.call_deferred()


func require(ok: bool, message: String) -> void:
	if not ok:
		failed = true
		push_error(message)
	else:
		print(message)


func key(code: Key) -> void:
	var event := InputEventKey.new()
	event.keycode = code
	event.pressed = true
	root.push_input(event)


func frame() -> void:
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw


func measure(comparison, previous: bool) -> float:
	comparison.old_render.button_pressed = previous
	for i in 12:
		await RenderingServer.frame_post_draw
	var start := Time.get_ticks_usec()
	for i in 90:
		await RenderingServer.frame_post_draw
	return 90000000.0 / (Time.get_ticks_usec() - start)


func run() -> void:
	change_scene_to_file("res://room.tscn")
	await process_frame
	await process_frame
	var room = current_scene
	key(KEY_F8)
	var comparison = room.character_comparison
	require(comparison != null and comparison.visible and comparison.actor != null, "F8 opened a neutral character")
	if comparison == null:
		quit(1)
		return
	var args := OS.get_cmdline_user_args()
	comparison.load_card(args[0])
	require(comparison.card_path == args[0], "F8 loaded test card")
	comparison.zoom.select(1)
	comparison.frame_actor()
	await frame()
	await comparison.save_screenshot(args[1] + "-front.png")
	var old_vsync := DisplayServer.window_get_vsync_mode()
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	for previous in [true, false, false, true]:
		var fps := await measure(comparison, previous)
		print("F8 %s render: %.1f FPS" % ["previous" if previous else "corrected", fps])
	DisplayServer.window_set_vsync_mode(old_vsync)
	comparison.old_render.button_pressed = true
	await frame()
	await comparison.save_screenshot(args[1] + "-previous.png")
	comparison.old_render.button_pressed = false
	comparison.angle.select(1)
	comparison.frame_actor()
	comparison.outlines.button_pressed = false
	comparison.lighting.select(1)
	comparison.set_light()
	await frame()
	await comparison.save_screenshot(args[1] + "-side.png")
	comparison.outlines.button_pressed = true
	comparison.angle.select(2)
	comparison.frame_actor()
	comparison.room_background.button_pressed = true
	await frame()
	require(comparison.scenery.get_child_count() > 0, "F8 loaded the room background")
	await comparison.save_screenshot(args[1] + "-rear.png")
	var edits = preload("res://character_edit.gd")
	var garments: Dictionary = edits.slots(comparison.actor)
	if garments.has("Bra") and garments.has("Top"):
		var inner: ShaderMaterial = garments.Bra[0].get_active_material(0)
		require(inner.get_shader_parameter("use_body_mask") == true, "Skye has a garment coverage map")
		edits.set_clothes(comparison.actor, false, "Top")
		require(inner.get_shader_parameter("body_mask_weights") == Vector2.ZERO, "Removing Top releases its Bra mask")
		edits.set_clothes(comparison.actor, true, "Top")
		require(inner.get_shader_parameter("body_mask_weights") == Vector2.ONE, "Restoring Top reapplies its Bra mask")
	require(comparison.materials.item_count > 10 and comparison.maps.text.contains("×"), "F8 listed surfaces and textures")
	key(KEY_F5)
	require(not comparison.visible and room.pair_preview.is_open(), "F5 opened from F8")
	for index in room.pair_preview.list.item_count:
		room.pair_preview.play_row(index)
		if room.pair_preview.tracks.size() == 2:
			break
	require(room.pair_preview.tracks.size() == 2 and room.pair_preview.duration > 0, "F5 loaded two paired tracks")
	await frame()
	key(KEY_F6)
	require(room.studio_preview.is_open() and not room.pair_preview.is_open(), "F6 opened from F5")
	require(room.studio_preview.motions.size() > 0, "F6 loaded scene actors")
	if room.studio_preview.duration > 0:
		room.studio_preview.scrub.value = room.studio_preview.duration * 0.4
	await frame()
	key(KEY_F7)
	require(room.animation_lab != null and room.animation_lab.is_open() and not room.studio_preview.is_open(), "F7 opened from F6")
	await frame()
	quit(int(failed))
