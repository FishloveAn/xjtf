extends SceneTree

# 读取 FBX 实例化并挂到 root 后的全局包围盒（含 node scale/rotation）
# 用法: godot --headless --script tools/_fbx_global_aabb.gd

const PATH := "res://assets/models/weapons/_test_pistol.fbx"


func _initialize() -> void:
	var scene: PackedScene = load(PATH)
	if scene == null:
		printerr("FAIL load")
		quit(1)
		return
	var root: Node3D = scene.instantiate()
	root.name = "FXB_ROOT"
	get_root().add_child(root)
	await process_frame
	var mesh_nodes: Array[Node] = []
	_collect_mesh(root, mesh_nodes)
	for mi in mesh_nodes:
		var mesh: Mesh = (mi as MeshInstance3D).mesh
		var local := mesh.get_aabb()
		var world := (mi as Node3D).global_transform * local
		print("mesh '", mi.name, "' local_size=", local.size, " world_size=", world.size)
		print("  node scale=", (mi as Node3D).scale, " rot=", (mi as Node3D).rotation)
	root.free()
	quit(0)


func _collect_mesh(n: Node, out: Array[Node]) -> void:
	for c in n.get_children():
		if c is MeshInstance3D:
			out.append(c)
		_collect_mesh(c, out)
