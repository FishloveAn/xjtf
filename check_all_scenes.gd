extends SceneTree

# 临时诊断脚本：实例化 res:// 下所有 .tscn 场景（跳过 UI 主菜单会阻塞捕获的场景），收集任何运行时错误。
# 用法：godot --headless --path <project> --script check_all_scenes.gd
# 输出：每个失败场景一行；全部通过则打印 CHECK_ALL_SCENES_OK

var _errors: Array[String] = []

func _initialize() -> void:
	call_deferred("_run_check")


func _run_check() -> void:
	_scan("res://scenes")
	if _errors.is_empty():
		print("CHECK_ALL_SCENES_OK")
	else:
		print("CHECK_ALL_SCENES_FAILED (%d)" % _errors.size())
		for e in _errors:
			print("  FAIL: ", e)
	quit(_errors.size())


func _scan(dir_path: String) -> void:
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return
	dir.list_dir_begin()
	var fname := dir.get_next()
	while fname != "":
		if dir.current_is_dir() and not fname.begins_with("."):
			_scan(dir_path.path_join(fname))
		elif fname.ends_with(".tscn"):
			var full := dir_path.path_join(fname)
			_try_instantiate(full)
		fname = dir.get_next()
	dir.list_dir_end()


func _try_instantiate(scene_path: String) -> void:
	var packed := load(scene_path) as PackedScene
	if packed == null:
		_errors.append("%s (load returned null)" % scene_path)
		return
	var inst := packed.instantiate()
	if inst == null:
		_errors.append("%s (instantiate returned null)" % scene_path)
		return
	# 加入场景树以触发 _ready/_enter_tree（网络类节点用 authority 处理）
	root.add_child(inst)
	# 立即摘除，避免跨场景副作用
	root.remove_child(inst)
	inst.queue_free()
