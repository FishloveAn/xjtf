## muzzle_flash.gd — 枪口火光（第一人称本地视觉，美术方向 §3.6/§5.1）
## 职责：短暂显示发光 quad（billboard 朝向相机）+ 暖色点光，寿命约 0.06s 后自动释放
## 输入：weapon_base._spawn_muzzle_flash 在本地开火时实例化（挂 current_scene，世界坐标枪口点）
## 输出：点光能量随寿命衰减，结束 queue_free（一次性，寿命极短，不池化）
## 谁调用：仅本地玩家开火视觉（weapon_base._on_fire_visual）；远端玩家看不到本地枪口火光（视觉层本地化）

extends Node3D

const LIFETIME := 0.06

var _t := 0.0
var _light: OmniLight3D


func _ready() -> void:
	_light = get_node_or_null("Light") as OmniLight3D
	# 随机滚转 + 轻微缩放变化，避免每次开火火光千篇一律
	rotation.z = randf_range(0.0, TAU)
	var s := randf_range(0.8, 1.2)
	scale = Vector3(s, s, s)


func _process(delta: float) -> void:
	_t += delta
	if _light != null:
		_light.light_energy = maxf(0.0, 1.5 * (1.0 - _t / LIFETIME))
	if _t >= LIFETIME:
		queue_free()
