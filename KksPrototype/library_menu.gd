extends CanvasLayer

const PAGE_SIZE := 160
const CATALOG_PATH := "res://Content/catalog.json"
const CardLibrary := preload("res://card_library.gd")
const BUNDLED_CARDS := {
	"e9fa91b1c7234f8d50302dbc462dbf47d536319e627951455a5b2f75ecf379df": "res://Content/Npc.kcs",
	"725eb31cc3ad2b49e27a4e46060f126ad8c9a0de6808ff9e88baad1d325553a0": "res://Content/Player.kcs",
}

var panel: PanelContainer
var search: LineEdit
var ready_only: CheckButton
var list: ItemList
var page_label: Label
var status: Label
var role: OptionButton
var coordinate: SpinBox
var card_dialog: FileDialog
var portable_dialog: FileDialog
var outfit_dialog: FileDialog
var source_dialog: FileDialog
var card_library: AcceptDialog
var catalog: Array = []
var catalog_stamp := -1
var playable: Dictionary = {}
var conversion_status: Dictionary = {}
var matches: Array = []
var page := 0
var game_root := ""
var previous_mouse := Input.MOUSE_MODE_CAPTURED
var job_pid := -1
var job_path := ""
var job_clip := ""
var job_npc := true
var job_card := ""
var card_sources: Dictionary = {}
var prepared_cards: Dictionary = {}


func _ready() -> void:
	panel = PanelContainer.new()
	panel.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	panel.offset_left = -440
	panel.offset_right = 440
	panel.offset_top = -292
	panel.offset_bottom = 292
	add_child(panel)
	var outer := VBoxContainer.new()
	outer.add_theme_constant_override("separation", 9)
	panel.add_child(outer)
	var filters := HBoxContainer.new()
	outer.add_child(filters)
	search = LineEdit.new()
	search.placeholder_text = "Search by name, bundle or ID"
	search.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	search.text_changed.connect(func(_value: String): filter())
	filters.add_child(search)
	ready_only = CheckButton.new()
	ready_only.text = "Playable Only"
	ready_only.button_pressed = true
	ready_only.toggled.connect(func(_value: bool): filter())
	filters.add_child(ready_only)
	list = ItemList.new()
	list.custom_minimum_size = Vector2(840, 325)
	list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	list.item_activated.connect(func(index: int): play(index))
	outer.add_child(list)

	var actions := HBoxContainer.new()
	outer.add_child(actions)
	button(actions, "←", func(): change_page(-1))
	page_label = Label.new()
	actions.add_child(page_label)
	button(actions, "→", func(): change_page(1))
	button(actions, "Play on NPC", play_selected)
	button(actions, "Save Portable PNG", choose_portable)
	button(actions, "Close", toggle)

	var card_actions := HBoxContainer.new()
	outer.add_child(card_actions)
	role = OptionButton.new()
	role.add_item("Replace NPC")
	role.add_item("Replace Player")
	card_actions.add_child(role)
	coordinate = SpinBox.new()
	coordinate.min_value = -1
	coordinate.max_value = 99
	coordinate.value = -1
	coordinate.suffix = "outfit"
	coordinate.tooltip_text = "−1 uses the default outfit. Other numbers select outfit slots on the card."
	card_actions.add_child(coordinate)
	button(card_actions, "Open Card", func(): card_dialog.popup_centered_ratio(0.75))
	button(card_actions, "Open Outfit Card", choose_outfit)
	button(card_actions, "Koikatsu Folder", func(): source_dialog.popup_centered_ratio(0.75))
	var editor_actions := HBoxContainer.new()
	outer.add_child(editor_actions)
	button(editor_actions, "Koikatsu Cards", func(): card_library.show_catalog())
	button(editor_actions, "Character Editor", func():
		toggle()
		get_parent().editor.toggle(role.selected == 0))
	button(editor_actions, "Toggle Clothing", func():
		get_parent().editor.quick_toggle(role.selected == 0)
		status.text = get_parent().editor.status.text)
	status = Label.new()
	status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	status.custom_minimum_size.y = 42
	outer.add_child(status)

	card_dialog = FileDialog.new()
	card_dialog.access = FileDialog.ACCESS_FILESYSTEM
	card_dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	card_dialog.filters = ["*.png ; Koikatsu Card", "*.kcs ; Prepared Character"]
	card_dialog.file_selected.connect(open_card)
	add_child(card_dialog)
	card_library = CardLibrary.new()
	card_library.card_selected.connect(open_card)
	add_child(card_library)
	portable_dialog = FileDialog.new()
	portable_dialog.access = FileDialog.ACCESS_FILESYSTEM
	portable_dialog.file_mode = FileDialog.FILE_MODE_SAVE_FILE
	portable_dialog.filters = ["*.png ; Portable Card"]
	portable_dialog.file_selected.connect(save_portable)
	add_child(portable_dialog)
	outfit_dialog = FileDialog.new()
	outfit_dialog.access = FileDialog.ACCESS_FILESYSTEM
	outfit_dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	outfit_dialog.filters = ["*.png ; Koikatsu Outfit Card"]
	outfit_dialog.file_selected.connect(open_outfit)
	add_child(outfit_dialog)
	source_dialog = FileDialog.new()
	source_dialog.access = FileDialog.ACCESS_FILESYSTEM
	source_dialog.file_mode = FileDialog.FILE_MODE_OPEN_DIR
	source_dialog.dir_selected.connect(set_game_root)
	add_child(source_dialog)
	var settings := ConfigFile.new()
	if settings.load("user://library.cfg") == OK:
		game_root = settings.get_value("import", "game_root", "")
	panel.hide()
	set_process(false)


