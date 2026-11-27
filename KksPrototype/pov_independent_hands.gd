extends VBoxContainer

const Hands := preload("res://animation_lab_hands.gd")
const Actions := preload("res://pov_hand_actions.gd")
const Preset := preload("res://hand_animation_preset.gd")

var lab: Node
var bindings: ConfigFile
var extra_actions: Dictionary = {}
var runners: Array[Node3D] = []
var controls: Array[Dictionary] = []
var pending: Array[Dictionary] = [{}, {}]
var mode := OptionButton.new()
var pair := OptionButton.new()
var status := Label.new()
var reaction_enabled := CheckButton.new()
var reaction_mode := OptionButton.new()
var intensity := SpinBox.new()
var camera_weight := 0.0
var camera_focus := Vector3.ZERO
var camera_eye := Vector3.ZERO


func setup(owner_lab: Node, preset_bindings: ConfigFile, additional := {}) -> void:
	lab = owner_lab
	bindings = preset_bindings
	extra_actions = additional
	for i in 2:
		var runner := Hands.new()
		runner.managed_side = i
		lab.stage.add_child(runner)
		runners.append(runner)
	var toolbar := HFlowContainer.new()
	add_child(toolbar)
	_label(toolbar, "Hand Mode")
	for option in ["Left", "Right", "Both"]:
		mode.add_item(option)
	mode.select(2)
	mode.item_selected.connect(_mode_changed)
	toolbar.add_child(mode)
	_button(toolbar, "Start selected", start_selected)
	_button(toolbar, "Release both", release_all)
	_label(toolbar, "Pair preset")
	pair.fit_to_longest_item = false
	pair.custom_minimum_size.x = 140.0
	pair.item_selected.connect(_select_pair)
	toolbar.add_child(pair)
	for i in 2:
		_make_side(i)
	var reactions := HFlowContainer.new()
	add_child(reactions)
	reaction_enabled.text = "NPC reaction"
	reaction_enabled.button_pressed = true
	reactions.add_child(reaction_enabled)
	for variant in ["Automatic", "Gaze and face", "Body only"]:
		reaction_mode.add_item(variant)
	reactions.add_child(reaction_mode)
	intensity.min_value = 0.0
	intensity.max_value = 1.5
	intensity.step = 0.05
	intensity.value = 1.0
	intensity.tooltip_text = "Reaction intensity"
	reactions.add_child(intensity)
	add_child(status)
	refresh_pairs()
	hide()


func _make_side(index: int) -> void:
	var row := HFlowContainer.new()
	add_child(row)
	_label(row, "Left Hand" if index == 0 else "Right Hand")
	var zone := OptionButton.new()
	var areas := ["Sides", "Feet", "Crown", "Thigh", "Belly", "Hand", "Face"]
	if not extra_actions.is_empty():
		areas.push_front("Original KKS")
	for area in areas:
		zone.add_item(area)
	zone.item_selected.connect(_fill_actions.bind(index))
	row.add_child(zone)
	var action := OptionButton.new()
	action.fit_to_longest_item = false
	action.custom_minimum_size.x = 128.0
	action.item_selected.connect(_action_changed.bind(index))
	row.add_child(action)
	var clip := OptionButton.new()
	clip.fit_to_longest_item = false
	clip.custom_minimum_size.x = 106.0
	clip.tooltip_text = "Finger animation"
	row.add_child(clip)
	var speed := SpinBox.new()
	speed.min_value = 0.25
	speed.max_value = 3.0
	speed.step = 0.05
	speed.value = 1.0
	speed.suffix = "x"
	speed.tooltip_text = "Hand speed"
	row.add_child(speed)
	speed.value_changed.connect(func(value: float): runners[index].motion_speed = value)
	var start := _button(row, "Contact", _start_from_ui.bind(index))
	_button(row, "Release", release.bind(index))
	controls.append({"zone": zone, "action": action, "clip": clip, "speed": speed, "start": start})
	_fill_actions(0, index)


func _fill_actions(area: int, index: int) -> void:
	var row := controls[index]
	row.action.clear()
	for id: String in Actions.ACTIONS:
		if Actions.ACTIONS[id][0] == row.zone.get_item_text(area):
			row.action.add_item(id.replace("_", " ").capitalize())
			row.action.set_item_metadata(row.action.item_count - 1, id)
	if row.zone.get_item_text(area) == "Original KKS":
		for id: String in extra_actions:
			row.action.add_item(extra_actions[id])
			row.action.set_item_metadata(row.action.item_count - 1, id)
	if row.action.item_count > 0:
		row.action.select(0)
	_action_changed(0, index)


func _action_changed(_item: int, index: int) -> void:
	var row := controls[index]
	row.clip.clear()
	row.clip.add_item("Preset animation", -1)
	row.clip.set_item_metadata(0, -2)
	row.clip.add_item("Relaxed fingers", -1)
	row.clip.set_item_metadata(1, -1)
	var base: Node3D = lab.stage.green_hands
	for layer: int in base.finger_layers(index):
		row.clip.add_item(base.item_label(index, layer), layer)
		row.clip.set_item_metadata(row.clip.item_count - 1, layer)
	row.clip.select(0)


