## zombie_ai_charger.gd — 特感·冲撞者 AI（M3-S2；Charger 原型改名避版权，GDD 附录 A）
## 职责：状态机 Idle→Chase→Windup→Charge→Stagger→Dead；直线冲撞（方向锁定前摇末朝向、
##       16m/s 高速、只撞世界不撞丧尸、撞墙/冲满距离停止）；命中玩家 → PlayerState.apply_pin
##       强制倒地（压制，兼容现有救援）；近战兜底（目标贴脸挥击，数据驱动）
## 继承：ZombieSpecialAI（公共：zombies.json 数据驱动/死亡链路/同步/玩家检索/音效钩子）
## 输入：Health.died 信号（基类接线）；players 组取最近玩家（基类 _nearest_player）
## 输出：驱动父节点 CharacterBody3D 位移/朝向；命中调用目标 PlayerState.apply_pin
## 谁调用：仅服务器执行（NetworkManager.is_server() 才跑 AI）；客户端纯显示
## 规范：单文件 ≤300 行；Windup 前摇表现用基元占位（视觉放大脉冲 + 音效钩子），骨骼动画 M3 后期替换

class_name ZombieChargerAI
extends ZombieSpecialAI

enum State { IDLE, CHASE, WINDUP, CHARGE, STAGGER, DEAD }

## 冲撞命中判定半径（米）：冲撞路径上玩家进入此距离即判定命中
const HIT_RADIUS := 1.6
## 冲撞发起朝向夹角阈值（度）：目标在正前方 ±30° 内才进入蓄力（"目标在一条直线上"）
const ALIGN_ANGLE_DEG := 30.0
## 冲撞中碰撞掩码：只撞世界（穿过丧尸，撞墙停，L4D 冲撞手感）
const CHARGE_MASK := 1

var state: State = State.IDLE

var _target: Node3D = null
var _move_dir := Vector3.FORWARD
var _charge_dir := Vector3.FORWARD
var _retarget_timer := 0.0
var _cooldown_timer := 0.0        # 冲撞冷却（命中/落空后冷却回 Chase）
var _melee_timer := 0.0           # 近战冷却
var _windup_timer := 0.0
var _stagger_timer := 0.0
var _charge_travelled := 0.0

# --- 数据驱动参数（默认值 = zombies.json 草案；_apply_params 覆盖，改 JSON 重启生效） ---
var _move_speed := 2.4
var _chase_range := 50.0
var _sight_range := 30.0
var _attack_range := 2.0
var _attack_damage := 20.0
var _attack_cooldown := 1.5
var _charge_windup_s := 0.7
var _charge_speed := 16.0
var _charge_range := 30.0
var _charge_min_range := 6.0
var _stagger_after_s := 1.0
var _cooldown_s := 8.0


func _ready() -> void:
	super._ready()  # 基类：body 引用/数据驱动加载/死亡接线/同步配置


func _apply_params() -> void:
	_move_speed = float(_params.get("move_speed", _move_speed))
	_chase_range = float(_params.get("chase_range_m", _chase_range))
	_sight_range = float(_params.get("sight_range_m", _sight_range))
	var atk: Dictionary = _params.get("attack", {})
	_attack_range = float(atk.get("range_m", _attack_range))
	_attack_damage = float(atk.get("damage", _attack_damage))
	_attack_cooldown = float(atk.get("cooldown_s", _attack_cooldown))
	var sp: Dictionary = _params.get("special", {})
	_charge_windup_s = float(sp.get("charge_windup_s", _charge_windup_s))
	_charge_speed = float(sp.get("charge_speed_mps", _charge_speed))
	_charge_range = float(sp.get("charge_range_m", _charge_range))
	_charge_min_range = float(sp.get("charge_min_range_m", _charge_min_range))
	_stagger_after_s = float(sp.get("stagger_after_s", _stagger_after_s))
	_cooldown_s = float(sp.get("cooldown_s", _cooldown_s))


