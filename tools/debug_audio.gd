extends SceneTree
## debug_audio.gd — M3-S7 P1 音效接线自测（headless 仿真）
## 用法：godot --headless --path . --script tools/debug_audio.gd
## 验证：
##   A1 EVENT_MAP 新条目（zombie_growl/weapon_reload/weapon_reload_done/weapon_empty/wave_alarm）
##      素材文件真实存在（Kenney CC0 已入库）；缺失时走 SfxPool 静默容错不报错
##   A2 换弹触发链：空仓点击（weapon_empty）→ 自动换弹开始（weapon_reload）→ 上膛完成（weapon_reload_done）
##   A3 尸潮警报：_begin_wave 波次预告 → wave_alarm（2D 非定位，全端）
##   A4 丧尸嘶吼：AI._growl_timer 归零 → zombie_growl 广播播放（随机间隔 + 相位复位）
##   A5 同帧同事件限流：同帧连发 10 次 → _limit_counts ≤ EVENT_LIMIT(4)
## 注意：--script 工具脚本不静态引用游戏类（M2-S3 铁律：编译期拉游戏类会失败），一律动态访问；
##       素材播放检查用「播放器.stream 是否命中目标文件」而非 is_playing（规避短音效已播完时序）

const MAIN_SCENE := "res://scenes/main/main.tscn"
## P1 新事件 → 目标文件名（与 sfx_pool.gd EVENT_MAP 末尾对齐；用于素材存在性 + 播放命中判断）
const EVENT_FILES := {
	"zombie_growl": "sfx_zombie_growl_01.ogg",
	"weapon_reload": "sfx_weapon_reload_01.ogg",
	"weapon_reload_done": "sfx_weapon_reload_done_01.ogg",
	"weapon_empty": "sfx_weapon_empty_01.ogg",
	"wave_alarm": "sfx_wave_alarm_01.ogg",
}

var _failures := 0
var _log := FileAccess.open("user://audio_test_progress.log", FileAccess.WRITE)


func _log_line(s: String) -> void:
	print(s)
	if _log != null:
		_log.store_line(s)
		_log.flush()


func _check(cond: bool, label: String) -> void:
	if cond:
		_log_line("  [PASS] " + label)
	else:
		_failures += 1
		_log_line("  [FAIL] " + label)


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	_log_line("=== AUDIO TEST START ===")
	var sfx := root.get_node_or_null("SfxPool")
	_check(sfx != null, "SfxPool autoload 就绪")
	if sfx == null:
		_finish()
		return
	_check_event_files()

	change_scene_to_file(MAIN_SCENE)
	await create_timer(2.0).timeout
	var main := current_scene
	var weapon := _find_pistol(main)
	if weapon == null:
		_fail("主场景未找到武器（WeaponPivot/Pistol）")
		_finish()
		return

	# --- A2 换弹触发链：空仓点击 → 自动换弹开始 → 上膛完成 ---
	_log_line("--- A2 换弹触发链 ---")
	weapon.set("reloading", false)
	weapon.set("mag_current", 0)
	weapon.try_fire()  # 空仓：只播点击声 + 服务器走自动换弹
	_check(_stream_played(sfx, EVENT_FILES["weapon_empty"]), "空仓点击 weapon_empty 触发（无枪声）")
	await create_timer(0.1).timeout
	_check(_stream_played(sfx, EVENT_FILES["weapon_reload"]), "自动换弹开始 weapon_reload 触发（reloading 翻转）")
	var reload_time: float = weapon.get("reload_time")
	await create_timer(reload_time + 0.3).timeout
	_check(_stream_played(sfx, EVENT_FILES["weapon_reload_done"]), "上膛完成 weapon_reload_done 触发")

	# --- A3 尸潮警报（波次预告/高潮触发） ---
	_log_line("--- A3 尸潮警报 ---")
	var wm := main.get_node_or_null("Gameplay/WaveManager")
	_check(wm != null, "WaveManager 就绪")
	if wm != null:
		if bool(wm.get("level_mode")):
			wm.set("level_mode", false)  # 回归竞技场波次（debug_wave_flow 同口径）
		wm._begin_wave(0)  # 触发 wave_started 广播 → 全端播 wave_alarm
		await create_timer(0.1).timeout
		_check(_stream_played(sfx, EVENT_FILES["wave_alarm"]), "波次预告 wave_alarm 触发（2D 非定位）")

	# --- A4 丧尸嘶吼 ---
	_log_line("--- A4 丧尸嘶吼 ---")
	var zombies := main.get_node_or_null("Zombies")
	var zombie := _spawn_zombie(zombies)
	_check(zombie != null, "测试丧尸生成")
	if zombie != null:
		var growl_ctrl := zombie.get_node_or_null("AI/GrowlCtrl")
		_check(growl_ctrl != null, "GrowlCtrl 控制器挂接（zombie_growl.gd）")
		if growl_ctrl != null:
			growl_ctrl.set("_timer", 0.0)  # 注入归零 → 下帧嘶吼
			await create_timer(0.3).timeout
			_check(_stream_played(sfx, EVENT_FILES["zombie_growl"]), "丧尸嘶吼 zombie_growl 触发（3-5s 随机间隔 + 广播）")

	# --- A5 同帧同事件限流 ≤4 ---
	_log_line("--- A5 同帧限流 ---")
	var limit_count := _same_frame_limit(sfx, "zombie_growl")
	_check(limit_count <= 4, "同帧同事件限流 zombie_growl ×10 → 实际 %d ≤ 4（EVENT_LIMIT）" % limit_count)
	_stop_all_sfx(sfx)  # 停掉测试触发的播放，防 OGG 播放器退出时"resources still in use"

	_finish()


