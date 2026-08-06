## loot_manager.gd — 掉落表 + 死亡掉落生成（M3-S6；tech-plan §4.2 掉落服务器权威）
## 职责：装载 data/loot.json（数据驱动，改 JSON 重启生效）；服务器侧丧尸死亡入口
##       on_zombie_died(zombie)：击杀统计（GameState 分列普通/特感）+ 按类型掷骰 →
##       命中则在死亡位置生成掉落物（World/Pickups 容器 + MultiplayerSpawner 复制各端）
## 输入：zombie_ai_common / zombie_ai_special 的 _on_died（服务器）经组动态 call 本入口
## 输出：GameState.register_zombie_kill；在 Pickups 容器生成 pickup_ammo/pickup_health
## 谁调用：仅服务器（掉落/统计服务器权威，tech-plan §4.2）；客户端不执行
## 规范：概率=累积轮盘掷骰（roll∈[0,1) 落累加区间；总和<1 剩余为不掉落）；
##       ZombieHealth.zombie_type 区分类型（common/charger/spitter，特感由 AI 基类注入）；
##       不引用丧尸/掉落物类类型（动态 call，防 M2-S3 加载环）；单文件 ≤300 行

class_name LootManager
extends Node

const LOOT_JSON_PATH := "res://data/loot.json"
const PICKUP_AMMO_SCENE := "res://scenes/environment/pickup_ammo.tscn"
const PICKUP_HEALTH_SCENE := "res://scenes/environment/pickup_health.tscn"
## 掉落物容器（main.tscn：World/Pickups，PickupSpawner 的 spawn_path，服务器 add_child 即复制）
const PICKUP_CONTAINER_PATH := "../../World/Pickups"

## 掉落概率表：zombie_type -> { 物品id: 概率 }（loot.json loot_table，测试脚本可注入覆盖）
var _table: Dictionary = {}
## 物品参数表：物品id -> {amount/heal...}（loot.json items）
var _items: Dictionary = {}
var _pickup_lifetime_s := 30.0


func _ready() -> void:
	# 掉落/统计服务器权威；group 供丧尸 AI 动态查找（get_first_node_in_group("loot_manager")）
	set_multiplayer_authority(NetworkManager.SERVER_ID)
	add_to_group("loot_manager")
	_load_loot()


func _load_loot() -> void:
	var file := FileAccess.open(LOOT_JSON_PATH, FileAccess.READ)
	if file == null:
		push_error("[LootManager] 无法打开 %s，掉落停用" % LOOT_JSON_PATH)
		return
	var parsed = JSON.parse_string(file.get_as_text())
	if not (parsed is Dictionary):
		push_error("[LootManager] %s 解析失败，掉落停用" % LOOT_JSON_PATH)
		return
	var table: Dictionary = (parsed as Dictionary).get("loot_table", {})
	_table = table if table is Dictionary else {}
	var items: Dictionary = (parsed as Dictionary).get("items", {})
	_items = items if items is Dictionary else {}
	_pickup_lifetime_s = float((parsed as Dictionary).get("pickup_lifetime_s", _pickup_lifetime_s))


# --- 死亡入口（服务器；由丧尸 AI._on_died 经组动态调用） ---

## 服务器：丧尸死亡 → 击杀统计 + 按类型掷骰 → 命中则死亡位置生成掉落物
func on_zombie_died(zombie: Node) -> void:
	if not NetworkManager.is_server():
		return
	if zombie == null or not is_instance_valid(zombie):
		return
	# 击杀统计（普通/特感分列，GameState 服务器权威累加）
	var ztype := _zombie_type(zombie)
	GameState.register_zombie_kill(ztype)
	# 掷骰掉落（概率表驱动）
	var drop := _roll(ztype)
	if drop.is_empty():
		return
	_spawn_pickup(drop, zombie.global_position)


## 取丧尸类型：Health.zombie_type（普通默认 common；特感由 ZombieSpecialAI._load_params 注入）
func _zombie_type(zombie: Node) -> String:
	var health := zombie.get_node_or_null("Health")
	if health != null and health.get("zombie_type") != null:
		var t := String(health.get("zombie_type"))
		if not t.is_empty():
			return t
	return "common"


## 累积轮盘掷骰：roll∈[0,1) 落入累加区间即掉落该物品；总概率<1 则剩余为不掉落
func _roll(ztype: String) -> Dictionary:
	var chances: Dictionary = _table.get(ztype, {})
	if chances.is_empty():
		return {}
	var r := randf()
	var acc := 0.0
	for item_id in chances:
		acc = acc + float(chances[item_id])
		if r < acc:
			var cfg: Dictionary = _items.get(item_id, {})
			var drop := {"type": item_id}
			drop.merge(cfg, true)  # 携带 items 参数（amount/heal）
			return drop
	return {}


## 服务器：在容器生成掉落物（先设权威再入树，Spawner 携带 authority 复制；M2-S5 可读名铁律）
func _spawn_pickup(drop: Dictionary, pos: Vector3) -> void:
	var scene_path := PICKUP_AMMO_SCENE
	if String(drop.get("type", "ammo")) == "medkit":
		scene_path = PICKUP_HEALTH_SCENE
	var scene := load(scene_path) as PackedScene
	if scene == null:
		push_warning("[LootManager] 无法装载 %s，掉落跳过" % scene_path)
		return
	var container := get_node_or_null(PICKUP_CONTAINER_PATH) as Node3D
	if container == null:
		push_warning("[LootManager] 掉落容器 %s 不存在，掉落跳过" % PICKUP_CONTAINER_PATH)
		return
	var pickup := scene.instantiate() as Node3D
	if pickup == null:
		return
	pickup.set_multiplayer_authority(NetworkManager.SERVER_ID)
	pickup.set("lifetime_s", _pickup_lifetime_s)  # 入树前注入存活时长（_ready 读取）
	container.add_child(pickup, true)  # 强制可读名：instantiate() 节点是 @ 保留名，Spawner 复制会失败
	pickup.global_position = pos + Vector3(0.0, 0.5, 0.0)  # 抬离地面防嵌入
