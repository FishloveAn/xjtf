## main.gd — 游戏主场景控制器
## 职责：主机权威生成/清理玩家节点（MultiplayerSpawner 复制到全员）；
##       单机（不开网络）也生成一个本地玩家；主机退出时客户端回主菜单；
##       丧尸刷怪由 Gameplay/WaveManager 接管（M2-S1 起，不再主场景直刷测试丧尸）
## 输入：NetworkManager 信号（peer_connected / peer_disconnected / server_disconnected）
## 输出：向 Players 容器生成 player.tscn 并 set_multiplayer_authority(peer_id)
## 谁调用：main.tscn 场景 root；仅服务器执行生成逻辑（tech-plan §4.2 网络节点由服务器生成）
## 规范：tech-plan §3.1 / §4.4；M0 不做主机迁移，主机退出即回主菜单（§4.5）

extends Node3D

const PLAYER_SCENE := preload("res://scenes/player/player.tscn")
const MAIN_MENU_SCENE := "res://scenes/ui/main_menu.tscn"
## 复制场景路径（M2-S5 联机实测缺陷修复）：4.7 MultiplayerSpawner 必须配置 spawnable_scenes，
## 否则客户端收到 spawn 包后 instantiate_scene 以空数组取 p_id=0 → 索引越界，
## 复制的玩家/丧尸/补给点在客户端无法创建（表现为客户端看不到任何玩家/丧尸）
const ZOMBIE_SCENE_PATH := "res://scenes/enemies/zombie_common.tscn"
const CHARGER_SCENE_PATH := "res://scenes/enemies/zombie_charger.tscn"  # M3-S2 特感复制
const SPITTER_SCENE_PATH := "res://scenes/enemies/zombie_spitter.tscn"  # M3-S3 喷吐者复制
const SUPPLY_SCENE_PATH := "res://scenes/environment/supply_point.tscn"

## 主机给客户端留的切场景宽限（秒）：避免生成包先于客户端主场景到达而被丢弃
const SPAWN_GRACE_SECONDS := 0.5

@onready var _players: Node3D = $Players
@onready var _player_spawner: MultiplayerSpawner = $PlayerSpawner
@onready var _zombie_spawner: MultiplayerSpawner = $ZombieSpawner
@onready var _pickup_spawner: MultiplayerSpawner = $PickupSpawner

## peer_id -> 玩家节点（去重用）
var _spawned_players: Dictionary = {}


func _ready() -> void:
	NetworkManager.peer_connected.connect(_on_peer_connected)
	NetworkManager.peer_disconnected.connect(_on_peer_disconnected)
	NetworkManager.server_disconnected.connect(_on_server_disconnected)

	# M2-S5 缺陷修复：注册可复制场景（两端都执行；单机直跑无 peer 时无副作用）
	_player_spawner.add_spawnable_scene("res://scenes/player/player.tscn")
	_zombie_spawner.add_spawnable_scene(ZOMBIE_SCENE_PATH)
	_zombie_spawner.add_spawnable_scene(CHARGER_SCENE_PATH)  # M3-S2 特感走同一 Spawner 复制
	_zombie_spawner.add_spawnable_scene(SPITTER_SCENE_PATH)  # M3-S3 喷吐者走同一 Spawner 复制
	_pickup_spawner.add_spawnable_scene(SUPPLY_SCENE_PATH)
	# M3-S6：丧尸死亡掉落物（弹药/医疗包）走 PickupSpawner 复制（服务器生成，各端同步）
	_pickup_spawner.add_spawnable_scene("res://scenes/environment/pickup_ammo.tscn")
	_pickup_spawner.add_spawnable_scene("res://scenes/environment/pickup_health.tscn")

	# M3-S6：进入主场景 = 新会话，统计清零（GameState autoload 跨场景常驻，重开对局必须重置）
	GameState.reset_session()

	if not NetworkManager.is_network_active():
		# 单机直跑（F5 不开网络）：生成本地玩家；波次刷怪由 WaveManager 驱动
		_spawn_player(NetworkManager.SERVER_ID)
		return

	# 防御：确保容器路径正确（与 .tscn 中的 spawn_path 一致）
	_player_spawner.spawn_path = _player_spawner.get_path_to(_players)

	if NetworkManager.is_server():
		# 主机：给自己留切场景宽限，再生成所有玩家
		await get_tree().create_timer(SPAWN_GRACE_SECONDS).timeout
		_spawn_player(NetworkManager.SERVER_ID)
		for peer_id in multiplayer.get_peers():
			_spawn_player(peer_id)
	else:
		# 客户端：通知服务器已进入主场景，等服务器生成自己的玩家
		_client_ready.rpc_id(NetworkManager.SERVER_ID)


## 客户端→服务器请求：客户端主场景就绪（tech-plan §4.4 请求类 RPC）
@rpc("any_peer", "call_local", "reliable")
func _client_ready() -> void:
	if not NetworkManager.is_server():
		return
	var sender: int = multiplayer.get_remote_sender_id()
	_spawn_player(sender)


## 服务器生成玩家节点（唯一入口，按 peer_id 去重）
func _spawn_player(peer_id: int) -> void:
	if _spawned_players.has(peer_id):
		return
	var player: Node3D = PLAYER_SCENE.instantiate()
	# M2-S5 缺陷修复：节点名 = str(peer_id)（Godot 官方推荐 name.to_int() 权威模式），
	# player_controller._enter_tree 用名字设 authority，保证 4.7 同步器能处理 pending spawn
	player.name = str(peer_id)
	# 先设权威再入树：生成包会携带 authority，客户端副本才能本地控制（关键顺序）
	player.set_multiplayer_authority(peer_id)
	_players.add_child(player)  # MultiplayerSpawner 自动复制到所有端
	_spawned_players[peer_id] = player


## 服务器清理玩家节点（对端断线时）
func _despawn_player(peer_id: int) -> void:
	var player: Node = _spawned_players.get(peer_id)
	if player != null:
		_spawned_players.erase(peer_id)
		player.queue_free()


func _on_peer_connected(peer_id: int) -> void:
	if NetworkManager.is_server():
		_spawn_player(peer_id)  # 中途加入（M0 边界：允许但少见）


func _on_peer_disconnected(peer_id: int) -> void:
	if NetworkManager.is_server():
		_despawn_player(peer_id)  # B7：客户端断线 → 胶囊消失，服务器不崩溃


func _on_server_disconnected() -> void:
	# B8：主机退出 → 客户端回主菜单，不崩溃
	get_tree().change_scene_to_file(MAIN_MENU_SCENE)
