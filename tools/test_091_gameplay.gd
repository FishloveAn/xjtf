extends SceneTree
## 0.9.1 垂直回归：初始装备、武器架、投掷物、固定区域刷怪与动态并发。

var _failures := 0


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	change_scene_to_file("res://scenes/main/main.tscn")
	await create_timer(1.0).timeout
	var main := current_scene
	var player := main.get_node("Players").get_child(0)
	_check(String(player.get("primary_weapon_id")).is_empty(), "玩家出生时主武器槽为空")
	_check(_active_weapon_id(player) == "pistol", "玩家出生时只激活手枪")

	var stand := main.get_node("World/Pickups/WeaponStandRifle")
	player.global_position = stand.global_position
	stand.call("request_pickup")
	_check(String(player.get("primary_weapon_id")) == "rifle", "地图武器架装备步枪")
	_check(_active_weapon_id(player) == "rifle", "新主武器自动替换并激活")
	_check((player.get("claimed_weapon_stands") as Array).has("rifle"), "武器架领取状态按玩家记录")

	var grenade_supply := main.get_node("World/Pickups/GrenadeSupply")
	player.global_position = grenade_supply.global_position
	grenade_supply.call("request_pickup")
	_check(int(player.get("grenade_count")) == 1, "固定补给发放一枚手雷")

	var wm := main.get_node("Gameplay/WaveManager")
	await _verify_spawn_zones(wm)
	_verify_dynamic_cap(wm.get("_director"))
	await _verify_aoe(main, wm)

	print("[0.9.1 玩法回归] %s" % ("PASS" if _failures == 0 else "%d FAIL" % _failures))
	change_scene_to_file("res://scenes/ui/main_menu.tscn")
	await process_frame
	quit(_failures)


func _verify_spawn_zones(wm: Node) -> void:
	wm.set("spawn_point_group", "horde_spawn_point")
	for wave_id in ["level_harass", "level_horde_01", "level_holdout"]:
		var config: Dictionary = wm.call("get_level_wave_config", wave_id)
		if config.is_empty():
			continue
		wm.set("_current_wave", config)
		var zone := String(config.get("spawn_zone", ""))
		var position: Vector3 = wm.call("_random_spawn_position")
		var exact_marker := false
		for marker in get_nodes_in_group("horde_spawn_point"):
			if String(marker.get_meta("spawn_zone", "")) == zone and position.is_equal_approx(marker.global_position):
				exact_marker = true
				break
		_check(exact_marker and position != Vector3.ZERO, "%s 波次严格使用 %s 固定刷怪点" % [wave_id, zone])
	await process_frame


func _verify_dynamic_cap(director: Node) -> void:
	director.set("_adaptive_cap", 60)
	director.set("_frame_samples", PackedFloat32Array())
	director.set("_sample_elapsed", 0.0)
	for i in 70:
		director.call("_sample_frame_time", 0.03)
	_check(int(director.get("_adaptive_cap")) == 55, "持续超预算时动态并发每次下降 5")
	director.set("_frame_samples", PackedFloat32Array())
	director.set("_sample_elapsed", 0.0)
	for i in 650:
		director.call("_sample_frame_time", 0.01)
	_check(int(director.get("_adaptive_cap")) == 60, "稳定恢复后动态并发回升且不超过 60")


func _verify_aoe(main: Node, wm: Node) -> void:
	var pool: Node = wm.get("_pool") as Node
	var zombie: Node3D = pool.call("spawn_from_pool", Vector3(30.0, 0.0, 0.0)) as Node3D
	await physics_frame
	var ai: Node = zombie.get_node("AI")
	ai.set_physics_process(false)
	var health: Node = zombie.get_node("Health")
	var grenade := (load("res://scenes/gameplay/grenade.tscn") as PackedScene).instantiate()
	main.get_node("Projectiles").add_child(grenade, true)
	grenade.global_position = zombie.global_position
	grenade.call("_apply_radial_damage", 6.0)
	_check(float(health.get("hp")) <= 0.0, "手雷中心 250 伤害可击杀普通怪")
	pool.call("despawn_to_pool", zombie)
	zombie = pool.call("spawn_from_pool", Vector3(32.0, 0.0, 0.0)) as Node3D
	await physics_frame
	zombie.get_node("AI").set_physics_process(false)
	health = zombie.get_node("Health")
	var fire_pool := main.get_node("Gameplay/FireZonePool")
	fire_pool.call("activate_zone", zombie.global_position, 1, 5.0, 8.0, 30.0)
	var zone := fire_pool.get_child(0)
	zone.call("_physics_process", 1.0)
	_check(is_equal_approx(float(health.get("hp")), 70.0), "燃烧区每秒造成 30 伤害")
	grenade.queue_free()
	pool.call("despawn_to_pool", zombie)


func _active_weapon_id(player: Node) -> String:
	for weapon in player.get_node("WeaponPivot").get_children():
		if weapon.visible:
			return String(weapon.get("weapon_id"))
	return ""


func _check(condition: bool, message: String) -> void:
	if condition:
		print("[PASS] %s" % message)
	else:
		_failures += 1
		printerr("[FAIL] %s" % message)
