extends SceneTree

const CardModel := preload("res://card_model.gd")
const Edit := preload("res://character_edit.gd")


func _initialize() -> void:
	capture.call_deferred()


func capture() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() != 2 or DisplayServer.get_name() == "headless":
		quit(1)
		return
	var actor := CardModel.load_actor(args[0])
	if not actor:
		quit(1)
		return
	var studio := SubViewport.new()
	studio.own_world_3d = true
	studio.size = Vector2i(640, 720)
	studio.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	studio.msaa_3d = Viewport.MSAA_2X
	root.add_child(studio)
	studio.add_child(actor)
	var world := WorldEnvironment.new()
	var environment := Environment.new()
	environment.background_mode = Environment.BG_COLOR
	environment.background_color = Color("#444954")
	world.environment = environment
	studio.add_child(world)
	var key := DirectionalLight3D.new()
	key.rotation_degrees = Vector3(-24, 159, 0)
	key.light_energy = 0.93
	studio.add_child(key)
	var camera := Camera3D.new()
	camera.fov = 33
	studio.add_child(camera)
	camera.make_current()
	for shot in [["body", 0.95, 3.3], ["face", 1.37, 1.0], ["legs", 0.34, 1.25], ["rear", 0.94, -1.55]]:
		var height: float = shot[1]
		if shot[0] == "rear":
			Edit.set_clothes(actor, false)
		camera.position = Vector3(0, height, -shot[2])
		camera.look_at(Vector3(0, height, 0))
		await RenderingServer.frame_post_draw
		await RenderingServer.frame_post_draw
		var file := args[1] + "-" + String(shot[0]) + ".png"
		if studio.get_texture().get_image().save_png(file) != OK:
			quit(1)
			return
	quit(0)