func activate(active: bool) -> void:
	visible = active
	cancel()
	var base: Node3D = lab.stage.green_hands
	for i in 2:
		var runner := runners[i]
		runner.items = base.items
		runner.layer_names = base.layer_names
		runner.reference = base.reference
		runner.enabled = active
		_action_changed(0, i)
	if active:
		refresh_pairs()
		_mode_changed(mode.selected)


func _mode_changed(index: int) -> void:
	for i in 2:
		var allowed := index == 2 or index == i
		controls[i].start.disabled = not allowed
		if not allowed:
			release(i)


func _start_from_ui(index: int) -> void:
	var preset := selected(index)
	var issue := start(index, preset)
	status.text = preset.get("name", "") if issue.is_empty() else issue


func selected(index: int) -> Dictionary:
	var side := "L" if index == 0 else "R"
	var row := controls[index]
	var action: String = row.action.get_selected_metadata()
	var preset := preset_for(action, side)
	if preset.is_empty():
		return {}
	var layer := int(row.clip.get_selected_metadata())
	if layer != -2:
		preset.finger_layer = layer
	return preset


func preset_for(action: String, side: String) -> Dictionary:
	var preset := Preset.bound_surface(bindings, action, side)
	if not preset.is_empty():
		preset.action = action
		return preset
	if extra_actions.has(action):
		return lab.native_preset(action, side)
	return Actions.make(action, side)


func can_start(index: int, preset: Dictionary) -> String:
	if not visible or lab.stage.duration <= 0.0 or not is_instance_valid(lab.stage.actors[1]):
		return "Select a green position and state first."
	if mode.selected != 2 and mode.selected != index:
		return "This hand is disabled by Hand Mode."
	if preset.is_empty() or not preset.has("contact"):
		return "No contact track is selected."
	if String(preset.asset).right(1) != ("L" if index == 0 else "R"):
		return "The preset belongs to the other hand."
	var rig: Skeleton3D = lab.stage.actors[1].get_node("Skeleton")
	if Hands.Contact.anchor(rig, preset.contact).is_empty():
		return "The contact bones are unavailable on this card."
	return ""


func start(index: int, preset: Dictionary) -> String:
	var issue := can_start(index, preset)
	if not issue.is_empty():
		return issue
	var runner := runners[index]
	if runner.tool_id >= 0:
		pending[index] = preset.duplicate(true)
		runner.release()
	else:
		_begin(index, preset)
	return ""


func _begin(index: int, preset: Dictionary) -> void:
	var runner := runners[index]
	runner.pose_id = lab.stage.green_hands.pose_id
	runner.motion_speed = controls[index].speed.value
	var issue: String = runner.start_contact_preset(lab.stage.actors[1], preset.duplicate(true))
	if not issue.is_empty():
		status.text = issue


func start_selected() -> void:
	var path: String = pair.get_selected_metadata()
	var bundled := Preset.read(path) if not path.is_empty() else {}
	var starting: Array[Dictionary] = [{}, {}]
	for i in 2:
		if mode.selected != 2 and mode.selected != i:
			continue
		starting[i] = bundled.tracks["L" if i == 0 else "R"] if not bundled.is_empty() else selected(i)
		var issue := can_start(i, starting[i])
		if not issue.is_empty():
			status.text = issue
			return
	for i in 2:
		if not starting[i].is_empty():
			start(i, starting[i])
	status.text = bundled.get("name", "Contacts started")


func release(index: int) -> void:
	pending[index] = {}
	runners[index].release()


func release_all() -> void:
	for i in 2:
		release(i)


func cancel() -> void:
	for i in runners.size():
		pending[i] = {}
		runners[i].cancel()
		runners[i].contact_motion.cache_key = ""
	camera_weight = 0.0


func advance(delta: float) -> void:
	if not visible:
		return
	for i in 2:
		var runner := runners[i]
		if runner.tool_id >= 0:
			runner.tick(delta)
			if runner.running and not runner.mouse_control and runner.custom_animation.get("action") == "gentle_head_touch":
				var elapsed := float(runner.custom_animation.duration) - float(runner.custom_animation.contact.release)
				if runner.custom_time >= elapsed:
					runner.release()
		if runner.tool_id < 0 and not pending[i].is_empty():
			var next := pending[i]
			pending[i] = {}
			if can_start(i, next).is_empty():
				_begin(i, next)
	var same := false
	if runners[0].tool_id >= 0 and runners[1].tool_id >= 0:
		var a: Dictionary = runners[0].custom_animation.contact
		var b: Dictionary = runners[1].custom_animation.contact
		same = a.kind == b.kind and (a.side == b.side or a.kind in ["belly", "crown"])
	for i in 2:
		var runner := runners[i]
		runner.contact_lane = move_toward(runner.contact_lane, (i * 2 - 1) * 0.041 if same else 0.0, delta * 0.24)


