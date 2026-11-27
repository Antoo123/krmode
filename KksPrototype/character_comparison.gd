extends CanvasLayer

const CardModel := preload("res://card_model.gd")
const CardLibrary := preload("res://card_library.gd")
const LibraryMenu := preload("res://library_menu.gd")
const OPEN_PATH := "user://CharacterComparisons"

var viewport: SubViewport
var camera := Camera3D.new()
var stage := Node3D.new()
var scenery := Node3D.new()
var key := DirectionalLight3D.new()
var world := WorldEnvironment.new()
var neutral := Environment.new()
var actor: Node3D
var card_path := ""
var materials := ItemList.new()
var maps := RichTextLabel.new()
var status := Label.new()
var room_background := CheckButton.new()
var outlines := CheckButton.new()
var old_render := CheckButton.new()
var angle := OptionButton.new()
var lighting := OptionButton.new()
var zoom := OptionButton.new()
var previous_mouse: Input.MouseMode
var outline_passes: Dictionary = {}
var subjects: Array[ShaderMaterial] = []


func _ready() -> void:
	layer = 20
	hide()
	var panel := PanelContainer.new()
	var panel_background := StyleBoxFlat.new()
	panel_background.bg_color = Color("#22242b")
	panel.add_theme_stylebox_override("panel", panel_background)
	panel.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(panel)
	var columns := HBoxContainer.new()
	panel.add_child(columns)
	var preview := SubViewportContainer.new()
	preview.stretch = true
	preview.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	columns.add_child(preview)
	viewport = SubViewport.new()
	viewport.own_world_3d = true
	viewport.msaa_3d = Viewport.MSAA_2X
	viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	preview.add_child(viewport)
	viewport.add_child(stage)
	stage.add_child(scenery)
	stage.add_child(camera)
	camera.fov = 33.0
	camera.near = 0.025
	camera.make_current()
	stage.add_child(key)
	stage.add_child(world)
	neutral.background_mode = Environment.BG_COLOR
	neutral.background_color = Color("#444954")
	world.environment = neutral

	var tools := VBoxContainer.new()
	tools.custom_minimum_size.x = 315
	columns.add_child(tools)
	var row := HBoxContainer.new()
	tools.add_child(row)
	add_button(row, "Open card…", choose_card)
	add_button(row, "Save PNG…", choose_screenshot)
	add_button(row, "Close", close)
	add_button(tools, "Neutral pose", reset_pose)
	add_options(tools, angle, ["Front", "Side", "Back"], frame_actor)
	add_options(tools, zoom, ["Full body", "Face", "Torso"], frame_actor)
	add_options(tools, lighting, ["Studio key", "Side light", "Room light"], set_light)
	add_toggle(tools, room_background, "Room background", false, set_background)
	add_toggle(tools, outlines, "Outlines", true, set_material_options)
	add_toggle(tools, old_render, "Previous shader", false, set_material_options)
	status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	tools.add_child(status)
	materials.size_flags_vertical = Control.SIZE_EXPAND_FILL
	materials.item_selected.connect(inspect_material)
	tools.add_child(materials)
	maps.size_flags_vertical = Control.SIZE_EXPAND_FILL
	maps.selection_enabled = true
	tools.add_child(maps)
	frame_actor()
	set_light()


func open() -> void:
	previous_mouse = Input.mouse_mode
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	show()
	viewport.render_target_update_mode = SubViewport.UPDATE_WHEN_VISIBLE
	load_card(card_path if not card_path.is_empty() else String(get_parent().dancer_model.get_meta("interaction_card", "res://Content/Npc.kcs")))
	set_background()
	set_light()


func close() -> void:
	hide()
	Input.mouse_mode = previous_mouse
	viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	drop_actor()
	for mesh in scenery.get_children():
		mesh.queue_free()


