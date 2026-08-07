## checkpoint_manager.gd — 推进制检查点/存档（M3-S5b；tech-plan §4.5 主机本机存档）
## 职责：章节完成（到达后门安全屋）→ save_progress 写 save/progress.json（user://，导出版可写）；
##       load_progress 读取（损坏兜底回退最近有效/默认）；has_progress 供主菜单显示"可续玩"。
## 输入：LevelAdvance._complete_segment（服务器）调用静态 save_progress；主菜单查询 has_progress
## 输出：user://save/progress.json；返回存档 Dictionary
## 谁调用：仅主机（服务器）写档，客户端不持有（延续主机权威，tech-plan §5 风险备注 2）；
##       读取不限端（主菜单/调试脚本）
## 规范：MVP 简化字段=段落号+完成时间（任务卡 §2-S5 H4）；存档损坏兜底（parse 失败回退默认）
##       单文件 ≤300 行；纯 RefCounted 静态工具（无场景引用，无加载环）

class_name CheckpointManager
extends RefCounted

const VERSION := 3
const COMPLETE_PHASE := 5
const CheckpointValidation := preload("res://scripts/gameplay/checkpoint_validation.gd")
const SAVE_DIR := "user://save"
const SAVE_PATH := "user://save/progress.json"
## 仓库内默认存档（未完成态种子，供首次运行/兜底读取）
const SEED_PATH := "res://save/progress.json"

## 服务器：写入存档。equipment 保存当前武器和各武器弹匣；level_phase 保存关卡状态机阶段。
## save_path 仅用于测试隔离，正式调用保持默认 user:// 路径。
static func save_progress(
	segment: int,
	finish_time_s: float,
	score: int = 0,
	equipment: Dictionary = {},
	level_phase: int = 0,
	save_path: String = SAVE_PATH,
	player_state: Dictionary = {},
	level_flags: Dictionary = {},
	segment_completed: bool = false,
) -> Dictionary:
	var data := {
		"version": VERSION,
		"segment": segment,
		"completed": segment_completed or level_phase >= COMPLETE_PHASE,
		"level_phase": level_phase,
		"finish_time_s": roundf(finish_time_s * 100.0) / 100.0,
		"best_score": score,
		"equipment": equipment.duplicate(true),
		"player_state": player_state.duplicate(true),
		"level_flags": level_flags.duplicate(true),
		"saved_at": Time.get_datetime_string_from_system(),
	}
	if _normalize_progress(data).is_empty():
		push_error("[CheckpointManager] 拒绝写入无效存档快照")
		return {}
	var save_dir := save_path.get_base_dir()
	var dir := DirAccess.open(save_dir)
	if dir == null:
		var err := DirAccess.make_dir_recursive_absolute(save_dir)
		if err != OK:
			push_error("[CheckpointManager] 无法创建存档目录 %s err=%d" % [save_dir, err])
			return {}
	var temp_path := save_path + ".tmp"
	var absolute_save_path := ProjectSettings.globalize_path(save_path)
	var absolute_temp_path := ProjectSettings.globalize_path(temp_path)
	var absolute_backup_path := ProjectSettings.globalize_path(save_path + ".bak")
	var file := FileAccess.open(temp_path, FileAccess.WRITE)
	if file == null:
		push_error("[CheckpointManager] 无法写入临时存档 %s" % temp_path)
		return {}
	file.store_string(JSON.stringify(data, "\t"))
	file.flush()
	file.close()
	var temp_file := FileAccess.open(temp_path, FileAccess.READ)
	var temp_text := temp_file.get_as_text() if temp_file != null else ""
	if temp_file != null:
		temp_file.close()
	var temp_parsed = JSON.parse_string(temp_text)
	if not (temp_parsed is Dictionary) or _normalize_progress(temp_parsed).is_empty():
		DirAccess.remove_absolute(absolute_temp_path)
		push_error("[CheckpointManager] 临时存档校验失败，保留原存档")
		return {}
	if _load_valid_file(save_path).is_empty() == false:
		var copy_err := DirAccess.copy_absolute(absolute_save_path, absolute_backup_path)
		if copy_err != OK:
			DirAccess.remove_absolute(absolute_temp_path)
			push_error("[CheckpointManager] 无法更新存档备份 err=%d" % copy_err)
			return {}
	if FileAccess.file_exists(save_path):
		var remove_err := DirAccess.remove_absolute(absolute_save_path)
		if remove_err != OK:
			DirAccess.remove_absolute(absolute_temp_path)
			return {}
	var rename_err := DirAccess.rename_absolute(absolute_temp_path, absolute_save_path)
	if rename_err != OK:
		push_error("[CheckpointManager] 无法替换主存档 err=%d" % rename_err)
		return {}
	print("[CheckpointManager] 已存档 %s（segment=%d 用时=%.1fs）" % [save_path, segment, finish_time_s])
	return data


