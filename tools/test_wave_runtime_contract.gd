extends SceneTree

const MAIN_SCENE := "res://scenes/main/main.tscn"
const SAVE_PATH := "user://save/test_wave_runtime_contract.json"
const LEVEL_WAIT := 5
const MAX_FRAMES := 2400

var _failed := 0
var _started_count := 0
var _begun_count := 0
var _cleared_count := 0
var _cleared_id := ""


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var game_state := root.get_node("GameState")
	var previous_save_path := String(game_state.get("checkpoint_path"))
	game_state.set("checkpoint_path", SAVE_PATH)
	_cleanup_save()
	var packed := load(MAIN_SCENE) as PackedScene
	var main := packed.instantiate()
	root.add_child(main)
	for _frame in 3:
		await process_frame

	var wave_manager := main.get_node("Gameplay/WaveManager")
	var zombies := main.get_node("Zombies")
	wave_manager.connect("event_wave_started", _on_wave_started)
	wave_manager.connect("event_wave_begun", _on_wave_begun)
	wave_manager.connect("event_level_wave_cleared", _on_wave_cleared)
	var config := {
		"id": "runtime_contract",
		"name": "运行时契约",
		"composition": {"common": 2},
		"concurrent_cap": 1,
		"spawn_style": "burst",
		"spawn_interval": 0.01,
		"reward": {"health_packs": 0, "ammo": 0},
	}
	_check(wave_manager.call("start_wave_config", config), "只通过公开接口启动测试波次")

	var first := await _wait_for_active_zombie(zombies)
	_check(first != null, "第一只普通怪按配额生成")
	_check(_alive_count(zombies) <= 1, "第一只生成时遵守并发上限 1")
	_damage_to_death(first)
	await _wait_until_no_alive(zombies)

	var second := await _wait_for_active_zombie(zombies)
	_check(second != null, "第一只死亡后第二只自动补位")
	_check(_alive_count(zombies) <= 1, "补位时仍遵守并发上限 1")
	_damage_to_death(second)
	await _wait_for_clear(wave_manager)

	_check(_started_count == 1, "波次预告事件只触发一次")
	_check(_begun_count == 1, "波次开始事件只触发一次")
	_check(_cleared_count == 1 and _cleared_id == "runtime_contract", "清波事件只触发一次且 ID 正确")
	_check(int(wave_manager.get("state")) == LEVEL_WAIT, "清波后回到 LEVEL_WAIT")

	main.queue_free()
	await process_frame
	await physics_frame
	await process_frame
	OS.delay_msec(1000)
	game_state.set("checkpoint_path", previous_save_path)
	_cleanup_save()
	print("[波次运行时契约] %s" % ("PASS" if _failed == 0 else "%d FAIL" % _failed))
	quit(0 if _failed == 0 else 1)


func _wait_for_active_zombie(zombies: Node) -> Node:
	for _frame in MAX_FRAMES:
		var active := _active_zombies(zombies)
		if not active.is_empty():
			return active[0]
		await process_frame
	return null


func _wait_until_no_alive(zombies: Node) -> void:
	for _frame in MAX_FRAMES:
		if _alive_count(zombies) == 0:
			return
		await process_frame


func _wait_for_clear(wave_manager: Node) -> void:
	for _frame in MAX_FRAMES:
		if _cleared_count > 0 and int(wave_manager.get("state")) == LEVEL_WAIT:
			return
		await process_frame


func _active_zombies(zombies: Node) -> Array[Node]:
	var active: Array[Node] = []
	for zombie in zombies.get_children():
		var health := zombie.get_node_or_null("Health")
		if health != null and float(health.get("hp")) > 0.0:
			active.append(zombie)
	return active


func _alive_count(zombies: Node) -> int:
	return _active_zombies(zombies).size()


func _damage_to_death(zombie: Node) -> void:
	var health := zombie.get_node_or_null("Health")
	if health != null:
		health.call("take_damage", 9999.0)


func _on_wave_started(_index: int, _name: String, _countdown: float) -> void:
	_started_count += 1


func _on_wave_begun(_index: int) -> void:
	_begun_count += 1


func _on_wave_cleared(wave_id: String) -> void:
	_cleared_count += 1
	_cleared_id = wave_id


func _check(condition: bool, message: String) -> void:
	if condition:
		print("[PASS] %s" % message)
	else:
		_failed += 1
		push_error("[FAIL] %s" % message)


func _cleanup_save() -> void:
	for suffix in ["", ".tmp", ".bak"]:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(SAVE_PATH + suffix))
