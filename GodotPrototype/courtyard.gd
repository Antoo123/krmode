extends Node3D

const WALK_SPEED := 3.8
const MOUSE_SPEED := 0.003

var player := CharacterBody3D.new()
var dancer_body: StaticBody3D
var player_model: Node3D
var player_anim: AnimationPlayer
var dancer_anim: AnimationPlayer
var camera := Camera3D.new()
var sky_yaw := 0.0
var pitch := 0.28
var smoke_tick := -1
var smoke_start: Vector3
var smoke_dance: Vector3
var smoke_walked := false
var smoke_walk_clip := false
var npc_model: Node3D
var npc_anim: AnimationPlayer
var slap_mark: MeshInstance3D
var slap_ready := true


func _ready() -> void:
	build_courtyard()
	add_child(player)
	player.collision_layer = 2
	player.collision_mask = 1
	player.position = Vector3(0, 0.06, 5.5)
	player.floor_snap_length = 0.25
	var capsule := CapsuleShape3D.new()
	capsule.radius = 0.30
	capsule.height = 1.72
	add_collision(player, capsule, Vector3.UP * 0.86)
	player_model = make_character(player, false)
	player_anim = player_model.get_node("AnimationPlayer")
	player_anim.play("Idle")

	dancer_body = StaticBody3D.new()
	add_child(dancer_body)
	dancer_body.position = Vector3(0, 0.03, -0.95)
	add_collision(dancer_body, capsule, Vector3.UP * 0.86)
	var dancer := make_character(dancer_body, true)
	dancer.rotation.y = PI
	dancer_anim = dancer.get_node("AnimationPlayer")
	dancer_anim.play("Dance")
	npc_model = dancer
	npc_anim = dancer_anim
	slap_mark = make_slap_mark(dancer)

	add_child(camera)
	camera.current = true
	camera.fov = 61.0
	camera.near = 0.06
	update_camera(1.0)
	build_hud()
	if "--smoke-test" in OS.get_cmdline_user_args():
		smoke_tick = 0
		smoke_start = player.position
		smoke_dance = dancer.get_node("Torso/ArmL").rotation
	else:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		sky_yaw -= event.relative.x * MOUSE_SPEED
		pitch = clampf(pitch - event.relative.y * MOUSE_SPEED, -0.12, 1.03)
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_ESCAPE:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_F:
		do_slap()
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func do_slap() -> void:
	if not slap_ready:
		return
	slap_ready = false
	player_anim.play("Slap")
	get_tree().create_timer(0.4).timeout.connect(func() -> void:
		if is_instance_valid(slap_mark):
			slap_mark.visible = true
			npc_anim.play("Slapped", 0.1))
	get_tree().create_timer(2.0).timeout.connect(func() -> void: slap_ready = true)


func make_slap_clip() -> Animation:
	var animation := Animation.new()
	animation.length = 1.0
	var paths := ["Torso:rotation", "Torso/Head:rotation", "Torso/ArmR:rotation",
		"Torso/ArmL:rotation", "Torso/ArmR/Elbow:rotation", "Torso/ArmL/Elbow:rotation"]
	for path in paths:
		animation.track_set_path(animation.add_track(Animation.TYPE_VALUE), NodePath(path))
	var keys := [
		[0.0, [Vector3(0, 0, 0), Vector3.ZERO, Vector3(0, 0, 0.1), Vector3(0, 0, 0.1), Vector3.ZERO, Vector3.ZERO]],
		[0.3, [Vector3(0, 0.5, 0), Vector3(0, 0.4, 0), Vector3(0, 0, 1.15), Vector3(0, 0, 0.35), Vector3(0, 0, 0), Vector3.ZERO]],
		[0.42, [Vector3(0, -0.6, 0), Vector3(0, -0.5, 0), Vector3(0, 0, -0.45), Vector3(0, 0, 0.2), Vector3(0, 0, 0), Vector3.ZERO]],
		[0.7, [Vector3(0, -0.25, 0), Vector3(0, -0.2, 0), Vector3(0, 0, -0.1), Vector3(0, 0, 0.15), Vector3(0, 0, 0), Vector3.ZERO]],
		[1.0, [Vector3.ZERO, Vector3.ZERO, Vector3(0, 0, 0.1), Vector3(0, 0, 0.1), Vector3.ZERO, Vector3.ZERO]],
	]
	for key in keys:
		var time: float = key[0]
		for track in range(key[1].size()):
			animation.track_insert_key(track, time, key[1][track])
	return animation


