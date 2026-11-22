# 运行时语义

验收契约是 spoke 仓库的 `docs/spec.md` §3、§4、§6；术语见 `CONTEXT.md`，坐标、Auto 模式与分配策略的决策背景见 ADR 0001、0002、0003。

## 公共面与深度 require

`require("common.packages.spoke.api")` 返回 13 个类：Epoch、Ticker、SpokeTree、Dock、LambdaEpoch、SpokeHandle、Trigger、State、Effect、Reaction、Memo、Phase、EffectBuilder。

SpokeRuntime 与工具类型不在门面上，需要时深 require：

- `common.packages.spoke.runtime.spoke_runtime`：`SpokeRuntime.batch(fn)`，合并 Auto 树 flush 的稳定入口。
- `common.packages.spoke.runtime.spoke_exception`：故障时保存的 frame/tree trace。
- `common.packages.spoke.runtime.spoke_error`：`SpokeError.log`，接管日志。

## 心智模型与 Epoch 生命周期

- 把树看作按源码顺序前进的增量程序：每个 Epoch 是一个工作单元，运行期间不被其他 Epoch 抢占；重跑先撤销旧子树，再重建。
- `init(self, s)` 可返回 `tick_fn`。Init 内 `s:call(child)` 会同步完成 child Init，然后才返回；Tick 不在构造或 child Init 中同步执行。
- 普通 Epoch 在 Init frame pop 后自动请求首个 Tick；Ticker 和 Reaction 不自动 arm。重复请求在交付前合并，detached/faulted 后请求为 no-op。
- Epoch 在 Init 结束记录 attachment 边界。每次 Tick 先逆序拆除边界后的记录，再执行 tick fn；Init 记录跨 Tick 保留，仅在 Detach 时拆除。
- Detach 逆序处理所有 attachment，因此子 Epoch、cleanup 和资源的混合声明顺序就是可观察的清理顺序。父重跑会先清掉相应子树，pending 队列随后跳过已拆除项。
- builder 只在当前 Init/Tick/Bootstrap 窗口有效，窗口外使用报 sealed 错误。跨窗口只捕获 `s:ports()` 或 Dock，不捕获 builder。
- `epoch:detach()` 幂等；活动 frame 内只标记请求，frame pop 后才真正拆除。树或 Dock 的销毁也遵守这一延迟，不能抽走正在执行的 Epoch。

## Attachment、export/import 与诊断

- `use` 拥有 handle、disposable 或 cleanup function；`on_cleanup` 添加清理动作。cleanup、dispose、handle teardown 单项失败仍须记录并继续其余清理，不能因此 fault 树。
- `export` / `import` 使用非空字符串 key 和词法向后查找：先查当前可见 attachment，再逐层查祖先。后声明值遮蔽先前值，早先 sibling 看不到晚声明值。
- `try_import` 未命中返回 `false, nil`，`import` 未命中抛错。树 services 在 root Init 前导出，按 key 排序，不能依赖 table 枚举顺序。
- `s:log(message)` 挂载持久的 `Log: <message>` LambdaEpoch，并输出 frame/tree trace；它占 attachment 与坐标位置。logger 可经 `logger` service 替换，logger 错误不得中断用户逻辑。

## Ticker、SpokeTree 与 SpokeRuntime

