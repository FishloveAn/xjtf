## door.gd — 安全屋门（M3-S5 推进制）
## 职责：关卡门（当前为开场安全屋门）。初始关闭（可碰撞=暂时安全）；LevelAdvance 检测到玩家
##       靠近出门触发体 → door_opened 广播 → 所有端隐藏网格并禁用碰撞（门"开启"，可通行）。
## 输入：LevelAdvance（服务器）调用 door_opened.rpc()；单机直接调用 door_opened()
## 输出：开门状态（视觉隐藏 + 碰撞禁用）；注册 "safe_doors" 组供 LevelAdvance 查找
## 谁调用：rustyard.tscn 摆放；LevelAdvance 推进状态机（服务器权威，authority 广播）
## 规范：服务器权威门状态（tech-plan §4.4）；authority RPC call_local 覆盖主机视角

class_name Door
extends StaticBody3D

## 是否已开启（服务器权威；客户端只收广播）
var is_open := false

@onready var _mesh: MeshInstance3D = $Mesh


func _ready() -> void:
	add_to_group("safe_doors")
	set_multiplayer_authority(NetworkManager.SERVER_ID)


## [authority] 服务器→所有人：开门（所有端隐藏门 + 禁用碰撞）
@rpc("authority", "call_local", "reliable")
func door_opened() -> void:
	if is_open:
		return
	is_open = true
	_mesh.visible = false
	collision_layer = 0
	collision_mask = 0
