## level_advance.gd — 推进制关卡状态机（M3-S5b；tech-plan §7.2 波次与关卡推进结合）
## 职责：驱动《铁锈仓库》三段式推进：开场安全屋→货场(搜刮)→货运通道(警戒)→装卸广场(守点)→
##       后门安全屋(回血/补给/存档)→完成；监听区域触发体（group level_trigger + trigger_id 分发）：
##       safe_exit=开门进货场 / corridor_enter=进警戒区 / corridor_mid=触发第一波 /
##       plaza_enter=触发守点高潮 / backdoor_enter=到达后门完成段落
##       守点高潮清波 → 后门开启；全员阵亡 → 失败提示；完成态 Enter=单机重开
## 输入：AreaTrigger.body_entered（玩家进入触发体）；WaveManager.event_level_wave_cleared
## 输出：door_opened 广播（门开关）；start_wave_config 触发关卡波次（level_horde_01/level_holdout/level_harass）；
##       CheckpointManager.save_progress 存档；event_* 信号给 HUD
## 谁调用：main.tscn 的 Gameplay/LevelAdvance；仅服务器推进（tech-plan §4.4），客户端只收广播
## 规范：phase 单调前进（不回退）；HUD 订阅 event_phase_changed/event_holdout_triggered/event_level_complete
##       单文件 ≤300 行；竞技场模式（level_mode=false，调试回归）下本节点静默

class_name LevelAdvance
extends Node3D

enum Phase { SAFE_ROOM, YARD, CORRIDOR, PLAZA, BACKDOOR, COMPLETE }

const PHASE_NAMES := [
	"开场安全屋（靠近门开启）", "货场·搜刮区", "货运通道·警戒区",
	"装卸广场·守点区", "后门安全屋", "段落完成",
]
const BACKDOOR_HEAL := 9999.0   # 到达后门：回血上限
const HARASS_WINDOW_MIN := 12.0 # 秒，货场停留超过此值后才可能触发骚扰潮
const HARASS_ROLL_S := 5.0      # 秒，骚扰判定周期
const HARASS_CHANCE := 0.15     # 每周期触发概率（P2：可预期小骚扰，不惩罚）
const MAIN_MENU_SCENE := "res://scenes/ui/main_menu.tscn"

signal event_phase_changed(phase: int, phase_name: String)
signal event_holdout_triggered
signal event_level_complete(segment: int)
signal event_level_failed

var phase: Phase = Phase.SAFE_ROOM

var _wm: WaveManager = null
var _trigger_areas: Dictionary = {}  # trigger_id -> AreaTrigger
var _safe_doors: Array[Door] = []
var _horde_triggered := false    # 第一波（通道中段）已触发
var _horde_pending := false      # 触发被上一波占用，清波后补触发
var _holdout_triggered := false  # 守点高潮已触发
var _holdout_pending := false
var _holdout_cleared := false    # 高潮清波 → 后门开启
var _harass_done := false
var _yard_elapsed := 0.0
var _harass_roll := HARASS_ROLL_S
var _segment_start_time := 0.0
var _fail_check := 0.0


func _ready() -> void:
	set_multiplayer_authority(NetworkManager.SERVER_ID)
	add_to_group("level_advance")
	_wm = get_node_or_null("../WaveManager") as WaveManager
	if _wm != null:
		_wm.level_mode = true                       # 推进制：自动开波停用，等区域触发
		_wm.spawn_point_group = "horde_spawn_point" # 关卡尸潮刷怪点与玩家出生点分离
		if not _wm.event_level_wave_cleared.is_connected(_on_level_wave_cleared):
			_wm.event_level_wave_cleared.connect(_on_level_wave_cleared)
	# 收集触发体与门（rustyard 场景节点已入树，_ready 在其后执行）
	for t in get_tree().get_nodes_in_group("level_trigger"):
		var trig := t as AreaTrigger
		if trig == null or trig.trigger_id.is_empty():
			continue
		_trigger_areas[trig.trigger_id] = trig
		if not trig.body_entered.is_connected(_on_trigger_body_entered.bind(trig)):
			trig.body_entered.connect(_on_trigger_body_entered.bind(trig))
	for d in get_tree().get_nodes_in_group("safe_doors"):
		var door := d as Door
		if door != null:
			_safe_doors.append(door)
	_segment_start_time = Time.get_ticks_msec() / 1000.0
	_broadcast_phase()


func _process(delta: float) -> void:
	if not NetworkManager.is_server():
		return
	if _wm == null or not _wm.level_mode:
		return  # 竞技场模式（调试回归把 level_mode 关掉）下关卡不推进
	if phase == Phase.YARD:
		_tick_harass(delta)
	# 失败检测节流（每秒一次；全员 DEAD 才提示）
	_fail_check -= delta
	if _fail_check <= 0.0:
		_fail_check = 1.0
		_check_all_dead()


# --- 区域触发分发（仅服务器推进；客户端只收广播） ---

func _on_trigger_body_entered(body: Node3D, trig: AreaTrigger) -> void:
	if not NetworkManager.is_server():
		return
	if not body.is_in_group("players"):
		return
	_handle_trigger(trig.trigger_id)


