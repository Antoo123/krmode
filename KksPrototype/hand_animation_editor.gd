extends VBoxContainer

const Preset := preload("res://hand_animation_preset.gd")
const Gizmo := preload("res://hand_animation_gizmo.gd")
const Contact := preload("res://hand_contact_motion.gd")
const SurfaceActions := preload("res://pov_hand_actions.gd")
const AXES := ["X", "Y", "Z", "RX", "RY", "RZ"]

var lab: CanvasLayer
var gizmo := Gizmo.new()
var history := UndoRedo.new()
var bindings := ConfigFile.new()
var preset := {}
var source := ""
var time := 0.0
var hand_time := 0.0
var frozen_hand := 0.0
var playing := false
var refreshing := false
var draft := Transform3D.IDENTITY
var preview_frame := Transform3D.IDENTITY
var edit_frame := Transform3D.IDENTITY
var drag_before := {}
var drag_draft := Transform3D.IDENTITY
var original: OptionButton
var library: OptionButton
var model: OptionButton
var zone: OptionButton
var positions: OptionButton
var bones: OptionButton
var bone: LineEdit
var title: LineEdit
var mode: OptionButton
var property: OptionButton
var fields: Array[SpinBox] = []
var previews: OptionButton
var seek: HSlider
var seconds: SpinBox
var duration: SpinBox
var speed: SpinBox
var looping: CheckBox
var interpolation: OptionButton
var fingers: OptionButton
var finger_speed: SpinBox
var path_toggle: CheckBox
var key_list: OptionButton
var key_time: SpinBox
var status: Label
var dialog: FileDialog
var remove_confirmation: ConfirmationDialog
var contact_controls: HFlowContainer
var contact_side: OptionButton
var amplitude: SpinBox
var contact_speed: SpinBox
var contact_sample := {}
var edit_scope: OptionButton
var edit_track: OptionButton
var surface_action_choice: OptionButton
var pair_tracks := {}
var pair_name := ""
var second_solver := Contact.new()


func _exit_tree() -> void:
	history.clear_history()
	history.free()


