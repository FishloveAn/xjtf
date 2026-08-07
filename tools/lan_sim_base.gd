extends SceneTree
## lan_sim_base.gd — M2-S5 联机模拟公共工具基类（debug_lan_sim.gd 继承本脚本）
## 职责：PASS/FAIL 记录、轮询等待、节点查找（玩家/补给/丧尸容器）、跨进程标记文件
## 纪律：--script 工具脚本不引用游戏类类型（M2-S3 铁律），全部动态访问；
##       lambda 修改外层局部变量在 GDScript 4 不可靠（M2-S5 实测），一律用成员变量承载回写；
##       显式类型注解防 ":=" 推断失败（M2-S4）；禁 Vector 字段复合赋值（M1-S5）

const MAIN_SCENE := "res://scenes/main/main.tscn"
const MAIN_MENU_SCENE := "res://scenes/ui/main_menu.tscn"
## 自动化联机测试使用独立端口，避免与用户正在运行的正式游戏（默认 5555）互相干扰。
const PORT := 15556
const SERVER_IP := "127.0.0.1"
const MAX_TOTAL_SEC := 150.0  # 兜底总超时（防死锁，正常远小于此）

var _nm: Node = null
var _pass := 0
var _fail := 0
var _main: Node = null
var _players: Node3D = null
var _zombies: Node3D = null
var _pickups: Node3D = null
# 以下成员变量供 lambda 回写（GDScript 4 lambda 修改外层局部变量不可靠）
var _got_conn := false
var _got_disc := false
var _wave_begun := 0
var _z_max := 0
var _me: Node3D = null
var _client_peer := 0  # 客户端 peer id（headless ENet 非固定 2，动态获取）


func _enter_main_scene() -> Node:
	change_scene_to_file(MAIN_SCENE)
	await create_timer(2.0).timeout  # 等场景加载 + autoload 转发信号就绪
	return current_scene


func _ensure_refs() -> void:
	if _main == null:
		return
	_players = _main.get_node_or_null("Players") as Node3D
	_zombies = _main.get_node_or_null("Zombies") as Node3D
	_pickups = _main.get_node_or_null("World/Pickups") as Node3D


func _find_player(auth: int) -> Node3D:
	for p in get_nodes_in_group("players"):
		if p.get_multiplayer_authority() == auth:
			return p as Node3D
	return null


func _find_supply(stype: int) -> Node3D:
	if _pickups == null:
		return null
	for c in _pickups.get_children():
		if int(c.get("supply_type")) == stype:
			return c as Node3D
	return null


func _count_supplies() -> int:
	var n := 0
	if _pickups != null:
		for c in _pickups.get_children():
			if c.is_in_group("supply_points"):
				n += 1
	return n


## 轮询等待：condition 为真返回 true；子超时 seconds 内未达返回 false
func _poll(deadline: int, seconds: float, condition: Callable) -> bool:
	var t := Time.get_ticks_msec() + int(seconds * 1000.0)
	while Time.get_ticks_msec() < t and Time.get_ticks_msec() < deadline:
		if condition.call():
			return true
		await create_timer(0.2).timeout
	return false


func _check(name: String, ok: bool, detail: String = "") -> void:
	if ok:
		_pass += 1
		print("[SIM][PASS] %s%s" % [name, "  " + detail if detail != "" else ""])
	else:
		_fail += 1
		printerr("[SIM][FAIL] %s  %s" % [name, detail])


func _write_marker(name: String) -> void:
	var f := FileAccess.open("user://%s.marker" % name, FileAccess.WRITE)
	if f != null:
		f.store_line("done")
		f.flush()


func _has_marker(name: String) -> bool:
	return FileAccess.file_exists("user://%s.marker" % name)


func _remove_marker(name: String) -> void:
	if FileAccess.file_exists("user://%s.marker" % name):
		DirAccess.remove_absolute(ProjectSettings.globalize_path("user://%s.marker" % name))


func _summary() -> void:
	print("[SIM] === LAN_SIM RESULT role=%s mode=%s PASS=%d FAIL=%d ===" % [get("_role"), get("_mode"), _pass, _fail])
