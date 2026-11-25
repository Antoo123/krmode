extends SceneTree
const Edit := preload("res://character_edit.gd")
const Pose := preload("res://npc_pose.gd")
const CARDS := ["res://Content/Npc.kcs", "C:/KKK/Myproject/Build/KKS/Cards/Friendly-portable.png", "C:/KKK/Myproject/Build/KKS/Cards/KK-BR-Chan-portable.png"]
const HEIGHTS := [1.0, 0.89, 1.13]
const CASES := [
	["hands", "standing", false, "hand_l", "L"],
	["hands", "standing", false, "hand_r", "R"],
	["hands", "fours", false, "hand_l", "L"],
	["hands", "fours", false, "hand_r", "R"],
	["hands", "fours", true, "hand_l", "L"],
	["hands", "fours", true, "hand_r", "R"],
	["fours", "fours", true, "lap", "L"],
	["fours", "fours", true, "seat_l", "L"],
	["fours", "fours", true, "seat_r", "R"],
	["fours", "fours", true, "foot_l", "L"],
	["fours", "fours", true, "foot_r", "R"],
	["back", "lie_back", false, "lap", "L"],
	["back", "lie_back", false, "chest_l", "L"],
	["back", "lie_back", false, "chest_r", "R"],
	["side", "standing", false, "flank_l", "R"],
	["side", "standing", false, "flank_r", "L"],
	["side", "standing", true, "flank_l", "L"],
	["side", "standing", true, "flank_r", "R"],
	["seat", "standing", true, "seat_l", "L"],
	["seat", "standing", true, "seat_r", "R"],
	["regression", "standing", false, "crown", "R"],
	["regression", "standing", false, "chest_l", "R"],
	["regression", "standing", false, "lap", "R"],
	["regression", "standing", false, "chin", "L"],
	["regression", "standing", false, "cheek_l", "R"],
	["regression", "standing", false, "cheek_r", "L"],
	["regression", "standing", false, "hip_l", "R"],
	["regression", "standing", false, "hip_r", "L"],
	["pair", "lie_back", false, "chest_l", "R"],
]
var room: Node3D
var game: Node3D
var camera: Camera3D
var out: String
var data: FileAccess

func _initialize() -> void:
	run.call_deferred()

func ticks(count: int) -> void:
	for frame in range(count):
		await physics_frame

func joint(rig: Skeleton3D, name: String) -> Vector3:
	return rig.to_global(rig.get_bone_global_pose(rig.find_bone("cf_j_" + name)).origin)

func shot(id: String, point: Vector3, view: int, side: String) -> void:
	var front: Vector3 = (room.player.global_position - room.dancer_body.global_position).slide(Vector3.UP).normalized()
	var tangent := Vector3.UP.cross(front) * (1.0 if side == "R" else -1.0)
	var close := view == 2
	camera.fov = 41 if close else 50
	camera.global_position = point + front * (0.37 if close else 0.97) + tangent * [0.42, 0.94, 0.42, -0.88][view] + Vector3.UP * [0.82, 0.44, 0.31, 0.48][view]
	if close:
		var from_player := point.direction_to(room.player_model.global_position).slide(Vector3.UP).normalized()
		camera.global_position = point - from_player * 0.37 + tangent * 0.44 + Vector3.UP * 0.32
	camera.look_at(point)
	camera.force_update_transform()
	camera.make_current()
	var view_limbs = game.player_view
	var restore := {}
	if is_instance_valid(view_limbs.root):
		view_limbs.root.hide()
		for part: MeshInstance3D in view_limbs.original:
			restore[part] = part.visible
			part.visible = view_limbs.original[part]
	RenderingServer.force_draw(false)
	RenderingServer.force_draw(false)
	root.get_texture().get_image().save_jpg(out.path_join(id + ".jpg"), 0.90)
	for part: MeshInstance3D in restore:
		part.visible = restore[part]
	if is_instance_valid(view_limbs.root):
		view_limbs.root.show()
	room.camera.make_current()

