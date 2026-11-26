extends CanvasLayer

const Stage := preload("res://animation_lab_stage.gd")
const Library := preload("res://card_library.gd")
const CATALOG := "res://Content/F7/catalog.json"
const CARESS_CATALOG := "res://Content/F7/h_caressing.json"
const ROLE_NAMES := ["Мужчина", "Женщина", "Женщина 2"]
const ZONES := ["Левая грудь", "Правая грудь", "Пах / гениталии", "Анальная область", "Левая ягодица", "Правая ягодица"]
const PERMISSION_KEYS := ["Bust_L", "Bust_R", "Kokan", "Anal", "Hip_L", "Hip_R"]
# HAibu.Proc maps the active HandCtrl collider family to these state prefixes.
const CONTACT_PREFIXES := ["M", "M", "A", "S", "S", "S"]
const TOOL_NAMES := ["Левая ладонь", "Правая ладонь", "Левые пальцы", "Правые пальцы", "Язык",
	"Массажёр Л", "Массажёр П", "Вибратор #7", "Вибратор #8", "Дилдо #9", "Дилдо #10", "Ротор Л", "Ротор П"]

var panel: PanelContainer
var sidebar: VBoxContainer
var inspector: VBoxContainer
var inspector_scroll: ScrollContainer
var viewport: SubViewport
var stage: Node3D
var search: LineEdit
var groups: OptionButton
var postures: OptionButton
var pairs: CheckButton
var green: CheckButton
var results: ItemList
var count: Label
var details: Label
var playback_status: Label
var states: OptionButton
var presets: OptionButton
var cameras: OptionButton
var scrub: HSlider
var clock: Label
var loop: CheckButton
var green_panel: VBoxContainer
var caress_positions: OptionButton
var caress_info: Label
var caress_catalog := {}
var caress_entry := {}
var caress_sources := {}
var caress_rest_clip := {}
var contact_prefix := ""
var contact_state := ""
var contact_clip := {}
var contact_time := 0.0
var contact_drag := false
var zone: OptionButton
var action: OptionButton
var side: OptionButton
var variation: OptionButton
var layer_clip: OptionButton
var layer_status: Label
var pov_hands: CheckButton
var hand_controls: VBoxContainer
var hand_tool: OptionButton
var hand_status: Label
var pov_boxes: Array[SpinBox] = []
var hand_overlay := false
var reaction_debug: Label
var hand_pointer := false
var card_options: Array[OptionButton] = []
var offset_boxes: Array[SpinBox] = []
var data: Dictionary = {}
var motion_paths: Dictionary = {}
var row: Dictionary = {}
var state: Array = []
var tracks: Array[String] = ["", "", ""]
var required: Array[bool] = [true, true, false]
var playing := false
var phase := 0.0
var speed := 1.0
var orbit := false
var panning := false
var prior_mouse := Input.MOUSE_MODE_CAPTURED


func _ready() -> void:
	layer = 12
	panel = PanelContainer.new()
	panel.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var background := StyleBoxFlat.new()
	background.bg_color = Color("#202833")
	background.content_margin_left = 8.0
	background.content_margin_right = 8.0
	background.content_margin_top = 6.0
	background.content_margin_bottom = 6.0
	panel.add_theme_stylebox_override("panel", background)
	add_child(panel)
	var layout := HBoxContainer.new()
	panel.add_child(layout)
	sidebar = VBoxContainer.new()
	sidebar.custom_minimum_size.x = 355
	layout.add_child(sidebar)
	var header := HBoxContainer.new()
	sidebar.add_child(header)
	var title := _label(header, "KKS Animation Test Lab")
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_button(header, "F7 · Закрыть", close)
	search = LineEdit.new()
	search.placeholder_text = "ID, японское название, контроллер"
	search.text_changed.connect(func(_text: String): _filter())
	sidebar.add_child(search)
	var filters := HBoxContainer.new()
	sidebar.add_child(filters)
	groups = _options(filters, ["Все группы"])
	for group in range(8):
		groups.add_item("AnimationInfo_%02d" % group)
	postures = _options(filters, ["Все положения"])
	for selector in [groups, postures]:
		selector.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		selector.item_selected.connect(func(_index: int): _filter())
	filters = HBoxContainer.new()
	sidebar.add_child(filters)
	pairs = _check(filters, "Парные")
	green = _check(filters, "H-Caressing")
	for button in [pairs, green]:
		button.toggled.connect(func(_on: bool): _filter())
	count = _label(sidebar, "")
	results = ItemList.new()
	results.size_flags_vertical = Control.SIZE_EXPAND_FILL
	results.item_selected.connect(_select_result)
	sidebar.add_child(results)

	var right := VBoxContainer.new()
	right.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	layout.add_child(right)
	var picture := SubViewportContainer.new()
	picture.stretch = true
	picture.size_flags_vertical = Control.SIZE_EXPAND_FILL
	picture.custom_minimum_size.y = 195
	picture.gui_input.connect(_camera_input)
	right.add_child(picture)
	viewport = SubViewport.new()
	viewport.own_world_3d = true
	picture.add_child(viewport)
	stage = Stage.new()
	viewport.add_child(stage)

	inspector = VBoxContainer.new()
	right.add_child(inspector)
	var transport := HBoxContainer.new()
	inspector.add_child(transport)
	_button(transport, "Play", play)
	_button(transport, "Pause", pause)
	_button(transport, "Stop", stop)
	_button(transport, "Restart", restart)
	loop = _check(transport, "Loop")
	loop.button_pressed = true
	var rate := _spin(transport, 0.1, 3.0, 0.05, 1.0, "Скорость")
	rate.value_changed.connect(func(value: float): speed = value)
	rate.suffix = "×"
	scrub = HSlider.new()
	scrub.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scrub.max_value = 1.0
	scrub.step = 0.001
	scrub.value_changed.connect(func(value: float):
		pause()
		_seek(value))
	transport.add_child(scrub)
	clock = _label(transport, "0.00 с")
	var settings := HBoxContainer.new()
	inspector.add_child(settings)
	states = _options(settings, ["Состояние Unity"])
	states.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	states.item_selected.connect(_select_state)
	presets = _options(settings, ["Категория / MoveOffset"])
	presets.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	presets.item_selected.connect(_set_preset)
	cameras = _options(settings, ["Орбита", "Свободная", "POV М", "POV Ж", "POV Ж2"])
	cameras.item_selected.connect(func(index: int):
		stage.pov = index - 2 if index >= 2 else -1
		stage.update_view())
	_button(settings, "Сброс камеры", _reset_camera)
	_button(settings, "Скрыть · H", _toggle_interface)

	inspector_scroll = ScrollContainer.new()
	inspector_scroll.custom_minimum_size.y = 170
	inspector_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	inspector.add_child(inspector_scroll)
	var options := VBoxContainer.new()
	options.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	inspector_scroll.add_child(options)
	details = _label(options, "")
	details.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	playback_status = _label(options, "")
	playback_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_build_green(options)
	for role in range(3):
		var cast := HBoxContainer.new()
		options.add_child(cast)
		var selector := _options(cast, [ROLE_NAMES[role]])
		selector.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		selector.clip_text = true
		selector.item_selected.connect(_change_card.bind(role))
		card_options.append(selector)
		for axis: String in ["X", "Y", "Z", "RX", "RY", "RZ"]:
			var rotation := axis.begins_with("R")
			var box := _spin(cast, -180.0 if rotation else -3.0, 180.0 if rotation else 3.0,
				1.0 if rotation else 0.01, 0.0, ROLE_NAMES[role] + " · " + axis)
			box.prefix = axis
			box.value_changed.connect(func(_value: float): _update_tweaks())
			offset_boxes.append(box)
	var reset := _button(options, "Сброс коррекции ролей", _reset_tweaks)
	reset.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	panel.hide()
	set_process(false)


