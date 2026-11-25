extends CanvasLayer

const Card := preload("res://card_model.gd")
const CardLibrary := preload("res://card_library.gd")
const CharacterEdit := preload("res://character_edit.gd")
const Retarget := preload("res://studio_retarget.gd")
const StudioVisuals := preload("res://studio_visuals.gd")
const StudioImport := preload("res://studio_import.gd")
const Workspace := preload("res://studio_workspace.gd")
const COLOR_GRADE := preload("res://studio_color_grade.gdshader")
const SAMPLE_MAGIC := 0x3154534b
const FIRST_PERSON_HEAD_LAYER := 20
const BUNDLED := "res://Content/StudioScenes"


class Motion:
	var actor: Node3D
	var skeleton: Skeleton3D
	var key := 0
	var title := ""
	var workspace_duplicates: Array[MeshInstance3D] = []
	var joints := PackedInt32Array()
	var positions := PackedVector3Array()
	var rotations := PackedFloat32Array()
	var scales := PackedVector3Array()
	var visuals: RefCounted


var panel: PanelContainer
var viewport: SubViewport
var world: Node3D
var camera: Camera3D
var grade: ColorRect
var catalogue: OptionButton
var shots: OptionButton
var importer: Node
var import_dialog: FileDialog
var reimport: Button
var import_button: Button
var import_message: Label
var cancel_import: Button
var import_result: ConfirmationDialog
var open_manifest := ""
var current_source := ""
var views: OptionButton
var scrub: HSlider
var time_label: Label
var status: Label
var play_button: Button
var transport: Array[BaseButton] = []
var scenes: Array[String] = []
var motions: Array[Motion] = []
var current_path := ""
var current_shot := 0
var duration := 0.0
var frames := 0
var time := 0.0
var playing := false
var speed := 1.0
var mouse_before: Input.MouseMode
var room_3d_disabled := false
var focus := Vector3.ZERO
var azimuth := 0.0
var elevation := 0.15
var distance := 4.0
var dragging := false
var source_camera := Transform3D.IDENTITY
var source_fov := 0.0
var source_near := 0.025
var camera_track := PackedFloat32Array()
var scene_environment: Environment
var scenery: Node3D
var workspace: Node3D
var workspace_dialog: AcceptDialog
var workspace_tree: Tree
var workspace_refresh: Button
var casting: VBoxContainer
var card_row: HBoxContainer
var qa_button: Button
var picker: AcceptDialog
var file_picker: FileDialog
var card_buttons: Array[Button] = []
var selected_cards: Array[String] = []
var active_cards: Array[String] = []
var replacements: Array[Retarget] = []
var picker_role := 0
var neutral_rig: Skeleton3D
var scene_caption := ""
var first_person := false
var first_person_actor := -1
var active_view := 0
var contacts: Array = []
var local_motion := PackedStringArray()
var reference_landmarks := false


func _ready() -> void:
	importer = StudioImport.new()
	add_child(importer)
	importer.progress.connect(_import_progress)
	importer.finished.connect(_import_finished)
	var test_source := ""
	var test_output := ""
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--capture-studio-preview="):
			_capture_preview.call_deferred(argument.trim_prefix("--capture-studio-preview="))
		elif argument.begins_with("--studio-test-source="):
			test_source = argument.trim_prefix("--studio-test-source=")
		elif argument.begins_with("--studio-test-output="):
			test_output = argument.trim_prefix("--studio-test-output=")
	if not test_output.is_empty():
		preload("res://studio_import_smoke.gd").run.call_deferred(self, test_source, test_output)


func _capture_preview(path: String) -> void:
	var key := InputEventKey.new()
	key.keycode = KEY_F6
	key.pressed = true
	get_viewport().push_input(key)
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--studio-scene="):
			var scene_name := argument.trim_prefix("--studio-scene=")
			var match_index := -1
			for index in range(scenes.size()):
				if catalogue.get_item_text(index).get_basename() == scene_name:
					match_index = index
					break
			_load_scene(match_index)
			if match_index < 0 or current_path != scenes[match_index]:
				push_error("F6 did not load " + scene_name)
				get_tree().quit(1)
				return
	if not is_open() or motions.is_empty():
		push_error("F6 did not load a scene.")
		get_tree().quit(1)
		return
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--studio-shot="):
			var shot_index := int(argument.trim_prefix("--studio-shot="))
			if shot_index >= 0 and shot_index < shots.item_count:
				_load_scene(catalogue.selected, shot_index)
			if current_shot != shot_index:
				push_error("F6 could not load the requested shot.")
				get_tree().quit(1)
				return
	for argument in OS.get_cmdline_user_args():
		if selected_cards.size() >= 1 and argument.begins_with("--studio-character-a="):
			selected_cards[0] = argument.trim_prefix("--studio-character-a=")
		elif selected_cards.size() >= 2 and argument.begins_with("--studio-character-b="):
			selected_cards[1] = argument.trim_prefix("--studio-character-b=")
	_update_card_buttons()
	_apply_cards()
	if active_cards != selected_cards:
		push_error("F6 could not apply the capture cards. " + status.text)
		get_tree().quit(1)
		return
	_stop()
	_seek(duration * 0.5)
	var view := 4
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--studio-view="):
			view = clampi(int(argument.trim_prefix("--studio-view=")), 0, 4)
	views.select(view)
	_view_preset(view)
	for frame in range(4):
		await get_tree().process_frame
		await RenderingServer.frame_post_draw
	var result := get_viewport().get_texture().get_image().save_png(path)
	print("Studio preview capture: ", error_string(result))
	get_tree().quit(int(result != OK))


