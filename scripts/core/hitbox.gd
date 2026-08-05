## hitbox.gd — 命中区域（Area3D，collision_layer=3）
## 职责：作为武器 hitscan（S3）与近战（S5）的命中目标；命中后把伤害转发给挂接的 Damageable
## 输入：服务器 hitscan intersect_ray 命中本节点 → 调用 apply_hit(dmg, attacker)
## 输出：转发到 damageable.take_damage()
## 谁调用：仅服务器（S3 hitscan / S5 丧尸近战）；collision_layer=3（tech-plan §3.3 敌人层）
## 规范：collision_layer=3 固定；碰撞层规划见 tech-plan §5.6

class_name Hitbox
extends Area3D

## 挂接的可受伤对象（默认父节点；跨节点挂接时手动指定）
@export var damageable: Node

func _ready() -> void:
	collision_layer = 3
	collision_mask = 0
	if damageable == null:
		damageable = get_parent()

## 服务器命中后调用：把伤害转发给 damageable（非服务器调用会被 damageable 拒绝）
func apply_hit(dmg: float, attacker: Node = null) -> void:
	var target := damageable as Damageable
	if target == null:
		push_warning("Hitbox 未挂接 Damageable: %s" % get_path())
		return
	target.take_damage(dmg, attacker)
