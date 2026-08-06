## zombie_ai_budget.gd — 分帧 AI 预算参数（M3-S4）
## 职责：从 director.json ai_budget.max_ai_per_frame 静态读取一次（改 JSON 重启生效）；
##       默认 80（M3-S4 实测：40 在 100 只下 AI 更新率约 24Hz 偏低，提至 80 约 48Hz；
##       100 只 CPU 帧时间仍 <16.7ms 裕量充足，见引擎版本记录性能基线）
## 输入：data/director.json（缺失/损坏回落默认 80，不阻塞运行）
## 输出：ZombieAIBudget.max_per_frame 供 zombie_ai_common 分帧预算使用（静态，无实例）
## 谁调用：zombie_ai_common._ready 首次调 ensure_loaded()；_ai_budget_ok 读 max_per_frame
## 规范：tech-plan §2.2 规则 3（性能参数数据驱动）/§5.4（分帧预算防一帧卡死）；
##       纯逻辑 RefCounted 无场景引用 → 无加载环（M2-S3 循环依赖风险不适用）

class_name ZombieAIBudget
extends RefCounted

const DIRECTOR_JSON_PATH := "res://data/director.json"
const DEFAULT_MAX_PER_FRAME := 80

static var max_per_frame := DEFAULT_MAX_PER_FRAME
static var _loaded := false


## 静态懒载：所有丧尸共享同一预算值（每帧轮询计数在 zombie_ai_common 内静态维护）
static func ensure_loaded() -> void:
	if _loaded:
		return
	_loaded = true
	var file := FileAccess.open(DIRECTOR_JSON_PATH, FileAccess.READ)
	if file == null:
		return
	var parsed = JSON.parse_string(file.get_as_text())
	if parsed is Dictionary:
		var cfg: Dictionary = parsed.get("ai_budget", {})
		max_per_frame = maxi(int(cfg.get("max_ai_per_frame", DEFAULT_MAX_PER_FRAME)), 1)