func add_button(parent: Control, title: String, action: Callable) -> void:
	var button := Button.new()
	button.text = title
	button.pressed.connect(action)
	parent.add_child(button)


func add_options(parent: Control, button: OptionButton, labels: Array, action: Callable) -> void:
	for title in labels:
		button.add_item(title)
	button.item_selected.connect(func(_index: int): action.call())
	parent.add_child(button)


func add_toggle(parent: Control, button: CheckButton, title: String, checked: bool, action: Callable) -> void:
	button.text = title
	button.button_pressed = checked
	button.toggled.connect(func(_checked: bool): action.call())
	parent.add_child(button)


func choose_card() -> void:
	var dialog := file_dialog(FileDialog.FILE_MODE_OPEN_FILE, PackedStringArray(["*.png,*.kcs ; Koikatsu cards"]))
	dialog.current_dir = CardLibrary.directory().get_base_dir()
	dialog.file_selected.connect(load_card)
	dialog.popup_centered_ratio(0.75)


func choose_screenshot() -> void:
	if not actor:
		return
	var dialog := file_dialog(FileDialog.FILE_MODE_SAVE_FILE, PackedStringArray(["*.png ; PNG image"]))
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OPEN_PATH))
	dialog.current_dir = ProjectSettings.globalize_path(OPEN_PATH)
	dialog.current_file = "%s-%s.png" % [card_path.get_file().get_basename(), angle.get_item_text(angle.selected).to_lower()]
	dialog.file_selected.connect(save_screenshot)
	dialog.popup_centered_ratio(0.65)


func file_dialog(mode: FileDialog.FileMode, filters: PackedStringArray) -> FileDialog:
	var dialog := FileDialog.new()
	dialog.access = FileDialog.ACCESS_FILESYSTEM
	dialog.file_mode = mode
	dialog.filters = filters
	dialog.close_requested.connect(dialog.queue_free)
	dialog.canceled.connect(dialog.queue_free)
	dialog.file_selected.connect(func(_path: String): dialog.queue_free())
	add_child(dialog)
	return dialog


func save_screenshot(path: String) -> void:
	await RenderingServer.frame_post_draw
	var result := viewport.get_texture().get_image().save_png(path)
	status.text = "Saved %s" % path.get_file() if result == OK else "Could not save PNG."


func load_card(path: String) -> void:
	var prepared := path
	if path.get_extension().to_lower() == "png":
		var file := FileAccess.open(path, FileAccess.READ)
		if not file or not CardModel.seek_portable_payload(file):
			var digest := FileAccess.get_sha256(path)
			prepared = CardLibrary.find_card(digest)
			var library = get_parent().menu
			if prepared.is_empty():
				prepared = LibraryMenu.BUNDLED_CARDS.get(digest, "")
			if prepared.is_empty():
				library.import_card(path, true, "", import_finished.bind(path))
				status.text = library.status.text
				return
	load_prepared(prepared, path)


func load_prepared(prepared: String, source: String) -> void:
	var target := CardModel.load_actor(prepared)
	if not target:
		status.text = "Could not read this character model."
		return
	drop_actor()
	actor = target
	card_path = source
	stage.add_child(actor)
	for mesh in actor.get_children():
		if mesh is not MeshInstance3D or not mesh.visible:
			continue
		for surface in mesh.mesh.get_surface_count():
			var material := mesh.get_active_material(surface) as ShaderMaterial
			if not material:
				continue
			var label := "%s / %d" % [mesh.name, surface + 1]
			materials.add_item(label)
			materials.set_item_tooltip(materials.item_count - 1, material.resource_name)
			subjects.append(material)
			outline_passes[material] = material.next_pass
	status.text = source.get_file()
	set_material_options()
	reset_pose()
	if not subjects.is_empty():
		materials.select(0)
		inspect_material(0)


func import_finished(path: String, source: String) -> void:
	if not visible:
		return
	if path.is_empty():
		status.text = get_parent().menu.status.text
		return
	load_prepared(path, source)