func is_open() -> bool:
	return is_instance_valid(panel) and panel.visible


func toggle() -> void:
	if not panel:
		_build()
	if is_open():
		picker.hide()
		file_picker.hide()
		import_dialog.hide()
		import_result.hide()
		workspace_dialog.hide()
		panel.hide()
		viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
		Input.mouse_mode = mouse_before
		get_viewport().disable_3d = room_3d_disabled
		dragging = false
		return
	mouse_before = Input.mouse_mode
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	room_3d_disabled = get_viewport().disable_3d
	get_viewport().disable_3d = true
	panel.show()
	viewport.render_target_update_mode = SubViewport.UPDATE_WHEN_VISIBLE
	_scan_scenes()
	if current_path.is_empty() and not scenes.is_empty():
		catalogue.select(0)
		_load_scene(0)
	if not open_manifest.is_empty():
		import_result.popup_centered(Vector2i(530, 0))


func _build() -> void:
	layer = 30
	panel = PanelContainer.new()
	panel.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(panel)
	panel.hide()

	var layout := VBoxContainer.new()
	panel.add_child(layout)
	var header := HBoxContainer.new()
	layout.add_child(header)
	catalogue = OptionButton.new()
	catalogue.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	catalogue.item_selected.connect(_load_scene)
	header.add_child(catalogue)
	shots = OptionButton.new()
	shots.item_selected.connect(func(index: int) -> void: _load_scene(catalogue.selected, index))
	header.add_child(shots)
	shots.hide()
	import_button = _button(header, "Import Scene", _choose_scene_file)
	reimport = _button(header, "Reimport Scene", _start_reimport)
	reimport.disabled = true
	_button(header, "Scene Objects", _show_workspace)
	_button(header, "Закрыть (F6)", toggle)

	var importing := HBoxContainer.new()
	layout.add_child(importing)
	import_message = Label.new()
	import_message.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	import_message.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	importing.add_child(import_message)
	cancel_import = _button(importing, "Отменить импорт", importer.cancel)
	cancel_import.hide()
	import_dialog = FileDialog.new()
	import_dialog.access = FileDialog.ACCESS_FILESYSTEM
	import_dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	import_dialog.filters = PackedStringArray(["*.png ; Сцены CharaStudio"])
	import_dialog.file_selected.connect(_start_import)
	add_child(import_dialog)
	import_result = ConfirmationDialog.new()
	import_result.title = "Импорт сцены"
	import_result.ok_button_text = "Открыть сцену"
	import_result.cancel_button_text = "Остаться здесь"
	import_result.confirmed.connect(_open_imported_scene)
	import_result.canceled.connect(func() -> void: open_manifest = "")
	add_child(import_result)
	workspace_dialog = AcceptDialog.new()
	workspace_dialog.title = "Scene Objects"
	workspace_tree = Tree.new()
	workspace_tree.columns = 2
	workspace_tree.hide_root = true
	workspace_tree.column_titles_visible = true
	workspace_tree.set_column_title(0, "Workspace")
	workspace_tree.set_column_title(1, "Состояние")
	workspace_tree.custom_minimum_size = Vector2(550, 310)
	workspace_tree.item_edited.connect(_workspace_visibility_changed)
	workspace_dialog.add_child(workspace_tree)
	workspace_refresh = workspace_dialog.add_button("Обновить объекты", true, "refresh")
	workspace_dialog.custom_action.connect(func(_action: StringName) -> void:
		workspace_dialog.hide()
		if not current_source.is_empty():
			importer.start(current_source, true, true))
	add_child(workspace_dialog)

	casting = VBoxContainer.new()
	layout.add_child(casting)
	casting.hide()
	var card_controls := HBoxContainer.new()
	casting.add_child(card_controls)
	var scroll := ScrollContainer.new()
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.custom_minimum_size.y = 43
	scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	card_controls.add_child(scroll)
	card_row = HBoxContainer.new()
	card_row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(card_row)
	_button(card_controls, "Применить", _apply_cards)
	_button(card_controls, "Вернуть исходных", _restore_cards)
	picker = CardLibrary.new()
	add_child(picker)
	picker.card_selected.connect(_choose_card)
	picker.add_button("Исходная модель", true, "original")
	picker.add_button("Выбрать файл…", true, "file")
	qa_button = picker.add_button("Test Characters / QA", true, "qa")
	picker.custom_action.connect(_browse_card)
	file_picker = FileDialog.new()
	file_picker.access = FileDialog.ACCESS_FILESYSTEM
	file_picker.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	file_picker.filters = PackedStringArray(["*.kcs, *.png ; Подготовленные карточки KKS"])
	add_child(file_picker)
	file_picker.file_selected.connect(_choose_card)

	var container := SubViewportContainer.new()
	container.stretch = true
	container.size_flags_vertical = Control.SIZE_EXPAND_FILL
	container.gui_input.connect(_camera_input)
	layout.add_child(container)
	viewport = SubViewport.new()
	viewport.own_world_3d = true
	container.add_child(viewport)
	world = Node3D.new()
	viewport.add_child(world)
	camera = Camera3D.new()
	camera.fov = 43.0
	camera.near = 0.025
	world.add_child(camera)
	camera.make_current()
	var grade_layer := CanvasLayer.new()
	viewport.add_child(grade_layer)
	grade = ColorRect.new()
	grade_layer.add_child(grade)
	grade.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	grade.mouse_filter = Control.MOUSE_FILTER_IGNORE
	grade.hide()
	var environment := WorldEnvironment.new()
	scene_environment = Environment.new()
	environment.environment = scene_environment
	scene_environment.background_mode = Environment.BG_COLOR
	scene_environment.background_color = Color("#303943")
	scene_environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	scene_environment.ambient_light_color = Color("#e7ecf4")
	scene_environment.ambient_light_energy = 0.7
	world.add_child(environment)
	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-45, 25, 0)
	light.light_energy = 0.95
	world.add_child(light)

	var controls := HBoxContainer.new()
	layout.add_child(controls)
	play_button = _button(controls, "Пуск", _toggle_play)
	transport.append(play_button)
	transport.append(_button(controls, "Стоп", _stop))
	transport.append(_button(controls, "С начала", _restart))
	var speeds := OptionButton.new()
	for factor: float in [0.1, 0.25, 0.5, 1.0, 2.0]:
		speeds.add_item("×%s" % factor)
		speeds.set_item_metadata(speeds.item_count - 1, factor)
	speeds.select(3)
	speeds.item_selected.connect(func(index: int) -> void: speed = speeds.get_item_metadata(index))
	controls.add_child(speeds)
	transport.append(speeds)
	views = OptionButton.new()
	for label: String in ["Общий", "Сбоку", "Сзади", "Крупно", "Камера CharaStudio"]:
		views.add_item(label)
	views.item_selected.connect(_view_preset)
	controls.add_child(views)
	scrub = HSlider.new()
	scrub.step = 0.001
	scrub.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scrub.value_changed.connect(_seek)
	scrub.drag_started.connect(func() -> void: _set_playing(false))
	controls.add_child(scrub)
	time_label = Label.new()
	controls.add_child(time_label)
	status = Label.new()
	layout.add_child(status)


