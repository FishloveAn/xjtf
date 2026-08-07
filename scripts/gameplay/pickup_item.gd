## pickup_item.gd — 丧尸死亡掉落物（M3-S6；复用 S4 补给点拾取管线）
## 职责：掉落物（弹药/小医疗包）基元占位，发光区分（蓝=弹药、红=医疗）；靠近按 E →
##       request_pickup（any_peer）→ 服务器校验（来源/距离/已用）→ 结算（补弹药/回血）→
##       used 置位 + 服务器 queue_free（MultiplayerSpawner 同步各端消失，双人抢同一掉落只结算一次）
## 输入：player_controller E 键（_find_nearby_pickup 找到本点 → request_pickup）；
##       LootManager 死亡掉落生成时 set pickup_type / heal_amount / ammo_amount / lifetime
## 输出：request_pickup RPC（any_peer）；结算经 WeaponSync（弹匣）/ HealthSync（hp）自动广播；
##       服务器权威生命周期到期（pickup_lifetime_s）→ queue_free 防地面堆积
## 谁调用：仅服务器结算（tech-plan §4.4 服务器权威，客户端只发请求、收 Spawner 复制）；
##       与 SupplyPoint 同模式：used 标记防连点/多人抢重复结算
## 规范：复用 E 键交互（与 S4 补给点一致，任务卡 §2-S6）；单文件 ≤300 行

class_name PickupItem
extends Node3D

enum Type { AMMO, HEALTH }

const PICKUP_RANGE := 2.5    # 米，交互距离（与 SupplyPoint.PICKUP_RANGE 一致，可及感一致）
const DEFAULT_AMMO := 30     # 默认补充弹药数（loot.json items.ammo.amount 数据驱动）
const DEFAULT_HEAL := 50.0   # 默认回血量（loot.json items.medkit.heal 数据驱动）
const ROTATE_SPEED := 1.5    # 弧度/秒，缓慢旋转（基元占位视觉区分，纯本地展示）

## 掉落物类型：AMMO（蓝色弹药盒）/ HEALTH（红色医疗包）
@export var pickup_type: Type = Type.AMMO
## 补充弹药数（<=0 = 补满当前武器弹匣）；回血量（HEALTH 时生效，PlayerState setter 钳制到 max_hp）
@export var heal_amount := DEFAULT_HEAL
@export var ammo_amount := DEFAULT_AMMO

## 已被拾取（服务器权威：防连点/多人同时抢同一掉落重复结算，同 S4 F4）
var used := false

## 存活时长（秒，服务器权威到期 queue_free；LootManager 按 loot.json pickup_lifetime_s 注入）
var lifetime_s := 30.0
var _life_timer := 0.0

@onready var _mesh_ammo: MeshInstance3D = $MeshAmmo
@onready var _mesh_health: MeshInstance3D = $MeshHealth


func _ready() -> void:
	# 服务器权威（authority 拾取结算 + 生命周期销毁）；group 供 player_controller/HUD 按组找
	set_multiplayer_authority(NetworkManager.SERVER_ID)
	add_to_group("pickup_items")
	_mesh_ammo.visible = pickup_type == Type.AMMO
	_mesh_health.visible = pickup_type == Type.HEALTH
	_life_timer = lifetime_s


func _process(delta: float) -> void:
	# 生命周期仅服务器推进：到期服务器 queue_free → Spawner 广播各端同步消失（防地面堆积）
	if NetworkManager.is_server():
		_life_timer = _life_timer - delta
		if _life_timer <= 0.0:
			queue_free()
	# 缓慢旋转纯视觉（所有端本地播放，不依赖服务器）
	rotation.y = rotation.y + ROTATE_SPEED * delta


# --- 拾取请求（any_peer：客户端→服务器，tech-plan §4.4；与 SupplyPoint 同模式） ---

## [any_peer] 客户端→服务器：拾取请求。服务器校验来源/距离/已用后结算并销毁
@rpc("any_peer", "call_local", "reliable")
func request_pickup() -> void:
	if not NetworkManager.is_server():
		return
	if used:
		return  # 已用：连点/多人抢不重复结算（双人抢同一掉落只结算一次，任务卡 §2-S6 自测 4）
	var sender: int = multiplayer.get_remote_sender_id()
	if sender == 0:
		# 服务器进程本地直接调用（单机/主机玩家按 E，无 RPC 上下文时 remote_sender=0）：
		# 以本机 peer 兜底（M2-S4 引擎记录：服务器 unique_id=1 恰为服务器玩家 authority）
		sender = multiplayer.get_unique_id()
	var player := _find_player_by_peer(sender)
	if player == null:
		return
	if global_position.distance_to(player.global_position) > PICKUP_RANGE:
		return  # 距离校验（服务器复验，防远程作弊）
	used = true
	_grant(player)
	_broadcast_pickup_sound()  # 拾取音（3D 世界声，全端可听；按类型播 pickup_ammo/pickup_health）
	queue_free()  # 服务器销毁 → MultiplayerSpawner 同步各端消失（单机即本地消失）


## 服务器：按类型发放（弹药补当前武器弹匣 / 医疗回血，上限校验在 PlayerState setter）
func _grant(player: Node3D) -> void:
	match pickup_type:
		Type.AMMO:
			var weapon := _get_active_weapon(player)
			if weapon != null:
				if ammo_amount > 0:
					# 数据驱动补弹：向当前弹匣补充 amount 发（上限 mag_size，不超不浪费）
					weapon.mag_current = mini(weapon.mag_size, weapon.mag_current + ammo_amount)
				else:
					weapon.mag_current = weapon.mag_size  # amount<=0：补满
		Type.HEALTH:
			var state := player.get_node_or_null("Health") as PlayerState
			if state != null:
				state.apply_healing(heal_amount)  # 回血/救起倒地（HealthSync 自动广播）


# --- 工具 ---

## [authority] 服务器→所有人：拾取音（掉落物消失走 Spawner 无 authority 广播，故单独 RPC）
@rpc("authority", "call_local", "reliable")
func pickup_sound() -> void:
	var event := "pickup_health" if pickup_type == Type.HEALTH else "pickup_ammo"
	SfxPool.play_3d(event, global_position)


## 广播拾取音：单机（无 peer）直接本地执行；多人走 authority RPC（call_local 覆盖主机视角）
func _broadcast_pickup_sound() -> void:
	if NetworkManager.is_network_active():
		pickup_sound.rpc()
	else:
		pickup_sound()


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