func setup(owner_lab: CanvasLayer) -> void:
	lab = owner_lab
	lab.stage.add_child(gizmo)
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(Preset.FOLDER))
	bindings.load(Preset.ASSIGNMENTS)
	var heading := _row()
	var title_label := _label(heading, "POV Hand Animation Editor")
	title_label.size_flags_horizontal = SIZE_EXPAND_FILL
	_button(heading, "↶", undo).tooltip_text = "Отмена"
	_button(heading, "↷", redo).tooltip_text = "Повтор"
	path_toggle = _check(heading, "Траектория", true)
	path_toggle.toggled.connect(func(_on: bool): redraw())
	_button(heading, "Закрыть", close_editor)

	var files := _row()
	original = _option(files, ["Original Animations"], _copy_original)
	original.custom_minimum_size.x = 138
	library = _option(files, ["Custom Animations"], _open_selected)
	library.custom_minimum_size.x = 140
	library.size_flags_horizontal = SIZE_EXPAND_FILL
	_button(files, "Новая", _new)
	title = LineEdit.new()
	title.placeholder_text = "Имя анимации"
	title.max_length = 96
	title.size_flags_horizontal = SIZE_EXPAND_FILL
	files.add_child(title)
	title.text_submitted.connect(func(value: String): _change("name", value.strip_edges()))
	title.focus_exited.connect(func(): _change("name", title.text.strip_edges()))
	_button(files, "Сохранить", func(): save_preset(false))
	_button(files, "Сохранить как", func(): save_preset(true))
	_button(files, "Переименовать", func(): save_preset(false))
	_button(files, "Удалить", _confirm_remove)

	var tracks := _row()
	edit_scope = _option(tracks, ["Edit Left Hand", "Edit Right Hand", "Edit Both Hands"], _edit_scope_changed)
	edit_scope.select(1)
	edit_track = _option(tracks, ["Left track", "Right track"], _switch_track)
	edit_track.hide()
	surface_action_choice = _option(tracks, ["Contact action template"], _choose_surface_action)
	for action: String in SurfaceActions.ACTIONS:
		surface_action_choice.add_item(action)
	var context := _row()
	positions = _option(context, [], func(i: int): lab._choose_caress_position(i))
	positions.custom_minimum_size.x = 124
	model = _option(context, Preset.ASSETS, _choose_model)
	model.custom_minimum_size.x = 105
	zone = _option(context, lab.ZONES, _choose_zone)
	zone.custom_minimum_size.x = 115
	bones = _option(context, [], func(i: int): _set_bone(bones.get_item_text(i)))
	bones.custom_minimum_size.x = 152
	bone = LineEdit.new()
	bone.placeholder_text = "Имя кости"
	bone.size_flags_horizontal = SIZE_EXPAND_FILL
	context.add_child(bone)
	bone.text_submitted.connect(_set_bone)

	var transform_row := _row()
	mode = _option(transform_row, ["Перемещение", "Вращение"], func(_i: int): redraw())
	mode.custom_minimum_size.x = 119
	property = _option(transform_row, ["Ключ", "Смещение", "Поправка позы"], _choose_property)
	property.custom_minimum_size.x = 121
	for index in AXES.size():
		var turn := index >= 3
		var control := _spin(transform_row, -360.0 if turn else -4.0, 360.0 if turn else 4.0,
			0.2 if turn else 0.002, 0.0, AXES[index] + " ")
		control.value_changed.connect(func(_value: float): _numeric())
		fields.append(control)
	_button(transform_row, "Сброс", _reset_transform)

	var transport := _row()
	previews = _option(transport, ["Кисть + NPC", "Только кисть", "Только NPC"], _preview_mode)
	previews.custom_minimum_size.x = 130
	_button(transport, "Play", play)
	_button(transport, "Pause", pause)
	_button(transport, "Stop", stop)
	_button(transport, "Restart", restart)
	looping = _check(transport, "Loop", true)
	looping.toggled.connect(func(on: bool): _change("loop", on))
	duration = _spin(transport, 0.1, 120.0, 0.05, 1.0, "Длит. ")
	duration.tooltip_text = "Длительность кисти, с"
	duration.prefix = ""
	duration.suffix = " с"
	duration.value_changed.connect(_duration_changed)
	speed = _spin(transport, 0.1, 4.0, 0.1, 1.0, "Скор. ")
	speed.tooltip_text = "Скорость предпросмотра"
	speed.prefix = ""
	speed.suffix = " ×"
	interpolation = _option(transport, ["Плавная", "Линейная"], func(i: int): _change("interpolation", "smooth" if i == 0 else "linear"))
	interpolation.custom_minimum_size.x = 100

	var timeline := _row()
	seconds = _spin(timeline, 0.0, 120.0, 0.01, 0.0, "с ")
	seconds.value_changed.connect(scrub)
	seek = HSlider.new()
	seek.step = 0.001
	seek.size_flags_horizontal = SIZE_EXPAND_FILL
	seek.custom_minimum_size.x = 78
	seek.value_changed.connect(scrub)
	seek.draw.connect(_draw_timeline_keys)
	timeline.add_child(seek)
	_button(timeline, "+ Ключ", add_key)
	key_list = _option(timeline, ["Ключи"], _seek_key)
	key_list.custom_minimum_size.x = 92
	key_time = _spin(timeline, 0.0, 120.0, 0.01, 0.0, "Время ")
	key_time.tooltip_text = "Новое время выбранного ключа"
	key_time.prefix = ""
	key_time.suffix = " с"
	_button(timeline, "Перенести", move_key)
	_button(timeline, "− Ключ", delete_key)

	var use := _row()
	_label(use, "Пальцы KKS")
	fingers = _option(use, [], func(i: int): _change("finger_layer", fingers.get_item_id(i)))
	fingers.size_flags_horizontal = SIZE_EXPAND_FILL
	finger_speed = _spin(use, 0.05, 8.0, 0.05, 1.0, "× ")
	finger_speed.value_changed.connect(func(value: float): _change("finger_speed", value))
	_button(use, "Импорт JSON", func(): _show_dialog(false))
	_button(use, "Экспорт JSON", func(): _show_dialog(true))
	_button(use, "Назначить в F7", assign)
	_button(use, "Снять назначение", unassign)
	contact_controls = _row()
	_label(contact_controls, "Цель NPC")
	contact_side = _option(contact_controls, ["Левая", "Правая"], _contact_side_changed)
	contact_side.custom_minimum_size.x = 98
	_label(contact_controls, "Амплитуда")
	amplitude = _spin(contact_controls, 0.0, 2.0, 0.05, 1.0, "")
	amplitude.value_changed.connect(func(value: float): _set_contact("amplitude", value))
	_label(contact_controls, "Темп действия")
	contact_speed = _spin(contact_controls, 0.1, 4.0, 0.05, 1.0, "")
	contact_speed.suffix = " ×"
	contact_speed.value_changed.connect(func(value: float): _set_contact("speed", value))
	contact_controls.hide()
	status = _label(self, "")
	status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	dialog = FileDialog.new()
	dialog.access = FileDialog.ACCESS_FILESYSTEM
	dialog.add_filter("*.json", "POV Hand Animation")
	dialog.file_selected.connect(_file_selected)
	add_child(dialog)
	remove_confirmation = ConfirmationDialog.new()
	remove_confirmation.confirmed.connect(_delete_saved)
	add_child(remove_confirmation)
	hide()


func open_editor() -> void:
	if not lab.stage.green_hands.enabled or not lab.stage.actors[1] or lab.stage.duration <= 0.0:
		return
	lab.pause()
	lab._cancel_hand()
	lab.independent_hands.activate(false)
	lab.transport.hide()
	lab.details.hide()
	lab.playback_status.hide()
	_rebuild_positions()
	show()
	if preset.is_empty():
		_new()
	else:
		_refresh()
	_refresh_library()
	status.text = "ЛКМ · выбрать кисть или потянуть ось. ПКМ · камера. + Ключ записывает позу в текущем времени."
	lab.inspector_scroll.custom_minimum_size.y = 345
	lab.inspector_scroll.scroll_vertical = 0
	redraw()


func close_editor() -> void:
	if not visible:
		return
	_end_drag()
	pause()
	hide()
	lab.transport.show()
	lab.details.show()
	lab.playback_status.show()
	gizmo.hide()
	lab.stage.green_hands.editor_preview = {}
	lab.stage.green_hands.second_editor_preview = {}
	lab.independent_hands.activate(lab.independent_switch.button_pressed and lab.stage.green_hands.enabled)
	lab.inspector_scroll.custom_minimum_size.y = 290 if lab.stage.green_hands.enabled else 170
	lab.stage.update_view()


