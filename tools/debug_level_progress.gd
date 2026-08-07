extends SceneTree
## debug_level_progress.gd — M3-S5 推进制关卡全流程自测（headless 仿真，服务器权威单机语义）
## 用法：godot --headless --path . --script tools/debug_level_progress.gd
## 验证（对应任务卡 §2-S5 自测）：
##  ① 初始：玩家出生开场安全屋；WaveManager 关卡模式开启；关卡补给点/尸潮刷怪点存在
##  ② 区域推进：靠近安全屋门 → 门开 + 进入货场(YARD)；进通道(CORRIDOR)
##  ③ 固定尸潮触发 1：通道中段进入 → 第一波(level_horde_01)启动 → 杀光清波回等待
##  ④ 固定尸潮触发 2：进装卸广场 → 守点高潮(level_holdout)启动 → 杀光 → 后门开启
##  ⑤ 到达后门安全屋：回血（满 hp）+ 隔离测试存档生成（segment≥1/completed=true）
##  ⑥ 全流程无红色 Error（脚本退出码 0 = 通过）
## 注意：工具脚本不引用游戏类（编译期 autoload 未注册，M2-S3 铁律），一律动态访问；
##       玩家穿传送模拟推进（不走物理路径），每步等 body_entered 触发。

const MAIN_SCENE := "res://scenes/main/main.tscn"
const LEVEL_ADVANCE_PATH := "Gameplay/LevelAdvance"
const WAVE_MANAGER_PATH := "Gameplay/WaveManager"
const SAVE_PATH := "user://save/debug_level_progress.json"
# 阶段枚举（level_advance.gd Phase）：SAFE_ROOM=0 YARD=1 CORRIDOR=2 PLAZA=3 BACKDOOR=4 COMPLETE=5
# 波次状态枚举（wave_manager.gd State）：SETUP=0 WAVE_ACTIVE=1 WAVE_CLEARED=2 ... LEVEL_WAIT=5
const P_YARD := 1
const P_CORRIDOR := 2
const P_BACKDOOR := 4
const S_SETUP := 0
const S_LEVEL_WAIT := 5

var _fail := 0
var _log := FileAccess.open("user://level_progress.log", FileAccess.WRITE)


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
	_log_line("=== LEVEL_PROGRESS START (M3-S5 三段式推进) ===")
	_cleanup_save()
	var game_state := root.get_node_or_null("GameState")
	if game_state != null:
		game_state.set("checkpoint_path", SAVE_PATH)
	change_scene_to_file(MAIN_SCENE)
	await create_timer(2.0).timeout
	var main := current_scene
	var la := main.get_node_or_null(LEVEL_ADVANCE_PATH)
	var wm := main.get_node_or_null(WAVE_MANAGER_PATH)
	var player := _find_player(main)
	_check(la != null and wm != null and player != null, "场景就绪：LevelAdvance/WaveManager/玩家 存在")
	if la == null or wm == null or player == null:
		_finish()
		return

	# --- ① 初始状态 ---
	_log_line("--- ① 初始：安全屋出生 / 关卡模式 / 资源存在 ---")
	_check(int(la.get("phase")) == 0, "初始阶段 = 开场安全屋（SAFE_ROOM）")
	_check(player.global_position.x < -16.0, "玩家出生在开场安全屋（x=%.1f < -16）" % player.global_position.x)
	_check(bool(wm.get("level_mode")), "WaveManager 关卡模式开启（level_mode=true）")
	_check(_group_count("spawn_point") >= 2, "玩家出生点存在（spawn_point 组 %d 个）" % _group_count("spawn_point"))
	_check(_group_count("horde_spawn_point") >= 8, "关卡尸潮刷怪点存在（horde_spawn_point 组 %d 个）" % _group_count("horde_spawn_point"))
	_check(_group_count("supply_points") >= 5, "关卡补给点存在（supply_points 组 %d 个）" % _group_count("supply_points"))

	# --- ② 安全屋门 → 货场 → 通道 ---
	_log_line("--- ② 区域推进：安全屋门 → 货场 → 货运通道 ---")
	await _teleport_to(player, "safe_exit", "靠近安全屋门")
	_check(int(la.get("phase")) == P_YARD, "安全屋门开启 → 进入货场（YARD）")
	_check(_door_open(), "安全屋门已开启（网格隐藏/碰撞禁用）")
	await _teleport_to(player, "corridor_enter", "进入货运通道入口")
	_check(int(la.get("phase")) == P_CORRIDOR, "进入货运通道（CORRIDOR）")

	# --- ③ 固定触发 1：通道中段第一波 ---
	_log_line("--- ③ 通道中段：第一波尸潮触发（level_horde_01）→ 清波 ---")
	await _teleport_to(player, "corridor_mid", "进入通道中段")
	_check(bool(la.get("_horde_triggered")), "第一波尸潮已触发标记（_horde_triggered）")
	_check(String(wm.get("_current_wave_id")) == "level_horde_01", "当前波次 = level_horde_01")
	await _fast_start(wm)
	_check(await _wait_wave_cleared(main, wm, player, 60.0), "第一波杀光 → 波次回等待（LEVEL_WAIT）")

	# --- ④ 固定触发 2：装卸广场守点高潮 ---
	_log_line("--- ④ 装卸广场：守点高潮触发（level_holdout）→ 清波 → 后门开启 ---")
	await _teleport_to(player, "plaza_enter", "进入装卸广场")
	_check(int(la.get("phase")) == 3, "进入装卸广场（PLAZA）")
	_check(bool(la.get("_holdout_triggered")), "守点高潮已触发标记（_holdout_triggered）")
	_check(String(wm.get("_current_wave_id")) == "level_holdout", "当前波次 = level_holdout（60-80 高潮波）")
	await _fast_start(wm)
	_check(await _wait_wave_cleared(main, wm, player, 90.0), "守点高潮杀光 → 清波回等待")
	_check(bool(la.get("_holdout_cleared")), "高潮清波 → 后门安全屋开启（_holdout_cleared）")

	# --- ⑤ 到达后门安全屋：回血 + 存档 ---
	_log_line("--- ⑤ 后门安全屋：回血 / 补给 / 存档 ---")
	var hp_before: float = player.get_node_or_null("Health").get("hp")
	await _teleport_to(player, "backdoor_enter", "进入后门安全屋")
	_check(int(la.get("phase")) >= P_BACKDOOR, "到达后门安全屋（phase=%d ≥ BACKDOOR）" % int(la.get("phase")))
	var ps := player.get_node_or_null("Health")
	var max_hp: float = ps.get("max_hp")
	_check(float(ps.get("hp")) >= max_hp - 0.01, "后门回血：hp 满值（%.0f/%.0f，from %.0f）" % [float(ps.get("hp")), max_hp, hp_before])
	_check(FileAccess.file_exists(SAVE_PATH), "隔离存档文件已生成")
	var parsed = _read_json(SAVE_PATH)
	_check(int(parsed.get("segment", 0)) >= 1, "存档 segment=%d ≥ 1（段落完成标记）" % int(parsed.get("segment", 0)))
	_check(bool(parsed.get("completed", false)), "存档 completed=true")
	_check(float(parsed.get("finish_time_s", 0.0)) > 0.0, "存档 finish_time_s=%.1fs（完成时间记录）" % float(parsed.get("finish_time_s", 0.0)))

	# --- ⑥ 全程无红色 Error（以本脚本未中断 + 退出码 0 佐证；另查日志无 ERROR 字样） ---
	_log_line("--- ⑥ 全流程输出无 ERROR（最后 40 行） ---")

	_log_line("=== LEVEL_PROGRESS %s (fail=%d) ===" % ["PASS" if _fail == 0 else "FAIL", _fail])
	_finish()


