extends CanvasLayer

const Edit := preload("res://character_edit.gd")
const CardModel := preload("res://card_model.gd")
const Wardrobe := preload("res://wardrobe.gd")

var panel: PanelContainer
var role: OptionButton
var clothes: VBoxContainer
var size_controls: Array[HSlider] = []
var status: Label
var donor_picker: FileDialog
var wardrobe: AcceptDialog
var anatomy_dialog: AcceptDialog
var anatomy_choices: OptionButton
var pick_outfit := false
var editing_camera := Camera3D.new()
var previous_mouse := Input.MOUSE_MODE_CAPTURED
var preview_distance := 2.15
var free_camera: CheckButton
var looking := false


func _ready() -> void:
	get_parent().add_child.call_deferred(editing_camera)
	editing_camera.fov = 47
	panel = PanelContainer.new()
	panel.position = Vector2(24, 24)
	panel.custom_minimum_size.x = 310
	add_child(panel)
	panel.set_anchor_and_offset(SIDE_BOTTOM, 1.0, -24)
	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	panel.add_child(scroll)
	var body := VBoxContainer.new()
	body.add_theme_constant_override("separation", 7)
	body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(body)
	role = OptionButton.new()
	role.add_item("NPC")
	role.add_item("Player")
	role.item_selected.connect(func(_index: int): refresh())
	body.add_child(role)
	free_camera = CheckButton.new()
	free_camera.text = "Free Camera"
	free_camera.tooltip_text = "Hold Right Mouse to look. WASD to fly, Q/E to descend or ascend."
	body.add_child(free_camera)
	var camera_hint := Label.new()
	camera_hint.text = "Right Mouse to look · WASD/QE to fly"
	camera_hint.hide()
	body.add_child(camera_hint)
	free_camera.toggled.connect(func(enabled: bool):
		stop_looking()
		camera_hint.visible = enabled)
	button(body, "Center on Character", func(): free_camera.button_pressed = false)
	wardrobe = Wardrobe.new()
	add_child(wardrobe)
	var catalogs := HBoxContainer.new()
	body.add_child(catalogs)
	button(catalogs, "Clothing", func(): wardrobe.show_for_actor(current_actor(), false))
	button(catalogs, "Hairstyles", func(): wardrobe.show_for_actor(current_actor(), true))
	button(body, "Anatomy Profile", show_anatomy)
	button(body, "Toggle Clothing", func(): quick_toggle(role.selected == 0))
	clothes = VBoxContainer.new()
	body.add_child(clothes)
	button(body, "Outfit from Card", func(): choose_donor(true))
	button(body, "Hair from Card", func(): choose_donor(false))
	var presets := HBoxContainer.new()
	body.add_child(presets)
	button(presets, "NPC Hair", func(): apply_hair("res://Content/Npc.kcs"))
	button(presets, "Player Hair", func(): apply_hair("res://Content/Player.kcs"))
	add_size(body, "Height", Vector3.UP)
	add_size(body, "Width", Vector3.RIGHT)
	add_size(body, "Depth", Vector3.BACK)
	button(body, "Reset Proportions", reset_size)
	status = Label.new()
	status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	body.add_child(status)
	button(body, "Close", func(): toggle())
	donor_picker = FileDialog.new()
	donor_picker.access = FileDialog.ACCESS_FILESYSTEM
	donor_picker.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	donor_picker.filters = ["*.kcs, *.png ; Prepared Character Card"]
	donor_picker.file_selected.connect(apply_donor)
	add_child(donor_picker)
	anatomy_dialog = AcceptDialog.new()
	anatomy_dialog.title = "Anatomy Profile"
	anatomy_dialog.get_ok_button().text = "Load"
	var anatomy_content := VBoxContainer.new()
	var anatomy_description := Label.new()
	anatomy_description.text = "Loads a prepared character with the selected body."
	anatomy_content.add_child(anatomy_description)
	anatomy_choices = OptionButton.new()
	anatomy_content.add_child(anatomy_choices)
	anatomy_dialog.add_child(anatomy_content)
	anatomy_dialog.confirmed.connect(apply_anatomy)
	add_child(anatomy_dialog)
	panel.hide()
	set_process(false)