func context_changed() -> void:
	if not visible:
		return
	if not lab.stage.green_hands.enabled:
		close_editor()
		return
	_rebuild_positions()
	_refresh()


func redraw() -> void:
	if not visible or preset.is_empty() or not lab.stage.green_hands.enabled or not is_instance_valid(lab.stage.actors[1]):
		return
	var hands: Node3D = lab.stage.green_hands
	var id := Preset.ASSETS.find(preset.asset)
	var rig: Skeleton3D = lab.stage.actors[1].get_node("Skeleton")
	rig.force_update_all_bone_transforms()
	hands.second_editor_preview = {}
	if not pair_tracks.is_empty() and edit_scope.selected == 2:
		_preview_other(hands)
	if preset.has("contact"):
		_redraw_contact(hands, id)
		return
	var resolved: Array = hands.contact_frame(rig, preset.bone, preset.zone)
	if resolved.is_empty():
		hands.editor_preview = {}
		gizmo.hide()
		status.text = "Кость «%s» недоступна у выбранной карточки." % preset.bone
		lab.stage.update_view()
		return
	var socket: Transform3D = resolved[0]
	socket.basis = socket.basis.orthonormalized()
	var offset := Preset.transform(preset.offset)
	var position_fix: Variant = preset.positions.get(str(hands.pose_id))
	var fix := Preset.transform(position_fix) if position_fix is Dictionary else Transform3D.IDENTITY
	var sampled := Preset.sample(preset, hand_time)
	edit_frame = socket * offset * fix
	if property.selected == 0:
		preview_frame = edit_frame * draft
	elif property.selected == 1:
		edit_frame = socket
		preview_frame = socket * draft * fix * sampled
	else:
		edit_frame = socket * offset
		preview_frame = edit_frame * draft * sampled
	hands.editor_preview = {"id": id, "world": preview_frame, "layer": int(preset.finger_layer),
		"time": hand_time, "rate": float(preset.finger_speed)}
	lab.stage.update_view()
	var trajectory := PackedVector3Array()
	var points := PackedVector3Array()
	if path_toggle.button_pressed and not preset.keys.is_empty():
		var root := socket * offset * fix
		for index in range(49):
			trajectory.append((root * Preset.sample(preset, float(preset.duration) * index / 48.0)).origin)
		for key: Dictionary in preset.keys:
			points.append((root * Preset.transform(key)).origin)
	gizmo.redraw(lab.stage.camera, preview_frame, edit_frame.basis.orthonormalized(), mode.selected == 1, trajectory, points)


func _preview_other(hands: Node3D) -> void:
	var side := "R" if String(preset.asset).ends_with("L") else "L"
	var track: Dictionary = pair_tracks[side]
	var id := Preset.ASSETS.find(track.asset)
	var sample_time := minf(time, float(track.duration))
	var local := Preset.adjustment(track, hands.pose_id) * Preset.contact_key(track, Preset.sample(track, sample_time))
	var result: Dictionary = hands.evaluate_contact(lab.stage.actors[1], id, track, local, sample_time,
		Contact.weight(track, sample_time), second_solver)
	if not result.is_empty():
		hands.second_editor_preview = {"id": id, "world": result.world, "contact": track.contact}


func _redraw_contact(hands: Node3D, id: int) -> void:
	lab.stage.camera.global_transform = hands.editor_contact_camera(lab.stage.actors[1], preset.contact)
	var offset := Preset.transform(preset.offset)
	var correction: Variant = preset.positions.get(str(hands.pose_id))
	var fix := Preset.transform(correction) if correction is Dictionary else Transform3D.IDENTITY
	var key := draft if property.selected == 0 else Preset.sample(preset, hand_time)
	if property.selected == 1:
		offset = draft
	elif property.selected == 2:
		fix = draft
	var amount := Contact.weight(preset, hand_time)
	if gizmo.axis >= 0:
		amount = 1.0
	contact_sample = hands.evaluate_contact(lab.stage.actors[1], id, preset,
		offset * fix * Preset.contact_key(preset, key), hand_time, amount)
	if contact_sample.is_empty():
		hands.editor_preview = {}
		gizmo.hide()
		status.text = "У выбранной карточки нет точки контакта."
		return
	preview_frame = contact_sample.world
	var socket: Transform3D = contact_sample.anchor
	edit_frame = socket if property.selected == 1 else socket * offset
	if property.selected == 0:
		edit_frame *= fix
	hands.editor_preview = {"id": id, "world": preview_frame, "sampled": true, "contact": preset.contact}
	lab.stage.update_view()
	var path := PackedVector3Array()
	var keys := PackedVector3Array()
	if path_toggle.button_pressed:
		var root := socket * offset * fix
		for index in range(33):
			var sample := Preset.sample(preset, float(preset.duration) * index / 32.0)
			path.append((root * Preset.contact_key(preset, sample)).origin)
		for value: Dictionary in preset.keys:
			keys.append((root * Preset.contact_key(preset, Preset.transform(value))).origin)
	gizmo.redraw(lab.stage.camera, preview_frame, edit_frame.basis, mode.selected == 1, path, keys)


func pointer(event: InputEvent) -> bool:
	if not visible:
		return false
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			pause()
			if gizmo.begin(lab.stage.camera, event.position, draft):
				drag_before = preset.duplicate(true)
				drag_draft = draft
			else:
				_pick_hand(event.position)
		else:
			_end_drag()
		return true
	if event is InputEventMouseMotion and gizmo.axis >= 0:
		draft = gizmo.drag(event.position)
		_sync_fields()
		redraw()
		return true
	return false


