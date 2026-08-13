## acid_pool.gd — 喷吐者酸液地面区域（M3-S3）
## 职责：Area3D 酸液区（半径数据驱动，默认 2.5m）：站内玩家持续扣血（DPS × 0.5s tick，
##       服务器权威，走 PlayerState.take_damage → HUD 血条自然下降）；到期自动 queue_free
##       （时长数据驱动，默认 6s）；只伤玩家（players 组过滤，丧尸/世界无效）；半透明绿色
##       圆盘视觉（基元占位，骨骼/特效 M3 后期替换）
## 输入：喷吐者 AI 生成时在 add_child 前 set radius/duration_s/dps/owner_node（zombies.json 驱动）；
##       生命周期所有端一致（同刻到期消失），伤害结算仅服务器
## 输出：区域内玩家 take_damage；到期 queue_free（各端本地创建，RPC 驱动一致）
## 谁调用：仅服务器伤害结算（tech-plan §4.2）；客户端只显示 + 到期清理
## 规范：collision_mask=1（玩家层——player.tscn 未显式配置，Godot 默认 layer 1）；
##       单文件 ≤300 行；酸区对丧尸无效（组过滤，任务卡 G4b）

class_name AcidPool
extends Area3D

const PLAYER_LAYER := 1      # 玩家碰撞层（M1-S5 碰撞层方案：世界1 / 命中区3 / 敌人4，玩家默认层 1）
const TICK_INTERVAL := 0.5   # 伤害结算间隔（秒，每次 DPS × tick）
const LANDING_Y := 0.05      # 落点离地高度（米，半透明圆盘贴地）

## 数据驱动参数（默认值 = data/zombies.json spitter.special.acid 草案；AI 生成时覆盖）
var radius := 2.5
var duration_s := 6.0
var dps := 10.0
## 攻击者引用（喷吐者 body）。喷吐者死亡后被 free，池内再结算以 null 传递（不悬挂引用）
var owner_node: Node = null

var _life_timer := 0.0
var _tick_timer := 0.0


func _ready() -> void:
	collision_layer = 0
	collision_mask = PLAYER_LAYER
	set_multiplayer_authority(NetworkManager.SERVER_ID)
	add_to_group("acid_pools")  # 调试脚本/HUD 警示按组查找
	_life_timer = duration_s
	_apply_geometry()


func _process(delta: float) -> void:
	# 生命周期在所有端推进（到期同时消失，两端可见一致）；伤害结算仅服务器
	_life_timer = _life_timer - delta
	if _life_timer <= 0.0:
		queue_free()
		return
	if not NetworkManager.is_server():
		return
	_tick_timer = _tick_timer - delta
	if _tick_timer <= 0.0:
		_tick_timer = TICK_INTERVAL
		_apply_damage()


## 服务器：对区内玩家持续结算伤害（DPS×tick）。酸区只伤玩家——players 组过滤，
## 丧尸（敌人层 4）与地面（世界层 1）即使重叠也不受伤（任务卡 G4b）
func _apply_damage() -> void:
	var attacker := owner_node if is_instance_valid(owner_node) else null
	for body in get_overlapping_bodies():
		if not body.is_in_group("players"):
			continue
		var ps := body.get_node_or_null("Health") as PlayerState
		if ps == null or ps.state == PlayerState.State.DEAD:
			continue
		ps.take_damage(dps * TICK_INTERVAL, attacker)


## 数据驱动几何：radius 变更时同步视觉圆盘、气泡粒子与碰撞柱。
## mesh/shape 为场景资源须 duplicate 后再改，否则会污染 PackedScene 共享资源
func _apply_geometry() -> void:
	var visual := get_node_or_null("Visual") as MeshInstance3D
	if visual != null and visual.mesh is CylinderMesh:
		visual.mesh = visual.mesh.duplicate()
		var cm := visual.mesh as CylinderMesh
		cm.top_radius = radius
		cm.bottom_radius = radius
	var bubbles := get_node_or_null("Bubbles") as GPUParticles3D
	if bubbles != null:
		bubbles.scale = Vector3(radius, 1.0, radius)
	var area := get_node_or_null("CollisionShape") as CollisionShape3D
	if area != null and area.shape is CylinderShape3D:
		area.shape = area.shape.duplicate()
		(area.shape as CylinderShape3D).radius = radius
