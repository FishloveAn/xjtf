extends SceneTree

const Checkpoints := preload("res://scripts/gameplay/checkpoint_manager.gd")
const TEST_PATH := "user://save/test_checkpoint_resume.json"

var _failures := 0
var _finished := false


func _init() -> void:
	create_timer(20.0).timeout.connect(_on_test_timeout)
	_run.call_deferred()


func _run() -> void:
	_cleanup_test_saves()
	_test_round_trip_keeps_resume_state()
	_test_corrupt_main_recovers_latest_valid_backup()
	_test_invalid_schema_is_not_resumeable()
	_test_version_one_completed_save_migrates_to_complete()
	_test_version_two_save_migrates_without_losing_equipment()
	await _test_capture_equipment_from_player()
	await _test_apply_magazines_to_recreated_player()
	_test_checkpoint_is_consumed_once_by_host()
	await _test_new_main_scene_restores_checkpoint()
	await _test_new_game_ignores_existing_checkpoint()
	await _test_trigger_boundaries_write_midgame_checkpoint()
	await _test_completed_checkpoint_resumes_in_backdoor_rest_area()
	_test_menu_distinguishes_new_game_and_continue()
	_cleanup_test_saves()
	if _failures == 0:
		_finished = true
		print("[存档测试] 1 PASS / 0 FAIL")
		quit(0)
	else:
		_finished = true
		printerr("[存档测试] FAIL=%d" % _failures)
		quit(1)


func _on_test_timeout() -> void:
	if not _finished:
		printerr("[存档测试] 测试异常中断或超时")
		quit(2)


func _test_round_trip_keeps_resume_state() -> void:
	var equipment := {
		"active_weapon": "rifle",
		"magazines": {"pistol": 3, "shotgun": 5, "rifle": 17, "smg": 21},
	}
	var player_state := {
		"position": [-8.5, 0.0, 12.25], "rotation_y": 1.25,
		"hp": 63.0, "state": 0,
	}
	var level_flags := {
		"horde_triggered": true, "horde_cleared": false, "holdout_triggered": false,
		"holdout_cleared": false, "harass_done": true,
	}
	var saved: Dictionary = Checkpoints.save_progress(
		1, 42.75, 9, equipment, 3, TEST_PATH, player_state, level_flags
	)
	var loaded: Dictionary = Checkpoints.load_progress(TEST_PATH)
	_expect(saved.get("version") == 3, "新存档使用 version=3")
	_expect(loaded.get("level_phase") == 3, "重新读取后保留关卡阶段")
	var loaded_equipment: Dictionary = loaded.get("equipment", {})
	var magazines: Dictionary = loaded_equipment.get("magazines", {})
	_expect(loaded_equipment.get("active_weapon") == "rifle", "重新读取后保留激活武器")
	_expect(int(magazines.get("pistol", -1)) == 3, "重新读取后保留手枪弹匣")
	_expect(int(magazines.get("rifle", -1)) == 17, "重新读取后保留步枪弹匣")
	_expect(loaded.get("player_state", {}).get("position") == player_state.position,
		"重新读取后保留玩家位置")
	_expect(float(loaded.get("player_state", {}).get("hp", -1.0)) == 63.0,
		"重新读取后保留玩家生命")
	_expect(loaded.get("level_flags", {}).get("horde_triggered", false),
		"重新读取后保留阶段触发标志")


func _test_invalid_schema_is_not_resumeable() -> void:
	_cleanup_test_saves()
	var file := FileAccess.open(TEST_PATH, FileAccess.WRITE)
	file.store_string('{"segment": 1, "completed": true}')
	file.close()
	var loaded: Dictionary = Checkpoints.load_progress(TEST_PATH)
	_expect(int(loaded.get("segment", -1)) == 0, "结构损坏时回退到未完成进度")
	_expect(not Checkpoints.has_progress(TEST_PATH), "结构损坏时不显示可续玩")


