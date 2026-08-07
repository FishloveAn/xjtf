extends "res://tools/debug_lan_sim.gd"
## 在既有双实例验收路径上读取 ENet 主机累计字节/包数，不修改联机测试逻辑。

var _net_first_usec := 0
var _net_last_usec := 0
var _sent_bytes := 0
var _received_bytes := 0
var _sent_packets := 0
var _received_packets := 0
var _sampling := true


func _initialize() -> void:
	super._initialize()
	call_deferred("_sample_network_loop")


func _run() -> void:
	if _mode != "perf_stress":
		await super._run()
		return
	if _role == "server":
		await _server_perf_stress()
	else:
		await _client_perf_stress()
	_summary()
	_sampling = false
	await create_timer(0.2).timeout
	if _nm != null:
		_nm.disconnect_from_server()
	change_scene_to_file(MAIN_MENU_SCENE)
	await create_timer(0.8).timeout
	quit(1 if _fail > 0 else 0)


func _sample_network_loop() -> void:
	while _sampling:
		await create_timer(0.1).timeout
		if _nm == null:
			continue
		var peer := _nm.multiplayer.multiplayer_peer as ENetMultiplayerPeer
		if peer == null:
			continue
		var host := peer.get_host()
		if host == null:
			continue
		var now_usec := Time.get_ticks_usec()
		if _net_first_usec == 0:
			_net_first_usec = now_usec
		_net_last_usec = now_usec
		# pop_statistic 返回并清零 ENet 自上次读取后的主机累计量，因此逐次累加。
		_sent_bytes += int(host.pop_statistic(ENetConnection.HOST_TOTAL_SENT_DATA))
		_received_bytes += int(host.pop_statistic(ENetConnection.HOST_TOTAL_RECEIVED_DATA))
		_sent_packets += int(host.pop_statistic(ENetConnection.HOST_TOTAL_SENT_PACKETS))
		_received_packets += int(host.pop_statistic(ENetConnection.HOST_TOTAL_RECEIVED_PACKETS))


func _server_perf_stress() -> void:
	var deadline := Time.get_ticks_msec() + 60000
	var err: int = _nm.create_host(PORT)
	_check("性能压测建房", err == OK, "err=%d" % err)
	if err != OK:
		return
	var ok := await _poll(deadline, 15.0, func() -> bool: return not _nm.multiplayer.get_peers().is_empty())
	_check("性能压测客户端接入", ok)
	if not ok:
		return
	_client_peer = int(_nm.multiplayer.get_peers()[0])
	_main = await _enter_main_scene()
	_ensure_refs()
	_write_marker("perf_stress_server_ready")
	ok = await _poll(deadline, 20.0, func() -> bool: return _has_marker("perf_stress_client_ready"))
	_check("性能压测两端场景就绪", ok)
	if not ok:
		return
	var wm := _main.get_node_or_null("Gameplay/WaveManager")
	wm._waves[2] = {
		"id": "network_perf_100", "name": "网络性能100",
		"composition": {"common": 100}, "concurrent_cap": 100,
		"spawn_style": "burst", "spawn_interval": 0.01,
		"cleared_when": {"type": "all_spawned_killed"},
		"reward": {"health_packs": 0, "ammo": 0},
	}
	wm._begin_wave(2)
	wm.set("_setup_timer", 0.05)
	ok = await _poll(deadline, 20.0, func() -> bool: return _zombies.get_child_count() == 100)
	_check("服务器100怪在场", ok, "count=%d" % _zombies.get_child_count())
	ok = await _poll(deadline, 20.0, func() -> bool: return _has_marker("perf_stress_client_100"))
	_check("客户端100怪复制完成", ok)
	_reset_measurement_window()
	_write_marker("perf_stress_measure")
	await create_timer(10.0).timeout
	_write_marker("perf_stress_done")


func _client_perf_stress() -> void:
	_remove_marker("perf_stress_server_ready")
	_remove_marker("perf_stress_client_ready")
	_remove_marker("perf_stress_client_100")
	_remove_marker("perf_stress_measure")
	_remove_marker("perf_stress_done")
	var deadline := Time.get_ticks_msec() + 60000
	var err: int = _nm.join_game(SERVER_IP, PORT)
	_check("性能压测加入", err == OK, "err=%d" % err)
	if err != OK:
		return
	var ok := await _poll(deadline, 15.0, func() -> bool: return _has_marker("perf_stress_server_ready"))
	_check("性能压测服务器场景就绪", ok)
	if not ok:
		return
	_main = await _enter_main_scene()
	_ensure_refs()
	_write_marker("perf_stress_client_ready")
	ok = await _poll(deadline, 25.0, func() -> bool: return _zombies.get_child_count() == 100)
	_check("客户端100怪在场", ok, "count=%d" % _zombies.get_child_count())
	_write_marker("perf_stress_client_100")
	ok = await _poll(deadline, 10.0, func() -> bool: return _has_marker("perf_stress_measure"))
	if ok:
		_reset_measurement_window()
	ok = await _poll(deadline, 15.0, func() -> bool: return _has_marker("perf_stress_done"))
	_check("100怪稳态采样10秒", ok)


func _reset_measurement_window() -> void:
	_sent_bytes = 0
	_received_bytes = 0
	_sent_packets = 0
	_received_packets = 0
	_net_first_usec = Time.get_ticks_usec()
	_net_last_usec = _net_first_usec


func _summary() -> void:
	super._summary()
	var seconds := float(_net_last_usec - _net_first_usec) / 1000000.0 if _net_last_usec > _net_first_usec else 0.0
	var report := {
		"role": _role,
		"mode": _mode,
		"sample_seconds": seconds,
		"sent_bytes": _sent_bytes,
		"received_bytes": _received_bytes,
		"sent_packets": _sent_packets,
		"received_packets": _received_packets,
		"sent_bytes_per_second": float(_sent_bytes) / seconds if seconds > 0.0 else 0.0,
		"received_bytes_per_second": float(_received_bytes) / seconds if seconds > 0.0 else 0.0,
	}
	var output_path := "user://perf_network_%s_%s.json" % [_role, _mode]
	var file := FileAccess.open(output_path, FileAccess.WRITE)
	file.store_string(JSON.stringify(report, "  "))
	file.close()
	print("[NET_PERF_JSON] " + JSON.stringify(report))
	print("[NET_PERF] 已写入 %s" % ProjectSettings.globalize_path(output_path))
