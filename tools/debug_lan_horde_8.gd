extends "res://tools/debug_lan_multi.gd"
## 8 个 headless 玩家 + 服务器 100 个普通怪的独立联机压力专项。
## 复用多实例工具的 run_id、出生快照、ENet 统计和同步退出协议，不改正式玩法逻辑。

const HORDE_SIZE := 100


func _run_server() -> void:
	var err: int = _nm.create_host(_port, _count)
	_check("压力专项动态端口建房", err == OK, "err=%d" % err)
	if err != OK:
		return
	var ok := await _poll(25.0, func() -> bool: return _nm.multiplayer.get_peers().size() == _count - 1)
	_check("8 人全部接入", ok, "peers=%d/%d" % [_nm.multiplayer.get_peers().size() + 1, _count])
	if not ok:
		return
	await _enter_main()
	_write_json("server_scene.json", {"run_id": _run_id})
	await _verify_players_and_snapshot()
	if _fail > 0:
		return
	ok = await _poll(25.0, func() -> bool: return _file_count("snapshot_") == _count)
	_check("8 端玩家快照齐全", ok, "snapshots=%d/%d" % [_file_count("snapshot_"), _count])
	if not ok:
		return

	var zombies := _main.get_node_or_null("Zombies")
	var wave_manager := _main.get_node_or_null("Gameplay/WaveManager")
	_check("压力场景节点可用", zombies != null and wave_manager != null)
	if zombies == null or wave_manager == null:
		return
	var waves = wave_manager.get("_waves")
	_check("波次数组可注入专项配置", waves is Array and waves.size() >= 3)
	if not (waves is Array) or waves.size() < 3:
		return
	waves[2] = {
		"id": "lan_horde_8x100",
		"name": "8人100怪联机压力专项",
		"composition": {"common": HORDE_SIZE},
		"concurrent_cap": HORDE_SIZE,
		"spawn_style": "burst",
		"spawn_interval": 0.01,
		"cleared_when": {"type": "all_spawned_killed"},
		"reward": {"health_packs": 0, "ammo": 0},
	}
	var director := wave_manager.get("_director") as Node
	if director != null:
		director.set("_degrade_enabled", false)
	wave_manager.set("level_mode", false)
	wave_manager.call("_begin_wave", 2)
	wave_manager.set("_setup_timer", 0.05)
	_write_json("horde_start.json", {"run_id": _run_id})
	ok = await _poll(35.0, func() -> bool: return zombies.get_child_count() == HORDE_SIZE)
	_check("服务器生成 100 个普通怪", ok, "zombies=%d" % zombies.get_child_count())
	if not ok:
		return
	_write_json("horde_seen_server_0.json", {"run_id": _run_id, "count": zombies.get_child_count()})
	ok = await _poll(35.0, func() -> bool: return _file_count("horde_seen_") == _count)
	_check("8 端均复制 100 怪", ok, "seen=%d/%d" % [_file_count("horde_seen_"), _count])
	if not ok:
		return

	# 冻结后续刷怪，只经正式 Health.take_damage 路径击杀一只并验证 Spawner 回池移除。
	wave_manager.set_process(false)
	_write_json("kill_go.json", {"run_id": _run_id})
	var health := zombies.get_child(0).get_node_or_null("Health")
	_check("普通怪 Health 可用于正式击杀", health != null)
	if health == null:
		return
	health.call("take_damage", 9999.0)
	ok = await _poll(8.0, func() -> bool: return zombies.get_child_count() < HORDE_SIZE)
	_check("服务器观察到击杀回池", ok, "zombies=%d" % zombies.get_child_count())
	if ok:
		_write_json("kill_seen_server_0.json", {"run_id": _run_id, "count": zombies.get_child_count()})
	ok = await _poll(20.0, func() -> bool: return _file_count("kill_seen_") == _count)
	_check("8 端均观察到击杀移除", ok, "seen=%d/%d" % [_file_count("kill_seen_"), _count])
	if not ok:
		_write_json("horde_finish.json", {"run_id": _run_id, "ok": false})
		return

	# 压测结束前让剩余怪物全部走服务器 Health→死亡表现→ZombiePool 回池正式链路。
	# 批量收尾不测掉落，清空概率表避免 99 次死亡额外生成随机 Pickup 干扰资源断言。
	# 单只完整死亡表现已经在上方验证；批量阶段先让客户端冻结 AI 本地 cleanup tween，
	# 避免它的兜底 queue_free 与服务器权威 Spawner despawn 重复争抢同一 net_id。
	_write_json("horde_cleanup_prepare.json", {"run_id": _run_id})
	ok = await _poll(15.0, func() -> bool: return _file_count("cleanup_armed_") == _count - 1)
	_check("7 个客户端已冻结重复本地清理", ok,
		"armed=%d/%d" % [_file_count("cleanup_armed_"), _count - 1])
	if not ok:
		return
	var loot_manager := _main.get_node_or_null("Gameplay/LootManager")
	if loot_manager != null:
		loot_manager.set("_table", {})
	_write_json("horde_cleanup_start.json", {"run_id": _run_id})
	for zombie in zombies.get_children():
		var zombie_health := zombie.get_node_or_null("Health")
		if zombie_health != null:
			zombie_health.call("take_damage", 9999.0)
	ok = await _poll(15.0, func() -> bool: return zombies.get_child_count() == 0)
	_check("服务器正式死亡链路清空压力怪物", ok, "zombies=%d" % zombies.get_child_count())
	var zombie_pool := wave_manager.get("_pool") as Node
	var pool_active_count := -1
	if zombie_pool != null:
		var active = zombie_pool.get("_active")
		if active is Array:
			pool_active_count = active.size()
	var pool_empty := zombie_pool != null and pool_active_count == 0
	_check("服务器 ZombiePool active 归零", pool_empty, "active=%d" % pool_active_count)
	if ok and pool_empty:
		_write_json("cleanup_seen_server_0.json", {"run_id": _run_id})
	ok = await _poll(20.0, func() -> bool: return _file_count("cleanup_seen_") == _count)
	_check("8 端完成怪物资源收尾", ok, "seen=%d/%d" % [_file_count("cleanup_seen_"), _count])
	_write_json("horde_finish.json", {"run_id": _run_id, "ok": ok})


