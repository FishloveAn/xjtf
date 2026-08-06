## hud.gd — 极简 HUD（S3：血条 + 弹药 + 倒地提示 + 救援进度 + 死亡黑屏；M2-S1：波次预告/播报条；S4：拾取提示）
## 职责：只读展示本地玩家的血量/弹药/状态/救援进度；订阅 WaveManager 波次事件只读展示；
##       检测附近补给点显示"按 E 拾取"提示（UI 不持有游戏状态，tech-plan §3.1）
## 输入：players 组找本地玩家 → 读 PlayerState.hp/state/revive_progress、WeaponBase 弹药；
##       Gameplay/WaveManager 的 event_* 信号（服务器广播触发）；supply_points 组找附近补给点
## 输出：无（纯展示，不写任何玩法数据）
## 谁调用：main.tscn 场景根下的 CanvasLayer；每帧 _process 刷新

extends CanvasLayer

@onready var _health_bar: ProgressBar = $Root/HealthBar
@onready var _health_label: Label = $Root/HealthLabel
@onready var _ammo_label: Label = $Root/AmmoLabel
@onready var _downed_label: Label = $Root/DownedLabel
@onready var _revive_bar: ProgressBar = $Root/ReviveBar
@onready var _dead_overlay: ColorRect = $Root/DeadOverlay
@onready var _wave_banner: Label = $Root/WaveBanner
@onready var _wave_countdown: Label = $Root/WaveCountdown
@onready var _wave_toast: Label = $Root/WaveToast
@onready var _pickup_hint: Label = $Root/PickupHint
@onready var _special_warn: Label = $Root/SpecialWarn

## 波次 Setup 倒计时展示（纯展示本地动画；波次是否开始由服务器 wave_begun 广播决定）
var _display_countdown := 0.0
var _last_display_secs := -1


func _ready() -> void:
	# 订阅波次事件（只读展示；WaveManager 服务器权威广播驱动）。
	# 独立实例化 HUD（如测试场景）时 WaveManager 不存在，静默跳过
	var wm := get_node_or_null("../Gameplay/WaveManager") as WaveManager
	if wm == null:
		return
	wm.event_wave_started.connect(_on_wave_started)
	wm.event_wave_begun.connect(_on_wave_begun)
	wm.event_wave_cleared.connect(_on_wave_cleared)
	wm.event_intermission_started.connect(_on_intermission_started)
	wm.event_victory.connect(_on_victory)


func _process(delta: float) -> void:
	_tick_wave_countdown(delta)
	var player := _get_local_player()
	if player == null:
		_hide_all()
		return
	var state := player.get_node_or_null("Health") as PlayerState
	if state == null:
		_hide_all()
		return
	_health_bar.visible = true
	_health_bar.max_value = state.max_hp
	_health_bar.value = state.hp
	_health_label.text = "%d / %d" % [int(state.hp), int(state.max_hp)]
	# 弹药：读本地玩家当前武器（服务器权威同步值）；换弹中显示提示
	var weapon := _get_active_weapon(player)
	if weapon != null:
		_ammo_label.visible = true
		if weapon.reloading:
			_ammo_label.text = "%s 换弹中…" % weapon.display_name
		else:
			_ammo_label.text = "%s  %d / %d" % [weapon.display_name, weapon.mag_current, weapon.mag_size]
	else:
		_ammo_label.visible = false
	# 状态提示：倒地 → 黄字提示；死亡 → 全屏黑幕
	_downed_label.visible = state.state == PlayerState.State.DOWN
	_dead_overlay.visible = state.state == PlayerState.State.DEAD
	# 救援进度：仅倒地且救援中显示（目标侧可见；服务器广播驱动，纯展示）
	_revive_bar.visible = state.state == PlayerState.State.DOWN and state.revive_active
	if _revive_bar.visible:
		_revive_bar.value = state.revive_progress * _revive_bar.max_value
	# S4 拾取提示：附近有补给点显示"按 E 拾取"（只读检测，不持有补给点状态）
	var supply := _find_nearby_supply(player)
	_pickup_hint.visible = supply != null
	if supply != null:
		var type_name := "弹药" if supply.supply_type == SupplyPoint.Type.AMMO else "医疗"
		_pickup_hint.text = "按 E 拾取 %s" % type_name
	# M3-S2 冲撞者前摇警示（可选表现，简单为主）：15m 内冲撞者处于蓄力（WINDUP=2）→ 提示
	_tick_special_warn(player)


