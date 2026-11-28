# 0044 编辑器原生支持本地多客户端试玩与试玩内 AI 角色切换

**Status**: accepted（2026-11-28；取代 [ADR-0040](0040-local-multiplayer-not-simulatable-in-editor.md)）

[ADR-0040](0040-local-multiplayer-not-simulatable-in-editor.md) 此前依据 `editor-cli 0.20.17` 帮助、编辑态 API 和公开手册，认定本地编辑器无法模拟多人，同时在「未查」一节留出「编辑器二级下拉菜单」。2026-11-28 经编辑器界面实证，SE 编辑器原生提供两项本地多人试玩能力，推翻 ADR-0040 关于「本地完全无法模拟多人、多人功能必须外部第二账号入房」的前提。

## 能力事实（2026-11-28 实证）

1. **试玩前：本地多人测试（多独立客户端窗口）**。编辑器顶部工具栏 **测试** 下拉菜单的 **测试** 页签包含 **本地多人测试** 与 **共建多人测试** 两项入口。**本地多人测试** 可在启动前设定客户端数量（例如 2），点击 **开始** 后运行多个独立客户端窗口进入同一试玩会话。
2. **试玩中：调试插件添加 AI 与切换角色控制器**。进入试玩后，顶部工具栏 **调试插件** 下拉菜单的 **AI** 子菜单提供 **添加AI** 与 **切换AI**。开发者可在试玩运行期动态增加 AI 角色，并切换角色控制器操控不同角色。
3. **CLI 与编辑态 API 边界（`editor-cli 0.20.20` 实测）**。本机 `editor-cli 0.20.20` 的 `play start`、`--help --include-internal` 以及在线编辑器的 `Editor.RunGame` 仍只触发单客户端试玩，尚未暴露上述两项界面入口的命令行或 Lua 自动化启动参数。能力缺口在自动化启动层，不在编辑器运行时。

## 决定

- **本地多人测试作为多客户端联调与 C 级观察主路径**。多端 HUD 布局、2 米邀请交互、安全区与 PK 边界、他人抢救、双端 `RemoteEvent` 收发等单机可观测的多人功能，优先通过编辑器 **本地多人测试** 的多独立窗口验证，不再因缺少外部第二账号而默认记为 `blocked`。
- **调试插件 AI 作为单窗口快速交互调试路径**。单人开发期可用 **添加AI** 与 **切换AI** 快速验证多人站位与角色切换操作；该能力是否能用于正式 C 级取证，待首轮运行时探针钉死其 `Player` 与网络身份语义后再定。
- **保留四层边界，不混用证明口径**。
  - 离线多连接夹具（`tests/support/local_link.lua` 与 `tests/probes/local_link_runtime.lua`）继续承担 8 到 10 连接规模的 A/B 级全自动回归，不被手工多窗口替代。
  - 仍禁止用业务脚本 `World:CreateUnit` 生成的 `EggyUnit` NPC 冒充真实玩家。
  - 真实平台容量（8 人以上真实并发）、真实多账号存档限流与跨设备网络环境，仍归 [生产开关台账](../acceptance/production-switches.md) 第 7、10 项，不得用本地双客户端窗口宣称容量已验收（与 [证据分级](../acceptance/evidence-levels.md) 一致）。

## 待首轮探针钉死的运行时语义

落地新多人测试流程前，须在编辑器内分别对两种模式各跑一次探针并回写结论。

- **本地多人测试（2 窗口）**：各窗口是否各自进入 `Players:GetPlayers()` 并拥有唯一 `UserId`、独立 `LocalPlayer` 与独立存档键；多窗口下 `editor-cli exec --platform client --player`、`play input --player` 以及 `lua tools/cli.lua screenshot` 的多窗口选择行为。
- **调试插件（添加AI / 切换AI）**：**添加AI** 生成的角色是否进入 `Players:GetPlayers()` 并触发 `PlayerAdded`；**切换AI** 是否同步切换客户端 `LocalPlayer`、`ClientStore` 以及服务端 `RemoteEvent` 收到的发送者 `player`。

## 后果

- [ADR-0040](0040-local-multiplayer-not-simulatable-in-editor.md) 状态改为 `superseded by ADR-0044`。
- 下游工具链与验收文档（`docs/agents/editor-cli.md`、`.agents/skills/verify-se-fish/`、`docs/acceptance/production-switches.md`）按本 ADR 与首轮探针结果分步更新。
- 本地多客户端启动当前仍需经编辑器 UI 点击一次 **本地多人测试 → 开始**；`editor-cli` 后续版本若开放对应参数，再补自动化启动路径。