func _run_client() -> void:
	_nm.connected_to_server.connect(func() -> void: _connected = true)
	var err: int = _nm.join_game("127.0.0.1", _port)
	_check("压力客户端发起加入", err == OK, "err=%d" % err)
	if err != OK:
		return
	var ok := await _poll(20.0, func() -> bool: return _connected)
	_check("压力客户端连接主机", ok)
	if not ok:
		return
	ok = await _poll(25.0, func() -> bool: return _valid_signal("server_scene.json"))
	_check("压力客户端收到主场景信号", ok)
	if not ok:
		return
	await _enter_main()
	await _verify_players_and_snapshot()
	if _fail > 0:
		return
	ok = await _poll(25.0, func() -> bool: return _file_count("snapshot_") == _count)
	_check("压力客户端收齐玩家快照", ok)
	if not ok:
		return
	var server_snapshot := _read_json("snapshot_server_0.json").get("players", {}) as Dictionary
	_check("压力客户端玩家槽映射一致", _snapshot_signature(_snapshot) == _snapshot_signature(server_snapshot))

	ok = await _poll(25.0, func() -> bool: return _valid_signal("horde_start.json"))
	_check("收到 100 怪压力阶段", ok)
	if not ok:
		return
	var zombies := _main.get_node_or_null("Zombies")
	_check("客户端 Zombies 容器可用", zombies != null)
	if zombies == null:
		return
	ok = await _poll(35.0, func() -> bool: return zombies.get_child_count() == HORDE_SIZE)
	_check("客户端复制完整 100 怪", ok, "zombies=%d" % zombies.get_child_count())
	if not ok:
		return
	_write_json("horde_seen_client_%d.json" % _index, {"run_id": _run_id, "count": zombies.get_child_count()})

	ok = await _poll(25.0, func() -> bool: return _valid_signal("kill_go.json"))
	_check("收到击杀观察阶段", ok)
	if not ok:
		return
	ok = await _poll(12.0, func() -> bool: return zombies.get_child_count() < HORDE_SIZE)
	_check("客户端观察到怪物击杀移除", ok, "zombies=%d" % zombies.get_child_count())
	if ok:
		_write_json("kill_seen_client_%d.json" % _index, {"run_id": _run_id, "count": zombies.get_child_count()})
	ok = await _poll(20.0, func() -> bool: return _valid_signal("horde_cleanup_prepare.json"))
	_check("收到批量收尾准备阶段", ok)
	if not ok:
		return
	for zombie in zombies.get_children():
		var ai := zombie.get_node_or_null("AI")
		if ai != null:
			ai.process_mode = Node.PROCESS_MODE_DISABLED
	_write_json("cleanup_armed_client_%d.json" % _index, {"run_id": _run_id})
	ok = await _poll(20.0, func() -> bool: return _valid_signal("horde_cleanup_start.json"))
	_check("收到怪物资源收尾阶段", ok)
	if not ok:
		return
	ok = await _poll(12.0, func() -> bool: return zombies.get_child_count() == 0)
	_check("客户端压力怪物副本清空", ok, "zombies=%d" % zombies.get_child_count())
	if ok:
		_write_json("cleanup_seen_client_%d.json" % _index, {"run_id": _run_id})
	ok = await _poll(25.0, func() -> bool: return _valid_signal("horde_finish.json"))
	_check("服务器完成 8 人 100 怪专项", ok)
