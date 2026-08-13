## zombie_ai_boomer.gd — 特感·自爆者 AI（哥布林 G4；对标 Boomer 自爆尸潮，M3-ART 接线）
## 职责：状态机 Idle→Chase→ExplodeWindup→Dead；慢速走近目标，贴近后自爆范围伤害（AOE
##       伤害范围内玩家 + 自身死亡触发血雾/掉落/清理链路）。尸潮召唤（Boome 原型喷溅增怪）
##       留待后续玩法扩展，本期只做自爆伤害。
## 继承：ZombieSpecialAI（公共：zombies.json 数据驱动/死亡链路/同步/玩家检索/音效钩子）
## 谁调用：仅服务器执行 AI；客户端纯显示
## 规范：单文件 ≤300 行；前摇视觉基元占位（放大脉冲），爆炸视觉走 AoeFxPool 广播

class_name ZombieBoomerAI
extends ZombieSpecialAI

enum State { IDLE, CHASE, EXPLODE_WINDUP, DEAD }

var state: State = State.IDLE

var _target: Node3D = null
var _move_dir := Vector3.FORWARD
var _retarget_timer := 0.0
var _windup_timer := 0.0

# --- 数据驱动参数（默认值 = zombies.json boomer 草案；_apply_params 覆盖，改 JSON 重启生效） ---
var _move_speed := 1.8
var _chase_range := 45.0
var _sight_range := 25.0
var _trigger_range := 2.5
var _explode_radius := 4.5
var _explode_damage := 50.0
var _explode_windup_s := 0.6


func _ready() -> void:
	super._ready()


func _params_id() -> String:
	return "boomer"


func _apply_params() -> void:
	_move_speed = float(_params.get("move_speed", _move_speed))
	_chase_range = float(_params.get("chase_range_m", _chase_range))
	_sight_range = float(_params.get("sight_range_m", _sight_range))
	var sp: Dictionary = _params.get("special", {})
	_trigger_range = float(sp.get("trigger_range_m", _trigger_range))
	_explode_radius = float(sp.get("explode_radius_m", _explode_radius))
	_explode_damage = float(sp.get("explode_damage", _explode_damage))
	_explode_windup_s = float(sp.get("windup_s", _explode_windup_s))


func _death_sfx_event() -> String:
	return "charger_death"  # 哥布林音色兜底（自爆死亡咆哮）


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
		State.EXPLODE_WINDUP:
			_tick_explode_windup(delta)


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
	# 贴近目标 → 自爆前摇
	if dist <= _trigger_range:
		_start_explode()
		return
	_face_target()
	_retarget_timer -= delta
	if _retarget_timer <= 0.0:
		_retarget_timer = 1.0
		_recompute_direction()
	_body.velocity.x = _move_dir.x * _move_speed
	_body.velocity.z = _move_dir.z * _move_speed
	if not _body.is_on_floor():
		_body.velocity.y = _body.velocity.y + _body.get_gravity().y * delta
	_body.move_and_slide()


func _start_explode() -> void:
	state = State.EXPLODE_WINDUP
	_windup_timer = _explode_windup_s
	_face_target()
	_pulse_visual()
	_play_anim("attack")
	_play_sfx("charge_windup")  # 自爆前摇（复用冲撞蓄力音，哥布林咆哮兜底）


func _tick_explode_windup(delta: float) -> void:
	_body.velocity = Vector3.ZERO
	_body.move_and_slide()
	_windup_timer -= delta
	if _windup_timer <= 0.0:
		_explode()


## 自爆：范围伤害玩家 + 广播 AOE 视觉 + 自身死亡（触发血雾/掉落/清理链路）
func _explode() -> void:
	_play_sfx("charger_death")  # 爆炸音（哥布林死亡咆哮兜底）
	var main := get_tree().current_scene
	if main != null and main.has_method("broadcast_aoe_visual"):
		main.broadcast_aoe_visual(_body.global_position, "grenade")
	for p in get_tree().get_nodes_in_group("players"):
		var dist := _body.global_position.distance_to(p.global_position)
		if dist <= _explode_radius:
			var ps := p.get_node_or_null("Health") as PlayerState
			if ps != null:
				ps.take_damage(_explode_damage, _body)
	# 自爆死亡：对自己造成致死伤害，走 Health.died 链路（血雾/掉落/清理，基类 _on_died）
	var health := _body.get_node_or_null("Health") as ZombieHealth
	if health != null:
		health.take_damage(health.max_hp + 1.0, _body)


# --- 工具 ---

func _face_target() -> void:
	if _target == null:
		return
	var to := _target.global_position - _body.global_position
	to.y = 0.0
	if to.length_squared() < 0.0001:
		return
	var to_unit := to.normalized()
	_body.rotation.y = atan2(-to_unit.x, -to_unit.z)


func _recompute_direction() -> void:
	if _target == null:
		return
	var dir := _navigation_direction(_target.global_position, _trigger_range)
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
	_visual_tween.tween_property(_visual, "scale", Vector3(1.35, 1.35, 1.35), _explode_windup_s * 0.6)
	_visual_tween.tween_property(_visual, "scale", Vector3(1.15, 1.15, 1.15), _explode_windup_s * 0.4)
