extends SceneTree

# 检查 char_zombie_common_01.glb 的网格信息：tris 数、包围盒、材质数
# 用法: godot --headless --script tools/_inspect_glb.gd

var _aabb := AABB()
var _tris := 0
var _mats := 0

func _initialize() -> void:
	var path := "res://assets/models/characters/char_zombie_common_01.glb"
	var scene: PackedScene = load(path)
	if scene == null:
		push_error("FAIL: cannot load " + path)
		quit(1)
		return
	var root: Node3D = scene.instantiate()
	_collect(root)
	print("root children: ", root.get_child_count())
	print("bounds: pos=", _aabb.position, " size=", _aabb.size)
	print("height: ", _aabb.size.y)
	print("total tris: ", _tris)
	print("material slots: ", _mats)
	for child in root.get_children():
		if child is MeshInstance3D:
			var mi: MeshInstance3D = child
			print("  MeshInstance: ", child.name, " surfaces=", mi.mesh.get_surface_count())
			for s in mi.mesh.get_surface_count():
				var mat = mi.mesh.surface_get_material(s)
				if mat:
					print("    surface ", s, " material: ", mat.resource_name if mat.resource_name else mat.get_class())
			print("  aabb=", mi.get_aabb())
	root.free()
	quit(0)

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
				_mats += 1
		_collect(child)
