## hit_feedback.gd — 命中/死亡特效触发（血雾 GPUParticles3D）
## 职责：在命中点生成一次性血雾粒子（预算内：粒子少、生命周期短）；结束后自动清理防泄漏
## 输入：weapon_base.hit_confirmed（客户端收到服务器广播后）调用 spawn_blood_puff(parent, world_pos)
## 输出：在 parent（世界节点，如 current_scene）下生成 blood_puff.tscn 实例并一次性播放
## 谁调用：客户端（**不本地猜命中**，只响应服务器 hit_confirmed 广播，tech-plan §4.4）；服务器 call_local（主机视角）
## 规范：血雾预算内（amount=12、lifetime=0.6s，不做大爆炸特效）；粒子结束（finished）即 queue_free

class_name HitFeedback
extends RefCounted

const BLOOD_PUFF_SCENE := preload("res://scenes/fx/blood_puff.tscn")


## 在 world_pos 生成一次性血雾；parent 需是世界节点（如 get_tree().current_scene）
static func spawn_blood_puff(parent: Node3D, world_pos: Vector3) -> void:
	if parent == null:
		return
	var puff := BLOOD_PUFF_SCENE.instantiate() as GPUParticles3D
	if puff == null:
		return
	puff.global_position = world_pos
	parent.add_child(puff)
	puff.restart()
	if puff.one_shot:
		puff.finished.connect(_free_puff.bind(puff))


static func _free_puff(puff: Node) -> void:
	if is_instance_valid(puff):
		puff.queue_free()
