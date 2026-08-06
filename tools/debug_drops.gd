extends SceneTree
## debug_drops.gd — M3-S6 掉落表 + 拾取 + 计分板统计自测（headless 仿真，服务器权威单机语义）
## 用法：godot --headless --path . --script tools/debug_drops.gd
## 验证（对应任务卡 §2-S6 自测）：
##  ① 初始：LootManager/GameState/Pickups 就绪；统计清零（新会话）
##  ② 真实概率掉落：刷 60 只普通丧尸击杀 → 击杀数累计正确（普通分列）、掉落物按概率生成
##  ③ ammo 拾取：强制 100% 弹药掉落 → 走近 E 拾取 → 弹匣补足、掉落物消失、不重复结算
##  ④ medkit 拾取：强制 100% 医疗掉落 → 扣血后拾取 → 回血（上限钳制）、掉落物消失
##  ⑤ 结算广播：GameState.finish_segment → scoreboard_requested 信号携带正确统计快照
##  ⑥ 倒地/救援统计：倒地次数 +1、救援完成 +1
##  ⑦ 全流程无红色 Error（脚本退出码 0 = 通过）
## 注意：工具脚本不引用游戏类（编译期 autoload 未注册，M2-S3 铁律），一律动态访问；
##       WaveManager 在主场景默认 level_mode=true（LevelAdvance 置位）不自动开波，测试环境干净。

const MAIN_SCENE := "res://scenes/main/main.tscn"
const LOOT_PATH := "Gameplay/LootManager"
const WAVE_MANAGER_PATH := "Gameplay/WaveManager"
const PICKUPS_PATH := "World/Pickups"
# pickup_item.gd Type：0=AMMO 1=HEALTH
const TYPE_AMMO := 0
const TYPE_HEALTH := 1