func button(parent: Control, caption: String, action: Callable) -> void:
	var control := Button.new()
	control.text = caption
	control.pressed.connect(action)
	parent.add_child(control)


func is_open() -> bool:
	return panel.visible


func toggle() -> void:
	if panel.visible:
		panel.hide()
		Input.mouse_mode = previous_mouse
		return
	previous_mouse = Input.mouse_mode
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	panel.show()
	var external := executable_dir().path_join("Catalog.json")
	var stamp := FileAccess.get_modified_time(external) if FileAccess.file_exists(external) else 0
	if catalog.is_empty() or catalog_stamp != stamp:
		var catalog_file := external if stamp > 0 else CATALOG_PATH
		var data: Variant = JSON.parse_string(FileAccess.get_file_as_string(catalog_file))
		if data is Dictionary:
			catalog = data.get("clips", [])
			catalog_stamp = stamp
	refresh_playable()
	filter()
	search.grab_focus()


func refresh_playable() -> void:
	playable.clear()
	conversion_status.clear()
	var dirs := ["res://Content/Motions", executable_dir().path_join("Motions"), "user://Motions"]
	for dir in dirs:
		if not DirAccess.dir_exists_absolute(dir):
			continue
		for name in DirAccess.get_files_at(dir):
			if name.ends_with(".kma"):
				playable[name.get_basename()] = true
			if name.begins_with("conversion") and name.ends_with(".tsv"):
				for line in FileAccess.get_file_as_string(dir.path_join(name)).split("\n", false):
					var fields := line.strip_edges().split("\t", true, 1)
					if fields.size() == 2:
						conversion_status[fields[0]] = fields[1]
	for id in [get_parent().IDLE_ID, get_parent().WALK_ID, get_parent().DANCE_ID]:
		if FileAccess.file_exists(get_parent().motion_path(id)):
			playable[id] = true


func filter() -> void:
	var query := search.text.strip_edges().to_lower()
	matches.clear()
	for row in catalog:
		if ready_only.button_pressed and not playable.has(row.id):
			continue
		if query.is_empty() or query in String(row.name).to_lower() or query in String(row.bundle).to_lower() or query in String(row.object_id):
			matches.append(row)
	page = 0
	show_page()


func change_page(direction: int) -> void:
	page = clampi(page + direction, 0, maxi(0, ceili(matches.size() / float(PAGE_SIZE)) - 1))
	show_page()


func show_page() -> void:
	list.clear()
	var start := page * PAGE_SIZE
	for i in range(start, mini(start + PAGE_SIZE, matches.size())):
		var row: Dictionary = matches[i]
		var ready := playable.has(row.id)
		var result: String = conversion_status.get(row.id, "")
		var suffix := ""
		if not ready:
			suffix = "   (import required)" if result.is_empty() or result == "ambiguous" else "   (no playable tracks)"
		list.add_item(("%s   ·   %s   ·   #%s" % [row.name, String(row.bundle).get_file(), String(row.id).right(6)]) + suffix)
		list.set_item_tooltip(list.item_count - 1, ("Mod: %s\n" % row.archive if row.archive else "") + row.bundle + "\nID " + row.object_id
			+ ("\n" + result if not ready and not result.is_empty() else ""))
	page_label.text = "%d/%d  ·  %d found  ·  %d playable" % [page + 1, maxi(1, ceili(matches.size() / float(PAGE_SIZE))), matches.size(), playable.size()]