func make_slapped_clip() -> Animation:
	var animation := Animation.new()
	animation.length = 1.6
	var paths := ["Torso/Head:rotation", "Torso:rotation", "Torso/ArmL:rotation", "Torso/ArmR:rotation"]
	for path in paths:
		animation.track_set_path(animation.add_track(Animation.TYPE_VALUE), NodePath(path))
	var keys := [
		[0.0, [Vector3.ZERO, Vector3.ZERO, Vector3(0, 0, 0.1), Vector3(0, 0, 0.1)]],
		[0.12, [Vector3(0.2, 0.0, 0.75), Vector3(0, 0.0, 0.0), Vector3(0, 0, 0.1), Vector3(0, 0, 0.1)]],
		[0.3, [Vector3(0.15, 0.0, 0.5), Vector3(0, 0.0, 0.0), Vector3(0, 0, 0.1), Vector3(0, 0, 0.1)]],
		[0.8, [Vector3(0.05, 0.0, 0.15), Vector3(0, 0.0, 0.0), Vector3(0, 0, 0.1), Vector3(0, 0, 0.1)]],
		[1.6, [Vector3.ZERO, Vector3.ZERO, Vector3(0, 0, 0.1), Vector3(0, 0, 0.1)]],
	]
	for key in keys:
		var time: float = key[0]
		for track in range(key[1].size()):
			animation.track_insert_key(track, time, key[1][track])
	return animation


func make_slap_mark(model: Node3D) -> MeshInstance3D:
	var head: Node3D = model.get_node("Torso/Head")
	var mesh := SphereMesh.new()
	mesh.radial_segments = 10
	mesh.rings = 5
	var mark := MeshInstance3D.new()
	mark.name = "SlapMark"
	mark.mesh = mesh
	mark.position = Vector3(0.1, -0.03, 0.17)
	mark.scale = Vector3(0.012, 0.07, 0.09)
	var material := StandardMaterial3D.new()
	material.albedo_color = Color(0.86, 0.12, 0.14)
	material.roughness = 0.6
	mark.material_override = material
	mark.visible = false
	head.add_child(mark)
	return mark


func _physics_process(delta: float) -> void:
	var direction := Vector2.ZERO
	if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		direction.x = float(Input.is_physical_key_pressed(KEY_D)) - float(Input.is_physical_key_pressed(KEY_A))
		direction.y = float(Input.is_physical_key_pressed(KEY_S)) - float(Input.is_physical_key_pressed(KEY_W))
	if smoke_tick >= 0:
		direction = Vector2.UP if smoke_tick < 150 else Vector2.ZERO
	step_player(direction, delta)
	update_camera(1.0 - exp(-16.0 * delta))
	if smoke_tick >= 0:
		check_smoke()


func step_player(direction: Vector2, delta: float) -> void:
	var motion := Vector3(direction.x, 0, direction.y).limit_length().rotated(Vector3.UP, sky_yaw)
	player.velocity.x = motion.x * WALK_SPEED
	player.velocity.z = motion.z * WALK_SPEED
	if player.is_on_floor():
		player.velocity.y = -0.2
	else:
		player.velocity.y -= 16.0 * delta
	player.move_and_slide()
	if player_anim.current_animation == "Slap":
		return
	var clip := "Idle"
	if motion.length_squared() > 0.001:
		player_model.rotation.y = lerp_angle(player_model.rotation.y, atan2(-motion.x, -motion.z), minf(1, delta * 15))
		var velocity := player.get_real_velocity()
		if Vector2(velocity.x, velocity.z).length() > 0.1:
			clip = "Walk"
	if player_anim.current_animation != clip:
		player_anim.play(clip, 0.16)


func update_camera(weight: float) -> void:
	var focus := player.position + Vector3.UP * 1.36
	var offset := Vector3(0.57, sin(pitch) * 4.1, cos(pitch) * 4.1).rotated(Vector3.UP, sky_yaw)
	var goal := focus + offset
	var ray := PhysicsRayQueryParameters3D.create(focus, goal, 1)
	var hit := get_world_3d().direct_space_state.intersect_ray(ray)
	if not hit.is_empty():
		goal = hit.position - offset.normalized() * 0.18
	camera.position = camera.position.lerp(goal, weight)
	# Clamp the interpolated position too when turning near a wall.
	ray.to = camera.position
	var swept := get_world_3d().direct_space_state.intersect_ray(ray)
	if not swept.is_empty():
		camera.position = swept.position.move_toward(focus, 0.18)
	camera.look_at(focus + Vector3.UP * 0.08)


