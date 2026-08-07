extends RefCounted
## 存档结构校验与旧版本迁移。保持纯数据逻辑，不访问场景或文件系统。


static func normalize_progress(data: Dictionary, current_version: int, complete_phase: int) -> Dictionary:
	if not data.has("version") or not (data.version is int or data.version is float):
		return {}
	var version := int(data.version)
	if version != 1 and version != 2 and version != current_version:
		return {}
	for key in ["segment", "finish_time_s", "best_score"]:
		if not data.has(key) or not (data[key] is int or data[key] is float):
			return {}
	if not data.has("completed") or not (data.completed is bool):
		return {}
	var segment := int(data.segment)
	var finish_time := float(data.finish_time_s)
	var score := int(data.best_score)
	if segment < 0 or finish_time < 0.0 or score < 0:
		return {}
	var phase := complete_phase if version == 1 and segment > 0 else 0
	var equipment: Dictionary = {}
	if version >= 2:
		if not data.has("level_phase") or not (data.level_phase is int or data.level_phase is float):
			return {}
		phase = int(data.level_phase)
		if phase < 0 or phase > complete_phase:
			return {}
		if not data.has("equipment") or not (data.equipment is Dictionary):
			return {}
		equipment = (data.equipment as Dictionary).duplicate(true)
		if not is_valid_equipment(equipment):
			return {}
	var player_state: Dictionary = {}
	var level_flags: Dictionary = {}
	if version == current_version:
		if not data.has("player_state") or not (data.player_state is Dictionary):
			return {}
		player_state = (data.player_state as Dictionary).duplicate(true)
		if not is_valid_player_state(player_state):
			return {}
		if not data.has("level_flags") or not (data.level_flags is Dictionary):
			return {}
		level_flags = (data.level_flags as Dictionary).duplicate(true)
		if not _is_valid_level_flags(level_flags):
			return {}
	return {
		"version": current_version,
		"segment": segment,
		"completed": bool(data.completed),
		"level_phase": phase,
		"finish_time_s": finish_time,
		"best_score": score,
		"equipment": equipment,
		"player_state": player_state,
		"level_flags": level_flags,
		"saved_at": String(data.get("saved_at", "")),
	}


static func is_valid_equipment(equipment: Dictionary) -> bool:
	if equipment.is_empty():
		return true
	if not (equipment.get("active_weapon", "") is String):
		return false
	var magazines = equipment.get("magazines")
	if not (magazines is Dictionary):
		return false
	for weapon_id in magazines:
		if not (weapon_id is String):
			return false
		var amount = magazines[weapon_id]
		if not (amount is int or amount is float) or int(amount) < 0:
			return false
	return true


static func is_valid_player_state(snapshot: Dictionary) -> bool:
	if snapshot.is_empty():
		return true
	var position = snapshot.get("position")
	if not (position is Array) or position.size() != 3:
		return false
	for coordinate in position:
		if not (coordinate is int or coordinate is float) or not is_finite(float(coordinate)):
			return false
	for key in ["rotation_y", "hp", "state"]:
		if not snapshot.has(key) or not (snapshot[key] is int or snapshot[key] is float):
			return false
	return is_finite(float(snapshot.rotation_y)) and float(snapshot.hp) >= 0.0 \
		and int(snapshot.state) >= 0 and int(snapshot.state) <= 2


static func _is_valid_level_flags(flags: Dictionary) -> bool:
	if flags.is_empty():
		return true
	for key in ["horde_triggered", "horde_cleared", "holdout_triggered", "holdout_cleared", "harass_done"]:
		if not flags.has(key) or not (flags[key] is bool):
			return false
	return true
