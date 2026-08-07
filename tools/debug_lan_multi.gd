extends SceneTree
## 4--8 人本机 headless 联机测量端。仅经游戏公开联机入口建房/加入，
## 结果和跨进程信号全部写入本轮独占目录，避免旧 marker 串场。

const MAIN_SCENE := "res://scenes/main/main.tscn"
const MAIN_MENU_SCENE := "res://scenes/ui/main_menu.tscn"
const SERVER_ID := 1
const TOTAL_TIMEOUT_MSEC := 75000

var _role := "server"
var _index := 0
var _count := 4
var _port := 0
var _run_id := ""
var _run_dir := ""
var _nm: Node
var _main: Node
var _pass := 0
var _fail := 0
var _started_msec := 0
var _sent_bytes := 0
var _received_bytes := 0
var _sent_packets := 0
var _received_packets := 0
var _sampling := true
var _connected := false
var _snapshot: Dictionary = {}


func _initialize() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg == "--server":
			_role = "server"
		elif arg == "--client":
			_role = "client"
		elif arg.begins_with("--index="):
			_index = int(arg.trim_prefix("--index="))
		elif arg.begins_with("--count="):
			_count = int(arg.trim_prefix("--count="))
		elif arg.begins_with("--port="):
			_port = int(arg.trim_prefix("--port="))
		elif arg.begins_with("--run-id="):
			_run_id = arg.trim_prefix("--run-id=")
		elif arg.begins_with("--run-dir="):
			_run_dir = arg.trim_prefix("--run-dir=")
	_started_msec = Time.get_ticks_msec()
	_nm = root.get_node_or_null("NetworkManager")
	if _nm == null or _run_id.is_empty() or _run_dir.is_empty() or _port <= 0 or _count < 2 or _count > 8:
		printerr("[LAN_MULTI][FATAL] 参数或 NetworkManager 无效")
		quit(2)
		return
	call_deferred("_run")
	call_deferred("_sample_network")


func _run() -> void:
	print("[LAN_MULTI] START run_id=%s role=%s index=%d count=%d port=%d" % [_run_id, _role, _index, _count, _port])
	if _role == "server":
		await _run_server()
	else:
		await _run_client()
	_sampling = false
	_write_json("exit_ready_%s_%d.json" % [_role, _index], {"run_id": _run_id})
	var exit_ready := await _poll(12.0, func() -> bool: return _file_count("exit_ready_") == _count)
	_check("全部进程抵达退出屏障", exit_ready, "ready=%d/%d" % [_file_count("exit_ready_"), _count])
	if _role == "server" and exit_ready:
		_write_json("exit_go.json", {
			"run_id": _run_id,
			"unix_msec": int(Time.get_unix_time_from_system() * 1000.0) + 1200,
		})
	var exit_go := await _poll(4.0, func() -> bool: return _valid_signal("exit_go.json"))
	_check("收到同步退出信号", exit_go)
	if exit_go:
		var quit_at := int(_read_json("exit_go.json").get("unix_msec", 0))
		while int(Time.get_unix_time_from_system() * 1000.0) < quit_at:
			await create_timer(0.05).timeout
	_write_result()
	await _shutdown_after_result()
	quit(1 if _fail > 0 else 0)


func _shutdown_after_result() -> void:
	# 客户端先停止轮询并释放本地复制场景，但保持 ENet peer 存活；服务器确认所有客户端
	# 场景已释放后，才在有效 channel 上释放自己的 Spawner，最后拆 peer。这样不会出现
	# 一端 channels=0、另一端仍在发 despawn 的退出竞态。
	if _main != null and is_instance_valid(_main):
		_main.process_mode = Node.PROCESS_MODE_DISABLED
	if _role == "client":
		multiplayer_poll = false
		if _main != null and is_instance_valid(_main):
			_main.queue_free()
			await process_frame
			await process_frame
			await process_frame
		_main = null
		_write_json("client_scene_freed_%d.json" % _index, {"run_id": _run_id})
		var server_closed := await _poll(8.0, func() -> bool: return _valid_signal("server_peer_closed.json"))
		_check("服务器完成有序网络关闭", server_closed)
		if _nm != null:
			_nm.disconnect_from_server()
		return

	var clients_freed := await _poll(8.0, func() -> bool: return _file_count("client_scene_freed_") == _count - 1)
	_check("全部客户端先释放复制场景", clients_freed,
		"freed=%d/%d" % [_file_count("client_scene_freed_"), _count - 1])
	multiplayer_poll = false
	if _main != null and is_instance_valid(_main):
		_main.queue_free()
		await process_frame
		await process_frame
		await process_frame
	_main = null
	if _nm != null:
		_nm.disconnect_from_server()
	_write_json("server_peer_closed.json", {"run_id": _run_id})


