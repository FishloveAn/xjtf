## zombie_pool.gd — 丧尸对象池（M2-S3a）
## 职责：预实例化 POOL_CAPACITY=128 只 zombie_common（隐藏，不进场景树，避免占用物理/剔除）；
##       spawn_from_pool(pos) 出池（复位 → 设权威 → add_child 到 Zombies 容器 → 置位）；
##       despawn_to_pool(z) 回池（完整复位，防"死尸复活"，M2 任务卡 §6 风险备注 2）
## 输入：WaveManager._ready 创建本节点并调用 setup(zombies_container)；出池位置由调用方给定
## 输出：spawn_from_pool 返回 Node3D 或 null（池空/超同屏上限）；despawn_to_pool 归还复用
## 谁调用：仅服务器（WaveManager 刷怪入口 / ZombieAI 死亡清理回调）；客户端不建池（本地无丧尸）
## 规范：tech-plan §5.5（对象池避免运行时反复 instantiate/free——高密度丧尸卡顿头号元凶）；
##       回池复位铁律：hp→max_hp、AI state→IDLE、collision→(4,5)、velocity→0、
##       血雾停喷、Visual scale→1、残留死亡 tween 杀掉、authority→SERVER_ID；
##       池节点出池时才 add_child（MultiplayerSpawner 关系：保持 M1 手动 add_child 模式，
##       S3 不做快照/兴趣管理，S5 联机验收再看）

class_name ZombiePool
extends Node

const ZOMBIE_SCENE_PATH := "res://scenes/enemies/zombie_common.tscn"
const POOL_CAPACITY := 128    # 预实例化容量（tech-plan §5.5：128 为 M3 100 只留余量）
const MAX_CONCURRENT := 100   # 同屏出池上限（M2 目标 30 只达标，为 M3 100 只留余量）
const COLLISION_LAYER := 4    # 丧尸身体层（敌人层，M1-S5 碰撞层方案）
const COLLISION_MASK := 5     # 世界1 + 敌人4（踩地/互相推挤）

var _zombies: Node3D = null       # Zombies 容器（出池 add_child 目标，由 setup 注入）
var _pool: Array[Node3D] = []     # 空闲池
var _active: Array[Node3D] = []   # 活跃池（出池上限统计）
var _scene: PackedScene = null    # 延迟 load（防加载期循环：池 preload 场景 → 场景引 AI → AI 引用池）


func _ready() -> void:
	# 供 ZombieAI 死亡清理经 get_first_node_in_group("zombie_pool") 回池，避免长引用链（tech-plan §8.4）
	add_to_group("zombie_pool")


func _exit_tree() -> void:
	# 池内 off-tree 节点不随场景树级联释放，必须手动清（防 ObjectDB 泄漏；
	# _active 节点在 Zombies 容器内由树级联释放，此处仅兜底）
	for z in _pool:
		if is_instance_valid(z):
			z.queue_free()
	_pool.clear()
	for z in _active:
		if is_instance_valid(z) and z.get_parent() == null:
			z.queue_free()
	_active.clear()


## 预实例化（WaveManager._ready 调用）。节点保持 off-tree：_ready 在首次 add_child 时才跑，
## AI 连接 died / ZombieSync 配置因此只在首次出池时初始化一次，之后反复复用不重复初始化
func setup(zombies: Node3D) -> void:
	_zombies = zombies
	_pool.clear()
	_active.clear()
	_scene = load(ZOMBIE_SCENE_PATH) as PackedScene
	if _scene == null:
		push_error("[ZombiePool] 无法装载 zombie_common.tscn，对象池停用")
		return
	for i in POOL_CAPACITY:
		var z: Node3D = _scene.instantiate()
		_pool.append(z)


## 出池：复位 → 先设权威再入树（M1 已验证顺序，生成包携带 authority）→ 置位。
## 返回 null 表示池空或超同屏上限（调用方跳过本只，不推进计数）
func spawn_from_pool(pos: Vector3) -> Node3D:
	if _zombies == null or _pool.is_empty():
		return null
	if _active.size() >= MAX_CONCURRENT:
		return null
	var z: Node3D = _pool.pop_back()
	_reset_zombie(z)
	z.set_multiplayer_authority(NetworkManager.SERVER_ID)
	_zombies.add_child(z)
	z.global_position = pos  # 先入树再设 global_position（4.7 实测：未入树设会触发错误）
	_active.append(z)
	return z


## 回池：移出场景树 → 完整复位 → 归还空闲池（ZombieAI 死亡清理回调调用）
func despawn_to_pool(z: Node3D) -> void:
	if not is_instance_valid(z):
		return
	var was_active := _active.has(z)
	if was_active:
		_active.erase(z)
	if z.get_parent() == _zombies:
		_zombies.remove_child(z)
	if not _pool.has(z):
		_pool.append(z)  # 防重复回池（同节点被二次 despawn 时不再入池）
	_reset_zombie(z)


## 回池复位铁律（M2 风险备注 2）：复位不彻底 = 第二次出池"死尸复活/碰撞残留/血雾复活"
func _reset_zombie(z: Node3D) -> void:
	# 血量回满：hp<=0 复活会免疫伤害（take_damage 提前返回），表现为"打不死"
	var health := z.get_node_or_null("Health") as ZombieHealth
	if health != null:
		health.hp = health.max_hp
	# AI 复位：state→IDLE、碰撞层恢复、速度归零、物理处理恢复、杀残留死亡 tween
	var ai := z.get_node_or_null("AI") as ZombieAI
	if ai != null:
		ai.reset_for_pool()
	# 可视复位：死亡淡出把 Visual scale 归零，出池必须恢复（否则"隐形丧尸"）
	var visual := z.get_node_or_null("Visual") as Node3D
	if visual != null:
		visual.scale = Vector3.ONE
	z.visible = true
	# 血雾停喷：一次性粒子未播完也复位（防出池后残留粒子跟随复活丧尸）
	var blood := z.get_node_or_null("BloodPuff") as GPUParticles3D
	if blood != null:
		blood.emitting = false
	# 服务器角度复位：位置/朝向/权威清零。用本地 position（off-tree 节点设 global_position
	# 会触发 4.7 错误"!is_inside_tree()"——get_global_transform 要求已入树；出池后再设 global）
	z.position = Vector3.ZERO
	z.rotation = Vector3.ZERO
	z.set_multiplayer_authority(NetworkManager.SERVER_ID)
