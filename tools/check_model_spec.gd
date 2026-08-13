extends SceneTree
## 模型规格校验器（Model Spec Checker）
## 按 docs/项目文档/02-设计/02-设计-美术-替换清单-M3.md §1 预算表自动检查 assets/models/ 下所有 .glb
## 检查项：tris 预算 / 材质数 ≤2 / 身高（角色） / 骨骼（普通丧尸应无、特感应有）
## 用法：
##   godot --headless --script tools/check_model_spec.gd                 # 检查全部
##   godot --headless --script tools/check_model_spec.gd res://assets/models/characters/char_zombie_common_01.glb  # 单文件
## 退出码：0 = 全部通过；1 = 存在 FAIL

const ROOT_DIR := "res://assets/models/"

# 预算表（按替换清单 §1）——面数是性能预算，超过上限才判失败
const BUDGETS := [
	["char_zombie_common", [500, 1200, "普通丧尸 ≤1200 tris"]],
	["char_goblin_", [2000, 4000, "哥布林特感 2000-4000 tris"]],
	["char_zombie_charger", [2000, 4000, "特感 2000-4000 tris"]],
	["char_zombie_spitter", [2000, 4000, "特感 2000-4000 tris"]],
	["char_player", [0, 3000, "玩家 ≤3000 tris"]],
	["char_survivor", [0, 3000, "玩家 ≤3000 tris"]],
	["wep_", [400, 2200, "武器 400-2200 tris"]],
	["env_prop", [0, 800, "装饰件 ≤800 tris"]],
	["env_", [0, 5000, "环境块 ≤5000 tris"]],
	["prop_", [0, 400, "道具 ≤400 tris"]],
]

# 无骨骼要求前缀（普通丧尸走剥骨方案，见替换清单 §2.1 方案 B）
const NO_SKELETON_PREFIXES := ["char_zombie_common"]
# 必须带骨骼前缀（特感带骨骼 + AnimationPlayer，§2.3）
const MUST_SKELETON_PREFIXES := ["char_goblin_", "char_zombie_charger", "char_zombie_spitter"]

var _pass := 0
var _fail := 0
var _files_checked := 0

func _initialize() -> void:
	var targets := _collect_targets()
	if targets.is_empty():
		print("NO_MODELS_FOUND in ", ROOT_DIR)
		quit(1)
		return
	for path in targets:
		_check_one(path)
	print("")
	print("SUMMARY: checked=", _files_checked, " PASS=", _pass, " FAIL=", _fail)
	quit(1 if _fail > 0 else 0)

func _collect_targets() -> Array:
	# 支持命令行单文件参数
	var args := OS.get_cmdline_user_args()
	if not args.is_empty():
		return args
	var out := []
	var dir := DirAccess.open(ROOT_DIR)
	if dir == null:
		push_error("FAIL: cannot open " + ROOT_DIR)
		return out
	for sub in _list_dirs(dir):
		var sub_dir := DirAccess.open(ROOT_DIR + sub)
		if sub_dir == null:
			continue
		for f in sub_dir.get_files():
			if f.ends_with(".glb"):
				out.append(ROOT_DIR + sub + "/" + f)
	return out

func _list_dirs(dir: DirAccess) -> Array:
	var out := []
	dir.list_dir_begin()
	var name := dir.get_next()
	while name != "":
		if dir.current_is_dir() and not name.begins_with("."):
			out.append(name)
		name = dir.get_next()
	dir.list_dir_end()
	return out