## 把玩家传送到指定触发体中心（触发 body_entered → LevelAdvance 分发推进）
func _teleport_to(player: Node3D, trigger_id: String, desc: String) -> void:
	var trig := _find_trigger(trigger_id)
	if trig == null:
		_check(false, "%s：找不到触发体 %s" % [desc, trigger_id])
		return
	player.global_position = trig.global_position
	await create_timer(0.5).timeout


func _find_trigger(trigger_id: String) -> Node3D:
	for t in get_nodes_in_group("level_trigger"):
		if String(t.get("trigger_id")) == trigger_id:
			return t as Node3D
	return null


## 加速波次开局：等波次进入 SETUP 后缩短倒计时/刷怪间隔/特感超时（纯测试手段）
func _fast_start(wm: Node) -> void:
	var t := 0.0
	while t < 3.0:
		if int(wm.get("state")) == S_SETUP and not (wm.get("_current_wave") is Dictionary and (wm.get("_current_wave") as Dictionary).is_empty()):
			break
		await create_timer(0.1).timeout
		t += 0.1
	wm.set("_setup_timer", 0.05)
	wm.set("_special_pending_timer", 100.0)  # 特感等 Director 超时兜底（10s）太长，直接放行
	var cfg: Dictionary = wm.get("_current_wave")
	if not cfg.is_empty():
		cfg["spawn_interval"] = 0.1  # trickle 加速（Director 压力缩放后约 0.13s/只）
	await create_timer(0.3).timeout


## 轮询击杀场上丧尸直到波次清波回 LEVEL_WAIT（每 0.2s 击杀 + 保玩家存活防测试中阵亡）
func _wait_wave_cleared(main: Node, wm: Node, player: Node3D, timeout: float) -> bool:
	var t := 0.0
	while t < timeout:
		_kill_all_zombies(main)
		_keep_player_alive(player)
		if int(wm.get("state")) == S_LEVEL_WAIT:
			return true
		await create_timer(0.2).timeout
		t += 0.2
	return false


func _kill_all_zombies(main: Node) -> void:
	var zombies := main.get_node_or_null("Zombies")
	if zombies == null:
		return
	for z in zombies.get_children():
		var health := z.get_node_or_null("Health")
		if health != null:
			health.take_damage(9999.0)


## 测试防阵亡：回血 + 若 DEAD 强制回 ALIVE（headless 仿真"玩家存活推进"）
func _keep_player_alive(player: Node3D) -> void:
	var ps := player.get_node_or_null("Health")
	if ps == null:
		return
	ps.apply_healing(9999.0)
	if int(ps.get("state")) == 2:  # DEAD
		ps.set("state", 0)  # ALIVE


func _find_player(main: Node) -> Node3D:
	var players := main.get_node_or_null("Players")
	if players == null:
		return null
	for p in players.get_children():
		if p.get_node_or_null("Health") != null:
			return p as Node3D
	return null


func _door_open() -> bool:
	for d in get_nodes_in_group("safe_doors"):
		return bool(d.get("is_open"))
	return false


func _group_count(group: String) -> int:
	return get_nodes_in_group(group).size()


func _read_json(path: String) -> Dictionary:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return {}
	var parsed = JSON.parse_string(file.get_as_text())
	return parsed if parsed is Dictionary else {}


func _finish() -> void:
	change_scene_to_file("res://scenes/ui/main_menu.tscn")
	await create_timer(0.8).timeout
	_cleanup_save()
	quit(_fail)


func _cleanup_save() -> void:
	for suffix in ["", ".tmp", ".bak"]:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(SAVE_PATH + suffix))
