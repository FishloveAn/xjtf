## test_zombie_ai.gd — 丧尸 AI 独立调试场景脚本
## 职责：单机直跑，刷 ZOMBIE_COUNT 只丧尸验证三态 AI 与分帧预算（冒烟 C4 加压可选）
## 谁调用：tests/scenes/test_zombie_ai.tscn 根节点
## 规范：tech-plan §8.5 独立调试场景；不依赖主流程即可验证

extends Node3D

const ZOMBIE_SCENE := preload("res://scenes/enemies/zombie_common.tscn")
const ZOMBIE_COUNT := 10


func _ready() -> void:
	var zombies := $Zombies
	for i in ZOMBIE_COUNT:
		var z: Node3D = ZOMBIE_SCENE.instantiate()
		z.set_multiplayer_authority(NetworkManager.SERVER_ID)  # 服务器权威（单机=本进程）
		var angle := TAU * i / ZOMBIE_COUNT
		z.global_position = Vector3(cos(angle) * 6.0, 0.0, sin(angle) * 6.0)
		zombies.add_child(z)
