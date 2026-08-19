extends SceneTree
## Rustyard 预烘焙导航验收：门洞连通、复杂墙绕行、对象池复用后重建路径。
## 用法：godot --headless --path . --script tools/debug_rustyard_navigation.gd

const MAIN_SCENE := "res://scenes/main/main.tscn"
const ATTACK_DISTANCE := 2.2

var _fail := 0


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	print("=== RUSTYARD NAVIGATION TEST START ===")
	change_scene_to_file(MAIN_SCENE)
	await create_timer(1.0).timeout
	var main := current_scene
	var player := main.get_node_or_null("Players/1") as CharacterBody3D
	var pool := main.get_node_or_null("Gameplay/WaveManager/ZombiePool")
	var door := main.get_node_or_null("World/Level/Rustyard/Walls/SafeDoor")
	var region := main.get_node_or_null("World/Level/Rustyard/NavigationRegion3D") as NavigationRegion3D
	_check(player != null and pool != null and door != null, "主场景玩家、对象池、安全门就绪")
	_check(region != null and region.navigation_mesh != null, "Rustyard 已挂载预烘焙 NavigationRegion3D")
	if player == null or pool == null or door == null:
		_finish()
		return
	player.set_physics_process(false)
	door.call("door_opened")
	await physics_frame
	await physics_frame
	var map_rid: RID = main.get_world_3d().navigation_map
	var server_path := NavigationServer3D.map_get_path(
		map_rid, Vector3(-22.0, 0.0, 0.0), Vector3(-10.0, 0.0, 0.0), true)
	_check(server_path.size() > 1, "NavigationServer 可查询安全屋到货场路径")
	_check(_path_crosses_door(server_path), "NavigationServer 路径穿过已开启门洞")
	var warehouse_sw_path := NavigationServer3D.map_get_path(
		map_rid, Vector3(-8.0, 0.0, 7.0), Vector3(-14.0, 0.0, 7.0), true)
	_check(warehouse_sw_path.size() > 1, "西南仓库入口到低平台可达")
	var warehouse_ne_path := NavigationServer3D.map_get_path(
		map_rid, Vector3(-1.0, 0.0, -11.0), Vector3(5.0, 0.0, -11.0), true)
	_check(warehouse_ne_path.size() > 1, "东北仓库入口到低平台可达")
	var cover_path := NavigationServer3D.map_get_path(
		map_rid, Vector3(-8.0, 0.0, -4.0), Vector3(-2.0, 0.0, -4.0), true)
	_check(cover_path.size() > 2 and _path_avoids_point(cover_path, Vector2(-5.0, -4.0), 0.55),
		"货场战术路障参与导航烘焙并产生绕行")

	# 第一轮走已开启的安全门。若 SafeDoor 被烘进导航源，这里不会产生穿门路径。
	player.global_position = Vector3(-10.0, 0.0, 0.0)
	var zombie := pool.call("spawn_from_pool", Vector3(-22.0, 0.0, 0.0)) as CharacterBody3D
	_check(zombie != null, "第一轮普通怪从对象池出池")
	if zombie == null:
		_finish()
		return
	var door_result := await _wait_for_navigation(zombie, player, 8.0)
	_check(int(door_result["path_points"]) > 1, "开门后生成有效路径（路径点 > 1）")
	_check(bool(door_result["crosses_door"]), "导航路径穿过安全门洞（SafeDoor 未烘进静态导航源）")
	_check(float(door_result["min_distance"]) <= ATTACK_DISTANCE,
		"开门后普通怪进入攻击范围（最近 %.2fm）" % float(door_result["min_distance"]))

	# 归池再出池，用 SafeEastA 实墙两侧验证旧 agent 不沿用上一轮路径且能绕过复杂障碍。
	pool.call("despawn_to_pool", zombie)
	player.global_position = Vector3(-22.0, 0.0, -4.7)
	var reused := pool.call("spawn_from_pool", Vector3(-10.0, 0.0, -4.7)) as CharacterBody3D
	_check(reused == zombie, "对象池复用同一普通怪实例")
	var wall_result := await _wait_for_navigation(reused, player, 12.0)
	_check(int(wall_result["path_points"]) > 2, "复用后重建复杂绕墙路径（路径点 > 2）")
	_check(float(wall_result["min_distance"]) <= ATTACK_DISTANCE,
		"复用后绕过 SafeEastA 实墙并进入攻击范围（最近 %.2fm）" % float(wall_result["min_distance"]))

	pool.call("despawn_to_pool", reused)
	_finish()


func _wait_for_navigation(zombie: CharacterBody3D, player: CharacterBody3D, timeout: float) -> Dictionary:
	var agent: NavigationAgent3D = null
	var max_path_points := 0
	var crosses_door := false
	var min_distance := zombie.global_position.distance_to(player.global_position)
	var elapsed := 0.0
	while elapsed < timeout:
		await physics_frame
		elapsed += 1.0 / float(Engine.physics_ticks_per_second)
		if agent == null:
			agent = zombie.get_node_or_null("NavigationAgent3D") as NavigationAgent3D
		if agent != null:
			var path := agent.get_current_navigation_path()
			max_path_points = maxi(max_path_points, path.size())
			for point in path:
				if absf(point.x + 16.0) < 0.8 and absf(point.z) < 1.4:
					crosses_door = true
		min_distance = minf(min_distance, zombie.global_position.distance_to(player.global_position))
		if min_distance <= ATTACK_DISTANCE:
			break
	return {"path_points": max_path_points, "crosses_door": crosses_door, "min_distance": min_distance}


func _path_crosses_door(path: PackedVector3Array) -> bool:
	for point in path:
		if absf(point.x + 16.0) < 0.8 and absf(point.z) < 1.4:
			return true
	return false


func _path_avoids_point(path: PackedVector3Array, point: Vector2, clearance: float) -> bool:
	for index in range(path.size() - 1):
		var start := Vector2(path[index].x, path[index].z)
		var end := Vector2(path[index + 1].x, path[index + 1].z)
		var segment := end - start
		var length_squared := segment.length_squared()
		var ratio := 0.0 if is_zero_approx(length_squared) else clampf(
			(point - start).dot(segment) / length_squared, 0.0, 1.0)
		if point.distance_to(start + segment * ratio) < clearance:
			return false
	return true


func _check(condition: bool, label: String) -> void:
	if condition:
		print("  [PASS] " + label)
	else:
		_fail += 1
		print("  [FAIL] " + label)


func _finish() -> void:
	print("=== RUSTYARD NAVIGATION TEST %s (fail=%d) ===" % ["PASS" if _fail == 0 else "FAIL", _fail])
	change_scene_to_file("res://scenes/ui/main_menu.tscn")
	await create_timer(0.5).timeout
	quit(_fail)