## 读取存档；缺失/损坏回退最近有效（仓库种子 → 内存默认）
static func load_progress(save_path: String = SAVE_PATH) -> Dictionary:
	var normalized := _load_valid_file(save_path)
	if not normalized.is_empty():
		return normalized
	normalized = _load_valid_file(save_path + ".bak")
	if not normalized.is_empty():
		push_warning("[CheckpointManager] 主存档损坏，已恢复最近有效备份")
		return normalized
	return _load_seed()


## 是否已有可续进度（已完成的段落号 > 0）
static func has_progress(save_path: String = SAVE_PATH) -> bool:
	if not FileAccess.file_exists(save_path) and not FileAccess.file_exists(save_path + ".bak"):
		return false
	return int(load_progress(save_path).get("segment", 0)) > 0


## 从玩家公开节点状态生成装备快照。当前武器系统没有备用弹药，magazines 即全部可恢复弹药。
static func capture_equipment(player: Node) -> Dictionary:
	if player == null:
		return {}
	var pivot := player.get_node_or_null("WeaponPivot")
	if pivot == null:
		return {}
	var active_weapon := ""
	var magazines := {}
	for weapon in pivot.get_children():
		if not _has_property(weapon, "weapon_id") or not _has_property(weapon, "mag_current"):
			continue
		var weapon_id := String(weapon.get("weapon_id"))
		if weapon_id.is_empty():
			continue
		magazines[weapon_id] = int(weapon.get("mag_current"))
		if _has_property(weapon, "visible") and bool(weapon.get("visible")):
			active_weapon = weapon_id
	if magazines.is_empty():
		return {}
	return {"active_weapon": active_weapon, "magazines": magazines}


## 将已校验的装备快照交给玩家公开入口恢复。
static func apply_equipment(player: Node, equipment: Dictionary) -> bool:
	if player == null or not CheckpointValidation.is_valid_equipment(equipment):
		return false
	if not player.has_method("restore_equipment"):
		return false
	return bool(player.call("restore_equipment", equipment))


## 采集主机玩家的可恢复状态；只包含重建后仍有意义的位置、朝向、生命与状态。
static func capture_player_state(player: Node3D) -> Dictionary:
	if player == null:
		return {}
	var health := player.get_node_or_null("Health")
	if health == null:
		return {}
	return {
		"position": [player.global_position.x, player.global_position.y, player.global_position.z],
		"rotation_y": player.global_rotation.y,
		"hp": health.hp,
		"state": int(health.state),
	}


## 在导航网格上校验位置后恢复玩家；位置不可信时保留关卡出生点。
static func apply_player_state(player: Node3D, snapshot: Dictionary) -> bool:
	if player == null or not CheckpointValidation.is_valid_player_state(snapshot) or snapshot.is_empty():
		return false
	var values: Array = snapshot.position
	var requested := Vector3(float(values[0]), float(values[1]), float(values[2]))
	var map := player.get_world_3d().navigation_map
	var walkable := NavigationServer3D.map_get_closest_point(map, requested)
	if walkable.distance_to(requested) > 0.75:
		return false
	player.global_position = walkable
	player.global_rotation.y = float(snapshot.rotation_y)
	if player is CharacterBody3D:
		(player as CharacterBody3D).velocity = Vector3.ZERO
	var health := player.get_node_or_null("Health")
	if health == null or not health.has_method("restore_checkpoint_state"):
		return false
	health.restore_checkpoint_state(float(snapshot.hp), int(snapshot.state))
	return true


## 兜底：优先读仓库种子文件（res://save/progress.json），失败用内存默认
static func _load_seed() -> Dictionary:
	var seed := FileAccess.open(SEED_PATH, FileAccess.READ)
	if seed != null:
		var parsed = JSON.parse_string(seed.get_as_text())
		if parsed is Dictionary:
			var normalized := _normalize_progress(parsed)
			if not normalized.is_empty():
				return normalized
	return {
		"version": VERSION,
		"segment": 0,
		"completed": false,
		"level_phase": 0,
		"finish_time_s": 0.0,
		"best_score": 0,
		"equipment": {},
		"player_state": {},
		"level_flags": {},
		"saved_at": "",
	}


static func _normalize_progress(data: Dictionary) -> Dictionary:
	return CheckpointValidation.normalize_progress(data, VERSION, COMPLETE_PHASE)


static func _has_property(object: Object, property_name: String) -> bool:
	for property in object.get_property_list():
		if String(property.name) == property_name:
			return true
	return false


static func _load_valid_file(path: String) -> Dictionary:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return {}
	var text := file.get_as_text()
	file.close()
	var json := JSON.new()
	if json.parse(text) != OK or not (json.data is Dictionary):
		return {}
	return _normalize_progress(json.data)
