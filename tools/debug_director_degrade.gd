extends SceneTree
## Director degrade 回归：启用时应把波次同屏上限裁剪到 director.json.max_concurrent。

const MAIN_SCENE := "res://scenes/main/main.tscn"
const CONFIGURED_CAP := 100

var _fail := 0


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	print("=== DIRECTOR DEGRADE TEST START ===")
	change_scene_to_file(MAIN_SCENE)
	await create_timer(1.0).timeout
	var main := current_scene
	var wm := main.get_node_or_null("Gameplay/WaveManager")
	var director: Node = wm.get("_director") as Node if wm != null else null
	_check(wm != null and director != null, "真实主场景 WaveManager/Director 就绪")
	if wm == null or director == null:
		_finish()
		return
	root.get_node("SfxPool").set("_events", {})
	_check(bool(director.get("_degrade_enabled")), "director.json degrade.enabled=true 已读取")
	_check(int(director.get("_degrade_max_concurrent")) == CONFIGURED_CAP,
		"director.json degrade.max_concurrent=100 已读取")
	director.set("_specials_threshold", 0.0)
	director.set("_specials_cooldown_s", 0.0)
	director.set("_specials_max_simultaneous", 5)
	var cfg := {
		"id": "degrade_enabled", "name": "降级启用",
		"composition": {"common": 100, "charger": 10, "spitter": 10},
		"concurrent_cap": 120,
		"spawn_style": "burst", "spawn_interval": 0.0,
		"reward": {"health_packs": 0, "ammo": 0},
	}
	_check(wm.call("start_wave_config", cfg), "启动波次上限 120 的普通怪+特感真实 burst 波")
	wm.set("_setup_timer", 0.0)
	var max_concurrent := await _observe_peak(wm, 4.0)
	_check(max_concurrent == CONFIGURED_CAP,
		"启用 degrade 后总同屏峰值被 max_concurrent=100 限制（实际=%d）" % max_concurrent)
	await _kill_until_cleared(wm, main.get_node("Zombies"), 8.0)
	wm.set("_current_wave", {"concurrent_cap": 120})
	director.set("_degrade_enabled", false)
	director.set("_degrade_max_concurrent", 0)
	_check(int(wm.call("_concurrent_cap")) == 120, "degrade.disabled 时完全不干预波次上限")
	director.set("_degrade_enabled", true)
	_check(int(wm.call("_concurrent_cap")) == 1,
		"degrade.enabled 且 max_concurrent 非正数时安全限制为 1")
	_finish()


func _observe_peak(wm: Node, seconds: float) -> int:
	var peak := 0
	var elapsed := 0.0
	while elapsed < seconds:
		await create_timer(0.05).timeout
		elapsed += 0.05
		peak = maxi(peak, int(wm.get("_concurrent_count")))
	return peak


func _kill_until_cleared(wm: Node, zombies: Node, seconds: float) -> void:
	var elapsed := 0.0
	while elapsed < seconds and int(wm.get("state")) != 5:
		for zombie in zombies.get_children():
			var health := zombie.get_node_or_null("Health")
			if health != null and float(health.get("hp")) > 0.0:
				health.call("take_damage", 9999.0)
		await create_timer(0.05).timeout
		elapsed += 0.05


func _check(condition: bool, label: String) -> void:
	if condition:
		print("  [PASS] " + label)
	else:
		_fail += 1
		print("  [FAIL] " + label)


func _finish() -> void:
	print("=== DIRECTOR DEGRADE TEST %s (fail=%d) ===" % ["PASS" if _fail == 0 else "FAIL", _fail])
	change_scene_to_file("res://scenes/ui/main_menu.tscn")
	await create_timer(0.5).timeout
	quit(_fail)
