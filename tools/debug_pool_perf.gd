extends SceneTree
## debug_pool_perf.gd — M3-S4 加压/性能/对象池自测（扩展版，替代 M2-S3 版）
## 用法：godot --headless --path . --script tools/debug_pool_perf.gd
## 验证：
##  ① 30/60/100 只普通丧尸同屏 headless CPU 帧率（fps avg/min + 最大单帧 delta + CPU 帧时间）
##     判据：100 只 CPU 帧时间 < 16.7ms（60fps 预算）→ 简化方案足够，MultiMesh 延后（M3 任务卡 §2-S4）
##  ② 每轮击杀 → Zombies 容器回落 0、池 idle=128/active=0（无节点泄漏）
##  ③ 池复用再刷 100 → 抽查复位质量（hp/state/collision/visible/scale，无"死尸复活"）
## 注意：加压波次强制纯 common composition（特感行为由 debug_charger/debug_spitter 独立覆盖）；
##       工具脚本不引用游戏类（M2-S3 铁律），一律动态访问。
## 输出：标准输出 + user://pool_perf_progress.log（帧时间曲线数据）

const MAIN_SCENE := "res://scenes/main/main.tscn"
const WAVE_MANAGER_PATH := "Gameplay/WaveManager"
const POOL_PATH := "Gameplay/WaveManager/ZombiePool"
const MEASURE_SECONDS := 5.0   # 每档采样时长
const CLEANUP_WAIT := 2.6      # 秒，> DEATH_CLEANUP_DELAY 1.5s 回池完成
const POOL_CAPACITY := 128     # 对象池容量（M3-S4 实测确认：100 峰值 + 特感分离够用）
const TARGETS := [30, 60, 100] # 加压档位（M3 任务卡 §2-S4：30 基准 / 60 常驻 / 100 峰值）
const TEST_SAVE_PATH := "user://save/debug_pool_perf_progress.json"