func play_selected() -> void:
	if list.is_anything_selected():
		play(list.get_selected_items()[0])


func play(index: int) -> void:
	var row: Dictionary = matches[page * PAGE_SIZE + index]
	if get_parent().play_npc_motion(row.id):
		status.text = "NPC is playing %s." % row.name
	else:
		convert_motion(row)


func set_game_root(path: String) -> void:
	if not FileAccess.file_exists(path.path_join("CharaStudio.exe")):
		status.text = "CharaStudio.exe was not found in the selected folder."
		return
	game_root = path
	var settings := ConfigFile.new()
	settings.set_value("import", "game_root", path)
	settings.save("user://library.cfg")
	status.text = "Koikatsu folder saved."


func open_card(path: String) -> void:
	var npc := role.selected == 0
	if path.get_extension().to_lower() == "png":
		var file := FileAccess.open(path, FileAccess.READ)
		if file and get_parent().CardModel.seek_portable_payload(file):
			var start := file.get_position()
			var version := file.get_32()
			var replacement := ""
			if version != get_parent().CardModel.CARD_MAGIC and start <= 33554432:
				file.seek(0)
				var hash := HashingContext.new()
				hash.start(HashingContext.HASH_SHA256)
				hash.update(file.get_buffer(start))
				replacement = CardLibrary.find_card(hash.finish().hex_encode())
			var updated: bool = not replacement.is_empty() and get_parent().load_card(replacement, npc)
			if updated or get_parent().load_card(path, npc):
				clear_card_source(npc)
				status.text = "Portable card loaded."
				if updated:
					status.text = "Loaded the updated version from the catalog."
				elif version != get_parent().CardModel.CARD_MAGIC:
					status.text = "An older model loaded. Open the original Koikatsu card to update its body details."
			else:
				status.text = "The card is damaged."
			return
		var digest := FileAccess.get_sha256(path)
		var bundled := CardLibrary.find_card(digest)
		if bundled.is_empty():
			bundled = BUNDLED_CARDS.get(digest, "")
		if not bundled.is_empty() and int(coordinate.value) == -1 and get_parent().load_card(bundled, npc):
			card_sources[npc] = path
			prepared_cards[npc] = bundled
			status.text = "Card loaded from the local library."
			return
	if path.get_extension().to_lower() == "kcs":
		status.text = "Card loaded." if get_parent().load_card(path, npc) else "Unsupported character format."
		card_sources.erase(npc)
		prepared_cards.erase(npc)
		return
	import_card(path, npc)


func clear_card_source(npc: bool) -> void:
	card_sources.erase(npc)
	prepared_cards.erase(npc)


func choose_portable() -> void:
	if not prepared_cards.has(role.selected == 0):
		status.text = "Open the original character PNG first."
		return
	portable_dialog.current_file = "character-portable.png"
	portable_dialog.popup_centered_ratio(0.72)


func save_portable(path: String) -> void:
	var npc := role.selected == 0
	if not prepared_cards.has(npc):
		return
	if FileAccess.file_exists(path):
		status.text = "Choose a new name for the portable card."
		return
	var original := FileAccess.get_file_as_bytes(card_sources[npc])
	var model_path: String = prepared_cards[npc]
	var model: PackedByteArray
	if model_path.get_extension().to_lower() == "png":
		var embedded := FileAccess.open(model_path, FileAccess.READ)
		if not embedded or not get_parent().CardModel.seek_portable_payload(embedded):
			status.text = "Could not read the embedded model."
			return
		model = embedded.get_buffer(embedded.get_length() - 16 - embedded.get_position())
	else:
		model = FileAccess.get_file_as_bytes(model_path)
	if original.is_empty() or model.is_empty() or model.size() > 134217728:
		status.text = "Could not read the original PNG or model."
		return
	var file := FileAccess.open(path, FileAccess.WRITE)
	if not file:
		status.text = "Could not save PNG."
		return
	file.store_buffer(original)
	file.store_buffer(model)
	file.store_64(model.size())
	file.store_buffer(get_parent().CardModel.PORTABLE_MARKER.to_ascii_buffer())
	file.close()
	status.text = "The PNG contains the model, clothing and textures."


