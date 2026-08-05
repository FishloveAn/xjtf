## wave_manager.gd — 波次状态机（M2-S1 + S2 Director 压力 + S3a 对象池刷怪）
## 职责：装载 waves.json；服务器权威推进 Setup→WaveActive→WaveCleared→Intermission→(下一波)Setup→通关；
##       刷怪走 ZombiePool 对象池（128 只隐藏复用，防运行时反复 instantiate/free 卡顿）；wave_* 事件 authority 广播
## 输入：waves.json；S2：trickle 刷怪计时由子节点 Director（director.gd）按压力缩放；输出：向 Zombies 出池（M1 手动 add_child）
## 谁调用：main.tscn 的 Gameplay/WaveManager；HUD 订阅 event_* 信号只读展示
## 规范：tech-plan §7.2/§5.5；4.7 铁律（get_gravity().y、禁 Vector 字段复合赋值）；单文件 ≤300 行；调试键 N=跳波/Enter=重开

class_name WaveManager
extends Node

enum State { SETUP, WAVE_ACTIVE, WAVE_CLEARED, INTERMISSION, VICTORY }

const WAVES_JSON_PATH := "res://data/waves.json"
const SETUP_COUNTDOWN := 10.0        # 秒，Setup 预告倒计时（E1，待平衡）
const INTERMISSION_COUNTDOWN := 30.0 # 秒，波间休整（E2，待平衡）
const CLEARED_PAUSE := 1.5           # 秒，WaveCleared 播报停留时长（E2 可读）
const BURST_BATCH := 8               # burst 每批刷怪数（短时间涌入，同屏 cap 仍生效）
const BURST_BATCH_INTERVAL := 0.15   # 秒，burst 批次间隔
const SPAWN_RADIUS := 3.0            # 米，刷怪点随机偏移半径

## 波次事件信号（HUD 等订阅，只读展示；由服务器 authority 广播触发）
signal event_wave_started(wave_index: int, wave_name: String, countdown: float)
signal event_wave_begun(wave_index: int)
signal event_wave_cleared(wave_index: int, wave_name: String)
signal event_intermission_started(countdown: float)
signal event_victory

var state: State = State.SETUP
var current_wave_index := 0  # 0-based，读 waves.json（E3：无硬编码波数）

var _waves: Array = []
var _current_wave: Dictionary = {}
var _spawned_count := 0
var _killed_count := 0
var _concurrent_count := 0
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
				_enter_intermission()
		State.INTERMISSION:
			_tick_intermission(delta)


func _start() -> void:
	# 防御：延迟帧执行时若已被摘除场景树（如测试脚本实例化后即移除），直接停用
	if not is_inside_tree() or not NetworkManager.is_server():
		return
	if not _load_waves():
		push_error("[WaveManager] waves.json 装载失败，波次系统停用")
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
	return true


# --- 状态流转 ---

func _begin_wave(wave_index: int) -> void:
	if wave_index >= _waves.size():
		_enter_victory()
		return
	current_wave_index = wave_index
	_current_wave = _waves[wave_index]
	_spawned_count = 0
	_killed_count = 0
	_concurrent_count = 0
	_spawn_timer = 0.0
	_setup_timer = SETUP_COUNTDOWN
	state = State.SETUP
	_broadcast_wave_started(wave_index, _current_wave.get("name", ""), SETUP_COUNTDOWN)


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
	_broadcast_victory()


# --- 刷怪（M2-S3a：改走对象池，tech-plan §5.5，避免运行时反复 instantiate/free） ---

func _spawn_one_zombie() -> void:
	if _pool == null:
		push_warning("[WaveManager] 对象池未就绪，跳过刷怪")
		return
	var zombie: Node3D = _pool.spawn_from_pool(_random_spawn_position())
	if zombie == null:
		push_warning("[WaveManager] 对象池耗尽/超同屏上限，跳过本只")
		return
	_spawned_count += 1
	_concurrent_count += 1
	# 池化复用同一节点：died 只连一次（is_connected 判重防重复计数/重复回池）
	var health := zombie.get_node_or_null("Health") as Damageable
	if health != null and not health.died.is_connected(_on_zombie_died.bind(zombie)):
		health.died.connect(_on_zombie_died.bind(zombie))


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
	return int(_current_wave.get("concurrent_cap", 999))


func _random_spawn_position() -> Vector3:
	var points := get_tree().get_nodes_in_group("spawn_point")
	if points.is_empty():
		return Vector3.ZERO
	var p := points[randi() % points.size()] as Node3D
	return p.global_position + Vector3(randf_range(-SPAWN_RADIUS, SPAWN_RADIUS), 0.0, randf_range(-SPAWN_RADIUS, SPAWN_RADIUS))


func _unhandled_input(event: InputEvent) -> void:
	if not NetworkManager.is_server() or not (event is InputEventKey) or not event.pressed or event.echo:
		return
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


@rpc("authority", "call_local", "reliable")
func wave_started(index: int, wname: String, countdown: float) -> void:
	event_wave_started.emit(index, wname, countdown)


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
