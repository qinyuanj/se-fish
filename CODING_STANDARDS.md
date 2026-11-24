# 编码规范

**约束**是官方公开契约，**项目规则**是本仓库的工程做法；教程的示例数值与完整生命周期方法集不额外要求。

## 命名

**项目规则**（`client/`、`server/`、`common/` 自写代码；迁移分层与豁免清单见 [ADR-0034](docs/adr/0034-self-written-code-snake-case.md)）：

- 文件、目录、`require` 命名空间与模块表变量名逐段同名，一律 snake_case：`common/fish_catch.lua` → `local fish_catch = require("common.fish_catch")`。
- 其余标识符一律 snake_case：局部变量、参数、函数与方法名、自研 table 字段、协议字段（`fish_count`、`get_reel_state`）；常量用 UPPER_SNAKE_CASE。
- 官方与引擎的名字照原样（大写不管），五类：官方 API 成员与内置服务名（`OnServerEvent`、`World`、`*Service`）；EUI 节点与单位属性表键（`Name`、`Text`、`FontSize`、`Parent`、`Visible`）、Spoke 作用域名与运行期单位名字符串；`data/` 导出字段与 `EggyAPI.lua` 存根；对应策划表列的配置字段；`packages/` 上游整包（含 `*_Script.lua` / `*_LocalScript.lua`）、`unit_scripts/`、编辑器生成物。
- 存量按 L1 文件与 `require` → L2 模块表变量 → L3 方法与自研字段三层迁移；未迁移的存量 PascalCase 名称不单独改名，随该层迁移一次到位。

## API 与运行端

**约束**（[S0]、[S1]）：用 SE 公开 API，核对签名、对象类型和运行端；可能为空的结果先判空；位置、碰撞、文本等成员须从具备该能力的具体类型访问，普通 table 不能替代引擎数据类型；沙盒的 `getmetatable` 只接受 table。`game`、`Enums`、`Vector3`、`Color`、`Quaternion`、`CFrame`、`RemoteEvent` 是全局入口，`EggyAPI.lua` 只是类型存根。common 模块双端独立运行：table 修改不跨端同步，普通 Lua 变量不跨对局持久化。

