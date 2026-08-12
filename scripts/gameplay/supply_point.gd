## supply_point.gd — 物资补给点（M2-S4：弹药 + 医疗，服务器权威拾取）
## 职责：场景中固定/波间刷出的补给点。靠近按 E → request_pickup（any_peer）→ 服务器校验
##       （来源/距离/已用）→ 结算（弹药补满当前武器弹匣 / 医疗 +50HP 且可救起倒地玩家）→
##       pickup_used 广播 → 所有端消失（MVP：消失，Intermission 按 waves.json reward 重刷）
## 输入：player_controller E 键（_find_nearby_supply 找到本点 → request_pickup）；
##       WaveManager Intermission 调静态 refresh_from_reward 刷新（reward 数据驱动）
## 输出：request_pickup RPC（any_peer）；pickup_used RPC（authority）；
##       结算经 WeaponSync（弹匣）/ HealthSync（hp/state）自动广播
## 谁调用：仅服务器结算（tech-plan §4.4）；客户端只发请求、收广播；静态刷新仅服务器调用
## 规范：F3 服务器权威（客户端不本地改资源）；F4 used 标记防连点/多人抢重复结算；
##       与 E 键救援共存：player_controller 补给点优先级高于救援（交互区更近，瞬时结算）

class_name SupplyPoint
extends Node3D

enum Type { AMMO, HEALTH }

const PICKUP_RANGE := 2.5    # 米，交互距离（与救援 REVIVE_RANGE 一致，玩家可及感一致）
const HEALTH_AMOUNT := 50.0  # 医疗补给回血量（PlayerState setter 钳制到 max_hp）
const SCENE_PATH := "res://scenes/environment/supply_point.tscn"

## 补给点类型：AMMO（蓝色弹药箱）/ HEALTH（红色医疗箱）
@export var supply_type: Type = Type.AMMO

## 已被拾取（服务器权威：防连点/多人同时抢同一补给点重复结算，F4）
var used := false

@onready var _mesh_ammo: Node3D = $MeshAmmo
@onready var _mesh_health: Node3D = $MeshHealth


func _ready() -> void:
	# 服务器权威（F3）：authority RPC（pickup_used）可发；结算逻辑只走服务器
	set_multiplayer_authority(NetworkManager.SERVER_ID)
	add_to_group("supply_points")  # player_controller/HUD 按组找（tech-plan §8.4）
	_mesh_ammo.visible = supply_type == Type.AMMO
	_mesh_health.visible = supply_type == Type.HEALTH


# --- 拾取请求（any_peer：客户端→服务器，tech-plan §4.4） ---

## [any_peer] 客户端→服务器：拾取请求。服务器校验来源/距离/已用后结算并广播
@rpc("any_peer", "call_local", "reliable")
func request_pickup() -> void:
	if not NetworkManager.is_server():
		return
	if used:
		return  # 已用：连点/多人抢不重复结算（F4）
	var sender: int = multiplayer.get_remote_sender_id()
	if sender == 0:
		# 服务器进程本地直接调用（单机/主机玩家按 E，无 RPC 上下文时 remote_sender=0）：
		# 以本机 peer 兜底（服务器 unique_id=1，恰为服务器玩家 authority）
		sender = multiplayer.get_unique_id()
	var player := _find_player_by_peer(sender)
	if player == null:
		return  # 防御：请求来源必须是 players 组中某玩家
	if global_position.distance_to(player.global_position) > PICKUP_RANGE:
		return  # 距离校验（服务器复验，防远程作弊）
	used = true
	_grant(player)
	_broadcast_pickup_used()


## 服务器：按类型发放（弹药补满当前武器弹匣 / 医疗回血并可救起倒地玩家）
func _grant(player: Node3D) -> void:
	match supply_type:
		Type.AMMO:
			var weapon := _get_active_weapon(player)
			if weapon != null:
				weapon.mag_current = weapon.mag_size  # 补满弹匣（WeaponSync 自动广播，客户端不本地改）
		Type.HEALTH:
			var state := player.get_node_or_null("Health") as PlayerState
			if state != null:
				state.apply_healing(HEALTH_AMOUNT)  # 回血/救起（HealthSync 自动广播）


## [authority] 服务器→所有人：补给点已用，所有端本地消失 + 拾取音（MVP：消失，Intermission 重刷）
@rpc("authority", "call_local", "reliable")
func pickup_used() -> void:
	var event := "pickup_health" if supply_type == Type.HEALTH else "pickup_ammo"
	SfxPool.play_3d(event, global_position)  # 拾取音（全端执行时各端本地播）
	queue_free()


## 广播拾取结果：单机（无 peer）直接本地执行；多人走 authority RPC（call_local 覆盖主机视角）
func _broadcast_pickup_used() -> void:
	if NetworkManager.is_network_active():
		pickup_used.rpc()
	else:
		pickup_used()


# --- 工具 ---

func _find_player_by_peer(peer_id: int) -> Node3D:
	for p in get_tree().get_nodes_in_group("players"):
		if p.get_multiplayer_authority() == peer_id:
			return p as Node3D
	return null


## 当前激活武器（WeaponPivot 下 visible 的那把；激活标记由 player_controller 切枪维护）
func _get_active_weapon(player: Node3D) -> WeaponBase:
	var pivot := player.get_node_or_null("WeaponPivot")
	if pivot == null:
		return null
	for child in pivot.get_children():
		var w := child as WeaponBase
		if w != null and w.visible:
			return w
	return null


# --- 波间刷新（WaveManager Intermission 调用；仅服务器） ---

## 服务器：清空 Pickups 容器内旧补给点，按 reward 数据驱动在固定点生成新补给点
static func refresh_from_reward(container: Node, spots: Array, reward: Dictionary) -> void:
	if container == null:
		return
	for c in container.get_children():
		if c.is_in_group("supply_points"):
			c.queue_free()
	var health_packs := int(reward.get("health_packs", 0))
	var ammo_count := int(reward.get("ammo", 0))
	var idx := 0
	for i in health_packs:
		_spawn(container, spots, idx, Type.HEALTH)
		idx += 1
	for i in ammo_count:
		_spawn(container, spots, idx, Type.AMMO)
		idx += 1


static func _spawn(container: Node, spots: Array, idx: int, stype: Type) -> void:
	var scene := load(SCENE_PATH) as PackedScene
	if scene == null:
		push_error("[SupplyPoint] 无法装载 supply_point.tscn，补给点跳过")
		return
	var s := scene.instantiate() as Node3D
	s.set("supply_type", stype)
	s.set_multiplayer_authority(NetworkManager.SERVER_ID)  # 先设权威再入树（生成包携带 authority）
	container.add_child(s, true)  # 强制可读名：instantiate() 节点是 @ 保留名，MultiplayerSpawner auto-spawn 会失败（M3-S1 回归）
	if not spots.is_empty():
		s.global_position = (spots[idx % spots.size()] as Node3D).global_position
