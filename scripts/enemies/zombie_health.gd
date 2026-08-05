## zombie_health.gd — 普通丧尸血量（服务器权威）
## 职责：hp/max_hp、take_damage（受击 emit damaged、hp<=0 → emit died，AI 监听 died 进 Dead）
## 输入：武器 hitscan（S3/S4）经 Hitbox.apply_hit 调用 take_damage(dmg, attacker)
## 输出：damaged/died 信号（服务器侧；客户端不读丧尸血量，死亡表现由 S6 接）
## 谁调用：仅服务器结算（tech-plan §4.2 伤害服务器权威）；客户端不直接调用
## 规范：extends Damageable（统一伤害接口）；hp 默认 100（对应 weapons.json 平衡：手枪 4 枪、霰弹近身 1 枪）

class_name ZombieHealth
extends Damageable

@export var max_hp := 100.0

## 当前血量（服务器权威）
var hp := 100.0


func take_damage(dmg: float, attacker: Node = null) -> void:
	if not NetworkManager.is_server():
		push_warning("zombie_health.take_damage 仅服务器调用，已拒绝")
		return
	if hp <= 0.0:
		return  # 已死
	hp = maxf(hp - dmg, 0.0)
	damaged.emit(dmg, attacker, hp)
	if hp <= 0.0:
		died.emit(attacker)
