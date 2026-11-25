extends RefCounted

static func run(viewer: CanvasLayer, source: String, output: String) -> void:
	var timer := Time.get_ticks_msec()
	var input := InputEventKey.new()
	input.keycode = KEY_F6
	input.pressed = true
	viewer.get_viewport().push_input(input)
	if not viewer.is_open():
		_fail(viewer, "F6 did not open.")
		return
	var mode := ""
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--studio-test-mode="):
			mode = argument.trim_prefix("--studio-test-mode=")
	if not source.is_empty():
		viewer.import_button.pressed.emit()
		var dialog: FileDialog = viewer.import_dialog
		if not dialog.visible:
			_fail(viewer, "The scene file picker did not open.")
			return
		dialog.current_dir = source.get_base_dir()
		dialog.current_file = source.get_file()
		dialog.get_ok_button().pressed.emit()
		if viewer.importer.pid < 0:
			_fail(viewer, "The file picker did not start the import. " + viewer.import_message.text)
			return
		var result: Dictionary = await viewer.importer.finished
		print("F6 import result ", result, " time ms ", Time.get_ticks_msec() - timer)
		if mode == "reject":
			viewer.get_tree().quit(int(result.has("manifest")))
			return
		if mode == "duplicate":
			viewer.get_tree().quit(int(result.get("status") != "existing"))
			return
		if not result.has("manifest") or not viewer.import_result.visible:
			_fail(viewer, viewer.import_message.text)
			return
		viewer.import_result.get_ok_button().pressed.emit()
		if viewer.current_path != result.manifest:
			_fail(viewer, "Import completed without a readable scene.")
			return
	else:
		var wanted := output.get_file()
		var found := false
		var opened := Time.get_ticks_msec()
		for index in range(viewer.scenes.size()):
			if viewer.catalogue.get_item_text(index) == wanted:
				viewer.catalogue.item_selected.emit(index)
				found = viewer.current_path == viewer.scenes[index]
				break
		if not found:
			_fail(viewer, "Imported scene was missing after restart.")
			return
		print("F6 loaded persisted ", wanted, " with ", viewer.motions.size(), " actors.")
		if mode == "cancel-reimport":
			var original: String = viewer.current_path
			viewer.reimport.pressed.emit()
			if viewer.importer.pid < 0:
				_fail(viewer, "Reimport did not start.")
				return
			viewer.cancel_import.pressed.emit()
			var result: Dictionary = await viewer.importer.finished
			viewer._scan_scenes()
			var saved: Array[String] = viewer.scenes
			if result.get("status") != "cancelled" or original not in saved:
				_fail(viewer, "Cancellation changed the last working revision.")
				return
			print("F6 cancelled reimport and retained ", wanted)
		else:
			var load_ms := Time.get_ticks_msec() - opened
			for frame in range(12):
				await RenderingServer.frame_post_draw
			var started := Time.get_ticks_usec()
			for frame in range(45):
				await RenderingServer.frame_post_draw
			print("F6 switch ms ", load_ms, " FPS ", 45000000.0 / (Time.get_ticks_usec() - started),
				" texture MiB ", RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TEXTURE_MEM_USED) / 1048576.0)
		viewer.get_tree().quit()
		return
	var count: int = viewer.motions.size()
	if count == 0 or viewer.card_buttons.size() != count:
		_fail(viewer, "Cast did not match scene.")
		return
	print("F6 opened ", count, " actors, ", viewer.frames, " frames, ", viewer.duration, " seconds")
	viewer._set_playing(false)
	var prop_nodes := {}
	if mode == "workspace":
		if not viewer.workspace:
			_fail(viewer, "Workspace is missing.")
			return
		print("Workspace entries ", viewer.workspace.entries.size(), " samples ", viewer.workspace.frames,
			" animated ", viewer.workspace.animated.size(), " anchors ", viewer.workspace.anchored.size())
		for key in viewer.workspace.items:
			var item: Variant = viewer.workspace.items[key]
			if item.node:
				prop_nodes[key] = item.node
				print("Workspace model #", key, " anchor #", item.anchor, " bone ", item.bone)
		if prop_nodes.is_empty():
			_fail(viewer, "Workspace has no rendered models.")
			return
		viewer._show_workspace()
		if not viewer.workspace_dialog.visible:
			_fail(viewer, "Workspace diagnostic tree did not open.")
			return
		await _frame(viewer, output + "-tree.png")
		viewer.workspace_dialog.hide()
	for phase: float in [0.0, 0.25, 0.5, 0.75, 1.0]:
		viewer.scrub.value = viewer.duration * phase
		await _frame(viewer, output + "-%03d.png" % roundi(phase * 100.0))
	var cards := OS.get_executable_path().get_base_dir().path_join("Cards/Koikatsu/UserData/female/[Community]/Anon11")
	for role in range(count):
		viewer.card_buttons[role].pressed.emit()
		if not viewer.picker.visible:
			_fail(viewer, "Card picker failed for %d" % role)
			return
		viewer.picker.card_selected.emit(cards.path_join(["Jhora.png", "Arcadia.png", "Clarrise.png"][role % 3]))
		viewer.picker.hide()
		var phase: float = viewer.time
		viewer._apply_cards()
		if viewer.active_cards[role] != viewer.selected_cards[role] or viewer.time != phase:
			_fail(viewer, "Cast change failed for %d. " % role + viewer.status.text)
			return
	viewer.scrub.value = viewer.duration * 0.5
	await _frame(viewer, output + "-cast.png")
	for key in prop_nodes:
		if viewer.workspace.items[key].node != prop_nodes[key]:
			_fail(viewer, "Workspace model was replaced with the character.")
			return
	viewer._restore_cards()
	if viewer.replacements.any(func(entry: Variant) -> bool: return entry != null):
		_fail(viewer, "Original cast was not restored.")
		return
	print("F6 verified replacement and restore for all ", count, " actors.")
	viewer.get_tree().quit()


static func _frame(viewer: CanvasLayer, path: String) -> void:
	await viewer.get_tree().process_frame
	await RenderingServer.frame_post_draw
	viewer.get_viewport().get_texture().get_image().save_png(path)


static func _fail(viewer: CanvasLayer, reason: String) -> void:
	push_error(reason)
	viewer.get_tree().quit(1)
