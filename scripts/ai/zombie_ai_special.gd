## zombie_ai_special.gd — 特感 AI 基类（M3-S2/S3；tech-plan §3.4/§5.4，冲撞者/喷吐者共用）
## 职责：特感公共基础设施——data/zombies.json 数据驱动加载（静态缓存 id→条目、改 JSON 重启
##       生效，_params 为实例级：多特感类型共存互不覆盖）、服务器权威 transform 同步
##       （SpecialSync）、死亡链路（Died→authority 广播→血雾/淡出→queue_free 清理，特感 ≤5
##       不池化）、玩家检索（DEAD 玩家不作目标）、简化导航朝向、音效钩子
## 输入：子类 _ready() 调 super._ready() 完成初始化；Health.died 信号 → _on_died
## 输出：父节点 CharacterBody3D 位移/朝向由子类状态机驱动（_physics_process）
## 谁调用：仅服务器执行（子类 _physics_process 判 is_server）；客户端纯显示
## 规范：特感同屏 ≤5（WaveManager cap 控制）；死亡直连 queue_free（M3 风险备注 6）；
##       子类差异点：_params_id() 条目 id、_apply_params() 差异参数、_death_sfx_event()、状态机
##       单文件 ≤300 行

class_name ZombieSpecialAI
extends Node

const COLLISION_LAYER := 4          # 敌人层（M1-S5 碰撞层方案）
const COLLISION_MASK := 5           # 世界1 + 敌人4
const DEATH_FADE_TIME := 0.6        # 秒，死亡 Visual 缩放淡出
const ZOMBIES_JSON_PATH := "res://data/zombies.json"

var _body: CharacterBody3D
var _visual: Node3D = null
var _anim_player: AnimationPlayer = null   # M3-ART-P1：特感 AnimationPlayer（glb 内嵌），按状态切换播放
var _die_clear_s := 2.5
var _visual_tween: Tween = null     # 前摇/死亡表现 tween，跨状态切换必须 kill

## 特感条目参数缓存（静态：JSON 只读一次，按 id 索引多条目，多实例共享；改 JSON 重启生效）
static var _params_loaded := false
static var _all_params: Dictionary = {}   # id → 条目（charger/spitter 各一份）
## 本实例条目参数（实例级：静态缓存仅按 id 索引，跨类型实例各取各的，不互相覆盖）
var _params: Dictionary = {}


func _ready() -> void:
	_body = get_parent() as CharacterBody3D
	if _body == null:
		return
	_visual = _body.get_node_or_null("Visual") as Node3D
	_load_params()
	_apply_params()
	var health := get_node_or_null("../Health") as ZombieHealth
	if health != null and not health.died.is_connected(_on_died):
		health.died.connect(_on_died)
	add_to_group("zombie_specials")  # HUD 前摇警示等按组查找
	_setup_sync()
	_bind_anim_player()  # M3-ART-P1：特感带骨骼 glb（含 AnimationPlayer），按状态切换播放


## M3-ART-P1：查找 glb 实例下的 AnimationPlayer 并初始化（spawn 一次）
func _bind_anim_player() -> void:
	if _visual == null:
		return
	_anim_player = _visual.find_child("AnimationPlayer", true, false)
	if _anim_player == null:
		return  # 无骨骼模型不要求动画（保持原状可跑）
	# 生成时播放 spawn 一次（任务规范：spawn 槽位，缺失时降级为代码淡入——本流程 6 槽已含 spawn）
	if _anim_player.has_animation("spawn"):
		_anim_player.play("spawn")
	else:
		_anim_player.play("idle")


## M3-ART-P1：按状态播放指定动画槽（特感 AnimationPlayer 6 槽：idle/walk/attack/hurt/death/spawn）
## 子类在状态切换点调用；无对应槽时回退 idle（pause/loop 保持默认）
func _play_anim(slot: String) -> void:
	if _anim_player == null:
		return
	if _anim_player.has_animation(slot):
		_anim_player.play(slot)
	elif _anim_player.has_animation("idle"):
		_anim_player.play("idle")


## 子类覆盖：zombies.json 条目 id（默认 charger；S3 喷吐者覆写 spitter）
func _params_id() -> String:
	return "charger"


## 子类覆盖：读取 _params 应用自身差异参数（基类已应用公共 hp/die_clear_s）
func _apply_params() -> void:
	pass


## 子类覆盖：死亡音效事件（charger=charger_death；S3 spitter 覆写）
func _death_sfx_event() -> String:
	return "zombie_died"