- 每个 Epoch 向最近祖先 Ticker 请求 Tick。Ticker 只控制推进节奏，不按请求先后执行；每次 `tick_next()` 都必须取当前 pending 集中 tick cursor 最小的 Epoch，包括 flush 中被重新 arm 的项。
- 自定义 Ticker 的 `bootstrap` 返回 root；`on_tick` 至少调用一次 `tick_next()` 或 pause，否则形成故障。`tick_next()` 只允许在 OnTick 中调用。
- pause 保留 pending 工作并停止请求与 OnTick；resume 在仍有 pending 时重新调度。故障边界可捕获 `SpokeException` 后 pause，使其余树继续运行。
- `SpokeTree.spawn` / `spawn_eager` 是 Auto，layer 分别为 0 / -1；`spawn_manual` 由调用方驱动。Auto 拒绝显式 `tick()` / `flush()`。
- Auto 在用户调用返回前同步排空。Manual `tick()` 只交付一个 pending Epoch，`flush()` 排空；两者拒绝重入。Manual spawn 后通常需要首次 `flush()` 才完成 Effect 等挂载。
- 同一工作单元内的 request 只登记意图，通常在 frame pop 后才调度，不会中途插入另一个 Epoch。需要严格先后时，用树的声明顺序表达，而不是依赖 request 调用顺序。
- `SpokeRuntime.batch(fn)` 只暂停 Auto flush；nested batch 仅最外层 release 排空。fn 抛错时也必须 release，再向调用方重抛；普通订阅通知等同步副作用不属于 batch 的合并范围。
- 跨树先按较小 flush layer，再按 spawn timestamp。高优先级树可嵌套 flush；新建且优先级不低于当前树的树，仅在创建 frame 存活期间获得 scoped boost，同级既有树不能相互递归嵌套。
- Manual 与 Auto 可共存；Manual 驱动结束后，Runtime 仍按相同规则交付已 pending 的 Auto 工作。
- Runtime 有 100 次跨树调度振荡 guard，超限后记录并清空 pending Auto 树。每个 Ticker（含 SpokeTree）默认有 1000 次 loop guard：同一 host entry 内 coordinate regression 或同一非 Ticker 重入会累计，队列排空或返回宿主后清零，重复推进嵌套 Ticker 不累计；超限后 fault/stop，因此也能拦住单个计算持续自我激发。bootstrap 中用 `s:loop_guard(n)` 配置，`n <= 0` 关闭。

## 坐标与 Dock

- Packed 坐标为 `hi`、`lo`、`depth` 组成的 128 bit 值：16 层、每层 8 bit、索引 0..255。比较顺序为 unsigned hi、unsigned lo、depth；高位用 `math.ult`，`INVALID` 吸收 extend。
- Init attachment 的 child 排在 parent Tick cursor 前，Tick attachment 排在后。Cleanup、Handle、Use、Call、Export 都占索引，不能只给 child 编号。
- 任一 cursor Invalid 时，沿 parent 链使用完整 `coord_index`、`tick_index`、`depth` 比较；深树、宽树和压缩重排都不能静默退化为错误顺序。
- Dock 是可在 builder 窗口外修改的 keyed 子树容器。child Init 同步执行，首 Tick 仍走调度；Dock 的位置决定所有后代的执行顺序，Dock 拆除按逆 attach 顺序清理它们。
- key 为非空字符串。replace 通常先拆旧 child 再挂新 child；若旧 child 正在执行，拆除延迟到 frame pop，自替换可表现为 new Init 先于 old cleanup，且 old 不再 Tick。self-drop 同理，清理后不得交付首 Tick。
- drop nil、空串或缺失 key 是 no-op，其他非字符串 key 抛错；Dock 正在 detaching 时 call 抛错。
- child Init 抛错后，faulted child 仍占该 key，后续 replace/drop 必须执行其已注册清理，并保证 Dock frame 平衡弹出。
- `dock:effect(key, block [, triggers])` 挂一个生命周期跟随该 slot 的 Effect，同 key 再挂先拆旧 Effect。slot 超过 255 且至少一半可回收时压缩；重排刷新整个移动子树（含嵌套 Dock 及其后代），并保持存活 child 的相对顺序。

## 故障、Teardown 与性能

- 用户 Init/Tick 错误只包装一次为保存故障时 frame stack 的 `SpokeException`，沿 Ticker 传播。未捕获 fault 到树边界后记录、置 faulted 并停止 flush，最终 Runtime 边界不向宿主 rethrow，树不自动复活。
- 排障先读 fault 的 frame/tree trace，再用事件日志区分 Init、Tick、frame-pop 调度与 Detach。修故障时同时核对后续 cleanup、pending 工作和树状态。
- 资源获取与清理由同一 Epoch 所有；宿主应在对象失效前驱动 teardown。核心不读取宿主全局、不注册计时器，宿主集成见 `eggy-integration.md`。
- 优先保持生命周期与顺序清晰。稳定子树避免无谓重建；per-tick builder、闭包、attachment 和动态子树是分配审查点。没有测量与具体需求时不引入池化，核心 Epoch 等对象不池化。
- Runtime 适合 orchestrate 长寿命行为，不应默认承载高频逐帧计算。需要分帧或单步调试时使用 Manual，由消费方控制节拍。