func _build_green(options: VBoxContainer) -> void:
	green_panel = VBoxContainer.new()
	options.add_child(green_panel)
	var position_row := HBoxContainer.new()
	green_panel.add_child(position_row)
	_label(position_row, "Position")
	caress_positions = _options(position_row, [])
	caress_positions.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	caress_positions.item_selected.connect(_choose_caress_position)
	caress_info = _label(green_panel, "")
	caress_info.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	var controls := HBoxContainer.new()
	green_panel.add_child(controls)
	zone = _options(controls, ZONES)
	action = _options(controls, [])
	action.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	side = _options(controls, ["Front", "Back"])
	variation = _options(controls, ["Слой 1", "Слой 2", "Слой 3"])
	var layer_controls := HBoxContainer.new()
	green_panel.add_child(layer_controls)
	layer_clip = _options(layer_controls, [])
	layer_clip.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_button(layer_controls, "Применить слой", _apply_layer)
	_button(layer_controls, "Снять слой", _remove_layer)
	layer_status = _label(green_panel, "")
	layer_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_build_hands()
	zone.item_selected.connect(func(_index: int): _fill_actions())
	for selector in [action, side, variation]:
		selector.item_selected.connect(func(_index: int): _choose_layer())
	green_panel.hide()
	inspector_scroll.custom_minimum_size.y = 170


func _build_hands() -> void:
	pov_hands = _check(green_panel, "POV Hands")
	pov_hands.toggled.connect(_toggle_hands)
	hand_controls = VBoxContainer.new()
	green_panel.add_child(hand_controls)
	var controls := HBoxContainer.new()
	hand_controls.add_child(controls)
	hand_tool = _options(controls, [])
	hand_tool.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hand_tool.item_selected.connect(func(_index: int): _cancel_hand())
	_button(controls, "Контакт", _start_hand)
	_button(controls, "Отпустить", _release_hand)
	_button(controls, "Сброс рук", _cancel_hand)
	var show := _check(controls, "Руки")
	show.button_pressed = true
	show.toggled.connect(func(on: bool):
		stage.green_hands.show_hands = on
		stage.update_view())
	var debug := _check(controls, "Цель")
	debug.toggled.connect(func(on: bool):
		stage.green_hands.debug = on
		stage.update_view())
	var rate := _spin(controls, 0.25, 3.0, 0.05, 1.0, "Скорость руки")
	rate.suffix = "×"
	rate.value_changed.connect(func(value: float): stage.green_hands.motion_speed = value)
	var camera_controls := HBoxContainer.new()
	hand_controls.add_child(camera_controls)
	for axis: String in ["X", "Y", "Дист.", "Наклон", "Поворот", "Крен"]:
		var rotation := pov_boxes.size() >= 3
		var box := _spin(camera_controls, -80.0 if rotation else -1.5, 80.0 if rotation else 1.5,
			1 if rotation else 0.02, 0, "Камера POV · " + axis)
		box.prefix = axis
		box.value_changed.connect(func(_value: float): _write_pov_boxes())
		pov_boxes.append(box)
	hand_status = _label(hand_controls, "")
	hand_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	var show_reaction := _check(hand_controls, "Диагностика NPC")
	reaction_debug = _label(hand_controls, "")
	reaction_debug.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	reaction_debug.hide()
	show_reaction.toggled.connect(func(on: bool): reaction_debug.visible = on)
	hand_controls.hide()


