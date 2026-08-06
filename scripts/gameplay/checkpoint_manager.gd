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

const VERSION := 1
const SAVE_DIR := "user://save"
const SAVE_PATH := "user://save/progress.json"
## 仓库内默认存档（未完成态种子，供首次运行/兜底读取）
const SEED_PATH := "res://save/progress.json"

## 服务器：写入存档。segment=已完成段落号（S5 为 1）；finish_time_s=段落用时；score 预留给 S6
static func save_progress(segment: int, finish_time_s: float, score: int = 0) -> Dictionary:
	var data := {
		"version": VERSION,
		"segment": segment,
		"completed": segment > 0,
		"finish_time_s": roundf(finish_time_s * 100.0) / 100.0,
		"best_score": score,
		"saved_at": Time.get_datetime_string_from_system(),
	}
	var dir := DirAccess.open(SAVE_DIR)
	if dir == null:
		var err := DirAccess.make_dir_recursive_absolute(SAVE_DIR)
		if err != OK:
			push_error("[CheckpointManager] 无法创建存档目录 %s err=%d" % [SAVE_DIR, err])
			return {}
	var file := FileAccess.open(SAVE_PATH, FileAccess.WRITE)
	if file == null:
		push_error("[CheckpointManager] 无法写入存档 %s" % SAVE_PATH)
		return {}
	file.store_string(JSON.stringify(data, "\t"))
	print("[CheckpointManager] 已存档 %s（segment=%d 用时=%.1fs）" % [SAVE_PATH, segment, finish_time_s])
	return data


## 读取存档；缺失/损坏回退最近有效（仓库种子 → 内存默认）
static func load_progress() -> Dictionary:
	var file := FileAccess.open(SAVE_PATH, FileAccess.READ)
	if file == null:
		return _load_seed()
	var parsed = JSON.parse_string(file.get_as_text())
	if not (parsed is Dictionary):
		push_warning("[CheckpointManager] 存档损坏，回退默认")
		return _load_seed()
	return parsed


## 是否已有可续进度（已完成的段落号 > 0）
static func has_progress() -> bool:
	if not FileAccess.file_exists(SAVE_PATH):
		return false
	return int(load_progress().get("segment", 0)) > 0


## 兜底：优先读仓库种子文件（res://save/progress.json），失败用内存默认
static func _load_seed() -> Dictionary:
	var seed := FileAccess.open(SEED_PATH, FileAccess.READ)
	if seed != null:
		var parsed = JSON.parse_string(seed.get_as_text())
		if parsed is Dictionary:
			return parsed
	return {
		"version": VERSION,
		"segment": 0,
		"completed": false,
		"finish_time_s": 0.0,
		"best_score": 0,
		"saved_at": "",
	}
