## zombie_ai_hunter.gd — 特感·跳跃者 AI（哥布林 G3；对标 Hunter 扑击压制，M3-ART 接线）
## 职责：状态机 Idle→Chase→PounceWindup→Pounce→Recover→Dead；快速追击，进入扑击范围后
##       跳跃扑击（弹道：上抛 + 水平冲刺），命中玩家 → PlayerState.apply_pin 强制倒地压制；
##       落地/扑空 → Recover 硬直后回追击。
## 继承：ZombieSpecialAI（公共：zombies.json 数据驱动/死亡链路/同步/玩家检索/音效钩子）
## 谁调用：仅服务器执行 AI；客户端纯显示
## 规范：单文件 ≤300 行；扑击弹道用 CharacterBody3D velocity（上抛 + 水平），非真骨骼动画

class_name ZombieHunterAI
extends ZombieSpecialAI

enum State { IDLE, CHASE, POUNCE_WINDUP, POUNCE, RECOVER, DEAD }

const HIT_RADIUS := 1.4        # 扑击命中判定半径（米）
const ALIGN_ANGLE_DEG := 25.0  # 扑击发起朝向夹角阈值（度）

var state: State = State.IDLE

var _target: Node3D = null
var _move_dir := Vector3.FORWARD
var _retarget_timer := 0.0
var _cooldown_timer := 0.0
var _windup_timer := 0.0
var _recover_timer := 0.0
var _pounce_dir := Vector3.FORWARD
var _pounce_launched := false

# --- 数据驱动参数（默认值 = zombies.json hunter 草案；_apply_params 覆盖，改 JSON 重启生效） ---
var _move_speed := 3.5
var _chase_range := 50.0
var _sight_range := 35.0
var _pounce_windup_s := 0.4
var _pounce_speed := 14.0
var _pounce_range := 14.0
var _pounce_min_range := 3.0
var _pounce_jump_height := 3.0
var _recover_s := 1.2
var _cooldown_s := 6.0


func _ready() -> void:
	super._ready()


func _params_id() -> String:
	return "hunter"


func _apply_params() -> void:
	_move_speed = float(_params.get("move_speed", _move_speed))
	_chase_range = float(_params.get("chase_range_m", _chase_range))
	_sight_range = float(_params.get("sight_range_m", _sight_range))
	var sp: Dictionary = _params.get("special", {})
	_pounce_windup_s = float(sp.get("pounce_windup_s", _pounce_windup_s))
	_pounce_speed = float(sp.get("pounce_speed_mps", _pounce_speed))
	_pounce_range = float(sp.get("pounce_range_m", _pounce_range))
	_pounce_min_range = float(sp.get("pounce_min_range_m", _pounce_min_range))
	_pounce_jump_height = float(sp.get("pounce_jump_height", _pounce_jump_height))
	_recover_s = float(sp.get("recover_s", _recover_s))
	_cooldown_s = float(sp.get("cooldown_s", _cooldown_s))


func _death_sfx_event() -> String:
	return "charger_death"  # 哥布林音色兜底


func _physics_process(delta: float) -> void:
	if not NetworkManager.is_server():
		return
	if state == State.DEAD:
		return
	match state:
		State.IDLE:
			_tick_idle()
		State.CHASE:
			_tick_chase(delta)
		State.POUNCE_WINDUP:
			_tick_pounce_windup(delta)
		State.POUNCE:
			_tick_pounce(delta)
		State.RECOVER:
			_tick_recover(delta)


# --- 状态行为 ---

func _tick_idle() -> void:
	var target := _nearest_player()
	if target != null and _body.global_position.distance_to(target.global_position) <= _sight_range:
		_target = target
		state = State.CHASE
		_play_anim("walk")


func _tick_chase(delta: float) -> void:
	var target := _nearest_player()
	if target == null:
		state = State.IDLE
		return
	_target = target
	var dist := _body.global_position.distance_to(target.global_position)
	if dist > _chase_range:
		state = State.IDLE
		return
	# 扑击条件：冷却就绪 + 距离在 [min, range] + 目标存活 + 无遮挡
	if _cooldown_timer <= 0.0 and dist >= _pounce_min_range and dist <= _pounce_range \
			and _target_alive() and _has_world_line_to(_target):
		_face_target()
		if _is_aligned():
			_start_pounce_windup()
			return
	if _cooldown_timer > 0.0:
		_cooldown_timer = maxf(_cooldown_timer - delta, 0.0)
	_retarget_timer -= delta
	if _retarget_timer <= 0.0:
		_retarget_timer = 0.6
		_recompute_direction()
	_body.velocity.x = _move_dir.x * _move_speed
	_body.velocity.z = _move_dir.z * _move_speed
	if not _body.is_on_floor():
		_body.velocity.y = _body.velocity.y + _body.get_gravity().y * delta
	_body.move_and_slide()


