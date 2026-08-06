## zombie_ai_common.gd — 普通丧尸状态机（Idle/Chase/Attack/Dead，tech-plan §5.4）
## 简化导航 + 分帧 AI 预算（director.json ai_budget 可配）+ 服务器权威死亡回池；
## 仅服务器执行；reset_for_pool 由 ZombiePool 回池调用（复位不彻底=死尸复活）

class_name ZombieAI
extends Node

enum State { IDLE, CHASE, ATTACK, DEAD }

const CHASE_RANGE := 20.0        # 米，超过回 Idle
const ATTACK_RANGE := 1.8        # 米，进入近战
const ATTACK_DAMAGE := 10.0      # 每次近战伤害
const ATTACK_WINDUP := 0.5       # 秒，前摇（表现由 S6 接）
const ATTACK_COOLDOWN := 1.0     # 秒，攻击冷却
const RETARGET_INTERVAL := 1.5   # 秒，重算朝向/移动方向（简化导航）
const MOVE_SPEED := 3.0          # 米/秒，追踪速度
const DEATH_FADE_TIME := 0.6     # 秒，死亡后 Visual 缩放淡出
const DEATH_CLEANUP_DELAY := 1.5 # 秒，死亡后清理（M2-S3a：延迟到回池，防泄漏）
const COLLISION_LAYER := 4       # 身体碰撞层（敌人层，M1-S5 碰撞层方案）
const COLLISION_MASK := 5        # 世界1 + 敌人4

var state: State = State.IDLE

var _body: CharacterBody3D
var _target: Node3D = null
var _move_dir := Vector3.FORWARD
var _retarget_timer := 0.0
var _attack_cooldown := 0.0
var _windup_timer := 0.0

## 死亡表现/清理 tween 引用：回池时须 kill，防淡出/清理计时作用于复活的丧尸（M2-S3a）
var _fade_tween: Tween = null
var _cleanup_tween: Tween = null

## 分帧预算静态计数（跨所有丧尸实例共享，按物理帧轮询）
static var _ai_last_frame := 0
static var _ai_updated_this_frame := 0


func _ready() -> void:
	_body = get_parent() as CharacterBody3D
	if _body == null:
		return
	var health := get_node_or_null("../Health") as Damageable
	# 幂等（M3-S1 回归）：request_ready 每次重跑，died 连接/同步器配置须判重（防重复回池）
	if health != null and not health.died.is_connected(_on_died):
		health.died.connect(_on_died)
	ZombieAIBudget.ensure_loaded()  # 分帧预算参数（director.json ai_budget，M3-S4）
	_apply_visibility_range()
	_setup_sync()


func _physics_process(delta: float) -> void:
	# AI 只在服务器跑（tech-plan §4.2/§5.4）；客户端纯显示
	if not NetworkManager.is_server():
		return
	if state == State.DEAD:
		return
	if not _ai_budget_ok():
		return  # 分帧预算：本帧跳过，轮询下帧
	match state:
		State.IDLE:
			_tick_idle()
		State.CHASE:
			_tick_chase(delta)
		State.ATTACK:
			_tick_attack(delta)


# --- 状态行为 ---

func _tick_idle() -> void:
	var target := _nearest_player()
	if target != null and _body.global_position.distance_to(target.global_position) <= CHASE_RANGE:
		_target = target
		state = State.CHASE


func _tick_chase(delta: float) -> void:
	var target := _nearest_player()
	if target == null:
		state = State.IDLE
		return
	_target = target
	var dist := _body.global_position.distance_to(target.global_position)
	if dist > CHASE_RANGE:
		state = State.IDLE
		return
	if dist <= ATTACK_RANGE:
		state = State.ATTACK
		_windup_timer = ATTACK_WINDUP
		return
	# 简化导航：按缓存方向直线移动，每 1.5s 重算朝向/方向（不寻路）
	_retarget_timer -= delta
	if _retarget_timer <= 0.0:
		_retarget_timer = RETARGET_INTERVAL
		_recompute_direction()
	_body.velocity.x = _move_dir.x * MOVE_SPEED
	_body.velocity.z = _move_dir.z * MOVE_SPEED
	if not _body.is_on_floor():
		# get_gravity().y 为负，必须 **加** 才向下加速（M1-ZOMBIE 反重力根因 f5ac73c）
		_body.velocity.y = _body.velocity.y + _body.get_gravity().y * delta
	_body.move_and_slide()


