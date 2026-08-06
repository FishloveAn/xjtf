## scoreboard.gd — 结算计分板/幸存统计（M3-S6；HUD 外独立界面）
## 职责：段落完成/游戏结束（服务器 GameState.finish_segment）→ 订阅 scoreboard_requested
##       信号（authority RPC 全端驱动）→ 只读展示 击杀（普通/特感分列）/救援数/倒地次数/
##       段落用时；显示时释放鼠标（玩家可看统计后按 Enter/Esc 继续）
## 输入：GameState.scoreboard_requested(data)（服务器结算广播，本端信号触发）
## 输出：无（纯展示，不写任何玩法数据；UI 不持有游戏状态，tech-plan §3.1）
## 谁调用：main.tscn 场景根下的 CanvasLayer（默认隐藏）；GameState 广播驱动显示
## 规范：只读展示；显示期间鼠标释放（结算需读屏幕）；重开/切换场景自动随节点释放

extends CanvasLayer

@onready var _root: Control = $Root
@onready var _kills_common: Label = $Root/Panel/VBox/KillsCommon
@onready var _kills_special: Label = $Root/Panel/VBox/KillsSpecial
@onready var _revives: Label = $Root/Panel/VBox/Revives
@onready var _downs: Label = $Root/Panel/VBox/Downs
@onready var _time: Label = $Root/Panel/VBox/TimeLabel
@onready var _hint: Label = $Root/Panel/VBox/Hint


func _ready() -> void:
	# 订阅结算信号（GameState autoload 常驻；独立实例化无 GameState 时静默跳过）
	GameState.scoreboard_requested.connect(_on_scoreboard)
	visible = false


## 结算数据显示（本端由服务器广播驱动；单机 call_local 直接触发）
func _on_scoreboard(data: Dictionary) -> void:
	_kills_common.text = "普通丧尸击杀：%d" % int(data.get("kills_common", 0))
	_kills_special.text = "特感击杀：%d" % int(data.get("kills_special", 0))
	_revives.text = "救援次数：%d" % int(data.get("revives", 0))
	_downs.text = "倒地次数：%d" % int(data.get("downs", 0))
	_time.text = "段落用时：%.1f 秒" % float(data.get("segment_time_s", 0.0))
	visible = true
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE  # 结算读屏：释放鼠标（玩家按 Enter/Esc 继续）
	print("[Scoreboard] 结算展示：%s" % str(data))