func button(parent: Control, caption: String, pressed: Callable) -> void:
	var item := Button.new()
	item.text = caption
	item.pressed.connect(pressed)
	parent.add_child(item)


func current_actor() -> Node3D:
	return get_parent().dancer_model if role.selected == 0 else get_parent().player_model


func is_open() -> bool:
	return panel.visible


func toggle(npc: bool = true) -> void:
	if is_open():
		stop_looking()
		free_camera.button_pressed = false
		wardrobe.hide()
		donor_picker.hide()
		anatomy_dialog.hide()
		panel.hide()
		get_parent().set_inspection_mode(false)
		get_parent().camera.make_current()
		Input.mouse_mode = previous_mouse
		set_process(false)
		return
	previous_mouse = Input.mouse_mode
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	role.select(0 if npc else 1)
	panel.show()
	get_parent().set_inspection_mode(true)
	refresh()
	editing_camera.make_current()
	set_process(true)


func quick_toggle(npc: bool) -> void:
	var actor: Node3D = get_parent().dancer_model if npc else get_parent().player_model
	var put_on := not Edit.is_dressed(actor)
	if Edit.set_clothes(actor, put_on):
		status.text = "Clothing visible." if put_on else "Clothing hidden."
	else:
		status.text = "This character has no recognized clothing."
	if is_open():
		refresh()


func refresh() -> void:
	var actor := current_actor()
	for child in clothes.get_children():
		clothes.remove_child(child)
		child.queue_free()
	var garments := Edit.slots(actor)
	for slot in garments:
		if slot == Edit.HAIR:
			continue
		var check := CheckBox.new()
		check.text = slot
		check.button_pressed = Edit.group_visible(garments, [slot])
		check.toggled.connect(func(enabled: bool): Edit.set_clothes(current_actor(), enabled, slot))
		clothes.add_child(check)
	var proportions := [actor.scale.y, actor.scale.x, actor.scale.z]
	for i in range(size_controls.size()):
		size_controls[i].set_value_no_signal(proportions[i])


func show_anatomy() -> void:
	anatomy_choices.clear()
	var actor := current_actor()
	var skeleton: Skeleton3D = actor.get_node("Skeleton")
	var male := skeleton.get_bone_name(0).to_lower().begins_with("cham")
	var default_card := "res://Content/Player.kcs" if male else "res://Content/Npc.kcs"
	anatomy_choices.add_item("Bundled Card")
	anatomy_choices.set_item_metadata(0, default_card)
	var folder := OS.get_executable_path().get_base_dir().path_join("Anatomy")
	if OS.has_feature("editor"):
		folder = ProjectSettings.globalize_path("res://../Build/KKS/Anatomy").simplify_path()
	var catalog := folder.path_join("catalog.tsv")
	if FileAccess.file_exists(catalog):
		for row in FileAccess.get_file_as_string(catalog).split("\n", false):
			var fields := row.strip_edges().split("\t")
			if fields.size() != 3 or fields[0] != ("0" if male else "1"):
				continue
			var file := fields[2]
			if file.get_file() != file or file.get_extension().to_lower() != "kcs":
				continue
			var path := folder.path_join(file)
			if FileAccess.file_exists(path):
				anatomy_choices.add_item(fields[1])
				anatomy_choices.set_item_metadata(anatomy_choices.item_count - 1, path)
	var active_path: String = actor.get_meta("anatomy_profile_path", default_card)
	for index in range(anatomy_choices.item_count):
		if anatomy_choices.get_item_metadata(index) == active_path:
			anatomy_choices.select(index)
			break
	anatomy_dialog.popup_centered()


