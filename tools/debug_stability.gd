extends SceneTree
## debug_stability.gd — M3-S8 稳定性长局循环自测（headless，服务器权威单机语义）
## 用法：godot --headless --path . --script tools/debug_stability.gd [-- --rounds 6]
## 验证（任务卡 §2-S8 I4：10 局×20 分钟无闪退；headless 自动化循环）：
##  ① 连续 N 局（默认 6，--rounds 可配）推进制关卡完整通关：
##     安全屋→货场(YARD)→货运通道(CORRIDOR)→通道中段触发第一波(level_horde_01)清波
##     →装卸广场守点高潮(level_holdout)清波→后门安全屋(回血/存档/段落完成)
##  ② 每局后检查无泄漏：Zombies 容器回落 0、ZombiePool idle=128/active=0、
##     Performance OBJECT_NODE_COUNT 局间稳定（不随局数线性增长）
##  ③ 记录每局完成时间与状态；退出码 0 = 全部通过（配合 bash 侧 grep ERROR 计数做
##     "无 ERROR 累积"证据）；脚本持续运行本身即"无崩溃"证据
## 注意：工具脚本不引用游戏类（编译期 autoload 未注册，M2-S3 铁律），一律动态访问；
##       玩家用传送模拟推进（不走物理路径，M3-S5 实测 Area3D body_entered 对传送可触发）；
##       波次间保持玩家存活（轮询回血防测试中阵亡卡关）。
## 输出：标准输出 + user://stability_progress.log

const MAIN_SCENE := "res://scenes/main/main.tscn"
const LEVEL_ADVANCE_PATH := "Gameplay/LevelAdvance"
const WAVE_MANAGER_PATH := "Gameplay/WaveManager"
const ZOMBIE_POOL_PATH := "Gameplay/WaveManager/ZombiePool"
const SAVE_PATH := "user://save/debug_stability_progress.json"
const SCENE_READY_WAIT := 2.0   # 秒，切场景后等待装配（main.gd 生成玩家 / 池预实例化）
const TRIGGER_WAIT := 0.5       # 秒，传送后等 body_entered 触发
const CLEANUP_WAIT := 3.0       # 秒，> 特感 die_clear_s 2.5s，死亡淡出完成
const DEFAULT_ROUNDS := 6       # 默认局数（任务卡 5-10 局验收范围）
# 阶段枚举（level_advance.gd Phase）：SAFE_ROOM=0 YARD=1 CORRIDOR=2 PLAZA=3 BACKDOOR=4 COMPLETE=5
# 波次状态（wave_manager.gd State）：SETUP=0 ... LEVEL_WAIT=5
const P_YARD := 1
const P_CORRIDOR := 2
const S_SETUP := 0
const S_LEVEL_WAIT := 5

var _fail := 0
var _log := FileAccess.open("user://stability_progress.log", FileAccess.WRITE)
var _rounds := DEFAULT_ROUNDS
var _stable_nodes: Array = []   # 每局稳定点 OBJECT_NODE_COUNT（跨局泄漏辅助判定）


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
	# 解析 --rounds N（-- 后用户参数，Godot 4 OS.get_cmdline_user_args）
	var args := OS.get_cmdline_user_args()
	for i in args.size():
		if args[i] == "--rounds" and i + 1 < args.size():
			_rounds = maxi(1, int(args[i + 1]))
	call_deferred("_run")


