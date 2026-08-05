## player_controller.gd — 第一人称玩家控制器
## 职责：WASD 移动 / Space 跳跃 / 鼠标视角（yaw 转身体、pitch 转 Head，clamp ±89°）；
##       配置 MultiplayerSynchronizer 同步 position/rotation/pitch；鼠标捕获（A5 验收）；
##       交互键 E：S4 补给点拾取优先（supply_points 组最近点 → request_pickup）→ 救援逻辑
##       M3-S1：左键开火（自动武器按住连发 _poll_auto_fire / 半自动按一次打一发）+ 数字键 1-4 切枪
## 输入：Input 动作（move_forward/back/left/right/jump）+ 鼠标事件；
##       MultiplayerSynchronizer 接收远端同步值
## 输出：修改自身 velocity/transform；authority 侧由同步器 20Hz 上报位置
## 谁调用：player.tscn 场景 root；仅 is_multiplayer_authority() 处理输入（远端只显示）
## 规范：tech-plan §3.2 / §6.1（Head 与 Body 分离，俯仰不转身体）

extends CharacterBody3D

const WALK_SPEED := 5.0       # 米/秒，移动速度
const JUMP_VELOCITY := 4.5    # 米/秒，起跳初速度

@export var mouse_sensitivity := 0.002  # 弧度/像素，鼠标灵敏度

## 头部俯仰角（弧度）。由同步器跨端同步；setter 负责同步驱动 Head 旋转
@export var pitch: float = 0.0:
	set(value):
		pitch = value
		if _head != null:
			_head.rotation.x = value

@onready var _head: Node3D = $Head
@onready var _camera: Camera3D = $Head/Camera

## 切枪数字键（M3-S1：数字键 1-4 对应 WeaponPivot 下武器列表顺序；各自弹药独立）
const _WEAPON_KEYS := [KEY_1, KEY_2, KEY_3, KEY_4]

## WeaponPivot 下的武器列表（S4：数字键切枪；列表顺序=切枪顺序）
var _weapons: Array[WeaponBase] = []
var _current_weapon_index := 0
## 左键按住状态（M3-S1 自动武器连发）：按下置 true、松开置 false；轮询只对 auto 武器开火
var _fire_held := false


func _ready() -> void:
	add_to_group("players")  # HUD 等按组找本地玩家（tech-plan §8.4 用组代替长引用链）
	_setup_sync()
	_collect_weapons()
	_place_at_spawn_point()
	if is_multiplayer_authority():
		_camera.current = true
		# 延迟一帧捕获：场景切换瞬间窗口可能未聚焦，立即设置不生效（M1-INPUT）
		_capture_mouse.call_deferred()


## M2-S5 缺陷修复：4.7 要求同步器 authority 在 _enter_tree 设置（早于 _ready 的 _setup_sync）。
## 若 authority 在 add_child 前/实例化时设置，客户端本地玩家副本的 PlayerSync 会报
## "unable to process the pending spawn since it has no network ID" 而创建失败。
## 服务器 spawn 时节点名 = str(peer_id)，两端一致（Godot 官方推荐 name.to_int() 模式）
func _enter_tree() -> void:
	if name.is_valid_int():
		set_multiplayer_authority(name.to_int())


## 捕获鼠标（A5）：延迟一帧执行，等待窗口聚焦
func _capture_mouse() -> void:
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


## 鼠标进入窗口时若未捕获则重试（场景切换后窗口失焦再聚焦会丢捕获）
func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_MOUSE_ENTER and is_multiplayer_authority():
		if Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
			_capture_mouse()


## 配置同步：position / rotation / pitch，20Hz（tech-plan §10 玩家同步指标）
func _setup_sync() -> void:
	var sync := $PlayerSync as MultiplayerSynchronizer
	var cfg := SceneReplicationConfig.new()
	# 4.7 要求：先 add_property() 注册属性，再 property_set_replication_mode() 设模式；
	# 属性路径相对同步器 root_path（默认 ..，即 Player 自身），"." 指根节点，":" 分隔属性名
	cfg.add_property(NodePath(".:position"))
	cfg.property_set_replication_mode(NodePath(".:position"), SceneReplicationConfig.REPLICATION_MODE_ALWAYS)
	cfg.add_property(NodePath(".:rotation"))
	cfg.property_set_replication_mode(NodePath(".:rotation"), SceneReplicationConfig.REPLICATION_MODE_ALWAYS)
	cfg.add_property(NodePath(".:pitch"))
	cfg.property_set_replication_mode(NodePath(".:pitch"), SceneReplicationConfig.REPLICATION_MODE_ALWAYS)
	sync.replication_config = cfg
	sync.replication_interval = 0.05


