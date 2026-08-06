## game_state.gd — 会话统计（M3-S6；tech-plan §2.1 autoload/game_state.gd）
## 职责：击杀（普通/特感分列）/救援数/倒地次数/段落用时 的服务器权威累加与结算广播；
##       main.tscn 进入时 reset_session() 开新会话；段落完成/游戏结束时 finish_segment()
##       组装统计快照 → scoreboard_requested 信号广播（authority RPC）→ 计分板只读展示
## 输入：zombie_ai 死亡回调（经 LootManager.on_zombie_died）调 register_zombie_kill；
##       player_state 救援完成/倒地调 register_revive / register_down；
##       level_advance/wave_manager 段落完成/通关调 finish_segment
## 输出：scoreboard_requested(data) 信号（全端，由 broadcast_scoreboard authority RPC 驱动）
## 谁调用：仅服务器累加（tech-plan §4.2 统计服务器权威，客户端只读展示）
## 规范：autoload 跨场景常驻，重开对局必须 reset_session()（main.gd 负责）；
##       单机（无 peer）走 call_local 直接触发，多人走 authority RPC 全端一致

extends Node

## 计分板数据就绪信号：data = {kills_common/kills_special/revives/downs/segment_time_s}
signal scoreboard_requested(data: Dictionary)

var kills_common := 0    # 普通丧尸击杀数
var kills_special := 0   # 特感（冲撞者/喷吐者）击杀数
var revives := 0         # 救援完成数（倒地玩家被救起）
var downs := 0           # 玩家倒地次数（ALIVE→DOWN 每次计入）
var segment_time_s := 0.0  # 段落/本局通关用时（秒，finish_segment 结算）
var session_start_time := 0.0


func _ready() -> void:
	# 统计节点权威=服务器：authority RPC（broadcast_scoreboard）服务器可发，客户端调用被忽略
	set_multiplayer_authority(NetworkManager.SERVER_ID)
	reset_session()


## 新会话清零（main.tscn 进入时调用；autoload 跨场景，重开对局必须重置）
func reset_session() -> void:
	kills_common = 0
	kills_special = 0
	revives = 0
	downs = 0
	segment_time_s = 0.0
	session_start_time = Time.get_ticks_msec() / 1000.0


# --- 服务器权威累加（仅服务器；客户端不得调用） ---

## 服务器：丧尸击杀登记，按类型分列（普通/特感）
func register_zombie_kill(ztype: String) -> void:
	if not NetworkManager.is_server():
		return
	if ztype == "common":
		kills_common += 1
	else:
		kills_special += 1


## 服务器：救援完成登记（玩家被救起）
func register_revive() -> void:
	if not NetworkManager.is_server():
		return
	revives += 1


## 服务器：玩家倒地登记（ALIVE→DOWN）
func register_down() -> void:
	if not NetworkManager.is_server():
		return
	downs += 1


## 服务器：段落/游戏结束结算。elapsed_s<0 时自动取会话用时；组装快照并全端广播计分板
func finish_segment(elapsed_s: float = -1.0) -> void:
	if not NetworkManager.is_server():
		return
	if elapsed_s < 0.0:
		elapsed_s = Time.get_ticks_msec() / 1000.0 - session_start_time
	segment_time_s = elapsed_s
	var data := {
		"kills_common": kills_common,
		"kills_special": kills_special,
		"revives": revives,
		"downs": downs,
		"segment_time_s": roundf(segment_time_s * 100.0) / 100.0,
	}
	if NetworkManager.is_network_active():
		broadcast_scoreboard.rpc(data)
	else:
		broadcast_scoreboard(data)


## [authority] 服务器→所有人：结算快照广播（客户端触发 scoreboard_requested 供计分板展示）
@rpc("authority", "call_local", "reliable")
func broadcast_scoreboard(data: Dictionary) -> void:
	scoreboard_requested.emit(data)
