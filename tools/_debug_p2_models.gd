extends SceneTree

# P2 验证：玩家 Body + 4 把武器模型存在性/节点结构/尺寸（写日志，不做硬性 PASS/FAIL 让 debug_weapon 评判）
# 用法: godot --headless --path . --script tools/_debug_p2_models.gd

const LOG := "user://p2_models_check.log"

var _failures: int = 0
var _lines: PackedStringArray = []


func _initialize() -> void:
	_check_player()
	_check_weapon("Pistol", "res://assets/models/weapons/wep_pistol_01.glb", 0.2, 0.3)
	_check_weapon("Shotgun", "res://assets/models/weapons/wep_shotgun_01.glb", 0.8, 1.0)
	_check_weapon("Rifle", "res://assets/models/weapons/wep_rifle_01.glb", 0.7, 0.9)
	_check_weapon("SMG", "res://assets/models/weapons/wep_smg_01.glb", 0.5, 0.7)
	_log("=== P2 Models Check END (failures=%d) ===" % _failures)
	# 输出汇总
	for ln in _lines:
		print(ln)
	print("DONE failures=%d" % _failures)
	quit(0)


func _log(s: String) -> void:
	print(s)
	_lines.append(s)


func _check_player() -> void:
	_log("--- Player Body ---")
	var path := "res://assets/models/characters/char_player_01.glb"
	var ps: PackedScene = load(path)
	if ps == null:
		_log("  FAIL: cannot load " + path)
		_failures += 1
		return
	var inst: Node3D = ps.instantiate()
	_log("  load: ok | root=" + inst.name + " | class=" + inst.get_class())
	inst.name = "PLAYER"
	get_root().add_child(inst)
	await process_frame
	_collect_mesh_info(inst, "  ")
	inst.queue_free()


func _check_weapon(tag: String, path: String, min_len: float, max_len: float) -> void:
	_log("--- Weapon %s ---" % tag)
	var ps: PackedScene = load(path)
	if ps == null:
		_log("  FAIL: load " + path)
		_failures += 1
		return
	var inst: Node3D = ps.instantiate()
	_log("  load: ok | root=" + inst.name)
	inst.name = "W_" + tag
	get_root().add_child(inst)
	await process_frame
	_collect_mesh_info(inst, "  ")
	# 验长度
	var sz: Vector3 = _global_size(inst)
	var longest: float = max(sz.x, sz.y, sz.z)
	_log("  longest axis=%.3f (target %.2f-%.2f)" % [longest, min_len, max_len])
	if longest < min_len or longest > max_len:
		_log("  WARN: length %.3f outside [%.2f,%.2f]" % [longest, min_len, max_len])
	# 验场景引用
	var scene := "res://scenes/weapons/" + tag.to_lower() + ".tscn"
	var sres: PackedScene = load(scene)
	if sres == null:
		_log("  FAIL: load scene " + scene)
		_failures += 1
	else:
		var root: Node = sres.instantiate()
		var visual: Node = root.get_node_or_null("Visual")
		if visual == null:
			_log("  FAIL: scene has no Visual child")
			_failures += 1
		else:
			_log("  scene Visual: " + visual.get_class() + " instance ok")
		root.free()
	inst.queue_free()


func _collect_mesh_info(n: Node, indent: String) -> void:
	for c in n.get_children():
		if c is MeshInstance3D:
			var mi: MeshInstance3D = c
			var tris: int = 0
			for s in mi.mesh.get_surface_count():
				var arrays = mi.mesh.surface_get_arrays(s)
				if arrays and arrays.size() > 0 and arrays[ArrayMesh.ARRAY_INDEX] != null:
					tris += arrays[ArrayMesh.ARRAY_INDEX].size() / 3
			var aabb: AABB = mi.global_transform * mi.mesh.get_aabb()
			_log("%s  MeshInstance '%s' | surfaces=%d | tris=%d | size=%.3fx%.3fx%.3f" % [
				indent, c.name, mi.mesh.get_surface_count(), tris, aabb.size.x, aabb.size.y, aabb.size.z])
		_collect_mesh_info(c, indent)


func _global_size(n: Node) -> Vector3:
	var sz := Vector3.ZERO
	for c in n.get_children():
		if c is MeshInstance3D:
			var a: AABB = (c as MeshInstance3D).global_transform * (c as MeshInstance3D).mesh.get_aabb()
			sz = a.size
		var cs: Vector3 = _global_size(c)
		if cs.length() > sz.length():
			sz = cs
	return sz
