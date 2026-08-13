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
const SPRINT_SPEED := 7.5
const SLIDE_START_SPEED := 8.5
const SLIDE_DURATION := 0.7
const SLIDE_COOLDOWN := 0.35
const GROUND_ACCEL := 28.0
const GROUND_DECEL := 34.0
const AIR_ACCEL := 8.0
const COYOTE_TIME := 0.12
const JUMP_BUFFER_TIME := 0.12
const JUMP_VELOCITY := 4.5    # 米/秒，起跳初速度
const WORLD_RENDER_LAYER := 1
const VIEW_RENDER_LAYER := 1 << 1

## 脚步/跳跃/落地音频（系统设计 02-设计-音频-系统设计.md §7.2）
const STEP_INTERVAL_WALK := 0.50   # 秒/步（行走步频）
const STEP_INTERVAL_RUN := 0.35    # 秒/步（奔跑步频；未来 Shift 奔跑键复用 run 事件）
const RUN_SPEED_THRESHOLD := 4.0   # 米/秒，水平速度高于此值按"奔跑"脚步
const LAND_FALL_SPEED := 6.0       # 米/秒，落地音触发的最小下落速度
## 脚下材质 → 脚步事件路由（射线命中 StaticBody3D 的节点名关键字，见 _detect_ground_material）
const _STEP_MATERIAL_METAL := ["door", "metal", "plate", "grate", "pipe"]
const _STEP_MATERIAL_DIRT := ["dirt", "soil", "sand", "mud"]

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
var _view_meshes: Array[Node3D] = []
var _current_weapon_index := 0
var primary_weapon_id := ""
var claimed_weapon_stands: Array[String] = []
var grenade_count := 0
var molotov_count := 0
## 左键按住状态（M3-S1 自动武器连发）：按下置 true、松开置 false；轮询只对 auto 武器开火
var _fire_held := false
## 脚步/落地状态（仅本地玩家使用）
var _step_timer := 0.0
var _was_on_floor := true
var _fall_speed := 0.0
var _slide_timer := 0.0
var _slide_cooldown := 0.0
var _slide_direction := Vector3.ZERO
var _coyote_timer := 0.0
var _jump_buffer_timer := 0.0
var _vaulting := false
var _vault_elapsed := 0.0
var _vault_from := Vector3.ZERO
var _vault_to := Vector3.ZERO
const VAULT_DURATION := 0.28
var _mouse_capture_requested := true

## 幸存者皮肤方案（美术方向 §3.1：换皮不换网，材质 albedo_color 变体；避纯蓝紫，留蓝紫给环境）。
## 每套 = 主体色（body，皮肤/服饰主色）+ 强调色（accent，袖口/胸甲/手套），比单色换皮观感更丰富。
## 按 peer authority 取模分配，所有端对同一玩家算出同一方案（第三人称 Body 与第一人称手臂观感一致）。
const SKIN_PALETTES: Array[Dictionary] = [
	{"body": Color(1.0, 0.79, 0.24), "accent": Color(0.30, 0.22, 0.14)},   # 安全黄 + 深棕
	{"body": Color(0.24, 0.86, 0.52), "accent": Color(0.08, 0.32, 0.18)},   # 医疗绿 + 深绿
	{"body": Color(1.0, 0.48, 0.18), "accent": Color(0.35, 0.16, 0.08)},    # 信号橙 + 深红棕
	{"body": Color(0.78, 0.80, 0.83), "accent": Color(0.28, 0.30, 0.34)},   # 灰白 + 深灰
]

## 第一人称 viewmodel 动画状态（美术方向 §5.1：sway 鼠标随动 / bob 步伐 / recoil 后坐 / reload 换弹下压）
## 仅本地玩家 authority 使用；动画偏移作用在 Head/Camera/ViewMesh 根节点（相机子节点、rotation 默认 0，
## 绕其 X/Y 轴即相机水平/垂直轴，避免枪 glb 自身 rotation.y=π 带来的符号翻转）
var _view_root: Node3D = null
var _view_root_base_pos := Vector3.ZERO
var _view_root_base_rot := Vector3.ZERO
var _recoil := 0.0                    # 后坐上抬角度（度），开火 +2.5°，快速衰减回弹
var _sway := Vector2.ZERO             # 平滑后的鼠标随动（x=俯仰 y=水平）
var _sway_target := Vector2.ZERO      # 鼠标累积目标，随帧回中
var _bob_time := 0.0                  # 步伐摆动相位
var _reload_level := 0.0              # 换弹下压强度 0..1（reloading 时升到 1，结束回 0）