func check_smoke() -> void:
	smoke_tick += 1
	smoke_walked = smoke_walked or (smoke_start.z - player.position.z > 2.0)
	smoke_walk_clip = smoke_walk_clip or player_anim.current_animation == "Walk"
	if smoke_tick == 100:
		do_slap()
	if smoke_tick != 200:
		return
	var arm: Node3D = null
	var dancing := npc_anim.current_animation == "Slapped"
	var clipped := true
	var grounded := true
	var idle := true
	var dance := true
	var smoke_slap := slap_mark.visible and dancing
	var passed := smoke_walked and smoke_walk_clip and smoke_slap
	var report := "Smoke: movement=%s walk=%s slap=%s" % [
		smoke_walked, smoke_walk_clip, smoke_slap]
	print(report)
	get_tree().quit(0 if passed else 1)


func build_courtyard() -> void:
	var world := WorldEnvironment.new()
	var weather := Environment.new()
	weather.background_mode = Environment.BG_SKY
	var sky := Sky.new()
	var sky_mat := ProceduralSkyMaterial.new()
	sky_mat.sky_top_color = Color("#344466")
	sky_mat.sky_horizon_color = Color("#f1b88d")
	sky_mat.ground_horizon_color = Color("#f1b88d")
	sky_mat.ground_bottom_color = Color("#493a4c")
	sky.sky_material = sky_mat
	weather.sky = sky
	weather.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	weather.ambient_light_color = Color("#ffe1c9")
	weather.ambient_light_energy = 0.69
	world.environment = weather
	add_child(world)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-46, -34, 0)
	sun.light_color = Color("#fff0d8")
	sun.light_energy = 1.15
	sun.shadow_enabled = true
	sun.directional_shadow_max_distance = 29.0
	add_child(sun)

	solid_box(Vector3(0, -0.26, 0), Vector3(17, 0.5, 17), Color("#a18c7b"))
	for x in range(-4, 5):
		for z in range(-4, 5):
			var tile_color := Color("#beab97") if (x + z) % 2 == 0 else Color("#cab7a4")
			box(self, Vector3(x * 1.78, -0.016, z * 1.78), Vector3(1.76, 0.03, 1.76), tile_color)
	solid_box(Vector3(0, 1.1, -8.25), Vector3(17, 2.2, 0.5), Color("#deaa88"))
	solid_box(Vector3(0, 0.45, 8.25), Vector3(17, 0.9, 0.5), Color("#d7a280"))
	for side in [-1, 1]:
		solid_box(Vector3(side * 8.25, 0.6, 0), Vector3(0.5, 1.2, 17), Color("#d7a280"))
		for z in [-5.9, 0.0, 5.9]:
			planter(Vector3(side * 6.4, 0, z))
		solid_box(Vector3(side * 4.0, 0.22, 2.55), Vector3(2.5, 0.44, 0.62), Color("#6c5351"))
		box(self, Vector3(side * 4.0, 0.47, 2.55), Vector3(2.62, 0.14, 0.72), Color("#9d6045"))

	for x in [-6.7, -4.0, -1.35, 1.35, 4.0, 6.7]:
		box(self, Vector3(x, 1.52, -7.8), Vector3(0.28, 3.04, 0.34), Color("#f2ccaa"))
	box(self, Vector3(0, 3.06, -7.81), Vector3(14.3, 0.23, 0.44), Color("#f2ccaa"))
	cylinder(self, Vector3(0, 0.012, -0.95), 2.45, 0.026, Color("#8c5157"))
	cylinder(self, Vector3(0, 0.023, -0.95), 2.24, 0.012, Color("#bd7277"))
	for i in range(28):
		var angle := i * TAU / 28
		var marker := box(self, Vector3(cos(angle) * 2.12, 0.032, -0.95 + sin(angle) * 2.12),
			Vector3(0.18, 0.006, 0.036), Color("#f4c9a1"))
		marker.rotation.y = -angle


func planter(at: Vector3) -> void:
	solid_box(at + Vector3.UP * 0.31, Vector3(1.5, 0.62, 1.45), Color("#ad6955"))
	box(self, at + Vector3.UP * 0.64, Vector3(1.59, 0.12, 1.54), Color("#f0bc91"))
	cylinder(self, at + Vector3.UP * 1.07, 0.13, 1.0, Color("#78534b"))
	sphere(self, at + Vector3(-0.3, 1.79, 0), Vector3(1.35, 1.19, 1.32), Color("#648b6a"))
	sphere(self, at + Vector3(0.35, 1.81, 0.15), Vector3(1.26, 1.15, 1.2), Color("#7c9c6e"))
	sphere(self, at + Vector3(-0.01, 2.29, -0.2), Vector3(1.4, 1.36, 1.35), Color("#94ab74"))