func run() -> void:
	var args := OS.get_cmdline_user_args()
	RenderingServer.render_loop_enabled = "perf" in args
	out = args[0]
	DirAccess.make_dir_recursive_absolute(out)
	data = FileAccess.open(out.path_join("trace.jsonl"), FileAccess.WRITE)
	room = load("res://room.tscn").instantiate()
	root.add_child(room)
	camera = Camera3D.new()
	root.add_child(camera)
	await ticks(8)
	game = room.npc_gameplay
	var entry: Dictionary = game.entries[0]
	for card in range(3 if "all" in args else 1):
		for case: Array in CASES:
			var group: String = case[0]
			if "all-groups" not in args and group not in args:
				continue
			var posture: String = case[1]
			var rear: bool = case[2]
			var zone: String = case[3]
			var side: String = case[4]
			if "perf" in args and (rear or zone not in ["flank_l", "chest_l"]):
				continue
			var outfits := [true, false] if "both" in args and group != "hands" else [true]
			for dressed: bool in outfits:
				game.close_dialogue(true)
				for key in ["posture", "turn", "facing_locked", "conversation_ready", "was_turned"]:
					entry.erase(key)
				if not room.load_card(CARDS[card], true):
					push_error("Card " + CARDS[card])
					quit(2)
					return
				var actor: Node3D = room.dancer_model
				var rig: Skeleton3D = actor.get_node("Skeleton")
				var player: Skeleton3D = room.player_model.get_node("Skeleton")
				actor.scale.y = HEIGHTS[card]
				Edit.set_clothes(actor, true)
				if not dressed:
					for slot in ["Top", "Bra", "Bottom", "Underwear", "Tights", "Socks", "Shoes"]:
						Edit.set_clothes(actor, false, slot)
				room.dancer_body.position = Vector3(0, 0.05, -0.32)
				room.player.position = Vector3(0, 0.10, 0.84)
				room.player.velocity = Vector3.ZERO
				actor.rotation.y = PI
				await ticks(6)
				game.open_dialogue(entry)
				game.mode = 0
				entry.face_speaker = false
				await ticks(8)
				if posture != "standing":
					game.set_posture(entry, {"type": posture})
					await ticks(128)
				if rear:
					game.set_posture(entry, {"type": "turn"})
					await ticks(65)
				if posture == "lie_back" and zone == "lap":
					entry.posture.spread_target = 1.0
					await ticks(75)
				var target: Dictionary = game.contact.zone_anchor(rig, zone) if args.has("baseline") else game.contact.zone_anchor(rig, zone, posture)
				var prefix := "%d-%s-%s-%s-%s" % [card, posture, "rear" if rear else "front", zone, "clothes" if dressed else "skin"]
				var allowed: bool = game.contact.zone_allowed(entry, zone, 0)
				var visible := []
				var cursor: Vector2 = room.camera.unproject_position(target.point)
				for x in [-20, -10, 0, 10, 20]:
					for y in [-20, -10, 0, 10, 20]:
						var chosen: String = game.contact.pick(cursor + Vector2(x, y)).get("id", "")
						if chosen not in visible:
							visible.append(chosen)
				var began: bool = allowed and game.contact.begin(entry, {"id": zone, "anchor": target}, false, side, 0)
				data.store_line(JSON.stringify({"id":prefix,"allowed":allowed,"pick":visible,"began":began,"anchor":str(target.point),"normal":str(target.normal),"posture":entry.get("posture",{}).get("complete",true),"height":actor.scale.y}))
				data.flush()
				if not began:
					shot(prefix + "-0", target.point, 0, side)
					print(prefix, " unavailable")
					continue
				var approach_frames := ceili(float(game.contact.state.approach) * 60.0)
				if args.has("perf"):
					if zone == "chest_l":
						var button := InputEventMouseButton.new()
						button.position = Vector2(-200, -200)
						game.contact.add_second_hand("L", button)
					await ticks(approach_frames + 20)
					var frame_times: Array[float] = []
					var start := Time.get_ticks_usec()
					var clock := start
					for frame in range(180):
						game.contact.drag_goal = Vector2(sin(frame * 0.08), cos(frame * 0.06)) * 0.18
						await ticks(1)
						var now := Time.get_ticks_usec()
						frame_times.append((now - clock) / 1000.0)
						clock = now
					frame_times.sort()
					var fps := 180.0 * 1000000.0 / float(clock - start)
					data.store_line(JSON.stringify({"id":prefix,"hands":game.contact.state.hands.size(),"fps":fps,"median_ms":frame_times[89],"p95_ms":frame_times[170],"p99_ms":frame_times[177]}))
					data.flush()
					game.contact.end()
					continue
				var paired := group in ["regression", "pair"] and zone == "chest_l"
				for stage in range(8):
					if stage == 4:
						game.contact.drag_goal = Vector2(-0.20, 0.23)
						if paired:
							var button := InputEventMouseButton.new()
							button.position = Vector2(-200, -200)
							game.contact.add_second_hand("L", button)
					if stage == 5:
						game.contact.drag_goal = Vector2(0.22, -0.20)
						if paired:
							var both: Dictionary = game.contact.state.hands
							data.store_line(JSON.stringify({"id":prefix,"paired":both.size()==2, "depths":[both.get("L",{}).get("mesh_depth",-1),both.get("R",{}).get("mesh_depth",-1)]}))
							game.contact.release_hand("L")
					if stage == 6:
						if paired:
							data.store_line(JSON.stringify({"id":prefix,"right_held":game.contact.state.held and not game.contact.state.hands.R.has("released")}))
						game.contact.release()
					await ticks([8, 12, 18, maxi(31, approach_frames - 27), 36 if paired else 18, 17, 15, 28][stage])
					var state: Dictionary = game.contact.state
					var grab: Dictionary = state.get("hands", {}).get(side, {})
					var point: Vector3 = grab.get("last_point", target.point)
					var w := joint(player, "hand_" + side)
					var e := joint(player, "forearm01_" + side)
					var s := joint(player, "arm00_" + side)
					var m := joint(player, "middle01_" + side)
					var span := joint(player,"index01_"+side) - joint(player,"little01_"+side)
					var palm := (m-w).cross(span).normalized() * (1.0 if side == "L" else -1.0)
					var pad := player.to_global(Pose.contact_landmark(player, side, "palm"))
					data.store_line(JSON.stringify({"id":prefix,"stage":stage,"point":str(point),"wrist":str(w),"elbow":str(e),"shoulder":str(s),"palm":str(palm),"gap":pad.distance_to(point),"bend":rad_to_deg((w-e).angle_to(m-w)),"depth":grab.get("mesh_depth",-1),"clearance":grab.get("mesh_clearance",-1),"returned":state.is_empty(),"weight":state.get("weight",0.0),"player":str(room.player.global_position)}))
					if card == 0 or stage in [1, 3, 4, 6]:
						var focus := point.lerp(e, 0.43) if stage in [0, 1, 5, 7] else point.lerp(w, 0.20)
						shot(prefix + "-%d" % stage, focus, [0, 1, 2, 2, 3, 1, 0, 0][stage], side)
				if game.contact.begin(entry, {"id": zone, "anchor": target}, false, side, 0):
					await ticks(18)
					game.close_dialogue()
					await ticks(12)
					shot(prefix + "-cancel", target.point, 0, side)
					await ticks(26)
				data.store_line(JSON.stringify({"id":prefix,"cancel_returned":game.contact.state.is_empty()}))
				data.flush()
				print(prefix, " complete")
	quit()