var _fail := 0
var _log := FileAccess.open("user://pool_perf_progress.log", FileAccess.WRITE)


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
	_log_line("=== POOL_PERF START (M3-S4 30/60/100 加压) ===")
	_cleanup_test_save()
	var game_state := root.get_node_or_null("GameState")
	if game_state != null:
		game_state.set("checkpoint_path", TEST_SAVE_PATH)
	change_scene_to_file(MAIN_SCENE)
	await create_timer(2.0).timeout
	var main := current_scene
	var wm := main.get_node_or_null(WAVE_MANAGER_PATH)
	var zombies := main.get_node_or_null("Zombies")
	var pool := main.get_node_or_null(POOL_PATH)
	_check(wm != null and zombies != null and pool != null, "场景就绪：WaveManager/Zombies/ZombiePool 存在")
	if wm == null or zombies == null or pool == null:
		_finish()
		return
	# 本工具验证对象池原始 100 怪能力；正式玩法的动态 40–60 上限在独立 Director 测试覆盖。
	var director := wm.get("_director") as Node
	if director != null:
		director.set("_degrade_enabled", false)
	_check(pool.get("_pool").size() == POOL_CAPACITY,
		"对象池容量 %d（M3-S4 确认：100 峰值 + 特感不池化 = 够用）" % pool.get("_pool").size())

	# --- 30 → 60 → 100 逐档加压采样 ---
	var perf_rows := {}
	for n in TARGETS:
		var row := await _run_pressure_round(wm, zombies, pool, n)
		perf_rows[n] = row
		if row["child_ok"] == false:
			_log_line("  !! 本档容器数不符，中止后续加压")
			break

	# --- 加压汇总 ---
	_log_line("--- 加压汇总（headless CPU 帧率，M3 任务卡 §2-S4 判定：<16.7ms=60fps 达标） ---")
	for n in TARGETS:
		var r: Dictionary = perf_rows.get(n, {})
		if r.is_empty():
			continue
		_log_line("  [%3d 只] fps_avg=%.1f fps_min=%.1f CPU帧时间≈%.2fms 最大单帧=%.1fms physics_tick=%d/%.0fs" % [
			n, r["fps_avg"], r["fps_min"], r["frame_ms"], r["delta_max_ms"], r["phys_ticks"], MEASURE_SECONDS])
	_check(float(perf_rows.get(30, {}).get("frame_ms", INF)) < 16.7, "30 只 CPU 帧时间 < 16.7ms（基准）")
	_check(float(perf_rows.get(60, {}).get("frame_ms", INF)) < 16.7, "60 只 CPU 帧时间 < 16.7ms（常驻目标）")
	_check(float(perf_rows.get(100, {}).get("frame_ms", INF)) < 16.7, "100 只 CPU 帧时间 < 16.7ms（峰值上限）")
	_check(int(perf_rows.get(100, {}).get("phys_ticks", 0)) >= int(MEASURE_SECONDS * 60.0) - 3,
		"100 只 physics 无滞后：%d ticks / %.0fs（60Hz 期望 ~%d）" % [
			int(perf_rows.get(100, {}).get("phys_ticks", 0)), MEASURE_SECONDS, int(MEASURE_SECONDS * 60.0)])
	if float(perf_rows.get(100, {}).get("frame_ms", INF)) < 16.7:
		_log_line("  结论：100 只独立实例 CPU 帧时间 <16.7ms → 简化方案达标，MultiMesh 延后（记录实测数据）")

	# --- 池复用再刷 100 → 抽查复位质量（无死尸复活） ---
	_log_line("--- 池复用：再刷 100 只 → 抽查复位质量 ---")
	wm._waves[2] = _pure_wave(100)
	wm._begin_wave(2)
	wm.set("_setup_timer", 0.05)
	await _wait_concurrent(wm, 100, 20.0)
	_check(zombies.get_child_count() == 100, "池复用 100 只出池（子节点数=%d）" % zombies.get_child_count())
	var dead_resurrect := 0
	var sample_ok := 0
	var bad_states := {}
	for z in zombies.get_children():
		var health := z.get_node_or_null("Health")
		var ai := z.get_node_or_null("AI")
		var hp: float = health.get("hp")
		var max_hp: float = health.get("max_hp")
		var ok := health != null and hp == max_hp
		ok = ok and ai != null and int(ai.get("state")) != 3  # 不是 DEAD 即未复活
		ok = ok and int(z.collision_layer) == 4 and int(z.collision_mask) == 5
		ok = ok and z.visible and (z.get_node("Visual") as Node3D).scale == Vector3.ONE
		if ok:
			sample_ok += 1
		else:
			dead_resurrect += 1
			var st: int = int(ai.get("state"))
			bad_states[st] = int(bad_states.get(st, 0)) + 1
	_log_line("  复位合格 %d/100，异常 %d（按 state 分布=%s）" % [sample_ok, dead_resurrect, str(bad_states)])
	_check(dead_resurrect == 0, "无死尸复活：hp/state/collision/visible/scale 全部复位")
	for z in zombies.get_children():
		var health := z.get_node_or_null("Health")
		if health != null:
			health.take_damage(9999.0)
	await create_timer(CLEANUP_WAIT).timeout
	_check(zombies.get_child_count() == 0, "复用轮击杀后容器回落为 0（实际=%d）" % zombies.get_child_count())
	_check(pool.get("_pool").size() == POOL_CAPACITY and pool.get("_active").size() == 0,
		"池状态 idle=%d/active=%d（无泄漏）" % [pool.get("_pool").size(), pool.get("_active").size()])

	_log_line("=== POOL_PERF %s (fail=%d) ===" % ["PASS" if _fail == 0 else "FAIL", _fail])
	_finish()


