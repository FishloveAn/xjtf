# ADR-001：Godot 4.7.1 + GDScript（不用 C#）

- 状态：定案
- 日期：2026-08-04

## 背景

1 人开发 + AI 协作，3-6 个月周期，局域网 PVE FPS。语言选择决定 AI 协作效率与迭代速度。

## 决策

- 引擎 Godot 4.7.1 stable（4.7.x 最新维护线）。
- 语言 **GDScript**，全项目禁止混用 C#。
- 物理 Jolt（4.4 起 3D 默认），渲染 Forward+（Windows 独享）。

## 结论

GDScript 语料丰富、迭代快、零额外依赖；本场景性能瓶颈在渲染与 AI 预算而非脚本，GDScript 足够。版本钉死在 `project.godot` 与 `docs/项目文档/03-开发/03-开发-引擎版本记录.md`，升级前全量冒烟。
