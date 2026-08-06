## main_menu.gd — 主菜单控制器
## 职责：建房（端口）/ 加房（IP+端口）；连接失败提示并回主菜单
## 输入：UI 按钮/输入框；NetworkManager 信号（connected_to_server / connection_failed）
## 输出：建房成功或连接成功 → 切换大厅；失败 → 状态栏提示
## 谁调用：main_menu.tscn 场景 root
## 规范：tech-plan §3.5 / §4.5；同机双开默认 IP=127.0.0.1（冒烟测试备注）

extends Control

const LOBBY_SCENE := "res://scenes/ui/lobby.tscn"

@onready var _ip_edit: LineEdit = $CenterContainer/VBoxContainer/IpEdit
@onready var _port_edit: LineEdit = $CenterContainer/VBoxContainer/PortEdit
@onready var _status_label: Label = $CenterContainer/VBoxContainer/StatusLabel
@onready var _host_button: Button = $CenterContainer/VBoxContainer/HostButton
@onready var _join_button: Button = $CenterContainer/VBoxContainer/JoinButton


func _ready() -> void:
	NetworkManager.connected_to_server.connect(_on_connected_to_server)
	NetworkManager.connection_failed.connect(_on_connection_failed)
	_host_button.pressed.connect(_on_host_pressed)
	_join_button.pressed.connect(_on_join_pressed)
	_show_save_status()


## S5 检查点：主菜单显示"可续玩"存档状态（save/progress.json，主机本机）
func _show_save_status() -> void:
	if CheckpointManager.has_progress():
		var p := CheckpointManager.load_progress()
		_status_label.text = "有存档：第 %d 段已完成（用时 %.0f 秒），重开可续" % [
			int(p.get("segment", 0)), float(p.get("finish_time_s", 0.0))]


func _on_host_pressed() -> void:
	var port := int(_port_edit.text)
	var err := NetworkManager.create_host(port)
	if err == OK:
		get_tree().change_scene_to_file(LOBBY_SCENE)
	else:
		_show_status("创建主机失败：端口被占用或绑定错误")  # B9


func _on_join_pressed() -> void:
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