func _pick_hand(screen: Vector2) -> void:
	var hands: Node3D = lab.stage.green_hands
	var camera: Camera3D = lab.stage.camera
	var best := 27.0
	var chosen := -1
	for index in hands.items.size():
		var tool: Variant = hands.items[index]
		if not tool.node.visible:
			continue
		var wrist: Vector3 = tool.node.global_transform * tool.rig.get_bone_global_pose(tool.wrist).origin
		var tip_id: int = tool.rig.find_bone("cf_j_middle03_" + String(Preset.ASSETS[index]).right(1))
		var tip: Vector3 = tool.node.global_transform * tool.rig.get_bone_global_pose(tip_id).origin
		if camera.is_position_behind(wrist) or camera.is_position_behind(tip):
			continue
		var distance := Geometry2D.get_closest_point_to_segment(screen, camera.unproject_position(wrist),
			camera.unproject_position(tip)).distance_to(screen)
		if distance < best:
			best = distance
			chosen = index
	if chosen >= 0 and chosen != model.selected:
		if not pair_tracks.is_empty() and edit_scope.selected == 2 and chosen % 2 != model.selected % 2:
			_switch_track(chosen % 2)
		else:
			_choose_model(chosen)


func _end_drag() -> void:
	if gizmo.axis < 0:
		return
	gizmo.finish()
	_finish_transform(drag_before, drag_draft)
	drag_before = {}
	redraw()


func _finish_transform(before: Dictionary, old_pose: Transform3D) -> void:
	if property.selected == 0:
		if not old_pose.is_equal_approx(draft):
			history.create_action("Трансформация кисти")
			history.add_do_method(_set_draft.bind(draft))
			history.add_undo_method(_set_draft.bind(old_pose))
			history.commit_action()
		return
	var updated := preset.duplicate(true)
	if property.selected == 1:
		updated.offset = Preset.frame(0.0, draft)
	else:
		updated.positions[str(lab.stage.green_hands.pose_id)] = Preset.frame(0.0, draft)
	_commit(updated, "Смещение", before)


func _numeric() -> void:
	if refreshing:
		return
	var p := Vector3(fields[0].value, fields[1].value, fields[2].value)
	var r := Vector3(fields[3].value, fields[4].value, fields[5].value) * (PI / 180.0)
	var old := draft
	draft = Transform3D(Basis.from_euler(r), p)
	_finish_transform(preset, old)
	redraw()


func _reset_transform() -> void:
	var old := draft
	draft = Transform3D.IDENTITY
	_sync_fields()
	_finish_transform(preset, old)
	redraw()


func _set_draft(value: Transform3D) -> void:
	property.select(0)
	draft = value
	_sync_fields()
	redraw()


func _sync_fields() -> void:
	var values := Preset.frame(0.0, draft)
	for index in fields.size():
		fields[index].set_value_no_signal(values.position[index] if index < 3 else values.rotation[index - 3])


func _choose_property(_index: int) -> void:
	if preset.is_empty():
		return
	match property.selected:
		0: draft = Preset.sample(preset, hand_time)
		1: draft = Preset.transform(preset.offset)
		2:
			var value: Variant = preset.positions.get(str(lab.stage.green_hands.pose_id))
			draft = Preset.transform(value) if value is Dictionary else Transform3D.IDENTITY
	_sync_fields()
	redraw()


func _choose_model(index: int) -> void:
	if refreshing:
		return
	var updated := preset.duplicate(true)
	if not pair_tracks.is_empty() and String(Preset.ASSETS[index]).right(1) != String(preset.asset).right(1):
		model.select(Preset.ASSETS.find(preset.asset))
		return
	updated.asset = Preset.ASSETS[index]
	updated.finger_layer = 0
	_commit(updated, "Модель кисти")


func _choose_zone(index: int) -> void:
	if refreshing:
		return
	var updated := preset.duplicate(true)
	updated.zone = index
	updated.bone = _suggest_bone(index, updated.asset)
	_commit(updated, "Зона")


func _set_bone(value: String) -> void:
	if value.strip_edges().is_empty() or value.length() > 160:
		return
	var rig: Skeleton3D = lab.stage.actors[1].get_node("Skeleton")
	if lab.stage.green_hands.contact_frame(rig, value.strip_edges(), preset.zone).is_empty():
		status.text = "Кость «%s» не найдена." % value
		return
	_change("bone", value.strip_edges())


func _suggest_bone(area: int, asset: String) -> String:
	var id := Preset.ASSETS.find(asset)
	var table := "aibulayer_%02d" % area
	for entry: Dictionary in lab.data.get("actions", []):
		if entry.table == table:
			for index in mini(entry.raw.idObjects.size(), entry.raw.nameParents.size()):
				if int(entry.raw.idObjects[index]) == id and not String(entry.raw.nameParents[index]).is_empty():
					return entry.raw.nameParents[index]
	return lab.stage.green_hands.FALLBACK[area]


func _rebuild_positions() -> void:
	positions.clear()
	for index in lab.caress_positions.item_count:
		positions.add_item(lab.caress_positions.get_item_text(index), lab.caress_positions.get_item_id(index))
	positions.select(positions.get_item_index(int(lab.row.get("id", -1))))


