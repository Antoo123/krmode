extends SceneTree

const Actions := preload("res://pov_hand_actions.gd")
const Preset := preload("res://hand_animation_preset.gd")
const Contact := preload("res://hand_contact_motion.gd")
const Wardrobe := preload("res://character_edit.gd")

var lab: CanvasLayer
var room: Node3D
var dual: Control
var output: String
var failed := 0
var rows := PackedStringArray(["pose,action,hand,measured,samples,approach_clearance,step_m"])
var missing := 0


func _initialize() -> void:
	run.call_deferred()


func check(condition: bool, label: String) -> bool:
	if not condition:
		failed += 1
		printerr("FAIL ", label)
	return condition


func press(code: Key) -> void:
	var event := InputEventKey.new()
	event.keycode = code
	event.pressed = true
	root.push_input(event)


func frames(count: int) -> void:
	for i in count:
		await RenderingServer.frame_post_draw


func save_frame(name: String) -> void:
	await frames(2)
	lab.stage.get_viewport().get_texture().get_image().save_png(output.path_join(name + ".png"))


func select_position(position: int) -> void:
	var index: int = lab.caress_positions.get_item_index(position)
	lab._choose_caress_position(index)
	lab.pause()
	lab.stage.green_hands.offset = Vector3.ZERO
	lab.stage.green_hands.angles = Vector3.ZERO
	lab._seek(0.30)


func advance(steps: int) -> void:
	for i in steps:
		lab._process(1.0 / 30.0)


