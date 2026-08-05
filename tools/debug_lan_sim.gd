extends "res://tools/lan_sim_base.gd"
## debug_lan_sim.gd — M2-S5 联机验收 headless 双实例模拟（B 组核心 + M2 波次/物资/救援同步）
## 用法（两个进程，先 server 后 client）：
##   A：godot --headless --path . --script tools/debug_lan_sim.gd -- --server --mode=main
##   B：godot --headless --path . --script tools/debug_lan_sim.gd -- --client --mode=main
##   （B7 断线轮跑 --mode=disconnect：server 侧等 client 退出验证清理）
## 验证：B1 建房 / B2 加入 / B3 列表 / B4 同进主场景 / B5 互见 / B6 位移同步（注入）/
##       B7 断线清理不崩 / B8 主机退出回主菜单 / B9 端口冲突；M2：波次广播、ZombieSpawner
##       复制丧尸 + 回池移除同步、补给点拾取广播两端一致、伤害 D2 / 救援 D3 数据一致
## 关键时序：server 等客户端接入后再进主场景（模拟真机"两端同步切场景"，防 Spawner
##           复制包先于客户端场景到达被丢弃）；headless ENet 客户端 peer id 非固定 2，动态取
## 跨进程协调：user:// 共享标记文件（lan_sim_client_done_<mode>.marker）

var _role := "server"   # server / client
var _mode := "main"     # main / disconnect


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	for a in args:
		if a == "--server":
			_role = "server"
		elif a == "--client":
			_role = "client"
		elif a.begins_with("--mode="):
			_mode = a.trim_prefix("--mode=")
	_nm = root.get_node_or_null("NetworkManager")
	if _nm == null:
		printerr("[SIM] NetworkManager autoload 未找到")
		quit(2)
		return
	# client 启动时清理自己可能残留的标记（防上次中断误判）
	if _role == "client":
		_remove_marker("lan_sim_client_done_%s" % _mode)
		_remove_marker("lan_sim_client_ready_%s" % _mode)
		_remove_marker("lan_sim_b6_ready")
		_remove_marker("lan_sim_client_b8_done")
	call_deferred("_run")


func _run() -> void:
	print("[SIM] === LAN_SIM START role=%s mode=%s ===" % [_role, _mode])
	var deadline := Time.get_ticks_msec() + int(MAX_TOTAL_SEC * 1000.0)
	if _mode == "main":
		if _role == "server":
			await _server_main(deadline)
		else:
			await _client_main(deadline)
	else:
		if _role == "server":
			await _server_disconnect(deadline)
		else:
			await _client_disconnect(deadline)
	_summary()
	change_scene_to_file(MAIN_MENU_SCENE)  # 释放主场景防对象泄漏（与 debug_wave_flow 一致）
	await create_timer(0.6).timeout
	quit(1 if _fail > 0 else 0)


# --- 服务器：主验证轮（B1-B6/B9 + M2 波次/物资/伤害/救援） ---

