## player_state.gd — 玩家状态（S2：血量 + 倒地/救援/复活状态机）
## 职责：服务器权威 hp/max_hp 与 state(ALIVE/DOWN/DEAD)；take_damage() 结算；
##       救援：try_start_revive（服务器 3s 计时 + 持续条件校验）→ revive_done 复活 hp=50；
##       hp/state 经 HealthSync（服务器权威）同步；救援事件经广播 RPC 通知所有端
## 输入：武器 hitscan（S3）/ 丧尸近战（S5）/ 调试按键 K 调用 take_damage；
##       救援者按 E → request_revive RPC（any_peer）；松开 E → cancel_revive RPC
## 输出：damaged/died 信号（服务器侧）；hp/state 同步；revive_started/cancelled/done 广播
## 谁调用：仅服务器结算（tech-plan §4.2）；客户端只读 hp/state、接收救援广播
## 规范：本节点权威显式设为服务器（与 HealthSync 一致，保证 authority 广播可发）；
##       所属玩家 peer 从父节点 Player 取（owner_peer_id，因本节点权威已是服务器）；
##       状态机归属本文件（控制器/UI 不得直接改 state）；DEAD 完整结算归 M2

class_name PlayerState
extends Damageable

enum State { ALIVE, DOWN, DEAD }

const REVIVE_TIME := 3.0   # 秒，救援耗时（任务卡 C5）
const REVIVE_HP := 50.0    # 复活后血量
const REVIVE_RANGE := 2.5  # 米，救援者与倒地者最大距离

@export var max_hp := 100.0

## 当前血量（服务器权威，0..max_hp）。setter 仅钳制不发信号——信号在 take_damage()（服务器）发出
@export var hp: float = 100.0:
	set(value):
		hp = clampf(value, 0.0, max_hp)

## 玩家状态（服务器权威，HealthSync 同步）。HUD/控制器只读
@export var state: State = State.ALIVE

## 救援中标记 + 进度（纯展示，不跨端同步；由 revive_* 广播在本端驱动）
var revive_active := false
var revive_progress := 0.0

## 服务器：当前正在救援本玩家的救援者（仅服务器使用）
var _active_revive_reviver: PlayerState = null
var _revive_timer := 0.0
## 单机调试：自己救自己模式（M2 移除）
var _debug_self_revive_mode := false

@onready var _health_sync: MultiplayerSynchronizer = $HealthSync


func _ready() -> void:
	# 状态机节点权威 = 服务器：血量/状态服务器权威（tech-plan §4.2），与 HealthSync 一致
	set_multiplayer_authority(NetworkManager.SERVER_ID)
	_setup_health_sync()


func _process(delta: float) -> void:
	# 服务器：救援计时与持续条件校验（救援者存活/未离开/目标仍倒地）
	if NetworkManager.is_server() and _active_revive_reviver != null:
		_tick_revive(delta)
	# 所有端：救援进度条动画（纯展示）
	if revive_active:
		revive_progress = minf(revive_progress + delta / REVIVE_TIME, 1.0)


## 配置血量/状态同步（4.7 铁律：先 add_property 再 set_replication_mode；replication_interval 非 sync_interval）
func _setup_health_sync() -> void:
	if _health_sync == null:
		return
	_health_sync.set_multiplayer_authority(NetworkManager.SERVER_ID)
	var cfg := SceneReplicationConfig.new()
	cfg.add_property(NodePath(".:hp"))
	cfg.property_set_replication_mode(NodePath(".:hp"), SceneReplicationConfig.REPLICATION_MODE_ALWAYS)
	cfg.add_property(NodePath(".:state"))
	cfg.property_set_replication_mode(NodePath(".:state"), SceneReplicationConfig.REPLICATION_MODE_ALWAYS)
	_health_sync.replication_config = cfg
	_health_sync.replication_interval = 0.05


## 服务器结算一次伤害（tech-plan §4.2）。
## 状态机：ALIVE →(hp<=0)→ DOWN（不是死亡）；DOWN 再受击 → DEAD
func take_damage(dmg: float, attacker: Node = null) -> void:
	if not NetworkManager.is_server():
		push_warning("player_state.take_damage 仅服务器调用，已拒绝: %s" % get_path())
		return
	match state:
		State.DEAD:
			return  # 已死亡：不再结算
		State.DOWN:
			# 倒地后再受击 → 死亡（M1：表现由 HUD 黑屏承接，完整结算归 M2）
			_clear_active_revive()
			state = State.DEAD
			died.emit(attacker)
		State.ALIVE:
			hp = hp - dmg
			damaged.emit(dmg, attacker, hp)
			_broadcast_player_hurt()  # 受击音效（视觉层，所有端可听）
			if hp <= 0.0:
				hp = 0.0
				state = State.DOWN  # 倒地不是死亡：不 emit died


## 服务器：医疗补给恢复（S4 补给点）。ALIVE 回血（setter 钳制到 max_hp）；
## DOWN 倒地玩家可被救起（state→ALIVE，血量保底 REVIVE_HP）；DEAD 无效
func apply_healing(amount: float) -> void:
	if not NetworkManager.is_server():
		return
	match state:
		State.DEAD:
			return  # 已死亡：医疗无效
		State.DOWN:
			_clear_active_revive()
			state = State.ALIVE
			hp = maxf(amount, REVIVE_HP)  # 医疗包 ≥ 复活保底血量
		State.ALIVE:
			hp = hp + amount  # setter 钳制到 max_hp