func apply_anatomy() -> void:
	if anatomy_choices.selected < 0:
		return
	var path: String = anatomy_choices.get_item_metadata(anatomy_choices.selected)
	var previous := current_actor()
	var scale := previous.scale
	var garments := Edit.slots(previous)
	var was_dressed := Edit.is_dressed(previous)
	var npc := role.selected == 0
	if not get_parent().load_card(path, npc):
		status.text = "Could not load the anatomy profile."
		return
	var actor := current_actor()
	actor.scale = scale
	actor.set_meta("anatomy_profile_path", path)
	if was_dressed:
		for slot: String in garments:
			if slot != Edit.HAIR and not Edit.group_visible(garments, [slot]):
				Edit.set_clothes(actor, false, slot)
	else:
		Edit.set_clothes(actor, false)
	get_parent().menu.clear_card_source(npc)
	status.text = "Anatomy profile loaded."
	refresh()


func apply_hair(path: String) -> void:
	pick_outfit = false
	apply_donor(path)


func choose_donor(outfit: bool) -> void:
	pick_outfit = outfit
	donor_picker.popup_centered_ratio(0.7)


func apply_donor(path: String) -> void:
	var donor := CardModel.load_actor(path)
	if not donor:
		status.text = "Open a portable PNG or .kcs."
		return
	var applied := Edit.replace_outfit(current_actor(), donor) if pick_outfit else Edit.replace_hair(current_actor(), donor)
	donor.free()
	if applied:
		status.text = "Outfit replaced." if pick_outfit else "Hair replaced."
		refresh()
	else:
		status.text = "The card has no compatible parts for this character."


func add_size(parent: Control, caption: String, axis: Vector3) -> void:
	var row := HBoxContainer.new()
	parent.add_child(row)
	var label := Label.new()
	label.text = caption
	label.custom_minimum_size.x = 85
	row.add_child(label)
	var slider := HSlider.new()
	slider.min_value = 0.78
	slider.max_value = 1.22
	slider.step = 0.01
	slider.value = 1.0
	slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	slider.value_changed.connect(func(value: float):
		var actor := current_actor()
		actor.scale = actor.scale * (Vector3.ONE - axis) + axis * value)
	row.add_child(slider)
	size_controls.append(slider)


func reset_size() -> void:
	current_actor().scale = Vector3.ONE
	refresh()


func zoom(amount: float) -> void:
	if free_camera.button_pressed:
		editing_camera.global_position += editing_camera.global_basis.z.normalized() * amount
	else:
		preview_distance = clampf(preview_distance + amount, 0.8, 3.5)


func stop_looking() -> void:
	if looking:
		looking = false
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_FOCUS_OUT:
		stop_looking()


func camera_input(event: InputEvent) -> bool:
	if not free_camera.button_pressed:
		return false
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_RIGHT:
		if event.pressed:
			looking = true
			Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
		else:
			stop_looking()
		return true
	if looking and event is InputEventMouseMotion:
		editing_camera.rotation.y -= event.relative.x * 0.003
		editing_camera.rotation.x = clampf(editing_camera.rotation.x - event.relative.y * 0.003, -1.52, 1.52)
		return true
	return false


func _process(delta: float) -> void:
	if free_camera.button_pressed:
		if looking:
			var step := Vector3(
				float(Input.is_physical_key_pressed(KEY_D)) - float(Input.is_physical_key_pressed(KEY_A)),
				float(Input.is_physical_key_pressed(KEY_E)) - float(Input.is_physical_key_pressed(KEY_Q)),
				float(Input.is_physical_key_pressed(KEY_S)) - float(Input.is_physical_key_pressed(KEY_W)))
			editing_camera.global_position += editing_camera.global_basis * step.limit_length() * delta * 2.4
		return
	var actor := current_actor()
	var forward := -actor.global_basis.z.normalized()
	var side := actor.global_basis.x.normalized()
	var focus := actor.global_position + Vector3.UP * 0.85 * actor.scale.y
	var desired := focus + forward * preview_distance + Vector3.UP * 0.27
	var hit := actor.get_world_3d().direct_space_state.intersect_ray(
		PhysicsRayQueryParameters3D.create(focus, desired, 1, [get_parent().dancer_body.get_rid()]))
	if not hit.is_empty():
		desired = hit.position - forward * 0.12
	editing_camera.global_position = desired
	editing_camera.look_at(focus + side * 0.55)