func _run() -> void:
	_log_line("=== STABILITY START (M3-S8 长局循环, rounds=%d) ===" % _rounds)
	var game_state := root.get_node_or_null("GameState")
	if game_state != null:
		game_state.set("checkpoint_path", SAVE_PATH)
	var round_times: Array = []   # 每局 [序号, 耗时s, 状态字符串]
	for round_no in range(1, _rounds + 1):
		var t0 := Time.get_ticks_msec()
		var status := await _play_one_round(round_no)
		var elapsed := float(Time.get_ticks_msec() - t0) / 1000.0
		round_times.append([round_no, elapsed, status])
		_log_line("[ROUND %d] 完成 耗时=%.1fs 状态=%s" % [round_no, elapsed, status])
		if status != "PASS":
			break  # 某局中断：不再继续，如实记录失败局数
		await create_timer(0.5).timeout  # 局间缓冲

	_log_line("--- 逐局汇总 ---")
	var passed := 0
	for row in round_times:
		_log_line("  局%d: %.1fs %s" % [row[0], row[1], row[2]])
		if row[2] == "PASS":
			passed += 1
	_check(passed == _rounds, "全部 %d 局通关（通过 %d/%d）" % [_rounds, passed, _rounds])
	# 跨局节点稳定判定：稳定点 node_count 无随局数线性增长（泄漏辅助证据）
	var min_nodes := 1 << 30   # 大初始值（mini 为 int 比较，INF 转 int 会变负数下界）
	var max_nodes := 0
	for n in _stable_nodes:
		min_nodes = mini(min_nodes, n)
		max_nodes = maxi(max_nodes, n)
	if _stable_nodes.size() >= 2:
		_log_line("  稳定点 node_count: %s（min=%d max=%d 波动=%d）" % [str(_stable_nodes), min_nodes, max_nodes, max_nodes - min_nodes])
		_check(max_nodes - min_nodes <= 80,
			"OBJECT_NODE_COUNT 局间波动 ≤80（无随局数增长的节点泄漏，波动=%d）" % (max_nodes - min_nodes))
	else:
		_check(false, "不足 2 局稳定点数据，无法判定跨局节点泄漏")
	_log_line("=== STABILITY %s (fail=%d, rounds=%d) ===" % ["PASS" if _fail == 0 else "FAIL", _fail, _rounds])
	_finish()


## 单局：加载主场景 → 三段式推进通关 → 局后泄漏检查 → 返回状态字符串
func _play_one_round(round_no: int) -> String:
	_log_line("--- 局 %d：加载主场景 ---" % round_no)
	_cleanup_save()
	change_scene_to_file(MAIN_SCENE)
	await create_timer(SCENE_READY_WAIT).timeout
	var main := current_scene
	if main == null:
		_log_line("  [FAIL] 主场景加载失败（null）")
		return "LOAD_FAIL"
	var la := main.get_node_or_null(LEVEL_ADVANCE_PATH)
	var wm := main.get_node_or_null(WAVE_MANAGER_PATH)
	var pool := main.get_node_or_null(ZOMBIE_POOL_PATH)
	var zombies := main.get_node_or_null("Zombies")
	var player := _find_player(main)
	_check(la != null and wm != null and pool != null and zombies != null and player != null,
		"场景就绪：LevelAdvance/WaveManager/ZombiePool/Zombies/玩家 存在")
	if la == null or wm == null or pool == null or zombies == null or player == null:
		return "SETUP_FAIL"
	_check(int(la.get("phase")) == 0, "初始阶段 = 开场安全屋（SAFE_ROOM）")
	_check(bool(wm.get("level_mode")), "推进制关卡模式开启（level_mode=true）")
	_stable_nodes.append(int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT)))

	# --- 三段式推进：安全屋门→货场→通道→第一波→守点高潮→后门安全屋 ---
	await _teleport_to(player, "safe_exit", "靠近安全屋门")
	_check(int(la.get("phase")) == P_YARD, "安全屋门开启 → 货场（YARD）")
	await _teleport_to(player, "corridor_enter", "进入货运通道入口")
	_check(int(la.get("phase")) == P_CORRIDOR, "进入货运通道（CORRIDOR）")
	await _teleport_to(player, "corridor_mid", "进入通道中段")
	_check(String(wm.get("_current_wave_id")) == "level_horde_01", "第一波触发（level_horde_01）")
	await _fast_start(wm)
	_check(await _wait_wave_cleared(wm, player, 60.0), "第一波清波 → 回 LEVEL_WAIT")
	await _teleport_to(player, "plaza_enter", "进入装卸广场")
	_check(int(la.get("phase")) == 3, "进入装卸广场（PLAZA，守点区）")
	_check(String(wm.get("_current_wave_id")) == "level_holdout", "守点高潮触发（level_holdout 60+2）")
	await _fast_start(wm)
	_check(await _wait_wave_cleared(wm, player, 90.0), "守点高潮清波 → 回 LEVEL_WAIT")
	_check(bool(la.get("_holdout_cleared")), "高潮清波 → 后门安全屋开启（_holdout_cleared）")
	await _teleport_to(player, "backdoor_enter", "到达后门安全屋")
	_check(int(la.get("phase")) >= 4, "段落完成（phase=%d ≥ BACKDOOR）" % int(la.get("phase")))
	_check(FileAccess.file_exists(SAVE_PATH), "隔离存档生成")

	# --- 局后泄漏检查：等死亡淡出完成 → 容器回落 / 池状态 ---
	await create_timer(CLEANUP_WAIT).timeout
	_check(zombies.get_child_count() == 0, "Zombies 容器回落 0（实际=%d，无丧尸残留）" % zombies.get_child_count())
	_check(int(pool.get("_pool").size()) == 128 and int(pool.get("_active").size()) == 0,
		"池状态 idle=%d/active=%d（无泄漏）" % [pool.get("_pool").size(), pool.get("_active").size()])
	# 掉落物生命周期 30s 内自清，切场景即整体释放；此处只记录不判定
	var pickups := main.get_node_or_null("World/Pickups")
	_log_line("  信息：Pickups 残留=%d（切场景释放，非泄漏判定项）" % (pickups.get_child_count() if pickups != null else -1))
	return "PASS"