## 停掉 SfxPool 全部播放器（3D/2D）并清 stream：测试结尾必调，防播放态 OGG 在退出时泄漏
func _stop_all_sfx(sfx: Node) -> void:
	for p in sfx.get("_pool"):
		p.stop()
		p.set("stream", null)
	for p in sfx.get("_pool_2d"):
		p.stop()
		p.set("stream", null)


func _finish() -> void:
	_log_line("=== AUDIO TEST %s (fail=%d) ===" % ["PASS" if _failures == 0 else "FAIL", _failures])
	change_scene_to_file("res://scenes/ui/main_menu.tscn")
	await create_timer(0.8).timeout
	quit(_failures)


## A1：P1 新事件目标素材文件存在性（缺失时 SfxPool 静默跳过，不报错——容错已由 M1-S7 保证）
func _check_event_files() -> void:
	_log_line("--- A1 P1 事件素材存在性 ---")
	for event in EVENT_FILES:
		var fname: String = EVENT_FILES[event]
		var path := "res://assets/audio/sfx/" + fname
		var ok := FileAccess.file_exists(path)
		_check(ok, "事件 %s 素材 %s %s" % [event, fname, "就位" if ok else "缺失（静默跳过）"])


## 找玩家当前手枪（WeaponPivot 下，动态访问防编译期引类）
func _find_pistol(main: Node) -> Node:
	var players := main.get_node_or_null("Players") as Node3D
	if players == null or players.get_child_count() == 0:
		return null
	var player := players.get_child(0) as Node3D
	var pivot := player.get_node_or_null("WeaponPivot")
	if pivot == null:
		return null
	return pivot.get_node_or_null("Pistol")


## 直接实例化普通丧尸（不经池，行为测试用；服务器权威单机语义）
func _spawn_zombie(zombies: Node) -> Node3D:
	if zombies == null:
		return null
	var scene := load("res://scenes/enemies/zombie_common.tscn") as PackedScene
	if scene == null:
		return null
	var z := scene.instantiate()
	z.set_multiplayer_authority(1)
	zombies.add_child(z)
	z.global_position = Vector3(5.0, 0.0, 5.0)
	return z


## 检查 3D/2D 池中是否有播放器加载了目标文件（stream 命中即接线成功，不限 is_playing 时序）
func _stream_played(sfx: Node, fname: String) -> bool:
	for p in sfx.get("_pool"):
		if _stream_matches(p.get("stream"), fname):
			return true
	for p in sfx.get("_pool_2d"):
		if _stream_matches(p.get("stream"), fname):
			return true
	return false


func _stream_matches(stream: Variant, fname: String) -> bool:
	if stream == null:
		return false
	return String(stream.get("resource_path")).ends_with(fname)


## 同帧连发 N 次 → 读 _limit_counts 验证限流生效（同物理帧内 _limit_counts 不重置）
func _same_frame_limit(sfx: Node, event_name: String) -> int:
	for i in 10:
		sfx.play_3d(event_name)
	var counts: Dictionary = sfx.get("_limit_counts")
	return int(counts.get(event_name, 0))


func _fail(msg: String) -> void:
	_failures += 1
	printerr("[AUDIO] FAIL: " + msg)
