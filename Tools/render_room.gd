extends SceneTree

# Render a room GLB to a PNG for visual QA.
# Usage: godot --path .\KksPrototype --script .\Tools\render_room.gd -- <glb> <out.png>
# The script verifies runtime GLTFDocument loading AND captures a lit view.


func _initialize() -> void:
	render.call_deferred()


func render() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() < 2 or DisplayServer.get_name() == "headless":
		quit(1)
		return
	var path: String = args[0]
	var out: String = args[1]

	var gltf := GLTFDocument.new()
	var state := GLTFState.new()
	var err := gltf.append_from_file(path, state)
	if err != OK:
		print("GLTF append_from_file err: ", err)
		quit(1)
		return
	var scene: Node = gltf.generate_scene(state)
	if scene == null:
		print("generate_scene returned null")
		quit(1)
		return

	var studio := SubViewport.new()
	studio.own_world_3d = true
	studio.size = Vector2i(1280, 720)
	studio.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	studio.msaa_3d = Viewport.MSAA_2X
	root.add_child(studio)
	studio.add_child(scene)

	var world := WorldEnvironment.new()
	var environment := Environment.new()
	environment.background_mode = Environment.BG_COLOR
	environment.background_color = Color("#4b4f5a")
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.ambient_light_color = Color("#e1e5ef")
	environment.ambient_light_energy = 0.53
	world.environment = environment
	studio.add_child(world)

	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-46, -24, 0)
	sun.light_color = Color("#fff7ee")
	sun.light_energy = 0.38
	sun.light_specular = 0.1
	sun.shadow_enabled = true
	studio.add_child(sun)

	var key := DirectionalLight3D.new()
	key.rotation_degrees = Vector3(-24, 159, 0)
	key.light_energy = 0.6
	key.light_specular = 0.0
	studio.add_child(key)

	var bounds := _world_bounds(scene)
	var center: Vector3 = bounds[0] + bounds[1] * 0.5
	var extent: float = maxf(bounds[1].length(), 1.0) * 0.5 + 1.0
	var camera := Camera3D.new()
	camera.fov = 55.0
	var pitch := 0.45
	camera.position = center + Vector3(-extent * 0.9, extent * 0.65 + center.y, extent * 1.1)
	studio.add_child(camera)
	camera.look_at(center, Vector3.UP)
	camera.make_current()

	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	var img := studio.get_texture().get_image()
	if img.save_png(out) != OK:
		print("save_png failed")
		quit(1)
		return
	print("saved ", out)
	quit(0)


func _world_bounds(node: Node) -> Array:
	_minp = Vector3.INF
	_maxp = -Vector3.INF
	_found = false
	_walk(node, Transform3D.IDENTITY)
	if not _found:
		return [Vector3.ZERO, Vector3(1, 1, 1)]
	return [_minp, _maxp - _minp]


var _minp := Vector3.INF
var _maxp := -Vector3.INF
var _found := false


func _walk(node: Node, parent_xf: Transform3D) -> void:
	var xf := parent_xf
	if node is Node3D:
		xf = parent_xf * (node as Node3D).transform
	if node is MeshInstance3D and node.mesh != null:
		var mn := String(node.name).to_lower()
		var skip := "sky" in mn or "kumo" in mn or "cloud" in mn or "shadow" in mn or "balck" in mn or "sea" in mn or "umi" in mn
		if not skip:
			var la: AABB = (node as MeshInstance3D).get_aabb()
			if la.size != Vector3.ZERO:
				for i in 8:
					var c := la.position + Vector3(
						(i & 1) * la.size.x,
						((i >> 1) & 1) * la.size.y,
						((i >> 2) & 1) * la.size.z)
					var w := xf * c
					_minp = _minp.min(w)
					_maxp = _maxp.max(w)
					_found = true
	for child in node.get_children():
		_walk(child, xf)