func _toggle_hands(on: bool) -> void:
	var hands: Node3D = stage.green_hands
	_cancel_hand()
	hands.enabled = on and green_panel.visible and hands.load_items()
	hand_controls.visible = on and green_panel.visible
	if hands.enabled:
		_read_pov_boxes()
		hand_status.text = "ПКМ · взгляд. ЛКМ · контакт, движение мыши · фаза. R · сброс камеры."
	elif on:
		hand_status.text = "Ресурсы рук KKS недоступны."
	inspector_scroll.custom_minimum_size.y = (290 if on else 210) if green_panel.visible else 170
	_seek(phase)


func _read_pov_boxes() -> void:
	var hands: Node3D = stage.green_hands
	for index in range(3):
		pov_boxes[index].set_value_no_signal(hands.offset[index])
		pov_boxes[index + 3].set_value_no_signal(hands.angles[index])


func _write_pov_boxes() -> void:
	var hands: Node3D = stage.green_hands
	if not hands.enabled:
		return
	hands.offset = Vector3(pov_boxes[0].value, pov_boxes[1].value, pov_boxes[2].value)
	hands.angles = Vector3(pov_boxes[3].value, pov_boxes[4].value, pov_boxes[5].value)
	hands.save_camera()
	stage.update_view()


func _reset_camera() -> void:
	if stage.green_hands.enabled:
		stage.green_hands.reset_camera()
		_read_pov_boxes()
		stage.update_view()
	else:
		stage.reset_view()


func is_open() -> bool:
	return panel.visible


func open() -> void:
	prior_mouse = Input.mouse_mode
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	panel.show()
	sidebar.show()
	inspector.show()
	viewport.render_target_update_mode = SubViewport.UPDATE_WHEN_VISIBLE
	if data.is_empty():
		var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(CATALOG))
		if parsed is Dictionary and parsed.get("version") == 1:
			data = parsed
			_index_motions()
			_load_caress_catalog()
			var labels: Array = []
			for entry: Dictionary in data.rows:
				if entry.posture not in labels:
					labels.append(entry.posture)
				entry["ready"] = _count_ready(entry)
			labels.sort()
			for label: String in labels:
				postures.add_item(label)
	_fill_cards()
	stage.stop_pose(required, true)
	stage.reset_view()
	_filter()
	details.text = "Выберите запись. ПКМ · орбита, СКМ · сдвиг, колесо · масштаб, WASDQE · свободная камера."
	playback_status.text = "Каталог F7 недоступен." if data.is_empty() else ""
	set_process(true)


func close() -> void:
	pause()
	pov_hands.set_pressed_no_signal(false)
	stage.green_hands.enabled = false
	_cancel_hand()
	stage.clear_cast()
	stage.set_placement([[0, 0, 0], [0, 0, 0]])
	row = {}
	caress_entry = {}
	state = []
	tracks = ["", "", ""]
	required = [true, true, false]
	green_panel.hide()
	states.clear()
	presets.clear()
	_reset_tweaks()
	orbit = false
	panning = false
	set_process(false)
	viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	panel.hide()
	Input.mouse_mode = prior_mouse


func _index_motions() -> void:
	var build := Library.directory().get_base_dir().get_base_dir()
	for folder: String in ["res://Content/Motions", "res://Content/F7/States", build.path_join("Motions"), "user://Motions"]:
		var directory := DirAccess.open(folder)
		if not directory:
			continue
		for file: String in directory.get_files():
			if file.ends_with(".kma"):
				motion_paths[file.get_basename()] = folder.path_join(file)


func _required(entry: Dictionary) -> Array[bool]:
	var result: Array[bool] = []
	for role: Dictionary in entry.roles:
		result.append(not String(role.file).is_empty())
	return result


func _clip_path(key: String) -> String:
	var info: Dictionary = data.get("clips", {}).get(key, {})
	return motion_paths.get(info.get("kma", ""), "")


func _load_caress_catalog() -> void:
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(CARESS_CATALOG))
	if not parsed is Dictionary:
		return
	caress_catalog = parsed.get("positions", {})
	caress_positions.clear()
	for id: String in caress_catalog:
		caress_positions.add_item(caress_catalog[id].position, int(id))


func _choose_caress_position(index: int) -> void:
	var id := caress_positions.get_item_id(index)
	for entry: Dictionary in data.rows:
		if int(entry.group) == 0 and int(entry.id) == id:
			for result in results.item_count:
				if results.get_item_metadata(result) == entry:
					results.select(result)
					break
			_select_entry(entry)
			return


func _caress_slot(clip: Dictionary) -> Array:
	var key := "%s#%s" % [clip.bundle, clip.path_id]
	data.clips[key] = {"name": clip.clip, "bundle": clip.bundle, "path_id": clip.path_id, "kma": clip.kma}
	return [key, clip.speed, clip.offset, clip.loop]


func _option_ready(option: Array, cast: Array[bool]) -> bool:
	for role in range(3):
		if cast[role]:
			var clip: Array = option[role + 2]
			if clip.is_empty() or clip.size() > 4 or _clip_path(clip[0]).is_empty():
				return false
	return cast.has(true)


func _count_ready(entry: Dictionary) -> int:
	var cast := _required(entry)
	var total := 0
	for option: Array in entry.options:
		total += int(_option_ready(option, cast))
	return total


