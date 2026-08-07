## wave_manager.gd — 波次状态机（M2-S1 + S2 Director 压力 + S3a 对象池刷怪 + S5 关卡触发）
## 职责：装载 waves.json；服务器权威推进 Setup→WaveActive→WaveCleared→Intermission→(下一波)Setup→通关；
##       刷怪走 ZombiePool 对象池（128 只隐藏复用，防运行时反复 instantiate/free 卡顿）；wave_* 事件 authority 广播
##       普通丧尸 composition 走池；特感（charger/spitter）独立实例化，Director 时机 + 共享同屏 cap ≤5（M3-S2/S3）
##       M3-S5 推进制：level_mode=true 时自动开波停用，等待 LevelAdvance 按区域触发
##       （start_wave_config 手动启动一个波次配置，清波后转 LEVEL_WAIT 而非 Intermission）
## 输入：waves.json；S2：trickle 刷怪计时由子节点 Director（director.gd）按压力缩放；输出：向 Zombies 出池（M1 手动 add_child）
## 谁调用：main.tscn 的 Gameplay/WaveManager；HUD 订阅 event_* 信号只读展示；
##       LevelAdvance（推进制）调用 start_wave_config / get_level_wave_config 并订阅 event_level_wave_cleared
## 规范：tech-plan §7.2/§5.5；4.7 铁律（get_gravity().y、禁 Vector 字段复合赋值）；调试键 N=跳波/Enter=重开（仅竞技场模式）

class_name WaveManager
extends Node

enum State { SETUP, WAVE_ACTIVE, WAVE_CLEARED, INTERMISSION, VICTORY, LEVEL_WAIT }

const WAVES_JSON_PATH := "res://data/waves.json"
const SETUP_COUNTDOWN := 10.0        # 秒，Setup 预告倒计时（E1，待平衡）
const INTERMISSION_COUNTDOWN := 30.0 # 秒，波间休整（E2，待平衡）
const CLEARED_PAUSE := 1.5           # 秒，WaveCleared 播报停留时长（E2 可读）
const LEVEL_SETUP_COUNTDOWN := 5.0   # 秒，关卡波次预告倒计时（推进制，比竞技场短，S5）
const BURST_BATCH := 8               # burst 每批刷怪数（短时间涌入，同屏 cap 仍生效）
const BURST_BATCH_INTERVAL := 0.15   # 秒，burst 批次间隔
const SPAWN_RADIUS := 3.0            # 米，刷怪点随机偏移半径
const SPECIAL_RELEASE_TIMEOUT := 10.0 # 秒，composition 特感等待 Director 时机超时兜底（防低压力卡关）
const CHARGER_SCENE_PATH := "res://scenes/enemies/zombie_charger.tscn"
const SPITTER_SCENE_PATH := "res://scenes/enemies/zombie_spitter.tscn"  # M3-S3 喷吐者

## 波次事件信号（HUD 等订阅，只读展示；由服务器 authority 广播触发）
signal event_wave_started(wave_index: int, wave_name: String, countdown: float)
signal event_wave_begun(wave_index: int)
signal event_wave_cleared(wave_index: int, wave_name: String)
signal event_intermission_started(countdown: float)
signal event_victory
## 关卡波次清除（S5 推进制）：level_mode 下清波后转 LEVEL_WAIT，通知 LevelAdvance 可推进下一步
signal event_level_wave_cleared(wave_id: String)

var state: State = State.SETUP
var current_wave_index := 0  # 0-based，读 waves.json（E3：无硬编码波数）
## 推进制开关（S5）：true=自动开波停用，等 LevelAdvance 区域触发；false=竞技场自动推进（默认）
var level_mode := false
## 刷怪点组名（S5）：竞技场默认 "spawn_point"（玩家出生点同组）；推进制由 LevelAdvance 切
## "horde_spawn_point"（关卡内散布的尸潮刷怪点，与玩家出生点分离）
var spawn_point_group := "spawn_point"

var _waves: Array = []
## 关卡波次配置（waves.json level_waves 数组，S5：触发式波次，见 LevelAdvance）
var _level_waves: Array = []
var _current_wave: Dictionary = {}
var _current_wave_id := ""
var _spawned_count := 0
var _killed_count := 0
var _concurrent_count := 0
## 特感刷怪计数（M3-S2/S3）：composition 按类型拆分配额，common 走池、charger/spitter 独立
## 实例化；_active_specials 为两种特感共享的同屏计数（cap ≤5，tech-plan §10）
var _spawned_commons := 0
var _spawned_chargers := 0
var _spawned_spitters := 0
var _active_specials := 0
var _special_pending_timer := 0.0
var _charger_scene: PackedScene = null
var _spitter_scene: PackedScene = null
var _spawn_timer := 0.0
var _setup_timer := 0.0
var _cleared_timer := 0.0
var _intermission_timer := 0.0

