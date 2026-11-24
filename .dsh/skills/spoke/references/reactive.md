# 响应式语义

验收契约是 spoke 仓库的 `docs/spec.md` §5、§6。Reactive 类型也是 Epoch；挂载窗口、Tick 回滚、tree coordinate、Auto/Manual flush、故障与振荡保护见 `runtime.md`，此处只记录响应式可观察行为。

## 类型速查

| 类型 | 责任 | 必须保留的行为 |
| --- | --- | --- |
| Trigger | 事件发射与订阅 | 起始订阅者集合、订阅顺序、FIFO 重入、逐订阅者错误隔离、整次 invoke batch |
| State | 可写 signal | 实际变化才通知；默认 `==`，table 按身份比较 |
| Computation（Effect/Memo 等的基类） | 静态与动态依赖 | 静态贯穿生命周期；动态按读取槽位换绑、裁剪并抑制 stale callback |
| Effect | 挂载即运行，依赖变化后重跑 | 上轮 attachments 逆序清理后再运行；可返回 signal |
| Reaction | 跳过首次运行的 Effect | mount 安装静态订阅，但不自动 Tick，也不建立首次动态依赖 |
| Memo | 派生 signal | 首次计算初值；相等重算不通知；builder 只有 `d` 与 `on_cleanup` |
| Phase | 条件挂载块 | 条件为静态依赖；false 清理并移除动态依赖，true 全新挂载 |

## Trigger 与 State

- Trigger 按订阅顺序通知。每次 dispatch 固定起始订阅者集合：本轮新增者不运行，本轮移除者仍运行；移除会影响后续事件，包括已排队事件。
- 同一函数可多次订阅。按 callback unsubscribe 删除所有匹配订阅；handle 只删除自己的订阅。优先让 builder 拥有 handle，避免手工清理遗漏。
- 重入 `invoke` 入队而非递归，按 FIFO 逐事件 dispatch。subscriber 抛错只记录并隔离，后续 subscriber 与事件仍继续。
- 一次 invoke 整体处于 batch：普通 subscriber 仍逐次收到通知，但 Auto 树中的 Effect/Memo 等通知全部 subscriber 后才 flush，因此观察不到 subscriber 序列制造的中间组合值。
- State 的初始值不通知；`set` 先比较再写入，变化时把新值传给 subscriber。`update(fn)` 读取当前值并复用 `set`，不绕过相等判断。
- 需要结构相等时传 `equals(old, new)`；核心不做任意 table deep equality。`spoke_runtime.batch` 不合并普通 State subscriber 的通知。
- 命名单元且初值为 nil 时，构造参数必须同时传 name 和 nil，避免把单字符串当作 initial value。

## 依赖跟踪：静态订阅与动态槽位

静态依赖可包含 Trigger 或 signal，创建 Computation 时订阅，直到 dispose；动态依赖由 `s:d(signal)` 建立并返回 `signal.now`，只接受 signal。两者可混用。

每次 block 运行（含重跑）按以下顺序发生：

1. 读取位置归零，但暂不退订旧依赖。
2. 第 n 次 `s:d(signal)` 对应第 n 槽位：首次读取新增订阅；相同 signal 保留订阅；不同 signal 先退订再换绑。
3. 回调携带槽位序号；只有该槽位已在本轮重新读到，回调才调度。换绑或重读前触发的旧依赖属于 stale，必须抑制。
4. block 结束后退订并删除本轮未读取的尾部槽位；即使用户 block 抛错，也照样收尾。
5. dispose 同时退订静态与动态依赖，不能遗留回调。

同一 signal 读两次占两个槽位，tracker 不去重；多次 schedule 最终合并成一次 Tick 是 Epoch 的职责。调试时分别记录 tracker 回调次数与 block 运行次数，避免把两层语义混为一谈。

## Effect、Reaction 与 Phase

- Effect 挂载后运行一次，依赖触发后重跑。每轮先逆序清理上轮 cleanup、订阅、子 computation 和其他 attachments，再执行新 block；不是复用旧子树。
- 子 Effect/Memo 在所属 block 完成后才运行，同级按挂载顺序执行；重跑仍按 tree coordinate 排序。需要先后关系时拆成按声明顺序排列的 computation，不依赖临时变量的中途状态。
- Effect block 返回 nil 时表示副作用；返回 signal 时 Effect 暴露 `now/subscribe/unsubscribe` 并镜像其值。重跑返回 nil 会把输出重置为 nil；旧 signal 的订阅随上轮 attachments 清理。
- Reaction 的静态订阅在 mount 时已生效，但首次 block 不运行，因而不能依赖“首轮 `d` 已绑定”。首次触发后才执行 block、建立动态依赖，之后按 Effect 规则清理重跑。
- Phase 额外订阅条件 signal；条件变化或其他静态 Trigger 都可调度，但 block 只在条件为 true 时运行。转 false 会完整清理，转 true 重新建立本轮资源与动态依赖。

## Builder 与 cleanup

EffectBuilder 除 Epoch attachments 外提供 `d`、`subscribe`、`memo`、`effect`、`reaction`、`phase`、`dock`。builder 只在当前 block 同步执行窗口内有效；跨窗口调度用 `s:ports()`，窗口外增删动态结构用捕获的 Dock。

子 computation 属于创建它的本轮 block，随本轮一起清理和重建。cleanup 与资源 setup 写在同一作用域；嵌套结构先于父节点清理。

MemoBuilder 刻意只提供 `d` 与 `on_cleanup`。Memo 与 Effect 共用静态/动态依赖、运行顺序和 cleanup 规则，但 selector 应保持纯派生；需要挂载子结构、额外订阅或拥有资源时使用 Effect。Memo 每次重算先清理，再通过 State 相等语义向下游发布；首次 nil 到值仍算变化并通知。