func draw_hands(actor: Node3D, eye: Transform3D) -> void:
	for i in 2:
		var runner := runners[i]
		runner.show_hands = lab.stage.green_hands.show_hands and (mode.selected == 2 or mode.selected == i or runner.tool_id >= 0)
		runner.debug = lab.stage.green_hands.debug
		runner.draw(actor, eye)


func view_camera(actor: Node3D, base: Node3D) -> Transform3D:
	var original: Transform3D = base.camera_pose(actor)
	var total := 0.0
	var focus := Vector3.ZERO
	var eye := Vector3.ZERO
	var points: Array[Vector3] = []
	var crown_frame := Transform3D.IDENTITY
	var crown_contacts := 0
	var rig: Skeleton3D = actor.get_node("Skeleton")
	for runner in runners:
		if runner.tool_id < 0 or runner.blend < 0.01:
			continue
		var anchored := Hands.Contact.anchor(rig, runner.custom_animation.contact)
		if anchored.is_empty():
			continue
		var point: Vector3 = anchored.frame.origin
		if runner.custom_animation.contact.kind == "crown":
			crown_frame = anchored.frame
			crown_contacts += 1
		var frame: Transform3D = base.frame_contact_camera(actor, original, runner.custom_animation.contact)
		var weight: float = runner.blend
		points.append(point)
		total += weight
		focus += point * weight
		eye += frame.origin * weight
	if total > 0.0:
		focus /= total
		eye /= total
		if crown_contacts == 2:
			var forward := crown_frame.basis.y
			if forward.dot(original.origin - focus) < 0.0:
				forward = -forward
			eye = focus + crown_frame.basis.z * 0.77 + forward * 0.59
		elif points.size() == 2:
			var original_direction := (original.origin - focus).normalized()
			var span := points[0].distance_to(points[1])
			eye = focus + original_direction * maxf(1.12, span * 1.80)
		camera_focus = camera_focus.lerp(focus, 0.18) if camera_weight > 0.001 else focus
		camera_eye = camera_eye.lerp(eye, 0.18) if camera_weight > 0.001 else eye
	camera_weight = lerpf(camera_weight, clampf(total, 0.0, 1.0), 0.16)
	if camera_weight < 0.001 or camera_focus.distance_squared_to(camera_eye) < 0.002:
		return original
	var direction := camera_eye.direction_to(camera_focus)
	var up := Vector3.UP if absf(direction.dot(Vector3.UP)) < 0.96 else Vector3.FORWARD
	var rotation := Basis.looking_at(direction, up) * Basis.from_euler(Vector3(base.angles).limit_length(15.0) * (PI / 180.0))
	return original.interpolate_with(Transform3D(rotation, camera_eye), camera_weight)


func reaction_contacts() -> Array[Dictionary]:
	var active: Array[Dictionary] = []
	if not visible or not reaction_enabled.button_pressed:
		return active
	for runner in runners:
		if runner.tool_id < 0 or runner.contact_result.is_empty():
			continue
		var data: Dictionary = runner.custom_animation.contact
		var amount := smoothstep(0.70, 1.0, runner.blend) * intensity.value
		if amount > 0.0:
			active.append({"kind": data.kind, "side": data.side, "amount": amount,
				"time": maxf(0.0, runner.contact_elapsed - float(data.approach) / maxf(0.01, runner.motion_speed * float(data.speed))),
				"speed": absf(runner.drag_speed) if runner.mouse_control else runner.motion_speed * float(data.speed),
				"travel": runner.contact_result.get("travel", Vector3.ZERO),
				"amplitude": data.amplitude, "point": runner.contact_result.point,
				"style": runner.custom_animation.get("action", runner.custom_animation.name)})
	return active


func refresh_pairs() -> void:
	var previous: Variant = pair.get_selected_metadata()
	if not previous:
		previous = bindings.get_value("pair_actions", "start", "")
	pair.clear()
	pair.add_item("Per-hand actions")
	pair.set_item_metadata(0, "")
	for file in DirAccess.get_files_at(Preset.FOLDER):
		if not file.ends_with(".json"):
			continue
		var path := Preset.FOLDER.path_join(file)
		var data := Preset.read(path)
		if int(data.get("version", 0)) != 2:
			continue
		pair.add_item(data.name)
		pair.set_item_metadata(pair.item_count - 1, path)
		if path == previous:
			pair.select(pair.item_count - 1)


func _select_pair(index: int) -> void:
	if index > 0:
		mode.select(2)
		_mode_changed(2)


func _label(parent: Control, caption: String) -> void:
	var label := Label.new()
	label.text = caption
	parent.add_child(label)


func _button(parent: Control, caption: String, callback: Callable) -> Button:
	var button := Button.new()
	button.text = caption
	button.pressed.connect(callback)
	parent.add_child(button)
	return button
