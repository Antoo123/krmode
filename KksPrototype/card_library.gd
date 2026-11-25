extends AcceptDialog

signal card_selected(path: String)

var entries: Array = []
var qa_cards := false
var search: LineEdit
var results: ItemList
var summary: Label


static func directory() -> String:
	if OS.has_feature("editor"):
		return ProjectSettings.globalize_path("res://../Build/KKS/Cards/Koikatsu").simplify_path()
	return OS.get_executable_path().get_base_dir().path_join("Cards/Koikatsu")


static func read_catalog() -> Array:
	var index := directory().path_join("catalog.json")
	if not FileAccess.file_exists(index):
		return []
	var data: Variant = JSON.parse_string(FileAccess.get_file_as_string(index))
	return data if data is Array else []


static func qa_catalog() -> Array:
	var index := directory().get_base_dir().path_join("QA/catalog.json")
	if not FileAccess.file_exists(index):
		return []
	var data: Variant = JSON.parse_string(FileAccess.get_file_as_string(index))
	return data if data is Array else []


static func qa_preset(id: String) -> Dictionary:
	for row in qa_catalog():
		if row is Dictionary and row.get("id") == id:
			return row
	return {}


static func qa_card(row: Dictionary) -> String:
	var relative: String = row.get("card", "")
	if relative.is_empty() or relative.is_absolute_path() or relative.simplify_path() != relative or relative.begins_with("../"):
		return ""
	var path := directory().get_base_dir().path_join(relative)
	return path if FileAccess.file_exists(path) else ""


static func ready_path(row: Variant) -> String:
	if row is not Dictionary or row.get("status") != "ready":
		return ""
	var local: String = row.get("path", "")
	if local.is_empty() or local.is_absolute_path() or local.begins_with("../") or local.simplify_path() != local:
		return ""
	var path := directory().path_join(local)
	return path if FileAccess.file_exists(path) else ""


static func find_card(digest: String) -> String:
	if digest.is_empty():
		return ""
	for row in read_catalog():
		if row is Dictionary and row.get("sha256") == digest:
			var path := ready_path(row)
			if not path.is_empty():
				return path
	return ""


func _ready() -> void:
	title = "Koikatsu Cards"
	min_size = Vector2i(650, 480)
	get_ok_button().text = "Load"
	confirmed.connect(load_selected)
	var content := VBoxContainer.new()
	add_child(content)
	search = LineEdit.new()
	search.placeholder_text = "Card or folder name"
	search.text_changed.connect(func(_value: String): filter())
	content.add_child(search)
	results = ItemList.new()
	results.custom_minimum_size.y = 350
	results.size_flags_vertical = Control.SIZE_EXPAND_FILL
	results.item_activated.connect(func(_index: int):
		load_selected()
		hide())
	content.add_child(results)
	summary = Label.new()
	content.add_child(summary)


func show_catalog(test_characters := false) -> void:
	qa_cards = test_characters
	title = "Test Characters / QA" if qa_cards else "Koikatsu Cards"
	entries = qa_catalog() if qa_cards else read_catalog()
	search.clear()
	filter()
	popup_centered()
	search.grab_focus()


func filter() -> void:
	results.clear()
	var query := search.text.strip_edges().to_lower()
	var available := 0
	for row in entries:
		if qa_cards:
			if row is not Dictionary:
				continue
			var id: String = row.get("id", "")
			if not id.is_empty() and not qa_card(row).is_empty():
				available += 1
				if query.is_empty() or query in id.to_lower():
					results.add_item(id)
					results.set_item_tooltip(results.item_count - 1, row.get("description", ""))
					results.set_item_metadata(results.item_count - 1, "qa://" + id)
			continue
		var path := ready_path(row)
		if path.is_empty():
			continue
		available += 1
		var source: String = row.get("source", path.get_file())
		if query.is_empty() or query in source.to_lower():
			var origin := "Bundled" if source.begins_with("DefaultData/") else "From UserData"
			results.add_item("%s  ·  %s" % [source.get_file().get_basename(), origin])
			results.set_item_tooltip(results.item_count - 1, source)
			results.set_item_metadata(results.item_count - 1, path)
	if results.item_count > 0:
		results.select(0)
	summary.text = "%d of %d ready · %d found" % [available, entries.size(), results.item_count]


func load_selected() -> void:
	var selected := results.get_selected_items()
	if not selected.is_empty():
		card_selected.emit(results.get_item_metadata(selected[0]))
