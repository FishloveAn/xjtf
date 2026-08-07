extends SceneTree

const MAIN_SCENE := "res://scenes/main/main.tscn"

var _failed := 0


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var packed := load(MAIN_SCENE) as PackedScene
	var main := packed.instantiate()
	root.add_child(main)
	for _frame in 3:
		await process_frame

	var wave_manager := main.get_node("Gameplay/WaveManager")
	_check(int(wave_manager.get("state")) == 5, "主场景波次目录加载完成")
	if not wave_manager.has_method("get_wave_config"):
		_check(false, "WaveManager 提供统一波次查询接口")
		main.queue_free()
		await process_frame
		quit(1)
		return

	var arena_wave: Dictionary = wave_manager.call("get_wave_config", "wave_01")
	_check(String(arena_wave.get("name", "")) == "试探", "统一接口可查询竞技场波次")
	_check(int(arena_wave.get("composition", {}).get("common", 0)) == 20, "竞技场波次配额保持不变")

	var level_wave: Dictionary = wave_manager.call("get_wave_config", "level_harass")
	_check(String(level_wave.get("name", "")) == "小骚扰", "统一接口可查询推进波次")
	_check(int(level_wave.get("composition", {}).get("common", 0)) == 8, "推进波次配额保持不变")

	level_wave["composition"]["common"] = 999
	var fresh_wave: Dictionary = wave_manager.call("get_wave_config", "level_harass")
	_check(int(fresh_wave.get("composition", {}).get("common", 0)) == 8, "查询结果为深拷贝，不污染目录")
	_check(wave_manager.call("get_level_wave_config", "level_harass") == fresh_wave, "旧推进查询接口保持兼容")
	var missing_wave: Dictionary = wave_manager.call("get_wave_config", "missing_wave")
	_check(missing_wave.is_empty(), "未知波次返回空配置")

	main.queue_free()
	await process_frame
	print("[波次目录测试] %s" % ("PASS" if _failed == 0 else "%d FAIL" % _failed))
	quit(0 if _failed == 0 else 1)


func _check(condition: bool, message: String) -> void:
	if condition:
		print("[PASS] %s" % message)
	else:
		_failed += 1
		push_error("[FAIL] %s" % message)
