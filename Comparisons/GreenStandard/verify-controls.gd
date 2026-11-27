extends SceneTree

func _initialize() -> void:
	run.call_deferred()

func wait_ticks(count: int) -> void:
	for i in count:
		await physics_frame

func mouse(delta: Vector2) -> void:
	var event := InputEventMouseMotion.new()
	event.position = root.get_visible_rect().size * 0.5
	event.relative = delta
	root.push_input(event)

func run() -> void:
	change_scene_to_file("res://room.tscn")
	await wait_ticks(12)
	var room: Node3D = current_scene
	var game: Node3D = room.npc_gameplay
	game.open_dialogue(game.entries[0])
	var green: Node3D = game.green
	var panel: Control = green.panel
	var hand: Node3D = panel.runners[0]
	green.control.select(1)
	green.controlled_hand.select(0)
	green._update_control()
	if not String(panel.start(0, panel.preset_for("touch_cheek", "L"))).is_empty():
		quit(1)
		return
	await wait_ticks(46)
	var baseline: float = hand.custom_time
	var part: String = hand.custom_animation.contact.side
	var direction: float = 1.0 if part == "L" else -1.0
	var signed := Vector2(direction * 11.0, 0)
	for i in 42:
		var anchor: Transform3D = hand.contact_result.get("anchor", Transform3D.IDENTITY)
		var camera: Camera3D = room.camera
		var p0 := camera.unproject_position(anchor.origin)
		var p1 := camera.unproject_position(anchor.origin + anchor.basis.x * direction * 0.08)
		signed = (p1 - p0).normalized() * 11.0
		mouse(signed)
		await physics_frame
	var peak: float = hand.custom_time
	var tension: float = green.reaction.contact_mix.cheek_offsets.get(part, 0.0)
	for i in 44:
		mouse(-signed)
		await physics_frame
	var reverse: float = hand.custom_time
	var relaxed: float = green.reaction.contact_mix.cheek_offsets.get(part, 0.0)
	panel.release_all()
	await wait_ticks(39)
	var stopped: bool = not hand.running and green.state == "Idle"
	green.restart()
	await wait_ticks(20)
	var restarted: bool = green.active() and green.state == "Idle" and green.position_id == 0
	print("Cheek viewport input: time %.3f -> %.3f -> %.3f, stretch %.3f -> %.3f, Stop=%s Restart=%s" % [baseline, peak, reverse, tension, relaxed, stopped, restarted])
	quit(int(peak <= baseline + 0.18 or reverse >= peak - 0.18 or tension <= relaxed + 0.07 or not stopped or not restarted))
