extends CanvasLayer

const Card := preload("res://card_model.gd")
const PAGE := 150

var room: Node3D
var panel: PanelContainer
var query: LineEdit
var categories: OptionButton
var list: ItemList
var info: Label
var page_label: Label
var scrub: HSlider
var gap: SpinBox
var catalog := {}
var matches: Array = []
var page := 0
var members: Array[Node3D] = []
var tracks: Dictionary = {}
var position := 0.0
var duration := 1.0
var playing := false
var prior_mouse := Input.MOUSE_MODE_CAPTURED
var hidden: Dictionary = {}
var center := Vector3.ZERO


func _ready() -> void:
	room = get_parent()
	panel = PanelContainer.new()
	panel.set_anchors_and_offsets_preset(Control.PRESET_CENTER_LEFT)
	panel.offset_left = 15
	panel.offset_top = -235
	add_child(panel)
	var layout := VBoxContainer.new()
	layout.custom_minimum_size = Vector2(410, 455)
	panel.add_child(layout)
	categories = OptionButton.new()
	for label in ["Matched pairs", "Male clips", "Female clips", "Item / other clips"]:
		categories.add_item(label)
	categories.item_selected.connect(func(_index: int): filter())
	layout.add_child(categories)
	query = LineEdit.new()
	query.placeholder_text = "Search pose, controller or bundle"
	query.text_changed.connect(func(_text: String): filter())
	layout.add_child(query)
	list = ItemList.new()
	list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	list.item_activated.connect(play_row)
	layout.add_child(list)
	var navigation := HBoxContainer.new()
	layout.add_child(navigation)
	button(navigation, "Previous", paginate.bind(-1))
	page_label = Label.new()
	navigation.add_child(page_label)
	button(navigation, "Next", paginate.bind(1))
	button(navigation, "Play pose", func():
		if list.is_anything_selected():
			play_row(list.get_selected_items()[0]))
	button(navigation, "Close", toggle)
	var playback := HBoxContainer.new()
	layout.add_child(playback)
	button(playback, "Play / Pause", func(): playing = not playing)
	scrub = HSlider.new()
	scrub.max_value = 1.0
	scrub.step = 0.002
	scrub.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scrub.value_changed.connect(func(value: float):
		position = value
		playing = false
		seek())
	playback.add_child(scrub)
	gap = SpinBox.new()
	gap.min_value = -1.5
	gap.max_value = 1.5
	gap.step = 0.02
	gap.value = 0.42
	gap.tooltip_text = "Relative offset between the preview actors"
	gap.value_changed.connect(func(_offset: float): position_members())
	playback.add_child(gap)
	info = Label.new()
	info.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	info.custom_minimum_size.y = 44
	layout.add_child(info)
	panel.hide()
	set_process(false)


func button(parent: Control, label: String, callback: Callable) -> void:
	var control := Button.new()
	control.text = label
	control.pressed.connect(callback)
	parent.add_child(control)


func is_open() -> bool:
	return panel.visible


func toggle() -> void:
	if panel.visible:
		for member in members:
			member.queue_free()
		members.clear()
		tracks.clear()
		for actor in hidden:
			if is_instance_valid(actor):
				actor.visible = hidden[actor]
		hidden.clear()
		panel.hide()
		Input.mouse_mode = prior_mouse
		set_process(false)
		return
	if room.menu.is_open():
		room.menu.toggle()
	if room.editor.is_open():
		room.editor.toggle()
	room.npc_gameplay.close_dialogue()
	room.npc_gameplay.contact.end()
	center = room.dancer_body.global_position
	center.y = room.player.global_position.y
	for file in ["res://Content/Player.kcs", "res://Content/Npc.kcs"]:
		var actor := Card.load_actor(file)
		if not actor:
			for member in members:
				member.queue_free()
			members.clear()
			return
		room.add_child(actor)
		members.append(actor)
	for actor in [room.player_model, room.dancer_model]:
		hidden[actor] = actor.visible
		actor.hide()
	position_members()
	prior_mouse = Input.mouse_mode
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	panel.show()
	set_process(true)
	if catalog.is_empty():
		var data = JSON.parse_string(FileAccess.get_file_as_string("res://Content/pair_catalog.json"))
		if data is Dictionary:
			catalog = data
	info.text = "Choose a controller pair or inspect a single clip."
	filter()


