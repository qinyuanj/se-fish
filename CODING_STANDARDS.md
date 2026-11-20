# 编码规范

编写或审查本仓库 SE 业务 Lua 时，按本次改动涉及的章节检查。运行时限制不适用于宿主机工具与独立 Lua 测试进程；存量代码仅在本次触及时按相关规则修订。

**约束**指官方公开契约；**项目规则**指本仓库采用的工程做法。教程里的命名、示例数值和完整生命周期方法集不作为额外要求。

接入管理器、界面、技能包，或修改配置、导出物时，先查 [AGENTS.md 的修改边界](AGENTS.md#修改边界)；命名和玩家文案查 [GLOSSARY.md](GLOSSARY.md)。

**已机检，审查时不必逐条比对**：`require` 的工程前缀与大小写、禁止加载 `EggyAPI.lua` 等引擎存根、禁用 `io`/`os`/`package`/`debug`、`server/Mgr/*.lua` 与 `MgrMap` 登记一致、可重入口不泄漏监听，以及界面 handler 与锚点行为的登记一致（[guards/static_require_test](tests/native/guards/static_require_test.lua)）；三端依赖方向、循环依赖与禁止引用测试夹具（[guards/arch_policy_test](tests/native/guards/arch_policy_test.lua)）。

## API 与运行端

**约束**（[S0]、[S1]）：使用 SE 公开 API，核对成员签名、对象类型和运行端；查询结果可能为空时先判空；位置、碰撞、文本等成员须从具有该能力的具体类型访问，普通 table 不能替代引擎数据类型。`game`、`Enums`、`Vector3`、`Color`、`Quaternion`、`CFrame`、`RemoteEvent` 是全局入口；`EggyAPI.lua` 只是类型存根。common 模块在双端独立运行，table 修改不会自动跨端同步，普通 Lua 变量也不提供跨对局持久化。

**项目规则**：新增或变更 API 调用时，按 [eggy 规则的查 API 顺序](.claude/rules/eggy/eggy.md#查-api-的顺序) 核对；签名、语义与运行端都有依据才算查清，未查到的名称标 `[未查证]`，不作为已可用接口交付。文档与实例不一致时记录并验证；CLI 命中的编辑时 `editor:GetService(...)` 示例不能用于玩法运行时。

## 模块与状态归属

**项目规则**（依据 [S0]、[S8]、[S19]）：

- server 持有权威玩法状态（校验、结算、存储）；client 处理输入、UI、相机和本地表现；common 放双端配置、协议与可共用逻辑。客户端提交操作意图，服务端判定血量、奖励和存档等结果。
- `main.lua` 组装模块、分发生命周期，业务逻辑归对应模块；依赖用 `local X = require(...)` 显式取得并保持单向，需要协调多个模块时由入口注入。
- 模块加载阶段只定义表、函数和必要的通信协议；事件绑定、UI 创建、玩家读取和玩法启动放进显式生命周期入口。纯配置模块加载时不获取 Service。
- 入口先处理已在线玩家、再分发 `Start`（见 [server/main.lua](server/main.lua)），因此 `OnPlayerAdded` 不能依赖 `Start` 已执行；管理器以 `pairs` 遍历，跨管理器的初始化依赖须显式安排。
- `pcall` 的业务失败要记录模块、操作、必要对象标识和错误内容，再按业务返回或清理，不能继续报告成功；包裹可能不存在的 UI/引擎 API 时允许忽略错误，同一行注明理由。

## 跨端通信

**约束**（[S8]）：RemoteEvent 每次传一个可选 payload，多字段合成 table；`OnServerEvent` 的 `player` 由引擎注入，服务端以它确认请求者身份。

| 方向 | 发送 | 接收回调 |
| --- | --- | --- |
| client → server | `FireServer(payload?)` | `OnServerEvent(player, payload)` |
| server → 指定 client | `FireClient(player, payload?)` | `OnClientEvent(payload)` |
| server → 全部 client | `FireAllClients(payload?)` | `OnClientEvent(payload)` |

载荷使用可序列化字段；`CFrame` 等引擎类型需先拆成位置、旋转等字段再传（依据见[来源取证](docs/技术难点识别.md#se-lua-手册与-api-取证)）。

**项目规则**（依据 [S8]）：

- 通过 [REUtil](common/REUtil.lua) 获取已有事件，双端共用事件名与协议定义；修改旧的多实参消息时，同时迁移发送端与接收端。
- 服务端按五层校验：身份 → 类型 → 频率 → 业务条件 → 结果下发（[RateLimit](common/RateLimit.lua) 管滑动窗，`CheckRECD` 是每通道固定窗口的粗拦截），全部通过后才改权威状态；限频不替代其他校验。
- 客户端先监听响应，再发请求；收到快照先检查结构，再更新显示。需要覆盖迟加入或重连时，提供只读、幂等的 ready / snapshot 握手。
- 玩家离开时清理按玩家保存的限频表和临时请求状态。

## 事件与异步生命周期

**约束**（[S6]）：`Signal`、`BindableEvent` 是同端通知，`Signal` 没有 `Wait()`；`Task` 使用协作式协程，`Task:Wait` 在协程中调用，异步接口是等待还是回调以公开签名为准；`TimerService:CreateTimer` 返回的 Timer 已启动，停止用 `Cancel()`，暂停与续跑用 `Pause()` / `Resume()`，周期回调不保证准点触发。

**项目规则**（依据 [S6]、[S19]）：

- 事件连接、Timer、异步任务、临时对象和玩家状态都指定拥有者与收尾入口；只实现实际需要的初始化、启动、重置、销毁职责。
- 每局只跑一次的监听（`Start`）可以不存句柄；可重入口（`OpenScreen` / `CloseScreen` / `Init` / 重建节点）里的连接必须存句柄，并在关闭或重建时断开，避免叠加。
- 初始化或启动中途失败时，按依赖反向清理已成功的部分；再次启动不应残留上一轮的连接、计时器或临时状态。
- 延迟回调执行前重新确认对象与流程仍有效；可重播流程用代次或等效机制使旧任务失效，防止上一轮回调修改新一轮状态。
- 关键结果由显式状态与去重控制，不依赖同帧事件的隐含顺序；触碰等可重复事件按业务去重，计数用整数，倒计时按结束时间计算或用越界判断结束。

## 验证审查

对本次修改涉及的每条规则，检查实现、关键分支及失败路径；引擎交互、通信和生命周期改动须覆盖涉及的双端行为、非法请求与重复进入等路径。

**项目规则**：夹具迁就生产，生产不迁就夹具——生产代码里只为测试存在的分支、历史名兼容或数据一律退回，改夹具；迁移真源时删除绑在旧真源上的断言，夹具只喂新真源的数据。

审查验证方式与交付证据见开发工作流的[测试纪律](docs/agents/workflow.md#测试纪律)和[完成判据](docs/agents/workflow.md#完成判据)，逐项核对；缺少证据的项目标为未验证。来源与版本取证（官方章节对照、CLI 查询记录、`EggyAPI.lua` 版本缺口）见[技术难点识别](docs/技术难点识别.md#se-lua-手册与-api-取证)。

[S0]: https://u5-creator.s3.game.163.com/manual/se/lua/00-from-editor-to-se-lua.html
[S1]: https://u5-creator.s3.game.163.com/manual/se/lua/01-project-setup-and-entrypoints.html
[S6]: https://u5-creator.s3.game.163.com/manual/se/lua/06-events-task-timer.html
[S8]: https://u5-creator.s3.game.163.com/manual/se/lua/08-client-server-remote-event.html
[S19]: https://u5-creator.s3.game.163.com/manual/se/lua/19-reusable-systems-managers.html