func _filter() -> void:
	results.clear()
	var needle := search.text.strip_edges().to_lower()
	for entry: Dictionary in data.get("rows", []):
		var key := "%02d:%02d" % [entry.group, entry.id]
		var label := "%s  %s" % [key, entry["name"]]
		var words := "%s %d %s %s" % [key, entry.id, entry.name, entry.label]
		for role: Dictionary in entry.roles:
			words += " " + String(role.file)
		if (groups.selected > 0 and int(entry.group) != groups.selected - 1) or (green.button_pressed and int(entry.group) != 0) or (pairs.button_pressed and not entry.paired):
			continue
		if postures.selected > 0 and entry.posture != postures.get_item_text(postures.selected):
			continue
		if not needle.is_empty() and needle not in words.to_lower():
			continue
		if not String(entry.label).is_empty():
			label += " · " + String(entry.label)
		var marker := "×" if int(entry.ready) == 0 else ("△" if _needs_scene(entry) else "✓")
		var index := results.add_item(marker + "  " + label)
		results.set_item_metadata(index, entry)
		results.set_item_tooltip(index, "%s · доступных состояний %s" % [entry.posture, entry.ready])
		if entry == row:
			results.select(index)
	count.text = "%d / %d   ✓ клипы   △ оснастка   × без треков" % [results.item_count, data.get("rows", []).size()]


func _needs_scene(entry: Dictionary) -> bool:
	return entry.chair or entry.desk or not String(entry.prop).is_empty()


func _select_result(index: int) -> void:
	_select_entry(results.get_item_metadata(index))


func _select_entry(entry: Dictionary) -> void:
	pause()
	if not contact_prefix.is_empty():
		_cancel_hand()
	row = entry
	caress_entry = caress_catalog.get(str(int(row.id)), {}) if int(row.group) == 0 else {}
	caress_sources.clear()
	caress_rest_clip = {}
	caress_positions.visible = not caress_entry.is_empty()
	if not caress_entry.is_empty():
		caress_positions.select(caress_positions.get_item_index(int(row.id)))
	required = _required(row)
	if required[2] and not stage.actors[2]:
		stage.set_card(2, Stage.DEFAULT_CARDS[2], "")
	_reset_tweaks()
	var names := PackedStringArray()
	for role in range(3):
		var controller: Dictionary = row.roles[role]
		if not String(controller.file).is_empty():
			names.append("%s: %s" % [ROLE_NAMES[role], controller.file])
	details.text = "AnimationInfo_%02d / %02d  %s  ·  %s\n%s" % [
		row.group, row.id, row.name, row.posture, "   |   ".join(names)]
	details.tooltip_text = ""
	for role in range(3):
		card_options[role].disabled = not required[role]
		if required[role]:
			details.tooltip_text += "%s: %s · %s\n" % [ROLE_NAMES[role], row.bases[role].file, row.roles[role].assetpath]
	green_panel.visible = int(row.group) == 0
	if green_panel.visible:
		stage.green_hands.choose_pose(int(row.id))
	_toggle_hands(pov_hands.button_pressed and green_panel.visible)
	inspector_scroll.scroll_vertical = 0
	presets.clear()
	var chosen := 0
	for category: Dictionary in row.categories:
		var preset := String(category.fileMove)
		presets.add_item("%d · %s" % [category.category, preset if not preset.is_empty() else "без смещения"])
		presets.set_item_metadata(presets.item_count - 1, preset)
		if int(category.category) == 8 and row.posture == "Стоя" and not preset.is_empty():
			chosen = presets.item_count - 1
	if presets.item_count > 0:
		presets.select(chosen)
	_set_preset(presets.selected)
	stage.reset_view()
	states.clear()
	var best := -1
	var priority := -1
	var options: Array = row.options
	if not caress_entry.is_empty():
		options = []
		for reference: Dictionary in caress_entry.states:
			var clip: Dictionary = reference.game if reference.studio == null else reference.studio
			caress_sources[reference.state] = reference
			options.append([reference.state, clip.slot, [], _caress_slot(clip), []])
	for option: Array in options:
		var ready := _option_ready(option, required)
		var label := "%s · %s" % [option[0], option[1]]
		if caress_sources.has(option[0]):
			var reference: Dictionary = caress_sources[option[0]]
			label = "%s · %s%s" % [reference.label, option[0], " · KKS" if reference.studio == null else ""]
		states.add_item(label if ready else "× " + label)
		var item := states.item_count - 1
		states.set_item_metadata(item, option)
		var score := 0
		if ready:
			score = 4 if option[1] == "M_Idle" else (3 if option[0] == "Idle" else 1)
		if score > priority:
			priority = score
			best = item
	if best < 0:
		state = []
		tracks = ["", "", ""]
		stage.stop_pose(required)
		playback_status.text = "Отсутствуют состояния и ссылки на клипы. " + " · ".join(row.issues)
	else:
		states.select(best)
		_select_state(best)
	if green_panel.visible:
		_fill_actions()