**项目规则**：新增或变更 API 调用时，先用 `lua tools/cli.lua docs search <查询>` 查本地官方缓存（为空先 `docs sync`，缺的成员页用 `docs sync api <类型名>` 补），再与 `EggyAPI.lua` 存根核对版本差异；签名、语义与运行端都有依据才算查清，未查到的名称标 `[未查证]`，不作为已可用接口交付。缓存无精确成员时按 [editor-cli 检索](docs/agents/editor-cli.md)兜底，不用通用 Web 搜索替代官方依据。文档与实例不一致时记录并验证；CLI 的编辑时 `editor:GetService(...)` 示例不能用于玩法运行时。取证口径见[技术难点识别](docs/技术难点识别.md#se-lua-手册与-api-取证)。

## 模块与状态归属

**项目规则**（依据 [S0]、[S8]、[S19]）：

- server 持权威玩法状态（校验、结算、存储），client 管输入、UI、相机与本地表现，common 放双端配置、协议与共用逻辑；客户端只提交操作意图，结果由服务端判定。
- `main.lua` 组装模块、分发生命周期，业务逻辑归对应模块；依赖用 `local X = require(...)` 显式取得并保持单向，多模块协调由入口注入。
- 加载阶段只定义表、函数和必要的通信协议；事件绑定、UI 创建、玩家读取和玩法启动放进显式生命周期入口，纯配置模块加载时不获取 Service。
- 入口先接入已在线玩家、再启动 `ServerRuntime`（见 [server/main.lua](server/main.lua)），玩家入场钩子不能依赖启动回调已执行；宿主与 Spoke 树按显式顺序装配。
- 三端脚本目录与文件名不得与 SE 内置服务名同名（`World`、`MapData`、`Game`、`Camps`、`*Service`）：编辑器按服务名索引脚本树，重名子树同步时被跳过，见 [architecture 关键边界](docs/architecture.md)与 [ADR-0033](docs/adr/0033-script-names-must-not-shadow-se-services.md)。
- `pcall` 的业务失败要记录模块、操作、对象标识与错误内容，再按业务返回或清理，不继续报成功；包裹可能不存在的 UI/引擎 API 时允许忽略，同行注明理由。

## 跨端通信

**约束**（[S8]）：RemoteEvent 每次传一个可选 payload，多字段合成 table；`OnServerEvent` 的 `player` 由引擎注入，服务端以它确认请求者身份。载荷须可序列化，`CFrame` 等引擎类型先拆成位置、旋转等字段再传（[来源取证](docs/技术难点识别.md#se-lua-手册与-api-取证)）。

| 方向 | 发送 | 接收回调 |
| --- | --- | --- |
| client → server | `FireServer(payload?)` | `OnServerEvent(player, payload)` |
| server → 指定 client | `FireClient(player, payload?)` | `OnClientEvent(payload)` |
| server → 全部 client | `FireAllClients(payload?)` | `OnClientEvent(payload)` |

**项目规则**（依据 [S8]）：

- 通过 [REUtil](common/re_util.lua) 获取已有事件，双端共用事件名与协议定义；改旧的多实参消息时同时迁移收发两端。
- 服务端按五层校验：身份 → 类型 → 频率 → 业务条件 → 结果下发，全部通过后才改权威状态；[RateLimit](common/rate_limit.lua) 管滑动窗，`CheckRECD` 是每通道固定窗口的粗拦截，限频不替代其他校验。数值字段须经 [Number.IsFiniteNumber](common/number.lua) 排除 `NaN` 与 `±math.huge`，再判整数、范围。
- 客户端先监听响应再发请求，收到快照先校验结构再更新显示；要覆盖迟加入或重连时，提供只读、幂等的 ready / snapshot 握手。
- 玩家离开时清理按玩家保存的限频表与临时请求状态。

## 事件与异步生命周期

**约束**（[S6]）：`Signal`、`BindableEvent` 是同端通知，`Signal` 没有 `Wait()`；`Task` 使用协作式协程，`Task:Wait` 在协程中调用，异步接口形态以公开签名为准；`TimerService:CreateTimer` 返回的 Timer 已启动，停止用 `Cancel()`，暂停与续跑用 `Pause()` / `Resume()`，周期回调不保证准点。

**项目规则**（依据 [S6]、[S19]）：

- 事件连接、Timer、异步任务、临时对象和玩家状态都指定拥有者与收尾入口；只实现实际需要的初始化、启动、重置、销毁职责。
- 每局只跑一次的监听（`Start`）可以不存句柄；可重入口（`Init` / 视图挂载或重建节点）里的连接必须由 Spoke scope 托管或存句柄并在关闭/重建时断开。
- 启动中途失败按依赖反向清理已成功的部分，再次启动不残留上一轮的连接、计时器或临时状态；延迟回调执行前重新确认对象与流程有效，可重播流程用代次或等效机制使旧任务失效。
- 关键结果由显式状态与去重控制，不依赖同帧事件的隐含顺序；触碰等可重复事件按业务去重，计数用整数，倒计时按结束时间计算或越界判断结束。

## 验证审查

对本次修改涉及的每条规则，检查实现、关键分支与失败路径；引擎交互、通信和生命周期改动覆盖双端行为、非法请求与重复进入；命名按[命名](#命名)核对。验证方式与交付证据见开发工作流的[测试纪律](docs/agents/workflow.md#测试纪律)和[完成判据](docs/agents/workflow.md#完成判据)，缺少证据的标为未验证；来源与版本取证见[技术难点识别](docs/技术难点识别.md#se-lua-手册与-api-取证)。**夹具迁就生产**：生产代码里只为测试存在的分支、历史名兼容或数据一律退回，改夹具；迁移真源时删除绑在旧真源上的断言。

[S0]: https://u5-creator.s3.game.163.com/manual/se/lua/00-from-editor-to-se-lua.html
[S1]: https://u5-creator.s3.game.163.com/manual/se/lua/01-project-setup-and-entrypoints.html
[S6]: https://u5-creator.s3.game.163.com/manual/se/lua/06-events-task-timer.html
[S8]: https://u5-creator.s3.game.163.com/manual/se/lua/08-client-server-remote-event.html
[S19]: https://u5-creator.s3.game.163.com/manual/se/lua/19-reusable-systems-managers.html