@onready var _zombies: Node3D = get_node("../../Zombies")
var _director: Director = null  # S2：子节点 Director 提供压力缩放后的刷怪间隔
var _pool: ZombiePool = null    # S3a：丧尸对象池（仅服务器侧创建；客户端不建池）


func _ready() -> void:
	# 波次节点权威=服务器（authority 广播可发）；延迟一帧启动等 HUD 连信号（E1 首播不丢）
	set_multiplayer_authority(NetworkManager.SERVER_ID)
	add_to_group("wave_manager")
	_director = Director.new()
	add_child(_director)
	# S3a：服务器侧预实例化 128 只隐藏丧尸（对象池，tech-plan §5.5）
	if NetworkManager.is_server():
		_pool = ZombiePool.new()
		_pool.name = "ZombiePool"
		add_child(_pool)
		_pool.setup(_zombies)
		# M3-S2/S3：特感场景延迟 load（不池化，死亡 queue_free，风险备注 6）
		_charger_scene = load(CHARGER_SCENE_PATH) as PackedScene
		_spitter_scene = load(SPITTER_SCENE_PATH) as PackedScene
	call_deferred("_start")


func _process(delta: float) -> void:
	# 状态机只由服务器推进（tech-plan §4.4）；客户端只收广播，不跑状态
	if not NetworkManager.is_server():
		return
	match state:
		State.SETUP:
			_tick_setup(delta)
		State.WAVE_ACTIVE:
			_tick_wave_active(delta)
		State.WAVE_CLEARED:
			_cleared_timer -= delta
			if _cleared_timer <= 0.0:
				if level_mode:
					_enter_level_wait()  # 推进制：清波后回等待，由 LevelAdvance 决定下一步
				else:
					_enter_intermission()
		State.INTERMISSION:
			_tick_intermission(delta)
		State.LEVEL_WAIT:
			pass  # 推进制：等待 LevelAdvance 按区域触发（start_wave_config）


func _start() -> void:
	# 防御：延迟帧执行时若已被摘除场景树（如测试脚本实例化后即移除），直接停用
	if not is_inside_tree() or not NetworkManager.is_server():
		return
	if not _load_waves():
		push_error("[WaveManager] waves.json 装载失败，波次系统停用")
		return
	if level_mode:
		# 推进制（S5）：不自动开波，等待 LevelAdvance 区域触发波次
		state = State.LEVEL_WAIT
		print("[WaveManager] 关卡推进模式：等待区域触发波次")
		return
	_begin_wave(0)


func _load_waves() -> bool:
	var file := FileAccess.open(WAVES_JSON_PATH, FileAccess.READ)
	if file == null:
		return false
	var parsed = JSON.parse_string(file.get_as_text())
	if not (parsed is Dictionary):
		return false
	var waves = parsed.get("waves", [])
	if not (waves is Array) or waves.is_empty():
		return false
	_waves = waves
	# S5：关卡触发式波次独立数组（竞技场 waves 保持 3 波推进不受影响）
	var level_waves = parsed.get("level_waves", [])
	_level_waves = level_waves if level_waves is Array else []
	return true


# --- 状态流转 ---

func _begin_wave(wave_index: int) -> void:
	if wave_index >= _waves.size():
		_enter_victory()
		return
	current_wave_index = wave_index
	_current_wave = _waves[wave_index]
	_current_wave_id = String(_current_wave.get("id", ""))
	_reset_wave_state()
	_setup_timer = SETUP_COUNTDOWN
	state = State.SETUP
	_broadcast_wave_started(wave_index, _current_wave.get("name", ""), SETUP_COUNTDOWN)