func _select_state(index: int) -> void:
	pause()
	_clear_caress_contact()
	caress_rest_clip = {}
	state = states.get_item_metadata(index)
	tracks = ["", "", ""]
	var missing := PackedStringArray()
	for role in range(3):
		if not required[role]:
			continue
		var slot: Array = state[role + 2]
		if slot.is_empty():
			missing.append("%s · у контроллера %s нет этого точного слота." % [ROLE_NAMES[role], row.roles[role].file])
			continue
		if slot.size() > 4:
			missing.append("%s · %s" % [ROLE_NAMES[role], slot[4]])
			continue
		tracks[role] = _clip_path(slot[0])
		if tracks[role].is_empty():
			var clip: Dictionary = data.clips[slot[0]]
			var reason := "KMA %s отсутствует" % clip.kma if not String(clip.kma).is_empty() else "клипа нет в индексе конвертации"
			missing.append("%s · %s · %s [%s #%s]" % [ROLE_NAMES[role], clip.name, reason, clip.bundle, clip.path_id])
	phase = 0.0
	stage.stop_pose(required)
	if not missing.is_empty():
		playback_status.text = "Недоступно · " + "\n".join(missing) + ("\n" + " · ".join(row.issues) if not row.issues.is_empty() else "")
	else:
		_arm_tracks()
		if not caress_entry.is_empty():
			loop.set_pressed_no_signal(bool(state[3][3]))
	_seek(0.0)
	if green_panel.visible:
		_choose_layer()


func _arm_tracks() -> bool:
	if state.is_empty() or not _option_ready(state, required):
		return false
	var issue: String = stage.setup_tracks(tracks, state, required)
	if not issue.is_empty():
		playback_status.text = issue
		return false
	var missing := PackedStringArray()
	if row.desk:
		missing.append("стол")
	if row.chair:
		missing.append("стул")
	if not String(row.prop).is_empty():
		missing.append(row.prop)
	playback_status.text = "Дорожки загружены · общая фаза. Контакты MotionIK требуют переноса."
	if not missing.is_empty():
		playback_status.text += " Оснастка · " + ", ".join(missing) + "."
	return true


func _set_preset(index: int) -> void:
	var key: String = presets.get_item_metadata(index) if index >= 0 else ""
	stage.set_placement(data.get("offsets", {}).get(key, [[0, 0, 0], [0, 0, 0]]))
	stage.update_view()


func _fill_cards() -> void:
	var built := Library.directory().get_base_dir()
	for role in range(3):
		var choice := card_options[role]
		choice.clear()
		_add_card(choice, ROLE_NAMES[role] + " · стандарт", Stage.DEFAULT_CARDS[role])
		var personal := "user://ImportedCards/" + ("player.kcs" if role == 0 else "npc.kcs")
		_add_card(choice, "Текущая импортированная", personal)
		for file: String in (["BR-Kun-portable.png"] if role == 0 else ["Friendly-portable.png", "KK-BR-Chan-portable.png"]):
			_add_card(choice, file.get_basename(), built.path_join(file))
		for qa: Dictionary in Library.qa_catalog():
			if ("_Male_" in String(qa.id)) == (role == 0) and not Library.qa_card(qa).is_empty():
				_add_card(choice, qa.id, "qa://" + String(qa.id))
		for card: Dictionary in Library.read_catalog():
			if String(card.get("source", "")).contains("/male/" if role == 0 else "/female/"):
				_add_card(choice, String(card.source).get_file().get_basename(), Library.ready_path(card))
		choice.select(0)
		choice.set_meta("active", 0)
		if role < 2:
			stage.set_card(role, Stage.DEFAULT_CARDS[role], "")


func _add_card(choice: OptionButton, label: String, path: String) -> void:
	if path.begins_with("qa://") or FileAccess.file_exists(path):
		choice.add_item(label)
		choice.set_item_metadata(choice.item_count - 1, path)


func _change_card(index: int, role: int) -> void:
	var choice := card_options[role]
	var path: String = choice.get_item_metadata(index)
	var motion := tracks[role] if stage.duration > 0.0 else ""
	var issue: String = stage.set_card(role, path, motion)
	if not issue.is_empty():
		choice.select(int(choice.get_meta("active", 0)))
		playback_status.text = issue
		return
	choice.set_meta("active", index)
	if green_panel.visible and role == 1:
		_choose_layer()
	_seek(phase)


func _update_tweaks() -> void:
	for role in range(3):
		var i := role * 6
		stage.tweaks[role].position = Vector3(offset_boxes[i].value, offset_boxes[i + 1].value, offset_boxes[i + 2].value)
		stage.tweaks[role].rotation_degrees = Vector3(offset_boxes[i + 3].value, offset_boxes[i + 4].value, offset_boxes[i + 5].value)
	stage.update_view()


func _reset_tweaks() -> void:
	for box in offset_boxes:
		box.set_value_no_signal(0.0)
	_update_tweaks()


func _fill_actions() -> void:
	action.clear()
	var table := "aibulayer_%02d" % zone.selected
	for entry: Dictionary in data.get("actions", []):
		if entry.table != table:
			continue
		var raw: Dictionary = entry.raw
		var names := PackedStringArray()
		var assets := PackedStringArray()
		for item: Dictionary in data.tools:
			if item.raw.id in raw.idObjects:
				var tool_id := int(item.raw.id)
				assets.append(item.raw.asset)
				names.append(TOOL_NAMES[tool_id] if tool_id >= 0 and tool_id < TOOL_NAMES.size() else item.raw.asset)
		action.add_item("#%d · %s" % [raw.id, " / ".join(names)])
		action.set_item_metadata(action.item_count - 1, raw)
		action.set_item_tooltip(action.item_count - 1, "%s · click %s · drag %s" % [
			" / ".join(assets), raw.actionClick, raw.actionDrag])
	if action.item_count > 0:
		action.select(0)
	_choose_layer()


func _layer_permission() -> bool:
	if state.is_empty():
		return false
	for permission: Dictionary in data.permissions:
		if permission.table == row.permission and permission.raw.AnimationName == state[0]:
			return bool(permission.raw.get(PERMISSION_KEYS[zone.selected], false))
	return false


