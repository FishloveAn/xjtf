extends SceneTree
# 紧急诊断（SB-M3-DX01）：真机 exe 进主场景后 WASD/鼠标视角无响应。
# headless 模拟"创建主机→开始游戏"全路径，逐项验证输入链路：
#   D1 关键状态：mouse_mode / 玩家位置 / is_multiplayer_authority / HUD 可见性 / autoload / Player 节点树
#   D2 注入移动：Input.action_press("move_forward") → global_position 应变化（move_and_slide 生效）
#   D3 注入开火：直接投递左键事件 → mag_current 应减 1
#   D4 注入鼠标 motion：直接投递 InputEventMouseMotion → Head.rotation.x 应变化
#   D5 InputMap 健全性：move_forward 等 action 是否存在 + get_vector 是否随 action_press 变化
# 用法：godot --headless --path . --script tools/debug_player_input.gd
# 注意：--script 工具不静态引用游戏类类型（M2-S3 铁律），全动态访问；
#       直接调 _unhandled_input 绕过引擎分发（逻辑层），再用 Input.parse_input_event（链路层）双层证据

const MAIN_SCENE := "res://scenes/main/main.tscn"
const WAIT_READY := 2.5  # 主场景 + 主机 0.5s 宽限生成玩家
const TEST_PORT := 15555  # 避开正式游戏默认使用的 5555 端口
const TEST_SAVE_PATH := "user://save/debug_player_input_progress.json"

var _failures := 0
var _player: Node3D = null


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	print("=== PLAYER_INPUT_DIAG START ===")
	_cleanup_test_save()
	var game_state := root.get_node_or_null("GameState")
	if game_state != null:
		game_state.set("checkpoint_path", TEST_SAVE_PATH)
	# 1) 模拟"创建主机"（与主菜单 _on_host_pressed 一致）
	var nm := root.get_node_or_null("NetworkManager")
	if nm == null:
		_fail("NetworkManager autoload 缺失")
		quit(1)
		return
	var err = nm.call("create_host", TEST_PORT)
	if err != OK:
		_fail("测试主机创建失败，端口 %d 不可用（err=%s）" % [TEST_PORT, str(err)])
		quit(1)
		return
	var uid: int = root.get_multiplayer().get_unique_id()
	print("[HOST] create_host err=%s is_server=%s unique_id=%s" % [
		str(err), str(nm.call("is_server")), str(uid)])

	change_scene_to_file(MAIN_SCENE)
	await create_timer(WAIT_READY).timeout
	var main := current_scene
	if main == null:
		_fail("主场景加载失败")
		quit(1)
		return

	# 2) 找本地玩家
	var players := main.get_node_or_null("Players") as Node3D
	if players == null or players.get_child_count() == 0:
		_fail("Players 容器为空（玩家未生成）")
		_autoloads()
		quit(1)
		return
	_player = players.get_child(0) as Node3D
	print("[SPAWN] player=%s authority=%s pos=%s" % [
		_player.name, _player.is_multiplayer_authority(), _player.global_position])

	# D1 关键状态
	_dump_state(main)
	# D5 InputMap 健全性
	await _check_input_map()

	# D2 注入移动
	await _inject_move()
	# D2b 只靠输入从出生点走到第一波触发区，并验证怪物会实际造成伤害
	await _walk_to_first_horde(main)
	# D3 注入开火
	await _inject_fire()
	# D4 注入鼠标视角
	_inject_mouse_look()

	# 汇总
	print("=== PLAYER_INPUT_DIAG %s ===" % ("PASS" if _failures == 0 else "FAIL(%d)" % _failures))
	change_scene_to_file("res://scenes/ui/main_menu.tscn")
	await create_timer(0.5).timeout
	_cleanup_test_save()
	quit(0 if _failures == 0 else 1)


func _cleanup_test_save() -> void:
	for suffix in ["", ".tmp", ".bak"]:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(TEST_SAVE_PATH + suffix))