func _death_sfx_event() -> String:
	return "charger_death"


func _physics_process(delta: float) -> void:
	# AI 只在服务器跑（tech-plan §4.2/§5.4）；客户端纯显示
	if not NetworkManager.is_server():
		return
	if state == State.DEAD:
		return
	match state:
		State.IDLE:
			_tick_idle()
		State.CHASE:
			_tick_chase(delta)
		State.WINDUP:
			_tick_windup(delta)
		State.CHARGE:
			_tick_charge(delta)
		State.STAGGER:
			_tick_stagger(delta)


# --- 状态行为 ---

func _tick_idle() -> void:
	var target := _nearest_player()
	if target != null and _body.global_position.distance_to(target.global_position) <= _sight_range:
		_target = target
		state = State.CHASE
		_play_anim("walk")  # M3-ART-P1：追击 → walk 槽


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
	# 近战兜底：目标贴脸 → 挥击（对倒地玩家同样生效：倒地再受击→DEAD，压制压力）
	if dist <= _attack_range:
		_try_melee()
	if _melee_timer > 0.0:
		_melee_timer = maxf(_melee_timer - delta, 0.0)
	# 冲撞条件：冷却就绪 + 距离 [min_range, range] + 目标存活 + 朝向夹角小（目标在正前方直线）
	if _cooldown_timer <= 0.0 and dist >= _charge_min_range and dist <= _charge_range \
			and _target_alive() and _is_aligned():
		_start_windup()
		return
	if _cooldown_timer > 0.0:
		_cooldown_timer = maxf(_cooldown_timer - delta, 0.0)
	# 简化导航（同普通丧尸）：1s 重算朝向，直线移动 + 撞墙物理
	_retarget_timer -= delta
	if _retarget_timer <= 0.0:
		_retarget_timer = 1.0
		_recompute_direction()
	_body.velocity.x = _move_dir.x * _move_speed
	_body.velocity.z = _move_dir.z * _move_speed
	if not _body.is_on_floor():
		_body.velocity.y = _body.velocity.y + _body.get_gravity().y * delta
	_body.move_and_slide()


func _start_windup() -> void:
	state = State.WINDUP
	_windup_timer = _charge_windup_s
	_recompute_direction()  # 蓄力期间站定转向目标
	_play_sfx("charge_windup")  # 音效钩子（S7 接素材，缺失静默跳过）
	_pulse_visual()  # 前摇表现：视觉放大脉冲（基元占位，M3 后期换骨骼动画）
	_play_anim("attack")  # M3-ART-P1：蓄力前摇 → attack 槽（Idle_Attack 改色骨骼动画）


func _tick_windup(delta: float) -> void:
	_body.velocity = Vector3.ZERO
	_body.move_and_slide()
	_windup_timer -= delta
	if _windup_timer > 0.0:
		return
	# 蓄力结束：锁定冲刺方向（前摇末朝向），进入直线冲撞
	if _target == null or not _target_alive():
		_reset_visual()
		state = State.CHASE
		_play_anim("walk")  # M3-ART-P1：取消冲撞 → 追击 walk
		return
	_charge_dir = _target.global_position - _body.global_position
	_charge_dir.y = 0.0
	if _charge_dir.length_squared() < 0.0001:
		_charge_dir = -_body.global_transform.basis.z
		_charge_dir.y = 0.0
	_charge_dir = _charge_dir.normalized()
	_charge_travelled = 0.0
	_body.collision_mask = CHARGE_MASK  # 冲撞只撞世界，穿过丧尸
	state = State.CHARGE
	_play_anim("walk")  # M3-ART-P1：冲撞移动 → walk 槽


