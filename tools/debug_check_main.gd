extends SceneTree
## 临时诊断脚本（M1-ZOMBIE）：定位主场景测试丧尸不生成/不显示的确切原因。
## 用法：godot --headless --path . --script tools/debug_check_main.gd
## 场景 A：单机直跑（不开网络）——主场景 _ready 直接 spawn 玩家+丧尸
## 场景 B：create_host 建房——主场景 _ready 等 0.5s 后 spawn 玩家+丧尸
## 输出：Zombies 容器子节点数 / 每个子节点 name/position/visible/collision_layer /
##       ZombieSpawner.spawnable_scenes 大小 / is_server() 值 / 运行时错误（stderr）
## 注意：--script 下 autoload 名在编译期不可解析，故经 root.get_node 运行时取 NetworkManager

const MAIN_SCENE := "res://scenes/main/main.tscn"
const PORT := 5555

var _nm: Node = null


func _initialize() -> void:
	_nm = root.get_node_or_null("NetworkManager")
	if _nm == null:
		printerr("NetworkManager autoload not found")
		quit(2)
		return
	call_deferred("_run")


func _run() -> void:
	print("=== DEBUG_CHECK_MAIN START ===")
	print("[env] is_server=", _nm.is_server(), " is_network_active=", _nm.is_network_active())
	await _test_standalone()
	await _test_host()
	print("=== DEBUG_CHECK_MAIN END ===")
	quit(0)


func _test_standalone() -> void:
	print("\n--- Scenario A: standalone (no network) ---")
	change_scene_to_file(MAIN_SCENE)
	await create_timer(1.5).timeout
	_dump_scene("A")


func _test_host() -> void:
	print("\n--- Scenario B: create_host + main ---")
	var err: Variant = _nm.call("create_host", PORT)
	print("[host] create_host err=", err,
		" is_server=", _nm.is_server(),
		" is_network_active=", _nm.is_network_active())
	change_scene_to_file(MAIN_SCENE)
	await create_timer(1.5).timeout
	_dump_scene("B")
	_nm.disconnect_from_server()


func _dump_scene(tag: String) -> void:
	var main := current_scene
	if main == null:
		print("[", tag, "] current_scene == null")
		return
	print("[", tag, "] main=", main.name, " is_server=", _nm.is_server())
	var spawner := main.get_node_or_null("ZombieSpawner") as MultiplayerSpawner
	if spawner != null:
		print("[", tag, "] ZombieSpawner spawnable_scene_count=", spawner.get_spawnable_scene_count(),
			" spawn_path=", spawner.spawn_path,
			" is_multiplayer_authority=", spawner.is_multiplayer_authority())
	else:
		print("[", tag, "] ZombieSpawner == null")
	var zombies := main.get_node_or_null("Zombies") as Node3D
	if zombies != null:
		print("[", tag, "] Zombies child_count=", zombies.get_child_count())
		for c in zombies.get_children():
			print("[", tag, "]   zombie name=", c.name,
				" class=", c.get_class(),
				" global_pos=", c.global_position,
				" visible=", c.visible,
				" coll_layer=", c.collision_layer,
				" authority=", c.get_multiplayer_authority())
	else:
		print("[", tag, "] Zombies == null")
	var players := main.get_node_or_null("Players") as Node3D
	if players != null:
		print("[", tag, "] Players child_count=", players.get_child_count())
		for c in players.get_children():
			print("[", tag, "]   player name=", c.name,
				" global_pos=", c.global_position,
				" visible=", c.visible,
				" authority=", c.get_multiplayer_authority())
	else:
		print("[", tag, "] Players == null")
	var points := get_nodes_in_group("spawn_point")
	print("[", tag, "] spawn_point group count=", points.size())
	for p in points:
		print("[", tag, "]   spawn ", p.name, " global_pos=", (p as Node3D).global_position)