func _handle_trigger(trigger_id: String) -> void:
	match trigger_id:
		"safe_exit":
			if phase == Phase.SAFE_ROOM:
				_open_doors()
				_set_phase(Phase.YARD)
				print("[LevelAdvance] 安全屋门开启，进入货场（搜刮区）")
		"corridor_enter":
			if phase == Phase.YARD:
				_set_phase(Phase.CORRIDOR)
				print("[LevelAdvance] 进入货运通道（警戒区）")
		"corridor_mid":
			if not _horde_triggered and phase >= Phase.CORRIDOR:
				_horde_triggered = true
				if not _trigger_level_wave("level_horde_01"):
					_horde_pending = true  # 上一波（骚扰潮）未清 → 清波后补触发
				print("[LevelAdvance] 通道中段：第一波尸潮触发")
		"plaza_enter":
			if not _holdout_triggered and phase >= Phase.CORRIDOR:
				_holdout_triggered = true
				_set_phase(Phase.PLAZA)
				if not _trigger_level_wave("level_holdout"):
					_holdout_pending = true
				event_holdout_triggered.emit()
				print("[LevelAdvance] 装卸广场：守点高潮触发")
		"backdoor_enter":
			if _holdout_cleared and phase < Phase.BACKDOOR:
				_complete_segment()


func _on_level_wave_cleared(wave_id: String) -> void:
	if wave_id == "level_harass":
		_harass_done = true
	if wave_id == "level_holdout":
		_holdout_cleared = true
		print("[LevelAdvance] 守点高潮清除，后门安全屋开启")
		_toast("尸潮清除，后门安全屋开启！")
	# 补触发挂起的高潮（玩家推进快于波次清空时）
	if _horde_pending:
		_horde_pending = false
		_trigger_level_wave("level_horde_01")
	elif _holdout_pending:
		_holdout_pending = false
		_trigger_level_wave("level_holdout")


## 触发关卡波次（复用 WaveManager 刷怪；区域触发=手动启动波次，tech-plan §7.2）
func _trigger_level_wave(wave_id: String) -> bool:
	if _wm == null or not _wm.level_mode:
		return false
	if _wm.state != WaveManager.State.LEVEL_WAIT:
		push_warning("[LevelAdvance] 波次非等待态（state=%d），%s 延后" % [_wm.state, wave_id])
		return false
	var cfg: Dictionary = _wm.get_level_wave_config(wave_id)
	if cfg.is_empty():
		push_error("[LevelAdvance] 找不到关卡波次配置 %s" % wave_id)
		return false
	return _wm.start_wave_config(cfg)


## 搜刮期骚扰潮（可选简单版，P2：小规模、可预期、不惩罚）：货场停留超窗 + 概率触发一次
func _tick_harass(delta: float) -> void:
	if _harass_done or _horde_triggered:
		return
	_yard_elapsed += delta
	if _yard_elapsed < HARASS_WINDOW_MIN:
		return
	_harass_roll -= delta
	if _harass_roll <= 0.0:
		_harass_roll = HARASS_ROLL_S
		if randf() < HARASS_CHANCE:
			if _trigger_level_wave("level_harass"):
				_harass_done = true
				print("[LevelAdvance] 货场骚扰潮触发")


# --- 完成/失败 ---

func _complete_segment() -> void:
	_set_phase(Phase.BACKDOOR)
	_heal_and_resupply_all()
	var elapsed := Time.get_ticks_msec() / 1000.0 - _segment_start_time
	CheckpointManager.save_progress(1, elapsed, 0)
	event_level_complete.emit(1)
	print("[LevelAdvance] 到达后门安全屋：回血/补给 + 已存档（段落用时 %.1fs）" % elapsed)
	_toast("段落完成！已存档，按 Enter 重开 / Esc 回主菜单")
	_set_phase(Phase.COMPLETE)


## 后门安全屋休整：全员满血 + 四把武器弹匣补满（服务器权威结算，HealthSync/WeaponSync 自动广播）
func _heal_and_resupply_all() -> void:
	for p in get_tree().get_nodes_in_group("players"):
		var state := p.get_node_or_null("Health") as PlayerState
		if state != null:
			state.apply_healing(BACKDOOR_HEAL)
		var pivot := p.get_node_or_null("WeaponPivot")
		if pivot == null:
			continue
		for w in pivot.get_children():
			var wb := w as WeaponBase
			if wb != null:
				wb.mag_current = wb.mag_size


## 全员阵亡 → 失败提示（可重试：重开/回主菜单）
func _check_all_dead() -> void:
	var players := get_tree().get_nodes_in_group("players")
	if players.is_empty():
		return
	for p in players:
		var ps := p.get_node_or_null("Health") as PlayerState
		if ps == null or ps.state != PlayerState.State.DEAD:
			return
	if phase < Phase.COMPLETE and phase != Phase.SAFE_ROOM:
		event_level_failed.emit()
		print("[LevelAdvance] 全员阵亡，段落失败（可重试）")


# --- 工具 ---

func _open_doors() -> void:
	for door in _safe_doors:
		if door == null or not is_instance_valid(door):
			continue
		if NetworkManager.is_network_active():
			door.door_opened.rpc()
		else:
			door.door_opened()


func _set_phase(p: Phase) -> void:
	phase = p
	_broadcast_phase()


func _broadcast_phase() -> void:
	if NetworkManager.is_network_active():
		phase_changed.rpc(phase, PHASE_NAMES[phase])
	else:
		phase_changed(phase, PHASE_NAMES[phase])


@rpc("authority", "call_local", "reliable")
func phase_changed(p: int, pname: String) -> void:
	event_phase_changed.emit(p, pname)


func _toast(text: String) -> void:
	print("[LevelAdvance] %s" % text)


func _unhandled_input(event: InputEvent) -> void:
	if not NetworkManager.is_server() or not (event is InputEventKey) or not event.pressed or event.echo:
		return
	# 完成态 Enter：单机重开（多人由主机退出重开房，主机权威 MVP）
	if event.keycode == KEY_ENTER and phase == Phase.COMPLETE:
		if not NetworkManager.is_network_active():
			get_tree().reload_current_scene()
		else:
			get_tree().change_scene_to_file(MAIN_MENU_SCENE)
