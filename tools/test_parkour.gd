extends SceneTree
## 跑酷状态回归：滑铲门槛、低障碍翻越、高墙/空中拒绝和状态中断。

var _failures := 0


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	change_scene_to_file("res://scenes/main/main.tscn")
	await create_timer(1.0).timeout
	var main := current_scene
	var player := main.get_node("Players").get_child(0) as CharacterBody3D
	var forward := -player.global_basis.z.normalized()
	player.velocity = forward * 7.5
	_send_key(KEY_SHIFT, true)
	player.call("_try_start_slide")
	_check(float(player.get("_slide_timer")) > 0.0, "冲刺中按 Ctrl 可进入约 0.7 秒滑铲")
	player.call("_cancel_parkour")
	_check(float(player.get("_slide_timer")) == 0.0, "倒地/死亡中断入口会立即取消滑铲")
	_send_key(KEY_SHIFT, false)

	var obstacle := _make_wall(main, player.global_position + forward * 0.75 + Vector3.UP * 0.4, Vector3(0.35, 0.8, 1.0))
	await physics_frame
	var vaulted := bool(player.call("_try_start_vault"))
	_check(vaulted, "0.6–1.2 米低障碍可翻越")
	player.call("_cancel_parkour")
	obstacle.queue_free()
	await physics_frame

	var high_wall := _make_wall(main, player.global_position + forward * 0.75 + Vector3.UP, Vector3(0.35, 2.0, 1.0))
	await physics_frame
	_check(not bool(player.call("_try_start_vault")), "高墙会拒绝翻越")
	high_wall.queue_free()
	player.position.y += 2.0
	await physics_frame
	_check(not bool(player.call("_try_start_vault")), "空中不能触发翻越")

	print("[跑酷回归] %s" % ("PASS" if _failures == 0 else "%d FAIL" % _failures))
	change_scene_to_file("res://scenes/ui/main_menu.tscn")
	await process_frame
	quit(_failures)


func _make_wall(main: Node, position: Vector3, size: Vector3) -> StaticBody3D:
	var wall := StaticBody3D.new()
	var shape_node := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = size
	shape_node.shape = shape
	wall.add_child(shape_node)
	main.get_node("World").add_child(wall)
	wall.global_position = position
	return wall


func _send_key(keycode: Key, pressed: bool) -> void:
	var event := InputEventKey.new()
	event.keycode = keycode
	event.pressed = pressed
	Input.parse_input_event(event)


func _check(condition: bool, message: String) -> void:
	if condition:
		print("[PASS] %s" % message)
	else:
		_failures += 1
		printerr("[FAIL] %s" % message)
