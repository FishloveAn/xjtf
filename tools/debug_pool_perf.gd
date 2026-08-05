extends SceneTree
# 临时仿真脚本（M2-S3b）：headless 实测波3（burst 30）性能 + 对象池无泄漏/无死尸复活验证。
# 用法：godot --headless --path . --script tools/debug_pool_perf.gd
# 验证：
#  ① 30 只同时在场（Zombies 容器子节点数 == 30）期间无报错；
#  ② headless CPU 帧率采样（headless 无渲染，FPS 反映 CPU 帧时间；
#     若 30 只阶段 min FPS ≥ 60 → 真实机器 60fps 可行性高，MultiMesh 可延后，记录实测数据）；
#  ③ 击杀 30 只 → 容器子节点数回落为 0、池 idle=128/active=0（无泄漏、无泄漏节点）；
#  ④ 再次刷 30 只（池复用）→ 抽查复活丧尸 hp=100/state=IDLE/collision 恢复/visible（无"死尸复活"）；
#  ⑤ 反复 2 轮 3 波（配合 debug_wave_flow）由 debug_wave_flow 覆盖，本脚本专注单轮加压细节。

const MAIN_SCENE := "res://scenes/main/main.tscn"
const WAVE_MANAGER_PATH := "Gameplay/WaveManager"
const POOL_PATH := "Gameplay/WaveManager/ZombiePool"
const MEASURE_SECONDS := 5.0  # 30 只同屏采样时长

var _fail := 0


func _log_line(s: String) -> void:
	print(s)


func _check(cond: bool, label: String) -> void:
	if cond:
		_log_line("  [PASS] " + label)
	else:
		_fail += 1
		_log_line("  [FAIL] " + label)


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	_log_line("=== POOL_PERF START ===")
	change_scene_to_file(MAIN_SCENE)
	await create_timer(2.0).timeout
	var main := current_scene
	var wm := main.get_node_or_null(WAVE_MANAGER_PATH)
	var zombies := main.get_node_or_null("Zombies")
	var pool := main.get_node_or_null(POOL_PATH)
	_check(wm != null and zombies != null and pool != null, "场景就绪：WaveManager/Zombies/ZombiePool 存在")

	# --- 第一轮：跳到波3（潮涌 burst 30），加速 Setup 倒计时 ---
	_log_line("--- 第一轮：波3 burst 30 ---")
	wm._begin_wave(2)
	wm.set("_setup_timer", 0.05)
	await _wait_concurrent(wm, 30, 5.0)
	_check(wm.get("state") == 1, "波3 进入 WAVE_ACTIVE")
	_check(zombies.get_child_count() == 30, "30 只同时在场（Zombies 子节点数=%d）" % zombies.get_child_count())

	# --- 30 只同屏期间采样 headless CPU 帧率 ---
	_log_line("--- 30 只同屏 FPS 采样（%.1fs，headless CPU 帧率） ---" % MEASURE_SECONDS)
	var fps_min := INF
	var fps_sum := 0.0
	var fps_n := 0
	var delta_max := 0.0
	var last_tick := Time.get_ticks_usec()
	var end := Time.get_ticks_msec() + int(MEASURE_SECONDS * 1000.0)
	var guard := 0
	while Time.get_ticks_msec() < end and guard < 1000000:
		await process_frame
		guard += 1
		var now := Time.get_ticks_usec()
		delta_max = maxf(delta_max, float(now - last_tick) / 1000.0)
		last_tick = now
		var f := Engine.get_frames_per_second()
		fps_min = minf(fps_min, f)
		fps_sum += f
		fps_n += 1
	var fps_avg := fps_sum / maxi(fps_n, 1)
	_log_line("  fps_avg=%.1f fps_min=%.1f delta_max=%.2fms (CPU 帧时间 ≈ %.2fms)"
		% [fps_avg, fps_min, delta_max * 1000.0, 1000.0 / maxf(fps_avg, 0.001)])
	_log_line("  结论判据：min FPS >= 60 则 CPU 帧时间 < 16.7ms，真实 60fps 可行 → 简化方案足够，MultiMesh 延后")
	_check(fps_min >= 60.0, "headless CPU 帧率 min %.1f >= 60（60fps 可行性）" % fps_min)

	# --- 击杀 30 只 → 等回池 → 容器回落 ---
	_log_line("--- 击杀 30 只 → 容器回落验证 ---")
	for z in zombies.get_children():
		var health := z.get_node_or_null("Health")
		if health != null:
			health.take_damage(9999.0)
	await create_timer(2.5).timeout  # DEATH_CLEANUP_DELAY=1.5s 后回池完成
	_check(zombies.get_child_count() == 0, "击杀后 Zombies 容器回落为 0（实际=%d）" % zombies.get_child_count())
	_check(pool.get("_pool").size() == 128 and pool.get("_active").size() == 0,
		"池状态 idle=128/active=0（实际 idle=%d active=%d）" % [pool.get("_pool").size(), pool.get("_active").size()])

	# --- 第二轮：再刷 30 只（池复用）→ 抽查复位质量（无死尸复活） ---
	_log_line("--- 第二轮：池复用再刷 30 只 → 抽查复位 ---")
	wm._begin_wave(2)
	wm.set("_setup_timer", 0.05)
	await _wait_concurrent(wm, 30, 5.0)
	_check(zombies.get_child_count() == 30, "第二轮 30 只出池（子节点数=%d）" % zombies.get_child_count())
	var dead_resurrect := 0
	var sample_ok := 0
	var bad_states := {}
	for z in zombies.get_children():
		# 动态访问（避免工具脚本编译期引用丧尸类→启动阶段 autoload 未注册的编译错误）
		var health := z.get_node_or_null("Health")
		var ai := z.get_node_or_null("AI")
		var hp: float = health.get("hp")
		var max_hp: float = health.get("max_hp")
		# 注意：复活丧尸会立即追击玩家（CHASE/ATTACK 正常），"死尸复活"判定只看 state != DEAD(3)
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
	_log_line("  复位合格 %d/30，异常 %d（按 state 分布=%s）" % [sample_ok, dead_resurrect, str(bad_states)])
	_check(dead_resurrect == 0, "无死尸复活：hp/state/collision/visible 全部复位")

	# --- 第二轮击杀 → 再次回落 ---
	for z in zombies.get_children():
		var health := z.get_node_or_null("Health")
		if health != null:
			health.take_damage(9999.0)
	await create_timer(2.5).timeout
	_check(zombies.get_child_count() == 0, "第二轮击杀后容器回落为 0（实际=%d）" % zombies.get_child_count())

	_log_line("=== POOL_PERF %s (fail=%d) ===" % ["PASS" if _fail == 0 else "FAIL", _fail])
	change_scene_to_file("res://scenes/ui/main_menu.tscn")
	await create_timer(0.8).timeout
	quit(_fail)


## 轮询直到场上丧尸数达到 target（或超时秒数）
func _wait_concurrent(wm: Node, target: int, timeout: float) -> void:
	var t := 0.0
	while t < timeout:
		if int(wm.get("_concurrent_count")) >= target:
			return
		await create_timer(0.1).timeout
		t += 0.1
