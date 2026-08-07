## zombie_ai_common.gd — 普通丧尸状态机（Idle/Chase/Attack/Dead，tech-plan §5.4）
## 简化导航 + 分帧 AI 预算（director.json ai_budget 可配）+ 服务器权威死亡回池；
## 仅服务器执行；reset_for_pool 由 ZombiePool 回池调用（复位不彻底=死尸复活）
## M3-S7：追踪嘶吼拆独立文件 zombie_growl.gd（防本文件超 300 行，M3-S4 拆 budget 先例）

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
const AVOID_SECONDS := 2.0       # 无导航网格时沿碰撞面绕行的最长时间
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
var _navigation_agent: NavigationAgent3D = null
var _avoid_dir := Vector3.ZERO
var _avoid_timer := 0.0

## 死亡表现/清理 tween 引用：回池时须 kill，防淡出/清理计时作用于复活的丧尸（M2-S3a）
var _fade_tween: Tween = null
var _cleanup_tween: Tween = null

## 分帧预算静态计数（跨所有丧尸实例共享，按物理帧轮询）
static var _ai_last_frame := 0
static var _ai_updated_this_frame := 0


func _enter_tree() -> void:
	_body = get_parent() as CharacterBody3D
	_setup_sync()


func _ready() -> void:
	_body = get_parent() as CharacterBody3D
	if _body == null:
		return
	_ensure_navigation_agent()
	_ensure_growl_ctrl()  # M3-S7：嘶吼控制器挂接（幂等：复用节点仅重设随机相位）
	var health := get_node_or_null("../Health") as Damageable
	# 幂等（M3-S1 回归）：request_ready 每次重跑，died 连接/同步器配置须判重（防重复回池）
	if health != null and not health.died.is_connected(_on_died):
		health.died.connect(_on_died)
	ZombieAIBudget.ensure_loaded()  # 分帧预算参数（director.json ai_budget，M3-S4）
	_apply_visibility_range()


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
	# 有导航网格时每个物理帧推进路径；旧关卡回退每 1.5s 更新直线/绕障方向。
	_avoid_timer = maxf(_avoid_timer - delta, 0.0)
	var has_navigation := _has_navigation_map()
	if has_navigation:
		_recompute_direction()
	else:
		_retarget_timer -= delta
	if not has_navigation and _retarget_timer <= 0.0:
		_retarget_timer = RETARGET_INTERVAL
		_recompute_direction()
	_body.velocity.x = _move_dir.x * MOVE_SPEED
	_body.velocity.z = _move_dir.z * MOVE_SPEED
	if not _body.is_on_floor():
		# get_gravity().y 为负，必须 **加** 才向下加速（M1-ZOMBIE 反重力根因 f5ac73c）
		_body.velocity.y = _body.velocity.y + _body.get_gravity().y * delta
	_body.move_and_slide()
	_update_collision_avoidance()


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


## 导航网格存在时取下一路径点；否则使用直线方向和局部碰撞绕障。
func _recompute_direction() -> void:
	if _target == null:
		return
	var destination := _target.global_position
	if _has_navigation_map():
		_navigation_agent.target_position = destination
		if not _navigation_agent.is_navigation_finished():
			destination = _navigation_agent.get_next_path_position()
	elif _avoid_timer > 0.0:
		if _has_clear_path_to_target():
			_avoid_timer = 0.0
		else:
			_set_move_direction(_avoid_dir)
			return
	var to := destination - _body.global_position
	to.y = 0.0
	if to.length_squared() < 0.0001:
		return
	_set_move_direction(to.normalized())


func _set_move_direction(dir: Vector3) -> void:
	_move_dir = dir
	_body.rotation.y = atan2(-dir.x, -dir.z)  # 让 -z 朝向目标