func position_members() -> void:
	for i in range(members.size()):
		members[i].global_position = center + Vector3(0, 0, gap.value * (0.5 if i == 0 else -0.5))
		members[i].rotation.y = 0.0 if i == 0 else PI


func camera_view() -> Dictionary:
	var focus := center + Vector3.UP * 0.78 - Vector3.RIGHT * 0.37
	var eye := center + Vector3(2.30, 1.58, 1.66)
	var ray := PhysicsRayQueryParameters3D.create(focus, eye, 1, [room.player.get_rid(), room.dancer_body.get_rid()])
	var hit: Dictionary = room.get_world_3d().direct_space_state.intersect_ray(ray)
	if not hit.is_empty():
		eye = hit.position.move_toward(focus, 0.12)
	return {"eye": eye, "focus": focus}


func filter() -> void:
	matches.clear()
	var text := query.text.strip_edges().to_lower()
	var pair := categories.selected == 0
	var rows: Array = catalog.get("pairs" if pair else "clips", [])
	for row: Dictionary in rows:
		var bundle: String = row.get("bundle", "")
		if not pair:
			var lower := bundle.to_lower()
			var role := 1 if "/male/" in lower else (2 if "/female/" in lower else 3)
			if role != categories.selected:
				continue
		if text.is_empty() or text in String(row.name).to_lower() or text in bundle.to_lower() or text in String(row.get("source", "")).to_lower():
			matches.append(row)
	page = 0
	show_page()


func paginate(step: int) -> void:
	page = clampi(page + step, 0, maxi(0, (matches.size() - 1) / PAGE))
	show_page()


func show_page() -> void:
	list.clear()
	for i in range(page * PAGE, mini((page + 1) * PAGE, matches.size())):
		var row: Dictionary = matches[i]
		var name: String = row.name
		var paths: Array = [row.male, row.female] if row.has("male") else [row.id]
		for id: String in paths:
			if not FileAccess.file_exists(room.motion_path(id)):
				name += "  [missing track]"
				break
		list.add_item(name)
	page_label.text = "%d/%d · %d" % [page + 1, maxi(1, ceili(matches.size() / float(PAGE))), matches.size()]


func play_row(index: int) -> void:
	var row: Dictionary = matches[page * PAGE + index]
	if members.size() != 2:
		return
	var ids: Array = [row.male, row.female] if row.has("male") else [row.id if categories.selected == 1 else "", row.id if categories.selected != 1 else ""]
	var staged := {}
	for role in range(2):
		if ids[role].is_empty():
			continue
		var rig: Skeleton3D = members[role].get_node("Skeleton")
		var clip := Card.animation(room.motion_path(ids[role]), rig)
		if not clip or clip.get_track_count() == 0:
			info.text = "A playable body track is missing for this pose."
			return
		staged[role] = clip
	tracks.clear()
	duration = 0.01
	for role in range(2):
		var player: AnimationPlayer = members[role].get_node("AnimationPlayer")
		var rig: Skeleton3D = members[role].get_node("Skeleton")
		var library := player.get_animation_library("")
		player.stop()
		rig.reset_bone_poses()
		if library.has_animation("Preview"):
			library.remove_animation("Preview")
		if staged.has(role):
			var clip: Animation = staged[role]
			library.add_animation("Preview", clip)
			player.play("Preview")
			player.pause()
			tracks[player] = clip.length
			duration = maxf(duration, clip.length)
	position = 0.0
	playing = true
	info.text = row.name
	seek()


func seek() -> void:
	for player: AnimationPlayer in tracks:
		player.seek(position * float(tracks[player]), true)
	scrub.set_value_no_signal(position)


func _process(delta: float) -> void:
	if playing and not tracks.is_empty():
		position = fposmod(position + delta / maxf(duration, 0.01), 1.0)
		seek()