func _server_main(deadline: int) -> void:
	var err: int = _nm.create_host(PORT)
	_check("B1 建房 create_host(5555)", err == OK, "err=%d" % err)
	if err != OK:
		return
	# 等客户端接入且主场景就绪后再进主场景（真机同时切场景时序：
	# 客户端场景先就绪，服务器 spawn 的复制包才不丢）
	var ok := await _poll(deadline, 15.0, func() -> bool: return not _nm.multiplayer.get_peers().is_empty())
	_check("B2 客户端接入(peers 非空)", ok, "peers=%s" % _nm.multiplayer.get_peers())
	if not ok:
		return
	_client_peer = int(_nm.multiplayer.get_peers()[0])
	print("[SIM] INFO client_peer=%d" % _client_peer)
	ok = await _poll(deadline, 20.0, func() -> bool: return _has_marker("lan_sim_client_ready_%s" % _mode))
	_check("B2 客户端主场景就绪(标记)", ok)
	_main = await _enter_main_scene()
	await create_timer(1.0).timeout  # main.gd 0.5s 宽限后玩家 1 生成
	_ensure_refs()
	ok = await _poll(deadline, 15.0, func() -> bool: return _find_player(_client_peer) != null)
	var p2: Node3D = _find_player(_client_peer)
	_check("B3 加入列表/客户端玩家出现", ok, "client_peer=%d" % _client_peer)
	_check("B4 双人同进主场景", ok and _find_player(1) != null and p2 != null)
	_check("B5 服务器看到客户端玩家", p2 != null)
	if p2 == null:
		return
	_write_marker("lan_sim_b6_ready")  # 通知客户端：服务器已就绪，可注入位移
	# B6：等 client 注入位移 → 服务器观察到（客户端权威位移 20Hz 上报）
	var p2_init: Vector3 = p2.global_position
	ok = await _poll(deadline, 10.0, func() -> bool:
		return p2.global_position.distance_to(p2_init) > 1.0)
	_check("B6 客户端位移同步到服务器", ok, "init=%s now=%s" % [p2_init, p2.global_position])
	# B9：端口被占用 → 再建房应失败
	err = _nm.create_host(PORT)
	_check("B9 端口占用建房失败", err != OK, "err=%d" % err)
	# M2 波次：跳过 Setup 倒计时直接开波（authority 广播 → 客户端收到 wave_begun）
	var wm := _main.get_node_or_null("Gameplay/WaveManager")
	if wm != null:
		wm.call("_enter_wave_active")
		wm.set("_spawn_timer", 0.0)  # 注入首只立即刷（正常刷怪路径，只缩短计时）
		await create_timer(0.2).timeout
		wm.set("_spawn_timer", 0.0)
		await create_timer(0.2).timeout
		wm.set("_spawn_timer", 0.0)
	ok = await _poll(deadline, 8.0, func() -> bool: return _zombies.get_child_count() >= 3)
	_check("M2 服务器刷出丧尸(≥3)", ok, "count=%d" % _zombies.get_child_count())
	# M2 丧尸死亡 → 回池移除（服务器端子节点回落）
	var z_before := _zombies.get_child_count()
	if z_before > 0:
		var zh := _zombies.get_child(0).get_node_or_null("Health")
		if zh != null:
			zh.take_damage(9999.0)
	ok = await _poll(deadline, 6.0, func() -> bool: return _zombies.get_child_count() == z_before - 1)
	_check("M2 丧尸死亡回池(子节点回落)", ok, "before=%d now=%d" % [z_before, _zombies.get_child_count()])
	# 清空剩余丧尸 + 停止波次刷怪：避免服务器侧 AI 追击玩家打乱后续补给/伤害/救援验证
	for z in _zombies.get_children():
		var zh := z.get_node_or_null("Health")
		if zh != null:
			zh.take_damage(9999.0)
	if wm != null:
		wm.set_process(false)
	await create_timer(1.5).timeout  # 等死亡表现/回池完成
	# M2 补给点：F1 静态点存在 → 弹药/医疗拾取结算（F2/F4），消失广播（F3，客户端观察）
	var p1 := _find_player(1)
	var ammo := _find_supply(0)
	var med := _find_supply(1)
	_check("F1 静态补给点存在", ammo != null and med != null)
	if p1 != null and ammo != null and med != null:
		# 注入初始状态：清怪前残留丧尸可能已攻击玩家，先复位保证结算断言确定
		var p1state := p1.get_node_or_null("Health")
		p1state.hp = 100.0
		p1state.state = 0
		var pistol := p1.get_node_or_null("WeaponPivot/Pistol")
		pistol.mag_current = pistol.mag_size - 5
		p1.global_position = ammo.global_position
		ammo.request_pickup()
		await create_timer(0.1).timeout
		_check("F2a 弹药补给补满弹匣", pistol.mag_current == pistol.mag_size,
			"mag=%d/%d" % [pistol.mag_current, pistol.mag_size])
		p1state.take_damage(80.0)  # 100→20
		p1.global_position = med.global_position
		med.request_pickup()
		await create_timer(0.1).timeout
		_check("F2b 医疗补给 +50HP", p1state.hp == 70.0, "hp=%.0f" % p1state.hp)
		_check("F3 补给点拾取后消失(服务器)", not is_instance_valid(ammo) and not is_instance_valid(med))
	# M2 伤害 D2：服务器对客户端玩家结算，客户端经 HealthSync 同步（client 侧观察）
	var p2state := p2.get_node_or_null("Health")
	if p2state != null:
		p2state.hp = 100.0  # 复位（同上：防残留丧尸攻击影响断言）
		p2state.state = 0
		p2state.take_damage(30.0)  # 100→70
		ok = await _poll(deadline, 3.0, func() -> bool: return p2state.hp == 70.0)
		_check("D2 伤害服务器结算", ok, "hp=%.0f" % p2state.hp)
		await create_timer(2.0).timeout  # 给客户端 HealthSync 观察 hp=70 的窗口
	# M2 救援 D3：客户端玩家倒地 → 玩家 1 靠近救援 → 3s 复活 hp50（client 侧观察同步）
	if p2state != null and p1 != null:
		p2state.take_damage(100.0)  # 70→0 DOWN
		await create_timer(0.3).timeout
		p1.global_position = p2.global_position
		var p1state := p1.get_node_or_null("Health")
		p2state.try_start_revive(p1state)
		ok = await _poll(deadline, 7.0, func() -> bool: return p2state.hp == 50.0 and p2state.state == 0)
		_check("D3 救援复活 hp50", ok, "hp=%.0f state=%d" % [p2state.hp, p2state.state])
	# 等 client 完成全部验证（标记文件）→ 然后断开触发 client 的 B8
	ok = await _poll(deadline, 30.0, func() -> bool: return _has_marker("lan_sim_client_done_main"))
	_check("跨端协调 client 验证完成", ok)
	# 模拟主机退出：断开会话并保持进程运行，让客户端收到 server_disconnected（B8）。
	# 不显式 close ENet peer（实测 close 会卡住主循环）；SceneMultiplayer 置 null 后
	# 客户端按 ENet 超时检测到断开。等客户端 B8 完成后本进程才正常退出
	_nm.disconnect_from_server()
	await _poll(deadline, 20.0, func() -> bool: return _has_marker("lan_sim_client_b8_done"))


