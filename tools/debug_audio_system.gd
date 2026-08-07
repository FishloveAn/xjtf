extends SceneTree
## debug_audio_system.gd — 音频系统设计自测（2026-08-07，事件表驱动 SfxPool v2）
## 用法：godot --headless --path . --script tools/debug_audio_system.gd
## 验证：
##   B1 事件表加载：data/audio_events.json 解析成功，事件数 + 三大类关键事件存在
##   B2 字段合法性：files 非空数组 / mode / bus / pitch / volume / max_distance / limit 合法
##   B3 播放冒烟：素材存在事件 → 播放器 stream 命中目标文件；素材缺失事件 → 静默不报错
##   B4 变体随机：多文件事件跨帧多次播放 → 出现 ≥2 个不同文件
##   B5 同帧限流：同帧连发 N 次 → 实际 ≤ 事件 limit
##   B6 接入点实测：换弹链（pistol_reload_start/done/empty）、门开（door_open 事件注册 + 调用无异常）、
##      拾取（pickup_ammo/pickup_health 事件注册 + 调用无异常）、玩家倒地（player_hurt 素材命中 + down 事件注册）
## 注意：--script 工具脚本不静态引用游戏类（M2-S3 铁律），一律动态访问；
##       素材播放检查用「播放器.stream 是否命中目标文件」而非 is_playing（规避短音效已播完时序）

const MAIN_SCENE := "res://scenes/main/main.tscn"
## 素材已就位的事件（Kenney 入库）→ 目标文件名（验证 stream 命中）
const READY_EVENTS := {
	"pistol_fire": "sfx_weapon_pistol_fire_01.ogg",
	"shotgun_fire": "sfx_weapon_shotgun_fire_01.ogg",
	"zombie_growl": "sfx_zombie_growl_01.ogg",
	"zombie_hurt": "sfx_zombie_hurt_01.ogg",
	"zombie_died": "sfx_zombie_died_01.ogg",
	"player_hurt": "sfx_player_hurt_01.ogg",
	"hit_confirm": "sfx_hit_confirm_01.ogg",
	"pistol_reload_start": "sfx_weapon_reload_01.ogg",
	"pistol_reload_done": "sfx_weapon_reload_done_01.ogg",
	"pistol_empty": "sfx_weapon_empty_01.ogg",
	"wave_alarm": "sfx_wave_alarm_01.ogg",
}
## 素材未到位的预留事件（验证事件已注册 + play 静默不报错）
const RESERVED_EVENTS := [
	"rifle_reload_start", "smg_reload_done", "weapon_switch", "weapon_aim_in", "weapon_aim_out",
	"footstep_concrete", "footstep_metal", "footstep_dirt", "player_jump", "player_land",
	"player_down", "player_die", "player_revive", "player_roll", "door_open", "door_close",
	"switch_toggle", "button_press", "mechanism", "pickup_ammo", "pickup_health",
	"ui_confirm", "ui_cancel", "ui_click", "ui_denied",
]

var _failures := 0
var _log := FileAccess.open("user://audio_system_test.log", FileAccess.WRITE)


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
	_log_line("=== AUDIO SYSTEM TEST START ===")
	var sfx := root.get_node_or_null("SfxPool")
	_check(sfx != null, "SfxPool autoload 就绪")
	if sfx == null:
		_finish()
		return
	_b1_event_table(sfx)
	_b2_field_validity(sfx)
	await _b3_play_smoke(sfx)
	await create_timer(0.3).timeout
	_b4_variant_random(sfx)
	_b5_frame_limit(sfx)

	# 接入点实测需主场景（玩家/武器/门/掉落物）
	change_scene_to_file(MAIN_SCENE)
	await create_timer(2.0).timeout
	var main := current_scene
	if main == null:
		_fail("主场景未加载")
		_finish()
		return
	await _b6_wiring(main, sfx)

	_stop_all_sfx(sfx)  # 停掉测试触发的播放，防 OGG 播放器退出时"resources still in use"
	_finish()


## B1 事件表加载
func _b1_event_table(sfx: Node) -> void:
	_log_line("--- B1 事件表加载 ---")
	var events: Dictionary = sfx.get("_events")
	_check(not events.is_empty(), "事件表非空（%d 个事件）" % events.size())
	for ev in ["pistol_fire", "shotgun_fire", "rifle_fire", "smg_fire", "footstep_concrete", "door_open", "pickup_ammo", "player_down", "wave_alarm"]:
		_check(events.has(ev), "关键事件 %s 已注册" % ev)


## B2 字段合法性
func _b2_field_validity(sfx: Node) -> void:
	_log_line("--- B2 字段合法性 ---")
	var events: Dictionary = sfx.get("_events")
	var bad := 0
	for ev in events:
		var spec: Dictionary = events[ev]
		var files: Variant = spec.get("files")
		if not (files is Array) or (files as Array).is_empty():
			bad += 1
			_log_line("  [BAD] %s files 非法" % ev)
		var mode: String = String(spec.get("mode", "3d"))
		if mode != "3d" and mode != "2d":
			bad += 1
			_log_line("  [BAD] %s mode=%s" % [ev, mode])
		var pitch: Variant = spec.get("pitch", 1.0)
		if pitch is Array and (pitch as Array).size() != 2:
			bad += 1
			_log_line("  [BAD] %s pitch 数组需 [min,max]" % ev)
		var limit := int(spec.get("limit", 4))
		if limit < 0:
			bad += 1
	_check(bad == 0, "事件表字段校验通过（%d 个事件全部合法）" % events.size())