func _ready() -> void:
	add_to_group("players")  # HUD 等按组找本地玩家（tech-plan §8.4 用组代替长引用链）
	_configure_weapon_visuals()
	_collect_weapons()
	_apply_skin()
	_place_at_spawn_point()
	if is_multiplayer_authority():
		_camera.current = true
		# 延迟一帧捕获：场景切换瞬间窗口可能未聚焦，立即设置不生效（M1-INPUT）
		_capture_mouse.call_deferred()


## 幸存者皮肤：按 peer authority 取模选方案，对 Body（第三人称）与 Arms（第一人称手臂）统一换色。
## 换皮不换网：按 surface index 决定主体/强调色（surface 0=主体、surface 1=强调），duplicate 材质避免污染共享资源。
func _apply_skin() -> void:
	var palette: Dictionary = SKIN_PALETTES[int(get_multiplayer_authority()) % SKIN_PALETTES.size()]
	var body_color: Color = palette.get("body", Color(1, 1, 1))
	var accent_color: Color = palette.get("accent", body_color)
	var body := get_node_or_null("Body") as Node3D
	if body != null:
		_apply_skin_recursive(body, body_color, accent_color)
	var arms := get_node_or_null("Head/Camera/ViewMesh/Arms") as Node3D
	if arms != null:
		_apply_skin_recursive(arms, body_color, accent_color)


func _apply_skin_recursive(node: Node, body_color: Color, accent_color: Color) -> void:
	if node is MeshInstance3D:
		var mi := node as MeshInstance3D
		var mesh := mi.mesh
		if mesh != null:
			for i in mesh.get_surface_count():
				var mat := mi.get_surface_override_material(i)
				if mat == null:
					mat = mesh.surface_get_material(i)
				if mat == null:
					continue
				var dup := mat.duplicate() as Material
				if dup is StandardMaterial3D:
					(dup as StandardMaterial3D).albedo_color = accent_color if i >= 1 else body_color
				mi.set_surface_override_material(i, dup)
	for child in node.get_children():
		_apply_skin_recursive(child, body_color, accent_color)


## M2-S5 缺陷修复：4.7 要求同步器 authority 在 _enter_tree 设置（早于 _ready 的 _setup_sync）。
## 若 authority 在 add_child 前/实例化时设置，客户端本地玩家副本的 PlayerSync 会报
## "unable to process the pending spawn since it has no network ID" 而创建失败。
## 服务器 spawn 时节点名 = str(peer_id)，两端一致（Godot 官方推荐 name.to_int() 模式）
func _enter_tree() -> void:
	if name.is_valid_int():
		set_multiplayer_authority(name.to_int())
	_setup_sync()


## 捕获鼠标（A5）：延迟一帧执行，等待窗口聚焦
func _capture_mouse() -> void:
	_mouse_capture_requested = true
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
	# ENet peer id 是随机大整数，不能用奇偶数取模分配出生点，否则会与主机高概率重叠。
	# 所有端对同一组 peer id 排序，得到一致且不重复的槽位。
	var peer_ids: Array[int] = [NetworkManager.SERVER_ID]
	if NetworkManager.is_network_active():
		var local_peer_id := multiplayer.get_unique_id()
		if not peer_ids.has(local_peer_id):
			peer_ids.append(local_peer_id)
	for peer_id in multiplayer.get_peers():
		if not peer_ids.has(peer_id):
			peer_ids.append(peer_id)
	peer_ids.sort()
	var index := peer_ids.find(get_multiplayer_authority())
	if index < 0:
		index = 0
	index %= points.size()
	var spawn := points[index] as Node3D
	global_position = spawn.global_position
	# 出生点朝向属于关卡设计的一部分；忽略它会让玩家面朝墙，按 W 看起来像无法移动。
	global_rotation.y = spawn.global_rotation.y


