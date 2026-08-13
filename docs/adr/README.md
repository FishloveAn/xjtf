# 架构决策记录（ADR）

> 记录本项目的关键架构取舍。每条决策独立成文，格式：状态 / 日期 / 背景 / 决策 / 结论。
> 术语与意图见根目录 `CONTEXT.md`；完整技术地基见 `docs/项目文档/02-设计/02-设计-技术方案.md`。

## 索引

| ADR | 决策 | 状态 |
|---|---|---|
| [ADR-001](adr-001-godot-gdscript.md) | Godot 4.7.1 + GDScript（不用 C#） | 定案 |
| [ADR-002](adr-002-listen-server-enet.md) | Listen Server + ENet + 内置 MultiplayerAPI | 定案 |
| [ADR-003](adr-003-player-prediction.md) | 玩家位移 = 客户端预测 + 服务器宽松校验 | 定案 |
| [ADR-004](adr-004-zombie-server-ai.md) | 丧尸 AI 只在服务器跑，客户端快照 + 插值 | 定案 |
| [ADR-005](adr-005-no-host-migration.md) | MVP 不做主机迁移 | 定案 |
| [ADR-006](adr-006-common-zombie-animation.md) | 普通丧尸动画（剥骨静态 + 代码摆动；MultiMesh 延后） | 定案（有修订） |
| [ADR-007](adr-007-hitscan-data-driven.md) | 武器 = hitscan + 数据驱动（JSON） | 定案 |
| [ADR-008](adr-008-smoke-testing.md) | 测试 = 冒烟清单 + 调试控制台（先不做单测） | 定案 |
