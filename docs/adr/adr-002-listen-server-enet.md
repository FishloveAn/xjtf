# ADR-002：Listen Server + ENet + 内置 MultiplayerAPI

- 状态：定案
- 日期：2026-08-04

## 背景

局域网 4-8 人合作 PVE，需要低延迟、易维护的多人方案。

## 决策

- 拓扑 **Listen Server（主机权威）**：主机 = 服务器 + 玩家 1，同一进程跑全部游戏逻辑。
- 底层 **ENetMultiplayerPeer**（内置），高层 **MultiplayerSynchronizer / MultiplayerSpawner / @rpc**。
- 不引第三方（WebSocket/Nakama/Steamworks 均不需要）；不建独立服务器进程（优化期可选无头主机）。

## 结论

服务器是唯一真相源；客户端只发请求、只收广播。局域网带宽宽裕，官方组件 + ENet 覆盖全部需求。
