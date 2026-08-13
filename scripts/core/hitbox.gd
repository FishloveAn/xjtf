## hitbox.gd — 命中区域（Area3D，collision_layer=3）
## 职责：作为武器 hitscan（S3）与近战（S5）的命中目标；命中后把伤害转发给挂接的 Damageable
## 输入：服务器 hitscan intersect_ray 命中本节点 → 调用 apply_hit(dmg, attacker)
## 输出：转发到 damageable.take_damage()
## 谁调用：仅服务器（S3 hitscan / S5 丧尸近战）；collision_layer=3（tech-plan §3.3 敌人层）
## 规范：collision_layer=3 固定；碰撞层规划见 tech-plan §5.6

class_name Hitbox
extends Area3D

const HITBOX_LAYER := 1 << 3

## 挂接的可受伤对象。统一使用 NodePath，避免场景反序列化时节点引用为空。
@export var damageable_path: NodePath = ^"../Health"
@export_enum("body", "head") var hit_zone := "body"

var _damageable: Damageable

func _ready() -> void:
	collision_layer = HITBOX_LAYER
	collision_mask = 0
	_damageable = get_node_or_null(damageable_path) as Damageable
	if _damageable == null:
		push_warning("Hitbox 未挂接 Damageable: %s -> %s" % [get_path(), damageable_path])

## 服务器命中后调用：把伤害转发给 damageable（非服务器调用会被 damageable 拒绝）
func apply_hit(dmg: float, attacker: Node = null) -> Dictionary:
	if _damageable == null:
		return {}
	if _damageable.has_method("apply_weapon_hit"):
		return _damageable.call("apply_weapon_hit", dmg, hit_zone, attacker)
	_damageable.take_damage(dmg, attacker)
	return {"hit_zone": hit_zone, "applied_damage": dmg, "killed": false}
