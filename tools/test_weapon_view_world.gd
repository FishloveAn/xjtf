extends SceneTree

# P2 玩家与武器美术接入最小验证：真实玩家场景的本地/远端可见性、渲染层、阴影与切枪兼容性。

const WEAPON_NAMES := [&"Pistol", &"Shotgun", &"Rifle", &"SMG"]
const WORLD_LAYER := 1
const VIEW_LAYER := 1 << 1

var _failures := 0


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var local_player := _spawn_player("1")
	var remote_player := _spawn_player("2")
	await process_frame

	_verify_player(local_player, true)
	_verify_player(remote_player, false)
	_verify_switching(local_player)

	local_player.queue_free()
	remote_player.queue_free()
	print("=== WEAPON_VIEW_WORLD %s ===" % ("PASS" if _failures == 0 else "FAIL(%d)" % _failures))
	quit(0 if _failures == 0 else 1)


func _spawn_player(peer_name: String) -> Node3D:
	var packed := load("res://scenes/player/player.tscn") as PackedScene
	var player := packed.instantiate() as Node3D
	player.name = peer_name
	get_root().add_child(player)
	return player


func _verify_player(player: Node3D, is_local: bool) -> void:
	var body := player.get_node_or_null("Body") as Node3D
	_expect(body != null, "%s 缺少第三人称 Body" % player.name)
	if body != null:
		_expect(body.visible != is_local, "%s Body 本地/远端可见性错误" % player.name)

	var view_root := player.get_node_or_null("Head/Camera/ViewMesh") as Node3D
	_expect(view_root != null, "%s 缺少 Camera/ViewMesh" % player.name)
	if view_root == null:
		return
	_expect(view_root.visible == is_local, "%s ViewMesh 本地可见性错误" % player.name)
	var camera := player.get_node("Head/Camera") as Camera3D
	_expect((camera.cull_mask & VIEW_LAYER) != 0, "%s Camera 未启用 ViewMesh 渲染层" % player.name)

	for weapon_name in WEAPON_NAMES:
		var weapon := player.get_node_or_null("WeaponPivot/%s" % weapon_name) as Node3D
		var view_mesh := view_root.get_node_or_null(String(weapon_name)) as Node3D
		_expect(weapon != null, "%s 缺少逻辑武器 %s" % [player.name, weapon_name])
		_expect(view_mesh != null, "%s 缺少 ViewMesh/%s" % [player.name, weapon_name])
		if weapon == null or view_mesh == null:
			continue
		var world_mesh := weapon.get_node_or_null("WorldMesh") as Node3D
		_expect(world_mesh != null, "%s/%s 缺少 WorldMesh" % [player.name, weapon_name])
		_expect(weapon.get_node_or_null("Visual") == null, "%s/%s 仍包含旧 Visual" % [player.name, weapon_name])
		if world_mesh == null:
			continue
		_expect(world_mesh.visible != is_local, "%s/%s WorldMesh 本地可见性错误" % [player.name, weapon_name])
		_verify_geometry(view_mesh, VIEW_LAYER, GeometryInstance3D.SHADOW_CASTING_SETTING_OFF, "ViewMesh/%s" % weapon_name)
		_verify_geometry(world_mesh, WORLD_LAYER, GeometryInstance3D.SHADOW_CASTING_SETTING_ON, "WorldMesh/%s" % weapon_name)


func _verify_switching(player: Node3D) -> void:
	player.set("primary_weapon_id", "rifle")
	player._set_active_weapon(2)
	var weapons: Array = player.get("_weapons")
	_expect(weapons.size() == 4, "切枪逻辑未保留四个 WeaponBase")
	for index in weapons.size():
		_expect(weapons[index].visible == (index == 2), "WeaponBase 激活标记与既有切枪逻辑不一致")
	var view_root := player.get_node("Head/Camera/ViewMesh")
	for index in WEAPON_NAMES.size():
		var view_mesh := view_root.get_node(String(WEAPON_NAMES[index])) as Node3D
		_expect(view_mesh.visible == (index == 2), "ViewMesh 未跟随切枪：%s" % WEAPON_NAMES[index])


func _verify_geometry(root: Node, expected_layer: int, expected_shadow: int, label: String) -> void:
	var meshes := _find_meshes(root)
	_expect(not meshes.is_empty(), "%s 不包含 MeshInstance3D" % label)
	for mesh in meshes:
		_expect(mesh.layers == expected_layer, "%s 渲染层错误" % label)
		_expect(mesh.cast_shadow == expected_shadow, "%s 阴影配置错误" % label)


func _find_meshes(root: Node) -> Array[MeshInstance3D]:
	var meshes: Array[MeshInstance3D] = []
	for child in root.get_children():
		if child is MeshInstance3D:
			meshes.append(child as MeshInstance3D)
		meshes.append_array(_find_meshes(child))
	return meshes


func _expect(condition: bool, message: String) -> void:
	if condition:
		return
	_failures += 1
	printerr("[P2 PLAYER/WEAPON] FAIL: " + message)