func _new() -> void:
	var selected := int(lab.zone.selected)
	var asset := "p_handR" if preset.is_empty() else String(preset.asset)
	var value := Preset.create(asset, selected, _suggest_bone(selected, asset))
	var rig: Skeleton3D = lab.stage.actors[1].get_node("Skeleton")
	var resolved: Array = lab.stage.green_hands.contact_frame(rig, value.bone, selected)
	var initial := Transform3D.IDENTITY
	if not resolved.is_empty():
		var attachment: Transform3D = resolved[0]
		var camera: Camera3D = lab.stage.camera
		var outward := (camera.global_position - attachment.origin).normalized() * 0.15
		initial.origin = attachment.basis.orthonormalized().inverse() * outward
	value.keys = [Preset.frame(0.0, initial)]
	_load(value, "")


func _copy_original(index: int) -> void:
	if index == 0:
		return
	var layer := original.get_item_id(index)
	var value := Preset.create(preset.asset, preset.zone, preset.bone)
	value.name = original.get_item_text(index) + " · копия"
	value.finger_layer = layer
	value.duration = maxf(0.1, lab.stage.green_hands.finger_length(model.selected, layer))
	value.keys = [Preset.frame(0.0, Transform3D.IDENTITY), Preset.frame(value.duration, Transform3D.IDENTITY)]
	_load(value, "")
	status.text = "Создана копия с исходным клипом кисти. Перемещение и поворот добавляются ключами."


func _open_selected(index: int) -> void:
	var path := String(library.get_item_metadata(index))
	if path.is_empty():
		return
	var value := Preset.read(path)
	if not value.is_empty():
		_load(value, path)
	else:
		status.text = "Пресет повреждён или формат не поддерживается."


func _edit_scope_changed(index: int) -> void:
	if preset.is_empty():
		return
	if index == 2:
		if pair_tracks.is_empty():
			source = ""
			pair_name = (String(preset.name) + " (both)").left(96)
			pair_tracks = {"L": SurfaceActions.make("stroke_left_side", "L"), "R": SurfaceActions.make("take_hand", "R")}
			if preset.has("contact"):
				pair_tracks[String(preset.asset).right(1)] = preset.duplicate(true)
			else:
				preset = pair_tracks[String(preset.asset).right(1)].duplicate(true)
			history.clear_history()
		edit_track.select(0 if String(preset.asset).ends_with("L") else 1)
	elif not pair_tracks.is_empty():
		_switch_track(index)
	elif String(preset.asset).right(1) != ("L" if index == 0 else "R"):
		_choose_model(Preset.ASSETS.find(preset.asset) ^ 1)
	_refresh()


func _switch_track(index: int) -> void:
	if pair_tracks.is_empty():
		return
	var side := "L" if index == 0 else "R"
	pair_tracks[String(preset.asset).right(1)] = preset.duplicate(true)
	preset = pair_tracks[side].duplicate(true)
	title.text = pair_name
	history.clear_history()
	edit_track.select(index)
	_refresh()


func _choose_surface_action(index: int) -> void:
	if index == 0 or preset.is_empty():
		return
	var value := surface_action(surface_action_choice.get_item_text(index), String(preset.asset).right(1))
	if value.is_empty():
		return
	if pair_tracks.is_empty():
		_load(value, "")
	else:
		_commit(value, "Contact action")


func _serialized(name: String) -> Dictionary:
	var value := preset.duplicate(true)
	if pair_tracks.is_empty():
		value.name = name
		return value
	var tracks := pair_tracks.duplicate(true)
	tracks[String(value.asset).right(1)] = value
	return {"version": 2, "name": name, "tracks": tracks}


func _load(value: Dictionary, path: String) -> void:
	pause()
	pair_tracks = value.tracks.duplicate(true) if int(value.version) == 2 else {}
	if not pair_tracks.is_empty():
		pair_name = value.name
		value = pair_tracks["L"]
		edit_scope.select(2)
	else:
		edit_scope.select(0 if String(value.asset).ends_with("L") else 1)
	source = path
	time = 0.0
	hand_time = 0.0
	history.clear_history()
	preset = value.duplicate(true)
	_refresh()


func _change(key: String, value: Variant) -> void:
	if key == "name" and not pair_tracks.is_empty() and not refreshing and not String(value).is_empty():
		pair_name = String(value)
		return
	if refreshing or preset.is_empty() or preset[key] == value:
		return
	if key == "name" and String(value).is_empty():
		return
	var updated := preset.duplicate(true)
	updated[key] = value
	_commit(updated, key)


func _commit(value: Dictionary, label: String, old := {}) -> void:
	var before: Dictionary = preset if old.is_empty() else old
	if value == before:
		return
	history.create_action(label)
	history.add_do_method(_restore.bind(value))
	history.add_undo_method(_restore.bind(before))
	history.commit_action()


func _restore(value: Dictionary) -> void:
	preset = value.duplicate(true)
	_refresh()


func undo() -> void:
	pause()
	if not history.undo():
		_choose_property(property.selected)


func redo() -> void:
	pause()
	history.redo()