func _tick_attack(delta: float) -> void:
	var health := _get_target_health()
	if health == null or health.state == PlayerState.State.DEAD:
		state = State.IDLE
		return
	if _body.global_position.distance_to(_target.global_position) > ATTACK_RANGE * 1.5:
		state = State.CHASE  # 目标拉开 → 追击（放宽阈值防抖动）
		return
	# 前摇 → 命中（走服务器权威伤害）
	_windup_timer -= delta
	if _windup_timer <= 0.0:
		_windup_timer = ATTACK_WINDUP
		if _attack_cooldown <= 0.0:
			health.take_damage(ATTACK_DAMAGE, _body)
			_attack_cooldown = ATTACK_COOLDOWN
	if _attack_cooldown > 0.0:
		_attack_cooldown = maxf(_attack_cooldown - delta, 0.0)
	# 攻击期间保持贴脸（站定挥击；S6 接前摇表现）
	_body.velocity = Vector3.ZERO
	_body.move_and_slide()


# --- 分帧预算（tech-plan §5.4：每帧最多 N 只，其余轮询） ---

func _ai_budget_ok() -> bool:
	var frame := Engine.get_physics_frames()
	if frame != _ai_last_frame:
		_ai_last_frame = frame
		_ai_updated_this_frame = 0
	if _ai_updated_this_frame >= ZombieAIBudget.max_per_frame:
		return false
	_ai_updated_this_frame += 1
	return true


# --- 工具 ---

func _nearest_player() -> Node3D:
	var best: Node3D = null
	var best_dist := INF
	for p in get_tree().get_nodes_in_group("players"):
		if p == _body:
			continue
		var dist := _body.global_position.distance_squared_to(p.global_position)
		if dist < best_dist:
			best_dist = dist
			best = p as Node3D
	return best


func _get_target_health() -> PlayerState:
	if _target == null:
		return null
	return _target.get_node_or_null("Health") as PlayerState


## 每 RETARGET_INTERVAL 重算一次朝向与移动方向（简化导航：直线推进，不寻路）
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


## 死亡（服务器 Health.died）：进 Dead 并广播 zombie_died（所有端播死亡表现 + 清理）
func _on_died(_attacker: Node) -> void:
	state = State.DEAD
	_broadcast_zombie_died()
	set_physics_process(false)


## [authority] 服务器→所有人：丧尸死亡。所有端禁用碰撞、播血雾爆发 + 淡出、定时清理
@rpc("authority", "call_local", "reliable")
func zombie_died() -> void:
	_body.collision_layer = 0
	_body.collision_mask = 0
	_body.velocity = Vector3.ZERO
	_play_sfx("zombie_died")  # 音效钩子（S7 接 AudioStreamPlayer 与素材）
	_play_death_fx()


## 广播死亡：单机（无 peer）直接本地执行；多人走 authority RPC（call_local 覆盖主机视角）
func _broadcast_zombie_died() -> void:
	if NetworkManager.is_network_active():
		zombie_died.rpc()
	else:
		zombie_died()


## 死亡表现（S6）：血雾爆发 + Visual 缩放淡出（tween 引用留存，回池复位时 kill）
func _play_death_fx() -> void:
	var blood := _body.get_node_or_null("BloodPuff") as GPUParticles3D
	if blood != null:
		blood.restart()
	var visual := _body.get_node_or_null("Visual") as Node3D
	if visual != null:
		_fade_tween = create_tween()
		_fade_tween.tween_property(visual, "scale", Vector3.ZERO, DEATH_FADE_TIME)
	_start_death_cleanup()


