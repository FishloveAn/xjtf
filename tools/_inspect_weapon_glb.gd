extends SceneTree

# 检查武器 GLB 导入后结构：节点树/包围盒/tris/朝向（最长轴是否 -Z）
# 用法: godot --headless --script tools/_inspect_weapon_glb.gd

const FILES := [
	"res://assets/models/weapons/wep_pistol_01.glb",
	"res://assets/models/weapons/wep_shotgun_01.glb",
	"res://assets/models/weapons/wep_rifle_01.glb",
]


func _initialize() -> void:
	for path in FILES:
		var scene: PackedScene = load(path)
		if scene == null:
			printerr("FAIL load " + path)
			continue
		var root: Node3D = scene.instantiate()
		root.name = "W"
		get_root().add_child(root)
		await process_frame
		var aabb := _collect_aabb(root)
		print(path.split("/")[-1])
		print("  bounds pos=", aabb.position, " size=", aabb.size)
		print("  longest axis=", _longest_axis(aabb.size))
		print("  tris=", _count_tris(root))
		root.free()
	quit(0)


func _collect_aabb(n: Node) -> AABB:
	var out := AABB()
	for c in n.get_children():
		if c is MeshInstance3D:
			var mi: MeshInstance3D = c
			out = out.merge(mi.global_transform * mi.mesh.get_aabb())
		out = out.merge(_collect_aabb(c))
	return out


func _longest_axis(sz: Vector3) -> String:
	var ax := 0
	if sz.y > sz.x:
		ax = 1
	if sz.z > sz[ax]:
		ax = 2
	return ["X", "Y", "Z"][ax]


func _count_tris(n: Node) -> int:
	var t := 0
	for c in n.get_children():
		if c is MeshInstance3D:
			var mi: MeshInstance3D = c
			for s in mi.mesh.get_surface_count():
				var arrays := mi.mesh.surface_get_arrays(s)
				if arrays and arrays.size() > 0 and arrays[ArrayMesh.ARRAY_INDEX] != null:
					t += arrays[ArrayMesh.ARRAY_INDEX].size() / 3
		t += _count_tris(c)
	return t
