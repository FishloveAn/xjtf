extends SceneTree
## debug_spitter.gd — M3-S3 喷吐者行为自测（headless 仿真，服务器权威单机语义）
## 用法：godot --headless --path . --script tools/debug_spitter.gd
## 验证：① 数据驱动参数生效（zombies.json spitter hp150/酸区半径2.5/DPS10/持续6s/射程25）
##       ② 吐酸全流程：喷吐者生成于玩家中距离 → Chase → SpitWindup(前摇) → 吐酸 → 酸区落地
##       ③ 玩家站酸区内持续扣血（hp 下降，HUD 血条走 damageable 服务器权威）→ 酸区到期消失
##       ④ 击杀死亡清理无泄漏；酸液区不伤丧尸（只伤玩家，组过滤）
##       ⑤ 波次 composition 特感配额 8（charger4+spitter4）→ 同屏特感总量峰值 ≤5（共享 cap）
## 注意：工具脚本不引用游戏类（编译期 autoload 未注册，M2-S3 铁律），一律动态访问。

const MAIN_SCENE := "res://scenes/main/main.tscn"
const WAVE_MANAGER_PATH := "Gameplay/WaveManager"
const SPITTER_SCENE_PATH := "res://scenes/enemies/zombie_spitter.tscn"
const COMMON_SCENE_PATH := "res://scenes/enemies/zombie_common.tscn"
const ACID_POOL_SCENE_PATH := "res://scenes/enemies/acid_pool.tscn"
# 喷吐者状态机（zombie_ai_spitter.gd）：IDLE=0 CHASE=1 SPIT_WINDUP=2 DEAD=3
const S_CHASE := 1
const S_SPIT_WINDUP := 2
const S_DEAD := 3
# 玩家状态（player_state.gd）：ALIVE=0 DOWN=1 DEAD=2
const P_ALIVE := 0

var _fail := 0
var _log := FileAccess.open("user://spitter_test_progress.log", FileAccess.WRITE)


func _log_line(s: String) -> void:
	print(s)
	if _log != null:
		_log.store_line(s)
		_log.flush()


