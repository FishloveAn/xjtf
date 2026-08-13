extends SceneTree
## 玩家报告回归：鼠标视角、Shift 冲刺和枪口曳光起点。

var _failures := 0


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	change_scene_to_file("res://scenes/main/main.tscn")
	await create_timer(1.0).timeout
	var player := current_scene.get_node("Players").get_child(0) as CharacterBody3D

	_check(player.has_method("_input"), "玩家使用优先级更高的 _input 接收鼠标事件")
	var before_pitch := float(player.get("pitch"))
	var motion := InputEventMouseMotion.new()
	motion.relative = Vector2(40.0, -30.0)
	Input.parse_input_event(motion)
	await process_frame
	_check(not is_equal_approx(float(player.get("pitch")), before_pitch), "捕获状态异常时鼠标移动仍可恢复并转动视角")

	_check(InputMap.has_action("sprint"), "InputMap 定义 sprint 动作")
	var shift_event := InputEventKey.new()
	shift_event.keycode = KEY_SHIFT
	shift_event.pressed = true
	Input.parse_input_event(shift_event)
	await process_frame
	_check(Input.is_action_pressed("sprint"), "真实 Shift 按键事件可触发 sprint 动作")
	shift_event.pressed = false
	Input.parse_input_event(shift_event)
	await process_frame
	player.global_position = Vector3(-20.0, 0.0, -0.6)
	Input.action_press("move_forward")
	Input.action_press("sprint")
	await create_timer(0.7).timeout
	var sprint_speed := Vector2(player.velocity.x, player.velocity.z).length()
	Input.action_release("sprint")
	Input.action_release("move_forward")
	_check(sprint_speed > 7.0, "按住 Shift 冲刺速度达到 7.5m/s（实际 %.2f）" % sprint_speed)

	var weapon := player.get_node("WeaponPivot/Pistol")
	_check(weapon.has_method("get_visual_muzzle_position"), "武器提供独立视觉枪口起点")
	if weapon.has_method("get_visual_muzzle_position"):
		var muzzle: Vector3 = weapon.call("get_visual_muzzle_position")
		var camera := player.get_node("Head/Camera") as Camera3D
		_check(muzzle.distance_to(camera.global_position) > 0.2, "曳光起点位于枪口而不是相机中心")

	print("[输入与枪口回归] %s" % ("PASS" if _failures == 0 else "%d FAIL" % _failures))
	change_scene_to_file("res://scenes/ui/main_menu.tscn")
	await process_frame
	quit(_failures)


func _check(condition: bool, message: String) -> void:
	if condition:
		print("[PASS] %s" % message)
	else:
		_failures += 1
		printerr("[FAIL] %s" % message)