func _tick_charge(delta: float) -> void:
	# 先判命中：冲撞路径上玩家进入命中半径 → 击倒压制（服务器权威结算）
	var hit := _nearest_player()
	if hit != null and _body.global_position.distance_to(hit.global_position) <= HIT_RADIUS:
		_on_charge_hit(hit)
		return
	_body.velocity.x = _charge_dir.x * _charge_speed
	_body.velocity.z = _charge_dir.z * _charge_speed
	if not _body.is_on_floor():
		_body.velocity.y = _body.velocity.y + _body.get_gravity().y * delta
	_body.move_and_slide()
	_charge_travelled = _charge_travelled + _charge_speed * delta
	if _body.is_on_wall():
		_enter_stagger()  # 撞墙停止
	elif _charge_travelled >= _charge_range:
		_enter_stagger()  # 冲满距离未命中 → 硬直收招


func _on_charge_hit(player: Node3D) -> void:
	var ps := player.get_node_or_null("Health") as PlayerState
	if ps != null and ps.state != PlayerState.State.DEAD:
		ps.apply_pin(_body)  # 强制倒地（压制）：复用 DOWN 状态，可被队友救援
		_play_sfx("charger_hit")
	_enter_stagger()


func _enter_stagger() -> void:
	state = State.STAGGER
	_stagger_timer = _stagger_after_s
	_cooldown_timer = _cooldown_s  # 冲撞后冷却（数据驱动）再回追击
	_body.collision_mask = COLLISION_MASK
	_reset_visual()
	_play_anim("hurt")  # M3-ART-P1：硬直/受击 → hurt 槽（HitReact 骨骼动画）


func _tick_stagger(delta: float) -> void:
	_body.velocity = Vector3.ZERO
	_body.move_and_slide()
	_stagger_timer -= delta
	if _stagger_timer > 0.0:
		return
	state = State.CHASE  # 硬直结束 → 回追击
	_play_anim("walk")  # M3-ART-P1：硬直结束 → 追击 walk


# --- 工具 ---

func _try_melee() -> void:
	if _melee_timer > 0.0:
		return
	var ps := _target.get_node_or_null("Health") as PlayerState
	if ps == null or ps.state == PlayerState.State.DEAD:
		return
	ps.take_damage(_attack_damage, _body)
	_melee_timer = _attack_cooldown


func _target_alive() -> bool:
	var ps := _target.get_node_or_null("Health") as PlayerState
	return ps != null and ps.state == PlayerState.State.ALIVE


## 目标是否在冲撞者正前方直线上（朝向夹角 ≤ ALIGN_ANGLE_DEG）
func _is_aligned() -> bool:
	var to := _target.global_position - _body.global_position
	to.y = 0.0
	if to.length_squared() < 0.01:
		return true
	var fwd := -_body.global_transform.basis.z
	return rad_to_deg(fwd.angle_to(to.normalized())) <= ALIGN_ANGLE_DEG


## 每 1s 重算一次朝向与移动方向（简化导航：直线推进，不寻路）
func _recompute_direction() -> void:
	if _target == null:
		return
	var to := _target.global_position - _body.global_position
	to.y = 0.0
	if to.length_squared() < 0.0001:
		return
	var dir := to.normalized()
	_move_dir = dir
	_body.rotation.y = atan2(-dir.x, -dir.z)  # 让 -z 朝向目标


# --- 死亡（基类处理死亡表现/清理；本类补 state=DEAD） ---

func _on_died(_attacker: Node) -> void:
	state = State.DEAD
	_play_anim("death")  # M3-ART-P1：死亡 → death 槽（Death 骨骼动画）
	super._on_died(_attacker)


# --- 前摇视觉表现（基元占位） ---

func _pulse_visual() -> void:
	if _visual == null:
		return
	_kill_visual_tweens()
	_visual.scale = Vector3.ONE
	_visual_tween = create_tween()
	_visual_tween.tween_property(_visual, "scale", Vector3(1.3, 1.3, 1.3), _charge_windup_s * 0.5)
	_visual_tween.tween_property(_visual, "scale", Vector3(1.05, 1.05, 1.05), _charge_windup_s * 0.5)


func _reset_visual() -> void:
	if _visual == null:
		return
	_kill_visual_tweens()
	_visual.scale = Vector3.ONE