func _test_corrupt_main_recovers_latest_valid_backup() -> void:
	var original := Checkpoints.load_progress(TEST_PATH)
	Checkpoints.save_progress(1, 50.0, 10, original.get("equipment", {}), 4, TEST_PATH, {
		"position": [-4.0, 0.0, 18.0], "rotation_y": 0.0, "hp": 80.0, "state": 0,
	}, {
		"horde_triggered": true, "horde_cleared": true, "holdout_triggered": true,
		"holdout_cleared": false, "harass_done": true,
	})
	var file := FileAccess.open(TEST_PATH, FileAccess.WRITE)
	file.store_string("{broken")
	file.close()
	var recovered := Checkpoints.load_progress(TEST_PATH)
	_expect(float(recovered.get("player_state", {}).get("hp", -1.0)) == 63.0,
		"主档损坏时恢复最近有效备份")
	_expect(int(recovered.get("level_phase", -1)) == 3,
		"备份保留上一次完整阶段，不读取半写状态")


func _test_version_one_completed_save_migrates_to_complete() -> void:
	var file := FileAccess.open(TEST_PATH, FileAccess.WRITE)
	file.store_string(JSON.stringify({
		"version": 1, "segment": 1, "completed": true,
		"finish_time_s": 12.5, "best_score": 3, "saved_at": "legacy",
	}))
	file.close()
	var migrated: Dictionary = Checkpoints.load_progress(TEST_PATH)
	_expect(int(migrated.get("version", 0)) == 3, "旧存档迁移到 version=3")
	_expect(int(migrated.get("level_phase", -1)) == 5, "旧已完成存档迁移为 COMPLETE 阶段")
	_expect(migrated.get("equipment", {}).is_empty(), "旧存档缺少装备时使用默认装备")


func _test_version_two_save_migrates_without_losing_equipment() -> void:
	_cleanup_test_saves()
	var file := FileAccess.open(TEST_PATH, FileAccess.WRITE)
	file.store_string(JSON.stringify({
		"version": 2, "segment": 1, "completed": false, "level_phase": 2,
		"finish_time_s": 18.0, "best_score": 4, "saved_at": "v2",
		"equipment": {"active_weapon": "rifle", "magazines": {"rifle": 6}},
	}))
	file.close()
	var migrated := Checkpoints.load_progress(TEST_PATH)
	_expect(int(migrated.get("version", 0)) == 3, "version=2 存档迁移到 version=3")
	_expect(migrated.get("equipment", {}).get("active_weapon") == "rifle",
		"version=2 迁移保留装备")
	_expect(migrated.get("player_state", {}).is_empty(), "version=2 缺少玩家状态时使用安全默认")


func _test_capture_equipment_from_player() -> void:
	var player_scene := load("res://scenes/player/player.tscn") as PackedScene
	var player := player_scene.instantiate()
	root.add_child(player)
	await process_frame
	var pivot := player.get_node("WeaponPivot")
	for weapon in pivot.get_children():
		weapon.mag_current = 7 if weapon.weapon_id == "rifle" else 2
		weapon.visible = weapon.weapon_id == "rifle"
	var equipment: Dictionary = Checkpoints.capture_equipment(player)
	_expect(equipment.get("active_weapon") == "rifle", "采集真实玩家当前武器")
	_expect(int(equipment.get("magazines", {}).get("rifle", -1)) == 7, "采集真实玩家步枪弹匣")
	player.queue_free()
	await process_frame


