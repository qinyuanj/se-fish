# 0040 本地模拟多人不可用，多人验收必须真实第二客户端

**Status**: accepted（2026-11-20 取证，2026-11-24 收口为能力事实型 ADR）

单客户端试玩是日常开发主路径，多人功能却必须有两个真实玩家才谈得上验收。本 ADR 只记钉子版本上的取证事实与验收边界，不对「官方是否另有未公开入口」下结论。

## 版本钉子

- 编辑器 `1.0.37`（`1.0.37(1794484929.37d345623a.4478607.37-0)`）；`editor-cli 0.20.17`（commit `184bb04`）。
- 版本变化即按本节重新取证。

## 取证范围

- **已查**：`editor-cli 0.20.17` 完整帮助（含 `--include-internal`、`play`、`input`、`exec`）、`docs search`（SE `manual` / `game-api`）、官方多开/实时共建公告与教程、`C:\FeverApps\party_pc` 可读文本及编辑器界面截图。
- **未查**：编辑器二级下拉菜单、`.npk` 打包资源与二进制反编译、双编辑器实例同房多开实验、真实多人房内 `play input --player` / `exec --player` 路由行为。

## 结论

- **`play start` 无人数或机器人参数**，总帮助亦无添加玩家、机器人或本地多人房间命令。
- **`play input --player` / `exec --player` 只能选择已有玩家**，不能创建玩家；`play input` 的 `--duration-ms` 上限为 5000。
- **`Player` 不能自行创建**（官方 API 明确只能从 `Players` 获取）。
- **NPC（`EggyUnit`）不能替代真实玩家**：不进 `Players:GetPlayers()`，无真实 `UserId`、独立客户端连接与网络所有权，覆盖不了 `PlayerAdded`/`PlayerRemoving`、双端 UI、输入路由与随进随出。
- **PC 编辑器多开用于多地图对照/协同编辑**，未说明可生成多游戏客户端或真实 `Player`；官方教程明确多人项需实际联机环境。

## 验收后果

- 多人条款的证据只能是**真实第二客户端**（或真实多人测试房间）；单客户端服务端逻辑或高仿真 NPC 只证明代码路径/单位级行为，不得写为「本地模拟多人已通过」。
- 缺少第二客户端时，多人条款按 [ADR-0039](0039-acceptance-surface-as-feature-files.md) 保持 `unverified` / `blocked`，本地可验证部分按 [ADR-0029](0029-scope-completeness-and-placeholder-first.md) 先行闭环，真实多人验收单列进[生产开关台账](../acceptance/production-switches.md)。