## 单档加压：刷 N 只 → 采样 MEASURE_SECONDS → 击杀回落 → 返回统计
func _run_pressure_round(wm: Node, zombies: Node, pool: Node, n: int) -> Dictionary:
	_log_line("--- 第 %d 档：纯 common 同屏 %d（burst，concurrent_cap=%d） ---" % [n, n, n])
	wm._waves[2] = _pure_wave(n)
	wm._begin_wave(2)
	wm.set("_setup_timer", 0.05)
	await _wait_concurrent(wm, n, 20.0)
	var child_ok := zombies.get_child_count() == n
	_check(child_ok, "%d 只同时在场（Zombies 子节点数=%d）" % [n, zombies.get_child_count()])
	if not child_ok:
		return {"child_ok": false}

	# 采样：逐帧记录 delta，统计 avg/min FPS、最大单帧与 physics tick 数（60Hz 下无滞后=300/5s）
	var fps_min := INF
	var fps_sum := 0.0
	var fps_n := 0
	var delta_max_ms := 0.0
	var delta_sum_ms := 0.0
	var phys_start := Engine.get_physics_frames()
	var last_tick := Time.get_ticks_usec()
	var end := Time.get_ticks_msec() + int(MEASURE_SECONDS * 1000.0)
	while Time.get_ticks_msec() < end:
		await process_frame
		var now := Time.get_ticks_usec()
		var d_ms := float(now - last_tick) / 1000.0
		delta_max_ms = maxf(delta_max_ms, d_ms)
		delta_sum_ms += d_ms
		last_tick = now
		var f := Engine.get_frames_per_second()
		fps_min = minf(fps_min, f)
		fps_sum += f
		fps_n += 1
	var phys_ticks := Engine.get_physics_frames() - phys_start
	var fps_avg := fps_sum / maxi(fps_n, 1)
	var frame_ms := delta_sum_ms / maxi(fps_n, 1)
	_log_line("  fps_avg=%.1f fps_min=%.1f 平均帧=%.2fms 最大单帧=%.1fms physics_tick=%d (CPU 帧时间 ≈ %.2fms)"
		% [fps_avg, fps_min, frame_ms, delta_max_ms, phys_ticks, 1000.0 / maxf(fps_avg, 0.001)])
	_check(fps_min >= 60.0, "headless CPU 帧率 min %.1f >= 60（60fps 可行性）" % fps_min)

	# 击杀 N 只 → 容器回落 + 池状态
	for z in zombies.get_children():
		var health := z.get_node_or_null("Health")
		if health != null:
			health.take_damage(9999.0)
	await create_timer(CLEANUP_WAIT).timeout
	_check(zombies.get_child_count() == 0, "击杀 %d 只后容器回落为 0（实际=%d）" % [n, zombies.get_child_count()])
	_check(pool.get("_pool").size() == POOL_CAPACITY and pool.get("_active").size() == 0,
		"池状态 idle=%d/active=%d" % [pool.get("_pool").size(), pool.get("_active").size()])
	return {
		"child_ok": true, "fps_avg": fps_avg, "fps_min": fps_min,
		"frame_ms": frame_ms, "delta_max_ms": delta_max_ms, "phys_ticks": phys_ticks,
	}


## 纯 common 加压波（特感隔离：行为由 debug_charger/debug_spitter 覆盖）
func _pure_wave(n: int) -> Dictionary:
	return {
		"id": "wave_perf_%d" % n, "name": "加压%d" % n,
		"composition": {"common": n},
		"concurrent_cap": n,
		"spawn_style": "burst",
		"spawn_interval": 0.1,
		"cleared_when": {"type": "all_spawned_killed"},
		"reward": {"health_packs": 0, "ammo": 0},
	}


## 轮询直到场上丧尸数达到 target（或超时秒数）
func _wait_concurrent(wm: Node, target: int, timeout: float) -> void:
	var t := 0.0
	while t < timeout:
		if int(wm.get("_concurrent_count")) >= target:
			return
		await create_timer(0.1).timeout
		t += 0.1


func _finish() -> void:
	change_scene_to_file("res://scenes/ui/main_menu.tscn")
	await create_timer(0.8).timeout
	_cleanup_test_save()
	quit(_fail)


func _cleanup_test_save() -> void:
	for suffix in ["", ".tmp", ".bak"]:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(TEST_SAVE_PATH + suffix))