func _choose_layer() -> void:
	_cancel_hand()
	stage.clear_overlay()
	_seek(phase)
	layer_clip.clear()
	hand_tool.clear()
	if action.selected < 0 or row.is_empty():
		layer_status.text = "Для зоны отсутствуют записи."
		return
	var raw: Dictionary = action.get_item_metadata(action.selected)
	for index in range(raw.idObjects.size()):
		var id := int(raw.idObjects[index])
		if id < 0:
			continue
		var title: String = TOOL_NAMES[id] if id < TOOL_NAMES.size() else "Инструмент #%d" % id
		hand_tool.add_item(title if id < 4 else title + " · требуется импорт")
		hand_tool.set_item_metadata(hand_tool.item_count - 1, [id, index])
		hand_tool.set_item_disabled(hand_tool.item_count - 1, id >= 4)
	if hand_tool.item_count:
		hand_tool.select(0)
	var choice: Dictionary = raw.layerActions[variation.selected]["front" if side.selected == 0 else "back"]
	var body := int(choice.body)
	var caption := "Тело #%d · предмет #%d · %s. " % [body, choice.item, row.permission]
	if not _layer_permission():
		layer_status.text = caption + "В текущем состоянии зона запрещена или правило отсутствует."
		return
	var sets: Array = data.get("layer_sets", [])
	var set_id := int(row.get("layer_set", -1))
	var layers: Array = sets[set_id] if set_id >= 0 and set_id < sets.size() else []
	for definition: Array in layers:
		if int(definition[0]) != body:
			continue
		if int(definition[2]) != 0:
			layer_status.text = caption + "Аддитивный слой требует эталонной позы Unity."
			return
		if definition[3].is_empty():
			layer_status.text = caption + "Маска слоя не сопоставлена со скелетом KMA."
			return
		for key: String in definition[4]:
			var path := _clip_path(key)
			if not path.is_empty():
				layer_clip.add_item(data.clips[key].name)
				layer_clip.set_item_metadata(layer_clip.item_count - 1, [path, definition[3]])
		layer_status.text = caption + ("Выберите клип слоя тела." if layer_clip.item_count else "Нет импортированного KMA для слоя тела.")
		return
	layer_status.text = caption + "В базовом контроллере не найдено клипов этого слоя."


func _apply_layer() -> void:
	if layer_clip.selected < 0 or stage.duration <= 0.0:
		layer_status.text += " Сначала загрузите основное состояние и клип слоя."
		return
	var chosen: Array = layer_clip.get_item_metadata(layer_clip.selected)
	var applied: bool = stage.set_overlay(chosen[0], chosen[1])
	_seek(phase)
	layer_status.text = "Слой тела применён." if applied else "В этом KMA нет совместимых дорожек для исходной маски."


func _remove_layer() -> void:
	_choose_layer()


func _start_hand() -> void:
	var hands: Node3D = stage.green_hands
	if not hands.enabled or hands.running:
		return
	if not contact_prefix.is_empty():
		_cancel_hand()
	if stage.duration <= 0.0 or action.selected < 0 or not _layer_permission():
		hand_status.text = "Контакт недоступен для выбранной зоны и состояния."
		return
	if hand_tool.selected < 0 or hand_tool.is_item_disabled(hand_tool.selected):
		hand_status.text = "Для выбранного действия требуется импорт инструмента."
		return
	var raw: Dictionary = action.get_item_metadata(action.selected)
	var tool: Array = hand_tool.get_item_metadata(hand_tool.selected)
	var item_layer := int(raw.layerActions[variation.selected]["front" if side.selected == 0 else "back"].item)
	var socket := String(raw.nameParents[tool[1]])
	var issue: String = hands.start_action(stage.actors[1], tool[0], item_layer, socket, zone.selected)
	if not issue.is_empty():
		hand_status.text = issue
		return
	stage.clear_overlay()
	hand_overlay = false
	if layer_clip.selected >= 0:
		var chosen: Array = layer_clip.get_item_metadata(layer_clip.selected)
		hand_overlay = stage.set_overlay(chosen[0], chosen[1])
		stage.overlay_weight = 0.0
		stage.overlay_phase = 0.0
	stage.green_reaction.begin(zone.selected, raw, layer_clip.get_item_text(layer_clip.selected) if hand_overlay else "")
	if not caress_sources.is_empty() and int(raw.actionClick) == 0:
		contact_prefix = CONTACT_PREFIXES[zone.selected]
		contact_drag = false
	var motion: String = hands.item_label(tool[0], item_layer) if hands.authored else "процедурная кисть"
	hand_status.text = "%s · %s · %s" % [
		motion, socket if not socket.is_empty() else hands.fallback,
		"Слой тела KKS" if hand_overlay else "Доступна анимация руки"]
	_seek(phase)


func _release_hand() -> void:
	stage.green_hands.release()
	hand_pointer = false


func _cancel_hand() -> void:
	var restore := not contact_clip.is_empty()
	_clear_caress_contact()
	stage.green_hands.cancel()
	stage.green_reaction.reset()
	hand_pointer = false
	if hand_overlay:
		stage.clear_overlay()
		hand_overlay = false
	if restore and stage.duration > 0.0:
		_arm_tracks()
	_seek(phase)


func _clear_caress_contact() -> void:
	contact_prefix = ""
	contact_state = ""
	contact_clip = {}
	contact_time = 0.0
	contact_drag = false
	stage.green_reaction.live_state = ""