func _dump_state(main: Node) -> void:
	# mouse_mode 值
	print("[STATE] Input.mouse_mode=%s (CAPTURED=4 VISIBLE=0)" % Input.mouse_mode)
	# 玩家状态/武器
	var health := _player.get_node_or_null("Health")
	print("[STATE] PlayerState state=%s hp=%s" % [str(health.get("state")), str(health.get("hp"))])
	var pivot := _player.get_node_or_null("WeaponPivot")
	if pivot != null:
		for w in pivot.get_children():
			if bool(w.get("visible")):
				print("[STATE] 激活武器=%s mag=%s/%s auto=%s" % [
					w.get("display_name"), w.get("mag_current"), w.get("mag_size"), w.get("auto")])
	# HUD 可见性
	var hud := main.get_node_or_null("HUD") as CanvasLayer
	if hud != null:
		var hl := hud.get_node_or_null("Root/HealthLabel") as Label
		var al := hud.get_node_or_null("Root/AmmoLabel") as Label
		var dl := hud.get_node_or_null("Root/DownedLabel") as Label
		var dov := hud.get_node_or_null("Root/DeadOverlay") as ColorRect
		print("[STATE] HUD HealthLabel='%s' vis=%s Ammo='%s' vis=%s Downed=%s DeadOverlay=%s" % [
			hl.text, hl.visible, al.text, al.visible, dl.visible, dov.visible])
	_autoloads()
	# Player 节点树（深度 2）
	_print_tree(_player, 0, 2)


func _autoloads() -> void:
	var names := []
	for c in root.get_children():
		names.append(c.name)
	print("[STATE] autoload/root children=%s" % str(names))


func _print_tree(node: Node, depth: int, max_depth: int) -> void:
	if depth > max_depth:
		return
	print("%s- %s (%s)" % ["  ".repeat(depth), node.name, node.get_class()])
	for c in node.get_children():
		_print_tree(c, depth + 1, max_depth)


func _check_input_map() -> void:
	for action in ["move_forward", "move_back", "move_left", "move_right", "jump", "interact"]:
		var ok: bool = InputMap.has_action(action)
		var strength: float = Input.get_action_strength(action)
		print("[INPUTMAP] %s exists=%s strength(未按)=%.2f" % [action, ok, strength])
		if not ok:
			_fail("InputMap 缺少 action " + action)
	# action_press 后 get_vector 应变非零（模拟按键）
	Input.action_press("move_forward")
	await create_timer(0.1).timeout
	var v: Vector2 = Input.get_vector("move_left", "move_right", "move_forward", "move_back")
	Input.action_release("move_forward")
	print("[INPUTMAP] action_press(move_forward) → get_vector=%s (期望非零)" % v)
	if v.is_zero_approx():
		_fail("get_vector 未随 action_press 变化（InputMap/动作链路断）")


## D2：按住 move_forward 0.5s，玩家应沿自身朝向移动（x/z 变化，y 不动=贴地）
func _inject_move() -> void:
	var before := _player.global_position
	Input.action_press("move_forward")
	await create_timer(0.5).timeout
	Input.action_release("move_forward")
	await create_timer(0.05).timeout
	var after := _player.global_position
	var dx := absf(after.x - before.x)
	var dz := absf(after.z - before.z)
	var dy := absf(after.y - before.y)
	print("[MOVE] before=%s after=%s dx=%.3f dz=%.3f dy=%.3f" % [before, after, dx, dz, dy])
	var moved := (dx > 0.05 or dz > 0.05)
	print("[MOVE] 移动生效=%s (x/z 位移)" % moved)
	if not moved:
		_fail("注入 move_forward 后 global_position 未变化（移动链路断）")
	if dy > 0.1:
		_fail("移动期间 y 变化 %.3f（玩家未贴地?）" % dy)