func _test_apply_magazines_to_recreated_player() -> void:
	var player_scene := load("res://scenes/player/player.tscn") as PackedScene
	var player := player_scene.instantiate()
	root.add_child(player)
	await process_frame
	var applied: bool = Checkpoints.apply_equipment(player, {
		"active_weapon": "rifle",
		"magazines": {"pistol": 4, "shotgun": 999, "rifle": 11, "smg": 23},
	})
	var actual := {}
	var capacities := {}
	for weapon in player.get_node("WeaponPivot").get_children():
		actual[weapon.weapon_id] = weapon.mag_current
		capacities[weapon.weapon_id] = weapon.mag_size
	_expect(applied, "装备快照成功应用到重建玩家")
	_expect(int(actual.get("pistol", -1)) == 4, "恢复手枪剩余弹药")
	_expect(int(actual.get("rifle", -1)) == 11, "恢复步枪剩余弹药")
	_expect(actual.get("shotgun") == capacities.get("shotgun"), "异常弹药按弹匣容量裁剪")
	var active_weapon := ""
	for weapon in player.get_node("WeaponPivot").get_children():
		if weapon.visible:
			active_weapon = weapon.weapon_id
	_expect(active_weapon == "rifle", "恢复当前激活武器")
	player.queue_free()
	await process_frame


func _test_checkpoint_is_consumed_once_by_host() -> void:
	var game_state := root.get_node("GameState")
	var progress := {
		"version": 2, "segment": 1, "completed": true, "level_phase": 5,
		"finish_time_s": 20.0, "best_score": 4, "saved_at": "test",
		"equipment": {"active_weapon": "smg", "magazines": {"smg": 13}},
	}
	game_state.prepare_checkpoint_resume(progress)
	var host_resume: Dictionary = game_state.take_checkpoint_resume(1)
	var host_second_take: Dictionary = game_state.take_checkpoint_resume(1)
	game_state.prepare_checkpoint_resume(progress)
	var late_client_take: Dictionary = game_state.take_checkpoint_resume(2)
	var host_after_client: Dictionary = game_state.take_checkpoint_resume(1)
	_expect(host_resume.get("equipment", {}).get("active_weapon") == "smg", "主机取得本会话检查点")
	_expect(host_second_take.is_empty(), "主机不能重复消费检查点")
	_expect(late_client_take.is_empty(), "后加入客户端不消费主机检查点")
	_expect(not host_after_client.is_empty(), "客户端拒绝不会误删主机检查点")


func _test_new_main_scene_restores_checkpoint() -> void:
	var game_state := root.get_node("GameState")
	var peer := ENetMultiplayerPeer.new()
	_expect(peer.create_server(0, 1) == OK, "续玩集成测试启动隔离主机")
	root.get_node("NetworkManager").multiplayer.multiplayer_peer = peer
	Checkpoints.save_progress(1, 33.0, 8, {
		"active_weapon": "smg",
		"magazines": {"pistol": 2, "shotgun": 3, "rifle": 4, "smg": 9},
	}, 3, TEST_PATH, {
		"position": [-20.0, 0.0, -0.6], "rotation_y": 0.5, "hp": 61.0, "state": 0,
	}, {
		"horde_triggered": true, "horde_cleared": true, "holdout_triggered": true,
		"holdout_cleared": false, "harass_done": false,
	})
	game_state.checkpoint_path = TEST_PATH
	game_state.request_checkpoint_resume(true)
	var main_scene := load("res://scenes/main/main.tscn") as PackedScene
	var main := main_scene.instantiate()
	root.add_child(main)
	await create_timer(0.7).timeout
	await process_frame
	var players := get_nodes_in_group("players")
	var player: Node = players[0] if not players.is_empty() else null
	var active_weapon := ""
	var smg_ammo := -1
	if player != null:
		for weapon in player.get_node("WeaponPivot").get_children():
			if weapon.visible:
				active_weapon = weapon.weapon_id
			if weapon.weapon_id == "smg":
				smg_ammo = weapon.mag_current
	var level := main.get_node("Gameplay/LevelAdvance")
	_expect(active_weapon == "smg", "重建主场景自动恢复激活武器")
	_expect(smg_ammo == 9, "重建主场景自动恢复剩余弹药")
	_expect(int(level.phase) == 3, "重建主场景自动恢复中途关卡阶段")
	_expect(player != null and player.global_position.distance_to(Vector3(-20.0, 0.0, -0.6)) < 0.75,
		"重建主场景恢复可行走位置")
	_expect(player != null and absf(float(player.get_node("Health").hp) - 61.0) < 0.1,
		"重建主场景恢复玩家生命")
	var restored_position: Vector3 = player.global_position
	_expect(not Checkpoints.apply_player_state(player, {
		"position": [9999.0, 9999.0, 9999.0], "rotation_y": 0.0, "hp": 10.0, "state": 0,
	}), "拒绝恢复到导航网格外的不安全位置")
	_expect(player.global_position.is_equal_approx(restored_position), "不安全位置被拒绝后保留当前可行走点")
	var wave_manager = main.get_node("Gameplay/WaveManager")
	_expect(int(wave_manager.state) != 5, "恢复未清守点阶段时从干净世界重启必要波次")
	main.queue_free()
	await process_frame
	root.get_node("NetworkManager").disconnect_from_server()
	game_state.checkpoint_path = Checkpoints.SAVE_PATH