func _switch_caress_contact(next: String, clip: Dictionary, keep_phase := false) -> bool:
	var slot := _caress_slot(clip)
	var path := _clip_path(slot[0])
	if path.is_empty() or not stage.switch_green_track(path, slot):
		hand_status.text = "Недоступно · %s · %s → %s.kma" % [next, clip.clip, clip.kma]
		return false
	contact_state = next
	contact_clip = clip
	contact_time = phase * stage.duration if keep_phase else 0.0
	stage.green_reaction.live_state = next
	return true


func _step_caress_contact(hands: Node3D, delta: float) -> void:
	if contact_prefix.is_empty():
		return
	if hands.running and hands.body_weight > 0.0 and contact_state.is_empty():
		var touch := contact_prefix + "_Touch"
		if not _switch_caress_contact(touch, caress_sources[touch].game):
			contact_prefix = ""
			return
	elif not hands.running:
		if contact_state.is_empty():
			_clear_caress_contact()
			return
		if contact_state.ends_with("_Touch") and contact_time < stage.duration:
			contact_time += delta * speed
			return
		if contact_state != "Idle":
			_switch_caress_contact("Idle", caress_sources.Idle.game)
		elif hands.tool_id < 0 and stage.green_fade_left <= 0.0:
			for index in states.item_count:
				var option: Array = states.get_item_metadata(index)
				if option[0] == "Idle":
					states.select(index)
					caress_rest_clip = contact_clip
					state = option.duplicate()
					state[3] = _caress_slot(caress_rest_clip)
					tracks[1] = _clip_path(state[3][0])
					loop.set_pressed_no_signal(true)
					break
			_clear_caress_contact()
			return
	if contact_state.ends_with("_Touch") and contact_time >= stage.duration:
		var held := contact_prefix + "_Idle"
		_switch_caress_contact(held, caress_sources[held].game)
	elif contact_drag and contact_state.ends_with("_Idle"):
		var hold: Variant = caress_sources[contact_state].hold
		if hold is Dictionary and contact_clip != hold:
			_switch_caress_contact(contact_state, hold, true)
	contact_time += delta * speed


func play() -> void:
	if stage.duration <= 0.0:
		if not _arm_tracks():
			return
		_seek(phase)
	if phase >= 1.0:
		_seek(0.0)
	playing = true
	_update_caress_info()


func pause() -> void:
	playing = false
	_update_caress_info()


func stop() -> void:
	pause()
	_cancel_hand()
	stage.stop_pose(required, row.is_empty())
	_seek(0.0)


func restart() -> void:
	_cancel_hand()
	_seek(0.0)
	play()


func _seek(value: float) -> void:
	phase = clampf(value, 0.0, 1.0)
	var reactions: bool = stage.green_hands.enabled and green_panel.visible and stage.duration > 0.0
	stage.green_reaction.setup(stage.actors[1] if reactions else null, int(row.id) if reactions else -1,
		String(state[0]) if reactions and not state.is_empty() else "")
	stage.seek(phase)
	scrub.set_value_no_signal(phase)
	clock.text = "%.2f / %.2f с" % [phase * stage.duration, stage.duration]
	_update_caress_info()
	if reaction_debug and reaction_debug.visible and reactions:
		_update_reaction_debug()


func _update_caress_info() -> void:
	if caress_entry.is_empty() or state.is_empty() or not caress_sources.has(state[0]):
		caress_info.hide()
		return
	var reference: Dictionary = caress_sources[state[0]]
	var clip: Dictionary = reference.game if reference.studio == null else reference.studio
	if not contact_clip.is_empty():
		clip = contact_clip
	elif not caress_rest_clip.is_empty():
		clip = caress_rest_clip
	var animation: Animation = stage.base_animations[1]
	var status := "Недоступно"
	if playing or not contact_state.is_empty():
		status = "Play"
	elif animation:
		status = "Pause"
	elif not tracks[1].is_empty() and playback_status.text.begins_with("Дорожки загружены"):
		status = "Stop"
	caress_info.show()
	caress_info.text = "%02d · %s · %s · %s · %d тр.\n%s #%s\n%s → %s.kma" % [
		int(caress_entry.id), caress_entry.controller, state[0] if contact_state.is_empty() else contact_state, status,
		animation.get_track_count() if animation else 0, clip.bundle, clip.path_id, clip.clip, clip.kma]


func _update_reaction_debug() -> void:
	var reaction: RefCounted = stage.green_reaction
	var hit: Dictionary = reaction.hit_group.get("group", {})
	var face: Dictionary = reaction.face.applied
	var body_mix := float(stage.overlay_weight) if hand_overlay else 0.0
	reaction_debug.text = "AnimationInfo_00/%02d · зона %s · HandCtrl #%s\n%s · %s · EyeNeck #%d\n%s %s · %s · %.2f / %.1f мм\nKMA %s · вес %.2f\n%s #%d · мешей %d · вес морфа %.2f\nБрови %s · глаза %s (%.2f) · рот %s (%.2f)" % [
		reaction.pose_id, reaction.zone, reaction.action_id, reaction.base_state, reaction.phase_name, reaction.look_id,
		reaction.table.get("reaction", ""), reaction.hit_key, hit.get("name", "—"), reaction.fader, reaction.hit_offset * 1000.0,
		reaction.motion if not String(reaction.motion).is_empty() else "—", body_mix,
		reaction.profile.get("face_table", ""), reaction.face_id, face.get("surfaces", 0), face.get("morph_weight", 0.0),
		face.get("eyebrow", "—"), face.get("eye", "—"), face.get("eye_open", 0.0),
		face.get("mouth", "—"), face.get("mouth_open", 0.0),
	]


