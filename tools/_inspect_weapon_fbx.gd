extends SceneTree

# 检查武器 FBX 导入后结构（节点树/包围盒/tris）
# 用法: godot --headless --script tools/_inspect_weapon_fbx.gd

var _aabb := AABB()
var _tris := 0


func _initialize() -> void:
	var path := "res://assets/models/weapons/_test_pistol.fbx"
	var scene: PackedScene = load(path)
	if scene == null:
		push_error("FAIL: cannot load " + path)
		quit(1)
		return
	var root: Node3D = scene.instantiate()
	_dump_node(root, 0)
	print("bounds: pos=", _aabb.position, " size=", _aabb.size)
	print("height(y): ", _aabb.size.y)
	print("total tris: ", _tris)
	root.free()
	quit(0)


func _dump_node(n: Node, depth: int) -> void:
	var pad := "  ".repeat(depth)
	print(pad + n.get_class() + " '" + n.name + "'")
	if n is Node3D:
		var t: Node3D = n
		print(pad + "    pos=", t.position, " rot=", t.rotation, " scale=", t.scale)
	_collect(n)
	for c in n.get_children():
		_dump_node(c, depth + 1)


func _collect(n: Node) -> void:
	for child in n.get_children():
		if child is MeshInstance3D:
			var mi: MeshInstance3D = child
			var a := mi.get_aabb()
			if _aabb.size == Vector3.ZERO:
				_aabb = a
			else:
				_aabb = _aabb.merge(a)
			for s in mi.mesh.get_surface_count():
				var arrays := mi.mesh.surface_get_arrays(s)
				if arrays and arrays.size() > 0 and arrays[ArrayMesh.ARRAY_INDEX] != null:
					_tris += arrays[ArrayMesh.ARRAY_INDEX].size() / 3
		_collect(child)
