## weapon_base.gd — 武器基类（hitscan + 数据驱动；S4 支持 pellets 多弹丸）
## 职责：从 data/weapons.json 装载武器参数；客户端开火/换弹入口（try_fire/try_reload）；
##       服务器权威：弹药/射速冷却/换弹/物理复判命中（Hitscan）→ 目标 damageable.take_damage；
##       mag_current/reloading 经 WeaponSync（服务器权威）同步
## 输入：player_controller（左键/R 键）调用 try_fire()/try_reload()；request_fire/request_reload RPC
## 输出：request_fire/request_reload RPC（any_peer）；弹药/换弹状态同步；_on_fire_visual() 钩子（S6/S7 接枪口/音效）
## 谁调用：仅本地玩家的控制器触发；服务器结算弹药与伤害（tech-plan §4.2 扣弹药只走服务器）
## 规范：数据驱动（改 data/weapons.json 即生效，无硬编码数值）；节点权威=服务器（与 PlayerState 一致）
##       RPC 请求 any_peer+call_local+reliable，服务器 get_remote_sender_id() 校验来源（§4.4）

class_name WeaponBase
extends Node3D

## 武器 id（对应 data/weapons.json 的 weapons[].id）
@export var weapon_id := "pistol"

# 武器参数（来自 weapons.json；加载失败时用与 pistol 条目一致的默认值兜底）
var display_name := "手枪"   # name_zh（HUD 显示）
var damage := 25.0
var fire_rate := 5.0        # 发/秒
var mag_size := 12
var reload_time := 1.2      # 秒
var spread_deg := 1.5       # 度（散射锥）
var range_m := 60.0
var auto := false
var pellets := 1            # 单次开火弹丸数（霰弹>1，每颗独立 spread+射线）
var muzzle_offset := Vector3(0.0, -0.02, -0.4)

# 服务器权威状态（WeaponSync 同步到所有端，客户端只读）
@export var mag_current := 0
@export var reloading := false

## 命中碰撞层：世界(1) + 命中区域(3)。玩家层(2)不在内 = 无友伤（MVP）
const HIT_MASK := 1 | 3

var _fire_interval := 0.0   # 1 / fire_rate
var _cooldown_timer := 0.0  # 射速冷却（服务器）
var _reload_timer := 0.0    # 换弹计时（服务器）

@onready var _weapon_sync: MultiplayerSynchronizer = $WeaponSync


func _ready() -> void:
	# 弹药/换弹服务器权威（tech-plan §4.2）：武器节点权威固定为服务器
	set_multiplayer_authority(NetworkManager.SERVER_ID)
	_load_weapon_data()
	mag_current = mag_size
	_setup_sync()


func _process(delta: float) -> void:
	if not NetworkManager.is_server():
		return
	if _cooldown_timer > 0.0:
		_cooldown_timer = maxf(_cooldown_timer - delta, 0.0)
	if reloading:
		_reload_timer -= delta
		if _reload_timer <= 0.0:
			reloading = false
			mag_current = mag_size


## 配置弹药/换弹同步（4.7 铁律：先 add_property 再 set_replication_mode；replication_interval 非 sync_interval）
func _setup_sync() -> void:
	if _weapon_sync == null:
		return
	_weapon_sync.set_multiplayer_authority(NetworkManager.SERVER_ID)
	var cfg := SceneReplicationConfig.new()
	cfg.add_property(NodePath(".:mag_current"))
	cfg.property_set_replication_mode(NodePath(".:mag_current"), SceneReplicationConfig.REPLICATION_MODE_ALWAYS)
	cfg.add_property(NodePath(".:reloading"))
	cfg.property_set_replication_mode(NodePath(".:reloading"), SceneReplicationConfig.REPLICATION_MODE_ALWAYS)
	_weapon_sync.replication_config = cfg
	_weapon_sync.replication_interval = 0.05


# --- 数据装载（数据驱动，tech-plan §6.2） ---

