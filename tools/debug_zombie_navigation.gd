extends SceneTree
## 普通丧尸绕障行为回归：玩家与丧尸之间有一堵有限长度的墙，丧尸应绕到攻击范围。
## 用法：godot --headless --path . --script tools/debug_zombie_navigation.gd

const ZOMBIE_SCENE_PATH := "res://scenes/enemies/zombie_common.tscn"
const START := Vector3(-5.0, 0.0, 0.0)
const TARGET := Vector3(5.0, 0.0, 0.0)
const TIMEOUT_SECONDS := 8.0
const REACHED_DISTANCE := 2.2

var _fail := 0


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	print("=== ZOMBIE NAVIGATION TEST START ===")
	var world := Node3D.new()
	world.name = "ZombieNavigationTest"
	root.add_child(world)
	_add_static_box(world, "Ground", Vector3(20.0, 0.2, 20.0), Vector3(0.0, -0.1, 0.0))
	_add_static_box(world, "FiniteWall", Vector3(0.6, 2.0, 5.0), Vector3(0.0, 1.0, 0.0))

	var player := CharacterBody3D.new()
	player.name = "TargetPlayer"
	player.add_to_group("players")
	world.add_child(player)
	player.global_position = TARGET

	var zombie_scene := load(ZOMBIE_SCENE_PATH) as PackedScene
	_check(zombie_scene != null, "普通丧尸场景可加载")
	if zombie_scene == null:
		_finish()
		return
	var zombie := zombie_scene.instantiate() as CharacterBody3D
	world.add_child(zombie)
	zombie.global_position = START

	var min_distance := START.distance_to(TARGET)
	var elapsed := 0.0
	while elapsed < TIMEOUT_SECONDS:
		await physics_frame
		elapsed += 1.0 / float(Engine.physics_ticks_per_second)
		min_distance = minf(min_distance, zombie.global_position.distance_to(TARGET))
		if min_distance <= REACHED_DISTANCE:
			break

	_check(min_distance <= REACHED_DISTANCE,
		"有限墙可绕行：%.1fs 内进入目标范围（最近 %.2fm）" % [TIMEOUT_SECONDS, min_distance])
	print("  最终位置=%s，最近距离=%.2fm" % [str(zombie.global_position), min_distance])
	world.queue_free()
	await process_frame
	_finish()


func _add_static_box(parent: Node3D, node_name: String, size: Vector3, position: Vector3) -> void:
	var body := StaticBody3D.new()
	body.name = node_name
	body.position = position
	var collision := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = size
	collision.shape = shape
	body.add_child(collision)
	parent.add_child(body)


func _check(condition: bool, label: String) -> void:
	if condition:
		print("  [PASS] " + label)
	else:
		_fail += 1
		print("  [FAIL] " + label)


func _finish() -> void:
	print("=== ZOMBIE NAVIGATION TEST %s (fail=%d) ===" % ["PASS" if _fail == 0 else "FAIL", _fail])
	quit(_fail)