func _input(event: InputEvent) -> void:
	if not is_multiplayer_authority():
		return
	# Esc 释放鼠标（A5）
	if event.is_action_pressed("ui_cancel"):
		SfxPool.play_2d("ui_cancel")
		_mouse_capture_requested = false
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		return
	# 点击窗口重新捕获（A5）：仅鼠标可见（Esc 释放后）时点击才重新捕获；
	# 已捕获（CAPTURED）状态下左键直接走开火分支，不再被此分支吞掉（M1-INPUT）
	if event is InputEventMouseButton and event.pressed and Input.mouse_mode == Input.MOUSE_MODE_VISIBLE:
		_mouse_capture_requested = true
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
		return
	# 鼠标视角：yaw 作用于身体（rotation.y），pitch 作用于 Head（rotation.x）
	if event is InputEventMouseMotion and _mouse_capture_requested:
		if Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
			Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
		var ps := get_node_or_null("Health") as PlayerState
		if ps != null and ps.state == PlayerState.State.DEAD:
			return  # 死亡：冻结视角（DOWN 保留视角）
		rotation.y = rotation.y - event.relative.x * mouse_sensitivity
		pitch = clampf(
			pitch - event.relative.y * mouse_sensitivity,
			deg_to_rad(-89.0),
			deg_to_rad(89.0)
		)
		# viewmodel 鼠标随动目标：枪口朝鼠标移动方向轻微摆（§5.1，随帧回中）
		_sway_target.x = clampf(_sway_target.x - event.relative.y * 0.004, -1.0, 1.0)
		_sway_target.y = clampf(_sway_target.y - event.relative.x * 0.004, -1.0, 1.0)
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
	if event is InputEventKey and event.pressed and not event.echo and event.keycode in [KEY_G, KEY_H]:
		var throwable_type := "grenade" if event.keycode == KEY_G else "molotov"
		if NetworkManager.is_server():
			request_throw(throwable_type)
		else:
			request_throw.rpc_id(NetworkManager.SERVER_ID, throwable_type)
		return
	if event.is_action_pressed("slide") and not event.is_echo():
		_try_start_slide()
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


## 交互键 E 按下：S4 补给点优先（交互区更近、瞬时结算）→ S6 掉落物拾取 → 再走救援
func _on_interact_pressed() -> void:
	var stand := _find_nearby_weapon_stand()
	if stand != null:
		if NetworkManager.is_server():
			stand.request_pickup()
		else:
			stand.request_pickup.rpc_id(NetworkManager.SERVER_ID)
		return
	var throwable_supply := _find_nearby_throwable_supply()
	if throwable_supply != null:
		if NetworkManager.is_server():
			throwable_supply.request_pickup()
		else:
			throwable_supply.request_pickup.rpc_id(NetworkManager.SERVER_ID)
		return
	# 补给点优先级高于掉落物/救援：拾取是瞬时动作，且补给点常在脚边，先结算不打断救援流
	var supply := _find_nearby_supply()
	if supply != null:
		if NetworkManager.is_server():
			supply.request_pickup()  # 单机/主机：服务器进程直接结算（无 peer 时 rpc 行为不可靠）
		else:
			supply.request_pickup.rpc_id(NetworkManager.SERVER_ID)
		return
	# S6 掉落物拾取：复用 E 键（与 S4 补给点一致交互）；客户端选目标，服务器复验距离/已用
	var pickup := _find_nearby_pickup()
	if pickup != null:
		if NetworkManager.is_server():
			pickup.request_pickup()
		else:
			pickup.request_pickup.rpc_id(NetworkManager.SERVER_ID)
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


func _find_nearby_weapon_stand() -> WeaponStand:
	var best: WeaponStand = null
	var best_dist := WeaponStand.PICKUP_RANGE
	for stand in get_tree().get_nodes_in_group("weapon_stands"):
		var dist := global_position.distance_to(stand.global_position)
		if dist <= best_dist:
			best_dist = dist
			best = stand as WeaponStand
	return best