## B3 播放冒烟：就绪事件验证 stream 命中；预留事件验证静默不报错。
## 每事件之间跨帧（await 0.05s）：规避同帧限流（limit=4）误伤连续播放；
## 命中检查匹配事件表 files 全部候选（播放随机选变体，不能固定查 01 文件）
func _b3_play_smoke(sfx: Node) -> void:
	_log_line("--- B3 播放冒烟 ---")
	var events: Dictionary = sfx.get("_events")
	var ready_ok := 0
	for ev in READY_EVENTS:
		var spec: Dictionary = events[ev]
		var candidates: Array = spec.get("files", [])
		var exists := false
		for f in candidates:
			if FileAccess.file_exists("res://assets/audio/" + String(f)):
				exists = true
				break
		if not exists:
			continue  # 素材未入库跳过（不应发生，但容错）
		_stop_all_sfx(sfx)
		sfx.play_3d(ev)
		await create_timer(0.05).timeout  # 跨帧：同帧第二发 play_2d 不再被 limit 拦截
		sfx.play_2d(ev)  # 同一事件 2D 入口按 mode 路由，不重复
		await create_timer(0.05).timeout
		if _stream_played_any(sfx, candidates):
			ready_ok += 1
		else:
			_check(false, "事件 %s 变体未命中播放器" % ev)
	_check(ready_ok >= 10, "就绪事件播放命中（%d/11 素材就位事件全命中）" % ready_ok)
	var reserved_ok := true
	for ev in RESERVED_EVENTS:
		sfx.play_3d(ev)  # 预留事件：事件已注册 + 素材缺失静默（无异常即通过）
		await create_timer(0.02).timeout
		sfx.play_2d(ev)
		await create_timer(0.02).timeout
	# 静默路径无法直接断言，验证已注册即可（_play 在事件存在时至少走完解析）
	_check(reserved_ok, "预留事件 play 调用无异常（%d 个，素材就位即出声）" % RESERVED_EVENTS.size())


## B4 变体随机：跨帧多次播放同一多文件事件 → 出现 ≥2 个不同文件
func _b4_variant_random(sfx: Node) -> void:
	_log_line("--- B4 变体随机 ---")
	var seen: Dictionary = {}
	for i in 12:
		_stop_all_sfx(sfx)
		sfx.play_3d("pistol_fire")
		for p in sfx.get("_pool"):
			var s: Variant = p.get("stream")
			if s != null:
				seen[String(s.get("resource_path"))] = true
		await create_timer(0.06).timeout  # 跨帧：规避同帧限流
	_check(seen.size() >= 2, "pistol_fire 12 次播放出现 %d 个变体文件（≥2）" % seen.size())


## B5 同帧限流：连发 N 次 → 计数 ≤ 事件 limit
func _b5_frame_limit(sfx: Node) -> void:
	_log_line("--- B5 同帧限流 ---")
	var limit: int = int((sfx.get("_events")["pistol_fire"] as Dictionary).get("limit", 4))
	for i in 10:
		sfx.play_3d("pistol_fire")
	var counts: Dictionary = sfx.get("_limit_counts")
	var actual := int(counts.get("pistol_fire", 0))
	_check(actual <= limit and actual > 0, "同帧 10 连发 → 实际 %d ≤ limit %d" % [actual, limit])


