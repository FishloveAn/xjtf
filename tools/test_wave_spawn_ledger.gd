extends SceneTree

const Ledger := preload("res://scripts/gameplay/wave_spawn_ledger.gd")

var _failed := 0


func _initialize() -> void:
	_run()


func _run() -> void:
	var ledger := Ledger.new()
	ledger.reset({"common": 2, "charger": 1})
	_check(ledger.total_count() == 3, "重置后按 composition 计算总配额")
	_check(ledger.spawned_count() == 0 and ledger.killed_count() == 0, "重置后生成与死亡计数清零")

	ledger.record_spawned("common")
	_check(not ledger.record_killed("common"), "未全部生成时不会提前清波")
	ledger.record_spawned("common")
	_check(not ledger.record_killed("common"), "仍有特感配额时不会提前清波")
	ledger.record_spawned("charger")
	_check(ledger.concurrent_count() == 1 and ledger.active_special_count() == 1, "特感生成计入同屏与特感计数")
	_check(ledger.record_killed("charger"), "全部生成并全部死亡后才清波")
	_check(ledger.concurrent_count() == 0 and ledger.active_special_count() == 0, "清波后运行计数归零")

	ledger.reset({"spitter": 1})
	_check(ledger.spawned_count() == 0 and ledger.killed_count() == 0, "连续波次重置不会串计数")

	ledger.reset({"common": 2, "charger": 1, "spitter": 1})
	_check(ledger.next_spawn_type(false, 1) == &"common", "Director 未放行特感时选择普通怪")
	ledger.record_spawned(&"common")
	ledger.record_spawned(&"common")
	_check(ledger.next_spawn_type(false, 1) == &"", "普通怪耗尽且特感未放行时等待")

	ledger.reset({"common": 1, "charger": 1, "spitter": 1})
	_check(ledger.next_spawn_type(true, 1) == &"charger", "特感放行时冲撞者优先")
	ledger.record_spawned(&"charger")
	_check(ledger.next_spawn_type(true, 1) == &"common", "达到特感上限时由普通怪补位")
	ledger.record_killed(&"charger")
	_check(ledger.next_spawn_type(true, 1) == &"spitter", "特感空位释放后选择喷吐者")
	_finish()


func _check(condition: bool, message: String) -> void:
	if condition:
		print("[PASS] %s" % message)
	else:
		_failed += 1
		push_error("[FAIL] %s" % message)


func _finish() -> void:
	print("[波次记账测试] %s" % ("PASS" if _failed == 0 else "%d FAIL" % _failed))
	quit(0 if _failed == 0 else 1)