## 关卡触发：手动启动一个波次配置（S5，level_mode 下由 LevelAdvance 调用）。
## 前置：仅 LEVEL_WAIT 态可启动（防上一波未清时叠加刷怪）；返回是否成功
func start_wave_config(cfg: Dictionary) -> bool:
	if not NetworkManager.is_server():
		return false
	if state != State.LEVEL_WAIT:
		return false
	if cfg.is_empty():
		return false
	_current_wave = cfg
	_current_wave_id = String(cfg.get("id", ""))
	_reset_wave_state()
	_setup_timer = LEVEL_SETUP_COUNTDOWN
	state = State.SETUP
	_broadcast_wave_started(-1, _current_wave.get("name", ""), LEVEL_SETUP_COUNTDOWN)
	return true


## 关卡波次配置查找（S5，LevelAdvance 调用）：优先 level_waves，回退竞技场 waves
func get_level_wave_config(wave_id: String) -> Dictionary:
	for w in _level_waves:
		if String(w.get("id", "")) == wave_id:
			return w
	for w in _waves:
		if String(w.get("id", "")) == wave_id:
			return w
	return {}


## 波次计数器统一复位（_begin_wave 与 start_wave_config 共用）
func _reset_wave_state() -> void:
	_spawned_count = 0
	_killed_count = 0
	_concurrent_count = 0
	_spawned_commons = 0
	_spawned_chargers = 0
	_spawned_spitters = 0
	_active_specials = 0
	_special_pending_timer = 0.0
	_spawn_timer = 0.0


func _enter_level_wait() -> void:
	state = State.LEVEL_WAIT
	_broadcast_level_wave_cleared(_current_wave_id)


func _tick_setup(delta: float) -> void:
	_setup_timer -= delta
	if _setup_timer <= 0.0:
		_enter_wave_active()


func _enter_wave_active() -> void:
	state = State.WAVE_ACTIVE
	_spawn_timer = 0.0  # 首帧即开始按 spawn_interval 刷怪
	_broadcast_wave_begun(current_wave_index)


func _tick_wave_active(delta: float) -> void:
	if _all_spawned():
		return  # 全刷出后等杀光（清波判定在 _on_zombie_died）
	# composition 有特感待刷 → 累计等待 Director 时机（压力阈值/冷却），超时兜底放行防卡关
	var comp: Dictionary = _current_wave.get("composition", {})
	if int(comp.get("charger", 0)) > _spawned_chargers or int(comp.get("spitter", 0)) > _spawned_spitters:
		_special_pending_timer += delta
	_spawn_timer -= delta
	if _spawn_timer > 0.0:
		return
	var style: String = _current_wave.get("spawn_style", "trickle")
	if style == "burst":
		_spawn_timer = BURST_BATCH_INTERVAL
		for i in BURST_BATCH:
			if _all_spawned() or _concurrent_count >= _concurrent_cap():
				break
			_spawn_one_zombie()
	else:
		# trickle：按 Director 压力缩放 spawn_interval 一只只出，场上低于 cap 才补
		_spawn_timer = _director.get_scaled_spawn_interval(float(_current_wave.get("spawn_interval", 2.0)))
		if _concurrent_count < _concurrent_cap():
			_spawn_one_zombie()


func _tick_intermission(delta: float) -> void:
	_intermission_timer -= delta
	if _intermission_timer <= 0.0:
		_begin_wave(current_wave_index + 1)


func _enter_wave_cleared() -> void:
	state = State.WAVE_CLEARED
	_cleared_timer = CLEARED_PAUSE
	var wave_name: String = _current_wave.get("name", "")
	_broadcast_wave_cleared(current_wave_index, wave_name)
	# reward 本期只读（S4 物资再消费），仅记录
	print("[WaveManager] 第 %d 波 %s 完成 reward=%s（S1 只读）" % [current_wave_index + 1, wave_name, str(_current_wave.get("reward", {}))])


func _enter_intermission() -> void:
	state = State.INTERMISSION
	_intermission_timer = INTERMISSION_COUNTDOWN
	_broadcast_intermission_started(INTERMISSION_COUNTDOWN)
	# S4：波间休整刷补给点（waves.json reward 数据驱动；Pickups 容器 + supply_spot 固定点）
	SupplyPoint.refresh_from_reward(get_node_or_null("../../World/Pickups"),
		get_tree().get_nodes_in_group("supply_spot"), _current_wave.get("reward", {}))


func _enter_victory() -> void:
	state = State.VICTORY
	# S6：竞技场通关结算（自动取会话用时）→ 广播计分板全端展示
	GameState.finish_segment()
	_broadcast_victory()


# --- 刷怪（M2-S3a：普通丧尸走对象池；M3-S2：特感独立实例化，tech-plan §5.5） ---

