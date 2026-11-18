---
name: spoke
description: 用 Lua 5.4 版 Spoke 在蛋仔 UGC 里写界面与玩法逻辑：Epoch、Ticker、SpokeTree、Dock 与 Trigger、State、Effect、Reaction、Memo、Phase 的用法与可观察语义，以及 EUI 宿主集成。凡是用 spoke 写面板、玩法实体或 manager，或排查生命周期、调度顺序、cleanup、动态依赖、batch、Auto/Manual、渲染时机的问题，都应加载本技能。
---

# Spoke（Lua 5.4）使用

## 核心原则

本技能写给 spoke 的消费方：在蛋仔 UGC 项目里用已经落位的库写业务代码，`common/packages/spoke/` 保持原样。设计判断落在可观察行为上——什么先跑、什么被清理、宿主事件返回时渲染走到哪一步——而不是内部实现。

依据优先级：`common/packages/spoke/` 的实际行为，其验收契约是 spoke 仓库的 `docs/spec.md`；与本技能冲突时按实际行为写代码，并把差异说明出来。需要新的库行为时，那是 spoke 仓库的改动，不是在本项目里给包打补丁的理由。

## 代码形状

```lua
local spoke = require("common.packages.spoke.api")
local SpokeTree, LambdaEpoch, Effect, Dock, State =
  spoke.SpokeTree, spoke.LambdaEpoch, spoke.Effect, spoke.Dock, spoke.State

local view = {}
local score = State.new(0)   -- 值：s:d(score) 跟踪
local rows = Dock.new()      -- 身份：窗口外 dock:call / dock:drop

local tree = SpokeTree.spawn(LambdaEpoch.new(function(s)
  s:call(rows)
  s:call(Effect.new(function(es)
    view.score = es:d(score)  -- 换成你的 EUI 写入
  end))
end))

score:set(1)                  -- Auto 树在这次调用返回前已经渲染完
rows:call("p1", LambdaEpoch.new(function() end))
tree:dispose()                -- 面板销毁时必须调用
```

## 工作流

### 1. 加载当前分支的参考

| 这次要碰的东西 | 读 |
| --- | --- |
| 驱动树、生命周期、调度顺序、坐标、Dock、故障 | `references/runtime.md` |
| Trigger、State、Effect、Reaction、Memo、Phase 的响应式行为 | `references/reactive.md` |
| 落位部署、EUI 面板、宿主事件、batch、销毁 | `references/eggy-integration.md` |

Effect 重跑、batch、Dock 这几处同时跨运行时与响应式，遇到它们就两边都读。

完成标准：本次要用到的分支都已读过；拿不准是否跨层时按跨层处理。

### 2. 先定驱动模式

默认 Auto：每个 EUI 面板、玩法实体或 manager 一棵小树，`SpokeTree.spawn` 返回时首帧渲染已经完成——宿主事件回调改状态即可，渲染在回调返回前结束。

Manual（`SpokeTree.spawn_manual`）只在三种情况用：一帧内多次写同一状态要合并、大计算要分帧、要单步调试。它 spawn 只跑 root Init，Effect 等挂载要等首 Tick，所以通常紧接着补一次 `tree:flush()`，之后由你给的帧节拍驱动 `tick()` / `flush()`。

完成标准：能说出这棵树为什么是 Auto，或它命中哪一条 Manual 场景、节拍由谁驱动。

### 3. 结构、值、身份分开表达

- 结构变化（join/leave、面板开关）不改变任何 signal 的值，用静态 Trigger 驱动结构 Effect。
- 值变化用 `s:d(signal)`，只让真正读它的那部分重跑。
- 行、卡片这类有身份的子结构放进 Dock：EffectBuilder 上是 `s:dock()`，普通 builder 上是 `s:call(Dock.new())`；宿主事件之后用捕获的 `dock` 增删，不整表重建。

builder（`s`）只在 Init/Tick/Bootstrap 窗口内有效：跨窗口只捕获 `s:ports()` 或 Dock，窗口外再动 builder 会报 sealed 错误。

完成标准：每个宿主事件都能指认它动的是结构还是值、影响哪棵子树，以及调用的是窗口内还是窗口外的句柄。

### 4. 合并写入，退出即销毁

一次宿主事件写多个 State 时，用 `SpokeRuntime.batch(fn)` 包住（深 require `common.packages.spoke.runtime.spoke_runtime`）：Auto 树的 flush 推迟到最外层返回，同时依赖多个值的 Effect 因此只跑一次。

面板销毁、退出、换场景时显式 `tree:dispose()`；宿主不会替你拆树，detach 逆序清理整棵子树。

完成标准：多写事件有 batch，并能说清不批会多跑哪几次；每棵树都有明确的 dispose 调用点。

### 5. 按可观察行为验收

交付前对着实际运行核对：宿主事件返回后 UI 到了该到的状态、销毁后没有残留订阅、再触发旧事件是安全 no-op、`tree.fault` 为空。出错时先读 fault 的 frame/tree trace，再用事件日志区分 Init、Tick、frame-pop 调度和 Detach。

宿主侧不要用 pcall 包住 flush 或事件回调——核心已经把用户块 fault、树级停 flush、Runtime 最终日志边界串起来；也不要为了改变行为去改 `common/packages/spoke/`。

完成标准：上面每一项都有实际运行结果；没跑过的写明未核对，不用读代码代替运行。

## 快速语义检查

- Init 同步执行；普通 Epoch 首个 Tick 自动排队，Init 返回前不跑 Tick。Init attachments 存活整个 Epoch，Tick attachments 在下一次 Tick 前逆序回滚。
- builder 只在回调窗口内有效；跨窗口调度用 `s:ports()`，动态 keyed 子树用捕获的 Dock。
- Ticker 按当前 tree coordinate 取最小 pending Epoch；同一工作单元里的 request 只登记意图，不中途插入另一个 Epoch。
- Auto 树在发起调用的返回前同步排空；Manual 树由调用方 `tick()` / `flush()`。这个区别是语义，不是宿主性能开关。
- Trigger 用 dispatch 起始的订阅者快照、FIFO 重入队列和逐订阅者错误隔离；State 默认以 `==` 抑制相同值通知。`SpokeRuntime.batch` 只延迟 Auto 树 flush，普通 State subscriber 仍逐次收到每次写入。
- 动态依赖按读取槽位换绑，过期槽位回调要抑制；Effect 先清理再重跑，Reaction 跳过首次运行，Memo 保持纯派生，Phase 只在条件为真时挂载块。
- 用户 Init/Tick 错误进入 fault 传播；cleanup、dispose、Trigger subscriber 与 logger 错误各自隔离，不会中止后续清理或通知。

## 交付说明

说明用了 Auto 还是 Manual、树挂在哪个宿主事件上、结构、值与身份各落在哪里、销毁路径，以及实际运行核对了什么。`common/packages/spoke/` 有改动时单独说明理由和升级方式。没核实的结论写明“未核对”。
