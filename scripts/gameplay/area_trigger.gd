## area_trigger.gd — 关卡区域触发体（M3-S5 推进制）
## 职责：带 trigger_id 的 Area3D，配合 LevelAdvance 驱动关卡推进（门/区域进入/尸潮触发点）。
##       仅做"区域标记"与信号转发，不含任何玩法逻辑——具体行为由 LevelAdvance 按 trigger_id 分发。
## 输入：玩家 CharacterBody3D 进入触发体（body_entered 信号）
## 输出：body_entered 信号 + 注册到 "level_trigger" 组（LevelAdvance 按组查找并连接）
## 谁调用：rustyard.tscn 中摆放的触发体节点；LevelAdvance._ready 扫描 "level_trigger" 组
## 规范：tech-plan §8.4 用组代替长引用链；editor_description 标注区域名（§8.4）

class_name AreaTrigger
extends Area3D

## 触发标识（LevelAdvance 分发用）：safe_exit / corridor_enter / corridor_mid / plaza_enter / backdoor_enter
@export var trigger_id := ""


func _ready() -> void:
	add_to_group("level_trigger")
	# 碰撞层沿用默认（玩家 CharacterBody3D 默认层 1，mask 1 可互相检测）