func _button(row: HBoxContainer, caption: String, callback: Callable) -> Button:
	var button := Button.new()
	button.text = caption
	button.pressed.connect(callback)
	row.add_child(button)
	return button


func _choose_scene_file() -> void:
	var directory := String(importer.game_root()).path_join("UserData/studio/scene")
	if DirAccess.dir_exists_absolute(directory):
		import_dialog.current_dir = directory
	import_dialog.popup_centered_ratio(0.75)


func _start_import(path: String) -> void:
	importer.start(path, false)


func _start_reimport() -> void:
	if not current_source.is_empty():
		importer.start(current_source, true)


func _import_progress(message: String) -> void:
	import_message.text = message
	import_button.disabled = true
	reimport.disabled = true
	cancel_import.show()
	cancel_import.disabled = importer.cancelled


func _import_finished(result: Dictionary) -> void:
	import_button.disabled = false
	reimport.disabled = current_source.is_empty()
	cancel_import.hide()
	match result.get("status", "failed"):
		"ready":
			import_message.text = "Сцена импортирована."
		"existing":
			import_message.text = "Эта версия сцены уже в каталоге."
		"cancelled":
			import_message.text = "Импорт отменён."
		_:
			import_message.text = "Ошибка импорта. " + String(result.get("message", "Нет результата импорта."))
	import_message.tooltip_text = import_message.text
	if not result.has("manifest"):
		return
	open_manifest = String(result.manifest)
	_scan_scenes()
	var warnings := PackedStringArray(result.get("warnings", []))
	import_result.dialog_text = import_message.text
	if not warnings.is_empty():
		import_result.dialog_text += "\n\n" + "\n".join(warnings)
	if is_open():
		import_result.popup_centered(Vector2i(530, 0))


func _open_imported_scene() -> void:
	var index := scenes.find(open_manifest)
	open_manifest = ""
	if index >= 0:
		_load_scene(index)


func _show_workspace() -> void:
	workspace_tree.clear()
	var root := workspace_tree.create_item()
	workspace_refresh.disabled = current_source.is_empty() or importer.pid >= 0
	if not workspace or workspace.entries.is_empty():
		workspace_tree.create_item(root).set_text(0, "Эта версия сцены не содержит данных Workspace.")
	else:
		var rows := {}
		var ui := {}
		for row: Dictionary in workspace.entries:
			rows[int(row.key)] = row
		for key: int in rows:
			_add_workspace_row(key, rows, ui, root, {})
	workspace_dialog.popup_centered()


