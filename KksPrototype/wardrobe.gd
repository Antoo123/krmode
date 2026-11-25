extends AcceptDialog

const Edit := preload("res://character_edit.gd")
const CardModel := preload("res://card_model.gd")
const HAIR_CATEGORIES := {101: "Back Hair", 102: "Bangs", 103: "Side Hair", 104: "Extra Locks"}
const CLOTHING_CATEGORIES := {105: "Top", 106: "Bottom", 107: "Bra", 108: "Underwear",
	109: "Gloves", 110: "Tights", 111: "Socks", 112: "Shoes"}

var category: OptionButton
var query: LineEdit
var results: ItemList
var state: CheckButton
var summary: Label
var rows: Array = []
var sex := 1
var directory := ""


func _ready() -> void:
	min_size = Vector2i(620, 490)
	get_ok_button().text = "Close"
	var content := VBoxContainer.new()
	add_child(content)
	category = OptionButton.new()
	category.item_selected.connect(func(_index: int): refresh())
	content.add_child(category)
	query = LineEdit.new()
	query.placeholder_text = "Name or ID"
	query.text_changed.connect(func(_text: String): refresh())
	content.add_child(query)
	results = ItemList.new()
	results.size_flags_vertical = Control.SIZE_EXPAND_FILL
	results.custom_minimum_size.y = 300
	results.item_activated.connect(func(_index: int): apply_selected())
	content.add_child(results)
	state = CheckButton.new()
	state.text = "Show partially removed variant"
	content.add_child(state)
	var apply := Button.new()
	apply.text = "Apply Selected"
	apply.pressed.connect(apply_selected)
	content.add_child(apply)
	summary = Label.new()
	content.add_child(summary)


func show_for_actor(actor: Node3D, hair: bool) -> void:
	title = "Hairstyles" if hair else "Clothing"
	var categories := HAIR_CATEGORIES if hair else CLOTHING_CATEGORIES
	category.clear()
	for id in categories:
		category.add_item(categories[id], id)
	category.select(0)
	query.set_text("")
	state.set_pressed_no_signal(false)
	state.visible = not hair
	var skeleton: Skeleton3D = actor.get_node("Skeleton")
	sex = 0 if skeleton.get_bone_name(0).to_lower().begins_with("cham") else 1
	directory = OS.get_executable_path().get_base_dir().path_join("Wardrobe")
	if OS.has_feature("editor"):
		directory = ProjectSettings.globalize_path("res://../Build/KKS/Wardrobe").simplify_path()
	rows.clear()
	var data := FileAccess.get_file_as_string(directory.path_join("catalog-%d.tsv" % sex))
	for line in data.split("\n", false):
		var fields := line.strip_edges().split("\t")
		if fields.size() >= 3 and fields[0].is_valid_int() and fields[1].is_valid_int():
			rows.append([int(fields[0]), int(fields[1]), fields[2]])
	refresh()
	popup_centered()


func refresh() -> void:
	results.clear()
	var selected_category := category.get_selected_id()
	var term := query.text.strip_edges().to_lower()
	var available := 0
	var total := 0
	for item in rows:
		if item[0] != selected_category:
			continue
		total += 1
		var key := "%d-%d-%d" % [sex, item[0], item[1]]
		if not FileAccess.file_exists(directory.path_join(key + ".kcs")):
			continue
		available += 1
		if term.is_empty() or term in String(item[2]).to_lower() or term in str(item[1]):
			var name: String = item[2]
			for character in name:
				var code := character.unicode_at(0)
				if code >= 0x3000 or (code >= 0x0400 and code <= 0x052f):
					name = "%s item" % (HAIR_CATEGORIES.get(item[0], CLOTHING_CATEGORIES.get(item[0], "Wardrobe")))
					break
			results.add_item("%s  ·  #%d" % [name, item[1]])
			results.set_item_metadata(results.item_count - 1, key)
	summary.text = "%d of %d available in this slot" % [available, total] if not rows.is_empty() else "Wardrobe catalog missing. Place the Wardrobe folder next to the executable."


func apply_selected() -> void:
	var selection := results.get_selected_items()
	if selection.is_empty():
		return
	var entry: String = results.get_item_metadata(selection[0])
	var path := directory.path_join(entry + ".kcs")
	var half := directory.path_join(entry + "-half.kcs")
	if state.button_pressed:
		if not FileAccess.file_exists(half):
			summary.text = "This item has no prepared partially removed variant."
			return
		path = half
	var donor := CardModel.load_actor(path)
	if not donor:
		summary.text = "Could not read the item data."
		return
	var editor := get_parent()
	var applied := Edit.replace_piece(editor.current_actor(), donor, category.get_selected_id())
	donor.free()
	if applied:
		editor.refresh()
		summary.text = "Item applied."
	else:
		summary.text = "This item is incompatible with the selected character."