func drop_actor() -> void:
	if actor:
		stage.remove_child(actor)
		actor.queue_free()
		actor = null
	outline_passes.clear()
	subjects.clear()
	materials.clear()
	maps.clear()


func reset_pose() -> void:
	if actor:
		var skeleton: Skeleton3D = actor.get_node("Skeleton")
		skeleton.reset_bone_poses()
		for mesh in actor.get_children():
			if mesh is MeshInstance3D and mesh.mesh is ArrayMesh:
				for index in mesh.mesh.get_blend_shape_count():
					mesh.set_blend_shape_value(index, 0.0)
	frame_actor()


func frame_actor() -> void:
	var height := 1.60
	if actor:
		var skeleton: Skeleton3D = actor.get_node("Skeleton")
		for bone in ["cf_J_Head_s", "cm_J_Head_s", "cf_j_head", "cm_j_head"]:
			var index := skeleton.find_bone(bone)
			if index >= 0:
				height = skeleton.get_bone_global_rest(index).origin.y + 0.13
				break
	var focus: Vector3 = Vector3.UP * height * [0.51, 0.88, 0.70][zoom.selected]
	var direction: Vector3 = [Vector3.FORWARD, Vector3.RIGHT, Vector3.BACK][angle.selected]
	camera.position = focus + direction * height * [1.95, 0.64, 0.94][zoom.selected]
	camera.look_at(focus)


func set_light() -> void:
	key.light_color = Color.WHITE
	key.light_energy = 1.0
	key.rotation_degrees = [Vector3(-40, 180, 0), Vector3(-31, 95, 0), Vector3(-40, 180, 0)][lighting.selected]
	if lighting.selected == 2:
		var source: DirectionalLight3D = get_parent().character_key
		if source:
			key.rotation_degrees = source.rotation_degrees + Vector3(0, 180, 0)
			key.light_color = source.light_color
			key.light_energy = source.light_energy


func set_background() -> void:
	scenery.visible = room_background.button_pressed
	world.environment = get_parent().room_environment if scenery.visible else neutral
	if not scenery.visible or scenery.get_child_count() > 0 or not get_parent().current_room:
		return
	var offset: Vector3 = get_parent().dancer_body.global_position
	var inverse_facing := Basis(Vector3.UP, PI)
	for mesh in get_parent().current_room.find_children("*", "MeshInstance3D", true, false):
		if not mesh.mesh or not mesh.is_visible_in_tree():
			continue
		var copy := MeshInstance3D.new()
		copy.mesh = mesh.mesh
		copy.material_override = mesh.material_override
		for surface in mesh.mesh.get_surface_count():
			copy.set_surface_override_material(surface, mesh.get_surface_override_material(surface))
		copy.transform = Transform3D(inverse_facing * mesh.global_basis, inverse_facing * (mesh.global_position - offset))
		scenery.add_child(copy)


func set_material_options() -> void:
	for material in subjects:
		material.next_pass = outline_passes[material] if outlines.button_pressed else null
		material.set_shader_parameter("previous_render", old_render.button_pressed)
		if material.next_pass is ShaderMaterial:
			material.next_pass.set_shader_parameter("previous_render", old_render.button_pressed)


func inspect_material(index: int) -> void:
	var material := subjects[index]
	var details := PackedStringArray([materials.get_item_text(index)])
	if not material.resource_name.is_empty():
		details.append(material.resource_name)
	for parameter in material.shader.get_shader_uniform_list():
		var property: String = parameter.name
		var value: Variant = material.get_shader_parameter(property)
		if value is Texture2D:
			details.append("%s  %s  %d × %d" % [property, value.resource_name, value.get_width(), value.get_height()])
		elif property in ["base_tint", "shadow_tint", "cutoff"] and value != null:
			details.append("%s  %s" % [property, value])
	maps.text = "\n".join(details)
