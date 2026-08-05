extends SceneTree
# 临时仿真脚本（M2-S1）：headless 跑主场景，程序化击杀验证 3 波全流程至通关。
# 用法：godot --headless --path . --script tools/debug_wave_flow.gd
# 验证：E3 3 波递进（试探10/警戒18/潮涌30 burst）→ 通关；Intermission N 键提前跳波
# 状态枚举：SETUP=0 WAVE_ACTIVE=1 WAVE_CLEARED=2 INTERMISSION=3 VICTORY=4

const MAIN_SCENE := "res://scenes/main/main.tscn"
const WAVE_MANAGER_PATH := "Gameplay/WaveManager"
const LOG_PATH := "user://wave_flow_progress.log"

var _log := FileAccess.open(LOG_PATH, FileAccess.WRITE)


func _log_line(s: String) -> void:
	print(s)
	if _log != null:
		_log.store_line(s)
		_log.flush()

var _nm: Node = null


func _initialize() -> void:
	_nm = root.get_node_or_null("NetworkManager")
	call_deferred("_run")


func _run() -> void:
	_log_line("=== WAVE_FLOW START ===")
	change_scene_to_file(MAIN_SCENE)
	await create_timer(2.0).timeout
	var main := current_scene
	var wm := main.get_node_or_null(WAVE_MANAGER_PATH)
	var last_wave_active := -1
	for i in 400:  # 每 0.5s 一轮，最多 200s
		await create_timer(0.5).timeout
		if i % 20 == 0:
			_log_line("[FLOW] t=%ds state=%s wave=%s spawned=%s killed=%s" % [
				int(i * 0.5), wm.get("state"), wm.get("current_wave_index"),
				wm.get("_spawned_count"), wm.get("_killed_count")])
		_kill_all(main)
		var st: int = wm.get("state")
		var wi: int = wm.get("current_wave_index")
		if st == 3:  # INTERMISSION：模拟调试键 N（_begin_wave 下一波）提前进下一波
			wm._begin_wave(wi + 1)
			_dump("SKIP_INTERMISSION", main)
		elif st == 4:  # VICTORY：3 波打完通关
			_dump("VICTORY", main)
			break
		elif st == 1 and wi != last_wave_active:
			last_wave_active = wi
			_dump("WAVE_ACTIVE_%d" % (wi + 1), main)
	_log_line("=== WAVE_FLOW END ===")
	change_scene_to_file("res://scenes/ui/main_menu.tscn")
	await create_timer(0.8).timeout
	quit(0)


func _kill_all(main: Node) -> void:
	var zombies := main.get_node_or_null("Zombies")
	if zombies == null:
		return
	for z in zombies.get_children():
		var health := z.get_node_or_null("Health")
		if health != null:
			health.take_damage(9999.0)


func _dump(tag: String, main: Node) -> void:
	var wm := main.get_node_or_null(WAVE_MANAGER_PATH)
	if wm == null:
		return
	_log_line("[%s] state=%s wave_index=%s spawned=%s killed=%s" % [
		tag, wm.get("state"), wm.get("current_wave_index"),
		wm.get("_spawned_count"), wm.get("_killed_count")])
	var hud := main.get_node_or_null("HUD") as CanvasLayer
	if hud == null:
		return
	var banner := hud.get_node_or_null("Root/WaveBanner") as Label
	var countdown := hud.get_node_or_null("Root/WaveCountdown") as Label
	var toast := hud.get_node_or_null("Root/WaveToast") as Label
	_log_line("[%s] HUD banner='%s' visible=%s" % [tag, banner.text, banner.visible])
	_log_line("[%s] HUD countdown='%s' visible=%s" % [tag, countdown.text, countdown.visible])
	_log_line("[%s] HUD toast='%s' visible=%s" % [tag, toast.text, toast.visible])