func _add_workspace_row(key: int, rows: Dictionary, ui: Dictionary, root: TreeItem, visiting: Dictionary) -> TreeItem:
	if ui.has(key):
		return ui[key]
	if visiting.has(key):
		return root
	visiting[key] = true
	var row: Dictionary = rows[key]
	var parent_key := int(row.get("parentKey", -1))
	var parent := _add_workspace_row(parent_key, rows, ui, root, visiting) if rows.has(parent_key) else root
	var display := workspace_tree.create_item(parent)
	var part: Variant = workspace.items.get(key)
	display.set_text(0, "%s  #%d" % [row.get("name", ""), key])
	display.set_metadata(0, key)
	if part and part.node:
		display.set_cell_mode(1, TreeItem.CELL_MODE_CHECK)
		display.set_checked(1, not part.override_hidden)
		display.set_editable(1, true)
		display.set_text(1, "Видимый" if part.visible else "Скрыт сценой")
		if not part.binding_warning.is_empty():
			display.set_tooltip_text(1, part.binding_warning)
		elif part.anchor >= 0:
			display.set_tooltip_text(1, "Привязка к #%d %s" % [part.anchor, part.bone])
	else:
		display.set_text(1, String(row.get("issue", "")) if not String(row.get("issue", "")).is_empty() else String(row.type))
	ui[key] = display
	visiting.erase(key)
	return display


func _workspace_visibility_changed() -> void:
	var row := workspace_tree.get_edited()
	if workspace and row:
		workspace.set_item_hidden(int(row.get_metadata(0)), not row.is_checked(1))


func _actor_groups(rows: Array) -> Array:
	var groups := {}
	for role in range(rows.size()):
		var group := String(rows[role].get("group", ""))
		if not groups.has(group):
			groups[group] = []
		groups[group].append(role)
	if groups.size() < 2:
		return []
	var shots_by_group: Array = [{"label": "Вся сцена"}]
	for group: String in groups:
		shots_by_group.append({"label": group if not group.is_empty() else "Без группы", "actors": groups[group]})
	return shots_by_group


func _scan_scenes() -> void:
	scenes.clear()
	catalogue.clear()
	for root: String in [BUNDLED, importer.library]:
		var directory := DirAccess.open(root)
		if not directory:
			continue
		var folders := directory.get_directories()
		folders.sort()
		if root == BUNDLED and folders.has("spanking"):
			folders.remove_at(folders.find("spanking"))
			folders.insert(0, "spanking")
		for folder: String in folders:
			if folder.begins_with("."):
				continue
			var scene_folder := root.path_join(folder)
			var item_name := ""
			var index_path := scene_folder.path_join("current.json")
			if FileAccess.file_exists(index_path):
				var pointer: Variant = JSON.parse_string(FileAccess.get_file_as_string(index_path))
				if not pointer is Dictionary or String(pointer.get("revision", "")).get_file() != pointer.get("revision"):
					continue
				scene_folder = scene_folder.path_join(pointer.revision)
				item_name = String(pointer.get("source", ""))
			var path := scene_folder.path_join("scene.json")
			if FileAccess.file_exists(path):
				scenes.append(path)
				if item_name.is_empty():
					var metadata: Variant = JSON.parse_string(FileAccess.get_file_as_string(path).trim_prefix("\ufeff"))
					item_name = String(metadata.get("source", folder + ".png")) if metadata is Dictionary else folder + ".png"
				catalogue.add_item(item_name)
	var selected := scenes.find(current_path)
	if selected < 0 and not current_source.is_empty():
		var scene_directory := current_path.get_base_dir().get_base_dir()
		for index in range(scenes.size()):
			if scenes[index].get_base_dir().get_base_dir() == scene_directory:
				selected = index
				break
	if selected >= 0:
		catalogue.select(selected)
	elif scenes.is_empty():
		status.text = "Нет подготовленных сцен CharaStudio."


