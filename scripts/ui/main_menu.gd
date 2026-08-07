## main_menu.gd — 主菜单控制器
## 职责：建房（端口）/ 加房（IP+端口）；连接失败提示并回主菜单
## 输入：UI 按钮/输入框；NetworkManager 信号（connected_to_server / connection_failed）
## 输出：建房成功或连接成功 → 切换大厅；失败 → 状态栏提示
## 谁调用：main_menu.tscn 场景 root
## 规范：tech-plan §3.5 / §4.5；同机双开默认 IP=127.0.0.1（冒烟测试备注）

extends Control

const LOBBY_SCENE := "res://scenes/ui/lobby.tscn"

@export var checkpoint_path := CheckpointManager.SAVE_PATH

@onready var _ip_edit: LineEdit = $CenterContainer/VBoxContainer/IpEdit
@onready var _port_edit: LineEdit = $CenterContainer/VBoxContainer/PortEdit
@onready var _status_label: Label = $CenterContainer/VBoxContainer/StatusLabel
@onready var _host_button: Button = $CenterContainer/VBoxContainer/HostButton
@onready var _continue_button: Button = $CenterContainer/VBoxContainer/ContinueButton
@onready var _join_button: Button = $CenterContainer/VBoxContainer/JoinButton


func _ready() -> void:
	NetworkManager.connected_to_server.connect(_on_connected_to_server)
	NetworkManager.connection_failed.connect(_on_connection_failed)
	_host_button.pressed.connect(_on_host_pressed)
	_continue_button.pressed.connect(_on_continue_pressed)
	_join_button.pressed.connect(_on_join_pressed)
	_show_save_status()


## S5 检查点：主菜单显示"可续玩"存档状态（save/progress.json，主机本机）
func _show_save_status() -> void:
	var can_continue := CheckpointManager.has_progress(checkpoint_path)
	_continue_button.visible = can_continue
	_continue_button.disabled = not can_continue
	if can_continue:
		var p := CheckpointManager.load_progress(checkpoint_path)
		if bool(p.get("completed", false)):
			_status_label.text = "有存档：第 %d 段已完成（后门休整）" % int(p.get("segment", 0))
		else:
			_status_label.text = "有存档：第 %d 段进行中（%s）" % [
				int(p.get("segment", 1)), LevelAdvance.PHASE_NAMES[int(p.get("level_phase", 0))]]


func _on_host_pressed() -> void:
	GameState.request_checkpoint_resume(false)
	var port := int(_port_edit.text)
	var err := NetworkManager.create_host(port)
	if err == OK:
		get_tree().change_scene_to_file(LOBBY_SCENE)
	else:
		_show_status("创建主机失败：端口被占用或绑定错误")  # B9


func _on_continue_pressed() -> void:
	GameState.request_checkpoint_resume(false)
	if not CheckpointManager.has_progress(checkpoint_path):
		_show_status("没有可继续的有效存档")
		return
	var port := int(_port_edit.text)
	if port < 0 or port > 65535:
		_show_status("继续游戏失败：端口必须在 0 到 65535 之间")
		return
	var err := NetworkManager.create_host(port)
	if err == OK:
		GameState.checkpoint_path = checkpoint_path
		GameState.request_checkpoint_resume(true)
		get_tree().change_scene_to_file(LOBBY_SCENE)
	else:
		_show_status("继续游戏失败：端口被占用或绑定错误")


func _on_join_pressed() -> void:
	GameState.request_checkpoint_resume(false)
	var ip := _ip_edit.text.strip_edges()
	var port := int(_port_edit.text)
	var err := NetworkManager.join_game(ip, port)
	if err == OK:
		# 发起成功，最终结果由信号决定
		_show_status("正在连接 %s:%d ..." % [ip, port])
	else:
		_show_status("加入失败：IP 或端口参数错误")


func _on_connected_to_server() -> void:
	get_tree().change_scene_to_file(LOBBY_SCENE)


func _on_connection_failed() -> void:
	_show_status("连接失败：无法连接到目标主机")


func _show_status(text: String) -> void:
	_status_label.text = text
