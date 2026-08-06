## zombie_ai_spitter.gd — 特感·喷吐者 AI（M3-S3；Spitter 原型改名避版权，GDD 附录 A）
## 职责：状态机 Idle→Chase(中距离拉扯)→SpitWindup(前摇吐酸)→Dead；远距吐酸制造地面酸液
##       区域逼迫走位：进入射程 [8m, 25m] 站定前摇（0.8s）→ 按目标移动提前量（0.6s）预测
##       落点 → 生成 acid_pool（Area3D 半径 2.5m/持续 6s/DPS 10，zombies.json 驱动）；
##       被近身（< spit_min_range_m）后退保持距离，不贴身近战（任务卡 G4a）
## 继承：ZombieSpecialAI（公共：zombies.json 数据驱动/死亡链路/同步/玩家检索/音效钩子）
## 输入：Health.died 信号（基类接线）；players 组取最近玩家（基类 _nearest_player）
## 输出：驱动父节点 CharacterBody3D 位移/朝向；吐酸经 spawn_acid_pool（authority RPC，
##       call_local）在全体端本地生成 AcidPool（视觉一致）；酸液伤害由 AcidPool 服务器 tick 结算
## 谁调用：仅服务器执行 AI（NetworkManager.is_server() 才跑，tech-plan §5.4）；客户端纯显示
## 规范：单文件 ≤300 行；前摇表现基元占位（视觉放大脉冲 + 音效钩子），骨骼动画 M3 后期替换

class_name ZombieSpitterAI
extends ZombieSpecialAI

enum State { IDLE, CHASE, SPIT_WINDUP, DEAD }

const ACID_POOL_SCENE := preload("res://scenes/enemies/acid_pool.tscn")
const LANDING_Y := 0.05  # 酸区落点离地高度（米，与 acid_pool.gd 一致）

var state: State = State.IDLE

var _target: Node3D = null
var _move_dir := Vector3.FORWARD
var _retarget_timer := 0.0
var _spit_cooldown := 0.0
var _windup_timer := 0.0

# --- 数据驱动参数（默认值 = zombies.json spitter 草案；_apply_params 覆盖，改 JSON 重启生效） ---
var _move_speed := 2.0
var _chase_range := 45.0
var _sight_range := 30.0
var _keep_distance := 14.0
var _spit_windup_s := 0.8
var _spit_range := 25.0
var _spit_min_range := 8.0
var _spit_lead := 0.6
var _acid_radius := 2.5
var _acid_duration := 6.0
var _acid_dps := 10.0
var _cooldown_s := 4.0


func _ready() -> void:
	super._ready()  # 基类：body 引用/数据驱动加载/死亡接线/同步配置


func _params_id() -> String:
	return "spitter"


func _apply_params() -> void:
	_move_speed = float(_params.get("move_speed", _move_speed))
	_chase_range = float(_params.get("chase_range_m", _chase_range))
	_sight_range = float(_params.get("sight_range_m", _sight_range))
	_keep_distance = float(_params.get("keep_distance_m", _keep_distance))
	var sp: Dictionary = _params.get("special", {})
	_spit_windup_s = float(sp.get("spit_windup_s", _spit_windup_s))
	_spit_range = float(sp.get("spit_range_m", _spit_range))
	_spit_min_range = float(sp.get("spit_min_range_m", _spit_min_range))
	_spit_lead = float(sp.get("spit_lead_seconds", _spit_lead))
	_cooldown_s = float(sp.get("cooldown_s", _cooldown_s))
	var acid: Dictionary = sp.get("acid", {})
	_acid_radius = float(acid.get("radius_m", _acid_radius))
	_acid_duration = float(acid.get("duration_s", _acid_duration))
	_acid_dps = float(acid.get("dps", _acid_dps))


func _death_sfx_event() -> String:
	return "spitter_death"


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
		State.SPIT_WINDUP:
			_tick_spit_windup(delta)


# --- 状态行为 ---

func _tick_idle() -> void:
	var target := _nearest_player()
	if target != null and _body.global_position.distance_to(target.global_position) <= _sight_range:
		_target = target
		state = State.CHASE


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
	if _spit_cooldown > 0.0:
		_spit_cooldown = maxf(_spit_cooldown - delta, 0.0)
	# 射程内 + 冷却就绪 + 目标存活 → 站定前摇吐酸（优先级最高）
	if _spit_cooldown <= 0.0 and dist >= _spit_min_range and dist <= _spit_range and _target_alive():
		_start_spit_windup()
		return
	# 中距离拉扯：被近身后退 / 过远前压 / 靠近 keep_distance 微调；始终朝向目标
	_face_target()
	_retarget_timer -= delta
	if _retarget_timer <= 0.0:
		_retarget_timer = 1.0
		_recompute_move_dir(dist)
	_body.velocity.x = _move_dir.x * _move_speed
	_body.velocity.z = _move_dir.z * _move_speed
	if not _body.is_on_floor():
		_body.velocity.y = _body.velocity.y + _body.get_gravity().y * delta
	_body.move_and_slide()