func _find_nearby_throwable_supply() -> ThrowableSupply:
	var best: ThrowableSupply = null
	var best_dist := ThrowableSupply.PICKUP_RANGE
	for supply in get_tree().get_nodes_in_group("throwable_supplies"):
		var typed := supply as ThrowableSupply
		var dist := global_position.distance_to(typed.global_position)
		if dist <= best_dist:
			best_dist = dist
			best = typed
	return best


## 找拾取范围内最近的掉落物（S6；与补给点同判定半径/交互，客户端选目标，服务器复验）
func _find_nearby_pickup() -> PickupItem:
	var best: PickupItem = null
	var best_dist := PickupItem.PICKUP_RANGE
	for p in get_tree().get_nodes_in_group("pickup_items"):
		var dist := global_position.distance_to(p.global_position)
		if dist <= best_dist:
			best_dist = dist
			best = p as PickupItem
	return best


## 配置第一人称与第三人称武器表现。可见性只在各 peer 本地决定，不进入同步状态。
func _configure_weapon_visuals() -> void:
	var owned_locally := is_multiplayer_authority()
	var body := get_node_or_null("Body") as Node3D
	if body != null:
		body.visible = not owned_locally
	var view_root := get_node_or_null("Head/Camera/ViewMesh") as Node3D
	if view_root != null:
		view_root.visible = owned_locally
		_configure_geometry(view_root, VIEW_RENDER_LAYER, GeometryInstance3D.SHADOW_CASTING_SETTING_OFF)
	var pivot := get_node_or_null("WeaponPivot")
	if pivot == null:
		return
	for child in pivot.get_children():
		var weapon := child as WeaponBase
		if weapon == null:
			continue
		var world_mesh := weapon.get_node_or_null("WorldMesh") as Node3D
		if world_mesh == null:
			continue
		world_mesh.visible = not owned_locally
		_configure_geometry(world_mesh, WORLD_RENDER_LAYER, GeometryInstance3D.SHADOW_CASTING_SETTING_ON)


func _configure_geometry(root: Node, render_layer: int, shadow_setting: int) -> void:
	for child in root.get_children():
		if child is GeometryInstance3D:
			var geometry := child as GeometryInstance3D
			geometry.layers = render_layer
			geometry.cast_shadow = shadow_setting as GeometryInstance3D.ShadowCastingSetting
		_configure_geometry(child, render_layer, shadow_setting)


## 收集 WeaponPivot 下的逻辑武器，并按同名节点关联 Camera/ViewMesh，默认激活第 0 把。
func _collect_weapons() -> void:
	_weapons.clear()
	_view_meshes.clear()
	var pivot := get_node_or_null("WeaponPivot")
	if pivot == null:
		return
	var view_root := get_node_or_null("Head/Camera/ViewMesh")
	_view_root = view_root
	if view_root != null:
		_view_root_base_pos = view_root.position
		_view_root_base_rot = view_root.rotation
	for child in pivot.get_children():
		var w := child as WeaponBase
		if w != null:
			_weapons.append(w)
			var view_mesh := view_root.get_node_or_null(String(w.name)) as Node3D if view_root != null else null
			_view_meshes.append(view_mesh)
			if not w.view_fired.is_connected(_on_weapon_view_fired):
				w.view_fired.connect(_on_weapon_view_fired)
	_set_active_weapon(0)


## 开火视觉回调（本地玩家武器）：后坐上抬（§5.1：2-4°、0.1s 回弹）
func _on_weapon_view_fired() -> void:
	_recoil = minf(_recoil + 2.5, 6.0)


## 切换激活武器：可见性即激活标记（弹药各自独立，由每个武器节点自身维护）。
## 切枪为本地状态（M1-S4 记录，不同步他人）→ 切枪音只本端播（3D 挂玩家近距衰减，audio_events.json weapon_switch）
func _set_active_weapon(index: int) -> void:
	if index < 0 or index >= _weapons.size():
		return
	if index > 0 and _weapons[index].weapon_id != primary_weapon_id:
		return
	if index != _current_weapon_index and _weapons.size() > 1:
		SfxPool.play_3d("weapon_switch", global_position)
	_current_weapon_index = index
	for i in _weapons.size():
		_weapons[i].visible = (i == index)
		if i < _view_meshes.size() and _view_meshes[i] != null:
			_view_meshes[i].visible = (i == index)


