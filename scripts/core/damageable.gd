## damageable.gd — 统一伤害接口（抽象基类，core 层）
## 职责：定义"可受伤对象"的最小契约：take_damage() 入口 + damaged/died 信号；
##       玩家（PlayerState）与丧尸（S5 zombie Health）都继承本类，武器/近战只面向本接口结算
## 输入：武器 hitscan（S3）/ 丧尸近战（S5）调用 take_damage(dmg, attacker)
## 输出：damaged(dmg, attacker, new_hp) / died(attacker) 信号
## 谁调用：仅服务器调用（tech-plan §4.2 伤害结算全在服务器）；客户端只读同步值
## 规范：core 层零热路径分配；子类必须重写 take_damage()

class_name Damageable
extends Node

## 受击信号：dmg=本次伤害，attacker=攻击者，new_hp=结算后血量（服务器侧发出）
signal damaged(dmg: float, attacker: Node, new_hp: float)
## 死亡信号：血量归零时发出（attacker=最后一击来源）
signal died(attacker: Node)

## 子类必须实现：结算一次伤害。非服务器调用由子类拒绝（防御，见 player_state.gd）
func take_damage(_dmg: float, _attacker: Node = null) -> void:
	push_error("Damageable.take_damage() 未在子类实现: %s" % get_path())