func _test_new_game_ignores_existing_checkpoint() -> void:
	var game_state := root.get_node("GameState")
	var peer := ENetMultiplayerPeer.new()
	_expect(peer.create_server(0, 1) == OK, "新游戏隔离测试启动主机")
	root.get_node("NetworkManager").multiplayer.multiplayer_peer = peer
	game_state.checkpoint_path = TEST_PATH
	game_state.request_checkpoint_resume(false)
	var main_scene := load("res://scenes/main/main.tscn") as PackedScene
	var main := main_scene.instantiate()
	root.add_child(main)
	await create_timer(0.7).timeout
	var level := main.get_node("Gameplay/LevelAdvance")
	var player: Node = get_nodes_in_group("players")[0]
	var active_weapon := ""
	for weapon in player.get_node("WeaponPivot").get_children():
		if weapon.visible:
			active_weapon = weapon.weapon_id
	_expect(int(level.phase) == 0, "普通新游戏忽略已有存档阶段")
	_expect(active_weapon == "pistol", "普通新游戏使用默认武器")
	main.queue_free()
	await process_frame
	root.get_node("NetworkManager").disconnect_from_server()
	game_state.checkpoint_path = Checkpoints.SAVE_PATH


func _test_trigger_boundaries_write_midgame_checkpoint() -> void:
	_cleanup_test_saves()
	var game_state := root.get_node("GameState")
	var peer := ENetMultiplayerPeer.new()
	_expect(peer.create_server(0, 1) == OK, "阶段边界测试启动隔离主机")
	root.get_node("NetworkManager").multiplayer.multiplayer_peer = peer
	game_state.checkpoint_path = TEST_PATH
	game_state.request_checkpoint_resume(false)
	var main := (load("res://scenes/main/main.tscn") as PackedScene).instantiate()
	root.add_child(main)
	await create_timer(0.7).timeout
	var player: Node3D = get_nodes_in_group("players")[0]
	player.global_position = Vector3(-16.3, 0.0, 0.0)
	await create_timer(0.1).timeout
	var yard := Checkpoints.load_progress(TEST_PATH)
	_expect(int(yard.get("level_phase", -1)) == 1,
		"进入货场稳定边界自动写入中途存档（actual=%s）" % yard.get("level_phase", -1))
	player.global_position = Vector3(7.0, 0.0, 0.0)
	await create_timer(0.1).timeout
	var corridor := Checkpoints.load_progress(TEST_PATH)
	_expect(int(corridor.get("level_phase", -1)) == 2, "进入通道稳定边界更新中途存档")
	_expect(not bool(corridor.get("completed", true)), "中途存档不会伪装为已完成段落")
	main.queue_free()
	await process_frame
	root.get_node("NetworkManager").disconnect_from_server()
	game_state.checkpoint_path = Checkpoints.SAVE_PATH


