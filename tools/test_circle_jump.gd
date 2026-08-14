extends SceneTree
## 圆弧跳回归：空中转向累积速度（圆弧跳）、直线跳不加速、软上限、落地动量保留。

var _failures := 0


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	change_scene_to_file("res://scenes/main/main.tscn")
	await create_timer(1.0).timeout
	var main := current_scene
	var player := main.get_node("Players").get_child(0) as CharacterBody3D
	var forward := -player.global_basis.z.normalized()
	var sprint_speed := float(player.get("SPRINT_SPEED"))
	var max_speed := float(player.get("AIR_STRAFE_MAX_SPEED"))
	var delta := 1.0 / 60.0

	# 1. 圆弧跳加速：起跳速度=冲刺，空中按横向键（输入方向与速度成 90°）累积速度
	var side := forward.cross(Vector3.UP).normalized()
	player.velocity = forward * sprint_speed
	for i in 20:
		player.call("_apply_air_strafe", side, delta)
	var speed_strafe := Vector2(player.velocity.x, player.velocity.z).length()
	_check(speed_strafe > sprint_speed, "空中横向转向累积速度超过冲刺（圆弧跳加速：%.2f > %.2f）" % [speed_strafe, sprint_speed])

	# 2. 直线跳不加速：输入方向与速度同向，不累积额外速度
	player.velocity = forward * sprint_speed
	for i in 20:
		player.call("_apply_air_strafe", forward, delta)
	var speed_straight := Vector2(player.velocity.x, player.velocity.z).length()
	_check(speed_straight <= sprint_speed + 0.01, "直线跳（无转向）不加速（%.2f ≤ %.2f）" % [speed_straight, sprint_speed])

	# 3. 软上限：超速（超过 AIR_STRAFE_MAX_SPEED）会被钳回上限
	player.velocity = forward * (max_speed + 5.0)
	player.call("_apply_air_strafe", forward, delta)
	var speed_cap := Vector2(player.velocity.x, player.velocity.z).length()
	_check(absf(speed_cap - max_speed) < 0.01, "超速被钳回软上限（%.2f ≈ %.2f）" % [speed_cap, max_speed])

	# 4. 落地动量保留：超速落地（圆弧跳动量）不被硬拉回冲刺速度
	player.velocity = forward * 10.0
	player.call("_apply_ground_move", forward, delta, true)
	var speed_landed := Vector2(player.velocity.x, player.velocity.z).length()
	_check(speed_landed > sprint_speed, "落地超速保留圆弧跳动量（%.2f > %.2f）" % [speed_landed, sprint_speed])

	# 5. 地面正常加速未被破坏：静止起跑朝目标速度逼近（不超过冲刺）
	player.velocity = Vector3.ZERO
	for i in 30:
		player.call("_apply_ground_move", forward, delta, true)
	var speed_ground := Vector2(player.velocity.x, player.velocity.z).length()
	_check(speed_ground > 0.0 and speed_ground <= sprint_speed + 0.01, "地面冲刺加速正常（%.2f ≤ %.2f）" % [speed_ground, sprint_speed])

	print("[圆弧跳回归] %s" % ("PASS" if _failures == 0 else "%d FAIL" % _failures))
	change_scene_to_file("res://scenes/ui/main_menu.tscn")
	await process_frame
	quit(_failures)


func _check(condition: bool, message: String) -> void:
	if condition:
		print("[PASS] %s" % message)
	else:
		_failures += 1
		printerr("[FAIL] %s" % message)
