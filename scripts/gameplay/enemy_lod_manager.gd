extends Node
## 远距离怪关闭阴影并降低动画更新，减少守点阶段窗口渲染压力。

var _timer := 0.0


func _process(delta: float) -> void:
	_timer += delta
	if _timer < 0.25:
		return
	_timer = 0.0
	var players := get_tree().get_nodes_in_group("players")
	for zombie in get_tree().get_nodes_in_group("zombies"):
		var body := zombie as Node3D
		if body == null:
			continue
		var distance := INF
		for player in players:
			distance = minf(distance, body.global_position.distance_to((player as Node3D).global_position))
		_set_lod(body, distance)


func _set_lod(root: Node, distance: float) -> void:
	for child in root.get_children():
		if child is GeometryInstance3D:
			(child as GeometryInstance3D).cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF if distance > 20.0 else GeometryInstance3D.SHADOW_CASTING_SETTING_ON
		if child is AnimationPlayer:
			(child as AnimationPlayer).active = distance <= 30.0
		_set_lod(child, distance)