func run() -> void:
	output = OS.get_cmdline_user_args()[0]
	change_scene_to_file("res://room.tscn")
	await frames(3)
	room = current_scene
	press(KEY_F7)
	lab = room.animation_lab
	if not check(lab != null and lab.is_open(), "open F7"):
		quit(1)
		return
	lab.set_process(false)
	var total := 0
	var playable := 0
	var paired := 0
	var triples := 0
	for entry: Dictionary in lab.data.rows:
		if int(entry.group) != 0:
			paired += int(lab._required(entry).count(true) == 2)
			triples += int(lab._required(entry).count(true) == 3)
	for position in 11:
		select_position(position)
		total += lab.states.item_count
		for state_index in lab.states.item_count:
			lab._select_state(state_index)
			if lab.stage.duration > 0.0 and lab.stage.base_animations[1]:
				lab._seek(0.37)
				playable += 1
	check(total == 154 and playable == 154, "154 original states sampled at phase 0.37")
	print("Original states: ", playable, "/", total, "; paired rows in F7: ", paired, "; triple roles: ", triples)
	select_position(0)
	lab.pov_hands.button_pressed = true
	lab.independent_switch.button_pressed = true
	dual = lab.independent_hands
	if not check(dual.visible and dual.runners.size() == 2, "independent hands activated"):
		quit(1)
		return
	for position in 11:
		select_position(position)
		await frames(3)
		for action: String in Actions.ACTIONS:
			if Actions.ACTIONS[action][1] not in ["side", "foot", "ankle", "crown"]:
				continue
			var i := int(Actions.ACTIONS[action][2] == "R")
			var side := "R" if i else "L"
			var runner: Node3D = dual.runners[i]
			var preset := Actions.make(action, side)
			dual.cancel()
			lab._seek(0.30)
			var issue: String = dual.start(i, preset)
			if not check(issue.is_empty(), "%s/%s %s" % [position, action, issue]):
				continue
			var samples := 0
			var measured := 0
			var largest := 0.0
			var last := Vector3.ZERO
			var maximum_gap := 0.0
			for tick in 22:
				lab._process(1.0 / 30.0)
				if tick in [5, 10, 16]:
					await frames(1)
				var result: Dictionary = runner.contact_result
				if result.is_empty() or runner.blend < 0.82:
					continue
				check(result.world.is_finite() and result.normal.is_normalized(), "%s/%s transform" % [position, action])
				measured += int(result.surface)
				var point: Vector3 = result.world.origin
				if samples > 0:
					largest = maxf(largest, point.distance_to(last))
				last = point
				maximum_gap = maxf(maximum_gap, Vector3(result.goal.origin).distance_to(result.point))
				samples += 1
			check(samples >= 4, "%s/%s contact reached" % [position, action])
			missing += int(measured == 0)
			rows.append("%d,%s,%s,%d,%d,%.4f,%.4f" % [position, action, side, measured, samples, maximum_gap, largest])
			dual.release(i)
			advance(14)
			check(runner.tool_id < 0, "%s/%s released" % [position, action])
		print("Position ", position, " done")
		await frames(1)
	var matrix := FileAccess.open(output.path_join("matrix.csv"), FileAccess.WRITE)
	matrix.store_string("\n".join(rows) + "\n")
	matrix.close()

	select_position(0)
	var left := Actions.make("stroke_hair", "L")
	var right := Actions.make("take_hand", "R")
	dual.controls[0].speed.value = 0.65
	dual.controls[1].speed.value = 1.45
	check(String(dual.start(0, left)).is_empty() and String(dual.start(1, right)).is_empty(), "different contacts")
	advance(30)
	check(dual.runners[0].running and dual.runners[1].running, "both running")
	check(dual.runners[0].custom_time < dual.runners[1].custom_time, "independent rates")
	check(not lab.stage.green_reaction.contact_mix.angles.is_empty(), "blended reaction")
	await save_frame("standing-crown-and-hand")
	dual.release(0)
	advance(18)
	check(dual.runners[0].tool_id < 0 and dual.runners[1].running, "only left released")
	check(not lab.stage.green_reaction.contact_mix.angles.is_empty(), "second reaction remains")
	dual.release_all()
	advance(45)
	check(dual.runners[1].tool_id < 0 and lab.stage.green_reaction.contact_mix.angles.is_empty(), "both and reactions returned")

	select_position(7)
	dual.controls[0].speed.value = 1.0
	dual.controls[1].speed.value = 1.0
	check(String(dual.start(0, Actions.make("stroke_left_foot", "L"))).is_empty(), "left foot sitting")
	check(String(dual.start(1, Actions.make("hold_right_foot", "R"))).is_empty(), "right foot sitting")
	advance(25)
	await save_frame("sitting-both-feet")
	dual.mode.select(0)
	dual._mode_changed(0)
	advance(20)
	check(dual.runners[0].running and dual.runners[1].tool_id < 0, "Left mode releases only right")
	dual.mode.select(2)
	dual._mode_changed(2)
	var before: float = lab.phase
	lab.restart()
	check(dual.runners[0].tool_id < 0 and lab.phase <= before, "restart cancels both")
	lab.pause()

	select_position(0)
	check(String(dual.start(0, Actions.make("hold_left_side", "L"))).is_empty(), "left side")
	check(String(dual.start(1, Actions.make("hold_right_side", "R"))).is_empty(), "right side")
	advance(22)
	await save_frame("standing-both-sides")
	select_position(2)
	dual.cancel()
	check(String(dual.start(0, Actions.make("stroke_left_foot", "L"))).is_empty(), "lying/bent foot route")
	advance(20)
	await save_frame("pose-02-foot")
	dual.cancel()
	check(String(dual.start(0, Actions.make("hold_head", "L"))).is_empty(), "same target left")
	check(String(dual.start(1, Actions.make("hold_head", "R"))).is_empty(), "same target right")
	advance(24)
	var left_point := Vector3(dual.runners[0].contact_result.get("point", Vector3.ZERO))
	var right_point := Vector3(dual.runners[1].contact_result.get("point", Vector3.ZERO))
	check(dual.runners[0].contact_lane < -0.03 and dual.runners[1].contact_lane > 0.03
		and left_point.distance_to(right_point) > 0.045, "shared target separation")
	await save_frame("same-crown-02")

	select_position(0)
	for footwear in ["shoes", "socks", "bare"]:
		var actor: Node3D = lab.stage.actors[1]
		Wardrobe.set_clothes(actor, footwear == "shoes", "Shoes")
		Wardrobe.set_clothes(actor, footwear != "bare", "Socks")
		Wardrobe.set_clothes(actor, footwear != "bare", "Tights")
		check(String(dual.start(0, Actions.make("hold_left_foot", "L"))).is_empty(), footwear)
		await frames(3)
		advance(19)
		check(bool(dual.runners[0].contact_result.get("surface", false)), "surface with " + footwear)
		await save_frame("foot-" + footwear)
		dual.cancel()
	var posed: Node3D = lab.stage.actors[1]
	posed.rotation.x += PI / 2.0
	lab._seek(0.30)
	await frames(3)
	dual.start(0, Actions.make("hold_left_foot", "L"))
	advance(19)
	check(bool(dual.runners[0].contact_result.get("surface", false)), "supine foot")
	await save_frame("supine-foot")
	posed.rotation.x -= PI / 2.0
	dual.cancel()

	select_position(0)
	dual.start(0, Actions.make("hold_head", "L"))
	dual.start(1, Actions.make("hold_right_side", "R"))
	advance(16)
	var old_actor: Node3D = lab.stage.actors[1]
	var phase_before: float = lab.phase
	var cards: OptionButton = lab.card_options[1]
	for index in cards.item_count:
		if cards.get_item_text(index) == "Skye":
			cards.select(index)
			lab._change_card(index, 1)
			break
	check(old_actor != lab.stage.actors[1] and is_equal_approx(lab.phase, phase_before), "card switch retained base phase")
	check(dual.runners[0].tool_id < 0 and dual.runners[1].tool_id < 0, "card switch cleared both attachments")
	lab._select_state(1)
	check(lab.stage.duration > 0.0, "changed green state")
	lab.pause()

	select_position(0)
	var editor: VBoxContainer = lab.hand_editor
	editor.open_editor()
	check(editor.visible, "editor opened")
	editor._load(left, "")
	editor.edit_scope.select(2)
	editor._edit_scope_changed(2)
	editor._switch_track(1)
	editor._choose_surface_action(3)
	editor.scrub(0.7)
	editor.add_key()
	editor._switch_track(0)
	editor.scrub(0.8)
	check(not editor.pair_tracks.is_empty() and not lab.stage.green_hands.second_editor_preview.is_empty(), "two-hand preview")
	var saved: Dictionary = editor._serialized("POV independent smoke")
	var path := output.path_join("pair-test.json")
	check(Preset.store(path, saved) == OK, "save pair JSON")
	var reloaded := Preset.read(path)
	check(int(reloaded.get("version", 0)) == 2 and reloaded.tracks.L.asset.ends_with("L") and reloaded.tracks.R.asset.ends_with("R"), "load separate tracks")
	if not reloaded.is_empty():
		editor._load(reloaded, path)
		editor.scrub(0.82)
		await save_frame("editor-two-tracks")
	editor.close_editor()
	lab.stop()
	check(dual.runners[0].tool_id < 0 and dual.runners[1].tool_id < 0, "stop")
	press(KEY_F5)
	check(room.pair_preview.is_open(), "F5 opens")
	for index in room.pair_preview.list.item_count:
		room.pair_preview.play_row(index)
		if room.pair_preview.tracks.size() == 2:
			break
	check(room.pair_preview.tracks.size() == 2, "F5 paired tracks")
	press(KEY_F6)
	check(room.studio_preview.is_open() and room.studio_preview.motions.size() > 0, "F6 saved scene actors")
	print("New action matrix ", rows.size() - 1, "; without a mesh hit ", missing, "; failed ", failed)
	quit(int(failed > 0))
