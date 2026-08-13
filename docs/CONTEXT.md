# CONTEXT.md — 项目领域上下文（agent 必读）

> 项目：《星际土匪》（StarBandit，L4D-like 局域网合作 PVE FPS）
> 引擎：Godot 4.7.1 stable ｜ 语言：GDScript ｜ 平台：Windows ｜ 联机：局域网 4-8 人
> 本文是领域术语与模块地图的速查入口；完整资料见 `docs/项目文档/README-总目录.md`。

## 1. 一句话 + 三大支柱

> 4-8 名玩家组成幸存者小队，在 Low Poly 废土中穿越一波波丧尸潮，靠搜刮、救援与互相支援，从安全屋推进到安全屋。

| 支柱 | 一句话 | 落地含义 |
|---|---|---|
| P1 合作的重量 | 玩家互为救命稻草，独自行动必死 | 救援/资源共享必须可靠联机同步；玩家轮廓可辨识 |
| P2 可控的恐惧曲线 | 紧张来自可预期节奏，非贴脸惊吓 | 波次有明确预告与节奏参数 |
| P3 低模即性能预算 | 视觉是性能预算的一部分 | 面数/材质有硬上限，帧率优先于细节 |

## 2. 技术选型（定案，见 docs/adr/）

- Godot **4.7.1 + GDScript**（禁 C#）、Jolt 物理、Forward+ 渲染。
- 多人：**ENet + 内置 MultiplayerAPI**（MultiplayerSynchronizer/Spawner/@rpc），**Listen Server（主机权威）**。
- 服务器是唯一真相源：血量/伤害/刷怪/波次/掉落/胜负全走服务器；玩家位移客户端预测 + 服务器宽松校验。
- 数据驱动：`data/*.json` 存数值（weapons/zombies/waves/director）。

## 3. 领域术语表

| 术语 | 含义 |
|---|---|
| 幸存者 | 玩家角色，4-8 人合作 |
| 普通丧尸 | 尸潮主力（同屏 30-100），剥骨静态网格 + 代码摆动（无骨骼） |
| 哥布林 | 特感精英（≤5 同屏），带 12 骨骼 + 6 动画；由普通丧尸"双种族并存"决策改造 |
| 冲撞者 / 喷吐者 / 跳跃者 / 自爆者 | 哥布林特感四型（原型 Charger/Spitter/Hunter/Boomer，机制借鉴、名称外观自创） |
| 倒地 / 救援 | 血量归零进入倒地（DOWN），队友 E 键扶起；倒地再受击死亡（DEAD） |
| 波次 | 搜刮期 → 警戒期 → 高潮期的递进节奏，`data/waves.json` 定义 |
| 导演（Director） | 按"压力值"驱动刷怪节奏，`data/director.json` 参数化 |
| 安全屋 | 关卡喘息点（门一关安全）；推进制的段落边界 |
| 铁锈仓库（Rustyard） | 首发关卡，三段式：货场 → 货运通道 → 装卸广场 |
| 补给点 / 掉落物 | 弹药（黄/橙）、医疗（医疗绿）、投掷物补给 |
| 换皮不换网 | 材质 albedo_color 变体区分外观，不复制网格（保合批） |

## 4. 模块地图

```
res://
├── autoload/          # 单例：network_manager（网络生命周期）、game_state（会话状态）
├── scenes/            # 场景 .tscn（main/player/enemies/weapons/environment/ui/fx/gameplay）
├── scripts/           # 脚本 .gd（core/gameplay/ai/weapons/player/enemies/fx/ui）
├── data/              # 纯数据 JSON（weapons/zombies/waves/director/audio_events）
├── assets/            # 美术音频（models/characters|weapons|environment|props、audio、shaders、textures）
├── tools/             # headless 校验/调试脚本（check_model_spec、check_all_*、debug_*、test_*）
└── tests/             # 冒烟测试场景
```

关键系统（详细见 `docs/项目文档/03-开发/03-开发-场景职责总表.md`）：

| 系统 | 脚本 | 职责 |
|---|---|---|
| 联机会话 | `autoload/network_manager.gd` | 建房/加入/断线；`SERVER_ID=1` |
| 玩家 | `scripts/player/player_controller.gd`、`player_state.gd` | 第一人称移动/射击/救援；血量状态机 |
| 战斗 | `scripts/weapons/weapon_base.gd`、`core/hitbox.gd` | hitscan + 数据驱动；服务器复判伤害 |
| 丧尸 AI | `scripts/ai/zombie_ai_common.gd`、`zombie_ai_special.gd` | 三态/多态状态机；仅服务器跑 |
| 波次/导演 | `scripts/gameplay/wave_manager.gd`、`director.gd` | 波次状态机 + 压力值刷怪 |
| 物资 | `scripts/gameplay/*_supply.gd`、`pickup_item.gd` | 补给点/掉落物拾取 |

## 5. 核心规则（铁律，违反即返工）

1. **服务器权威**：伤害/扣血/扣弹药/刷怪/波次/拾取五类操作只准走服务器。
2. **RPC 规范**：请求 `@rpc("any_peer","call_local","reliable")` + 校验来源；广播 `@rpc("authority",...)`；服务器 id 用 `NetworkManager.SERVER_ID`，禁写死 `1`。
3. **数据驱动**：调数值改 `data/*.json`，脚本只读 + 应用。
4. **文件纪律**：单文件 ≤300 行；一个场景一个职责；snake_case；禁 move/rename（.tscn 是绝对路径）。
5. **美术铁律**：材质 ≤2/模型；CC0 逐条记账（`CREDITS/`）；换皮不换网；可交互物暖色系、蓝紫留给环境。
6. **性能预算**：主机 60 FPS 第一优先；普通丧尸 ≤1200 tris、特感 2000-4000、玩家 ≤3000；同屏丧尸 ≤100（特感 ≤5）。

## 6. 权威文档入口

- 术语与意图 → `docs/项目文档/01-需求分析/01-需求分析-游戏概念文档.md`
- 架构决策 → `docs/adr/`
- 技术地基 → `docs/项目文档/02-设计/02-设计-技术方案.md`
- 美术规格 → `docs/项目文档/02-设计/02-设计-美术方向.md`、`02-设计-美术-替换清单-M3.md`
- 文档总目录 → `docs/项目文档/README-总目录.md`