func choose_outfit() -> void:
	if not card_sources.has(role.selected == 0):
		status.text = "Open the character PNG card before replacing its outfit."
		return
	outfit_dialog.popup_centered_ratio(0.75)


func open_outfit(path: String) -> void:
	var npc := role.selected == 0
	if card_sources.has(npc):
		import_card(card_sources[npc], npc, path)


func import_card(card: String, npc: bool, outfit: String = "") -> void:
	if game_root.is_empty():
		var candidate := card.get_base_dir()
		while not candidate.is_empty():
			if FileAccess.file_exists(candidate.path_join("CharaStudio.exe")):
				set_game_root(candidate)
				break
			var ancestor := candidate.get_base_dir()
			if ancestor == candidate:
				break
			candidate = ancestor
	if game_root.is_empty() or not FileAccess.file_exists(game_root.path_join("CharaStudio.exe")):
		status.text = "This PNG contains no model or textures. Open a prepared PNG or .kcs for standalone use."
		return
	if not can_start_job():
		return
	var script := tools_dir().path_join("import_kks_card.ps1")
	if not FileAccess.file_exists(script):
		status.text = "Place the Tools folder next to the executable."
		return
	var destination := "user://ImportedCards/%s.kcs" % ("npc" if npc else "player")
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(destination.get_base_dir()))
	var args := ["-NoProfile", "-ExecutionPolicy", "Bypass", "-WindowStyle", "Hidden",
		"-File", script, "-GameRoot", game_root, "-Card", card, "-Output",
		ProjectSettings.globalize_path(destination), "-Coordinate", str(int(coordinate.value))]
	if not outfit.is_empty():
		args.append_array(["-Outfit", outfit])
	job_pid = OS.create_process("powershell.exe", args, false)
	job_path = destination
	job_npc = npc
	job_card = card
	job_clip = ""
	start_wait("Loading the PNG and outfit. This may take a minute.")


func convert_motion(row: Dictionary) -> void:
	if not can_start_job():
		return
	var script := tools_dir().path_join("convert_kks_library.py")
	if not FileAccess.file_exists(script):
		status.text = "Place the Tools folder next to the executable."
		return
	var target := ProjectSettings.globalize_path("user://Motions")
	var catalog_copy := ProjectSettings.globalize_path("user://motion-catalog.json")
	var file := FileAccess.open(catalog_copy, FileAccess.WRITE)
	if not file:
		status.text = "Could not prepare the import request."
		return
	file.store_string(JSON.stringify({"clips": [row]}))
	file.close()
	var stage := OS.get_environment("TEMP").path_join("Myproject-KKS-menu-library")
	job_pid = OS.create_process("python", [script, game_root, catalog_copy, target, "--stage", stage, "--id", row.id, "--exact", "--decode-first"], false)
	job_path = "user://Motions/%s.kma" % row.id
	job_clip = row.id
	start_wait("Preparing %s from the local bundle." % row.name)


func can_start_job() -> bool:
	if job_pid >= 0:
		status.text = "Wait for the current import to finish."
		return false
	if not FileAccess.file_exists(game_root.path_join("CharaStudio.exe")):
		status.text = "Select your Koikatsu Sunshine installation folder first."
		return false
	return true


func start_wait(message: String) -> void:
	if job_pid < 0:
		status.text = "Could not start the converter. Clip imports require Python on PATH."
		return
	status.text = message
	set_process(true)


func _process(_delta: float) -> void:
	if OS.is_process_running(job_pid):
		return
	var successful := OS.get_process_exit_code(job_pid) == 0 and FileAccess.file_exists(job_path)
	job_pid = -1
	set_process(false)
	if not successful:
		status.text = "Import returned no data. Check the converter report."
	elif job_clip.is_empty():
		if get_parent().load_card(job_path, job_npc):
			card_sources[job_npc] = job_card
			prepared_cards[job_npc] = job_path
			status.text = "Character and clothing loaded."
		else:
			status.text = "Could not open the prepared meshes."
	else:
		status.text = "Clip is ready." if get_parent().play_npc_motion(job_clip) else "The clip has no tracks for this NPC skeleton."
		refresh_playable()
		filter()


func executable_dir() -> String:
	return OS.get_executable_path().get_base_dir()


func tools_dir() -> String:
	if OS.has_feature("editor"):
		return ProjectSettings.globalize_path("res://").path_join("../Tools").simplify_path()
	return executable_dir().path_join("Tools")