func _refresh() -> void:
	refreshing = true
	title.text = preset.name if pair_tracks.is_empty() else pair_name
	edit_track.visible = not pair_tracks.is_empty() and edit_scope.selected == 2
	edit_track.select(0 if String(preset.asset).ends_with("L") else 1)
	model.select(Preset.ASSETS.find(preset.asset))
	zone.select(int(preset.zone))
	var has_contact := preset.has("contact")
	zone.disabled = has_contact
	bones.disabled = has_contact
	bone.editable = not has_contact
	contact_controls.visible = has_contact
	if has_contact:
		contact_side.select(0 if preset.contact.side == "L" else 1)
		contact_side.disabled = preset.contact.kind in ["belly", "crown", "chin"]
		amplitude.set_value_no_signal(preset.contact.amplitude)
		contact_speed.set_value_no_signal(preset.contact.speed)
	bone.text = preset.bone
	bones.clear()
	var choices := _suggest_bone(zone.selected, preset.asset)
	for name: String in [choices, lab.stage.green_hands.FALLBACK[zone.selected], preset.bone, "cf_j_hips", "cf_j_spine03", "cf_j_head"]:
		if name not in _item_texts(bones):
			bones.add_item(name)
	bones.select(_item_texts(bones).find(preset.bone))
	original.clear()
	original.add_item("Original Animations", -1)
	fingers.clear()
	fingers.add_item("Покой", 99)
	for layer: int in lab.stage.green_hands.finger_layers(model.selected):
		var caption: String = lab.stage.green_hands.item_label(model.selected, layer)
		original.add_item(caption, layer)
		fingers.add_item(caption, layer)
	var finger_index := fingers.get_item_index(int(preset.finger_layer))
	fingers.select(maxi(0, finger_index))
	duration.set_value_no_signal(preset.duration)
	finger_speed.set_value_no_signal(preset.finger_speed)
	looping.set_pressed_no_signal(preset.loop)
	interpolation.select(0 if preset.interpolation == "smooth" else 1)
	_sync_timeline()
	_refresh_keys()
	refreshing = false
	_choose_property(property.selected)


func _item_texts(list: OptionButton) -> PackedStringArray:
	var result := PackedStringArray()
	for index in list.item_count:
		result.append(list.get_item_text(index))
	return result


func _refresh_keys() -> void:
	key_list.clear()
	key_list.add_item("Ключи · %d" % preset.keys.size())
	for key: Dictionary in preset.keys:
		key_list.add_item("%.3f с" % key.time)
	var index := _key_at(hand_time)
	key_list.select(index + 1)
	key_time.set_value_no_signal(hand_time)
	seek.queue_redraw()


func _draw_timeline_keys() -> void:
	if preset.is_empty() or previews.selected == 2:
		return
	var span := maxf(0.0, seek.size.x - 14.0)
	for key: Dictionary in preset.keys:
		var x := 7.0 + span * float(key.time) / float(preset.duration)
		var at := Vector2(x, seek.size.y * 0.5 + 7.0)
		seek.draw_line(at, at + Vector2(0.0, 5.0), Color("#ffd875"), 2.0, true)


func _key_at(at: float) -> int:
	for index in preset.keys.size():
		if absf(float(preset.keys[index].time) - at) < 0.0005:
			return index
	return -1


func add_key() -> void:
	pause()
	var updated := preset.duplicate(true)
	var index := _key_at(hand_time)
	var pose := draft if property.selected == 0 else Preset.sample(preset, hand_time)
	var new_key := Preset.frame(hand_time, pose)
	if index < 0:
		if updated.keys.size() >= 1000:
			status.text = "Достигнут лимит в 1000 ключей."
			return
		updated.keys.append(new_key)
	else:
		updated.keys[index] = new_key
	_sort_keys(updated)
	_commit(updated, "Ключ")


func move_key() -> void:
	var index := key_list.selected - 1
	if index < 0:
		return
	var updated := preset.duplicate(true)
	var at := clampf(key_time.value, 0.0, float(preset.duration))
	var other := _key_at(at)
	if other >= 0 and other != index:
		status.text = "На этом времени уже есть ключ."
		return
	updated.keys[index].time = at
	_sort_keys(updated)
	_commit(updated, "Время ключа")
	scrub(at)


func delete_key() -> void:
	var index := key_list.selected - 1
	if index >= 0:
		var updated := preset.duplicate(true)
		updated.keys.remove_at(index)
		_commit(updated, "Удаление ключа")


func _sort_keys(value: Dictionary) -> void:
	value.keys.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return float(a.time) < float(b.time))


func _seek_key(index: int) -> void:
	if index > 0:
		if previews.selected == 2:
			previews.select(0)
		scrub(float(preset.keys[index - 1].time))


func _duration_changed(value: float) -> void:
	if preset.has("contact") and value <= float(preset.contact.approach) + float(preset.contact.release) + 0.05:
		duration.set_value_no_signal(preset.duration)
		status.text = "Оставьте время для действия между подходом и возвратом."
		return
	if not preset.keys.is_empty() and value < float(preset.keys[-1].time):
		duration.set_value_no_signal(preset.duration)
		status.text = "Сначала перенесите последний ключ внутрь новой длительности."
		return
	_change("duration", value)


func _contact_side_changed(index: int) -> void:
	_set_contact("side", "L" if index == 0 else "R")


func _set_contact(key: String, value: Variant) -> void:
	if refreshing or not preset.has("contact"):
		return
	var updated := preset.duplicate(true)
	if key == "side" and updated.contact.kind == "cheek" and updated.contact.side != value:
		for point: Dictionary in updated.keys:
			point.position[0] = -float(point.position[0])
	updated.contact[key] = value
	updated.bone = Contact.bone_name(updated.contact)
	_commit(updated, key)