## 服务器权威装备主武器；地图武器架调用。
func equip_primary(weapon_id: String) -> bool:
	if not NetworkManager.is_server() or weapon_id not in ["shotgun", "rifle", "smg"]:
		return false
	if NetworkManager.is_network_active():
		sync_primary_weapon.rpc(weapon_id)
	else:
		sync_primary_weapon(weapon_id)
	return true


func has_claimed_weapon_stand(weapon_id: String) -> bool:
	return claimed_weapon_stands.has(weapon_id)


func mark_weapon_stand_claimed(weapon_id: String) -> void:
	if NetworkManager.is_server() and NetworkManager.is_network_active():
		sync_claimed_weapon_stand.rpc(weapon_id)
	else:
		sync_claimed_weapon_stand(weapon_id)


@rpc("any_peer", "call_local", "reliable")
func sync_claimed_weapon_stand(weapon_id: String) -> void:
	var sender := multiplayer.get_remote_sender_id()
	if sender != 0 and sender != NetworkManager.SERVER_ID:
		return
	if weapon_id in ["shotgun", "rifle", "smg"] and not claimed_weapon_stands.has(weapon_id):
		claimed_weapon_stands.append(weapon_id)


func grant_throwable(throwable_type: String) -> bool:
	if not NetworkManager.is_server() or throwable_type not in ["grenade", "molotov"]:
		return false
	var count := grenade_count if throwable_type == "grenade" else molotov_count
	if count >= 1:
		return false
	if NetworkManager.is_network_active():
		sync_throwable_inventory.rpc(throwable_type, 1)
	else:
		sync_throwable_inventory(throwable_type, 1)
	return true


@rpc("any_peer", "call_local", "reliable")
func sync_throwable_inventory(throwable_type: String, count: int) -> void:
	var sender := multiplayer.get_remote_sender_id()
	if sender != 0 and sender != NetworkManager.SERVER_ID:
		return
	if throwable_type == "grenade":
		grenade_count = clampi(count, 0, 1)
	elif throwable_type == "molotov":
		molotov_count = clampi(count, 0, 1)


@rpc("any_peer", "call_local", "reliable")
func request_throw(throwable_type: String) -> void:
	if not NetworkManager.is_server() or throwable_type not in ["grenade", "molotov"]:
		return
	var sender := multiplayer.get_remote_sender_id()
	if sender != 0 and sender != get_multiplayer_authority():
		return
	var count := grenade_count if throwable_type == "grenade" else molotov_count
	if count <= 0:
		return
	var ps := get_node_or_null("Health") as PlayerState
	if ps != null and ps.state != PlayerState.State.ALIVE:
		return
	var path := "res://scenes/gameplay/%s.tscn" % throwable_type
	var scene := load(path) as PackedScene
	var projectile := scene.instantiate() as ThrowableProjectile
	projectile.owner_peer_id = get_multiplayer_authority()
	projectile.initial_velocity = -_camera.global_basis.z * 14.0 + Vector3.UP * 2.0
	get_tree().current_scene.get_node("Projectiles").add_child(projectile, true)
	projectile.global_position = _camera.global_position + -_camera.global_basis.z * 0.6
	if NetworkManager.is_network_active():
		sync_throwable_inventory.rpc(throwable_type, count - 1)
	else:
		sync_throwable_inventory(throwable_type, count - 1)


@rpc("any_peer", "call_local", "reliable")
func sync_primary_weapon(weapon_id: String) -> void:
	var sender := multiplayer.get_remote_sender_id()
	if sender != 0 and sender != NetworkManager.SERVER_ID:
		return
	primary_weapon_id = weapon_id
	for i in _weapons.size():
		if _weapons[i].weapon_id == weapon_id:
			_set_active_weapon(i)
			return


