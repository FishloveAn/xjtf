extends SceneTree
## 可重复性能基线：同一脚本分别在 headless 与窗口模式运行，输出 JSON。

const MAIN_SCENE := "res://scenes/main/main.tscn"
const WAVE_MANAGER_PATH := "Gameplay/WaveManager"
const SAMPLE_SECONDS := 8.0
const TARGET_ZOMBIES := 100

var _samples: Array[Dictionary] = []


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	change_scene_to_file(MAIN_SCENE)
	await create_timer(2.0).timeout
	var main := current_scene
	var wm := main.get_node_or_null(WAVE_MANAGER_PATH)
	var zombies := main.get_node_or_null("Zombies")
	if wm == null or zombies == null:
		printerr("[PERF] 主场景测量节点缺失")
		quit(2)
		return
	wm._waves[2] = {
		"id": "perf_baseline_100", "name": "性能基线100",
		"composition": {"common": TARGET_ZOMBIES},
		"concurrent_cap": TARGET_ZOMBIES,
		"spawn_style": "burst", "spawn_interval": 0.05,
		"cleared_when": {"type": "all_spawned_killed"},
		"reward": {"health_packs": 0, "ammo": 0},
	}
	wm._begin_wave(2)
	wm.set("_setup_timer", 0.05)
	var deadline := Time.get_ticks_msec() + 20000
	while zombies.get_child_count() < TARGET_ZOMBIES and Time.get_ticks_msec() < deadline:
		await create_timer(0.1).timeout
	if zombies.get_child_count() != TARGET_ZOMBIES:
		printerr("[PERF] 100 怪生成超时，实际=%d" % zombies.get_child_count())
		quit(3)
		return
	await create_timer(1.0).timeout
	var started_usec := Time.get_ticks_usec()
	var physics_start := Engine.get_physics_frames()
	var last_usec := started_usec
	while Time.get_ticks_usec() - started_usec < int(SAMPLE_SECONDS * 1000000.0):
		await process_frame
		var now_usec := Time.get_ticks_usec()
		_samples.append({
			"frame_ms": float(now_usec - last_usec) / 1000.0,
			"process_ms": Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0,
			"physics_ms": Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0,
			"navigation_ms": Performance.get_monitor(Performance.TIME_NAVIGATION_PROCESS) * 1000.0,
			"draw_calls": Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME),
			"primitives": Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME),
			"render_objects": Performance.get_monitor(Performance.RENDER_TOTAL_OBJECTS_IN_FRAME),
			"video_mem": Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED),
			"texture_mem": Performance.get_monitor(Performance.RENDER_TEXTURE_MEM_USED),
			"buffer_mem": Performance.get_monitor(Performance.RENDER_BUFFER_MEM_USED),
		})
		last_usec = now_usec
	var elapsed_sec := float(Time.get_ticks_usec() - started_usec) / 1000000.0
	var report := {
		"timestamp": Time.get_datetime_string_from_system(true),
		"godot": Engine.get_version_info(),
		"os": OS.get_name(),
		"cpu": OS.get_processor_name(),
		"logical_cpu_count": OS.get_processor_count(),
		"headless": DisplayServer.get_name() == "headless",
		"display_server": DisplayServer.get_name(),
		"renderer": RenderingServer.get_current_rendering_method(),
		"rendering_device": RenderingServer.get_video_adapter_name(),
		"zombies": zombies.get_child_count(),
		"sample_seconds": elapsed_sec,
		"sample_frames": _samples.size(),
		"physics_ticks": Engine.get_physics_frames() - physics_start,
		"nodes": int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT)),
		"objects": int(Performance.get_monitor(Performance.OBJECT_COUNT)),
		"resources": int(Performance.get_monitor(Performance.OBJECT_RESOURCE_COUNT)),
		"orphan_nodes": int(Performance.get_monitor(Performance.OBJECT_ORPHAN_NODE_COUNT)),
		"static_memory_bytes": int(Performance.get_monitor(Performance.MEMORY_STATIC)),
		"static_memory_peak_bytes": int(Performance.get_monitor(Performance.MEMORY_STATIC_MAX)),
		"metrics": {
			"frame_ms": _stats("frame_ms"),
			"process_ms": _stats("process_ms"),
			"physics_ms": _stats("physics_ms"),
			"navigation_ms": _stats("navigation_ms"),
			"draw_calls": _stats("draw_calls"),
			"primitives": _stats("primitives"),
			"render_objects": _stats("render_objects"),
			"video_mem_bytes": _stats("video_mem"),
			"texture_mem_bytes": _stats("texture_mem"),
			"buffer_mem_bytes": _stats("buffer_mem"),
		},
	}
	var mode := "headless" if report["headless"] else "window"
	var output_path := "user://perf_baseline_%s.json" % mode
	var file := FileAccess.open(output_path, FileAccess.WRITE)
	file.store_string(JSON.stringify(report, "  "))
	file.close()
	print("[PERF_JSON] " + JSON.stringify(report))
	print("[PERF] 已写入 %s" % ProjectSettings.globalize_path(output_path))
	change_scene_to_file("res://scenes/ui/main_menu.tscn")
	await create_timer(0.8).timeout
	quit(0)


func _stats(key: String) -> Dictionary:
	var values: Array[float] = []
	for sample in _samples:
		values.append(float(sample[key]))
	values.sort()
	if values.is_empty():
		return {"avg": 0.0, "p95": 0.0, "max": 0.0}
	var sum := 0.0
	for value in values:
		sum += value
	var p95_index := mini(int(ceil(values.size() * 0.95)) - 1, values.size() - 1)
	return {"avg": sum / values.size(), "p95": values[p95_index], "max": values[-1]}
