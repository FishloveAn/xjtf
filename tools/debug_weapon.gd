extends SceneTree
# 临时仿真脚本（M3-S1）：headless 跑主场景，验证 4 把武器数据装载 + 自动连发逻辑。
# 用法：godot --headless --path . --script tools/debug_weapon.gd
# 验证：
#   D1 数据装载：WeaponPivot 下 4 把武器（pistol/shotgun/rifle/smg）参数与 data/weapons.json 一致
#   D2 自动连发：对 auto 武器注入按住左键（_fire_held）+ 每物理帧 _poll_auto_fire →
#                弹药按 fire_rate 下降（受服务器 _cooldown_timer 限速）
#   D3 半自动不连发：对非 auto 武器同样注入按住轮询 → 弹药不消耗（按一次打一发）
#   D4 打空自动换弹：auto 武器弹匣 1 发打空后再开火 → 进入 reloading
# 注意：--script 工具脚本不静态引用游戏类类型（M2-S3 铁律：编译期拉游戏类会失败），
#       武器/玩家状态全部动态访问 node.get("...") / node.set("...")

const MAIN_SCENE := "res://scenes/main/main.tscn"
const WEAPONS_JSON := "res://data/weapons.json"
const HOLD_SECONDS := 1.0
const SIM_FPS := 60.0

var _failures := 0


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	print("=== WEAPON_TEST START ===")
	change_scene_to_file(MAIN_SCENE)
	await create_timer(2.0).timeout
	var main := current_scene
	var players := main.get_node_or_null("Players") as Node3D
	if players == null or players.get_child_count() == 0:
		printerr("[weapon] no player found")
		quit(1)
		return
	var player := players.get_child(0) as Node3D
	var pivot := player.get_node_or_null("WeaponPivot") as Node3D
	if pivot == null:
		printerr("[weapon] no WeaponPivot")
		quit(1)
		return

	_verify_load(pivot)  # D1
	await _verify_auto_hold(player, "Rifle", 7.0)   # D2 步枪 7.0 发/秒
	await _verify_auto_hold(player, "SMG", 10.0)    # D2 冲锋枪 10.0 发/秒
	await _verify_semi_hold(player, "Pistol")       # D3 手枪单发
	await _verify_semi_hold(player, "Shotgun")      # D3 霰弹单发
	await _verify_empty_reload(player)              # D4 打空自动换弹

	print("=== WEAPON_TEST %s ===" % ("PASS" if _failures == 0 else "FAIL(%d)" % _failures))
	change_scene_to_file("res://scenes/ui/main_menu.tscn")
	await create_timer(0.8).timeout
	quit(0 if _failures == 0 else 1)


## D1：遍历 WeaponPivot 子节点，逐字段对照 data/weapons.json
func _verify_load(pivot: Node) -> void:
	var file := FileAccess.open(WEAPONS_JSON, FileAccess.READ)
	if file == null:
		_fail("cannot open " + WEAPONS_JSON)
		return
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	if not (parsed is Dictionary):
		_fail("weapons.json parse failed")
		return
	var entries := {}
	for w in (parsed as Dictionary).get("weapons", []):
		entries[(w as Dictionary).get("id", "")] = w
	var count := 0
	for child in pivot.get_children():
		var wid: String = child.get("weapon_id")
		if wid == "" or not (entries.has(wid)):
			continue
		count += 1
		var entry: Dictionary = entries[wid]
		_check(wid, "damage", child.get("damage"), entry.get("damage"))
		_check(wid, "fire_rate", child.get("fire_rate"), entry.get("fire_rate"))
		_check(wid, "mag_size", child.get("mag_size"), entry.get("mag_size"))
		_check(wid, "reload_time", child.get("reload_time"), entry.get("reload_time"))
		_check(wid, "spread_deg", child.get("spread_deg"), entry.get("spread_deg"))
		_check(wid, "range_m", child.get("range_m"), entry.get("range_m"))
		_check(wid, "auto", child.get("auto"), entry.get("auto"))
		_check(wid, "pellets", child.get("pellets"), entry.get("pellets", 1))
		print("[LOAD] %s name=%s damage=%s fire_rate=%s mag=%s reload=%s auto=%s pellets=%s" % [
			wid, child.get("display_name"), child.get("damage"), child.get("fire_rate"),
			child.get("mag_size"), child.get("reload_time"), child.get("auto"), child.get("pellets")])
	if count != 4:
		_fail("expected 4 weapons loaded, got %d" % count)
	else:
		print("[LOAD] 4 weapons loaded OK")


