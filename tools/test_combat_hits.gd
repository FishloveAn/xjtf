extends SceneTree
## 战斗命中回归：通过怪物公开 Hitbox 验证身体伤害、特感伤害与普通怪爆头。

const CASES := [
	["common", "res://scenes/enemies/zombie_common.tscn", 25.0],
	["charger", "res://scenes/enemies/zombie_charger.tscn", 25.0],
	["spitter", "res://scenes/enemies/zombie_spitter.tscn", 25.0],
]

var _failures := 0


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	print("=== COMBAT_HITS START ===")
	var host := Node3D.new()
	root.add_child(host)
	for entry in CASES:
		await _verify_body_hit(host, entry[0], entry[1], entry[2])
	await _verify_common_headshot(host)
	await _verify_special_headshot(host, "charger", "res://scenes/enemies/zombie_charger.tscn", 600.0)
	await _verify_special_headshot(host, "spitter", "res://scenes/enemies/zombie_spitter.tscn", 150.0)
	print("=== COMBAT_HITS %s ===" % ("PASS" if _failures == 0 else "FAIL(%d)" % _failures))
	host.free()
	await process_frame
	await physics_frame
	quit(_failures)


func _verify_body_hit(host: Node3D, label: String, scene_path: String, damage: float) -> void:
	var enemy := (load(scene_path) as PackedScene).instantiate() as Node3D
	host.add_child(enemy)
	var health := enemy.get_node_or_null("Health")
	var hitbox := enemy.get_node_or_null("Hitbox")
	var before := float(health.get("hp")) if health != null else -1.0
	if hitbox != null:
		hitbox.call("apply_hit", damage, null)
	var after := float(health.get("hp")) if health != null else before
	_check(after == before - damage, "%s 身体命中扣除 %.0f HP（%.0f→%.0f）" % [label, damage, before, after])
	enemy.queue_free()
	await process_frame


func _verify_common_headshot(host: Node3D) -> void:
	var enemy := (load("res://scenes/enemies/zombie_common.tscn") as PackedScene).instantiate() as Node3D
	host.add_child(enemy)
	var health := enemy.get_node_or_null("Health")
	var head := enemy.get_node_or_null("HeadHitbox")
	_check(head != null, "普通怪存在独立头部 Hitbox")
	if head != null:
		var result: Dictionary = head.call("apply_hit", 1.0, null)
		_check(String(head.get("hit_zone")) == "head", "头部 Hitbox 标记为 head")
		_check(float(health.get("hp")) == 0.0,
			"普通怪头部命中直接击杀（hp=%.0f result=%s）" % [float(health.get("hp")), str(result)])
	enemy.queue_free()
	await process_frame


func _verify_special_headshot(host: Node3D, label: String, scene_path: String, max_hp: float) -> void:
	var enemy := (load(scene_path) as PackedScene).instantiate() as Node3D
	host.add_child(enemy)
	var health := enemy.get_node("Health")
	var head := enemy.get_node_or_null("HeadHitbox")
	_check(head != null, "%s 存在独立头部 Hitbox" % label)
	if head != null:
		var result: Dictionary = head.call("apply_hit", 25.0, null)
		_check(is_equal_approx(float(health.get("hp")), max_hp - 50.0), "%s 爆头造成 2 倍伤害" % label)
		_check(not bool(result.get("killed", true)), "%s 爆头不直接秒杀" % label)
	enemy.queue_free()
	await process_frame


func _check(ok: bool, label: String) -> void:
	if ok:
		print("  [PASS] ", label)
	else:
		_failures += 1
		printerr("  [FAIL] ", label)