## 把玩家传送到指定触发体中心（触发 body_entered → LevelAdvance 分发推进）
func _teleport_to(player: Node3D, trigger_id: String, desc: String) -> void:
	var trig := _find_trigger(trigger_id)
	if trig == null:
		_log_line("  !! %s：找不到触发体 %s" % [desc, trigger_id])
		return
	player.global_position = trig.global_position
	await create_timer(TRIGGER_WAIT).timeout


func _find_trigger(trigger_id: String) -> Node3D:
	for t in get_nodes_in_group("level_trigger"):
		if String(t.get("trigger_id")) == trigger_id:
			return t as Node3D
	return null


## 加速波次开局：等 SETUP 就绪后缩短倒计时/刷怪间隔/放行特感（纯测试手段）
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
		cfg["spawn_interval"] = 0.1  # trickle/burst 统一加速
	await create_timer(0.3).timeout


## 轮询击杀场上丧尸直到波次清波回 LEVEL_WAIT（每 0.2s 击杀 + 保玩家存活防测试中阵亡）
func _wait_wave_cleared(wm: Node, player: Node3D, timeout: float) -> bool:
	var main := current_scene
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


func _finish() -> void:
	change_scene_to_file("res://scenes/ui/main_menu.tscn")
	await create_timer(0.8).timeout
	var final_scene := current_scene
	# SceneTree.quit() 不会替测试脚本排空当前场景的延迟删除；显式释放并跨物理帧排空，
	# 避免最后一局的拾取物/播放器随场景滞留到引擎退出检查。
	if final_scene != null:
		current_scene = null
		final_scene.queue_free()
	await process_frame
	await physics_frame
	await process_frame
	# --fixed-fps 会让上述帧在数毫秒内跑完；给音频后端真实时间释放已停止的短音效。
	OS.delay_msec(1000)
	_cleanup_save()
	if _log != null:
		_log.close()
		_log = null
	quit(_fail)


func _cleanup_save() -> void:
	for suffix in ["", ".tmp", ".bak"]:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(SAVE_PATH + suffix))
