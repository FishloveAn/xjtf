## hitscan.gd — hitscan 命中复判（服务器物理空间）
## 职责：从服务器物理空间做 intersect_ray，返回命中结果；射线 exclude 射手自身
## 输入：weapon_base._server_fire 调用 server_raycast(origin, dir, range_m, shooter, mask)
## 输出：Dictionary（PhysicsDirectSpaceState3D.intersect_ray 结果；无命中为空 dict）
## 谁调用：仅服务器（weapon_base，tech-plan §5.6 / §6.2 复判）
## 规范：core 层零热路径分配；collision_mask 由调用方传（默认世界+命中区域 1|3）

class_name Hitscan
extends RefCounted

## 服务器物理空间射线复判。命中结果含 "collider" 等键；无命中返回空 Dictionary
static func server_raycast(
	origin: Vector3,
	dir: Vector3,
	range_m: float,
	shooter: Node3D,
	collision_mask: int = 1 | 3
) -> Dictionary:
	var space := shooter.get_world_3d().direct_space_state
	var to := origin + dir.normalized() * range_m
	var exclude: Array[RID] = []
	# exclude 射手自身碰撞体（防止射向自己/贴脸自伤；tech-plan §6.2）
	if shooter is CollisionObject3D:
		exclude.append((shooter as CollisionObject3D).get_rid())
	var query := PhysicsRayQueryParameters3D.create(origin, to, collision_mask, exclude)
	# 需要命中 Area3D（hitbox 是 Area3D，collision_layer=3）
	query.collide_with_areas = true
	query.collide_with_bodies = true
	return space.intersect_ray(query)