func _load_weapon_data() -> void:
	var file := FileAccess.open("res://data/weapons.json", FileAccess.READ)
	if file == null:
		push_error("weapon_base: 无法打开 res://data/weapons.json，使用默认参数")
		_apply_weapon_data({})
		return
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	if parsed is Dictionary:
		var weapons: Array = (parsed as Dictionary).get("weapons", [])
		for entry in weapons:
			if entry is Dictionary and (entry as Dictionary).get("id", "") == weapon_id:
				_apply_weapon_data(entry as Dictionary)
				return
	push_error("weapon_base: weapons.json 未找到武器 %s，使用默认参数" % weapon_id)
	_apply_weapon_data({})


func _apply_weapon_data(w: Dictionary) -> void:
	# 兜底默认值与 data/weapons.json 的 pistol 条目一致（仅数据文件缺失/出错时生效）
	display_name = w.get("name_zh", weapon_id)
	damage = w.get("damage", 25.0)
	fire_rate = w.get("fire_rate", 5.0)
	mag_size = int(w.get("mag_size", 12))
	reload_time = w.get("reload_time", 1.2)
	spread_deg = w.get("spread_deg", 1.5)
	range_m = w.get("range_m", 60.0)
	auto = w.get("auto", false)
	pellets = maxi(int(w.get("pellets", 1)), 1)  # 扩展字段：霰弹单次散射弹丸数
	var off: Array = w.get("muzzle_offset", [0.0, -0.02, -0.4])
	if off.size() >= 3:
		muzzle_offset = Vector3(float(off[0]), float(off[1]), float(off[2]))
	else:
		muzzle_offset = Vector3(0.0, -0.02, -0.4)
	_fire_interval = 1.0 / maxf(fire_rate, 0.1)


# --- 客户端入口（仅本地玩家） ---

## 本地玩家左键：开火（客户端只算瞄准原方向；spread 在服务器按 pellets 应用，S4）
func try_fire() -> void:
	if not _is_owned_locally():
		return
	if reloading:
		return
	var origin := _get_aim_origin()
	var dir := _get_aim_dir()
	_on_fire_visual()  # S3 占位；S6/S7 接枪口火花/音效
	if NetworkManager.is_server():
		_server_fire(origin, dir)  # 单机/主机：直接本地执行服务器逻辑
	else:
		request_fire.rpc_id(NetworkManager.SERVER_ID, origin, dir, -1)


## 本地玩家 R 键：换弹
func try_reload() -> void:
	if not _is_owned_locally():
		return
	if NetworkManager.is_server():
		_server_start_reload()
	else:
		request_reload.rpc_id(NetworkManager.SERVER_ID)


## 客户端本地视觉钩子（枪口火花/音效；开火音效本地即时播放，视觉层 tech-plan §4.2）
func _on_fire_visual() -> void:
	_play_sfx(weapon_id + "_fire")  # pistol_fire / shotgun_fire


# --- RPC（请求类 any_peer，tech-plan §4.4） ---

## [any_peer] 客户端→服务器：开火请求。服务器复判（§6.2 第 3-4 步）
@rpc("any_peer", "call_local", "reliable")
func request_fire(origin: Vector3, dir: Vector3, target_id: int) -> void:
	if not NetworkManager.is_server():
		return
	var sender: int = multiplayer.get_remote_sender_id()
	if not _is_player_peer(sender):
		return  # 防御：请求来源必须为本武器所属玩家
	_server_fire(origin, dir)


## [any_peer] 客户端→服务器：换弹请求
@rpc("any_peer", "call_local", "reliable")
func request_reload() -> void:
	if not NetworkManager.is_server():
		return
	var sender: int = multiplayer.get_remote_sender_id()
	if not _is_player_peer(sender):
		return
	_server_start_reload()


# --- 服务器结算（tech-plan §4.2 / §6.2） ---

## 服务器：开火结算（弹药/射速冷却/物理复判/伤害；S4 支持 pellets 多弹丸）
func _server_fire(origin: Vector3, dir: Vector3) -> void:
	if reloading:
		return
	# 空仓自动换弹先于冷却检查（M3-S1 回归）：打出最后一发后冷却被置位，若先查冷却，
	# 紧接着的开火请求会在冷却处提前返回，永远到不了空仓分支 → 空仓不自动换弹
	if mag_current <= 0:
		_server_start_reload()
		return
	if _cooldown_timer > 0.0:
		return  # 射速冷却（fire_rate）
	mag_current -= 1
	_cooldown_timer = _fire_interval
	var player := _get_player()
	for i in pellets:
		# 每颗独立 spread（pistol pellets=1 也应用一次；未来无散射武器可 spread_deg=0）
		var pellet_dir := _apply_spread(dir) if (pellets > 1 or spread_deg > 0.0) else dir
		_hitscan_pellet(origin, pellet_dir, player)


