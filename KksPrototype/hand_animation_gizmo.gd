extends MeshInstance3D

const COLORS := [Color("#ff6868"), Color("#71e778"), Color("#62aaff")]
const SEGMENTS := 32
var drawing := ImmediateMesh.new()
var handles: Array[Array] = [[], [], []]
var pivot := Transform3D.IDENTITY
var axis_parent := Basis.IDENTITY
var size_m := 0.12
var rotating := false
var axis := -1
var initial := Transform3D.IDENTITY
var click := Vector2.ZERO
var drag_camera: Camera3D
var start_vector := Vector3.ZERO


func _ready() -> void:
	mesh = drawing
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.no_depth_test = true
	material.vertex_color_use_as_albedo = true
	material_override = material
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	hide()


func redraw(camera: Camera3D, pose: Transform3D, parent_basis: Basis, rings: bool,
		path: PackedVector3Array, keys: PackedVector3Array) -> void:
	if axis < 0:
		pivot = pose
		axis_parent = parent_basis
		rotating = rings
		size_m = clampf(camera.global_position.distance_to(pose.origin) * 0.17, 0.055, 0.24)
	drawing.clear_surfaces()
	drawing.surface_begin(Mesh.PRIMITIVE_LINES)
	for index in range(3):
		var points := handles[index]
		points.clear()
		var direction: Vector3 = axis_parent[index]
		var cross: Vector3 = axis_parent[(index + 1) % 3]
		var other: Vector3 = axis_parent[(index + 2) % 3]
		var ink: Color = Color.WHITE if index == axis else COLORS[index]
		if rotating:
			for step in range(SEGMENTS + 1):
				var angle := TAU * step / SEGMENTS
				points.append(pivot.origin + (cross * cos(angle) + other * sin(angle)) * size_m)
		else:
			points.append(pivot.origin + direction * size_m * 0.14)
			points.append(pivot.origin + direction * size_m)
			var arrow: Vector3 = points[1] - direction * size_m * 0.2
			for tip in [cross, -cross, other, -other]:
				_line(points[1], arrow + tip * size_m * 0.085, ink)
		for index2 in range(1, points.size()):
			_line(points[index2 - 1], points[index2], ink)
	for index in range(1, path.size()):
		_line(path[index - 1], path[index], Color("#ffd875"))
		if index % 8 == 0:
			var heading := (path[index] - path[index - 1]).normalized()
			var cross := heading.cross(camera.global_basis.z).normalized() * size_m * 0.055
			_line(path[index], path[index] - heading * size_m * 0.11 + cross, Color("#ffd875"))
			_line(path[index], path[index] - heading * size_m * 0.11 - cross, Color("#ffd875"))
	for point in keys:
		for index in range(3):
			var arm: Vector3 = axis_parent[index] * size_m * 0.075
			_line(point - arm, point + arm, Color("#ffe7a8"))
	drawing.surface_end()
	show()


func begin(camera: Camera3D, screen: Vector2, local: Transform3D) -> bool:
	if not visible:
		return false
	var closest := 10.0
	for index in range(3):
		var points := handles[index]
		for j in range(1, points.size()):
			var a: Vector3 = points[j - 1]
			var b: Vector3 = points[j]
			if camera.is_position_behind(a) or camera.is_position_behind(b):
				continue
			var candidate := Geometry2D.get_closest_point_to_segment(screen,
				camera.unproject_position(a), camera.unproject_position(b)).distance_to(screen)
			if candidate < closest:
				closest = candidate
				axis = index
	if axis < 0:
		return false
	drag_camera = camera
	initial = local
	click = screen
	start_vector = _ray_vector(screen)
	return true


func drag(screen: Vector2) -> Transform3D:
	var updated := initial
	if axis < 0:
		return updated
	var direction: Vector3 = axis_parent[axis]
	var local_axis := Vector3.ZERO
	local_axis[axis] = 1.0
	if rotating:
		var current := _ray_vector(screen)
		var amount := (screen.x - click.x - screen.y + click.y) * 0.009
		if not current.is_zero_approx() and not start_vector.is_zero_approx():
			amount = start_vector.signed_angle_to(current, direction)
		updated.basis = Basis(local_axis, amount) * initial.basis
	else:
		var start := drag_camera.unproject_position(pivot.origin)
		var screen_axis := drag_camera.unproject_position(pivot.origin + direction * size_m) - start
		var amount := -(screen.y - click.y) * size_m / 65.0
		if screen_axis.length_squared() > 25.0:
			amount = (screen - click).dot(screen_axis) * size_m / screen_axis.length_squared()
		updated.origin += local_axis * amount
	return updated


func finish() -> void:
	axis = -1
	drag_camera = null


func _ray_vector(screen: Vector2) -> Vector3:
	var direction: Vector3 = axis_parent[axis]
	var ray := drag_camera.project_ray_normal(screen)
	if absf(ray.dot(direction)) < 0.14:
		return Vector3.ZERO
	var hit: Variant = Plane(direction, pivot.origin).intersects_ray(drag_camera.project_ray_origin(screen), ray)
	return (Vector3(hit) - pivot.origin).normalized() if hit is Vector3 else Vector3.ZERO


func _line(a: Vector3, b: Vector3, color: Color) -> void:
	drawing.surface_set_color(color)
	drawing.surface_add_vertex(a)
	drawing.surface_add_vertex(b)
