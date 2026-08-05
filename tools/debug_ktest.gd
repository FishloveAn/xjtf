extends SceneTree
## 诊断脚本 v6：模拟按 K 键——直接向本地玩家 _unhandled_input 注入 KEY_K 事件，验证扣血路径
## 注意：只验证代码路径（is_server 守卫 + take_damage + HUD 可读 hp）；真实键盘 IME/布局拦截属运行时问题

const MAIN_SCENE := "res://scenes/main/main.tscn"

func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	print("=== KTEST START ===")
	change_scene_to_file(MAIN_SCENE)
	await create_timer(1.0).timeout
	var main := current_scene
	var players := main.get_node_or_null("Players") as Node3D
	if players == null or players.get_child_count() == 0:
		print("[k] no player found")
		quit(1)
		return
	var player := players.get_child(0) as Node3D
	var state := player.get_node_or_null("Health")
	var nm := root.get_node_or_null("NetworkManager")
	print("[k] is_server=", nm.is_server(), " player=", player.name)
	print("[k] hp before=", state.hp, " state=", state.state)
	var ev := InputEventKey.new()
	ev.keycode = KEY_K
	ev.physical_keycode = KEY_K
	ev.pressed = true
	player._unhandled_input(ev)
	print("[k] hp after =", state.hp, " state=", state.state, " (expect 80/ALIVE)")
	var ev_r := InputEventKey.new()
	ev_r.keycode = KEY_R
	ev_r.physical_keycode = KEY_R
	ev_r.pressed = true
	player._unhandled_input(ev_r)
	print("[k] R injected ok (reload path, weapon exists=", player.get_node_or_null("WeaponPivot") != null, ")")
	print("=== KTEST END ===")
	quit(0)