## 服务器：单颗弹丸射线复判；命中 Hitbox → 结算该颗伤害（多颗命中同一目标=累加，符合霰弹直觉）
func _hitscan_pellet(origin: Vector3, dir: Vector3, player: Node3D) -> void:
	var hit := Hitscan.server_raycast(origin, dir, range_m, player, HIT_MASK)
	if hit.is_empty():
		return
	var collider: Node = hit.get("collider")
	if collider is Hitbox:
		(collider as Hitbox).apply_hit(damage, player)  # → damageable.take_damage（hp/state 经 HealthSync 广播）
		_broadcast_hit_confirmed(hit.get("position", Vector3.ZERO))
	# 命中普通世界物体（墙/地）无伤害；apply_damage 广播由状态同步隐式完成，避免重复结算


## [authority] 服务器→所有人：命中确认（客户端**收到广播才播血雾/受击音效**，不本地猜，tech-plan §4.4）
@rpc("authority", "call_local", "reliable")
func hit_confirmed(pos: Vector3) -> void:
	_play_sfx("zombie_hurt", pos)  # 命中音效（3D 定位在命中点）
	var parent := get_tree().current_scene as Node3D
	if parent != null:
		HitFeedback.spawn_blood_puff(parent, pos)


## 广播命中确认：单机（无 peer）直接本地执行；多人走 authority RPC（call_local 覆盖主机视角）
func _broadcast_hit_confirmed(pos: Vector3) -> void:
	if NetworkManager.is_network_active():
		hit_confirmed.rpc(pos)
	else:
		hit_confirmed(pos)


## 音效钩子：事件 → SfxPool 播放（素材缺失静默跳过；S7 接线；pos 默认武器位置）
func _play_sfx(event: String, pos: Vector3 = Vector3.ZERO) -> void:
	if pos == Vector3.ZERO:
		pos = global_position
	SfxPool.play_3d(event, pos)


## 服务器：开始换弹
func _server_start_reload() -> void:
	if reloading:
		return
	if mag_current >= mag_size:
		return
	reloading = true
	_reload_timer = reload_time


# --- 工具 ---

func _get_player() -> Node3D:
	var pivot := get_parent()
	if pivot == null:
		return null
	return pivot.get_parent() as Node3D  # WeaponPivot.parent = Player


## 是否属于本地玩家（本玩家根节点权威=本 peer）
func _is_owned_locally() -> bool:
	var player := _get_player()
	return player != null and player.is_multiplayer_authority()


## 本武器所属玩家的 peer id（用于 RPC 来源校验）
func _is_player_peer(peer_id: int) -> bool:
	var player := _get_player()
	return player != null and player.get_multiplayer_authority() == peer_id


func _get_camera() -> Camera3D:
	var player := _get_player()
	if player == null:
		return null
	return player.get_node_or_null("Head/Camera") as Camera3D


func _get_aim_origin() -> Vector3:
	var cam := _get_camera()
	return cam.global_position if cam != null else global_position


func _get_aim_dir() -> Vector3:
	var cam := _get_camera()
	return (-cam.global_transform.basis.z).normalized() if cam != null else (-global_transform.basis.z).normalized()


## 在朝向的圆锥内加随机散射（spread_deg）
func _apply_spread(base_dir: Vector3) -> Vector3:
	if spread_deg <= 0.0:
		return base_dir
	var spread_rad := deg_to_rad(spread_deg)
	var up := Vector3.UP
	if absf(base_dir.dot(up)) > 0.99:
		up = Vector3.RIGHT  # 朝天/朝地时换参考轴，避免 looking_at 失效
	var basis := Basis.looking_at(base_dir, up)
	var rotated := basis.rotated(basis.x, randf_range(-spread_rad, spread_rad))
	rotated = rotated.rotated(basis.y, randf_range(-spread_rad, spread_rad))
	return (-rotated.z).normalized()