func _load_scene(index: int, shot_index := 0) -> void:
	if index < 0 or index >= scenes.size():
		return
	var path := scenes[index]
	if path == current_path and shot_index == current_shot:
		return
	# Leave the previous selection in place until the new assets have loaded.
	catalogue.select(scenes.find(current_path))
	if path == current_path:
		shots.select(current_shot)
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path).trim_prefix("\ufeff"))
	if not parsed is Dictionary or parsed.get("version") != 1:
		status.text = "Не удалось прочитать " + path
		return
	var staged: Array[Motion] = []
	var count := int(parsed.get("frames", 0))
	var length := float(parsed.get("duration", 0.0))
	var rows: Variant = parsed.get("actors")
	var folder := path.get_base_dir()
	var staging: Dictionary = {}
	var staging_path := folder.path_join("staging.json")
	if FileAccess.file_exists(staging_path):
		var data: Variant = JSON.parse_string(FileAccess.get_file_as_string(staging_path))
		if data is Dictionary:
			staging = data
	var reflection_scale := 1.0
	var calibration_path := folder.path_join("visual-tuning.json")
	if FileAccess.file_exists(calibration_path):
		var calibration: Variant = JSON.parse_string(FileAccess.get_file_as_string(calibration_path))
		if calibration is Dictionary:
			reflection_scale = clampf(float(calibration.get("reflection_scale", 1.0)), 0.0, 1.0)
	if count < 1 or length < 0.0 or (count == 1) != (length == 0.0) or not rows is Array:
		status.text = "Неполный импорт сцены."
		return
	var shot_rows: Array = staging.get("shots", [])
	if shot_rows.is_empty() and parsed.has("importVersion"):
		shot_rows = _actor_groups(rows)
	var shot: Dictionary = {}
	if not shot_rows.is_empty():
		shot_index = clampi(shot_index, 0, shot_rows.size() - 1)
		shot = shot_rows[shot_index]
		var cast: Array = []
		for role: Variant in shot.get("actors", []):
			if int(role) < 0 or int(role) >= rows.size():
				status.text = "Постановка ссылается на отсутствующего персонажа."
				return
			cast.append(rows[int(role)])
		if not cast.is_empty():
			rows = cast
		if shot.get("pose", false):
			length = 0.0
	for row: Dictionary in rows:
		var motion := _load_actor(folder, row, count, reflection_scale)
		if not motion:
			for pending: Motion in staged:
				pending.actor.free()
			status.text = "Не удалось загрузить персонажа или его дорожку."
			return
		staged.append(motion)
	for motion: Motion in motions:
		world.remove_child(motion.actor)
		motion.actor.free()
	_clear_replacements()
	var keep_scenery := path == current_path
	if not keep_scenery:
		if workspace:
			workspace.free()
		workspace = Workspace.load_workspace(folder)
		if workspace:
			world.add_child(workspace)
	if scenery and not keep_scenery:
		scenery.free()
		scenery = null
	motions = staged
	for motion: Motion in motions:
		world.add_child(motion.actor)
		if workspace and not parsed.get("workspaceDetached", false):
			motion.workspace_duplicates = workspace.legacy_meshes(motion.key, motion.actor)
	current_path = path
	current_source = String(parsed.get("sourcePath", ""))
	reimport.disabled = current_source.is_empty() or importer.pid >= 0
	current_shot = shot_index
	catalogue.select(index)
	shots.clear()
	for entry: Dictionary in shot_rows:
		shots.add_item(String(entry.get("label", "Постановка %d" % (shots.item_count + 1))))
	shots.visible = shot_rows.size() > 1
	shots.select(shot_index if not shot_rows.is_empty() else -1)
	duration = length
	frames = count
	_set_color_grade(path.get_base_dir(), String(parsed.get("colorGrade", "")).get_file())
	source_fov = float(parsed.get("cameraFov", 0.0)) if shot.get("source_camera", true) else 0.0
	source_near = maxf(0.025, float(shot.get("camera_near", staging.get("camera_near", 0.025))))
	camera_track.clear()
	var track: Variant = parsed.get("cameraTrack", [])
	if track is Array and track.size() == count * 8:
		camera_track = PackedFloat32Array(track)
	var background: Dictionary = parsed.get("cameraBackground", {})
	scene_environment.background_color = Color(background.r, background.g, background.b) if background.has("r") else Color("#303943")
	if source_fov > 0.0:
		var origin: Dictionary = parsed.cameraPosition
		var rotation: Dictionary = parsed.cameraRotation
		source_camera = Transform3D(
			Basis(Quaternion(rotation.x, rotation.y, rotation.z, rotation.w).normalized()),
			Vector3(origin.x, origin.y, origin.z))
	scrub.set_value_no_signal(0.0)
	scrub.max_value = duration
	scrub.editable = duration > 0.0
	for button in transport:
		button.disabled = duration == 0.0
	var scenery_file := String(staging.get("scenery", "")).get_file()
	if not keep_scenery and not scenery_file.is_empty():
		scenery = _load_scenery(folder.path_join(scenery_file))
		if scenery:
			world.add_child(scenery)
	if staging.has("background"):
		scene_environment.background_color = Color.from_string(String(staging.background), scene_environment.background_color)
	first_person = bool(staging.get("first_person", false))
	first_person_actor = int(staging.get("first_person_actor", -1)) if first_person else -1
	reference_landmarks = bool(staging.get("reference_landmarks", false))
	contacts = shot.get("contacts", staging.get("contacts", []))
	local_motion = PackedStringArray(shot.get("local_motion", []))
	views.set_item_text(4, "От первого лица" if first_person else "Камера CharaStudio")
	views.set_item_disabled(4, source_fov <= 0.0)
	scene_caption = "%s  |  Персонажей %d  |  ПКМ — ракурс, колесо — масштаб" % [parsed.get("source", ""), motions.size()]
	if parsed.get("contactReview", false):
		scene_caption += "  |  Контакты требуют проверки" if contacts.is_empty() else ""
	status.text = scene_caption
	status.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	status.tooltip_text = scene_caption
	var warnings := PackedStringArray(parsed.get("warnings", []))
	if not warnings.is_empty():
		status.tooltip_text += "\n" + "\n".join(warnings)
	if workspace and not workspace.warnings.is_empty():
		status.tooltip_text += "\n" + "\n".join(workspace.warnings)
	_build_cast()
	casting.visible = not motions.is_empty()
	_update_card_buttons()
	active_view = 0
	_seek(0.0)
	var use_source_view := bool(shot.get("source_view",
		staging.get("source_view", first_person or parsed.has("importVersion"))))
	var default_view := 4 if use_source_view and source_fov > 0.0 else 0
	views.select(default_view)
	_view_preset(default_view)
	_set_playing(true)


