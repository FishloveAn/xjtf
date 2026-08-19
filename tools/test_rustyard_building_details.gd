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

	_check_warehouse(rustyard, "WarehouseSW", "SpotWarehouseSW", "SupplyWarehouseSWAmmo",
		Vector3(-12, 0, 7))
	_check_warehouse(rustyard, "WarehouseNE", "SpotWarehouseNE", "SupplyWarehouseNEHealth",
		Vector3(3, 0, -11))
	_check_tactical_covers(rustyard)
	_check_warm_lights(rustyard)
	_check_visual_buildings(rustyard)
	_check_protected_gameplay_layout(rustyard)

	rustyard.queue_free()
	_finish()


func _check_warehouse(rustyard: Node3D, warehouse_name: String,
		spot_name: String, supply_name: String, original_supply_position: Vector3) -> void:
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
		_check(spot.position.is_equal_approx(original_supply_position),
			warehouse_name + " 既有补给标记位置保持不变")
		_check(supply.position.is_equal_approx(original_supply_position),
			warehouse_name + " 既有补给实例位置保持不变")


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


func _check_protected_gameplay_layout(rustyard: Node3D) -> void:
	var trigger_specs := {
		"SafeExit": ["safe_exit", Vector3(-16.3, 1.5, 0)],
		"CorridorEnter": ["corridor_enter", Vector3(7, 1.5, 0)],
		"CorridorMid": ["corridor_mid", Vector3(13, 1.5, 0)],
		"PlazaEnter": ["plaza_enter", Vector3(21.5, 1.5, 0)],
		"BackdoorEnter": ["backdoor_enter", Vector3(39, 1.5, 0)],
	}
	var triggers := rustyard.get_node_or_null("Triggers")
	_check(triggers != null and triggers.get_child_count() == trigger_specs.size(),
		"既有推进触发器数量保持不变")
	if triggers != null:
		for trigger_name in trigger_specs:
			var trigger := triggers.get_node_or_null(trigger_name) as Area3D
			var spec: Array = trigger_specs[trigger_name]
			_check(trigger != null and trigger.is_in_group("level_trigger"),
				trigger_name + " 触发器结构保持不变")
			if trigger != null:
				_check(trigger.get("trigger_id") == spec[0]
						and trigger.position.is_equal_approx(spec[1]),
					trigger_name + " 触发标识与位置保持不变")

	var horde_specs := {
		"HordeYardA": [Vector3(-12, 0, -12), "yard"],
		"HordeYardB": [Vector3(-12, 0, 12), "yard"],
		"HordeYardC": [Vector3(2, 0, -13), "yard"],
		"HordeYardD": [Vector3(2, 0, 13), "yard"],
		"HordeCorrA": [Vector3(8, 0, -2.5), "corridor"],
		"HordeCorrB": [Vector3(8, 0, 2.5), "corridor"],
		"HordeCorrC": [Vector3(19, 0, -2.5), "corridor"],
		"HordeCorrD": [Vector3(19, 0, 2.5), "corridor"],
		"HordePlazaA": [Vector3(22, 0, -14), "plaza"],
		"HordePlazaB": [Vector3(30, 0, -15), "plaza"],
		"HordePlazaC": [Vector3(38, 0, -13), "plaza"],
		"HordePlazaD": [Vector3(22, 0, 14), "plaza"],
		"HordePlazaE": [Vector3(30, 0, 15), "plaza"],
		"HordePlazaF": [Vector3(38, 0, 13), "plaza"],
		"HordePlazaG": [Vector3(30, 0, 0), "plaza"],
		"HordePlazaH": [Vector3(25, 0, 0), "plaza"],
	}
	var horde_spawns := rustyard.get_node_or_null("Markers/HordeSpawns")
	_check(horde_spawns != null and horde_spawns.get_child_count() == horde_specs.size(),
		"既有尸潮刷怪点数量保持不变")
	if horde_spawns != null:
		for spawn_name in horde_specs:
			var spawn := horde_spawns.get_node_or_null(spawn_name) as Marker3D
			var spec: Array = horde_specs[spawn_name]
			_check(spawn != null and spawn.is_in_group("horde_spawn_point")
					and spawn.position.is_equal_approx(spec[0])
					and spawn.get_meta("spawn_zone", "") == spec[1],
				spawn_name + " 刷怪位置与分区保持不变")

	var supply_spot_positions := {
		"SpotYardA": Vector3(-10, 0, -8),
		"SpotYardB": Vector3(-10, 0, 8),
		"SpotYardC": Vector3(2, 0, -4),
		"SpotCorr": Vector3(13, 0, 0),
		"SpotBack": Vector3(44, 0, 0),
		"SpotWarehouseSW": Vector3(-12, 0, 7),
		"SpotWarehouseNE": Vector3(3, 0, -11),
	}
	var supply_spots := rustyard.get_node_or_null("Markers/SupplySpots")
	_check(supply_spots != null and supply_spots.get_child_count() == supply_spot_positions.size(),
		"既有补给标记数量保持不变")
	if supply_spots != null:
		for spot_name in supply_spot_positions:
			var spot := supply_spots.get_node_or_null(spot_name) as Marker3D
			_check(spot != null and spot.position.is_equal_approx(supply_spot_positions[spot_name]),
				spot_name + " 补给标记位置保持不变")

	var pickup_positions := {
		"SupplyYardAmmo": Vector3(-10, 0, -8),
		"SupplyYardHealth": Vector3(-10, 0, 8),
		"SupplyYardAmmo2": Vector3(2, 0, -4),
		"SupplyCorrAmmo": Vector3(13, 0, 0),
		"SupplyBackHealth": Vector3(44, 0, -2),
		"SupplyBackAmmo": Vector3(44, 0, 2),
		"SupplyWarehouseSWAmmo": Vector3(-12, 0, 7),
		"SupplyWarehouseNEHealth": Vector3(3, 0, -11),
	}
	var pickups := rustyard.get_node_or_null("Pickups")
	_check(pickups != null and pickups.get_child_count() == pickup_positions.size(),
		"既有补给实例数量保持不变")
	if pickups != null:
		for pickup_name in pickup_positions:
			var pickup := pickups.get_node_or_null(pickup_name) as Node3D
			_check(pickup != null and pickup.position.is_equal_approx(pickup_positions[pickup_name]),
				pickup_name + " 补给实例位置保持不变")


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
