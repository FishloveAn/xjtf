extends SceneTree

# P2 验收：玩家 Body 与四把武器的引用、尺寸、朝向、枪口对齐和切枪可见性。
# 用法：godot --headless --path . --script tools/_debug_p2_models.gd

const PLAYER_SCENE := "res://scenes/player/player.tscn"
const PLAYER_MODEL := "res://assets/models/characters/char_player_01.glb"
const WEAPONS := [
	["Pistol", "res://assets/models/weapons/wep_pistol_01.glb", 0.20, 0.30, -0.40],
	["Shotgun", "res://assets/models/weapons/wep_shotgun_01.glb", 0.80, 1.00, -0.45],
	["Rifle", "res://assets/models/weapons/wep_rifle_01.glb", 0.70, 0.90, -0.45],
	["SMG", "res://assets/models/weapons/wep_smg_01.glb", 0.50, 0.70, -0.45],
]

var _failures := 0


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var packed := load(PLAYER_SCENE) as PackedScene
	_expect(packed != null, "玩家场景可加载")
	if packed == null:
		_finish()
		return

	var player := packed.instantiate() as Node3D
	root.add_child(player)
	await process_frame

	_check_player_body(player)
	_check_weapons(player)
	_check_weapon_visibility(player)

	root.remove_child(player)
	player.free()
	_finish()


func _check_player_body(player: Node3D) -> void:
	var body := player.get_node_or_null("Body") as Node3D
	_expect(body != null, "Player/Body 存在")
	if body == null:
		return
	_expect(body.scene_file_path == PLAYER_MODEL, "Player/Body 引用 char_player_01.glb")
	_expect(is_equal_approx(body.scale.x, 1.0) and body.scale.is_equal_approx(Vector3.ONE), "玩家模型使用 1:1 比例")
	_expect(absf(wrapf(body.rotation.y - PI, -PI, PI)) < 0.001, "玩家模型正面朝 Godot 前方 -Z")

	var bounds := _node_bounds(player, body)
	_expect(absf(bounds.size.y - 1.8) < 0.02, "玩家模型场景高度约 1.80m（实际 %.3fm）" % bounds.size.y)
	_expect(absf(bounds.position.y) < 0.02, "玩家模型脚底对齐地面 y=0（实际 %.3f）" % bounds.position.y)
	_expect(absf(bounds.end.y - 1.8) < 0.02, "玩家模型头顶对齐 y=1.80m（实际 %.3f）" % bounds.end.y)


func _check_weapons(player: Node3D) -> void:
	var pivot := player.get_node_or_null("WeaponPivot") as Node3D
	_expect(pivot != null, "Player/WeaponPivot 存在")
	if pivot == null:
		return
	_expect(pivot.get_child_count() == WEAPONS.size(), "WeaponPivot 恰好包含四把武器")

	for spec in WEAPONS:
		var weapon := pivot.get_node_or_null(spec[0]) as Node3D
		_expect(weapon != null, "%s 场景实例存在" % spec[0])
		if weapon == null:
			continue
		var visual := _find_scene_instance(weapon, spec[1])
		_expect(visual != null, "%s/WorldMesh 存在" % spec[0])
		if visual == null:
			continue
		_expect(visual.scene_file_path == spec[1], "%s/WorldMesh 引用正确 GLB" % spec[0])

		# Quaternius 转换后的枪口位于模型局部 +Z；场景必须转到 Godot 前方 -Z。
		var visual_forward := (visual.transform.basis * Vector3.BACK).normalized()
		_expect(visual_forward.dot(Vector3.FORWARD) > 0.999, "%s 枪口朝 -Z" % spec[0])

		var bounds := _node_bounds(weapon, visual)
		var longest := maxf(bounds.size.x, maxf(bounds.size.y, bounds.size.z))
		_expect(longest >= spec[2] and longest <= spec[3], "%s 长度 %.3fm 在规格范围内" % [spec[0], longest])
		_expect(absf(bounds.position.z - spec[4]) < 0.01, "%s 枪口端对齐 muzzle_offset.z" % spec[0])


func _find_scene_instance(parent: Node, scene_path: String) -> Node3D:
	for child in parent.get_children():
		if child is Node3D and (child as Node3D).scene_file_path == scene_path:
			return child as Node3D
	return null


func _check_weapon_visibility(player: Node3D) -> void:
	var pivot := player.get_node_or_null("WeaponPivot")
	if pivot == null:
		return
	_expect(_visible_weapon_count(pivot) == 1 and pivot.get_child(0).visible, "初始仅手枪可见")
	for index in pivot.get_child_count():
		player.call("_set_active_weapon", index)
		var selected := pivot.get_child(index) as Node3D
		_expect(_visible_weapon_count(pivot) == 1 and selected.visible, "切到第 %d 把时仅该武器可见" % (index + 1))


func _visible_weapon_count(pivot: Node) -> int:
	var count := 0
	for child in pivot.get_children():
		if child is Node3D and (child as Node3D).visible:
			count += 1
	return count


func _node_bounds(owner: Node3D, subtree: Node3D) -> AABB:
	var state := {"initialized": false, "bounds": AABB()}
	var relative := owner.global_transform.affine_inverse() * subtree.global_transform
	_collect_bounds(subtree, relative, state)
	return state.bounds


func _collect_bounds(node: Node, transform: Transform3D, state: Dictionary) -> void:
	if node is MeshInstance3D:
		var mesh_instance := node as MeshInstance3D
		if mesh_instance.mesh != null:
			var transformed := transform * mesh_instance.mesh.get_aabb()
			if state.initialized:
				state.bounds = state.bounds.merge(transformed)
			else:
				state.bounds = transformed
				state.initialized = true
	for child in node.get_children():
		var child_transform := transform
		if child is Node3D:
			child_transform *= (child as Node3D).transform
		_collect_bounds(child, child_transform, state)


func _expect(condition: bool, message: String) -> void:
	if condition:
		print("PASS  ", message)
	else:
		_failures += 1
		printerr("FAIL  ", message)


func _finish() -> void:
	print("P2_MODELS_SUMMARY failures=", _failures)
	quit(1 if _failures > 0 else 0)
