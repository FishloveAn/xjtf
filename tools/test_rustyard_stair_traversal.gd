extends SceneTree
## 使用玩家同规格胶囊体验证两组低平台楼梯可实际通行。
## 用法：godot --headless --path . --script tools/test_rustyard_stair_traversal.gd

const RUSTYARD_SCENE := "res://scenes/environment/rustyard/rustyard.tscn"
const WALK_SPEED := 2.0
const TIMEOUT_SECONDS := 3.0

var _failures := 0


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var packed := load(RUSTYARD_SCENE) as PackedScene
	_check(packed != null, "Rustyard 场景可加载")
	if packed == null:
		_finish()
		return
	var rustyard := packed.instantiate() as Node3D
	root.add_child(rustyard)
	await physics_frame
	await physics_frame

	var sw_result := await _walk_to_platform(Vector3(-11.5, 0.05, 7), -1.0, -14.0)
	_check(bool(sw_result["reached"]), "玩家规格胶囊体可登上西南仓库低平台")
	_check(float(sw_result["height"]) >= 0.45, "西南仓库平台提供 0.5 米高度变化")
	var ne_result := await _walk_to_platform(Vector3(2.5, 0.05, -11), 1.0, 5.0)
	_check(bool(ne_result["reached"]), "玩家规格胶囊体可登上东北仓库低平台")
	_check(float(ne_result["height"]) >= 0.45, "东北仓库平台提供 0.5 米高度变化")

	rustyard.queue_free()
	_finish()


func _walk_to_platform(start: Vector3, direction: float, target_x: float) -> Dictionary:
	var body := CharacterBody3D.new()
	body.floor_snap_length = 0.1
	body.position = start
	var collision := CollisionShape3D.new()
	collision.position = Vector3(0, 0.9, 0)
	var capsule := CapsuleShape3D.new()
	capsule.radius = 0.4
	capsule.height = 1.8
	collision.shape = capsule
	body.add_child(collision)
	root.add_child(body)
	await physics_frame

	var elapsed := 0.0
	var reached := false
	while elapsed < TIMEOUT_SECONDS:
		var delta := 1.0 / float(Engine.physics_ticks_per_second)
		body.velocity.x = direction * WALK_SPEED
		body.velocity.z = 0.0
		body.velocity.y = -0.1 if body.is_on_floor() else body.velocity.y - 9.8 * delta
		body.move_and_slide()
		if ((direction < 0.0 and body.position.x <= target_x)
				or (direction > 0.0 and body.position.x >= target_x)):
			reached = true
			break
		elapsed += delta
		await physics_frame
	var result := {"reached": reached, "height": body.position.y, "position": body.position}
	body.queue_free()
	await physics_frame
	return result


func _check(condition: bool, label: String) -> void:
	if condition:
		print("  [PASS] " + label)
	else:
		_failures += 1
		print("  [FAIL] " + label)


func _finish() -> void:
	print("RUSTYARD_STAIR_TRAVERSAL %s (fail=%d)" % [
		"PASS" if _failures == 0 else "FAIL", _failures])
	quit(_failures)
