extends SubViewport

const IDLE := Quaternion(Vector3.UP, -0.36) * Quaternion(Vector3.RIGHT, 0.22)
const TO_WORLD := Basis(Vector3.RIGHT, -PI / 2.0)

var accent := Color.WHITE
var _phone := Node3D.new()
var _target := IDLE

func _ready() -> void:
	size = Vector2i(342, 232)
	transparent_bg = true
	own_world_3d = true
	msaa_3d = Viewport.MSAA_4X
	render_target_update_mode = SubViewport.UPDATE_ONCE
	var camera := Camera3D.new()
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.size = 1.80
	add_child(camera)
	camera.position = Vector3(1.4, 1.6, 5.0)
	camera.look_at(Vector3.ZERO)
	camera.make_current()

	var environment := WorldEnvironment.new()
	environment.environment = Environment.new()
	environment.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.environment.ambient_light_color = Color("#e4f0ff")
	environment.environment.ambient_light_energy = 0.72
	add_child(environment)
	var key := DirectionalLight3D.new()
	key.rotation_degrees = Vector3(-32, -22, 0)
	key.light_energy = 1.35
	add_child(key)
	var fill := DirectionalLight3D.new()
	fill.rotation_degrees = Vector3(-23, 145, 0)
	fill.light_energy = 0.85
	add_child(fill)

	add_child(_phone)
	_phone.quaternion = IDLE
	_build_phone()
	set_process(false)

func set_angles(angles: Variant) -> void:
	var target := IDLE
	if angles is Vector3:
		# Browser rotations are intrinsic Z–X–Y, with world +Z pointing up.
		var heading := Basis(Vector3.BACK, deg_to_rad(angles.x))
		var pitch := Basis(Vector3.RIGHT, deg_to_rad(angles.y))
		var roll := Basis(Vector3.UP, deg_to_rad(angles.z))
		target = (TO_WORLD * heading * pitch * roll).get_rotation_quaternion()
	if absf(_target.dot(target)) > 0.9999995:
		return
	_target = target
	set_process(true)

func _process(delta: float) -> void:
	var current := _phone.quaternion
	if absf(current.dot(_target)) > 0.9999995:
		_phone.quaternion = _target
		set_process(false)
	else:
		_phone.quaternion = current.slerp(_target, 1.0 - exp(-24.0 * delta))
	render_target_update_mode = SubViewport.UPDATE_ONCE

func _build_phone() -> void:
	var trim := accent.darkened(0.48)
	var glass := Color("#19292e")
	var dark := Color("#10191d")
	_slab(Vector3.ZERO, Vector3(0.75, 1.49, 0.108), 0.085, trim)
	_slab(Vector3(0, 0, -0.057), Vector3(0.713, 1.45, 0.010), 0.076, trim.darkened(0.45))
	_slab(Vector3(0, 0, 0.057), Vector3(0.716, 1.45, 0.012), 0.074, dark)
	_slab(Vector3(0, -0.005, 0.065), Vector3(0.653, 1.354, 0.007), 0.056, glass)
	_slab(Vector3(0, 0.592, 0.072), Vector3(0.205, 0.051, 0.008), 0.025, dark)
	_slab(Vector3(0, -0.605, 0.072), Vector3(0.198, 0.017, 0.006), 0.008, accent.darkened(0.2))
	_slab(Vector3(0.365, 0.211, 0), Vector3(0.040, 0.232, 0.035), 0.016, trim)
	_slab(Vector3(0.172, 0.465, -0.066), Vector3(0.300, 0.340, 0.031), 0.045, trim)
	_lens(Vector3(0.116, 0.518, -0.091))
	_lens(Vector3(0.230, 0.408, -0.091))
	for side in [-1, 1]:
		var mark := BoxMesh.new()
		mark.size = Vector3(0.158, 0.017, 0.008)
		var segment := _mesh(mark, accent, Vector3(0.055 * side, 0.054, 0.073))
		segment.rotation.z = -side * PI / 4.0

func _lens(center: Vector3) -> void:
	var rim := CylinderMesh.new()
	rim.top_radius = 0.061
	rim.bottom_radius = 0.061
	rim.height = 0.015
	_mesh(rim, Color("#1d282d"), center).rotation.x = PI / 2.0
	var lens := CylinderMesh.new()
	lens.top_radius = 0.039
	lens.bottom_radius = 0.039
	lens.height = 0.009
	_mesh(lens, Color("#395b72"), center - Vector3(0, 0, 0.009)).rotation.x = PI / 2.0

func _slab(center: Vector3, dimensions: Vector3, radius: float, color: Color) -> void:
	var half_width := dimensions.x / 2.0
	var half_height := dimensions.y / 2.0
	var half_depth := dimensions.z / 2.0
	var outline := PackedVector2Array()
	for corner in range(4):
		var corner_angle := corner * PI / 2.0
		var sign_angle := corner_angle + PI / 4.0
		var inset := Vector2(signf(cos(sign_angle)) * (half_width - radius),
			signf(sin(sign_angle)) * (half_height - radius))
		for step in range(7):
			var angle := corner_angle + step * PI / 12.0
			outline.append(inset + Vector2(cos(angle), sin(angle)) * radius)

	var surface := SurfaceTool.new()
	surface.begin(Mesh.PRIMITIVE_TRIANGLES)
	surface.set_smooth_group(-1)
	for index in range(outline.size()):
		var a := outline[index]
		var b := outline[(index + 1) % outline.size()]
		var front_a := Vector3(a.x, a.y, half_depth)
		var front_b := Vector3(b.x, b.y, half_depth)
		var back_a := Vector3(a.x, a.y, -half_depth)
		var back_b := Vector3(b.x, b.y, -half_depth)
		for vertex in [
			Vector3(0, 0, half_depth), front_b, front_a,
			Vector3(0, 0, -half_depth), back_a, back_b,
			back_a, front_b, back_b,
			back_a, front_a, front_b
		]:
			surface.add_vertex(vertex)
	surface.generate_normals()
	_mesh(surface.commit(), color, center)

func _mesh(mesh: Mesh, color: Color, position: Vector3) -> MeshInstance3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.roughness = 0.68
	var instance := MeshInstance3D.new()
	instance.mesh = mesh
	instance.material_override = material
	instance.position = position
	_phone.add_child(instance)
	return instance