func _load_scenery(path: String) -> Node3D:
	if ResourceLoader.exists(path, "PackedScene"):
		var packed := load(path) as PackedScene
		return packed.instantiate() as Node3D
	if FileAccess.file_exists(path) and path.get_extension() == "glb":
		var importer := GLTFDocument.new()
		var imported := GLTFState.new()
		if importer.append_from_file(path, imported) == OK:
			return importer.generate_scene(imported) as Node3D
	return null


func _pick_card(role: int) -> void:
	picker_role = role
	picker.show_catalog(picker.qa_cards)


func _browse_card(action: StringName) -> void:
	if action == &"qa":
		picker.show_catalog(not picker.qa_cards)
		qa_button.text = "Koikatsu Cards" if picker.qa_cards else "Test Characters / QA"
		return
	picker.hide()
	if action == &"original":
		_choose_card("")
	else:
		file_picker.popup_centered_ratio(0.7)


func _choose_card(path: String) -> void:
	if picker_role >= selected_cards.size():
		return
	selected_cards[picker_role] = path
	_update_card_buttons()


func _build_cast() -> void:
	for button in card_buttons:
		button.free()
	card_buttons.clear()
	selected_cards.resize(motions.size())
	selected_cards.fill("")
	active_cards.assign(selected_cards)
	replacements.resize(motions.size())
	for role in range(motions.size()):
		var button := _button(card_row, "", _pick_card.bind(role))
		button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		button.tooltip_text = "%s  ·  ID %d" % [motions[role].title, motions[role].key]
		card_buttons.append(button)


func _role_name(role: int) -> String:
	if motions.size() == 2:
		return ["A", "B"][role]
	return str(role + 1)


func _update_card_buttons() -> void:
	for role in range(motions.size()):
		var path := selected_cards[role]
		card_buttons[role].text = "%s · %s" % [_role_name(role),
			"Исходная модель" if path.is_empty() else path.get_file().get_basename()]


func _clear_replacements() -> void:
	for replacement: Retarget in replacements:
		if replacement:
			replacement.actor.hide()
			replacement.actor.queue_free()
	replacements.clear()
	active_cards.clear()


func _restore_cards() -> void:
	selected_cards.fill("")
	_update_card_buttons()
	_apply_cards()


func _apply_cards() -> void:
	if not casting.visible or selected_cards == active_cards:
		return
	if not neutral_rig:
		var path := "res://Content/Npc.kcs"
		neutral_rig = Card.read_rig(FileAccess.open(path, FileAccess.READ), path)
		if not neutral_rig:
			status.text = "Не удалось загрузить нейтральный скелет KKS."
			return
		add_child(neutral_rig)
	var staged := replacements.duplicate()
	for role in range(motions.size()):
		if selected_cards[role] == active_cards[role]:
			continue
		staged[role] = null
		if selected_cards[role].is_empty():
			continue
		var selection := selected_cards[role]
		var qa := selection.begins_with("qa://")
		var preset := CardLibrary.qa_preset(selection.trim_prefix("qa://")) if qa else {}
		var path := CardLibrary.qa_card(preset) if qa else selection
		var actor := Card.load_actor(path)
		if actor and qa:
			_prepare_qa_actor(actor, preset)
		var target := Retarget.new()
		if not actor or not target.setup(actor, motions[role].skeleton, neutral_rig, local_motion):
			if actor:
				actor.free()
			for pending: Retarget in staged:
				if pending and pending not in replacements:
					pending.actor.free()
			status.text = "Роль %s требует совместимую подготовленную карточку PNG или KCS." % _role_name(role)
			return
		if role == first_person_actor:
			_mark_first_person_head(actor, target.rig)
		staged[role] = target
	for role in range(motions.size()):
		if replacements[role] != staged[role]:
			if replacements[role]:
				replacements[role].actor.hide()
				replacements[role].actor.queue_free()
			if staged[role]:
				world.add_child(staged[role].actor)
		motions[role].actor.visible = staged[role] == null
	replacements.assign(staged)
	active_cards.assign(selected_cards)
	status.text = scene_caption
	var skipped := 0
	for replacement: Retarget in replacements:
		if replacement:
			skipped += replacement.skipped_accessories
	if skipped > 0:
		status.text += "  |  Скрыто аксессуаров с повреждённой привязкой: %d" % skipped
	_seek(time)


func _prepare_qa_actor(actor: Node3D, preset: Dictionary) -> void:
	if not CharacterEdit.set_clothes(actor, false):
		CharacterEdit.update_skin_masks(actor, CharacterEdit.slots(actor))
	for child in actor.get_children():
		if child is MeshInstance3D and String(child.name) in preset.get("hide", []):
			child.hide()
	var scale_factor := float(preset.get("scale", 1.0))
	if not is_equal_approx(scale_factor, 1.0):
		var rig := actor.get_node("Skeleton") as Skeleton3D
		var height := rig.find_bone(Retarget.HEIGHT)
		if height >= 0:
			var rest := rig.get_bone_rest(height)
			rest.basis = rest.basis.scaled(Vector3.ONE * scale_factor)
			rig.set_bone_rest(height, rest)
			rig.set_bone_pose_scale(height, rest.basis.get_scale())
	actor.set_meta("studio_qa_preset", true)