## 确定性出生：所有端按节点 authority 取同一出生点，避免首次同步前的闪位
func _place_at_spawn_point() -> void:
	var points := get_tree().get_nodes_in_group("spawn_point")
	if points.is_empty():
		return
	var index := (get_multiplayer_authority() - 1) % points.size()
	global_position = (points[index] as Node3D).global_position


func _unhandled_input(event: InputEvent) -> void:
	if not is_multiplayer_authority():
		return
	# Esc 释放鼠标（A5）
	if event.is_action_pressed("ui_cancel"):
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		return
	# 点击窗口重新捕获（A5）：仅鼠标可见（Esc 释放后）时点击才重新捕获；
	# 已捕获（CAPTURED）状态下左键直接走开火分支，不再被此分支吞掉（M1-INPUT）
	if event is InputEventMouseButton and event.pressed and Input.mouse_mode == Input.MOUSE_MODE_VISIBLE:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
		return
	# 鼠标视角：yaw 作用于身体（rotation.y），pitch 作用于 Head（rotation.x）
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		var ps := get_node_or_null("Health") as PlayerState
		if ps != null and ps.state == PlayerState.State.DEAD:
			return  # 死亡：冻结视角（DOWN 保留视角）
		rotation.y = rotation.y - event.relative.x * mouse_sensitivity
		pitch = clampf(
			pitch - event.relative.y * mouse_sensitivity,
			deg_to_rad(-89.0),
			deg_to_rad(89.0)
		)
		return
	# 交互键 E：倒地自救援（单机调试）/ 救援附近倒地队友（多人）
	if event.is_action_pressed("interact"):
		_on_interact_pressed()
		return
	if event.is_action_released("interact"):
		_on_interact_released()
		return
	# 开火（左键）：按下即打一发（半自动按一次打一发；自动武器按下后由 _poll_auto_fire
	# 在 _physics_process 持续开火接管，松开停止）。_fire_held 记录按住状态（M3-S1）
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		_fire_held = event.pressed
		if not event.pressed:
			return
		var ps := get_node_or_null("Health") as PlayerState
		if ps != null and ps.state == PlayerState.State.ALIVE:
			var weapon := _get_weapon()
			if weapon != null:
				weapon.try_fire()
		return
	# 换弹（R）
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_R:
		var weapon := _get_weapon()
		if weapon != null:
			weapon.try_reload()
		return
	# 切枪：数字键 1-4（对应 WeaponPivot 下武器列表顺序；各自弹药独立，M3-S1 扩至 4 把）
	if event is InputEventKey and event.pressed and not event.echo:
		for i in _WEAPON_KEYS.size():
			if event.keycode == _WEAPON_KEYS[i]:
				_set_active_weapon(i)
				return
	# 临时调试：按 K 对自己扣 20 血（S1 冒烟 C1 验证用；M2 移除）
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_K:
		if NetworkManager.is_server():  # 伤害只走服务器（tech-plan §4.2）；客户端按 K 不生效
			var state := get_node_or_null("Health") as PlayerState
			if state != null:
				state.take_damage(20.0)
		return


## 交互键 E 按下：S4 补给点优先（交互区更近、瞬时结算）→ 再走救援（多人/单机自救援）
func _on_interact_pressed() -> void:
	# 补给点优先级高于救援：拾取是瞬时动作，且补给点常在脚边，先结算不打断救援流
	var supply := _find_nearby_supply()
	if supply != null:
		if NetworkManager.is_server():
			supply.request_pickup()  # 单机/主机：服务器进程直接结算（无 peer 时 rpc 行为不可靠）
		else:
			supply.request_pickup.rpc_id(NetworkManager.SERVER_ID)
		return
	var ps := get_node_or_null("Health") as PlayerState
	if ps == null:
		return
	match ps.state:
		PlayerState.State.DOWN:
			# 单机调试：无队友实体，由服务器进程直接执行救援（C5 验证用；M2 移除）
			if NetworkManager.is_server():
				ps._debug_self_revive()
		PlayerState.State.ALIVE:
			var target_peer := _find_down_target_peer()
			if target_peer > 0:
				ps.request_revive.rpc_id(NetworkManager.SERVER_ID, target_peer)
		PlayerState.State.DEAD:
			pass  # 已死亡：不响应