var _fail := 0
var _log := FileAccess.open("user://drops.log", FileAccess.WRITE)
var _sb_data: Dictionary = {}  # 结算广播捕获（成员变量：lambda 写局部变量不可靠，M2-S5 铁律）


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
	_log_line("=== DROPS_TEST START (M3-S6 掉落/拾取/统计) ===")
	change_scene_to_file(MAIN_SCENE)
	await create_timer(2.0).timeout
	var main := current_scene
	var loot := main.get_node_or_null(LOOT_PATH)
	var wm := main.get_node_or_null(WAVE_MANAGER_PATH)
	var pool := main.get_node_or_null("Gameplay/WaveManager/ZombiePool")
	var pickups := main.get_node_or_null(PICKUPS_PATH) as Node3D
	var player := _find_player(main)
	# GameState 为 autoload（root 子节点）；工具脚本编译期不能引用全局名（M2-S3 铁律），动态访问
	var gs := root.get_node_or_null("GameState")
	_check(loot != null and wm != null and pool != null and pickups != null and player != null,
		"场景就绪：LootManager/WaveManager/ZombiePool/Pickups/玩家 存在")
	if loot == null or pool == null or pickups == null or player == null:
		_finish()
		return

	_check(gs != null, "GameState autoload 存在")
	if gs == null:
		_finish()
		return

	# --- ① 初始状态：统计清零（main.gd 新会话 reset） ---
	_log_line("--- ① 初始：统计清零 / 掉落表装载 ---")
	_check(int(gs.get("kills_common")) == 0 and int(gs.get("kills_special")) == 0,
		"新会话统计清零（kills_common=0 kills_special=0）")
	_check(_pickup_count(pickups, -1) == 0, "无初始掉落物（pickup_items 数=0）")
	_check(not _table_is_empty(loot), "掉落表已装载（loot.json loot_table 非空）")

	# --- ② 真实概率掉落链路：刷 60 只普通丧尸击杀 ---
	_log_line("--- ② 真实概率掉落：刷 60 只 common → 击杀 → 掉落物生成 + 击杀统计 ---")
	var spawn_pos := Vector3(35, 1, 35)  # 远离玩家出生点（安全屋 x<-16），丧尸不追击干扰
	var spawned: Array[Node3D] = []
	for i in 60:
		var z: Node3D = pool.call("spawn_from_pool", spawn_pos) as Node3D
		if z != null:
			spawned.append(z)
	_check(spawned.size() == 60, "对象池出池 60 只普通丧尸")
	for z in spawned:
		var health: Node = z.get_node_or_null("Health")
		if health != null:
			health.call("take_damage", 9999.0)
	await create_timer(0.5).timeout
	_check(int(gs.get("kills_common")) == 60, "普通击杀统计=60（kills_common=%d）" % int(gs.get("kills_common")))
	_check(int(gs.get("kills_special")) == 0, "特感击杀统计=0（kills_special=%d）" % int(gs.get("kills_special")))
	var drop_count := _pickup_count(pickups, -1)
	_check(drop_count > 0 and drop_count <= 60,
		"真实概率掉落生成（60 只 → 掉落物 %d 个，期望 ~12，非 0）" % drop_count)

	# --- ③ ammo 拾取（确定性：覆盖概率表 100% 弹药） ---
	_log_line("--- ③ ammo 掉落拾取：E 键 → 弹匣补足 / 掉落物消失 ---")
	_clear_pickups(pickups)  # 清掉阶段②概率遗留掉落物，保证确定性匹配
	await create_timer(0.1).timeout
	loot.set("_table", {"common": {"ammo": 1.0}})
	await _spawn_and_kill(pool, player, spawn_pos)
	var ammo := _find_pickup(pickups, TYPE_AMMO)
	_check(ammo != null, "100% 弹药掉落：生成 1 个弹药掉落物")
	if ammo != null:
		var weapon := player.get_node_or_null("WeaponPivot/Pistol")
		var mag_size: int = weapon.get("mag_size")
		weapon.set("mag_current", mag_size - 5)
		player.global_position = ammo.global_position
		player._on_interact_pressed()
		await create_timer(0.1).timeout
		var mag: int = weapon.get("mag_current")
		_check(mag == mag_size, "拾取后弹匣补足（%d → %d/%d）" % [mag_size - 5, mag, mag_size])
		_check(not is_instance_valid(ammo), "拾取后掉落物消失")
		_check(_pickup_count(pickups, TYPE_AMMO) == 0, "弹药掉落物已清除（防重复拾取）")

	# --- ④ medkit 拾取（确定性：覆盖概率表 100% 医疗） ---
	_log_line("--- ④ medkit 掉落拾取：扣血 → E 键 → 回血 +50 / 上限钳制 ---")
	_clear_pickups(pickups)  # 清掉阶段③遗留（保险），保证确定性匹配
	await create_timer(0.1).timeout
	loot.set("_table", {"common": {"medkit": 1.0}})
	await _spawn_and_kill(pool, player, spawn_pos)
	var medkit := _find_pickup(pickups, TYPE_HEALTH)
	_check(medkit != null, "100% 医疗掉落：生成 1 个医疗掉落物")
	if medkit != null:
		var ps := player.get_node_or_null("Health")
		ps.call("take_damage", 60.0)
		var hp_before: float = ps.get("hp")
		player.global_position = medkit.global_position
		player._on_interact_pressed()
		await create_timer(0.1).timeout
		var hp_after: float = ps.get("hp")
		_check(absf(hp_after - (hp_before + 50.0)) < 0.01,
			"拾取后回血 +50（%.0f → %.0f）" % [hp_before, hp_after])
		_check(not is_instance_valid(medkit), "拾取后医疗掉落物消失")

	# --- ⑤ 结算广播：finish_segment → scoreboard_requested 快照正确 ---
	_log_line("--- ⑤ 结算广播：统计快照（击杀/救援/倒地/段落用时） ---")
	gs.scoreboard_requested.connect(_on_scoreboard)
	gs.call("finish_segment", 12.5)
	await create_timer(0.1).timeout
	_check(not _sb_data.is_empty(), "finish_segment 触发 scoreboard_requested 广播")
	if not _sb_data.is_empty():
		_check(int(_sb_data.get("kills_common")) == 62,
			"快照普通击杀=62（60+2 阶段 ③④）" )
		_check(int(_sb_data.get("kills_special")) == 0, "快照特感击杀=0")
		_check(absf(float(_sb_data.get("segment_time_s")) - 12.5) < 0.01, "快照段落用时=12.5s")
		_check(absf(float(gs.get("segment_time_s")) - 12.5) < 0.01, "GameState.segment_time_s 已结算")

	# --- ⑥ 倒地/救援统计 ---
	_log_line("--- ⑥ 倒地/救援统计：倒地次数 +1 / 救援完成 +1 ---")
	var ps := player.get_node_or_null("Health")
	var downs_before: int = gs.get("downs")
	var revives_before: int = gs.get("revives")
	ps.call("take_damage", 9999.0)
	_check(int(ps.get("state")) == 1, "玩家进入倒地（DOWN）")
	_check(int(gs.get("downs")) == downs_before + 1, "倒地次数 +1（downs=%d）" % int(gs.get("downs")))
	ps.call("_debug_self_revive")
	await create_timer(3.5).timeout
	_check(int(ps.get("state")) == 0, "救援完成：玩家回到 ALIVE")
	_check(int(gs.get("revives")) == revives_before + 1, "救援完成数 +1（revives=%d）" % int(gs.get("revives")))

	# --- ⑦ 特感掉落验证：冲撞者死亡 → 必掉 + 特感击杀分列 ---
	_log_line("--- ⑦ 特感掉落：charger 必掉（概率和=1.0）/ 特感击杀统计 ---")
	loot.call("_load_loot")  # 恢复真实掉落表（阶段③④覆盖了 _table）
	_clear_pickups(pickups)
	await create_timer(0.1).timeout
	var zombies := main.get_node_or_null("Zombies")
	var special_before: int = gs.get("kills_special")
	var charger := _spawn_special(zombies, "res://scenes/enemies/zombie_charger.tscn", spawn_pos + Vector3(4, 0, 0))
	_check(charger != null, "冲撞者生成成功")
	if charger != null:
		var ch_health: Node = charger.get_node_or_null("Health")
		if ch_health != null:
			ch_health.call("take_damage", 9999.0)
		await create_timer(0.4).timeout
		_check(int(gs.get("kills_special")) == special_before + 1,
			"特感击杀分列 +1（kills_special=%d）" % int(gs.get("kills_special")))
		_check(_pickup_count(pickups, -1) >= 1, "冲撞者必掉掉落物（概率和 1.0 → 生成 %d 个）" % _pickup_count(pickups, -1))

	_log_line("=== DROPS_TEST %s (fail=%d) ===" % ["PASS" if _fail == 0 else "FAIL", _fail])
	_finish()