## 刷怪分发：按 composition 剩余配额取类型（特感受 Director 时机 + 共享同屏 cap 约束）
func _spawn_one_zombie() -> void:
	var ztype := _next_spawn_type()
	if ztype == "charger":
		_spawn_one_charger()
	elif ztype == "spitter":
		_spawn_one_spitter()
	elif ztype == "common":
		_spawn_one_common()


func _next_spawn_type() -> String:
	var comp: Dictionary = _current_wave.get("composition", {})
	if int(comp.get("charger", 0)) > _spawned_chargers and _can_spawn_special():
		return "charger"
	if int(comp.get("spitter", 0)) > _spawned_spitters and _can_spawn_special():
		return "spitter"
	if int(comp.get("common", 0)) > _spawned_commons:
		return "common"
	return ""


## Director 特感时机：pressure ≥ 阈值 + 冷却已过才放行；等待超时兜底（防低压力卡关）。
## 冲撞者/喷吐者共享同一时机与同屏 cap（特感总量 ≤5，tech-plan §10）
func _can_spawn_special() -> bool:
	if _active_specials >= _special_cap():
		return false
	if _special_pending_timer >= SPECIAL_RELEASE_TIMEOUT:
		return true
	return _director != null and _director.can_spawn_special()


## 特感同屏上限：director.json max_simultaneous 生效，硬上限 5（tech-plan §10）
func _special_cap() -> int:
	if _director == null:
		return 5
	return _director.special_cap()


func _spawn_one_common() -> void:
	if _pool == null:
		push_warning("[WaveManager] 对象池未就绪，跳过刷怪")
		return
	var zombie: Node3D = _pool.spawn_from_pool(_random_spawn_position())
	if zombie == null:
		push_warning("[WaveManager] 对象池耗尽/超同屏上限，跳过本只")
		return
	_spawned_commons += 1
	_spawned_count += 1
	_concurrent_count += 1
	# 池化复用同一节点：died 只连一次（is_connected 判重防重复计数/重复回池）
	var health := zombie.get_node_or_null("Health") as Damageable
	if health != null and not health.died.is_connected(_on_zombie_died.bind(zombie)):
		health.died.connect(_on_zombie_died.bind(zombie))


## 特感刷出：独立实例化（特感 ≤5 不池化，死亡 queue_free，风险备注 6）
func _spawn_one_charger() -> void:
	if _charger_scene == null:
		push_warning("[WaveManager] 无法装载 zombie_charger.tscn，跳过特感")
		return
	var charger: Node3D = _charger_scene.instantiate()
	charger.name = "Charger"
	charger.set_multiplayer_authority(NetworkManager.SERVER_ID)
	_zombies.add_child(charger, true)  # 强制可读名（MultiplayerSpawner 复制要求，M2-S5）
	charger.global_position = _random_spawn_position()
	_spawned_chargers += 1
	_spawned_count += 1
	_concurrent_count += 1
	_active_specials += 1
	if _director != null:
		_director.mark_special_spawned()  # 推进 Director 特感冷却
	var health := charger.get_node_or_null("Health") as Damageable
	if health != null and not health.died.is_connected(_on_charger_died.bind(charger)):
		health.died.connect(_on_charger_died.bind(charger))


func _on_charger_died(_attacker: Node, _charger: Node) -> void:
	_killed_count += 1
	_concurrent_count = maxi(_concurrent_count - 1, 0)
	_active_specials = maxi(_active_specials - 1, 0)
	_check_wave_cleared()


## 喷吐者刷出：独立实例化（特感 ≤5 不池化，死亡 queue_free，风险备注 6）
func _spawn_one_spitter() -> void:
	if _spitter_scene == null:
		push_warning("[WaveManager] 无法装载 zombie_spitter.tscn，跳过特感")
		return
	var spitter: Node3D = _spitter_scene.instantiate()
	spitter.name = "Spitter"
	spitter.set_multiplayer_authority(NetworkManager.SERVER_ID)
	_zombies.add_child(spitter, true)  # 强制可读名（MultiplayerSpawner 复制要求，M2-S5）
	spitter.global_position = _random_spawn_position()
	_spawned_spitters += 1
	_spawned_count += 1
	_concurrent_count += 1
	_active_specials += 1  # 与冲撞者共享同屏计数（cap ≤5）
	if _director != null:
		_director.mark_special_spawned()  # 推进 Director 特感冷却
	var health := spitter.get_node_or_null("Health") as Damageable
	if health != null and not health.died.is_connected(_on_spitter_died.bind(spitter)):
		health.died.connect(_on_spitter_died.bind(spitter))


