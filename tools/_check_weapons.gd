extends SceneTree

# 批量检查武器 FBX 尺寸（导入后含 node scale）
# 用法: godot --headless --script tools/_check_weapons.gd

const FILES := [
	"res://assets/models/weapons/_test_pistol.fbx",
]


func _initialize() -> void:
	for path in FILES:
		var scene: PackedScene = load(path)
		if scene == null:
			printerr("FAIL load " + path)
			continue
		var root: Node3D = scene.instantiate()
		var aabb := _collect_aabb(root)
		print(path.split("/")[-1], " -> bounds pos=", aabb.position, " size=", aabb.size)
		root.free()
	quit(0)


func _collect_aabb(n: Node) -> AABB:
	var out := AABB()
	for child in n.get_children():
		if child is MeshInstance3D:
			var mi: MeshInstance3D = child
			var a := mi.get_aabb()  # 本地
			var gt := mi.global_transform
			# 世界 AABB（含父节点 scale）
			var wa := gt * a
			if out.size == Vector3.ZERO:
				out = wa
			else:
				out = out.merge(wa)
		out = out.merge(_collect_aabb(child))
	return out
