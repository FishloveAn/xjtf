extends SceneTree
## debug_charger.gd — M3-S2 冲撞者行为自测（headless 仿真，服务器权威单机语义）
## 用法：godot --headless --path . --script tools/debug_charger.gd
## 验证：① 直线冲撞全流程：冲撞者生成于玩家正前方直线 → Chase → Windup(蓄力) → Charge(直线冲撞)
##        → 命中玩家 DOWN（强制倒地，可被救援）→ 击杀死亡清理；
##       ② 冲撞落空：玩家侧移 → 冲满距离未命中 → 硬直 Stagger → 冷却回 Chase（cooldown>0）；
##       ③ 波次 composition 特感配额 8 → 同屏特感峰值 ≤ director cap（≤5 硬上限）；
##       ④ 全程无红色 Error。
## 注意：工具脚本不引用游戏类（编译期 autoload 未注册，M2-S3 铁律），一律动态访问。

const MAIN_SCENE := "res://scenes/main/main.tscn"
const WAVE_MANAGER_PATH := "Gameplay/WaveManager"
const CHARGER_SCENE_PATH := "res://scenes/enemies/zombie_charger.tscn"
# 冲撞者状态机（zombie_ai_charger.gd）：IDLE=0 CHASE=1 WINDUP=2 CHARGE=3 STAGGER=4 DEAD=5
const S_CHASE := 1
const S_WINDUP := 2
const S_CHARGE := 3
const S_STAGGER := 4
const S_DEAD := 5
# 玩家状态（player_state.gd）：ALIVE=0 DOWN=1 DEAD=2
const P_ALIVE := 0
const P_DOWN := 1

var _fail := 0
var _log := FileAccess.open("user://charger_test_progress.log", FileAccess.WRITE)


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
	_log_line("=== CHARGER TEST START ===")
	change_scene_to_file(MAIN_SCENE)
	await create_timer(2.0).timeout
	var main := current_scene
	var zombies := main.get_node_or_null("Zombies")
	var wm := main.get_node_or_null(WAVE_MANAGER_PATH)
	var player := _find_player(main)
	_check(wm != null and zombies != null and player != null, "场景就绪：WaveManager/Zombies/玩家 存在")
	if wm == null or zombies == null or player == null:
		_finish()
		return
	wm.set("_setup_timer", 999.0)  # 冻结普通波次刷怪，专注冲撞者行为测试

	# --- ① 直线冲撞 → 命中玩家 DOWN ---
	_log_line("--- ① 直线冲撞 → 命中玩家 DOWN ---")
	# S5 主场景已换推进制关卡（带墙）；移到装卸广场中央（开阔无遮挡），保证 15m 直线可达
	player.global_position = Vector3(30.0, 0.0, 0.0)
	var start_pos: Vector3 = player.global_position
	var charger := _spawn_charger(zombies, start_pos + Vector3(0.0, 0.0, 15.0))
	_check(charger != null, "冲撞者生成于玩家正前方 15m 直线上")
	if charger == null:
		_finish()
		return
	var saw_windup := false
	var saw_charge := false
	var saw_stagger := false
	var saw_down := false
	for i in 200:  # 最多 20s
		await create_timer(0.1).timeout
		if not is_instance_valid(charger) or not is_instance_valid(player):
			break
		var st: int = int(charger.get_node_or_null("AI").get("state"))
		if st == S_WINDUP:
			saw_windup = true
		elif st == S_CHARGE:
			saw_charge = true
		elif st == S_STAGGER:
			saw_stagger = true
		if int(player.get_node_or_null("Health").get("state")) == P_DOWN:
			saw_down = true
		if saw_down and saw_windup and saw_charge and saw_stagger:
			break
	_check(saw_windup, "蓄力前摇 Windup 出现")
	_check(saw_charge, "直线冲刺 Charge 出现")
	_check(saw_down, "命中玩家 → 玩家状态 DOWN（倒地，可被救援）")
	_check(saw_stagger, "命中后硬直 Stagger 出现")

	# --- ② 击杀 → 死亡清理 ---
	_log_line("--- ② 击杀冲撞者 → 死亡清理 ---")
	var health := charger.get_node_or_null("Health")
	health.take_damage(9999.0)
	_check(int(charger.get_node_or_null("AI").get("state")) == S_DEAD, "击杀后冲撞者进 DEAD")
	var t := 0.0
	while t < 6.0 and is_instance_valid(charger):
		await create_timer(0.2).timeout
		t += 0.2
	_check(not is_instance_valid(charger) or charger.is_queued_for_deletion(),
		"死亡清理完成（die_clear_s=2.5s 后节点已释放）")
	_check(_count_chargers(zombies) == 0, "Zombies 容器无残留冲撞者（无泄漏）")

	# --- ③ 冲撞落空 → 硬直 → 冷却回 Chase ---
	_log_line("--- ③ 冲撞落空（玩家侧移）→ 硬直 → 冷却回 Chase ---")
	var ps := player.get_node_or_null("Health")
	ps.apply_healing(100.0)  # 复活：DOWN→ALIVE（服务器权威单机）
	player.global_position = Vector3(30.0, 0.0, 0.0)  # 仍用装卸广场（开阔，冲撞落空语义成立）
	var charger_b := _spawn_charger(zombies, Vector3(30.0, 0.0, 15.0))
	_check(charger_b != null, "冲撞者 B 生成于新玩家正前方 15m 直线上")
	if charger_b == null:
		_finish()
		return
	var moved := false
	var saw_stagger_b := false
	var saw_chase_after := false
	var chase_cooldown := 0.0
	for i in 200:
		await create_timer(0.1).timeout
		if not is_instance_valid(charger_b) or not is_instance_valid(player):
			break
		var ai := charger_b.get_node_or_null("AI")
		var st: int = int(ai.get("state"))
		if st == S_CHARGE and not moved:
			player.global_position = Vector3(-2.0, 0.0, 0.0)  # 侧移躲开冲撞路径（x=5）
			moved = true
		if st == S_STAGGER:
			saw_stagger_b = true
		if st == S_CHASE and saw_stagger_b:
			saw_chase_after = true
			chase_cooldown = float(ai.get("_cooldown_timer"))
			break
	_check(moved, "冲撞路径中途玩家侧移（冲撞方向锁定不追踪）")
	_check(saw_stagger_b, "冲满距离未命中 → 硬直 Stagger 收招")
	_check(saw_chase_after, "硬直结束 → 冷却回 Chase（cooldown=%.1fs > 0）" % chase_cooldown)
	_check(chase_cooldown > 0.0, "回 Chase 时冲撞冷却计时生效（cooldown=%.1fs）" % chase_cooldown)
	_check(int(ps.get("state")) == P_ALIVE, "落空冲撞未伤及玩家（玩家仍 ALIVE）")
	var health_b := charger_b.get_node_or_null("Health")
	if is_instance_valid(charger_b):
		health_b.take_damage(9999.0)
		var tb := 0.0
		while tb < 6.0 and is_instance_valid(charger_b):
			await create_timer(0.2).timeout
			tb += 0.2

	# --- ④ 波次特感配额 + 同屏 cap ---
	_log_line("--- ④ 波次 composition 特感配额 8 → 同屏峰值 ≤ cap（硬上限 5） ---")
	wm._waves[2] = {
		"composition": {"common": 0, "charger": 8},
		"concurrent_cap": 12,
		"spawn_style": "trickle",
		"spawn_interval": 0.1,
		"cleared_when": {"type": "all_spawned_killed"},
	}
	wm._begin_wave(2)
	wm.set("_setup_timer", 0.05)
	var director = wm.get("_director")  # Director 子节点（_ready 动态 add_child，非固定名；未类型化以动态调用）
	var cap: int = int(director.special_cap())
	var max_active := 0
	var max_living := 0
	var spawned_total := 0
	var tt := 0.0
	var last_kill := -4.0
	while tt < 35.0 and spawned_total < 8:
		await create_timer(0.2).timeout
		tt += 0.2
		max_active = maxi(max_active, int(wm.get("_active_specials")))
		max_living = maxi(max_living, _count_living_chargers(zombies))
		spawned_total = int(wm.get("_spawned_chargers"))
		if tt - last_kill >= 4.0:
			_kill_living_chargers(zombies)
			last_kill = tt
	_check(spawned_total >= 8, "composition 特感配额 8 全部刷出（spawned=%d）" % spawned_total)
	_check(max_living <= 5, "同屏特感峰值 %d ≤ 5（硬上限）" % max_living)
	_check(max_active <= cap, "同屏活跃特感峰值 %d ≤ director cap %d" % [max_active, cap])

	_finish()