func _hide_all() -> void:
	_health_bar.visible = false
	_ammo_label.visible = false
	_downed_label.visible = false
	_revive_bar.visible = false
	_dead_overlay.visible = false
	_pickup_hint.visible = false
	_special_warn.visible = false


## 找本机玩家（players 组中 is_multiplayer_authority() 为真的那个；单机即唯一玩家）
func _get_local_player() -> Node3D:
	for p in get_tree().get_nodes_in_group("players"):
		if p.is_multiplayer_authority():
			return p as Node3D
	return null


## 找当前激活武器（WeaponPivot 下 visible 的那把；激活标记由 player_controller 切枪维护）
func _get_active_weapon(player: Node3D) -> WeaponBase:
	var pivot := player.get_node_or_null("WeaponPivot")
	if pivot == null:
		return null
	for child in pivot.get_children():
		var w := child as WeaponBase
		if w != null and w.visible:
			return w
	return null


## 找本地玩家拾取范围内最近的补给点（只读检测，显示"按 E 拾取"提示；与玩家控制器同判定半径）
func _find_nearby_supply(player: Node3D) -> SupplyPoint:
	var best: SupplyPoint = null
	var best_dist := SupplyPoint.PICKUP_RANGE
	for s in get_tree().get_nodes_in_group("supply_points"):
		var dist := player.global_position.distance_to(s.global_position)
		if dist <= best_dist:
			best_dist = dist
			best = s as SupplyPoint
	return best


## M3-S2 冲撞者前摇警示：15m 内冲撞者处于蓄力（WINDUP=2，见 zombie_ai_charger.gd）→ 红字提示
func _tick_special_warn(player: Node3D) -> void:
	var show := false
	for c in get_tree().get_nodes_in_group("zombie_specials"):
		var ai := c.get_node_or_null("AI")
		if ai != null and int(ai.get("state")) == 2 \
				and player.global_position.distance_to(c.global_position) <= 15.0:
			show = true
			break
	_special_warn.visible = show


# --- 波次预告/播报（只读展示，服务器广播驱动；不持有游戏状态） ---

func _on_wave_started(wave_index: int, wave_name: String, countdown: float) -> void:
	_wave_banner.text = "第 %d 波：%s" % [wave_index + 1, wave_name]
	_wave_banner.visible = true
	_display_countdown = countdown
	_last_display_secs = -1
	_wave_countdown.text = "%d 秒后开始" % int(ceil(countdown))
	_wave_countdown.visible = true
	_wave_toast.visible = false


## Setup 倒计时本地动画（纯展示；真实开波由服务器 wave_begun 广播驱动）
func _tick_wave_countdown(delta: float) -> void:
	if not _wave_countdown.visible or _display_countdown <= 0.0:
		return
	_display_countdown -= delta
	var secs := int(ceil(_display_countdown))
	if secs != _last_display_secs:
		_last_display_secs = secs
		_wave_countdown.text = "%d 秒后开始" % maxi(secs, 0)


func _on_wave_begun(_wave_index: int) -> void:
	_wave_banner.visible = false
	_wave_countdown.visible = false


func _on_wave_cleared(wave_index: int, wave_name: String) -> void:
	_wave_toast.text = "第 %d 波 %s 完成！" % [wave_index + 1, wave_name]
	_wave_toast.visible = true


func _on_intermission_started(countdown: float) -> void:
	_wave_toast.text = "休整中 %d 秒（按 N 提前开始）" % int(countdown)
	_wave_toast.visible = true


func _on_victory() -> void:
	_wave_banner.text = "通关！全部波次完成"
	_wave_banner.visible = true
	_display_countdown = 0.0  # 停止倒计时动画，保留"按 Enter 再来一局"
	_wave_countdown.text = "按 Enter 再来一局"
	_wave_countdown.visible = true
	_wave_toast.visible = false