func _load_params() -> void:
	if not _params_loaded:
		_params_loaded = true
		var file := FileAccess.open(ZOMBIES_JSON_PATH, FileAccess.READ)
		if file != null:
			var parsed = JSON.parse_string(file.get_as_text())
			if parsed is Dictionary:
				for z in parsed.get("zombies", []):
					if z is Dictionary and not String(z.get("id", "")).is_empty():
						_all_params[z.get("id")] = z
	_params = _all_params.get(_params_id(), {})  # 实例级：按类型取各自条目
	var hp: float = float(_params.get("hp", 100.0))
	var health := get_node_or_null("../Health") as ZombieHealth
	if health != null:
		health.max_hp = hp
		health.hp = hp
		health.zombie_type = _params_id()  # M3-S6：掉落表/击杀统计按特感类型分列
	_die_clear_s = float(_params.get("die_clear_s", _die_clear_s))


# --- 工具（子类复用） ---

## 最近玩家（DEAD 玩家不作目标；DOWN 倒地玩家仍是目标，持续压制）
func _nearest_player() -> Node3D:
	var best: Node3D = null
	var best_dist := INF
	for p in get_tree().get_nodes_in_group("players"):
		var ps := p.get_node_or_null("Health") as PlayerState
		if ps == null or ps.state == PlayerState.State.DEAD:
			continue
		var dist := _body.global_position.distance_squared_to(p.global_position)
		if dist < best_dist:
			best_dist = dist
			best = p as Node3D
	return best


## 音效钩子：事件 → SfxPool 播放（素材缺失静默跳过；pos 默认特感位置）
func _play_sfx(event: String, pos: Vector3 = Vector3.ZERO) -> void:
	if pos == Vector3.ZERO:
		pos = _body.global_position
	SfxPool.play_3d(event, pos)


# --- 死亡（复用 Damageable.died 链路 + 血雾/淡出，不池化直连清理） ---

func _on_died(_attacker: Node) -> void:
	_kill_visual_tweens()
	_broadcast_zombie_died()
	_notify_loot_manager()  # M3-S6：特感死亡掉落（高概率）+ 击杀统计
	set_physics_process(false)


## 通知掉落系统（服务器）：经组动态 call（不引 LootManager 类型，防 M2-S3 加载环）
func _notify_loot_manager() -> void:
	var lm := get_tree().get_first_node_in_group("loot_manager")
	if lm != null:
		lm.call("on_zombie_died", _body)


## [authority] 服务器→所有人：特感死亡。所有端禁用碰撞、播血雾爆发 + 淡出、定时清理
@rpc("authority", "call_local", "reliable")
func zombie_died() -> void:
	_body.collision_layer = 0
	_body.collision_mask = 0
	_body.velocity = Vector3.ZERO
	_play_sfx(_death_sfx_event())
	_play_death_fx()


func _broadcast_zombie_died() -> void:
	if NetworkManager.is_network_active():
		zombie_died.rpc()
	else:
		zombie_died()


func _play_death_fx() -> void:
	var blood := _body.get_node_or_null("BloodPuff") as GPUParticles3D
	if blood != null:
		blood.restart()
	if _visual != null:
		_kill_visual_tweens()
		_visual_tween = create_tween()
		_visual_tween.tween_property(_visual, "scale", Vector3.ZERO, DEATH_FADE_TIME)
	_start_death_cleanup()


func _start_death_cleanup() -> void:
	_visual_tween = create_tween()
	_visual_tween.tween_interval(_die_clear_s)
	_visual_tween.tween_callback(_free_zombie)


## 死亡清理：特感数量 ≤5，不池化，死亡直连 queue_free（风险备注 6）
func _free_zombie() -> void:
	if not is_instance_valid(_body):
		return
	_body.queue_free()


## 杀残留视觉 tween：状态切换/死亡淡出不得受旧 tween 干扰
func _kill_visual_tweens() -> void:
	if _visual_tween != null and _visual_tween.is_valid():
		_visual_tween.kill()
		_visual_tween = null


# --- 配置服务器权威 transform 同步（4.7 铁律：先 add_property 再 set_replication_mode） ---

func _setup_sync() -> void:
	var sync := _body.get_node_or_null("SpecialSync") as MultiplayerSynchronizer
	if sync == null:
		return
	if sync.replication_config != null:
		return
	sync.set_multiplayer_authority(NetworkManager.SERVER_ID)
	var cfg := SceneReplicationConfig.new()
	cfg.add_property(NodePath(".:position"))
	cfg.property_set_replication_mode(NodePath(".:position"), SceneReplicationConfig.REPLICATION_MODE_ALWAYS)
	cfg.add_property(NodePath(".:rotation"))
	cfg.property_set_replication_mode(NodePath(".:rotation"), SceneReplicationConfig.REPLICATION_MODE_ALWAYS)
	sync.replication_config = cfg
	sync.replication_interval = 0.05  # 20Hz（tech-plan §10 丧尸同步 15-20Hz）