func _finish() -> void:
	_log_line("=== CHARGER TEST %s (fail=%d) ===" % ["PASS" if _fail == 0 else "FAIL", _fail])
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


## 直接实例化冲撞者（不经过 WaveManager，便于行为测试；服务器权威单机语义）
func _spawn_charger(zombies: Node, pos: Vector3) -> Node3D:
	var scene := load(CHARGER_SCENE_PATH) as PackedScene
	if scene == null:
		return null
	var c := scene.instantiate()
	c.set_multiplayer_authority(1)
	zombies.add_child(c)
	c.global_position = pos
	return c


## 容器内冲撞者节点数（按 AI 脚本路径识别，兼容普通丧尸）
func _count_chargers(zombies: Node) -> int:
	var n := 0
	for c in zombies.get_children():
		if _is_charger_node(c):
			n += 1
	return n


## 存活冲撞者数（state != DEAD，死亡淡出节点不计入同屏特感）
func _count_living_chargers(zombies: Node) -> int:
	var n := 0
	for c in zombies.get_children():
		if _is_charger_node(c) and int(c.get_node_or_null("AI").get("state")) != S_DEAD:
			n += 1
	return n


func _kill_living_chargers(zombies: Node) -> void:
	for c in zombies.get_children():
		if _is_charger_node(c) and int(c.get_node_or_null("AI").get("state")) != S_DEAD:
			c.get_node_or_null("Health").take_damage(9999.0)


func _is_charger_node(node: Node) -> bool:
	var ai := node.get_node_or_null("AI")
	if ai == null:
		return false
	var script: Script = ai.get_script()
	return script != null and String(script.resource_path).ends_with("zombie_ai_charger.gd")
