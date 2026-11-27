extends SceneTree

var failures := 0
var room: Node3D
var game: Node3D
var green: Node3D
var out: String

func _initialize() -> void:
	run.call_deferred()

func move_mouse(delta: Vector2) -> void:
	var event := InputEventMouseMotion.new()
	event.position = root.get_visible_rect().size * 0.5
	event.global_position = event.position
	event.relative = delta
	root.push_input(event)

func wait_frames(count: int) -> void:
	for i in count:
		await physics_frame
	await RenderingServer.frame_post_draw

func verify(ok: bool, label: String) -> void:
	if not ok:
		failures += 1
		printerr("FAIL ", label)

func capture(name: String) -> void:
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png(out.path_join(name + ".png"))

func run() -> void:
	out = OS.get_cmdline_user_args()[0]
	change_scene_to_file("res://room.tscn")
	await wait_frames(8)
	room = current_scene
	game = room.npc_gameplay
	green = game.green
	room.player.position = room.dancer_body.position + Vector3(0, 0.10, 1.08)
	await wait_frames(9)
	var event := InputEventKey.new()
	event.pressed = true
	event.keycode = KEY_E
	root.push_input(event)
	await wait_frames(15)
	if not green.active():
		printerr("FAIL automatic Green ", green.failure, " ", game.answer.text)
		quit(1)
		return
	verify(green.positions.item_count == 7 and room.animation_lab == null, "seven positions, no F7")
	for i in green.positions.item_count:
		var id: int = green.positions.get_item_id(i)
		green.select_position(id)
		await wait_frames(32)
		var fixed: Transform3D = room.camera.global_transform
		for n in 6:
			move_mouse(Vector2(90, -44))
			await physics_frame
		verify(fixed.origin.distance_to(room.camera.global_position) < 0.015 and fixed.basis.z.distance_to(room.camera.global_basis.z) < 0.015, "static camera position " + str(id))
		await capture("default-" + str(id))
	green.select_position(0)
	await wait_frames(30)
	var panel: Control = green.panel
	var left: Node3D = panel.runners[0]
	var right: Node3D = panel.runners[1]
	green.control.select(1)
	green.controlled_hand.select(0)
	green._update_control()
	var issue: String = panel.start(0, panel.preset_for("chin_lift", "L"))
	verify(issue.is_empty(), "chin start " + issue)
	verify(String(panel.start(1, panel.preset_for("touch_cheek", "R"))).is_empty(), "cheek start")
	await wait_frames(35)
	var initial: float = left.custom_time
	var head := 0.0
	for i in 55:
		move_mouse(Vector2(0, -10))
		await physics_frame
		head = maxf(head, Vector3(green.reaction.contact_mix.angles.get("cf_j_head", Vector3.ZERO)).length())
	var peak: float = left.custom_time
	verify(peak > initial + 0.35 and head > 1.0, "chin progress and lift")
	verify(left.contact_result.get("tips", []).size() == 2 and right.contact_result.get("tips", []).size() == 2, "two fingers")
	print("face contacts: chin measured=", left.contact_result.get("surface"), " cheek measured=", right.contact_result.get("surface"), " head degrees=", head,
		" cheek weight=", green.reaction.contact_mix.cheek_offsets)
	await capture("default-face-lift")
	for i in 38:
		move_mouse(Vector2(0, 11))
		await physics_frame
	verify(left.custom_time < peak - 0.35, "reverse")
	await wait_frames(30)
	var still: float = left.custom_time
	await wait_frames(20)
	verify(absf(left.custom_time - still) < 0.012, "stops with mouse")
	green.controlled_hand.select(1)
	green._update_control()
	verify(left.running and right.running, "switch controlling hand")
	panel.release(0)
	await wait_frames(28)
	verify(not left.running and right.running, "independent release")
	panel.release_all()
	await wait_frames(39)
	verify(green.reaction.contact_mix.cheek_offsets.get("L", 0.0) < 0.02, "cheek release")
	game.close_dialogue()
	var library := preload("res://card_library.gd")
	var cards := library.directory().get_base_dir()
	for file in ["Friendly-portable.png", "KK-BR-Chan-portable.png"]:
		verify(room.load_card(cards.path_join(file), true), "loaded card " + file)
		await wait_frames(8)
		game.open_dialogue(game.entries[0])
		for i in green.positions.item_count:
			var id: int = green.positions.get_item_id(i)
			green.select_position(id)
			await wait_frames(23)
			verify(green.state == "Idle" and green.failure.is_empty(), file + " position " + str(id))
			await capture(file.get_basename() + "-" + str(id))
		green.select_position(0)
		green.control.select(0)
		green._update_control()
		for action in ["chin_lift", "touch_cheek"]:
			verify(String(panel.start(1, panel.preset_for(action, "R"))).is_empty(), file + action)
			await wait_frames(106)
			print(file, " ", action, " measured=", right.contact_result.get("surface"), " tips=", right.contact_result.get("tips", []).size())
			await capture(file.get_basename()+"-"+action)
			panel.release_all()
			await wait_frames(26)
		game.close_dialogue()
	print("Green test failures: ", failures)
	quit(int(failures > 0))