## 从检查点恢复当前武器和各武器弹匣；仅服务器在玩家 ready 后调用。
func restore_equipment(equipment: Dictionary) -> bool:
	var magazines = equipment.get("magazines")
	if not (magazines is Dictionary) or _weapons.is_empty():
		return false
	var active_weapon := String(equipment.get("active_weapon", ""))
	primary_weapon_id = String(equipment.get("primary_weapon", ""))
	claimed_weapon_stands.clear()
	for claimed in equipment.get("claimed_weapon_stands", []):
		if String(claimed) in ["shotgun", "rifle", "smg"]:
			claimed_weapon_stands.append(String(claimed))
	grenade_count = clampi(int(equipment.get("grenade_count", 0)), 0, 1)
	molotov_count = clampi(int(equipment.get("molotov_count", 0)), 0, 1)
	if primary_weapon_id.is_empty() and active_weapon != "pistol":
		primary_weapon_id = active_weapon
	var active_index := -1
	for index in _weapons.size():
		var weapon := _weapons[index]
		if magazines.has(weapon.weapon_id):
			weapon.mag_current = clampi(int(magazines[weapon.weapon_id]), 0, weapon.mag_size)
		if weapon.weapon_id == active_weapon:
			active_index = index
	if active_index >= 0:
		_set_active_weapon(active_index)
	return true


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


## 脚步/落地音频（每物理帧，仅本地玩家 authority 分支调用）：
## 步频计时触发脚步（速度阈值分走/跑事件）；落地检测（下落速度超阈值播 player_land）
func _tick_movement_sfx(delta: float) -> void:
	var on_floor := is_on_floor()
	if on_floor and not _was_on_floor:
		# 落地：从空中回落地面的那一帧
		if _fall_speed >= LAND_FALL_SPEED:
			SfxPool.play_3d("player_land", global_position)
		_fall_speed = 0.0
	elif not on_floor:
		# 空中：累积下落速度（velocity.y 为负）
		_fall_speed = maxf(_fall_speed, -velocity.y)
	var h_speed := Vector2(velocity.x, velocity.z).length()
	if on_floor and h_speed > 0.5:
		_step_timer = _step_timer - delta
		if _step_timer <= 0.0:
			var running := h_speed > RUN_SPEED_THRESHOLD
			SfxPool.play_3d(_footstep_event(), global_position)
			var interval := STEP_INTERVAL_RUN if running else STEP_INTERVAL_WALK
			# 步频 ±15% 抖动，避免多步节奏像节拍器
			_step_timer = interval * randf_range(0.85, 1.15)
	else:
		_step_timer = 0.0
	_was_on_floor = on_floor


## 脚步事件：按脚下材质路由（材质检测失败/未知一律水泥）
func _footstep_event() -> String:
	match _detect_ground_material():
		"metal":
			return "footstep_metal"
		"dirt":
			return "footstep_dirt"
		_:
			return "footstep_concrete"


## 脚下材质检测：向下射线（mask=1 世界层，exclude 自身碰撞体），
## 命中 StaticBody3D 节点名关键字匹配材质（rustyard：Ground/Wall→水泥、Door→金属）
func _detect_ground_material() -> String:
	var space := get_world_3d().direct_space_state
	var from := global_position + Vector3(0.0, -0.4, 0.0)
	var query := PhysicsRayQueryParameters3D.create(from, from + Vector3(0.0, -3.0, 0.0), 1, [get_rid()])
	var hit := space.intersect_ray(query)
	if hit.is_empty():
		return "concrete"
	var collider := hit.get("collider") as Node
	if collider == null:
		return "concrete"
	var n := String(collider.name).to_lower()
	for kw in _STEP_MATERIAL_METAL:
		if n.contains(kw):
			return "metal"
	for kw in _STEP_MATERIAL_DIRT:
		if n.contains(kw):
			return "dirt"
	return "concrete"


## 每帧更新第一人称 viewmodel 动画（仅本地玩家）：在基准 transform 上叠加 sway/bob/recoil/reload 偏移
func _process(delta: float) -> void:
	if not is_multiplayer_authority():
		return
	_update_viewmodel(delta)