# --- 客户端：主验证轮（B2/B4/B5/B6 + M2 同步观察 + B8） ---

func _client_main(deadline: int) -> void:
	_got_conn = false
	_nm.connected_to_server.connect(func() -> void: _got_conn = true)
	var err: int = _nm.join_game(SERVER_IP, PORT)
	_check("B2 发起加入 join_game", err == OK, "err=%d" % err)
	if err != OK:
		return
	var ok := await _poll(deadline, 10.0, func() -> bool: return _got_conn)
	_check("B2 连接成功 connected_to_server", ok)
	if not ok:
		return
	_main = await _enter_main_scene()
	_ensure_refs()
	_write_marker("lan_sim_client_ready_%s" % _mode)  # 通知服务器：本端场景已就绪
	# 等服务器生成自己的玩家（_client_ready → 服务器 spawn）
	_me = null
	ok = await _poll(deadline, 10.0, func() -> bool:
		_me = _find_player(_nm.multiplayer.get_unique_id())
		return _me != null)
	_check("B4 玩家2生成(同进主场景)", ok)
	_check("B5 客户端看到玩家1", _find_player(1) != null)
	if _me == null:
		return
	# B6 注入位移：等服务器基准就绪（防注入同步先于服务器记录初始位置），本地立即生效
	var ok2 := await _poll(deadline, 10.0, func() -> bool: return _has_marker("lan_sim_b6_ready"))
	_check("B6 服务器基准就绪", ok2)
	var target := Vector3(0, 0, 8)
	_me.global_position = target
	_check("B6 注入位移本地生效", _me.global_position.distance_to(target) < 0.5)
	# M2 波次广播：收到 wave_begun（authority 广播链路）
	var wm := _main.get_node_or_null("Gameplay/WaveManager")
	_wave_begun = 0
	if wm != null:
		wm.event_wave_begun.connect(func(_i: int) -> void: _wave_begun += 1)
	ok = await _poll(deadline, 20.0, func() -> bool: return _wave_begun > 0)
	_check("M2 波次广播 wave_begun", ok)
	# M2 丧尸复制：ZombieSpawner 复制的副本（记录峰值，等回池后回落）
	_z_max = 0
	ok = await _poll(deadline, 25.0, func() -> bool:
		_z_max = maxi(_z_max, _zombies.get_child_count())
		return _zombies.get_child_count() > 0)
	_check("M2 客户端看到复制的丧尸", ok, "count=%d" % _zombies.get_child_count())
	ok = await _poll(deadline, 10.0, func() -> bool: return _zombies.get_child_count() < _z_max)
	_check("M2 丧尸回池后客户端副本移除", ok, "peak=%d now=%d" % [_z_max, _zombies.get_child_count()])
	# M2 补给两端一致：pickup_used 广播 → 所有端本地消失
	ok = await _poll(deadline, 15.0, func() -> bool: return _count_supplies() == 0)
	_check("M2 补给点拾取两端一致消失", ok, "remain=%d" % _count_supplies())
	# M2 伤害/救援同步（HealthSync 服务器权威 → 客户端 hp/state）
	var my_state := _me.get_node_or_null("Health")
	if my_state != null:
		ok = await _poll(deadline, 15.0, func() -> bool: return my_state.hp == 70.0)
		_check("D2 客户端血量同步(100→70)", ok, "hp=%.0f" % my_state.hp)
		ok = await _poll(deadline, 15.0, func() -> bool: return my_state.state == 1)
		_check("D3 客户端倒地状态同步", ok, "state=%d" % my_state.state)
		ok = await _poll(deadline, 12.0, func() -> bool: return my_state.state == 0 and my_state.hp == 50.0)
		_check("D3 客户端复活同步 hp50", ok, "hp=%.0f state=%d" % [my_state.hp, my_state.state])
	# 完成所有 M2/B 组验证 → 先通知服务器（服务器收到后断开，触发下方 B8）
	_write_marker("lan_sim_client_done_main")
	# B8：服务器退出 → server_disconnected → main.gd 回主菜单，不崩
	_got_disc = false
	_nm.server_disconnected.connect(func() -> void: _got_disc = true)
	ok = await _poll(deadline, 40.0, func() -> bool: return _got_disc)
	_check("B8 检测到主机退出", ok)
	ok = await _poll(deadline, 5.0, func() -> bool:
		return current_scene != null and current_scene.scene_file_path == MAIN_MENU_SCENE)
	_check("B8 客户端回主菜单不崩", ok, "scene=%s" % (current_scene.scene_file_path if current_scene != null else "null"))
	_write_marker("lan_sim_client_b8_done")  # 通知服务器：B8 完成，服务器可退出


