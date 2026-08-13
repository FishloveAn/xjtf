extends SceneTree
## 准星命中反馈回归：服务器确认伤害后，准星中央显示足够醒目的命中标记。

var _failures := 0


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	change_scene_to_file("res://scenes/main/main.tscn")
	await create_timer(1.0).timeout
	var player := current_scene.get_node("Players").get_child(0)
	var weapon := player.get_node("WeaponPivot/Pistol")
	var marker := current_scene.get_node("HUD/Root/HitMarker") as Label
	weapon.hit_confirmed(Vector3.ZERO, "body", 25.0, false)
	_check(marker.visible, "命中怪物后准星中央立即显示命中标记")
	await create_timer(0.25).timeout
	_check(marker.visible, "命中标记至少持续 0.25 秒，实机中可清楚看见")

	print("[准星命中反馈回归] %s" % ("PASS" if _failures == 0 else "%d FAIL" % _failures))
	change_scene_to_file("res://scenes/ui/main_menu.tscn")
	await process_frame
	quit(_failures)


func _check(condition: bool, message: String) -> void:
	if condition:
		print("[PASS] %s" % message)
	else:
		_failures += 1
		printerr("[FAIL] %s" % message)
