extends SceneTree
## 普通丧尸可见距离回归：GLB Visual 子树与旧 MeshInstance3D Visual 都应用 60m 剔除距离。
## 用法：godot --headless --path . --script tools/test_zombie_visibility_range.gd

const ZOMBIE_SCENE_PATH := "res://scenes/enemies/zombie_common.tscn"
const ZOMBIE_AI_SCRIPT_PATH := "res://scripts/ai/zombie_ai_common.gd"
const EXPECTED_RANGE_END := 60.0

var _fail := 0


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	print("=== ZOMBIE VISIBILITY RANGE TEST START ===")
	var zombie_scene := load(ZOMBIE_SCENE_PATH) as PackedScene
	var zombie_ai_script := load(ZOMBIE_AI_SCRIPT_PATH) as Script
	_check(zombie_scene != null and zombie_ai_script != null, "普通丧尸场景与 AI 脚本可加载")
	if zombie_scene == null or zombie_ai_script == null:
		quit(_fail)
		return
	var glb_zombie := zombie_scene.instantiate() as CharacterBody3D
	root.add_child(glb_zombie)
	await process_frame
	_check_visual_geometry(glb_zombie, "实例化 GLB")
	glb_zombie.queue_free()
	await process_frame

	var legacy_zombie := _create_legacy_zombie(zombie_ai_script)
	root.add_child(legacy_zombie)
	await process_frame
	_check_visual_geometry(legacy_zombie, "旧 MeshInstance3D")
	legacy_zombie.queue_free()
	await process_frame

	print("=== ZOMBIE VISIBILITY RANGE TEST %s (fail=%d) ===" % [
		"PASS" if _fail == 0 else "FAIL", _fail])
	quit(_fail)


func _create_legacy_zombie(zombie_ai_script: Script) -> CharacterBody3D:
	var zombie := CharacterBody3D.new()
	zombie.name = "LegacyZombie"
	var visual := MeshInstance3D.new()
	visual.name = "Visual"
	visual.mesh = BoxMesh.new()
	zombie.add_child(visual)
	var ai := Node.new()
	ai.name = "AI"
	ai.set_script(zombie_ai_script)
	zombie.add_child(ai)
	return zombie


func _check_visual_geometry(zombie: CharacterBody3D, label: String) -> void:
	var visual := zombie.get_node_or_null("Visual")
	var geometries: Array[GeometryInstance3D] = []
	_collect_geometry(visual, geometries)
	_check(not geometries.is_empty(), "%s Visual 下存在 GeometryInstance3D" % label)
	for geometry in geometries:
		_check(is_equal_approx(geometry.visibility_range_end, EXPECTED_RANGE_END),
			"%s/%s visibility_range_end=%.1f" % [
				label, str(visual.get_path_to(geometry)), geometry.visibility_range_end])


func _collect_geometry(node: Node, output: Array[GeometryInstance3D]) -> void:
	if node == null:
		return
	if node is GeometryInstance3D:
		output.append(node as GeometryInstance3D)
	for child in node.get_children():
		_collect_geometry(child, output)


func _check(condition: bool, label: String) -> void:
	if condition:
		print("  [PASS] " + label)
	else:
		_fail += 1
		print("  [FAIL] " + label)