## 死亡后定时清理（M2-S3a：回调改回池而非 queue_free；客户端/无池场景走 queue_free 兜底）
func _start_death_cleanup() -> void:
	_cleanup_tween = create_tween()
	_cleanup_tween.tween_interval(DEATH_CLEANUP_DELAY)
	_cleanup_tween.tween_callback(_free_zombie)


## 死亡清理回调：服务器回池复用；客户端/无池兜底 queue_free（不引 ZombiePool 类型防加载环）
func _free_zombie() -> void:
	if not is_instance_valid(_body):
		return
	var pool := get_tree().get_first_node_in_group("zombie_pool")
	if pool != null:
		pool.call("despawn_to_pool", _body)
	else:
		_body.queue_free()


## 回池复位（M2-S3a 风险备注 2）：状态/碰撞/速度/残留 tween 全还原，防"死尸复活"
func reset_for_pool() -> void:
	if _body == null:
		return
	state = State.IDLE
	_target = null
	_move_dir = Vector3.FORWARD
	_retarget_timer = 0.0
	_attack_cooldown = 0.0
	_windup_timer = 0.0
	_kill_death_tweens()
	set_physics_process(true)  # _on_died 里关掉了，复活必须恢复
	_body.collision_layer = COLLISION_LAYER
	_body.collision_mask = COLLISION_MASK
	_body.velocity = Vector3.ZERO
	_body.rotation = Vector3.ZERO
	var sync := _body.get_node_or_null("ZombieSync") as MultiplayerSynchronizer
	if sync != null:
		sync.set_multiplayer_authority(NetworkManager.SERVER_ID)  # ZombieSync 复位（服务器角度）


## 杀残留死亡 tween：出池后淡出/清理计时不得继续作用于复活的丧尸（防"隐形丧尸"）
func _kill_death_tweens() -> void:
	if _fade_tween != null and _fade_tween.is_valid():
		_fade_tween.kill()
		_fade_tween = null
	if _cleanup_tween != null and _cleanup_tween.is_valid():
		_cleanup_tween.kill()
		_cleanup_tween = null


## 远处剔除（M3-S4）：visibility_range 60m（tech-plan §5.2），仅真机渲染生效，幂等
func _apply_visibility_range() -> void:
	var visual := _body.get_node_or_null("Visual") as GeometryInstance3D
	if visual != null:
		visual.visibility_range_end = 60.0


## 音效钩子：事件 → SfxPool 播放（素材缺失静默跳过；S7 接线；pos 默认丧尸位置）
func _play_sfx(event: String, pos: Vector3 = Vector3.ZERO) -> void:
	if pos == Vector3.ZERO:
		pos = _body.global_position
	SfxPool.play_3d(event, pos)


## 配置服务器权威 transform 同步（4.7 铁律：先 add_property 再 set_replication_mode；replication_interval 非 sync_interval）
func _setup_sync() -> void:
	var sync := _body.get_node_or_null("ZombieSync") as MultiplayerSynchronizer
	if sync == null:
		return
	# 幂等（M3-S1 回归）：_ready 每次出池重跑，同步器配置只在首次初始化一次（防重复重建配置）
	if sync.replication_config != null:
		return
	sync.set_multiplayer_authority(NetworkManager.SERVER_ID)
	var cfg := SceneReplicationConfig.new()
	cfg.add_property(NodePath(".:position"))
	cfg.property_set_replication_mode(NodePath(".:position"), SceneReplicationConfig.REPLICATION_MODE_ALWAYS)
	cfg.add_property(NodePath(".:rotation"))
	cfg.property_set_replication_mode(NodePath(".:rotation"), SceneReplicationConfig.REPLICATION_MODE_ALWAYS)
	sync.replication_config = cfg
	sync.replication_interval = 0.05  # 20Hz（tech-plan §10 丧尸同步 15-20Hz）