func _start_pounce_windup() -> void:
	state = State.POUNCE_WINDUP
	_windup_timer = _pounce_windup_s
	_face_target()
	_pulse_visual()
	_play_anim("attack")
	_play_sfx("charge_windup")  # 扑击前摇（复用哥布林冲撞蓄力音兜底）


func _tick_pounce_windup(delta: float) -> void:
	_body.velocity = Vector3.ZERO
	_body.move_and_slide()
	_windup_timer -= delta
	if _windup_timer > 0.0:
		return
	if _target == null or not _target_alive():
		_reset_visual()
		state = State.CHASE
		_play_anim("walk")
		return
	_start_pounce()


## 起跳扑击：锁定方向 + 上抛（v=√(2gh)）+ 水平冲刺（弹道模拟）
func _start_pounce() -> void:
	state = State.POUNCE
	var to := _target.global_position - _body.global_position
	to.y = 0.0
	if to.length_squared() < 0.01:
		to = -_body.global_transform.basis.z
	_pounce_dir = to.normalized()
	_body.rotation.y = atan2(-_pounce_dir.x, -_pounce_dir.z)
	_pounce_launched = false
	var g := absf(_body.get_gravity().y)
	var vy := sqrt(2.0 * g * _pounce_jump_height)
	_body.velocity = _pounce_dir * _pounce_speed + Vector3.UP * vy
	_play_anim("attack")


func _tick_pounce(delta: float) -> void:
	if not _pounce_launched:
		if not _body.is_on_floor() or _body.velocity.y > 0.0:
			_pounce_launched = true
	var hit := _nearest_player()
	if hit != null and _body.global_position.distance_to(hit.global_position) <= HIT_RADIUS:
		_on_pounce_hit(hit)
		return
	if not _body.is_on_floor():
		_body.velocity.y = _body.velocity.y + _body.get_gravity().y * delta
	_body.move_and_slide()
	# 已跳起并回落落地 → 扑空硬直
	if _pounce_launched and _body.is_on_floor() and _body.velocity.y <= 0.0:
		_enter_recover()


func _on_pounce_hit(player: Node3D) -> void:
	var ps := player.get_node_or_null("Health") as PlayerState
	if ps != null and ps.state != PlayerState.State.DEAD:
		ps.apply_pin(_body)  # 强制倒地压制（复用倒地/救援链路）
		_play_sfx("charger_hit")
	_enter_recover()


func _enter_recover() -> void:
	state = State.RECOVER
	_recover_timer = _recover_s
	_cooldown_timer = _cooldown_s
	_body.velocity = Vector3.ZERO
	_reset_visual()
	_play_anim("hurt")


func _tick_recover(delta: float) -> void:
	_body.velocity = Vector3.ZERO
	_body.move_and_slide()
	_recover_timer -= delta
	if _recover_timer <= 0.0:
		state = State.CHASE
		_play_anim("walk")


# --- 工具 ---

func _target_alive() -> bool:
	var ps := _target.get_node_or_null("Health") as PlayerState
	return ps != null and ps.state == PlayerState.State.ALIVE


func _is_aligned() -> bool:
	var to := _target.global_position - _body.global_position
	to.y = 0.0
	if to.length_squared() < 0.01:
		return true
	var fwd := -_body.global_transform.basis.z
	return rad_to_deg(fwd.angle_to(to.normalized())) <= ALIGN_ANGLE_DEG


func _face_target() -> void:
	if _target == null:
		return
	var to := _target.global_position - _body.global_position
	to.y = 0.0
	if to.length_squared() < 0.0001:
		return
	var dir := to.normalized()
	_body.rotation.y = atan2(-dir.x, -dir.z)


func _recompute_direction() -> void:
	if _target == null:
		return
	var dir := _navigation_direction(_target.global_position, _pounce_min_range)
	if dir.length_squared() < 0.0001:
		return
	_move_dir = dir
	_body.rotation.y = atan2(-dir.x, -dir.z)


# --- 死亡（基类处理死亡表现/清理；本类补 state=DEAD） ---

func _on_died(_attacker: Node) -> void:
	state = State.DEAD
	_play_anim("death")
	super._on_died(_attacker)


# --- 前摇视觉表现（基元占位，与冲撞者同款） ---

func _pulse_visual() -> void:
	if _visual == null:
		return
	_kill_visual_tweens()
	_visual.scale = Vector3.ONE
	_visual_tween = create_tween()
	_visual_tween.tween_property(_visual, "scale", Vector3(0.9, 0.85, 0.9), _pounce_windup_s * 0.6)


func _reset_visual() -> void:
	if _visual == null:
		return
	_kill_visual_tweens()
	_visual.scale = Vector3.ONE
