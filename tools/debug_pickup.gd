extends SceneTree
# 临时仿真脚本（M2-S4）：headless 跑主场景，模拟 E 键拾取验证补给点链路。
# 用法：godot --headless --path . --script tools/debug_pickup.gd
# 验证：F2 弹药补满/医疗回血；F3 拾取后消失；F4 连点不重复结算；距离校验（服务器复验）
# 注意：--script 工具脚本不引用游戏类类型（M2-S3 铁律：编译期拉游戏类会失败），
#       补给点类型用 int 动态访问（supply_type：0=AMMO 1=HEALTH）

const MAIN_SCENE := "res://scenes/main/main.tscn"

func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	print("=== PICKUP_TEST START ===")
	change_scene_to_file(MAIN_SCENE)
	await create_timer(2.0).timeout
	var main := current_scene
	var players := main.get_node_or_null("Players") as Node3D
	if players == null or players.get_child_count() == 0:
		printerr("[pickup] no player found")
		quit(1)
		return
	var player := players.get_child(0) as Node3D
	var state := player.get_node_or_null("Health")
	var weapon := player.get_node_or_null("WeaponPivot/Pistol")
	var pickups := main.get_node_or_null("World/Pickups") as Node3D
	if state == null or weapon == null or pickups == null:
		printerr("[pickup] missing nodes")
		quit(1)
		return
	print("[init] hp=", state.hp, " mag=", weapon.mag_current, " pickups=", pickups.get_child_count())

	# D：距离校验——玩家远离所有补给点，按 E 应无效果
	player.global_position = Vector3(30, 0, 30)
	var before_mag: int = weapon.mag_current
	player._on_interact_pressed()
	print("[D] far-from-supply mag=", weapon.mag_current, " expect=", before_mag, " (no change)")

	# A：弹药补给——耗 5 发 → 走近 ammo 点同帧连按两次 E：弹匣补满且不重复结算（F2+F4）、点消失（F3）
	var ammo := _find_supply_by_type(pickups, 0)
	weapon.mag_current = weapon.mag_size - 5
	player.global_position = ammo.global_position
	player._on_interact_pressed()
	player._on_interact_pressed()  # 同帧第二次：used=true 已设，应被服务器拒绝
	await create_timer(0.1).timeout
	print("[A] ammo mag=", weapon.mag_current, " expect=", weapon.mag_size,
		" removed=", not is_instance_valid(ammo))

	# B：医疗补给——扣 80 HP → 走近 health 点按 E → 恢复 50（上限 max_hp 100）、点消失
	var health := _find_supply_by_type(pickups, 1)
	state.take_damage(80.0)
	var hp_before: float = state.hp
	player.global_position = health.global_position
	player._on_interact_pressed()
	await create_timer(0.1).timeout
	print("[B] health hp=", state.hp, " from=", hp_before, " (+50 expect)",
		" removed=", not is_instance_valid(health))

	# C：全部拾取后容器内无剩余补给点（F3 不可重复拾取）
	var remaining := 0
	for c in pickups.get_children():
		if c.is_in_group("supply_points"):
			remaining += 1
	print("[C] remaining supplies=", remaining, " (expect 0)")

	# E：Intermission 波间刷新（reward 数据驱动）——经 WaveManager._enter_intermission 触发
	# wave_01 reward={health_packs:0, ammo:1} → 应生成 1 个弹药补给点
	var wm := main.get_node_or_null("Gameplay/WaveManager")
	wm._begin_wave(0)  # S5：推进制下 _current_wave 为空，先切竞技场第 0 波让 reward 生效
	wm._enter_intermission()
	await create_timer(0.1).timeout
	var spawned_count := 0
	var spawned_ammo := 0
	for c in pickups.get_children():
		if c.is_in_group("supply_points"):
			spawned_count += 1
			if int(c.get("supply_type")) == 0:
				spawned_ammo += 1
	print("[E] intermission spawned=", spawned_count, " ammo=", spawned_ammo, " (expect 1/1)")
	print("=== PICKUP_TEST END ===")
	# 切回主菜单释放主场景（防退出时对象泄漏；与 debug_wave_flow 结束方式一致）
	change_scene_to_file("res://scenes/ui/main_menu.tscn")
	await create_timer(0.8).timeout
	quit(0)


func _find_supply_by_type(pickups: Node, type: int) -> Node3D:
	for c in pickups.get_children():
		if int(c.get("supply_type")) == type:
			return c as Node3D
	return null
