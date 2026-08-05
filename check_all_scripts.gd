extends SceneTree

# 临时诊断脚本：递归加载 res:// 下所有 .gd 脚本，收集任何 Parse Error / 加载失败。
# 用法：godot --headless --path <project> --script check_all_scripts.gd
# 输出：每个失败脚本一行；全部通过则打印 CHECK_ALL_SCRIPTS_OK
# 注意：必须等 autoload（NetworkManager/SfxPool）注册后再扫描，否则误报 Identifier not found。

var _errors: Array[String] = []

func _initialize() -> void:
	# SceneTree._initialize 在 autoload 注册后、主循环开始前调用
	call_deferred("_run_check")


func _run_check() -> void:
	_scan("res://")
	if _errors.is_empty():
		print("CHECK_ALL_SCRIPTS_OK")
	else:
		print("CHECK_ALL_SCRIPTS_FAILED (%d)" % _errors.size())
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
			if fname != ".godot":
				_scan(dir_path.path_join(fname))
		elif fname.ends_with(".gd"):
			var full := dir_path.path_join(fname)
			var res := load(full)
			if res == null:
				_errors.append("%s (load returned null)" % full)
		fname = dir.get_next()
	dir.list_dir_end()