func _on_spitter_died(_attacker: Node, _spitter: Node) -> void:
	_killed_count += 1
	_concurrent_count = maxi(_concurrent_count - 1, 0)
	_active_specials = maxi(_active_specials - 1, 0)
	_check_wave_cleared()


func _on_zombie_died(_attacker: Node, _zombie: Node) -> void:
	_killed_count += 1
	_concurrent_count = maxi(_concurrent_count - 1, 0)
	_check_wave_cleared()


func _check_wave_cleared() -> void:
	var total := _wave_total_count()  # cleared_when M2 统一 all_spawned_killed
	if _spawned_count >= total and _killed_count >= total:
		_enter_wave_cleared()


func _wave_total_count() -> int:
	var total := 0
	var comp: Dictionary = _current_wave.get("composition", {})
	for key in comp:
		total += int(comp[key])
	return total


func _all_spawned() -> bool:
	return _spawned_count >= _wave_total_count()


func _concurrent_cap() -> int:
	var wave_cap := int(_current_wave.get("concurrent_cap", 999))
	if _director == null:
		return wave_cap
	return _director.concurrent_cap(wave_cap)


func _random_spawn_position() -> Vector3:
	var points := get_tree().get_nodes_in_group(spawn_point_group)
	if points.is_empty():
		return Vector3.ZERO
	var p := points[randi() % points.size()] as Node3D
	return p.global_position + Vector3(randf_range(-SPAWN_RADIUS, SPAWN_RADIUS), 0.0, randf_range(-SPAWN_RADIUS, SPAWN_RADIUS))


func _unhandled_input(event: InputEvent) -> void:
	if not NetworkManager.is_server() or not (event is InputEventKey) or not event.pressed or event.echo:
		return
	if level_mode:
		return  # 推进制：调试跳波键不适用（波次由区域触发）
	if event.keycode == KEY_N and (state == State.INTERMISSION or state == State.WAVE_CLEARED):
		_begin_wave(current_wave_index + 1)
	elif event.keycode == KEY_ENTER and state == State.VICTORY:
		_begin_wave(0)


func _broadcast_wave_started(index: int, wname: String, countdown: float) -> void:
	if NetworkManager.is_network_active():
		wave_started.rpc(index, wname, countdown)
	else:
		wave_started(index, wname, countdown)


func _broadcast_wave_begun(index: int) -> void:
	if NetworkManager.is_network_active():
		wave_begun.rpc(index)
	else:
		wave_begun(index)


func _broadcast_wave_cleared(index: int, wname: String) -> void:
	if NetworkManager.is_network_active():
		wave_cleared.rpc(index, wname)
	else:
		wave_cleared(index, wname)


func _broadcast_intermission_started(countdown: float) -> void:
	if NetworkManager.is_network_active():
		intermission_started.rpc(countdown)
	else:
		intermission_started(countdown)


func _broadcast_victory() -> void:
	if NetworkManager.is_network_active():
		victory.rpc()
	else:
		victory()


## 关卡波次清除广播（S5）：单机直接调用，多人 authority RPC
func _broadcast_level_wave_cleared(wave_id: String) -> void:
	if NetworkManager.is_network_active():
		level_wave_cleared.rpc(wave_id)
	else:
		level_wave_cleared(wave_id)


@rpc("authority", "call_local", "reliable")
func level_wave_cleared(wave_id: String) -> void:
	event_level_wave_cleared.emit(wave_id)


@rpc("authority", "call_local", "reliable")
func wave_started(index: int, wname: String, countdown: float) -> void:
	event_wave_started.emit(index, wname, countdown)
	# M3-S7：尸潮警报（波次预告/高潮触发，全端本地播放，非定位 2D；素材缺失静默跳过）
	SfxPool.play_2d("wave_alarm")


@rpc("authority", "call_local", "reliable")
func wave_begun(index: int) -> void:
	event_wave_begun.emit(index)


@rpc("authority", "call_local", "reliable")
func wave_cleared(index: int, wname: String) -> void:
	event_wave_cleared.emit(index, wname)


@rpc("authority", "call_local", "reliable")
func intermission_started(countdown: float) -> void:
	event_intermission_started.emit(countdown)


@rpc("authority", "call_local", "reliable")
func victory() -> void:
	event_victory.emit()