func _update_viewmodel(delta: float) -> void:
	if _view_root == null:
		return
	# 后坐：上抬角度快速衰减回弹（§5.1：2-4°、0.1s 回弹）
	_recoil = maxf(_recoil - delta * 30.0, 0.0)
	# 鼠标随动：目标随帧回中，实际值平滑跟随
	_sway_target = _sway_target.lerp(Vector2.ZERO, minf(delta * 8.0, 1.0))
	_sway = _sway.lerp(_sway_target, minf(delta * 12.0, 1.0))
	# 步伐 bob：着地移动时上下/左右轻微晃动（§5.1：1-3cm）
	var h_speed := Vector2(velocity.x, velocity.z).length()
	if is_on_floor() and h_speed > 0.5:
		_bob_time += delta * (h_speed * 1.6)
	else:
		_bob_time = 0.0
	var bob_y := sin(_bob_time * 2.0) * 0.012
	var bob_x := sin(_bob_time) * 0.008
	var bob_roll := sin(_bob_time) * 0.01
	# 换弹下压：reloading 期间枪口下压/略回收，结束回位
	var weapon := _get_weapon()
	var reloading := weapon != null and weapon.reloading
	_reload_level = move_toward(_reload_level, 1.0 if reloading else 0.0, delta * 5.0)
	# 合成偏移（ViewMesh rotation 默认 0，绕其 X 轴正=抬头、Y 轴正=左转）
	var rot_off := Vector3.ZERO
	var pos_off := Vector3.ZERO
	rot_off.x += deg_to_rad(_recoil)      # 后坐上抬
	rot_off.x += _sway.x * 0.02           # 鼠标随动俯仰
	rot_off.y += _sway.y * 0.02           # 鼠标随动水平
	rot_off.z += bob_roll
	rot_off.x -= _reload_level * 0.3      # 换弹下压（负=低头）
	pos_off.x += bob_x
	pos_off.y += bob_y
	pos_off.y -= _reload_level * 0.05     # 换弹下移
	pos_off.z += _reload_level * 0.02     # 换弹略回收
	_view_root.rotation = _view_root_base_rot + rot_off
	_view_root.position = _view_root_base_pos + pos_off


func _physics_process(delta: float) -> void:
	# 远端玩家不做输入，只由同步器更新 transform
	if not is_multiplayer_authority():
		return
	var ps := get_node_or_null("Health") as PlayerState
	if ps != null and ps.state != PlayerState.State.ALIVE:
		# DOWN/DEAD：移动禁用（DOWN 视角保留，DEAD 视角在 _unhandled_input 冻结）
		velocity = Vector3.ZERO
		_cancel_parkour()
		return
	_slide_cooldown = maxf(_slide_cooldown - delta, 0.0)
	_jump_buffer_timer = maxf(_jump_buffer_timer - delta, 0.0)
	if Input.is_action_just_pressed("jump"):
		_jump_buffer_timer = JUMP_BUFFER_TIME
	if _vaulting:
		_tick_vault(delta)
		return
	var input_dir := Input.get_vector("move_left", "move_right", "move_forward", "move_back")
	var direction := (transform.basis * Vector3(input_dir.x, 0, input_dir.y)).normalized()
	if is_on_floor():
		_coyote_timer = COYOTE_TIME
	else:
		_coyote_timer = maxf(_coyote_timer - delta, 0.0)
	if _slide_timer > 0.0:
		_slide_timer = maxf(_slide_timer - delta, 0.0)
		var slide_speed := lerpf(WALK_SPEED, SLIDE_START_SPEED, _slide_timer / SLIDE_DURATION)
		velocity.x = _slide_direction.x * slide_speed
		velocity.z = _slide_direction.z * slide_speed
	else:
		var sprinting := Input.is_action_pressed("sprint") and direction != Vector3.ZERO and is_on_floor()
		var target_speed := SPRINT_SPEED if sprinting else WALK_SPEED
		var target := direction * target_speed
		var acceleration := AIR_ACCEL if not is_on_floor() else (GROUND_ACCEL if direction != Vector3.ZERO else GROUND_DECEL)
		velocity.x = move_toward(velocity.x, target.x, acceleration * delta)
		velocity.z = move_toward(velocity.z, target.z, acceleration * delta)
		_camera.fov = move_toward(_camera.fov, 80.0 if sprinting else 75.0, delta * 18.0)
	_head.position.y = move_toward(_head.position.y, 1.05 if _slide_timer > 0.0 else 1.6, delta * 4.5)
	if not is_on_floor():
		# 注意：get_gravity().y 为负（默认 -9.8），必须 **加** 它才会向下加速；
		# 之前写成减号导致反重力（跳跃后会越飘越高，M1-ZOMBIE 与丧尸同源，f5ac73c 引入）
		velocity.y = velocity.y + get_gravity().y * delta
	if _jump_buffer_timer > 0.0 and _coyote_timer > 0.0:
		if is_on_floor() and _try_start_vault():
			_jump_buffer_timer = 0.0
			return
		velocity.y = JUMP_VELOCITY
		_jump_buffer_timer = 0.0
		_coyote_timer = 0.0
		SfxPool.play_3d("player_jump", global_position)
	move_and_slide()
	# 自动武器连发轮询：按住左键对 auto 武器持续开火（半自动按一次打一发，不连发）
	_poll_auto_fire()
	# 脚步/落地音频（仅本地玩家；素材缺失静默，就位即生效）
	_tick_movement_sfx(delta)