func _run_server() -> void:
	var err: int = _nm.create_host(_port, _count)
	_check("动态隔离端口建房", err == OK, "err=%d" % err)
	if err != OK:
		return
	var ok := await _poll(20.0, func() -> bool: return _nm.multiplayer.get_peers().size() == _count - 1)
	_check("全部客户端接入", ok, "peers=%s" % _nm.multiplayer.get_peers())
	if not ok:
		return
	await _enter_main()
	_write_json("server_scene.json", {"run_id": _run_id})
	await _verify_players_and_snapshot()
	if _fail > 0:
		return
	ok = await _poll(20.0, func() -> bool: return _file_count("snapshot_") == _count)
	_check("收齐全部观察者出生快照", ok, "snapshots=%d/%d" % [_file_count("snapshot_"), _count])
	if not ok:
		return
	_write_json("move_go.json", {"run_id": _run_id})
	await _verify_movement_observation()
	ok = await _poll(15.0, func() -> bool: return _file_count("move_seen_") == _count)
	_check("全部观察者看到位移", ok, "seen=%d/%d" % [_file_count("move_seen_"), _count])
	_write_json("finish.json", {"run_id": _run_id, "ok": ok})


func _run_client() -> void:
	_nm.connected_to_server.connect(func() -> void: _connected = true)
	var err: int = _nm.join_game("127.0.0.1", _port)
	_check("发起加入", err == OK, "err=%d" % err)
	if err != OK:
		return
	var ok := await _poll(15.0, func() -> bool: return _connected)
	_check("连接主机", ok)
	if not ok:
		return
	ok = await _poll(20.0, func() -> bool: return _valid_signal("server_scene.json"))
	_check("主机已进入主场景", ok)
	if not ok:
		return
	await _enter_main()
	await _verify_players_and_snapshot()
	if _fail > 0:
		return
	ok = await _poll(20.0, func() -> bool: return _file_count("snapshot_") == _count)
	_check("收齐全部出生快照", ok, "snapshots=%d/%d" % [_file_count("snapshot_"), _count])
	if not ok:
		return
	var server_snapshot := _read_json("snapshot_server_0.json").get("players", {}) as Dictionary
	_check("出生槽映射与主机一致", _snapshot_signature(_snapshot) == _snapshot_signature(server_snapshot))
	ok = await _poll(15.0, func() -> bool: return _valid_signal("move_go.json"))
	_check("收到位移阶段信号", ok)
	if not ok:
		return
	if _index == 1:
		var me := _find_player(_nm.multiplayer.get_unique_id())
		if me != null:
			# 出生槽沿 Z 轴间隔 1.2m；沿 X 移动可避免测试目标撞上相邻玩家。
			var target := me.global_position + Vector3(0.75, 0.0, 0.0)
			me.global_position = target
			_write_json("move_target.json", {
				"run_id": _run_id, "peer_id": _nm.multiplayer.get_unique_id(),
				"x": target.x, "z": target.z,
			})
	await _verify_movement_observation()
	ok = await _poll(20.0, func() -> bool: return _valid_signal("finish.json"))
	_check("主机完成本轮", ok)


func _enter_main() -> void:
	change_scene_to_file(MAIN_SCENE)
	await create_timer(2.0).timeout
	_main = current_scene


func _verify_players_and_snapshot() -> void:
	var ok := await _poll(20.0, func() -> bool: return get_nodes_in_group("players").size() == _count)
	_check("本端看到全部玩家", ok, "players=%d/%d" % [get_nodes_in_group("players").size(), _count])
	if not ok:
		return
	_snapshot = {}
	var slots: Dictionary = {}
	for node in get_nodes_in_group("players"):
		var player := node as Node3D
		var peer_id := player.get_multiplayer_authority()
		var slot := _position_key(player.global_position)
		_snapshot[str(peer_id)] = slot
		slots[slot] = true
	_check("玩家 peer 唯一", _snapshot.size() == _count, "unique=%d" % _snapshot.size())
	_check("出生槽唯一", slots.size() == _count, "unique_slots=%d/%d" % [slots.size(), _count])
	_write_json("snapshot_%s_%d.json" % [_role, _index], {
		"run_id": _run_id, "role": _role, "index": _index, "players": _snapshot,
	})