func _mark_first_person_head(actor: Node3D, rig: Skeleton3D) -> void:
	var head := rig.find_bone("cf_j_head")
	for part in actor.get_children():
		if part is not MeshInstance3D:
			continue
		var name := String(part.name)
		var joint := rig.find_bone(name)
		while joint >= 0 and joint != head:
			joint = rig.get_bone_parent(joint)
		if (head >= 0 and joint == head) or part.get_meta("wardrobe_slot", "") == "Hair":
			part.layers = 1 << (FIRST_PERSON_HEAD_LAYER - 1)


func _set_color_grade(folder: String, filename: String) -> void:
	grade.hide()
	grade.material = null
	if filename.is_empty():
		return
	var image := Image.new()
	if image.load_png_from_buffer(FileAccess.get_file_as_bytes(folder.path_join(filename))) != OK:
		return
	if image.get_size() != Vector2i(1024, 32):
		return
	var material := ShaderMaterial.new()
	material.shader = COLOR_GRADE
	material.set_shader_parameter("color_grade", ImageTexture.create_from_image(image))
	grade.material = material
	grade.show()


func _load_actor(folder: String, row: Dictionary, count: int, reflection_scale: float) -> Motion:
	var data := FileAccess.open(folder.path_join(String(row.get("motion", "")).get_file()), FileAccess.READ)
	if not data or data.get_32() != SAMPLE_MAGIC or data.get_32() != count:
		return null
	var bones := data.get_32()
	var tracks := data.get_32()
	if bones < 1 or tracks < 1 or tracks > bones or data.get_length() != 16 + tracks * (4 + count * 40):
		return null
	var visual_file := String(row.get("visuals", "")).get_file()
	var actor := Card.load_actor(folder.path_join(String(row.get("model", "")).get_file()), not visual_file.is_empty())
	if not actor:
		return null
	var skeleton: Skeleton3D = actor.get_node("Skeleton")
	if skeleton.get_bone_count() != bones:
		actor.free()
		return null
	var motion := Motion.new()
	motion.actor = actor
	motion.skeleton = skeleton
	motion.key = int(row.get("key", 0))
	motion.title = String(row.get("name", ""))
	if not visual_file.is_empty():
		motion.visuals = StudioVisuals.load_cache(folder.path_join(visual_file), actor, count, reflection_scale)
		if not motion.visuals:
			actor.free()
			return null
	motion.joints.resize(tracks)
	motion.positions.resize(tracks * count)
	motion.rotations.resize(tracks * count * 4)
	motion.scales.resize(tracks * count)
	for track in range(tracks):
		var joint := data.get_32()
		if joint >= bones or (track == 0 and joint != 0) or (track > 0 and joint <= motion.joints[track - 1]):
			actor.free()
			return null
		motion.joints[track] = joint
		for frame in range(count):
			var offset := track * count + frame
			motion.positions[offset] = Card.read_vector(data)
			for axis in range(4):
				motion.rotations[offset * 4 + axis] = data.get_float()
			motion.scales[offset] = Card.read_vector(data)
	return motion


func _read_rotation(motion: Motion, index: int) -> Quaternion:
	var values := motion.rotations
	var offset := index * 4
	return Quaternion(values[offset], values[offset + 1], values[offset + 2], values[offset + 3]).normalized()


func _seek(value: float) -> void:
	if frames < 1:
		return
	time = clampf(value, 0.0, duration)
	var at := time / duration * (frames - 1) if duration > 0.0 else 0.0
	var first := mini(floori(at), maxi(0, frames - 2))
	var following := mini(first + 1, frames - 1) - first
	var weight := at - first
	for motion: Motion in motions:
		for track in range(motion.joints.size()):
			var sample := track * frames + first
			var position := motion.positions[sample].lerp(motion.positions[sample + following], weight)
			var rotation := _read_rotation(motion, sample).slerp(_read_rotation(motion, sample + following), weight)
			var scale := motion.scales[sample].lerp(motion.scales[sample + following], weight)
			var joint := motion.joints[track]
			if joint == 0:
				motion.actor.transform = Transform3D(Basis(rotation) * Basis.from_scale(scale), position)
			else:
				motion.skeleton.set_bone_pose_position(joint, position)
				motion.skeleton.set_bone_pose_rotation(joint, rotation)
				motion.skeleton.set_bone_pose_scale(joint, scale)
		if motion.visuals and motion.actor.visible:
			motion.visuals.seek(at)
		for duplicate in motion.workspace_duplicates:
			duplicate.hide()
	if casting.visible and active_cards.any(func(path: String) -> bool: return not path.is_empty()):
		for role in range(motions.size()):
			if replacements[role]:
				replacements[role].apply(motions[role].actor)
				replacements[role].preserve_landmarks(not reference_landmarks or role == 0)
		for contact: Dictionary in contacts:
			_apply_contact(contact)
	if workspace:
		var rigs := {}
		var models := {}
		for role in range(motions.size()):
			if replacements[role]:
				models[motions[role].key] = replacements[role].actor
				if not workspace.anchored.is_empty():
					rigs[motions[role].key] = [motions[role].skeleton, replacements[role].rig]
		workspace.seek(time, rigs, models)
	if active_view == 4 and not camera_track.is_empty():
		_seek_camera(first, first + following, weight)
	scrub.set_value_no_signal(time)
	time_label.text = "%.3f / %.3f с" % [time, duration] if duration > 0.0 else "Статичная поза"


