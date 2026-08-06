## zombie_growl.gd — 普通丧尸追踪嘶吼控制器（M3-S7）
## 职责：每丧尸独立随机间隔（3-5s）触发 zombie_growl 音效，仅 Idle/Chase 吼（Attack/Dead 不吼）；
##       服务器计时 + authority 广播全端 3D 播放（3D 定位在丧尸位置）；
##       与 SfxPool EVENT_LIMIT 同帧限流兜底（防 80 只同帧齐吼刷屏，音频方向 §4.5 同发预算）
## 挂接：ZombieAI._ready 动态 add_child（name=GrowlCtrl，幂等重设相位；沿用 Director 动态子节点先例）
## 谁调用：仅服务器执行 _physics_process（is_server）；客户端只收 growl RPC 播放
## 规范：单文件 ≤300 行；不静态引用 ZombieAI 类型（防 M2-S3 加载环，经父节点动态 get("state")）

class_name ZombieGrowl
extends Node

const GROWL_INTERVAL_MIN := 3.0  # 秒，嘶吼最小间隔
const GROWL_INTERVAL_MAX := 5.0  # 秒，嘶吼最大间隔（每丧尸独立随机相位）
## ZombieAI.State 枚举值（不引用父类类型，防加载环；与 zombie_ai_common.gd 定义对齐）
const STATE_IDLE := 0
const STATE_CHASE := 1

var _ai: Node = null
var _body: Node3D = null
var _timer := 0.0


## 由 ZombieAI 调用：绑定父 AI 与丧尸实体，并重置随机相位（每次出池重设）
func setup(ai: Node, body: Node3D) -> void:
	_ai = ai
	_body = body
	_timer = _random_interval()


func _physics_process(delta: float) -> void:
	if _ai == null or _body == null or not NetworkManager.is_server():
		return
	_timer -= delta
	if _timer > 0.0:
		return
	_timer = _random_interval()
	var st: int = int(_ai.get("state"))
	if st != STATE_IDLE and st != STATE_CHASE:
		return  # Attack/Dead 不吼（Attack 由受击/前摇反馈代替）
	_broadcast_growl()  # 全端播放（同帧同事件限流由 SfxPool EVENT_LIMIT 兜底）


func _random_interval() -> float:
	return randf_range(GROWL_INTERVAL_MIN, GROWL_INTERVAL_MAX)


## [authority] 服务器→所有人：本丧尸嘶吼（3D 定位在丧尸位置；素材缺失静默跳过，SfxPool 容错）
@rpc("authority", "call_local", "reliable")
func growl() -> void:
	SfxPool.play_3d("zombie_growl", _body.global_position)


func _broadcast_growl() -> void:
	if NetworkManager.is_network_active():
		growl.rpc()
	else:
		growl()