func _check(cond: bool, label: String) -> void:
	if cond:
		_log_line("  [PASS] " + label)
	else:
		_fail += 1
		_log_line("  [FAIL] " + label)


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	_log_line("=== SPITTER TEST START ===")
	change_scene_to_file(MAIN_SCENE)
	await create_timer(2.0).timeout
	var main := current_scene
	var zombies := main.get_node_or_null("Zombies")
	var world := main.get_node_or_null("World")
	var wm := main.get_node_or_null(WAVE_MANAGER_PATH)
	var player := _find_player(main)
	_check(wm != null and zombies != null and world != null and player != null, "场景就绪：WaveManager/Zombies/World/玩家 存在")
	if wm == null or zombies == null or world == null or player == null:
		_finish()
		return
	wm.set("_setup_timer", 999.0)  # 冻结普通波次刷怪，专注喷吐者行为测试

	# --- ① 数据驱动参数生效 ---
	_log_line("--- ① 数据驱动参数生效（zombies.json spitter 条目） ---")
	var start_pos: Vector3 = player.global_position
	var spitter := _spawn_spitter(zombies, start_pos + Vector3(12.0, 0.0, 0.0))
	_check(spitter != null, "喷吐者生成于玩家中距离 12m")
	if spitter == null:
		_finish()
		return
	var ai := spitter.get_node_or_null("AI")
	_check(absf(float(ai.get("_acid_radius")) - 2.5) < 0.001, "酸区半径数据驱动=2.5m")
	_check(absf(float(ai.get("_acid_duration")) - 6.0) < 0.001, "酸区持续数据驱动=6s")
	_check(absf(float(ai.get("_acid_dps")) - 10.0) < 0.001, "酸液 DPS 数据驱动=10")
	_check(absf(float(ai.get("_spit_range")) - 25.0) < 0.001, "射程数据驱动=25m")
	_check(absf(float(spitter.get_node_or_null("Health").get("hp")) - 150.0) < 0.001, "hp 数据驱动=150（脆，优先击杀）")

	# --- ② 吐酸全流程：Chase → SpitWindup → 酸区落地 ---
	_log_line("--- ② 吐酸全流程：Chase → SpitWindup → 酸区落地 ---")
	var saw_windup := false
	var saw_pool := false
	var pool: Node = null
	for i in 150:  # 最多 15s
		await create_timer(0.1).timeout
		if not is_instance_valid(spitter):
			break
		if int(ai.get("state")) == S_SPIT_WINDUP:
			saw_windup = true
		var pools := get_nodes_in_group("acid_pools")
		if pools.size() > 0:
			saw_pool = true
			pool = pools[0]
		if saw_windup and saw_pool:
			break
	_check(saw_windup, "前摇 SpitWindup 出现（站定吐酸）")
	_check(saw_pool, "酸液区落地生成（Area3D 圆盘）")
	if pool != null:
		_check(pool.global_position.distance_to(start_pos) <= 5.0, "酸区落点贴近玩家当前位置")
		_check(absf(float(pool.get("radius")) - 2.5) < 0.001, "酸区实例半径=2.5m")
		_check(absf(float(pool.get("duration_s")) - 6.0) < 0.001, "酸区实例持续=6s")
		_check(absf(float(pool.get("dps")) - 10.0) < 0.001, "酸区实例 DPS=10")

	# --- ③ 玩家站酸区内持续扣血（走 damageable，服务器权威） ---
	_log_line("--- ③ 玩家站酸区内持续扣血 → 走出/到期即停 ---")
	var ps := player.get_node_or_null("Health")
	ps.apply_healing(100.0)  # 保底满血（服务器权威单机）
	var hp_start: float = ps.get("hp")
	await create_timer(2.5).timeout
	var hp_end: float = ps.get("hp")
	_check(hp_end < hp_start - 10.0, "站酸区 2.5s 持续扣血（hp %.0f → %.0f，DPS≈10）" % [hp_start, hp_end])
	_check(int(ps.get("state")) == P_ALIVE, "酸伤后玩家仍 ALIVE（2.5s 扣约 25HP 未倒地）")

	# --- ④ 击杀 → 死亡清理无泄漏 ---
	_log_line("--- ④ 击杀喷吐者 → 死亡清理无泄漏 ---")
	var health := spitter.get_node_or_null("Health")
	health.take_damage(9999.0)
	_check(int(ai.get("state")) == S_DEAD, "击杀后喷吐者进 DEAD")
	var t := 0.0
	while t < 6.0 and is_instance_valid(spitter):
		await create_timer(0.2).timeout
		t += 0.2
	_check(not is_instance_valid(spitter) or spitter.is_queued_for_deletion(),
		"死亡清理完成（die_clear_s=2.5s 后节点已释放）")
	_check(_count_spitters(zombies) == 0, "Zombies 容器无残留喷吐者（无泄漏）")

	# --- ⑤ 酸液区到期自动消失 ---
	_log_line("--- ⑤ 酸液区到期自动消失（不无限存在） ---")
	var t2 := 0.0
	while t2 < 8.0 and get_nodes_in_group("acid_pools").size() > 0:
		await create_timer(0.2).timeout
		t2 += 0.2
	_check(get_nodes_in_group("acid_pools").size() == 0, "酸液区 6s 后消失（无残留）")

	# --- ⑥ 酸液区不伤丧尸（只伤玩家，组过滤 G4b） ---
	_log_line("--- ⑥ 酸液区不伤丧尸（只伤玩家） ---")
	var zombie := _spawn_common(zombies, Vector3(15.0, 0.0, 15.0))
	zombie.get_node_or_null("AI").set_physics_process(false)  # 冻结普通丧尸 AI，防止移动离开酸区
	var manual_pool: Node = (load(ACID_POOL_SCENE_PATH) as PackedScene).instantiate()
	world.add_child(manual_pool)
	manual_pool.global_position = Vector3(15.0, 0.05, 15.0)
	var z_hp_start: float = zombie.get_node_or_null("Health").get("hp")
	await create_timer(1.2).timeout
	var z_hp_end: float = zombie.get_node_or_null("Health").get("hp")
	_check(z_hp_end == z_hp_start, "丧尸站酸区内 hp 不变（%.0f → %.0f，只伤玩家）" % [z_hp_start, z_hp_end])
	manual_pool.queue_free()
	zombie.queue_free()

	# --- ⑦ 波次特感配额 + 共享同屏 cap（冲撞者+喷吐者 ≤5） ---
	_log_line("--- ⑦ 波次 composition 特感配额 8（charger4+spitter4）→ 同屏总量峰值 ≤5 ---")
	wm._waves[2] = {
		"composition": {"common": 0, "charger": 4, "spitter": 4},
		"concurrent_cap": 12,
		"spawn_style": "trickle",
		"spawn_interval": 0.1,
		"cleared_when": {"type": "all_spawned_killed"},
	}
	wm._begin_wave(2)
	wm.set("_setup_timer", 0.05)
	var director = wm.get("_director")  # Director 子节点（动态调用）
	var cap: int = int(director.special_cap())
	var max_active := 0
	var max_living := 0
	var spawned_total := 0
	var tt := 0.0
	var last_kill := -4.0
	while tt < 40.0 and spawned_total < 8:
		await create_timer(0.2).timeout
		tt += 0.2
		max_active = maxi(max_active, int(wm.get("_active_specials")))
		max_living = maxi(max_living, _count_living_specials(zombies))
		spawned_total = int(wm.get("_spawned_chargers")) + int(wm.get("_spawned_spitters"))
		if tt - last_kill >= 4.0:
			_kill_living_specials(zombies)
			last_kill = tt
	_check(spawned_total >= 8, "composition 特感配额 8 全部刷出（charger+spitter=%d）" % spawned_total)
	_check(max_living <= 5, "同屏特感总量峰值 %d ≤ 5（冲撞者+喷吐者共享 cap）" % max_living)
	_check(max_active <= cap, "同屏活跃特感峰值 %d ≤ director cap %d" % [max_active, cap])

	_finish()