func _test_completed_checkpoint_resumes_in_backdoor_rest_area() -> void:
	_cleanup_test_saves()
	var game_state := root.get_node("GameState")
	var peer := ENetMultiplayerPeer.new()
	_expect(peer.create_server(0, 1) == OK, "完成档测试启动隔离主机")
	root.get_node("NetworkManager").multiplayer.multiplayer_peer = peer
	Checkpoints.save_progress(1, 88.0, 12, {
		"active_weapon": "rifle", "magazines": {"rifle": 8},
	}, 4, TEST_PATH, {
		"position": [35.0, 0.0, 0.0], "rotation_y": 0.0, "hp": 100.0, "state": 0,
	}, {
		"horde_triggered": true, "horde_cleared": true,
		"holdout_triggered": true, "holdout_cleared": true, "harass_done": true,
	}, true)
	game_state.checkpoint_path = TEST_PATH
	game_state.request_checkpoint_resume(true)
	var main := (load("res://scenes/main/main.tscn") as PackedScene).instantiate()
	root.add_child(main)
	var level = main.get_node("Gameplay/LevelAdvance")
	var completed_signals := [0]
	level.event_level_complete.connect(func(_segment: int): completed_signals[0] += 1)
	await create_timer(0.8).timeout
	var players := get_nodes_in_group("players")
	var player: Node3D = players[0] if not players.is_empty() else null
	_expect(int(level.phase) == 4, "完成档恢复到可活动的后门休整区而非 COMPLETE 软锁")
	_expect(completed_signals[0] == 1, "后门休整恢复仍显示段落完成结算")
	var before := player.global_position if player != null else Vector3.ZERO
	Input.action_press("move_forward")
	await create_timer(0.2).timeout
	Input.action_release("move_forward")
	_expect(player != null and player.global_position.distance_to(before) > 0.1,
		"完成档恢复后玩家仍可移动")
	main.queue_free()
	await process_frame
	root.get_node("NetworkManager").disconnect_from_server()
	game_state.checkpoint_path = Checkpoints.SAVE_PATH


func _test_menu_distinguishes_new_game_and_continue() -> void:
	Checkpoints.save_progress(1, 10.0, 0, {
		"active_weapon": "pistol", "magazines": {"pistol": 6},
	}, 5, TEST_PATH)
	var menu_scene := load("res://scenes/ui/main_menu.tscn") as PackedScene
	var menu := menu_scene.instantiate()
	menu.checkpoint_path = TEST_PATH
	root.add_child(menu)
	var continue_button: Button = menu.get_node("CenterContainer/VBoxContainer/ContinueButton")
	var port_edit: LineEdit = menu.get_node("CenterContainer/VBoxContainer/PortEdit")
	var game_state := root.get_node("GameState")
	_expect(continue_button.visible and not continue_button.disabled, "有效存档时显示并启用继续按钮")
	port_edit.text = "0"
	continue_button.pressed.emit()
	_expect(game_state.is_checkpoint_resume_requested(), "继续建房成功时请求恢复")
	root.get_node("NetworkManager").disconnect_from_server()
	game_state.request_checkpoint_resume(true)
	port_edit.text = "99999"
	continue_button.pressed.emit()
	_expect(not game_state.is_checkpoint_resume_requested(), "继续建房失败时清除恢复请求")
	port_edit.text = "0"
	menu.get_node("CenterContainer/VBoxContainer/HostButton").pressed.emit()
	_expect(not game_state.is_checkpoint_resume_requested(), "普通建房明确保持新游戏")
	root.get_node("NetworkManager").disconnect_from_server()
	menu.queue_free()


func _expect(condition: bool, message: String) -> void:
	if condition:
		print("[PASS] %s" % message)
	else:
		_failures += 1
		printerr("[FAIL] %s" % message)


func _cleanup_test_saves() -> void:
	for suffix in ["", ".tmp", ".bak"]:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(TEST_PATH + suffix))