## 交互键 E 松开：取消救援（服务器复校验后取消）
func _on_interact_released() -> void:
	var ps := get_node_or_null("Health") as PlayerState
	if ps != null:
		ps.cancel_revive.rpc_id(NetworkManager.SERVER_ID)


## 找救援范围内最近的倒地玩家（客户端选目标；服务器会复校验）
func _find_down_target_peer() -> int:
	var best_peer := -1
	var best_dist := PlayerState.REVIVE_RANGE
	for p in get_tree().get_nodes_in_group("players"):
		if p == self:
			continue
		var ps := p.get_node_or_null("Health") as PlayerState
		if ps == null or ps.state != PlayerState.State.DOWN:
			continue
		var dist := global_position.distance_to(p.global_position)
		if dist <= best_dist:
			best_dist = dist
			best_peer = p.get_multiplayer_authority()
	return best_peer


## 找拾取范围内最近的补给点（S4；客户端选目标，服务器复验距离/已用）。
## 优先级高于救援：补给点交互区与救援范围相近（2.5m），拾取为瞬时结算
func _find_nearby_supply() -> SupplyPoint:
	var best: SupplyPoint = null
	var best_dist := SupplyPoint.PICKUP_RANGE
	for s in get_tree().get_nodes_in_group("supply_points"):
		var dist := global_position.distance_to(s.global_position)
		if dist <= best_dist:
			best_dist = dist
			best = s as SupplyPoint
	return best


## 收集 WeaponPivot 下的武器（顺序即数字键 1/2 切枪顺序），默认激活第 0 把
func _collect_weapons() -> void:
	_weapons.clear()
	var pivot := get_node_or_null("WeaponPivot")
	if pivot == null:
		return
	for child in pivot.get_children():
		var w := child as WeaponBase
		if w != null:
			_weapons.append(w)
	_set_active_weapon(0)


## 切换激活武器：可见性即激活标记（弹药各自独立，由每个武器节点自身维护）
func _set_active_weapon(index: int) -> void:
	if index < 0 or index >= _weapons.size():
		return
	_current_weapon_index = index
	for i in _weapons.size():
		_weapons[i].visible = (i == index)


## 当前武器（WeaponPivot 下激活的那把）
func _get_weapon() -> WeaponBase:
	if _weapons.is_empty():
		return null
	return _weapons[_current_weapon_index]


## 自动武器连发轮询（M3-S1）：_fire_held（按住左键）时对 auto 武器持续 try_fire。
## 服务器侧由 _cooldown_timer 按 fire_rate 限速；半自动（auto=false）不在此连发——
## 只在 _unhandled_input 的按下事件打一发（按一次打一发）。独立成函数便于 headless
## 调试脚本注入按住状态实证（tools/debug_weapon.gd）
func _poll_auto_fire() -> void:
	if not _fire_held:
		return
	var ps := get_node_or_null("Health") as PlayerState
	if ps != null and ps.state != PlayerState.State.ALIVE:
		return
	var weapon := _get_weapon()
	if weapon == null or not weapon.auto:
		return
	weapon.try_fire()


func _physics_process(delta: float) -> void:
	# 远端玩家不做输入，只由同步器更新 transform
	if not is_multiplayer_authority():
		return
	var ps := get_node_or_null("Health") as PlayerState
	if ps != null and ps.state != PlayerState.State.ALIVE:
		# DOWN/DEAD：移动禁用（DOWN 视角保留，DEAD 视角在 _unhandled_input 冻结）
		velocity = Vector3.ZERO
		return
	var input_dir := Input.get_vector("move_left", "move_right", "move_forward", "move_back")
	var direction := (transform.basis * Vector3(input_dir.x, 0, input_dir.y)).normalized()
	if direction != Vector3.ZERO:
		velocity.x = direction.x * WALK_SPEED
		velocity.z = direction.z * WALK_SPEED
	else:
		velocity.x = move_toward(velocity.x, 0.0, WALK_SPEED)
		velocity.z = move_toward(velocity.z, 0.0, WALK_SPEED)
	if not is_on_floor():
		# 注意：get_gravity().y 为负（默认 -9.8），必须 **加** 它才会向下加速；
		# 之前写成减号导致反重力（跳跃后会越飘越高，M1-ZOMBIE 与丧尸同源，f5ac73c 引入）
		velocity.y = velocity.y + get_gravity().y * delta
	if Input.is_action_just_pressed("jump") and is_on_floor():
		velocity.y = JUMP_VELOCITY
	move_and_slide()
	# 自动武器连发轮询：按住左键对 auto 武器持续开火（半自动按一次打一发，不连发）
	_poll_auto_fire()
