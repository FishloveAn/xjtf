extends SceneTree
## Rustyard 特感导航回归：隔墙时不得穿墙施法，绕到有效位置后保留原技能。
## 用法：godot --headless --path . --script tools/debug_special_navigation.gd

const MAIN_SCENE := "res://scenes/main/main.tscn"
const CHARGER_SCENE := "res://scenes/enemies/zombie_charger.tscn"
const SPITTER_SCENE := "res://scenes/enemies/zombie_spitter.tscn"
const PLAYER_POS := Vector3(-22.0, 0.0, -4.7)
const ENEMY_POS := Vector3(-10.0, 0.0, -4.7)

var _fail := 0


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	print("=== SPECIAL NAVIGATION TEST START ===")
	change_scene_to_file(MAIN_SCENE)
	await create_timer(1.0).timeout
	var main := current_scene
	var player := main.get_node_or_null("Players/1") as CharacterBody3D
	var zombies := main.get_node_or_null("Zombies")
	var wm := main.get_node_or_null("Gameplay/WaveManager")
	var door := main.get_node_or_null("World/Level/Rustyard/Walls/SafeDoor")
	_check(player != null and zombies != null and wm != null and door != null,
		"主场景玩家、特感容器、WaveManager、安全门就绪")
	if player == null or zombies == null or wm == null or door == null:
		_finish()
		return
	wm.set("_setup_timer", 999.0)
	player.set_physics_process(false)
	player.global_position = PLAYER_POS
	door.call("door_opened")
	await physics_frame
	await physics_frame

	await _test_charger(zombies, player)
	await _clear_specials(zombies)
	await _reset_player(player)
	await _test_spitter(zombies, player)
	await _clear_specials(zombies)
	_finish()


func _test_charger(zombies: Node, player: CharacterBody3D) -> void:
	print("--- 冲撞者：隔墙追路，取得直线后冲撞 ---")
	var charger := _spawn_special(CHARGER_SCENE, zombies, ENEMY_POS)
	_check(charger != null, "冲撞者生成在 SafeEastA 实墙另一侧")
	if charger == null:
		return
	var ai := charger.get_node_or_null("AI")
	_check(_sync_ready(charger), "冲撞者 SpecialSync 保持服务器权威位置/旋转复制")
	var saw_path_points := 0
	var entered_skill_while_blocked := false
	var saw_charge_after_clear := false
	var min_distance := charger.global_position.distance_to(player.global_position)
	var elapsed := 0.0
	while elapsed < 15.0 and is_instance_valid(charger):
		await physics_frame
		elapsed += 1.0 / float(Engine.physics_ticks_per_second)
		var agent := charger.get_node_or_null("NavigationAgent3D") as NavigationAgent3D
		if agent != null:
			saw_path_points = maxi(saw_path_points, agent.get_current_navigation_path().size())
		var blocked := not _has_world_line(charger, player)
		var state := int(ai.get("state"))
		if blocked and (state == 2 or state == 3):
			entered_skill_while_blocked = true
		if not blocked and state == 3:
			saw_charge_after_clear = true
		min_distance = minf(min_distance, charger.global_position.distance_to(player.global_position))
		if saw_charge_after_clear and int(player.get_node("Health").get("state")) != 0:
			break
	_check(saw_path_points > 2, "冲撞者取得复杂绕墙路径（路径点 > 2，实际=%d）" % saw_path_points)
	_check(not entered_skill_while_blocked, "冲撞者隔墙时不错误蓄力/冲撞")
	_check(saw_charge_after_clear, "冲撞者绕到视线位置后确实进入 CHARGE（非近战替代）")
	_check(int(player.get_node("Health").get("state")) != 0,
		"冲撞技能仍能命中并压制玩家（最近 %.2fm）" % min_distance)


