# 蛋仔宿主集成

落地细节见 spoke 仓库的 `docs/integration-best-practices.md` 与 `docs/eggy-host-integration-guide.md`，范式决策见 ADR 0002、0004、0005、0009。集成代码写在本项目里；`common/packages/spoke/` 是从 spoke 仓库镜像来的原始字节，升级只换 submodule SHA。

## 部署与加载

消费方 require 根下必须物理存在 `common/packages/spoke/`。宿主没有可配置的 `package.path`，目录折叠加载也没有作为契约验证，因此统一使用：

```lua
local spoke = require("common.packages.spoke.api")
```

通过 submodule 固定源码 SHA，部署时把包的原始字节镜像到相同路径。镜像要清除已删除的旧文件，不能只做增量合并。文档和脚本使用 PowerShell 7 / Windows 原生形式，保留 LF、无 BOM。

## 默认 Auto-first

每个 EUI 面板、玩法实体或 manager 拥有一棵小的 Auto 树。宿主事件回调修改 State 或 Trigger 后，SpokeRuntime 在回调返回前同步完成相关渲染。

Manual 只保留给三种场景：高频写入合并（一帧内多次写同一状态只渲染一次）、大计算分帧（`tree:tick()` 逐步推进）、单步调试。不要为核心添加 `SetTimeOut`、`EVENT.REPEAT_TIMEOUT` 或宿主全局读取。

## 生命周期

- Auto 树 `SpokeTree.spawn` 返回时首帧渲染已经同步完成，不需要额外动作。
- Manual 树 spawn 只同步跑 root Init，通常立即补一次 `tree:flush()` 完成 Effect 挂载；否则早于首帧的宿主事件会撞上尚未挂载的结构（Dock 为 nil）。之后由消费方帧节拍驱动 `tick()` / `flush()`。
- 退出、换场景、面板销毁时显式 `tree:dispose()`；宿主不会自动拆树，detach 逆序清理整棵子树。

## 组合模式

- 树根常用一个首次挂载后不读信号的 Effect 来搭建子结构，因为 `effect`、`memo`、`phase`、`dock` 组合方法在 EffectBuilder 上，而不在普通 Epoch builder 上。
- join/leave 等结构事件不改变 State 的值，使用静态 Trigger，例如 `s:effect(block, { roster_changed })`；score 等值变化通过 `s:d(state)` 跟踪。
- 在有效挂载窗口内捕获 `local dock = s:dock(...)` 到 upvalue，宿主事件之后调用 `dock:call(id, epoch)` / `dock:drop(id)`。builder 在窗口外密封，Dock 不是。
- 同一事件写多个 State 时，用深 require 的 `SpokeRuntime.batch(fn)` 延迟 Auto 树 flush，让同时依赖多个值的 Effect 只看到最外层 release 后的最终组合；普通 State subscriber 仍逐次收到每次写入。
- 共享状态用单例树加 `s:export` / `s:import`（字符串 key）串起来。

## 错误处理

核心已经把用户块 fault 包装、树级停止和 Runtime 最终日志边界串起来。宿主侧不要再用 pcall 包住每次 flush 或事件回调；检查 `tree.fault`，需要接管日志时替换 `SpokeError.log` 或提供 logger service。

## 集成评审清单

1. 是否默认使用多棵小 Auto 树，而 Manual 有明确理由？
2. 结构变化和值变化是否分别走静态 Trigger 与动态 signal？
3. 是否只捕获 ports / Dock，而没有在窗口后调用密封 builder？
4. 多状态写入是否 batch，树退出是否 dispose？
5. `common/packages/spoke/` 是否零改动？部署路径与 require 前缀是否逐字一致？
