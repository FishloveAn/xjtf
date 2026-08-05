## lobby.gd — 大厅控制器
## 职责：在线玩家列表实时刷新（peer_connected/peer_disconnected）；主机"开始游戏"广播；
##       客户端显示"等待主机开始游戏"；主机退出回主菜单
## 输入：NetworkManager 信号（peer_connected / peer_disconnected / server_disconnected）
## 输出：主机点开始 → @rpc("authority") 广播 → 全员切换主场景
## 谁调用：lobby.tscn 场景 root
## 规范：tech-plan §4.4 广播类 RPC 用 authority；B1-B4 联机验收

extends Control

const MAIN_SCENE := "res://scenes/main/main.tscn"
const MAIN_MENU_SCENE := "res://scenes/ui/main_menu.tscn"

@onready var _player_list: VBoxContainer = $CenterContainer/VBoxContainer/PlayerList
@onready var _status_label: Label = $CenterContainer/VBoxContainer/StatusLabel
@onready var _start_button: Button = $CenterContainer/VBoxContainer/StartButton

## peer_id -> 显示名（服务端/客户端各自维护；服务端以 peer_connected 增员）
var _players: Dictionary = {}


func _ready() -> void:
	NetworkManager.peer_connected.connect(_on_peer_connected)
	NetworkManager.peer_disconnected.connect(_on_peer_disconnected)
	NetworkManager.server_disconnected.connect(_on_server_disconnected)
	_start_button.pressed.connect(_on_start_pressed)

	if NetworkManager.is_server():
		_start_button.visible = true  # 仅主机可见/可用（B1）
	_add_player(NetworkManager.SERVER_ID, "主机")
	_refresh_list()


func _add_player(peer_id: int, display_name: String) -> void:
	if not _players.has(peer_id):
		_players[peer_id] = display_name
		_refresh_list()


func _remove_player(peer_id: int) -> void:
	if _players.erase(peer_id):
		_refresh_list()


func _refresh_list() -> void:
	for child in _player_list.get_children():
		child.queue_free()
	for peer_id in _players:
		var label := Label.new()
		label.text = "玩家 %d（%s）" % [peer_id, _players[peer_id]]
		_player_list.add_child(label)
	if NetworkManager.is_server():
		_status_label.text = "在线玩家：%d / 8 —— 点击开始游戏" % _players.size()
	else:
		_status_label.text = "等待主机开始游戏（在线玩家：%d / 8）" % _players.size()  # B2


func _on_peer_connected(peer_id: int) -> void:
	_add_player(peer_id, "玩家")  # B3：列表实时增员


func _on_peer_disconnected(peer_id: int) -> void:
	_remove_player(peer_id)


func _on_start_pressed() -> void:
	if not NetworkManager.is_server():
		return
	_start_game.rpc()  # 广播（含 call_local），全员切主场景（B4）


## 服务器→所有人广播（tech-plan §4.4；客户端调用会被引擎忽略，安全网）
@rpc("authority", "call_local", "reliable")
func _start_game() -> void:
	get_tree().change_scene_to_file(MAIN_SCENE)


func _on_server_disconnected() -> void:
	# 主机退出：客户端回主菜单，不崩溃（tech-plan §4.5）
	get_tree().change_scene_to_file(MAIN_MENU_SCENE)
