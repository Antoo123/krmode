extends RefCounted

const FOLDER := "user://POVHands"
const EXAMPLES := "res://Content/F7/HandPresets"
const ASSIGNMENTS := FOLDER + "/assignments.cfg"
const ASSETS := ["p_handL", "p_handR", "p_fingerL", "p_fingerR"]


static func create(asset: String, zone: int, bone: String) -> Dictionary:
	return {"version": 1, "name": "Новая анимация", "asset": asset, "zone": zone, "bone": bone,
		"duration": 1.0, "loop": true, "interpolation": "smooth", "finger_layer": 0, "finger_speed": 1.0,
		"offset": frame(0.0, Transform3D.IDENTITY), "positions": {}, "keys": []}


static func frame(time: float, pose: Transform3D) -> Dictionary:
	var p := pose.origin
	var r := pose.basis.orthonormalized().get_euler() * (180.0 / PI)
	return {"time": time, "position": [p.x, p.y, p.z], "rotation": [r.x, r.y, r.z]}


static func transform(value: Dictionary) -> Transform3D:
	var p: Array = value.position
	var r: Array = value.rotation
	return Transform3D(Basis.from_euler(Vector3(r[0], r[1], r[2]) * (PI / 180.0)), Vector3(p[0], p[1], p[2]))


static func adjustment(preset: Dictionary, position_id: int) -> Transform3D:
	var result := transform(preset.offset)
	var correction: Variant = preset.positions.get(str(position_id))
	return result * transform(correction) if correction is Dictionary else result


static func sample(preset: Dictionary, time: float) -> Transform3D:
	var keys: Array = preset.keys
	if keys.is_empty():
		return Transform3D.IDENTITY
	if time <= float(keys[0].time):
		return transform(keys[0])
	for index in range(1, keys.size()):
		var right: Dictionary = keys[index]
		if time <= float(right.time):
			var left: Dictionary = keys[index - 1]
			var weight := inverse_lerp(float(left.time), float(right.time), time)
			if preset.interpolation == "smooth":
				weight = smoothstep(0.0, 1.0, weight)
			return transform(left).interpolate_with(transform(right), weight)
	return transform(keys[-1])


static func read(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}
	var file := FileAccess.open(path, FileAccess.READ)
	if not file or file.get_length() > 2097152:
		return {}
	var decoded: Variant = JSON.parse_string(file.get_as_text())
	if not decoded is Dictionary:
		return {}
	return validate(decoded)


static func validate(value: Dictionary) -> Dictionary:
	if value.get("version") == 2:
		var tracks: Variant = value.get("tracks")
		if not tracks is Dictionary or not value.get("name") is String or String(value.name).strip_edges().is_empty() or String(value.name).length() > 96:
			return {}
		for side in ["L", "R"]:
			var track: Variant = tracks.get(side)
			if not track is Dictionary or track.get("version") != 1 or validate(track).is_empty():
				return {}
			if not String(track.asset).ends_with(side) or not track.has("contact"):
				return {}
		return value
	if value.get("version") != 1:
		return {}
	if (not value.get("name") is String or String(value.name).strip_edges().is_empty()
			or String(value.name).length() > 96 or not value.get("bone") is String
			or String(value.bone).is_empty() or String(value.bone).length() > 160):
		return {}
	if (value.get("asset") not in ASSETS or not _number(value.get("zone"), 0.0, 5.0)
			or not _number(value.get("duration"), 0.1, 120.0) or not value.get("loop") is bool
			or value.get("interpolation") not in ["linear", "smooth"]
			or not _number(value.get("finger_layer"), -1.0, 99.0)
			or not _number(value.get("finger_speed"), 0.05, 8.0)):
		return {}
	if int(value.zone) != value.zone or int(value.finger_layer) != value.finger_layer:
		return {}
	if not _frame(value.get("offset")) or not value.get("positions") is Dictionary or not value.get("keys") is Array:
		return {}
	if value.has("contact") and not _contact(value.contact, float(value.duration)):
		return {}
	for id: String in value.positions:
		if not id.is_valid_int() or int(id) < 0 or int(id) > 10 or not _frame(value.positions[id]):
			return {}
	if value.keys.size() > 1000:
		return {}
	var previous := -1.0
	for key: Variant in value.keys:
		if not _frame(key) or not _number(key.get("time"), 0.0, value.duration) or float(key.time) - previous < 0.00001:
			return {}
		previous = float(key.time)
	return value


static func bound_contact(bindings: ConfigFile, kind: String) -> Dictionary:
	var path := String(bindings.get_value("contacts", kind, ""))
	var edited := read(path) if path.begins_with(FOLDER + "/") else {}
	if edited.get("contact", {}).get("kind", "") == kind:
		return edited
	var name := "take_hand" if kind == "hand" else "stroke_" + kind
	return read(EXAMPLES.path_join(name + ".json"))


static func bound_surface(bindings: ConfigFile, action: String, side: String) -> Dictionary:
	if action in ["stroke_thigh", "stroke_belly", "take_hand"]:
		var kind := "hand" if action == "take_hand" else action.trim_prefix("stroke_")
		var legacy := bound_contact(bindings, kind)
		if not legacy.is_empty() and String(legacy.asset).right(1) != side:
			legacy.asset = String(legacy.asset).left(-1) + side
		return legacy
	var path := String(bindings.get_value("surface_actions", action + "/" + side, ""))
	var value := read(path) if path.begins_with(FOLDER + "/") else {}
	if value.get("action") == action and String(value.get("asset", "")).ends_with(side):
		return value
	return {}


static func _contact(value: Variant, duration: float) -> bool:
	return (value is Dictionary and value.get("kind") in ["thigh", "belly", "hand", "side", "foot", "ankle", "crown", "chest", "lap", "seat", "chin", "cheek"]
		and value.get("side") in ["L", "R"]
		and _number(value.get("amplitude"), 0.0, 2.0)
		and _number(value.get("speed"), 0.1, 4.0)
		and _number(value.get("approach"), 0.1, 10.0)
		and _number(value.get("release"), 0.1, 10.0)
		and float(value.approach) + float(value.release) < duration - 0.05)


static func contact_key(preset: Dictionary, key: Transform3D) -> Transform3D:
	var scaled := key
	scaled.origin *= float(preset.contact.amplitude)
	return scaled


static func store(path: String, preset: Dictionary) -> Error:
	var target := ProjectSettings.globalize_path(path)
	var temporary := target + ".part"
	var file := FileAccess.open(temporary, FileAccess.WRITE)
	if not file:
		return FileAccess.get_open_error()
	file.store_string(JSON.stringify(preset, "\t") + "\n")
	file.flush()
	var issue := file.get_error()
	file.close()
	if issue != OK:
		DirAccess.remove_absolute(temporary)
		return issue
	issue = DirAccess.rename_absolute(temporary, target)
	if issue != OK:
		DirAccess.remove_absolute(temporary)
	return issue


static func _frame(value: Variant) -> bool:
	if not value is Dictionary:
		return false
	for name in ["position", "rotation"]:
		var components: Variant = value.get(name)
		if not components is Array or components.size() != 3:
			return false
		for component: Variant in components:
			if not _number(component, -3600.0, 3600.0):
				return false
	return true


static func _number(value: Variant, lower: float, upper: float) -> bool:
	return (value is float or value is int) and is_finite(float(value)) and float(value) >= lower and float(value) <= upper