func _start_spit_windup() -> void:
	state = State.SPIT_WINDUP
	_windup_timer = _spit_windup_s
	_face_target()  # 前摇站定，锁定朝向
	_play_sfx("spit_windup")  # 音效钩子（S7 接素材，缺失静默跳过）
	_pulse_visual()  # 前摇表现：视觉放大脉冲（基元占位）


func _tick_spit_windup(delta: float) -> void:
	_body.velocity = Vector3.ZERO
	_body.move_and_slide()
	_windup_timer -= delta
	if _windup_timer > 0.0:
		return
	if _target == null or not _target_alive():
		_reset_visual()
		state = State.CHASE
		return
	_spit()
	_spit_cooldown = _cooldown_s  # 吐完进入冷却（数据驱动），期间维持距离拉扯
	_reset_visual()
	state = State.CHASE


## 吐酸：目标当前位置 + 水平移动速度 × 提前量 → 预测落点生成酸液区（直线落地，无弹道投射物）
func _spit() -> void:
	var predicted := _target.global_position
	if _target is CharacterBody3D:
		var tv := (_target as CharacterBody3D).velocity
		predicted.x = predicted.x + tv.x * _spit_lead
		predicted.z = predicted.z + tv.z * _spit_lead
	predicted.y = LANDING_Y
	_play_sfx("acid_land", predicted)
	_spawn_acid_pool(predicted)


# --- 酸液区生成（authority RPC：各端本地创建，视觉一致；伤害仅服务器结算） ---

func _spawn_acid_pool(pos: Vector3) -> void:
	if NetworkManager.is_network_active():
		spawn_acid_pool.rpc(pos)
	else:
		spawn_acid_pool(pos)


## [authority] 服务器→所有人：在落点生成 AcidPool。数据参数取自各端同一份 zombies.json，
## 故无需 RPC 传参；挂 World 容器（避开 Zombies 的 MultiplayerSpawner，不走复制通道）
@rpc("authority", "call_local", "reliable")
func spawn_acid_pool(pos: Vector3) -> void:
	var pool: Area3D = ACID_POOL_SCENE.instantiate()
	pool.set("radius", _acid_radius)
	pool.set("duration_s", _acid_duration)
	pool.set("dps", _acid_dps)
	pool.set("owner_node", _body)
	pool.set_multiplayer_authority(NetworkManager.SERVER_ID)
	var world := get_tree().current_scene.get_node_or_null("World")
	if world != null:
		world.add_child(pool)
	else:
		get_tree().current_scene.add_child(pool)
	pool.global_position = pos


# --- 工具 ---

func _target_alive() -> bool:
	var ps := _target.get_node_or_null("Health") as PlayerState
	return ps != null and ps.state == PlayerState.State.ALIVE


## 始终朝向目标（吐酸方向基准）；-z 指向目标（与普通丧尸/冲撞者一致）
func _face_target() -> void:
	if _target == null:
		return
	var to := _target.global_position - _body.global_position
	to.y = 0.0
	if to.length_squared() < 0.0001:
		return
	var to_unit := to.normalized()
	_body.rotation.y = atan2(-to_unit.x, -to_unit.z)


## 每 1s 重算一次位移方向（简化导航：直线推进，不寻路）。距离策略决定进退
func _recompute_move_dir(dist: float) -> void:
	if _target == null:
		return
	var to := _target.global_position - _body.global_position
	to.y = 0.0
	if to.length_squared() < 0.0001:
		return
	var to_unit := to.normalized()
	if dist < _spit_min_range:
		_move_dir = -to_unit          # 被近身 → 后退拉开距离
	elif dist > _spit_range:
		_move_dir = to_unit           # 超出射程 → 前压
	elif dist > _keep_distance:
		_move_dir = -to_unit          # 略近于保持距离 → 微退
	else:
		_move_dir = to_unit           # 略远于保持距离 → 微进


# --- 死亡（基类处理死亡表现/清理；本类补 state=DEAD） ---

func _on_died(_attacker: Node) -> void:
	state = State.DEAD
	super._on_died(_attacker)


# --- 前摇视觉表现（基元占位，与冲撞者同款） ---

func _pulse_visual() -> void:
	if _visual == null:
		return
	_kill_visual_tweens()
	_visual.scale = Vector3.ONE
	_visual_tween = create_tween()
	_visual_tween.tween_property(_visual, "scale", Vector3(1.25, 1.25, 1.25), _spit_windup_s * 0.5)
	_visual_tween.tween_property(_visual, "scale", Vector3(1.05, 1.05, 1.05), _spit_windup_s * 0.5)


func _reset_visual() -> void:
	if _visual == null:
		return
	_kill_visual_tweens()
	_visual.scale = Vector3.ONE
