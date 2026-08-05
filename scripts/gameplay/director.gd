## director.gd — 简化导演：压力值 → 刷怪节奏（M2-S2）
## 职责：每 update_interval_s（0.5s，director.json）重算 pressure ∈ [0,1]：
##       pressure = clamp(0.4*(1-存活玩家占比) + 0.3*(1-场上丧尸/上限)
##                        + 0.3*(本波已过时间/期望时长), 0, 1)
##       输出 spawn_interval = base * (max_scale - pressure)，结果钳制 [min_s, max_s]，
##       供 WaveManager trickle 刷怪计时使用
## 输入：data/director.json（权重/更新频率/期望时长/缩放与钳制/特感占位/降级占位）；
##       父节点 WaveManager（本节点由 WaveManager._ready 动态 add_child 挂载，免改 main.tscn）；
##       玩家存活占比来自 players 组（PlayerState.state == ALIVE 才计入存活）
## 输出：get_scaled_spawn_interval(base) 供 WaveManager 调用；周期 print 摘要（E4 可观测）
## 谁调用：仅服务器（刷怪计时只在服务器推进，tech-plan §4.4）；客户端不计算
## 规范：tech-plan §7.3；数据全部来自 director.json（改 JSON 重启生效）；
##       M2 无特感：specials.enabled=false 仅读取结构占位，不触发；
##       degrade 降级开关仅读取预留，实际降级逻辑 S3 对象池时实现
## 注意：burst 波（第 3 波）用固定批次间隔，不走压力缩放（S2 只接管 trickle）

class_name Director
extends Node

const DIRECTOR_JSON_PATH := "res://data/director.json"
const PRINT_EVERY_N := 10  # 每 N 次重算打印一次摘要（0.5s×10=5s 一条，E4 可观测）

## 当前压力值 ∈ [0,1]（服务器侧每 update_interval_s 重算；HUD/调试只读）
var pressure := 0.0

var _params: Dictionary = {}
var _update_interval := 0.5
var _weights: Dictionary = {}
var _expected_duration := 90.0
var _max_scale := 1.6
var _min_s := 0.5
var _max_s := 5.0
var _specials_enabled := false
var _degrade_enabled := false

var _wm: WaveManager = null
var _wave_elapsed := 0.0
var _update_timer := 0.0
var _print_count := 0
var _last_interval := 0.0


func _ready() -> void:
	if not _load_params():
		push_warning("[Director] director.json 装载失败，使用内置默认值")
	_wm = get_parent() as WaveManager
	_update_timer = _update_interval


func _process(delta: float) -> void:
	# 压力只驱动服务器刷怪节奏；客户端（非服务器）不计算
	if _wm == null or not NetworkManager.is_server():
		return
	if _wm.state == WaveManager.State.WAVE_ACTIVE:
		_wave_elapsed += delta
	else:
		_wave_elapsed = 0.0  # Setup/Cleared/Intermission 期间不累计波内时间
	_update_timer -= delta
	if _update_timer > 0.0:
		return
	_update_timer = _update_interval
	_recompute_pressure()
	_print_count += 1
	if _print_count % PRINT_EVERY_N == 1:
		_debug_print()


## 供 WaveManager 刷怪计时：base * (max_scale - pressure)，结果钳制 [min_s, max_s]
func get_scaled_spawn_interval(base_interval: float) -> float:
	_last_interval = clampf(base_interval * (_max_scale - pressure), _min_s, _max_s)
	return _last_interval


func _recompute_pressure() -> void:
	var alive_ratio := _alive_player_ratio()
	var zombie_ratio := _zombie_depletion_ratio()
	var time_ratio := minf(_wave_elapsed / _expected_duration, 1.0)
	pressure = clampf(
		_weight("player_alive") * (1.0 - alive_ratio)
		+ _weight("zombie_depletion") * (1.0 - zombie_ratio)
		+ _weight("time_elapsed") * time_ratio,
		0.0, 1.0
	)


## 权重取值（缺省 0，防止 JSON 删字段后崩）
func _weight(key: String) -> float:
	return float(_weights.get(key, 0.0))


## 存活玩家占比：players 组中 ALIVE 玩家数 / 总玩家数（DOWN/DEAD 不计存活）
func _alive_player_ratio() -> float:
	var players := get_tree().get_nodes_in_group("players")
	if players.is_empty():
		return 0.0  # 防御：无玩家视为最紧张（该项满压）
	var alive := 0
	for p in players:
		var ps := p.get_node_or_null("Health") as PlayerState
		if ps != null and ps.state == PlayerState.State.ALIVE:
			alive += 1
	return float(alive) / float(players.size())


## 场上丧尸占比：场上丧尸数 / 该波同屏上限（WaveManager._concurrent_count 作为输入）
func _zombie_depletion_ratio() -> float:
	var cap := _wm._concurrent_cap()
	if cap <= 0:
		return 1.0  # 无上限 → 该项 0 压
	return clampf(float(_wm._concurrent_count) / float(cap), 0.0, 1.0)


## 装载 director.json：所有可调参数落在此处，改 JSON 重启生效
func _load_params() -> bool:
	var file := FileAccess.open(DIRECTOR_JSON_PATH, FileAccess.READ)
	if file == null:
		return false
	var parsed = JSON.parse_string(file.get_as_text())
	if not (parsed is Dictionary):
		return false
	_params = parsed
	_update_interval = float(_params.get("update_interval_s", 0.5))
	_weights = _params.get("pressure_weights", {})
	_expected_duration = float(_params.get("expected_wave_duration_s", 90.0))
	var si: Dictionary = _params.get("spawn_interval", {})
	_max_scale = float(si.get("max_scale", 1.6))
	_min_s = float(si.get("min_s", 0.5))
	_max_s = float(si.get("max_s", 5.0))
	# 特感占位（M2 无特感）：仅读取结构，enabled=false 不触发
	var specials: Dictionary = _params.get("specials", {})
	_specials_enabled = bool(specials.get("enabled", false))
	# 降级开关占位（S3 对象池时实现实际降级）：仅读取
	var degrade: Dictionary = _params.get("degrade", {})
	_degrade_enabled = bool(degrade.get("enabled", false))
	return true


func _debug_print() -> void:
	if _wm.state != WaveManager.State.WAVE_ACTIVE:
		return  # 压力只服务刷怪阶段，Setup/Intermission 不刷屏
	print("[Director] pressure=%.2f spawn_interval=%.2fs wave_elapsed=%.1fs (specials=%s degrade=%s)" % [
		pressure, _last_interval, _wave_elapsed, _specials_enabled, _degrade_enabled
	])