## 所属玩家的 peer id（本节点权威已设为服务器，故从父节点 Player 取）
func owner_peer_id() -> int:
	var parent := get_parent()
	if parent == null:
		return NetworkManager.SERVER_ID
	return parent.get_multiplayer_authority()


## 玩家根节点位置（本状态节点挂 Player 下；Player 是 Node3D 才有 global_position）
func _player_global_position() -> Vector3:
	var player := get_parent() as Node3D
	return player.global_position if player != null else Vector3.ZERO


# --- 救援请求（any_peer：客户端→服务器，tech-plan §4.4） ---

## 客户端→服务器：救援者请求救援目标玩家（target_peer_id = 目标所属 peer）
@rpc("any_peer", "call_local", "reliable")
func request_revive(target_peer_id: int) -> void:
	if not NetworkManager.is_server():
		return
	var sender: int = multiplayer.get_remote_sender_id()
	if owner_peer_id() != sender:
		return  # 防御：调用者必须是被救援请求来源玩家本人
	var target := _find_by_peer(target_peer_id)
	if target != null:
		target.try_start_revive(self)


## 客户端→服务器：救援者松开 E，取消救援
@rpc("any_peer", "call_local", "reliable")
func cancel_revive() -> void:
	if not NetworkManager.is_server():
		return
	var sender: int = multiplayer.get_remote_sender_id()
	if owner_peer_id() != sender:
		return
	cancel_active_revive(self)


# --- 救援逻辑（服务器权威） ---

## 服务器：尝试开始救援（由 request_revive 转发到目标 PlayerState）
func try_start_revive(reviver: PlayerState) -> void:
	if not NetworkManager.is_server():
		return
	if state != State.DOWN:
		return
	if reviver == null or reviver.state != State.ALIVE:
		return
	if _player_global_position().distance_to(reviver._player_global_position()) > REVIVE_RANGE:
		return
	_active_revive_reviver = reviver
	_revive_timer = 0.0
	revive_started.rpc(owner_peer_id(), reviver.owner_peer_id())


## 服务器：救援者主动取消（松开 E）
func cancel_active_revive(reviver: PlayerState) -> void:
	if not NetworkManager.is_server():
		return
	if _active_revive_reviver == reviver:
		_clear_active_revive()
		revive_cancelled.rpc(owner_peer_id())


## 服务器：单机调试——无队友实体时由服务器进程执行"自己救自己"（C5 验证用；M2 移除）
func _debug_self_revive() -> void:
	if not NetworkManager.is_server():
		return
	if state != State.DOWN:
		return
	_debug_self_revive_mode = true
	_active_revive_reviver = self
	_revive_timer = 0.0
	revive_started.rpc(owner_peer_id(), owner_peer_id())


## 服务器：每帧救援计时 + 持续条件校验
func _tick_revive(delta: float) -> void:
	var ok := state == State.DOWN
	if _debug_self_revive_mode:
		pass  # 单机调试：不校验救援者状态/距离
	else:
		var reviver := _active_revive_reviver
		ok = ok and reviver != null and reviver.state == State.ALIVE \
			and _player_global_position().distance_to(reviver._player_global_position()) <= REVIVE_RANGE
	if not ok:
		_clear_active_revive()
		revive_cancelled.rpc(owner_peer_id())
		return
	_revive_timer += delta
	if _revive_timer >= REVIVE_TIME:
		_clear_active_revive()
		state = State.ALIVE
		hp = REVIVE_HP
		revive_done.rpc(owner_peer_id())


func _clear_active_revive() -> void:
	_active_revive_reviver = null
	_revive_timer = 0.0
	_debug_self_revive_mode = false


## 服务器：按 peer 找玩家 PlayerState（players 组，玩家根节点权威=peer）
func _find_by_peer(peer_id: int) -> PlayerState:
	for p in get_tree().get_nodes_in_group("players"):
		if p.get_multiplayer_authority() == peer_id:
			return p.get_node_or_null("Health") as PlayerState
	return null


# --- 救援事件广播（authority：本节点权威=服务器，广播到所有端） ---

@rpc("authority", "call_local", "reliable")
func revive_started(_target_peer: int, _reviver_peer: int) -> void:
	revive_active = true
	revive_progress = 0.0


@rpc("authority", "call_local", "reliable")
func revive_cancelled(_target_peer: int) -> void:
	revive_active = false
	revive_progress = 0.0


@rpc("authority", "call_local", "reliable")
func revive_done(_target_peer: int) -> void:
	revive_active = false
	revive_progress = 0.0


## [authority] 服务器→所有人：玩家受击（播放受击音效，3D 定位在玩家位置）
@rpc("authority", "call_local", "reliable")
func player_hurt() -> void:
	var pos := Vector3.ZERO
	var player := get_parent() as Node3D
	if player != null:
		pos = player.global_position
	SfxPool.play_3d("player_hurt", pos)


## 广播玩家受击：**只播给受击玩家自己**（音频方向 §1：受击闷响是"体感"声，队友不需要）；
## 单机（无 peer）直接本地执行
func _broadcast_player_hurt() -> void:
	if NetworkManager.is_network_active():
		player_hurt.rpc_id(owner_peer_id())
	else:
		player_hurt()
