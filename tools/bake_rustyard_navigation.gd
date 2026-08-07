extends SceneTree
## 离线生成 Rustyard 导航网格。按 BoxShape3D 静态墙生成膨胀网格；安全门明确跳过，保证门洞连通。
## 用法：godot --headless --path . --script tools/bake_rustyard_navigation.gd

const RUSTYARD_SCENE := "res://scenes/environment/rustyard/rustyard.tscn"
const OUTPUT_PATH := "res://scenes/environment/rustyard/rustyard_navigation_mesh.tres"
const CELL_SIZE := 0.4
const AGENT_RADIUS := 0.4


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var packed := load(RUSTYARD_SCENE) as PackedScene
	if packed == null:
		_fail("无法加载 Rustyard 场景")
		return
	var rustyard := packed.instantiate() as Node3D
	root.add_child(rustyard)
	var safe_door := rustyard.get_node_or_null("Walls/SafeDoor")
	if safe_door == null:
		_fail("找不到 SafeDoor，拒绝生成可能封死门洞的导航网格")
		return
	var ground_collision := rustyard.get_node_or_null("Ground/Collision") as CollisionShape3D
	if ground_collision == null or not (ground_collision.shape is BoxShape3D):
		_fail("Ground/Collision 不是 BoxShape3D")
		return
	var ground_size := (ground_collision.shape as BoxShape3D).size
	var ground_center := ground_collision.global_position
	var min_x := ground_center.x - ground_size.x * 0.5 + AGENT_RADIUS
	var max_x := ground_center.x + ground_size.x * 0.5 - AGENT_RADIUS
	var min_z := ground_center.z - ground_size.z * 0.5 + AGENT_RADIUS
	var max_z := ground_center.z + ground_size.z * 0.5 - AGENT_RADIUS
	var columns := int(floor((max_x - min_x) / CELL_SIZE))
	var rows := int(floor((max_z - min_z) / CELL_SIZE))
	if columns <= 0 or rows <= 0 or columns * rows > 20000:
		_fail("导航单元规模异常：%d×%d" % [columns, rows])
		return

	var obstacles: Array[Rect2] = []
	for body in rustyard.find_children("*", "StaticBody3D", true, false):
		if body.name == "Ground" or body == safe_door:
			continue
		var collision := body.get_node_or_null("Collision") as CollisionShape3D
		if collision == null or collision.disabled or not (collision.shape is BoxShape3D):
			continue
		var size := (collision.shape as BoxShape3D).size
		var center := collision.global_position
		obstacles.append(Rect2(
			Vector2(center.x - size.x * 0.5 - AGENT_RADIUS, center.z - size.z * 0.5 - AGENT_RADIUS),
			Vector2(size.x + AGENT_RADIUS * 2.0, size.z + AGENT_RADIUS * 2.0)))

	var vertices := PackedVector3Array()
	var vertex_indices := {}
	var polygons: Array[PackedInt32Array] = []
	var walkable_cells := 0
	for z_index in rows:
		for x_index in columns:
			var center := Vector2(
				min_x + (float(x_index) + 0.5) * CELL_SIZE,
				min_z + (float(z_index) + 0.5) * CELL_SIZE)
			if _is_blocked(center, obstacles):
				continue
			var polygon := PackedInt32Array()
			polygon.append(_vertex_index(Vector2i(x_index, z_index), min_x, min_z, vertices, vertex_indices))
			polygon.append(_vertex_index(Vector2i(x_index, z_index + 1), min_x, min_z, vertices, vertex_indices))
			polygon.append(_vertex_index(Vector2i(x_index + 1, z_index + 1), min_x, min_z, vertices, vertex_indices))
			polygon.append(_vertex_index(Vector2i(x_index + 1, z_index), min_x, min_z, vertices, vertex_indices))
			polygons.append(polygon)
			walkable_cells += 1

	if walkable_cells < 1000 or walkable_cells > 18000:
		_fail("可行走单元规模异常：%d" % walkable_cells)
		return
	var navigation_mesh := NavigationMesh.new()
	navigation_mesh.agent_radius = AGENT_RADIUS
	navigation_mesh.agent_height = 1.7
	navigation_mesh.set_vertices(vertices)
	for polygon in polygons:
		navigation_mesh.add_polygon(polygon)

	var polygon_count := navigation_mesh.get_polygon_count()
	var vertex_count := navigation_mesh.get_vertices().size()
	if polygon_count == 0 or vertex_count == 0:
		rustyard.queue_free()
		_fail("烘焙结果为空")
		return
	var error := ResourceSaver.save(navigation_mesh, OUTPUT_PATH)
	rustyard.queue_free()
	if error != OK:
		_fail("保存导航资源失败，错误码 %d" % error)
		return
	print("[PASS] Rustyard 导航网格已生成：polygons=%d vertices=%d cells=%d" % [polygon_count, vertex_count, walkable_cells])
	print("[PASS] SafeDoor 未参与静态导航源")
	quit(0)


func _fail(message: String) -> void:
	push_error("[FAIL] " + message)
	quit(1)


func _is_blocked(point: Vector2, obstacles: Array[Rect2]) -> bool:
	for obstacle in obstacles:
		if obstacle.has_point(point):
			return true
	return false


func _vertex_index(grid_point: Vector2i, min_x: float, min_z: float,
		vertices: PackedVector3Array, indices: Dictionary) -> int:
	if indices.has(grid_point):
		return int(indices[grid_point])
	var index := vertices.size()
	vertices.append(Vector3(
		min_x + float(grid_point.x) * CELL_SIZE,
		0.0,
		min_z + float(grid_point.y) * CELL_SIZE))
	indices[grid_point] = index
	return index