# --- 工具 ---

func _on_scoreboard(data: Dictionary) -> void:
	_sb_data = data


## 刷 1 只丧尸并击杀（返回前生成掉落物；杀后短暂等待掉落生成）
func _spawn_and_kill(pool: Node, player: Node3D, pos: Vector3) -> void:
	var z: Node3D = pool.call("spawn_from_pool", pos + Vector3(2, 0, 0)) as Node3D
	if z != null:
		var health: Node = z.get_node_or_null("Health")
		if health != null:
			health.call("take_damage", 9999.0)
	await create_timer(0.4).timeout
	_keep_player_alive(player)


## 掉落物计数（type=-1 全部；0=弹药 1=医疗）
func _pickup_count(pickups: Node3D, type: int) -> int:
	var count := 0
	for c in pickups.get_children():
		if c.is_in_group("pickup_items"):
			if type < 0 or int(c.get("pickup_type")) == type:
				count += 1
	return count


func _find_pickup(pickups: Node3D, type: int) -> Node3D:
	for c in pickups.get_children():
		if c.is_in_group("pickup_items") and int(c.get("pickup_type")) == type:
			return c as Node3D
	return null


func _table_is_empty(loot: Node) -> bool:
	var t = loot.get("_table")
	return not (t is Dictionary) or (t as Dictionary).is_empty()


## 清空容器中遗留的掉落物（测试隔离：确定性阶段前清掉概率阶段产物）
func _clear_pickups(pickups: Node3D) -> void:
	for c in pickups.get_children():
		if c.is_in_group("pickup_items"):
			c.queue_free()


## 独立实例化特感并加入 Zombies 容器（特感 AI 自载参数/类型注入/死亡链路）
func _spawn_special(zombies: Node3D, scene_path: String, pos: Vector3) -> Node3D:
	if zombies == null:
		return null
	var scene := load(scene_path) as PackedScene
	if scene == null:
		return null
	var sp := scene.instantiate() as Node3D
	if sp == null:
		return null
	sp.set_multiplayer_authority(1)  # 服务器权威（先设再入树）
	zombies.add_child(sp, true)
	sp.global_position = pos
	return sp


func _find_player(main: Node) -> Node3D:
	var players := main.get_node_or_null("Players")
	if players == null:
		return null
	for p in players.get_children():
		if p.get_node_or_null("Health") != null:
			return p as Node3D
	return null


## 测试防阵亡：回血 + 若 DEAD 强制回 ALIVE（headless 仿真"玩家存活"）
func _keep_player_alive(player: Node3D) -> void:
	var ps := player.get_node_or_null("Health")
	if ps == null:
		return
	ps.call("apply_healing", 9999.0)
	if int(ps.get("state")) == 2:  # DEAD
		ps.set("state", 0)  # ALIVE


func _finish() -> void:
	change_scene_to_file("res://scenes/ui/main_menu.tscn")
	await create_timer(0.8).timeout
	quit(_fail)