## D2：注入按住左键 + 连发轮询 HOLD_SECONDS 秒，弹药应只按 fire_rate 消耗
## 注：_poll_auto_fire 只对**当前激活武器**连发（切枪后按住开火才是真实 gameplay），
##     测试必须先切到目标武器再注入按住，否则激活的仍是 Pistol（auto=false）→ 目标 0 发
func _verify_auto_hold(player: Node, node_name: String, expect_rate: float) -> void:
	var weapon := player.get_node_or_null("WeaponPivot/" + node_name)
	if weapon == null:
		_fail("no weapon node " + node_name)
		return
	_activate_weapon(player, weapon)
	_reset_weapon(weapon)
	player.set("_fire_held", true)
	var start_mag: int = weapon.get("mag_current")
	var frames := int(HOLD_SECONDS * SIM_FPS)
	for i in frames:
		player._poll_auto_fire()
		await create_timer(1.0 / SIM_FPS).timeout
	player.set("_fire_held", false)
	var spent: int = start_mag - int(weapon.get("mag_current"))
	var expected: float = expect_rate * HOLD_SECONDS
	print("[AUTO] %s spent=%d in %.1fs rate=%.1f/s (expect ~%.1f/s)" % [
		node_name, spent, HOLD_SECONDS, spent / HOLD_SECONDS, expect_rate])
	if absf(float(spent) - expected) > 3.0:
		_fail("%s auto spent=%d, expect ~%.0f (fire_rate 限速失效?)" % [node_name, spent, expected])


## D3：半自动武器同样注入按住轮询 → 弹药不消耗（按一次打一发，控制器不对非 auto 连发）
func _verify_semi_hold(player: Node, node_name: String) -> void:
	var weapon := player.get_node_or_null("WeaponPivot/" + node_name)
	if weapon == null:
		_fail("no weapon node " + node_name)
		return
	_activate_weapon(player, weapon)
	_reset_weapon(weapon)
	player.set("_fire_held", true)
	var start_mag: int = weapon.get("mag_current")
	var frames := int(HOLD_SECONDS * SIM_FPS)
	for i in frames:
		player._poll_auto_fire()
		await create_timer(1.0 / SIM_FPS).timeout
	player.set("_fire_held", false)
	var spent: int = start_mag - int(weapon.get("mag_current"))
	print("[SEMI] %s spent=%d in %.1fs hold (expect 0: 半自动按一次打一发)" % [
		node_name, spent, HOLD_SECONDS])
	if spent != 0:
		_fail("%s semi-auto fired %d rounds while held (非 auto 不应连发)" % [node_name, spent])


## D4：auto 武器弹匣剩 1 发，打空后再开火 → 自动进入换弹
func _verify_empty_reload(player: Node) -> void:
	var weapon := player.get_node_or_null("WeaponPivot/Rifle")
	if weapon == null:
		_fail("no weapon node Rifle")
		return
	_reset_weapon(weapon)
	weapon.set("mag_current", 1)
	weapon.try_fire()  # 打出最后一发
	weapon.try_fire()  # 弹匣空 → _server_fire 走 _server_start_reload
	var reloading: bool = weapon.get("reloading")
	var mag: int = weapon.get("mag_current")
	print("[RELOAD] mag=%d reloading=%s (expect 0/true)" % [mag, reloading])
	if mag != 0 or not reloading:
		_fail("auto reload on empty mag failed mag=%d reloading=%s" % [mag, reloading])


## 切到指定武器（补齐注入前的激活步骤：_poll_auto_fire 只对当前激活武器连发）
func _activate_weapon(player: Node, weapon: Node) -> void:
	var weapons: Array = player.get("_weapons")
	for i in weapons.size():
		if weapons[i] == weapon:
			player._set_active_weapon(i)
			return


## 重置武器状态：补满弹匣、清除换弹与射速冷却（避免串测残留）
func _reset_weapon(weapon: Node) -> void:
	weapon.set("reloading", false)
	weapon.set("mag_current", int(weapon.get("mag_size")))
	weapon.set("_cooldown_timer", 0.0)


func _check(wid: String, field: String, got: Variant, want: Variant) -> void:
	var ok := false
	if got is float and want is float:
		ok = is_equal_approx(got, want)
	else:
		ok = got == want
	if not ok:
		_fail("%s.%s got=%s want=%s" % [wid, field, got, want])


func _fail(msg: String) -> void:
	_failures += 1
	printerr("[WEAPON] FAIL: " + msg)