func _try_start_slide() -> void:
	if not is_on_floor() or _slide_timer > 0.0 or _slide_cooldown > 0.0:
		return
	var horizontal := Vector3(velocity.x, 0.0, velocity.z)
	if horizontal.length() < SPRINT_SPEED - 0.25:
		return
	_slide_direction = horizontal.normalized()
	_slide_timer = SLIDE_DURATION
	_slide_cooldown = SLIDE_DURATION + SLIDE_COOLDOWN


func _try_start_vault() -> bool:
	if not is_on_floor() or _slide_timer > 0.0:
		return false
	var forward := -global_basis.z.normalized()
	var space := get_world_3d().direct_space_state
	var exclude := [get_rid()]
	var low_from := global_position + Vector3.UP * 0.65
	var low_hit := space.intersect_ray(PhysicsRayQueryParameters3D.create(low_from, low_from + forward * 1.0, 1, exclude))
	if low_hit.is_empty():
		return false
	var high_from := global_position + Vector3.UP * 1.25
	if not space.intersect_ray(PhysicsRayQueryParameters3D.create(high_from, high_from + forward * 1.0, 1, exclude)).is_empty():
		return false
	var landing_probe := global_position + forward * 1.35 + Vector3.UP * 1.6
	var floor_hit := space.intersect_ray(PhysicsRayQueryParameters3D.create(landing_probe, landing_probe - Vector3.UP * 2.2, 1, exclude))
	if floor_hit.is_empty() or (floor_hit.normal as Vector3).y < 0.7:
		return false
	var landing := (floor_hit.position as Vector3) + Vector3.UP * 0.05
	var ceiling_hit := space.intersect_ray(PhysicsRayQueryParameters3D.create(landing + Vector3.UP * 0.1, landing + Vector3.UP * 1.85, 1, exclude))
	if not ceiling_hit.is_empty():
		return false
	_vaulting = true
	_vault_elapsed = 0.0
	_vault_from = global_position
	_vault_to = landing
	velocity = Vector3.ZERO
	return true


func _tick_vault(delta: float) -> void:
	_vault_elapsed += delta
	var t := clampf(_vault_elapsed / VAULT_DURATION, 0.0, 1.0)
	var position := _vault_from.lerp(_vault_to, t)
	position.y += sin(t * PI) * 0.35
	global_position = position
	if t >= 1.0:
		_vaulting = false
		velocity = Vector3.ZERO


func _cancel_parkour() -> void:
	_slide_timer = 0.0
	_vaulting = false
	_head.position.y = 1.6
	_camera.fov = 75.0