func _max_time() -> float:
	if previews.selected == 2:
		return maxf(0.1, lab.stage.duration)
	var length := float(preset.duration)
	if not pair_tracks.is_empty() and edit_scope.selected == 2:
		var side := "R" if String(preset.asset).ends_with("L") else "L"
		length = maxf(length, float(pair_tracks[side].duration))
	return length


func _sync_timeline() -> void:
	time = clampf(time, 0.0, _max_time())
	seek.max_value = _max_time()
	seconds.max_value = _max_time()
	key_time.max_value = preset.duration
	seek.set_value_no_signal(time)
	seconds.set_value_no_signal(time)


func _preview_mode(_index: int) -> void:
	frozen_hand = hand_time
	_sync_timeline()
	_set_time(time)


func scrub(value: float) -> void:
	if refreshing:
		return
	pause()
	_set_time(value)
	_refresh_keys()


func _set_time(value: float) -> void:
	time = clampf(value, 0.0, _max_time())
	seek.set_value_no_signal(time)
	seconds.set_value_no_signal(time)
	hand_time = frozen_hand if previews.selected == 2 else minf(time, preset.duration)
	if property.selected == 0:
		draft = Preset.sample(preset, hand_time)
		_sync_fields()
	if previews.selected != 1 and lab.stage.duration > 0.0:
		var npc_phase := time / float(lab.stage.duration)
		if lab.loop.button_pressed and npc_phase > 1.0:
			npc_phase = fposmod(npc_phase, 1.0)
		lab._seek(npc_phase)
	else:
		redraw()


func play() -> void:
	lab.pause()
	if time >= _max_time():
		_set_time(0.0)
	playing = true


func pause() -> void:
	playing = false


func stop() -> void:
	pause()
	_set_time(0.0)
	_refresh_keys()


func restart() -> void:
	stop()
	play()


func advance(delta: float) -> void:
	if not playing:
		return
	var next := time + delta * speed.value * float(preset.get("contact", {}).get("speed", 1.0))
	if next >= _max_time():
		if looping.button_pressed:
			next = fposmod(next, _max_time())
		else:
			pause()
	_set_time(next)


func save_preset(copy: bool) -> bool:
	var name := title.text.strip_edges()
	if name.is_empty():
		status.text = "Введите имя пресета."
		return false
	var path := source if not copy and source.begins_with(Preset.FOLDER + "/") else ""
	if path.is_empty():
		path = Preset.FOLDER.path_join(Crypto.new().generate_random_bytes(12).hex_encode() + ".json")
	var value := _serialized(name)
	if Preset.validate(value).is_empty():
		status.text = "Invalid tracks or timing."
		return false
	var result := Preset.store(path, value)
	if result != OK:
		status.text = "Ошибка записи · %s" % error_string(result)
		return false
	if pair_tracks.is_empty():
		preset.name = name
	else:
		pair_name = name
	source = path
	lab.independent_hands.refresh_pairs()
	_refresh_library()
	status.text = "Сохранено · " + name
	return true


func _refresh_library() -> void:
	library.clear()
	library.add_item("Custom Animations")
	library.set_item_metadata(0, "")
	var rows := []
	for folder in [Preset.FOLDER, Preset.EXAMPLES]:
		for file in DirAccess.get_files_at(folder):
			if not file.ends_with(".json"):
				continue
			var path: String = folder.path_join(file)
			var value := Preset.read(path)
			if not value.is_empty():
				rows.append([String(value.name), path])
	rows.sort_custom(func(a: Array, b: Array) -> bool: return a[0].naturalnocasecmp_to(b[0]) < 0)
	for entry: Array in rows:
		var index := library.item_count
		library.add_item(entry[0])
		library.set_item_metadata(index, entry[1])
		if source == entry[1]:
			library.select(index)


func _confirm_remove() -> void:
	if not source.begins_with(Preset.FOLDER + "/"):
		status.text = "Удалить можно сохранённый пользовательский пресет."
		return
	remove_confirmation.dialog_text = "Удалить «%s»?" % preset.name
	remove_confirmation.popup_centered()


func _delete_saved() -> void:
	if not source.begins_with(Preset.FOLDER + "/"):
		return
	if DirAccess.remove_absolute(ProjectSettings.globalize_path(source)) != OK:
		status.text = "Не удалось удалить файл."
		return
	for section in ["actions", "contacts", "surface_actions", "pair_actions"]:
		if bindings.has_section(section):
			for key: String in bindings.get_section_keys(section):
				if bindings.get_value(section, key) == source:
					bindings.erase_section_key(section, key)
	bindings.save(Preset.ASSIGNMENTS)
	_new()
	_refresh_library()
	status.text = "Пресет удалён."


func _show_dialog(export: bool) -> void:
	dialog.file_mode = FileDialog.FILE_MODE_SAVE_FILE if export else FileDialog.FILE_MODE_OPEN_FILE
	dialog.title = "Экспорт пресета" if export else "Импорт пресета"
	dialog.current_file = "hand-animation.json" if export else ""
	dialog.popup_centered_ratio(0.65)


func _file_selected(path: String) -> void:
	if dialog.file_mode == FileDialog.FILE_MODE_SAVE_FILE:
		var value := _serialized(title.text.strip_edges())
		if Preset.validate(value).is_empty():
			status.text = "Invalid tracks or timing."
			return
		var result := Preset.store(path if path.ends_with(".json") else path + ".json", value)
		status.text = "JSON экспортирован." if result == OK else error_string(result)
		return
	var value := Preset.read(path)
	if value.is_empty():
		status.text = "Не удалось прочитать JSON пресета."
		return
	_load(value, "")
	save_preset(true)