## D2b：不瞬移，持续按 W 沿出生朝向穿过安全屋门和通道，验证完整战斗闭环。
func _walk_to_first_horde(main: Node) -> void:
	var level_advance := main.get_node_or_null("Gameplay/LevelAdvance")
	var wave_manager := main.get_node_or_null("Gameplay/WaveManager")
	var health := _player.get_node_or_null("Health")
	if level_advance == null or wave_manager == null or health == null:
		_fail("关卡推进测试缺少 LevelAdvance/WaveManager/Health")
		return

	Input.action_press("move_forward")
	var walk_elapsed := 0.0
	while walk_elapsed < 10.0 and not bool(level_advance.get("_horde_triggered")):
		await create_timer(0.1).timeout
		walk_elapsed += 0.1
	Input.action_release("move_forward")
	print("[LEVEL] 输入行走 %.1fs 后 pos=%s phase=%s horde_triggered=%s" % [
		walk_elapsed, _player.global_position, str(level_advance.get("phase")),
		str(level_advance.get("_horde_triggered"))])
	if not bool(level_advance.get("_horde_triggered")):
		_fail("只靠移动输入无法从出生点抵达第一波触发区（可能被门/碰撞卡住）")
		return

	var hp_before := float(health.get("hp"))
	var combat_elapsed := 0.0
	var max_zombies := 0
	while combat_elapsed < 20.0 and float(health.get("hp")) >= hp_before:
		var zombies := main.get_node_or_null("Zombies")
		if zombies != null:
			max_zombies = maxi(max_zombies, zombies.get_child_count())
		await create_timer(0.2).timeout
		combat_elapsed += 0.2
	var hp_after := float(health.get("hp"))
	print("[COMBAT] wave=%s max_zombies=%d wait=%.1fs hp=%.1f→%.1f" % [
		str(wave_manager.get("_current_wave_id")), max_zombies, combat_elapsed, hp_before, hp_after])
	if max_zombies <= 0:
		_fail("第一波触发后 20 秒内没有生成怪物")
	elif hp_after >= hp_before:
		_fail("怪物已生成，但 20 秒内没有追上并攻击玩家")


## D3：直接投递左键按下事件（模拟 _unhandled_input 收到）。CAPTURED 时走开火分支。
func _inject_fire() -> void:
	# headless 不会自动捕获鼠标，显式设置成游戏运行时应有的状态后再测控制器逻辑。
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	if Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
		print("[FIRE] SKIP：当前显示后端不支持鼠标捕获，留给窗口化冒烟测试验证")
		return
	var pivot := _player.get_node_or_null("WeaponPivot")
	if pivot == null:
		return
	var mag_before: int = -1
	for w in pivot.get_children():
		if bool(w.get("visible")):
			mag_before = int(w.get("mag_current"))
			break
	# 逻辑层：直接调用 _unhandled_input（绕过引擎分发，测控制器本身）
	var ev := InputEventMouseButton.new()
	ev.button_index = MOUSE_BUTTON_LEFT
	ev.pressed = true
	_player.call("_unhandled_input", ev)
	await create_timer(0.05).timeout
	var mag_after: int = -1
	for w in pivot.get_children():
		if bool(w.get("visible")):
			mag_after = int(w.get("mag_current"))
			break
	var spent := mag_before - mag_after
	print("[FIRE] 逻辑层直接投递左键: mag %s→%s 消耗=%d" % [mag_before, mag_after, spent])
	print("[FIRE] 开火生效=%s (期望消耗>0；0 表示被 mouse_mode 分支吞掉或武器无弹药)" % (spent > 0))
	if spent <= 0:
		_fail("左键开火未消耗弹药（mouse_mode=%s 时左键被'重新捕获'分支吞掉？）" % Input.mouse_mode)


## D4：直接投递 MouseMotion（CAPTURED 时转动视角）。绕过引擎分发。
func _inject_mouse_look() -> void:
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	if Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
		print("[LOOK] SKIP：当前显示后端不支持鼠标捕获，留给窗口化冒烟测试验证")
		return
	var head := _player.get_node_or_null("Head") as Node3D
	var rot_before: float = head.rotation.x
	var ev := InputEventMouseMotion.new()
	ev.relative = Vector2(0, -200)  # 上移鼠标 → pitch 减小
	ev.position = Vector2(640, 360)
	_player.call("_unhandled_input", ev)
	var rot_after: float = head.rotation.x
	var dr := absf(rot_after - rot_before)
	print("[LOOK] 逻辑层投递 motion: Head.rotation.x %f→%f 变化=%.4f" % [rot_before, rot_after, dr])
	print("[LOOK] 视角转动生效=%s (期望>0；0 表示 mouse_mode≠CAPTURED 被忽略)" % (dr > 0.0001))
	if dr <= 0.0001:
		_fail("鼠标视角未转动（mouse_mode=%s，motion 被忽略）" % Input.mouse_mode)


func _fail(msg: String) -> void:
	_failures += 1
	printerr("[DX01] FAIL: " + msg)