func _process(delta: float) -> void:
	var hands: Node3D = stage.green_hands
	var moving: bool = hands.enabled and hands.tool_id >= 0
	if moving:
		hands.tick(delta)
		if hand_overlay:
			stage.overlay_weight = hands.body_weight
			stage.overlay_phase = hands.action_phase
			if hands.tool_id < 0:
				stage.clear_overlay()
				hand_overlay = false
	stage.green_fade_left = maxf(0.0, stage.green_fade_left - delta)
	_step_caress_contact(hands, delta)
	var reacting: bool = hands.enabled and stage.duration > 0.0
	if reacting:
		stage.green_reaction.advance(hands, stage.camera.global_position, delta)
	if not contact_state.is_empty():
		var runtime_phase := contact_time / maxf(stage.duration, 0.001)
		_seek(fposmod(runtime_phase, 1.0) if bool(contact_clip.loop) else runtime_phase)
	elif playing:
		var next := phase + delta * speed / maxf(stage.duration, 0.001)
		if loop.button_pressed:
			next = fposmod(next, 1.0)
		elif next >= 1.0:
			pause()
		_seek(next)
	elif moving or reacting:
		_seek(phase)
	if cameras.selected == 1 and not (get_viewport().gui_get_focus_owner() is LineEdit):
		var direction := Vector3(
			float(Input.is_physical_key_pressed(KEY_D)) - float(Input.is_physical_key_pressed(KEY_A)),
			float(Input.is_physical_key_pressed(KEY_E)) - float(Input.is_physical_key_pressed(KEY_Q)),
			float(Input.is_physical_key_pressed(KEY_S)) - float(Input.is_physical_key_pressed(KEY_W)))
		if not direction.is_zero_approx():
			stage.focus += stage.camera.basis * direction.normalized() * delta * 2.0
			stage.update_view()


func _camera_input(event: InputEvent) -> void:
	if stage.green_hands.enabled:
		_green_camera_input(event)
		return
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_RIGHT:
			orbit = event.pressed
		if event.button_index == MOUSE_BUTTON_MIDDLE:
			panning = event.pressed
		if event.pressed and event.button_index in [MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN]:
			stage.distance = clampf(stage.distance * (0.89 if event.button_index == MOUSE_BUTTON_WHEEL_UP else 1.12), 0.4, 18.0)
	elif event is InputEventMouseMotion:
		if orbit:
			var eye: Vector3 = stage.camera.position
			stage.yaw -= event.relative.x * 0.007
			stage.pitch = clampf(stage.pitch + event.relative.y * 0.007, -1.48, 1.48)
			if cameras.selected == 1:
				stage.focus = eye - stage.orbit_offset()
		if panning:
			stage.focus += stage.camera.basis * Vector3(-event.relative.x, event.relative.y, 0.0) * 0.003 * stage.distance
	stage.update_view()


func _green_camera_input(event: InputEvent) -> void:
	var hands: Node3D = stage.green_hands
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_LEFT:
			if event.pressed:
				_start_hand()
				hand_pointer = hands.running
			else:
				_release_hand()
		elif event.button_index == MOUSE_BUTTON_RIGHT:
			orbit = event.pressed
			if not orbit:
				hands.save_camera()
		elif event.pressed and event.button_index in [MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN]:
			var direction := -1.0 if event.button_index == MOUSE_BUTTON_WHEEL_UP else 1.0
			hands.offset.z = clampf(hands.offset.z + direction * 0.07 * signf(hands.PRESETS[hands.pose_id].z), -0.5, 1.3)
			hands.save_camera()
	elif event is InputEventMouseMotion:
		if orbit:
			hands.angles.y = clampf(hands.angles.y - event.relative.x * 0.28, -80.0, 80.0)
			hands.angles.x = clampf(hands.angles.x - event.relative.y * 0.28, -80.0, 80.0)
		elif hand_pointer and hands.running and action.selected >= 0:
			var raw: Dictionary = action.get_item_metadata(action.selected)
			if int(raw.actionDrag) >= 0:
				hands.action_phase = fposmod(hands.action_phase + event.relative.length() * 0.004, 1.0)
				contact_drag = not event.relative.is_zero_approx() or contact_drag
	_read_pov_boxes()
	stage.update_view()


func _toggle_interface() -> void:
	sidebar.visible = not sidebar.visible
	inspector.visible = sidebar.visible


func handle_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_ESCAPE:
			close()
		elif event.keycode == KEY_H:
			_toggle_interface()
		elif event.keycode == KEY_R:
			_reset_camera()


func _label(parent: Node, value: String) -> Label:
	var control := Label.new()
	control.text = value
	parent.add_child(control)
	return control


func _options(parent: Node, values: Array) -> OptionButton:
	var control := OptionButton.new()
	control.fit_to_longest_item = false
	for value: String in values:
		control.add_item(value)
	parent.add_child(control)
	return control


func _button(parent: Node, value: String, callback: Callable) -> Button:
	var control := Button.new()
	control.text = value
	control.pressed.connect(callback)
	parent.add_child(control)
	return control


func _check(parent: Node, value: String) -> CheckButton:
	var control := CheckButton.new()
	control.text = value
	parent.add_child(control)
	return control


func _spin(parent: Node, low: float, high: float, step: float, value: float, tip: String) -> SpinBox:
	var control := SpinBox.new()
	control.min_value = low
	control.max_value = high
	control.step = step
	control.value = value
	control.tooltip_text = tip
	parent.add_child(control)
	return control