func make_character(parent: Node3D, dancer: bool) -> Node3D:
	var model := Node3D.new()
	model.name = "Character"
	parent.add_child(model)
	var skin := Color("#d99972") if dancer else Color("#ba805d")
	var shirt := Color("#f38b87") if dancer else Color("#276b73")
	var pants := Color("#513955") if dancer else Color("#323c50")
	var hair := Color("#4c2c39") if dancer else Color("#34303b")
	var shoes := Color("#fff4dd")
	var torso := joint(model, "Torso", Vector3(0, 0.79, 0))
	sphere(torso, Vector3(0, 0.24, 0), Vector3(0.59, 0.63, 0.32), shirt)
	sphere(torso, Vector3(0, 0.04, 0), Vector3(0.48, 0.24, 0.29), pants)
	sphere(torso, Vector3(0, 0.56, 0), Vector3(0.19, 0.23, 0.19), skin)
	var head := joint(torso, "Head", Vector3(0, 0.73, 0))
	sphere(head, Vector3.ZERO, Vector3(0.42, 0.45, 0.39), skin)
	sphere(head, Vector3(0, 0.107, 0.034), Vector3(0.44, 0.31, 0.39), hair)
	if dancer:
		sphere(head, Vector3(0.045, -0.045, 0.14), Vector3(0.41, 0.49, 0.24), hair)
		sphere(head, Vector3(0.155, 0.22, 0.085), Vector3(0.24, 0.25, 0.27), hair)
	for side in [-1, 1]:
		sphere(head, Vector3(side * 0.077, -0.012, -0.181), Vector3(0.033, 0.041, 0.025), Color("#352a31"))
		var suffix := "L" if side < 0 else "R"
		var arm := joint(torso, "Arm" + suffix, Vector3(side * 0.28, 0.40, 0))
		sphere(arm, Vector3(0, -0.123, 0), Vector3(0.17, 0.34, 0.18), shirt)
		var elbow := joint(arm, "Elbow", Vector3(0, -0.255, 0))
		sphere(elbow, Vector3(0, -0.118, 0), Vector3(0.13, 0.29, 0.14), skin)
		var leg := joint(torso, "Leg" + suffix, Vector3(side * 0.14, 0, 0))
		sphere(leg, Vector3(0, -0.17, 0), Vector3(0.25, 0.42, 0.25), pants)
		var knee := joint(leg, "Knee", Vector3(0, -0.34, 0))
		sphere(knee, Vector3(0, -0.165, 0), Vector3(0.20, 0.39, 0.20), pants)
		sphere(knee, Vector3(0, -0.37, -0.065), Vector3(0.22, 0.17, 0.35), shoes)

	var animator := AnimationPlayer.new()
	animator.name = "AnimationPlayer"
	model.add_child(animator)
	var clips := AnimationLibrary.new()
	clips.add_animation("Idle", make_clip("Idle", 2.4))
	clips.add_animation("Walk", make_clip("Walk", 0.64))
	if not dancer:
		clips.add_animation("Slap", make_slap_clip())
	if dancer:
		clips.add_animation("Slapped", make_slapped_clip())
	if dancer:
		clips.add_animation("Dance", load_dance())
	animator.add_animation_library("", clips)
	return model