## 有导航网格时使用 NavigationAgent3D；当前关卡无网格时由碰撞绕障回退接管。
func _ensure_navigation_agent() -> void:
	_navigation_agent = _body.get_node_or_null("NavigationAgent3D") as NavigationAgent3D
	if _navigation_agent == null:
		_navigation_agent = NavigationAgent3D.new()
		_navigation_agent.name = "NavigationAgent3D"
		_body.call_deferred("add_child", _navigation_agent)
	_navigation_agent.path_desired_distance = 0.4
	_navigation_agent.target_desired_distance = ATTACK_RANGE
	_navigation_agent.radius = 0.4
	_navigation_agent.height = 1.7


func _has_navigation_map() -> bool:
	if _navigation_agent == null or not _navigation_agent.is_inside_tree():
		return false
	var map_rid := _navigation_agent.get_navigation_map()
	return map_rid.is_valid() and not NavigationServer3D.map_get_regions(map_rid).is_empty()


## 记录撞墙后的切线方向。这个回退只负责现有没有 NavMesh 的旧关卡，避免有限墙永久卡死。
func _update_collision_avoidance() -> void:
	if _has_navigation_map() or _body.get_slide_collision_count() == 0:
		return
	for i in _body.get_slide_collision_count():
		var normal := _body.get_slide_collision(i).get_normal()
		normal.y = 0.0
		if normal.length_squared() < 0.25 or _move_dir.dot(normal) >= -0.1:
			continue
		normal = normal.normalized()
		var tangent_a := normal.cross(Vector3.UP).normalized()
		var tangent_b := -tangent_a
		var probe_distance := 1.5
		var target_pos := _target.global_position if _target != null else _body.global_position
		var distance_a := (_body.global_position + tangent_a * probe_distance).distance_squared_to(target_pos)
		var distance_b := (_body.global_position + tangent_b * probe_distance).distance_squared_to(target_pos)
		_avoid_dir = tangent_a if distance_a <= distance_b else tangent_b
		_avoid_timer = AVOID_SECONDS
		_retarget_timer = 0.0
		return


func _has_clear_path_to_target() -> bool:
	if _target == null or _body.get_world_3d() == null:
		return false
	var from := _body.global_position + Vector3.UP * 0.8
	var to := _target.global_position + Vector3.UP * 0.8
	var query := PhysicsRayQueryParameters3D.create(from, to, 1, [_body.get_rid()])
	return _body.get_world_3d().direct_space_state.intersect_ray(query).is_empty()


## 死亡（服务器 Health.died）：进 Dead 并广播 zombie_died（所有端播死亡表现 + 清理）；
## 掉落/击杀统计由 LootManager 处理（服务器，S6）
func _on_died(_attacker: Node) -> void:
	state = State.DEAD
	_broadcast_zombie_died()
	_notify_loot_manager()
	set_physics_process(false)


## 通知掉落系统（服务器）：经组动态 call（不引 LootManager 类型，防 M2-S3 加载环）
func _notify_loot_manager() -> void:
	var lm := get_tree().get_first_node_in_group("loot_manager")
	if lm != null:
		lm.call("on_zombie_died", _body)


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


## 死亡清理回调：服务器回池复用；联网客户端等待服务器 Spawner despawn；
## 单机且无池的独立测试场景才本地 queue_free（不引 ZombiePool 类型防加载环）。
func _free_zombie() -> void:
	if not is_instance_valid(_body):
		return
	var pool := get_tree().get_first_node_in_group("zombie_pool")
	if pool != null:
		pool.call("despawn_to_pool", _body)
	elif NetworkManager.is_network_active() and not NetworkManager.is_server():
		return
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
	_avoid_dir = Vector3.ZERO
	_avoid_timer = 0.0
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


## 嘶吼控制器挂接（M3-S7，独立文件 zombie_growl.gd）：幂等，_ready 每次出池重跑仅重设随机相位
func _ensure_growl_ctrl() -> void:
	var ctrl := get_node_or_null("GrowlCtrl") as ZombieGrowl
	if ctrl == null:
		ctrl = ZombieGrowl.new()
		ctrl.name = "GrowlCtrl"
		add_child(ctrl)
	ctrl.setup(self, _body)


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