func _apply_contact(contact: Dictionary) -> void:
	var receiver := _contact_role(contact, "receiver")
	var mover := _contact_role(contact, "mover")
	var roles := motions.size()
	if receiver < 0 or receiver >= roles or mover < 0 or mover >= roles or receiver == mover:
		return
	if not replacements[receiver] and not replacements[mover]:
		return
	var target_a: Skeleton3D = replacements[receiver].rig if replacements[receiver] else motions[receiver].skeleton
	var target_b: Skeleton3D = replacements[mover].rig if replacements[mover] else motions[mover].skeleton
	var size: Vector3 = replacements[receiver].contact_scale if replacements[receiver] and contact.get("body_extent", false) else Vector3.ONE
	Retarget.keep_contact(motions[receiver].skeleton, motions[mover].skeleton, target_a, target_b, size, contact)


func _contact_role(contact: Dictionary, field: String) -> int:
	var key := field + "_key"
	if not contact.has(key):
		return int(contact.get(field, -1))
	for role in range(motions.size()):
		if motions[role].key == int(contact[key]):
			return role
	return -1


func _seek_camera(first: int, following: int, blend: float) -> void:
	var frame := _camera_sample(first)
	var next := _camera_sample(following)
	camera.transform = frame.interpolate_with(next, blend)
	camera.fov = lerpf(camera_track[first * 8 + 7], camera_track[following * 8 + 7], blend)


func _camera_sample(frame: int) -> Transform3D:
	var offset := frame * 8
	var t := camera_track
	var position := Vector3(t[offset], t[offset + 1], t[offset + 2])
	var rotation := Quaternion(t[offset + 3], t[offset + 4], t[offset + 5], t[offset + 6]).normalized()
	return Transform3D(Basis(rotation), position)


func _process(delta: float) -> void:
	if is_open() and playing:
		_seek(fposmod(time + delta * speed, duration))


func _set_playing(value: bool) -> void:
	playing = value and duration > 0.0
	play_button.text = "Пауза" if playing else "Пуск"


func _toggle_play() -> void:
	_set_playing(not playing)


func _stop() -> void:
	_set_playing(false)
	_seek(0.0)


func _restart() -> void:
	_seek(0.0)
	_set_playing(true)


func _view_preset(index: int) -> void:
	active_view = index
	var points: Array[Vector3] = []
	for role in range(motions.size()):
		var rig: Skeleton3D = replacements[role].rig if role < replacements.size() and replacements[role] else motions[role].skeleton
		rig.force_update_all_bone_transforms()
		for name: String in ["cf_j_head", "cf_j_hips", "cf_j_hand_L", "cf_j_hand_R", "cf_j_foot_L", "cf_j_foot_R"]:
			var joint := rig.find_bone(name)
			if joint >= 0:
				points.append(rig.to_global(rig.get_bone_global_pose(joint).origin))
	if points.is_empty() and workspace:
		for item in workspace.items.values():
			if item.node and item.visible:
				points.append(item.world_pose.origin)
	if points.is_empty():
		points.append(Vector3.ZERO)
	var bounds := AABB(points[0], Vector3.ZERO)
	for point: Vector3 in points:
		bounds = bounds.expand(point)
	focus = bounds.get_center()
	if index == 4 and source_fov > 0.0:
		camera.transform = source_camera
		camera.fov = source_fov
		camera.near = source_near
		camera.set_cull_mask_value(FIRST_PERSON_HEAD_LAYER, first_person_actor < 0)
		if not camera_track.is_empty():
			var sample := time / duration * (frames - 1) if duration > 0.0 else 0.0
			var first := floori(sample)
			_seek_camera(first, mini(first + 1, frames - 1), sample - first)
		var offset := camera.position - focus
		distance = offset.length()
		if distance > 0.0:
			elevation = asin(offset.y / distance)
			azimuth = atan2(offset.x, offset.z)
		return
	camera.fov = 43.0
	azimuth = [0.0, PI / 2.0, PI, PI / 4.0][mini(index, 3)]
	elevation = 0.15
	distance = maxf(bounds.size.length() * 1.5, 1.5)
	if index == 3:
		distance *= 0.57
	_update_camera()


func _update_camera() -> void:
	camera.near = 0.025
	camera.set_cull_mask_value(FIRST_PERSON_HEAD_LAYER, true)
	var offset := Vector3(sin(azimuth) * cos(elevation), sin(elevation), cos(azimuth) * cos(elevation))
	camera.position = focus + offset * distance
	camera.look_at(focus)


func _camera_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_RIGHT:
			dragging = event.pressed
		elif event.pressed and event.button_index in [MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN]:
			active_view = -1
			distance = clampf(distance * (0.86 if event.button_index == MOUSE_BUTTON_WHEEL_UP else 1.16), 0.22, 25.0)
			_update_camera()
	elif event is InputEventMouseMotion and (dragging or event.button_mask & MOUSE_BUTTON_MASK_MIDDLE):
		active_view = -1
		if dragging:
			azimuth -= event.relative.x * 0.006
			elevation = clampf(elevation + event.relative.y * 0.006, -1.35, 1.35)
		else:
			focus += (-camera.basis.x * event.relative.x + camera.basis.y * event.relative.y) * distance * 0.0015
		_update_camera()
