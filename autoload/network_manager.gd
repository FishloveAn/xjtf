## network_manager.gd — 网络生命周期单例（autoload 注册名：NetworkManager）
## 职责：建房（Listen Server）/ 加房 / 断线清理；转发 SceneMultiplayer 信号；端口与 SERVER_ID 常量
## 输入：create_host(port) / join_game(ip, port)，由主菜单/大厅 UI 调用
## 输出：connected_to_server / connection_failed / server_disconnected /
##       peer_connected / peer_disconnected 信号（UI 只订阅本单例，不直接碰 multiplayer）
## 谁调用：scripts/ui/main_menu.gd / scripts/ui/lobby.gd / scripts/main/main.gd
## 规范：tech-plan §3.5 / §4.4；autoload 用 PascalCase（§2.2 规则 4）

extends Node

## 服务器固定 peer id（Godot 约定，禁止写死魔法数，tech-plan §4.4）
const SERVER_ID := 1
const DEFAULT_PORT := 5555
const MAX_PLAYERS := 8

signal connected_to_server
signal connection_failed
signal server_disconnected
signal peer_connected(peer_id: int)
signal peer_disconnected(peer_id: int)

var _is_hosting := false


func _ready() -> void:
	# 转发 SceneMultiplayer 信号；autoload 常驻，跨场景不失效
	multiplayer.connected_to_server.connect(_forward_connected)
	multiplayer.connection_failed.connect(_forward_connection_failed)
	multiplayer.server_disconnected.connect(_forward_server_disconnected)
	multiplayer.peer_connected.connect(_forward_peer_connected)
	multiplayer.peer_disconnected.connect(_forward_peer_disconnected)


## 建房（Listen Server）。端口被占用时 create_server 返回错误码，需检查（引擎版本记录 API 注意点）
func create_host(port: int = DEFAULT_PORT, max_clients: int = MAX_PLAYERS) -> Error:
	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_server(port, max_clients)
	if err != OK:
		printerr("NetworkManager: 创建主机失败 port=%d err=%d" % [port, err])
		return err
	multiplayer.multiplayer_peer = peer
	_is_hosting = true
	return OK


## 加房。返回值只代表"发起成功"；最终结果由 connected_to_server / connection_failed 决定
func join_game(ip: String, port: int = DEFAULT_PORT) -> Error:
	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_client(ip, port)
	if err != OK:
		printerr("NetworkManager: 加入失败 ip=%s port=%d err=%d" % [ip, port, err])
		return err
	multiplayer.multiplayer_peer = peer
	_is_hosting = false
	return OK


## 断开并清理当前会话（断线/失败/回主菜单时调用）
func disconnect_from_server() -> void:
	multiplayer.multiplayer_peer = null
	_is_hosting = false


## 是否服务器（Listen Server 主机）进程
func is_server() -> bool:
	# 无网络会话即单机服务器语义，同时避免 peer 刚清空时调用 is_server 触发引擎报错。
	return not is_network_active() or multiplayer.is_server()


## 是否本进程创建了主机
func is_hosting() -> bool:
	return _is_hosting


## 是否处于网络会话中（建房或加房后为 true；单机直跑为 false）
func is_network_active() -> bool:
	return multiplayer.multiplayer_peer != null


# --- 信号转发 ---

func _forward_connected() -> void:
	connected_to_server.emit()


func _forward_connection_failed() -> void:
	connection_failed.emit()
	disconnect_from_server()


func _forward_server_disconnected() -> void:
	server_disconnected.emit()
	disconnect_from_server()


func _forward_peer_connected(peer_id: int) -> void:
	peer_connected.emit(peer_id)


func _forward_peer_disconnected(peer_id: int) -> void:
	peer_disconnected.emit(peer_id)
