extends SceneTree
## Rustyard P2 建筑细节验收：可进入仓库、低平台、战术掩体与暖色局部灯。
## 用法：godot --headless --path . --script tools/test_rustyard_building_details.gd

const RUSTYARD_SCENE := "res://scenes/environment/rustyard/rustyard.tscn"

var _failures := 0


func _initialize() -> void:
	var packed := load(RUSTYARD_SCENE) as PackedScene
	_check(packed != null, "Rustyard 场景可加载")
	if packed == null:
		_finish()
		return
	var rustyard := packed.instantiate() as Node3D
	root.add_child(rustyard)

	_check_warehouse(rustyard, "WarehouseSW", "SpotWarehouseSW", "SupplyWarehouseSWAmmo")
	_check_warehouse(rustyard, "WarehouseNE", "SpotWarehouseNE", "SupplyWarehouseNEHealth")
	_check_tactical_covers(rustyard)
	_check_warm_lights(rustyard)
	_check_visual_buildings(rustyard)

	rustyard.queue_free()
	_finish()


func _check_warehouse(rustyard: Node3D, warehouse_name: String,
		spot_name: String, supply_name: String) -> void:
	var warehouse := rustyard.get_node_or_null("Walls/" + warehouse_name)
	_check(warehouse != null, warehouse_name + " 可进入仓库存在")
	if warehouse == null:
		return
	for part_name in ["Roof", "Platform", "Stairs"]:
		var body := warehouse.get_node_or_null(part_name) as StaticBody3D
		_check(body != null, warehouse_name + "/" + part_name + " 使用静态碰撞体")
		if body == null:
			continue
		_check(body.get_node_or_null("Collision") is CollisionShape3D,
			warehouse_name + "/" + part_name + " 有简化碰撞")
	var roof := warehouse.get_node_or_null("Roof") as Node
	_check(roof != null and roof.is_in_group("navigation_ceiling"),
		warehouse_name + " 屋顶不会被导航烘焙投影成地面障碍")
	for part_name in ["Platform", "Stairs"]:
		var part := warehouse.get_node_or_null(part_name) as Node
		_check(part != null and part.is_in_group("navigation_floor"),
			warehouse_name + "/" + part_name + " 标记为可行走楼面")

	var spot := rustyard.get_node_or_null("Markers/SupplySpots/" + spot_name) as Marker3D
	var supply := rustyard.get_node_or_null("Pickups/" + supply_name) as Node3D
	_check(spot != null and supply != null, warehouse_name + " 补给标记和补给点存在")
	if spot != null and supply != null:
		_check(spot.position.is_equal_approx(supply.position), warehouse_name + " 补给标记与实例位置一致")
		_check(is_equal_approx(supply.position.y, 0.5), warehouse_name + " 补给位于低平台表面")


func _check_tactical_covers(rustyard: Node3D) -> void:
	var covers := rustyard.get_node_or_null("TacticalCovers")
	_check(covers != null, "战术掩体容器存在")
	if covers == null:
		return
	_check(covers.get_child_count() == 4, "战术掩体数量为 4")
	for child in covers.get_children():
		_check(child is StaticBody3D, str(child.name) + " 是静态碰撞体")
		_check(child.get_node_or_null("Collision") is CollisionShape3D,
			str(child.name) + " 使用简化碰撞")
		_check(child.get_node_or_null("Visual") is Node3D, str(child.name) + " 复用正式路障模型")


func _check_warm_lights(rustyard: Node3D) -> void:
	var lighting := rustyard.get_node_or_null("LocalLighting")
	_check(lighting != null, "局部灯光容器存在")
	if lighting == null:
		return
	_check(lighting.get_child_count() == 4, "局部灯光数量为 4")
	for fixture in lighting.get_children():
		var light := fixture.get_node_or_null("Light") as OmniLight3D
		_check(light != null, str(fixture.name) + " 挂载 OmniLight3D")
		if light != null:
			_check(light.light_color.r > light.light_color.b, str(fixture.name) + " 使用暖色光")
			_check(light.omni_range <= 6.0, str(fixture.name) + " 光照范围受控")


func _check_visual_buildings(rustyard: Node3D) -> void:
	var buildings := rustyard.get_node_or_null("Buildings")
	_check(buildings != null and buildings.get_child_count() == 8, "P1 建筑外壳仍保持 8 个")
	if buildings == null:
		return
	_check(buildings.find_children("*", "CollisionObject3D", true, false).is_empty(),
		"P1 建筑外壳仍为纯视觉")


func _check(condition: bool, label: String) -> void:
	if condition:
		print("  [PASS] " + label)
	else:
		_failures += 1
		print("  [FAIL] " + label)


func _finish() -> void:
	print("RUSTYARD_BUILDING_DETAILS %s (fail=%d)" % [
		"PASS" if _failures == 0 else "FAIL", _failures])
	quit(_failures)