func _verify_movement_observation() -> void:
	var ok := await _poll(15.0, func() -> bool: return _valid_signal("move_target.json"))
	_check("位移目标已发布", ok)
	if not ok:
		return
	var target := _read_json("move_target.json")
	var peer_id := int(target.get("peer_id", 0))
	var player := _find_player(peer_id)
	ok = await _poll(10.0, func() -> bool:
		player = _find_player(peer_id)
		if player == null:
			return false
		var dx := player.global_position.x - float(target.get("x", 0.0))
		var dz := player.global_position.z - float(target.get("z", 0.0))
		return Vector2(dx, dz).length() < 0.35)
	_check("观察到客户端权威位移", ok, "peer=%d pos=%s" % [peer_id, player.global_position if player != null else "null"])
	if ok:
		_write_json("move_seen_%s_%d.json" % [_role, _index], {"run_id": _run_id, "peer_id": peer_id})


func _find_player(peer_id: int) -> Node3D:
	for node in get_nodes_in_group("players"):
		if node.get_multiplayer_authority() == peer_id:
			return node as Node3D
	return null


func _position_key(position: Vector3) -> String:
	return "%.1f,%.1f,%.1f" % [position.x, position.y, position.z]


func _snapshot_signature(snapshot: Dictionary) -> String:
	var keys := snapshot.keys()
	keys.sort()
	var parts: PackedStringArray = []
	for key in keys:
		parts.append("%s=%s" % [key, snapshot[key]])
	return "|".join(parts)


func _poll(seconds: float, condition: Callable) -> bool:
	var until := mini(Time.get_ticks_msec() + int(seconds * 1000.0), _started_msec + TOTAL_TIMEOUT_MSEC)
	while Time.get_ticks_msec() < until:
		if condition.call():
			return true
		await create_timer(0.15).timeout
	return false


func _check(label: String, ok: bool, detail: String = "") -> void:
	if ok:
		_pass += 1
		print("[LAN_MULTI][PASS] %s%s" % [label, "  " + detail if not detail.is_empty() else ""])
	else:
		_fail += 1
		printerr("[LAN_MULTI][FAIL] %s%s" % [label, "  " + detail if not detail.is_empty() else ""])


func _path(name: String) -> String:
	return _run_dir.path_join(name)


func _write_json(name: String, value: Dictionary) -> void:
	var file := FileAccess.open(_path(name), FileAccess.WRITE)
	if file == null:
		_check("写入协议文件 " + name, false, "error=%d" % FileAccess.get_open_error())
		return
	file.store_string(JSON.stringify(value))
	file.close()


func _read_json(name: String) -> Dictionary:
	if not FileAccess.file_exists(_path(name)):
		return {}
	var file := FileAccess.open(_path(name), FileAccess.READ)
	if file == null:
		return {}
	var parsed = JSON.parse_string(file.get_as_text())
	file.close()
	return parsed as Dictionary if parsed is Dictionary else {}


func _valid_signal(name: String) -> bool:
	return String(_read_json(name).get("run_id", "")) == _run_id


func _file_count(prefix: String) -> int:
	var directory := DirAccess.open(_run_dir)
	if directory == null:
		return 0
	var count := 0
	for name in directory.get_files():
		if name.begins_with(prefix) and name.ends_with(".json") and _valid_signal(name):
			count += 1
	return count


func _sample_network() -> void:
	while _sampling:
		await create_timer(0.2).timeout
		if _nm == null:
			continue
		var peer := _nm.multiplayer.multiplayer_peer as ENetMultiplayerPeer
		if peer == null or peer.get_host() == null:
			continue
		var host := peer.get_host()
		_sent_bytes += int(host.pop_statistic(ENetConnection.HOST_TOTAL_SENT_DATA))
		_received_bytes += int(host.pop_statistic(ENetConnection.HOST_TOTAL_RECEIVED_DATA))
		_sent_packets += int(host.pop_statistic(ENetConnection.HOST_TOTAL_SENT_PACKETS))
		_received_packets += int(host.pop_statistic(ENetConnection.HOST_TOTAL_RECEIVED_PACKETS))


func _write_result() -> void:
	var elapsed := maxf(float(Time.get_ticks_msec() - _started_msec) / 1000.0, 0.001)
	var result := {
		"run_id": _run_id, "role": _role, "index": _index, "player_count": _count,
		"pass_count": _pass, "fail_count": _fail, "elapsed_seconds": elapsed,
		"snapshot": _snapshot, "sent_bytes": _sent_bytes, "received_bytes": _received_bytes,
		"sent_packets": _sent_packets, "received_packets": _received_packets,
		"sent_bytes_per_second": float(_sent_bytes) / elapsed,
		"received_bytes_per_second": float(_received_bytes) / elapsed,
	}
	_write_json("result_%s_%d.json" % [_role, _index], result)
	print("[LAN_MULTI] RESULT " + JSON.stringify(result))