func make_clip(clip: String, length: float) -> Animation:
	var animation := Animation.new()
	animation.length = length
	animation.loop_mode = Animation.LOOP_LINEAR
	var paths := ["Torso:position", "Torso:rotation", "Torso/Head:rotation", "Torso/ArmL:rotation",
		"Torso/ArmR:rotation", "Torso/ArmL/Elbow:rotation", "Torso/ArmR/Elbow:rotation",
		"Torso/LegL:rotation", "Torso/LegR:rotation", "Torso/LegL/Knee:rotation", "Torso/LegR/Knee:rotation"]
	for path in paths:
		var track := animation.add_track(Animation.TYPE_VALUE)
		animation.track_set_path(track, NodePath(path))
	for i in range(33):
		var phase := TAU * i / 32.0
		var wave := sin(phase)
		var beat := cos(phase * 2)
		var values: Array[Vector3] = [
			Vector3(0, 0.79 + wave * 0.008, 0), Vector3(0, wave * 0.025, 0), Vector3(0, wave * -0.035, 0),
			Vector3(0.03, 0, -0.13), Vector3(-0.02, 0, 0.13), Vector3(-0.13, 0, 0), Vector3(-0.13, 0, 0),
			Vector3.ZERO, Vector3.ZERO, Vector3.ZERO, Vector3.ZERO]
		if clip == "Walk":
			values[0] = Vector3(0, 0.78 + beat * 0.027, 0)
			values[1] = Vector3(0.04, wave * 0.10, 0)
			values[3].x = -wave * 0.53
			values[4].x = wave * 0.53
			values[7].x = wave * 0.59
			values[8].x = -wave * 0.59
			values[9].x = maxf(0, -wave) * 0.66
			values[10].x = maxf(0, wave) * 0.66
		for track in range(values.size()):
			animation.track_insert_key(track, length * i / 32.0, values[track])
	return animation


func load_dance() -> Animation:
	var definition: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://Dance.json"))
	var animation := Animation.new()
	animation.length = definition.duration
	animation.loop_mode = Animation.LOOP_LINEAR
	for channel: Dictionary in definition.tracks:
		var track := animation.add_track(Animation.TYPE_VALUE)
		var path: String = channel.joint + ":" + channel.property
		animation.track_set_path(track, NodePath(path))
		var sample_count: int = channel.x.size()
		for i in range(sample_count):
			var value := Vector3(channel.x[i], channel.y[i], channel.z[i])
			if channel.property == "rotation":
				value *= PI / 180.0
			animation.track_insert_key(track, animation.length * i / (sample_count - 1), value)
	return animation


func build_hud() -> void:
	var overlay := CanvasLayer.new()
	add_child(overlay)
	var panel := PanelContainer.new()
	panel.position = Vector2(24, 24)
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var background := StyleBoxFlat.new()
	background.bg_color = Color(0.12, 0.10, 0.15, 0.88)
	background.corner_radius_top_left = 12
	background.corner_radius_top_right = 12
	background.corner_radius_bottom_left = 12
	background.corner_radius_bottom_right = 12
	background.content_margin_left = 18
	background.content_margin_right = 18
	background.content_margin_top = 11
	background.content_margin_bottom = 11
	panel.add_theme_stylebox_override("panel", background)
	overlay.add_child(panel)
	var label := Label.new()
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.text = "WASD   Ходьба     Мышь   Камера     F   Пощёчина     Esc   Курсор"
	label.add_theme_font_size_override("font_size", 17)
	label.add_theme_color_override("font_color", Color("#fff3e1"))
	panel.add_child(label)


func joint(parent: Node3D, joint_name: String, at: Vector3) -> Node3D:
	var pivot := Node3D.new()
	pivot.name = joint_name
	parent.add_child(pivot)
	pivot.position = at
	return pivot


func add_collision(parent: CollisionObject3D, shape: Shape3D, at: Vector3) -> void:
	var collider := CollisionShape3D.new()
	collider.shape = shape
	collider.position = at
	parent.add_child(collider)


func solid_box(at: Vector3, size: Vector3, color: Color) -> void:
	var body := StaticBody3D.new()
	add_child(body)
	body.position = at
	var shape := BoxShape3D.new()
	shape.size = size
	add_collision(body, shape, Vector3.ZERO)
	box(body, Vector3.ZERO, size, color)


func box(parent: Node3D, at: Vector3, size: Vector3, color: Color) -> MeshInstance3D:
	var mesh := BoxMesh.new()
	mesh.size = size
	return surface(parent, at, mesh, color)


func sphere(parent: Node3D, at: Vector3, size: Vector3, color: Color) -> void:
	var mesh := SphereMesh.new()
	mesh.radial_segments = 12
	mesh.rings = 6
	surface(parent, at, mesh, color).scale = size


func cylinder(parent: Node3D, at: Vector3, radius: float, height: float, color: Color) -> void:
	var mesh := CylinderMesh.new()
	mesh.top_radius = radius
	mesh.bottom_radius = radius
	mesh.height = height
	mesh.radial_segments = 56
	surface(parent, at, mesh, color)


func surface(parent: Node3D, at: Vector3, mesh: Mesh, color: Color) -> MeshInstance3D:
	var object := MeshInstance3D.new()
	object.position = at
	object.mesh = mesh
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.roughness = 0.88
	object.material_override = material
	parent.add_child(object)
	return object
