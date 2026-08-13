extends Node
## 窗口实机性能采样；每 5 秒输出一次，出现长帧时立即输出现场规模。

var _timer := 0.0
var _peak_frame_ms := 0.0


func _process(delta: float) -> void:
	var frame_ms := delta * 1000.0
	_peak_frame_ms = maxf(_peak_frame_ms, frame_ms)
	_timer += delta
	if frame_ms >= 50.0 or _timer >= 5.0:
		_report(frame_ms >= 50.0)
		_timer = 0.0
		_peak_frame_ms = 0.0


func _report(stall: bool) -> void:
	var zombies := get_tree().get_nodes_in_group("zombies").size()
	if zombies == 0:
		var container := get_node_or_null("../../Zombies")
		zombies = container.get_child_count() if container != null else 0
	var pickups := get_tree().get_nodes_in_group("pickup_items").size()
	var nodes := int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT))
	var physics_ms := Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0
	var draws := int(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME))
	var render_objects := int(Performance.get_monitor(Performance.RENDER_TOTAL_OBJECTS_IN_FRAME))
	print("[Performance%s] peak=%.1fms physics=%.2fms zombies=%d pickups=%d nodes=%d draws=%d objects=%d" % [
		" STALL" if stall else "", _peak_frame_ms, physics_ms, zombies, pickups, nodes, draws, render_objects
	])