func _finish() -> void:
	_log_line("=== SPITTER TEST %s (fail=%d) ===" % ["PASS" if _fail == 0 else "FAIL", _fail])
	change_scene_to_file("res://scenes/ui/main_menu.tscn")
	await create_timer(0.8).timeout
	quit(_fail)


func _find_player(main: Node) -> Node3D:
	var players := main.get_node_or_null("Players")
	if players == null:
		return null
	for p in players.get_children():
		if p.get_node_or_null("Health") != null:
			return p as Node3D
	return null


## 直接实例化喷吐者（不经过 WaveManager，便于行为测试；服务器权威单机语义）
func _spawn_spitter(zombies: Node, pos: Vector3) -> Node3D:
	var scene := load(SPITTER_SCENE_PATH) as PackedScene
	if scene == null:
		return null
	var s := scene.instantiate()
	s.set_multiplayer_authority(1)
	zombies.add_child(s)
	s.global_position = pos
	return s


## 直接实例化普通丧尸（酸液不伤丧尸验证用）
func _spawn_common(zombies: Node, pos: Vector3) -> Node3D:
	var scene := load(COMMON_SCENE_PATH) as PackedScene
	if scene == null:
		return null
	var z := scene.instantiate()
	z.set_multiplayer_authority(1)
	zombies.add_child(z)
	z.global_position = pos
	return z


## 容器内喷吐者节点数（按 AI 脚本路径识别）
func _count_spitters(zombies: Node) -> int:
	var n := 0
	for c in zombies.get_children():
		if _is_spitter_node(c):
			n += 1
	return n


## 存活特感数（charger+spitter，state != DEAD 才计入；死亡淡出节点不计）
func _count_living_specials(zombies: Node) -> int:
	var n := 0
	for c in zombies.get_children():
		if _is_special_node(c) and int(c.get_node_or_null("AI").get("state")) != S_DEAD:
			n += 1
	return n


func _kill_living_specials(zombies: Node) -> void:
	for c in zombies.get_children():
		if _is_special_node(c) and int(c.get_node_or_null("AI").get("state")) != S_DEAD:
			c.get_node_or_null("Health").take_damage(9999.0)


func _is_special_node(node: Node) -> bool:
	var ai := node.get_node_or_null("AI")
	if ai == null:
		return false
	return _is_spitter_node(node) or _is_charger_node(node)


func _is_spitter_node(node: Node) -> bool:
	var ai := node.get_node_or_null("AI")
	if ai == null:
		return false
	var script: Script = ai.get_script()
	return script != null and String(script.resource_path).ends_with("zombie_ai_spitter.gd")


func _is_charger_node(node: Node) -> bool:
	var ai := node.get_node_or_null("AI")
	if ai == null:
		return false
	var script: Script = ai.get_script()
	return script != null and String(script.resource_path).ends_with("zombie_ai_charger.gd")