func _test_spitter(zombies: Node, player: CharacterBody3D) -> void:
	print("--- 喷吐者：隔墙追路，取得视线后吐酸 ---")
	for pool in get_nodes_in_group("acid_pools"):
		pool.queue_free()
	await physics_frame
	var spitter := _spawn_special(SPITTER_SCENE, zombies, ENEMY_POS)
	_check(spitter != null, "喷吐者生成在 SafeEastA 实墙另一侧")
	if spitter == null:
		return
	var ai := spitter.get_node_or_null("AI")
	_check(_sync_ready(spitter), "喷吐者 SpecialSync 保持服务器权威位置/旋转复制")
	var saw_path_points := 0
	var entered_skill_while_blocked := false
	var saw_clear_line := false
	var saw_pool_after_clear := false
	var elapsed := 0.0
	while elapsed < 25.0 and is_instance_valid(spitter):
		await physics_frame
		elapsed += 1.0 / float(Engine.physics_ticks_per_second)
		var agent := spitter.get_node_or_null("NavigationAgent3D") as NavigationAgent3D
		if agent != null:
			saw_path_points = maxi(saw_path_points, agent.get_current_navigation_path().size())
		var blocked := not _has_world_line(spitter, player)
		if blocked and int(ai.get("state")) == 2:
			entered_skill_while_blocked = true
		if not blocked:
			saw_clear_line = true
		if saw_clear_line and not get_nodes_in_group("acid_pools").is_empty():
			saw_pool_after_clear = true
			break
	_check(saw_path_points > 2, "喷吐者取得复杂绕墙路径（路径点 > 2，实际=%d）" % saw_path_points)
	_check(not entered_skill_while_blocked, "喷吐者隔墙时不错误进入吐酸前摇")
	_check(saw_clear_line, "喷吐者绕墙取得对玩家的世界视线")
	_check(saw_pool_after_clear, "喷吐者取得视线后仍生成酸液区")


func _spawn_special(path: String, zombies: Node, pos: Vector3) -> CharacterBody3D:
	var packed := load(path) as PackedScene
	if packed == null:
		return null
	var enemy := packed.instantiate() as CharacterBody3D
	enemy.set_multiplayer_authority(1)
	zombies.add_child(enemy, true)
	enemy.global_position = pos
	return enemy


func _has_world_line(enemy: CharacterBody3D, player: CharacterBody3D) -> bool:
	var from := enemy.global_position + Vector3.UP * 0.8
	var to := player.global_position + Vector3.UP * 0.8
	var query := PhysicsRayQueryParameters3D.create(from, to, 1, [enemy.get_rid()])
	var hit := enemy.get_world_3d().direct_space_state.intersect_ray(query)
	if hit.is_empty():
		return true
	var collider := hit.get("collider") as Node
	return collider == player or (collider != null and player.is_ancestor_of(collider))


func _sync_ready(enemy: CharacterBody3D) -> bool:
	var sync := enemy.get_node_or_null("SpecialSync") as MultiplayerSynchronizer
	return sync != null and sync.get_multiplayer_authority() == 1 \
		and sync.replication_config != null and is_equal_approx(sync.replication_interval, 0.05)


func _reset_player(player: CharacterBody3D) -> void:
	var health := player.get_node("Health")
	health.set("state", 0)
	health.set("hp", health.get("max_hp"))
	player.global_position = PLAYER_POS
	await physics_frame


func _clear_specials(zombies: Node) -> void:
	for child in zombies.get_children():
		if child.get_node_or_null("AI") != null:
			child.queue_free()
	await physics_frame


func _check(condition: bool, label: String) -> void:
	if condition:
		print("  [PASS] " + label)
	else:
		_fail += 1
		print("  [FAIL] " + label)


func _finish() -> void:
	print("=== SPECIAL NAVIGATION TEST %s (fail=%d) ===" % ["PASS" if _fail == 0 else "FAIL", _fail])
	change_scene_to_file("res://scenes/ui/main_menu.tscn")
	await create_timer(0.5).timeout
	quit(_fail)