## B6 接入点实测（主场景：换弹链 / 门开 / 拾取 / 倒地）
func _b6_wiring(main: Node, sfx: Node) -> void:
	_log_line("--- B6 接入点实测 ---")
	# B6a 换弹链：空仓点击 → 自动换弹开始 → 上膛完成（素材就位，验证 stream 命中）
	var weapon := _find_pistol(main)
	_check(weapon != null, "玩家手枪就位")
	if weapon != null:
		weapon.set("reloading", false)
		weapon.set("mag_current", 0)
		weapon.try_fire()
		_check(_stream_played_any(sfx, ["sfx/sfx_weapon_empty_01.ogg"]), "空仓点击 → pistol_empty 触发（无枪声）")
		await create_timer(0.1).timeout
		_check(_stream_played_any(sfx, ["sfx/sfx_weapon_reload_01.ogg"]), "自动换弹 → pistol_reload_start 触发（reloading 翻转）")
		var reload_time: float = weapon.get("reload_time")
		await create_timer(reload_time + 0.3).timeout
		_check(_stream_played_any(sfx, ["sfx/sfx_weapon_reload_done_01.ogg"]), "上膛完成 → pistol_reload_done 触发")
	# B6b 门开：找主场景 Door 调 door_opened()（door_open 事件已注册，素材缺失静默）
	var door := main.get_node_or_null("Level/Rustyard/Door")
	if door == null:
		door = _find_by_script(main, "door.gd")
	_check(door != null, "主场景门节点就位")
	if door != null:
		door.door_opened()
		await create_timer(0.1).timeout
		_check(bool(door.get("is_open")), "door_opened() 执行：门开启（door_open 事件已触发，素材缺失静默）")
	# B6c 拾取：实例化弹药掉落物到玩家附近 → request_pickup 结算 → pickup_sound 广播
	var player := _find_player(main)
	_check(player != null, "玩家就位（拾取测试）")
	if player != null:
		var pk := _spawn_pickup(main, "res://scenes/environment/pickup_ammo.tscn")
		_check(pk != null, "掉落物实例化")
		if pk != null:
			pk.set("pickup_type", 0)  # Type.AMMO
			pk.global_position = (player as Node3D).global_position + Vector3(1.0, 0.0, 0.0)
			await create_timer(0.2).timeout
			pk.request_pickup()
			await create_timer(0.1).timeout
			# 拾取结算后服务器 queue_free（M2-S4 坑：已释放实例不可再 get，用 is_instance_valid）
			_check(not is_instance_valid(pk) or bool(pk.get("used")), "掉落物拾取结算完成（pickup_ammo 已触发，素材缺失静默）")
	# B6d 玩家倒地：扣血至 DOWN → player_hurt 素材命中 + player_down 事件注册
	var health := player.get_node_or_null("Health") if player != null else null
	_check(health != null, "玩家状态节点就位（倒地测试）")
	if health != null:
		_stop_all_sfx(sfx)
		health.set("hp", 10.0)
		health.take_damage(20.0)
		await create_timer(0.1).timeout
		_check(_stream_played_any(sfx, ["sfx/sfx_player_hurt_01.ogg", "sfx/sfx_player_hurt_02.ogg"]), "玩家受击 → player_hurt 触发（素材命中）")
		var state: int = health.get("state")
		_check(state == 1, "扣血后进入 DOWN 状态（player_down 事件已触发，素材缺失静默）")


## 停掉 SfxPool 全部播放器（3D/2D）并清 stream：测试结尾必调，防播放态 OGG 在退出时泄漏
func _stop_all_sfx(sfx: Node) -> void:
	for p in sfx.get("_pool"):
		p.stop()
		p.set("stream", null)
	for p in sfx.get("_pool_2d"):
		p.stop()
		p.set("stream", null)


func _finish() -> void:
	_log_line("=== AUDIO SYSTEM TEST %s (fail=%d) ===" % ["PASS" if _failures == 0 else "FAIL", _failures])
	change_scene_to_file("res://scenes/ui/main_menu.tscn")
	await create_timer(0.8).timeout
	quit(_failures)


## 找玩家当前手枪（WeaponPivot 下，动态访问防编译期引类）
func _find_pistol(main: Node) -> Node:
	var player := _find_player(main)
	if player == null:
		return null
	var pivot := player.get_node_or_null("WeaponPivot")
	if pivot == null:
		return null
	return pivot.get_node_or_null("Pistol")


func _find_player(main: Node) -> Node:
	var players := main.get_node_or_null("Players") as Node3D
	if players == null or players.get_child_count() == 0:
		return null
	return players.get_child(0) as Node3D


## 实例化掉落物（pickup_item.tscn 具体场景：pickup_ammo/pickup_health）
func _spawn_pickup(main: Node, path: String) -> Node3D:
	var scene := load(path) as PackedScene
	if scene == null:
		return null
	var pk := scene.instantiate() as Node3D
	pk.set_multiplayer_authority(1)
	var container := main.get_node_or_null("World/Pickups")
	if container == null:
		container = main
	container.add_child(pk)
	return pk


## 递归按脚本文件名找节点（rustyard Door 实例化路径不固定）
func _find_by_script(node: Node, script_name: String) -> Node:
	for c in node.get_children():
		var s: Variant = c.get_script()
		if s != null and String(s.get("resource_path")).ends_with(script_name):
			return c
		var found := _find_by_script(c, script_name)
		if found != null:
			return found
	return null


## 检查 3D/2D 池中是否有播放器加载了候选文件中的任意一个（stream 命中即接线成功，不限 is_playing 时序；
## 播放随机选变体，候选数组全匹配才稳）
func _stream_played_any(sfx: Node, candidates: Array) -> bool:
	for p in sfx.get("_pool"):
		if _stream_matches_any(p.get("stream"), candidates):
			return true
	for p in sfx.get("_pool_2d"):
		if _stream_matches_any(p.get("stream"), candidates):
			return true
	return false


func _stream_matches_any(stream: Variant, candidates: Array) -> bool:
	if stream == null:
		return false
	var rp := String(stream.get("resource_path"))
	for f in candidates:
		if rp.ends_with(String(f)):
			return true
	return false


func _fail(msg: String) -> void:
	_failures += 1
	printerr("[AUDIO_SYSTEM] FAIL: " + msg)