# --- 断线轮：B7（客户端关窗 → 服务器清玩家不崩） ---

func _server_disconnect(deadline: int) -> void:
	var err: int = _nm.create_host(PORT)
	_check("B1 建房 create_host(5555)", err == OK, "err=%d" % err)
	if err != OK:
		return
	# 等客户端接入后同步进主场景（同 _server_main 时序）
	var ok := await _poll(deadline, 15.0, func() -> bool: return not _nm.multiplayer.get_peers().is_empty())
	if not ok:
		_check("B3/B5 客户端接入互见", false)
		return
	_client_peer = int(_nm.multiplayer.get_peers()[0])
	ok = await _poll(deadline, 20.0, func() -> bool: return _has_marker("lan_sim_client_ready_%s" % _mode))
	if not ok:
		_check("B3/B5 客户端接入互见", false)
		return
	_main = await _enter_main_scene()
	await create_timer(1.0).timeout
	_players = _main.get_node_or_null("Players") as Node3D
	ok = await _poll(deadline, 15.0, func() -> bool: return _find_player(_client_peer) != null)
	_check("B3/B5 客户端接入互见", ok)
	if not ok:
		return
	_got_disc = false
	_nm.peer_disconnected.connect(func(id: int) -> void:
		if id == _client_peer:
			_got_disc = true)
	ok = await _poll(deadline, 20.0, func() -> bool: return _got_disc)
	_check("B7 检测到客户端断线", ok)
	ok = await _poll(deadline, 4.0, func() -> bool: return _find_player(_client_peer) == null and _players.get_child_count() == 1)
	_check("B7 断线清理玩家不崩", ok, "players=%d" % _players.get_child_count())


func _client_disconnect(deadline: int) -> void:
	_got_conn = false
	_nm.connected_to_server.connect(func() -> void: _got_conn = true)
	var err: int = _nm.join_game(SERVER_IP, PORT)
	_check("B2 发起加入 join_game", err == OK, "err=%d" % err)
	if err != OK:
		return
	var ok := await _poll(deadline, 10.0, func() -> bool: return _got_conn)
	_check("B2 连接成功 connected_to_server", ok)
	if not ok:
		return
	_main = await _enter_main_scene()
	await create_timer(1.0).timeout
	_write_marker("lan_sim_client_ready_%s" % _mode)  # 通知服务器：本端场景已就绪
	ok = await _poll(deadline, 10.0, func() -> bool: return _find_player(_nm.multiplayer.get_unique_id()) != null)
	_check("B4 客户端进主场景", ok)
	_check("B5 客户端看到玩家1", _find_player(1) != null)
	_write_marker("lan_sim_client_done_disconnect")
	await create_timer(2.0).timeout  # 短暂停留后关窗（模拟 B 直接关闭窗口）
	print("[SIM][PASS] B7 客户端模拟关窗退出")
