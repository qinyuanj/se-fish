# 蛋仔 SE 宿主集成

落地细节见 spoke 仓库的 `docs/integration-best-practices.md` 与 `docs/eggy-host-integration-guide.md`，范式决策见 ADR 0002、0004、0009、0013。目标宿主是 SE（世界编辑器）；原点版（帧同步）是并行编辑器，不是旧版本。集成代码写在本项目里；`common/packages/spoke/` 是从 spoke 仓库镜像来的原始字节，消费方自选 submodule 或纯拷贝，版本都固定到完整上游 commit SHA。

## 部署与加载

消费方脚本工程根下必须物理存在 `common/packages/spoke/`。宿主没有可配置的 `package.path`；`require` 必须带目录前缀、不带 `.lua`、不能跨端，因此包必须落在 `common/` 下才双端可用。目录折叠加载也没有作为契约验证，因此统一使用：

```lua
local spoke = require("common.packages.spoke.api")
```

submodule 由指针固定 SHA，纯拷贝由消费方版本台账固定同一个完整 SHA。每次同步把核心包、使用时的 `spoke_eggy` 与技能按原始字节整包镜像到消费方对应路径，三者同源；技能不进宿主部署树。镜像要清除已删除的旧文件，不能只做增量合并，也不能就地修改副本。文档和脚本使用 PowerShell 7 / Windows 原生形式，保留 LF、无 BOM。

## SE 宿主 API 出处

本技能中的 `game:GetService`、`RunService.Heartbeat`、`TimerService:CreateTimer`、`Unit.Destroying`、`Unit.Name` 与 `Parent` 都是 SE 宿主 API。签名以消费方工程从 SE 导出的 `EggyAPI.lua` 为现场依据，公开手册取证见 spoke 仓库的 `docs/research/se-host-capabilities.md`；按这些证据保留原名称，不按其他平台的字面相似性猜测或替换。

| API | 签名或用途 |
| --- | --- |
| `RunService.Heartbeat` | `Heartbeat:Connect(function(deltaTime) ... end)`；每逻辑帧触发，`deltaTime` 单位为秒 |
| `TimerService:CreateTimer` | `CreateTimer(repeatCount, interval, execute, func)`；创建计时器，不是 Auto 树的驱动 |
| `Unit.Destroying` | `Destroying:Connect(function() ... end)`；无事件参数，用于显式销毁边界 |

`EggyAPI.lua` 是编辑器提示与类型辅助存根，不属于玩法代码，不要在业务脚本里 `require` 它。核心包保持零宿主依赖；这些 API 只落在消费方集成或 `spoke_eggy` 的宿主边界上。`EVENT.REPEAT_TIMEOUT` 是原点版口径；SE 的 Manual 树由消费方用 `Heartbeat` 驱动，Auto 树保持同步 inline flush。

## 默认 Auto-first

每个 EUI 面板、玩法实体或 manager 拥有一棵小的 Auto 树。宿主事件回调修改 State 或 Trigger 后，spoke_runtime 在回调返回前同步完成相关渲染。

Manual 只保留给三种场景：高频写入合并（一帧内多次写同一状态只渲染一次）、大计算分帧（`tree:tick()` 逐步推进）、单步调试。不要为核心添加 `RunService.Heartbeat` 订阅、`TimerService:CreateTimer` 或宿主全局读取。

## 生命周期

- Auto 树 `SpokeTree.spawn` 返回时首帧渲染已经同步完成，不需要额外动作。
- Manual 树 spawn 只同步跑 root Init，通常立即补一次 `tree:flush()` 完成 Effect 挂载；否则早于首帧的宿主事件会撞上尚未挂载的结构（Dock 为 nil）。之后由消费方帧节拍驱动 `tick()` / `flush()`。
- 树要跟随 Unit 的显式销毁（含父级销毁级联）时，用与核心包平级的 `spoke_eggy`：

```lua
local spoke_eggy = require("common.packages.spoke_eggy.api")
local behaviour = spoke_eggy.behaviour(unit, function(s, self)
  -- init 收到 EffectBuilder 与 Behaviour；返回值会被丢弃
end, { name = "Panel" })
```

  `behaviour()` 返回前首帧已经完成。handle 提供 `root`、`is_alive` 和幂等的 `dispose()`：`Destroying` 先把 `is_alive` 设为 false 并刷新仍挂载的 Auto 树，再拆树、断开连接。树名按 `options.name`、非空 `Unit.Name`、`"SpokeBehaviour"` 回落。init 故障留在 `behaviour.root.fault`，不抛给宿主。
- 没有 Unit 生命周期时不要用 `spoke_eggy`，直接 `SpokeTree.spawn`。Manual 树也不进这个包：消费方自己 `spawn_manual`、连接 `Destroying`，并用 `RunService.Heartbeat` 驱动。两种情况下，退出点都要显式 `dispose()`。
- `is_alive` 只表示这次显式销毁。关局、换场景不触发 `Destroying`，包内也没有关局总线；需要那种清理时必须另有已取证触发点。`Destroying` 回调里 `Parent` 可能已是 nil，回调只使用连接时捕获的 handle。

## 组合模式

- 树根常用一个首次挂载后不读信号的 Effect 来搭建子结构，因为 `effect`、`memo`、`phase`、`dock` 组合方法在 EffectBuilder 上，而不在普通 Epoch builder 上。
- join/leave 等结构事件不改变 State 的值，使用静态 Trigger，例如 `s:effect(block, { roster_changed })`；score 等值变化通过 `s:d(state)` 跟踪。
- 在有效挂载窗口内捕获 `local dock = s:dock(...)` 到 upvalue，宿主事件之后调用 `dock:call(id, epoch)` / `dock:drop(id)`。builder 在窗口外密封，Dock 不是。
- 同一事件写多个 State 时，用深 require 的 `spoke_runtime.batch(fn)` 延迟 Auto 树 flush，让同时依赖多个值的 Effect 只看到最外层 release 后的最终组合；普通 State subscriber 仍逐次收到每次写入。
- 共享状态用单例树加 `s:export` / `s:import`（字符串 key）串起来。

## 错误处理

核心已经把用户块 fault 包装、树级停止和 runtime 最终日志边界串起来。宿主侧不要再用 pcall 包住每次 flush 或事件回调；检查 `tree.fault`，需要接管日志时替换 `SpokeError.log` 或提供 logger service。

## 集成评审清单

1. 是否默认使用多棵小 Auto 树，而 Manual 有明确理由？
2. 结构变化和值变化是否分别走静态 Trigger 与动态 signal？
3. 是否只捕获 ports / Dock，而没有在窗口后调用密封 builder？
4. 多状态写入是否 batch；跟随 Unit 的树是否交给 `spoke_eggy`，其余树是否有明确 `dispose()`？
5. 是否把关局或换场景清理误挂在 `is_alive` 上？
6. `common/packages/spoke/` 与 `spoke_eggy` 是否都保持原样？各自部署路径与 require 前缀是否逐字一致？