func _check_one(path: String) -> void:
	_files_checked += 1
	var scene: PackedScene = load(path)
	if scene == null:
		_fail += 1
		print("FAIL  ", path, "  [cannot load]")
		return
	var root: Node3D = scene.instantiate()
	var info := _analyze(root)
	root.free()

	var fname := path.get_file().to_lower()
	var budget := _match_budget(fname)
	var errors := []

	# 1) tris 预算
	if not budget.is_empty():
		if info.tris > budget[1]:
			errors.append("tris=%d 超出预算上限 %d (%s)" % [info.tris, budget[1], budget[2]])
	elif info.tris <= 0:
		errors.append("tris=0（无网格？）")

	# 2) 材质数 ≤2（美术方向铁律 3）
	if info.materials > 2:
		errors.append("材质数=%d 超过 2（铁律：最多 2 种材质）" % info.materials)

	# 3) 骨骼要求
	if _match_prefix(fname, NO_SKELETON_PREFIXES) and info.skeletons > 0:
		errors.append("普通丧尸应无骨骼（剥骨方案 B），检测到 Skeleton3D=%d" % info.skeletons)
	if _match_prefix(fname, MUST_SKELETON_PREFIXES) and info.skeletons == 0:
		errors.append("特感应带骨骼（§2.3），未检测到 Skeleton3D")

	# 4) 身高合理性（角色类，含丧尸/哥布林/玩家）
	if fname.begins_with("char_") and info.height > 0:
		if info.height < 1.2 or info.height > 2.6:
			errors.append("身高 %.2fm 异常（角色预期 1.2-2.6m，参考门 2.4m/人 1.8m）" % info.height)

	if errors.is_empty():
		_pass += 1
		print("PASS  ", path, "  tris=%d  mats=%d  height=%.2fm  skeleton=%d" % [info.tris, info.materials, info.height, info.skeletons])
	else:
		_fail += 1
		print("FAIL  ", path)
		for e in errors:
			print("        - ", e)

func _match_budget(fname: String) -> Array:
	for b in BUDGETS:
		if fname.begins_with(b[0]):
			return b[1]
	return []

func _match_prefix(fname: String, prefixes: Array) -> bool:
	for p in prefixes:
		if fname.begins_with(p):
			return true
	return false

func _analyze(root: Node3D) -> Dictionary:
	var info := {"tris": 0, "materials": 0, "skeletons": 0, "height": 0.0}
	var mats := {}
	var bbox := {"min": Vector3.INF, "max": Vector3(-INF, -INF, -INF)}
	_collect(root, info, bbox, Transform3D.IDENTITY, mats)
	if bbox.min.is_finite() and bbox.max.is_finite():
		info.height = bbox.max.y - bbox.min.y
	info.materials = mats.size()
	return info

func _collect(n: Node, info: Dictionary, bbox: Dictionary, acc: Transform3D, mats: Dictionary) -> void:
	var t := acc
	if n is Node3D:
		t = acc * (n as Node3D).transform
	if n is Skeleton3D:
		info.skeletons += 1
	if n is MeshInstance3D:
		var mi := n as MeshInstance3D
		if mi.mesh != null:
			var a := mi.mesh.get_aabb()
			var corners := [
				Vector3(a.position.x, a.position.y, a.position.z),
				Vector3(a.end.x, a.position.y, a.position.z),
				Vector3(a.position.x, a.end.y, a.position.z),
				Vector3(a.position.x, a.position.y, a.end.z),
				Vector3(a.end.x, a.end.y, a.position.z),
				Vector3(a.end.x, a.position.y, a.end.z),
				Vector3(a.position.x, a.end.y, a.end.z),
				Vector3(a.end.x, a.end.y, a.end.z),
			]
			for c in corners:
				var p: Vector3 = t * c
				bbox.min = bbox.min.min(p)
				bbox.max = bbox.max.max(p)
			for s in mi.mesh.get_surface_count():
				var arrays := mi.mesh.surface_get_arrays(s)
				if arrays and arrays.size() > 0 and arrays[ArrayMesh.ARRAY_INDEX] != null:
					info.tris += arrays[ArrayMesh.ARRAY_INDEX].size() / 3
				var mat := mi.mesh.surface_get_material(s)
				if mat != null:
					mats[mat.resource_path if mat.resource_path != "" else str(mat.get_instance_id())] = true
	for child in n.get_children():
		_collect(child, info, bbox, t, mats)