func _action_key(id: int, area: int, action_id: int, side: int, variant: int) -> String:
	return "%d/%d/%d/%d/%d" % [area, action_id, side, variant, id]


func _selected_action_key() -> String:
	if lab.action.selected < 0 or lab.zone.selected != int(preset.zone):
		return ""
	var action: Dictionary = lab.action.get_item_metadata(lab.action.selected)
	var id := Preset.ASSETS.find(preset.asset)
	for tool: Variant in action.idObjects:
		if int(tool) == id:
			return _action_key(id, lab.zone.selected, action.id, lab.side.selected, lab.variation.selected)
	return ""


func assign() -> void:
	if not pair_tracks.is_empty():
		if save_preset(false):
			bindings.set_value("pair_actions", "start", source)
			var issue := bindings.save(Preset.ASSIGNMENTS)
			status.text = "Assigned to Start selected in F7." if issue == OK else error_string(issue)
			var option: OptionButton = lab.independent_hands.pair
			for i in option.item_count:
				if option.get_item_metadata(i) == source:
					option.select(i)
					lab.independent_hands._select_pair(i)
					break
		return
	if preset.has("action"):
		if save_preset(false):
			bindings.set_value("surface_actions", _surface_key(preset.action, String(preset.asset).right(1)), source)
			var issue := bindings.save(Preset.ASSIGNMENTS)
			status.text = "Assigned to " + String(preset.action) if issue == OK else error_string(issue)
		return
	if preset.has("contact"):
		if save_preset(false):
			bindings.set_value("contacts", preset.contact.kind, source)
			var result := bindings.save(Preset.ASSIGNMENTS)
			status.text = "Назначено действию %s." % Contact.NAMES[preset.contact.kind] if result == OK else error_string(result)
		return
	var key := _selected_action_key()
	if key.is_empty():
		status.text = "Ниже в F7 выберите действие с зоной и моделью текущего пресета."
		return
	if not save_preset(false):
		return
	bindings.set_value("actions", key, source)
	var error := bindings.save(Preset.ASSIGNMENTS)
	status.text = "Назначено выбранному действию F7." if error == OK else error_string(error)


func unassign() -> void:
	if not pair_tracks.is_empty() or preset.has("action"):
		var section := "pair_actions" if not pair_tracks.is_empty() else "surface_actions"
		var key := "start" if not pair_tracks.is_empty() else _surface_key(preset.action, String(preset.asset).right(1))
		if bindings.has_section_key(section, key):
			bindings.erase_section_key(section, key)
			var issue := bindings.save(Preset.ASSIGNMENTS)
			status.text = "Assignment removed." if issue == OK else error_string(issue)
		return
	if preset.has("contact"):
		if bindings.has_section_key("contacts", preset.contact.kind):
			bindings.erase_section_key("contacts", preset.contact.kind)
			var result := bindings.save(Preset.ASSIGNMENTS)
			status.text = "Назначение снято." if result == OK else error_string(result)
		return
	var key := _selected_action_key()
	if not key.is_empty() and bindings.has_section_key("actions", key):
		bindings.erase_section_key("actions", key)
		var error := bindings.save(Preset.ASSIGNMENTS)
		status.text = "Назначение снято." if error == OK else error_string(error)


func _surface_key(action: String, side: String) -> String:
	return action + "/" + side


func surface_action(action: String, side: String) -> Dictionary:
	var value := Preset.bound_surface(bindings, action, side)
	return SurfaceActions.make(action, side) if value.is_empty() else value


func contact_action(kind: String) -> Dictionary:
	return Preset.bound_contact(bindings, kind)


func assigned(id: int, area: int, action_id: int, side: int, variant: int) -> Dictionary:
	var key := _action_key(id, area, action_id, side, variant)
	var path := String(bindings.get_value("actions", key, ""))
	var value := Preset.read(path) if path.begins_with(Preset.FOLDER + "/") else {}
	if not value.is_empty() and value.asset == Preset.ASSETS[id] and int(value.zone) == area:
		return value
	return {}


func _row() -> HFlowContainer:
	var row := HFlowContainer.new()
	add_child(row)
	return row


func _label(parent: Control, content: String) -> Label:
	var label := Label.new()
	label.text = content
	parent.add_child(label)
	return label


func _button(parent: Control, caption: String, call: Callable) -> Button:
	var button := Button.new()
	button.text = caption
	button.pressed.connect(call)
	parent.add_child(button)
	return button


func _option(parent: Control, values: Array, call: Callable) -> OptionButton:
	var option := OptionButton.new()
	option.clip_text = true
	for value: String in values:
		option.add_item(value)
	option.item_selected.connect(call)
	parent.add_child(option)
	return option


func _spin(parent: Control, minimum: float, maximum: float, step: float, value: float, prefix: String) -> SpinBox:
	var control := SpinBox.new()
	control.min_value = minimum
	control.max_value = maximum
	control.step = step
	control.value = value
	control.prefix = prefix
	control.get_line_edit().expand_to_text_length = false
	parent.add_child(control)
	return control


func _check(parent: Control, caption: String, value: bool) -> CheckBox:
	var check := CheckBox.new()
	check.text = caption
	check.button_pressed = value
	parent.add_child(check)
	return check
