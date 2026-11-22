# MgrFerry 航班 keyed route 所有权与 spoke 生命周期适配研究

## 结论摘要

**推荐强度：单表 keyed route 所有权为有条件的中等推荐；现在直接用 spoke Dock 接管航班生命周期则下调为弱推荐／暂缓。**

route.Id 与 Dock 的非空字符串 key 匹配，Dock 也提供 keyed child 的 attach、replace、drop 与 cleanup；但它没有业务取消原因，没有公开的按 key 读取航班记录的 interface，同 key call 还会先替换旧 child。这些语义不能直接替代 PendingFlight 查询、同航线重复交票拒绝、交票人匹配和取消／正常到期分流（server/Mgr/MgrFerry.lua:85-107，server/Mgr/MgrFerry.lua:200-202，server/Mgr/MgrFerry.lua:276-277，common/packages/spoke/runtime/dock.lua:21-33，common/packages/spoke/runtime/dock.lua:50-79）。

最关键的反向证据：正常到期在调用 Depart **之前**删除 Flights[routeId]，随后可能广播 departed，也可能因缺锚点广播 cancelled；玩家退出则在另一处删除并广播 cancelled。因此“从所有者移除／detach／cleanup”不等于“业务取消”，cleanup 不得无条件广播 cancelled（server/Mgr/MgrFerry.lua:227-245，server/Mgr/MgrFerry.lua:269-270，server/Mgr/MgrFerry.lua:288-301，server/Mgr/MgrFerry.lua:313-325）。

本研究只读源码与资料，未运行测试、未操作宿主，未修改业务代码、测试、ADR、GLOSSARY、spoke/spoke_eggy 或 HTML。

## 1. 范围与非目标

### 范围

- 同一去程航班在 BoardPending[routeId] 与 Flights[routeId] 之间的迁移。
- Update 到期、玩家退出、缺锚点取消、退款、恢复与广播。
- keyed route 所有权是否能加深现有 module，以及 spoke Dock／Epoch cleanup 是否匹配。
- 保留 World:GetServerTime() 宿主时钟、Save.Execute 存档 adapter、server/main.lua 的 MgrMap 组装与生命周期分发 seam。

### 非目标

- 不设计新 interface、函数签名、状态机类型或补丁。
- 不改造返程 ReturnPending；它按 player.UserId 归属，和 route keyed 去程是另一笔状态（server/Mgr/MgrFerry.lua:14，server/Mgr/MgrFerry.lua:146-175）。
- 不引入通用生命周期框架、全局 unit factory/container，也不把 OwnedUnits 扩展到纯 Lua 航班记录。
- 不评估传送物理、落点、船体或客户端视觉改造；不把研究当作性能测量或宿主真机验证。

## 2. 现有寿命／所有权时间线

### 2.1 组装与交票落账

1. MgrFerry 是单表 module；LastSeq、Recoveries、ReturnPending、Flights、BoardPending 都是其表内状态（server/Mgr/MgrFerry.lua:12-14）。
2. server/main.lua 在 MgrMap 注册 MgrFerry，并注入 PlayerData、Interact、Save、SpecialItem；这是现有组装 seam，不应另建平行入口（server/main.lua:14-47，server/main.lua:81-96，server/main.lua:197-201）。
3. 入口在 GameStart 分发 Start，在 Heartbeat 分发 Update，退出时经存档／离场流程后分发 OnPlayerRemoving（server/main.lua:260-305，server/main.lua:310-330）。MgrFerry:Start 只取得 World 并连接 FerryAction（server/Mgr/MgrFerry.lua:305-311）。
4. PendingFlight 按 BoardPending 后 Flights 的顺序取任一航班；Board 发现任一项就拒绝 sailing，所以两张表共同表达“route 已占用”（server/Mgr/MgrFerry.lua:85-93）。
5. Board 创建含 player、operation、routeId 的 flight 并写入 BoardPending；真实扣票和 recovery 记录只在 Save draft transform 中发生（server/Mgr/MgrFerry.lua:90-102）。Settle 经 Save:Execute 执行并等待回调（server/Mgr/MgrFerry.lua:71-83）。
6. 回调先核对 BoardPending[route.Id] == flight，再删除 pending；失败只回复失败，成功才新建含 DepartAt 的 Flights 记录，随后广播 countdown 并回复交票人（server/Mgr/MgrFerry.lua:102-110）。同步未接纳时由 Board 删除 pending（server/Mgr/MgrFerry.lua:112-116）。
7. 测试证明落账完成前不扣真实票、不广播、不建立 Flights；drain 后才扣票并开航班（tests/native/ferry_test.lua:255-268）。同 route 第二次交票拒绝且不扣票（tests/native/ferry_test.lua:682-690）。

### 2.2 到期、出发与缺锚点

1. Update 先对在线、已初始化且未暂停的玩家执行 Recover，再读取一次 World:GetServerTime()（server/Mgr/MgrFerry.lua:288-296）。
2. 随后遍历六条配置 route；到期时**先删 Flights 项，再调用 Depart**（server/Mgr/MgrFerry.lua:296-301，common/GameCfg.lua:1279-1300）。所以通用 detach 发生时，尚无“正常出发／缺锚点取消”的结果。
3. 正常 Depart 按 BoatRange 和传送结果分别确认交票人、记录搭便船者到达，最后广播 departed（server/Mgr/MgrFerry.lua:247-270）。测试覆盖同行、范围外玩家不动、表项删除与最后的 departed（tests/native/ferry_test.lua:348-362）。
4. 对交票人，未赶上船按“已交付、不退票”处理；在船上但传送失败才退款（server/Mgr/MgrFerry.lua:253-258）。规则冲突见第 8 节。
5. 缺锚点时，为仍在线且匹配的交票人调用 FinishTravel(..., false, 'anchor', ...) 退款，再广播 cancelled（server/Mgr/MgrFerry.lua:227-245）。退款与 recovery 清除在同一 draft transform 中按 operation 去重；广播不等待独立写入完成（server/Mgr/MgrFerry.lua:119-143，server/Mgr/MgrFerry.lua:238-245）。
6. 缺锚点退票、无传送、cancelled，以及退款写失败后的重试与重进恢复均有测试（tests/native/ferry_test.lua:270-288，tests/native/ferry_test.lua:441-450）。

### 2.3 玩家退出与恢复

1. OnPlayerRemoving 先清玩家维度状态，再扫描 BoardPending：交票人匹配时仅删除，不广播（server/Mgr/MgrFerry.lua:313-319）。
2. 第二次扫描 Flights 才在交票人匹配时删除并广播 cancelled（server/Mgr/MgrFerry.lua:320-325）。测试要求只取消交票人的 route，不影响另一 route（tests/native/ferry_test.lua:474-491）。
3. 付款中退出后，另一玩家可接管同 route；旧回调因对象身份不等不得删除新航班（server/Mgr/MgrFerry.lua:103-107，tests/native/ferry_test.lua:428-439）。
4. Recover 若 recovery 记录仍对应 PendingFlight 中同玩家、同 operation 的航班，就不退款；否则经 FinishTravel(..., false, 'interrupted', ...) 恢复。Recoveries 防止并发重复恢复（server/Mgr/MgrFerry.lua:272-285）。
5. 重进测试证明：退出后清掉 flight，再由 Update 恢复，会退票、不传送、不重启航班，重复 Update 不重复退款（tests/native/ferry_test.lua:509-523）。

## 3. 所有清理路径及缺口

| 路径 | 当前清理与外部效果 | 证据 |
|---|---|---|
| Save 同步未接纳 | 删除匹配的 BoardPending；失败回复；无 countdown/cancelled | server/Mgr/MgrFerry.lua:112-115 |
| Save 回调失败 | 删除匹配的 BoardPending；失败回复；无 Flights | server/Mgr/MgrFerry.lua:102-105 |
| 旧异步回调 | 身份不等直接返回；不得清新航班 | server/Mgr/MgrFerry.lua:103-104；tests/native/ferry_test.lua:428-439 |
| pending 交票人退出 | 删除 BoardPending；不广播 | server/Mgr/MgrFerry.lua:317-319 |
| active 交票人退出 | 删除 Flights；广播 cancelled | server/Mgr/MgrFerry.lua:320-324 |
| 正常到期 | 先删除 Flights，后出发；最终 departed | server/Mgr/MgrFerry.lua:295-301，server/Mgr/MgrFerry.lua:269-270 |
| 到期缺锚点 | 先删除 Flights，后持久退款；cancelled | server/Mgr/MgrFerry.lua:227-245 |
| 重进／中断恢复 | 活动航班仍匹配则保留；否则幂等退款并清 recovery | server/Mgr/MgrFerry.lua:119-143，server/Mgr/MgrFerry.lua:272-285 |
| 返程退出 | 清 ReturnPending[userId]，迟到回调不能再传送 | server/Mgr/MgrFerry.lua:146-175，server/Mgr/MgrFerry.lua:313-316 |

### 缺口与风险

1. **取消原因不在所有权事件里。** 正常到期、缺锚点、玩家退出都删除 Flights，但外部结果不同；不能由同一个无条件 cleanup 区分（server/Mgr/MgrFerry.lua:227-245，server/Mgr/MgrFerry.lua:269-270，server/Mgr/MgrFerry.lua:295-301，server/Mgr/MgrFerry.lua:320-324）。
2. **现有测试会漏掉“正常出发前多播 cancelled”。** 正常出发只断言最后一条广播是 departed，没有断言完整序列或 cancelled 为零；drop cleanup 先播 cancelled、Depart 再播 departed 仍可能通过（tests/native/ferry_test.lua:348-362）。
3. **pending 退出没有精确广播序列断言。** 现有用例证明另一玩家能接管且旧玩家没有成功回复，未断言旧 pending 清理不产生 cancelled（tests/native/ferry_test.lua:428-439）。
4. **route key 不提供 player 反查。** 当前退出扫描两张表寻找 flight.player == player；仅换成 route keyed child 不会自动回答“该玩家拥有哪条 route”（server/Mgr/MgrFerry.lua:317-324）。若仍扫描，收益是 locality，不是已证明的性能提升。
5. **未来树缺少既有总销毁入口。** MgrFerry 只有 Start、Update、OnPlayerRemoving，没有 Stop/dispose；MgrMap 入口也只展示 Start、玩家加入／退出与 Update 分发（server/Mgr/MgrFerry.lua:288-326，server/main.lua:260-330）。SpokeTree:dispose() 的实际实现只是 detach()（common/packages/spoke/runtime/spoke_tree.lua:169-179）。关局时谁调用它，本仓当前源码不能回答。
6. **没有性能证据。** Update 只遍历六条 route，退出最多扫描两张 route 表（common/GameCfg.lua:1282-1291，server/Mgr/MgrFerry.lua:296-302，server/Mgr/MgrFerry.lua:317-325）。本研究未测量，不应以性能为采用理由。

## 4. spoke 语义匹配度及依据

### 匹配的部分

- **key 类型匹配。** route id 由字符串 zone id 生成，Route 只接受字符串；Dock 要求非空字符串 key（common/GameCfg.lua:1289-1300，common/packages/spoke/runtime/dock.lua:8-24）。
- **keyed 子树与幂等移除部分匹配。** drop 对缺失 key 是 no-op，并 detach 对应 child（common/packages/spoke/runtime/dock.lua:99-123，common/packages/spoke/runtime/dock_slots.lua:33-52）。
- **cleanup 归 Epoch 所有。** on_cleanup 注册 attachment，detach 逆序释放；单项失败会报告并继续其他清理（common/packages/spoke/runtime/epoch_builder.lua:83-89，common/packages/spoke/runtime/epoch_teardown.lua:19-36，common/packages/spoke/runtime/epoch_teardown.lua:49-61）。
- **核心不替业务决定宿主时钟或存档。** 保留宿主 Update 读时钟与 Save adapter 是必要约束，而非额外兼容层（server/Mgr/MgrFerry.lua:71-83，server/Mgr/MgrFerry.lua:288-301）。

### 不匹配或不足以替代业务的部分

1. **同 key replace 不等于同航线拒单。** Dock:call 经 _install 先 drop(key) 再 attach 新 epoch；Board 的玩法却是已有 pending/active 时拒绝第二人且不扣票。Dock 不能取代业务 guard（common/packages/spoke/runtime/dock.lua:50-79，server/Mgr/MgrFerry.lua:85-96，tests/native/ferry_test.lua:682-690）。
2. **没有公开的 keyed 航班读取 interface。** dock.lua 暴露 call、effect、drop 等，未暴露返回 key 对应 child 的公共查询；DockSlots.find 是内部实现（common/packages/spoke/runtime/dock.lua:36-141，common/packages/spoke/runtime/dock_slots.lua:33-40）。业务却必须由 PendingFlight 取回 player／operation 供重放和恢复核对（server/Mgr/MgrFerry.lua:85-88，server/Mgr/MgrFerry.lua:200-202，server/Mgr/MgrFerry.lua:276-277）。若另加 route→flight registry，Dock 就没有独占权威状态，容易退化为 shallow wrapper。
3. **detach 没有业务原因。** drop 只接收 key，Epoch:detach() 不接收原因，cleanup fn 也没有业务 outcome 参数（common/packages/spoke/runtime/dock.lua:99-123，common/packages/spoke/runtime/epoch.lua:115-138，common/packages/spoke/runtime/epoch_builder.lua:83-89）。cleanup 只能释放通用资源，不能推导 cancelled、退款原因或 departed。
4. **活动 frame 内拆除有延迟。** drop 在 child frame 存活时把 detach 延迟到 frame pop，但立即 release key slot；Epoch 也只在 frame 深度为零时立即 detach（common/packages/spoke/runtime/dock.lua:111-123，common/packages/spoke/runtime/epoch.lua:129-138）。现有 operation／对象身份保护仍必要，不能交给 Dock 替换顺序替代（server/Mgr/MgrFerry.lua:103-107）。
5. **spoke_eggy 不天然适配。** 航班是 route keyed 纯 Lua 记录，不是 Unit；ADR-0024 的宿主包把树绑到 Unit.Destroying，不能据此推断航班或关局寿命（docs/adr/0024-introduce-spoke-eggy-host-package.md:5-12，docs/adr/0026-no-global-unit-factory.md:5-8）。
6. **没有现成宿主销毁语义可复用。** 核心 dispose() 仅 detach；本研究未核对真实关局、换场景是否触发业务清理事件，不能把 is_alive、玩家退出或 Destroying 当作航班取消信号（common/packages/spoke/runtime/spoke_tree.lua:177-179，docs/adr/0024-introduce-spoke-eggy-host-package.md:5）。

**判定：局部结构匹配，整体业务寿命只部分匹配。spoke 可以是 implementation 候选，但不足以成为采用理由，更不能把取消广播塞进通用 detach/cleanup。**

## 5. deletion test：是否真正加深 module

### 只用 Dock 包装双表／另加查询表

删除包装后，Board 仍要自己拒单，Update 仍要判断到期与结果，OnPlayerRemoving 仍要找 payer，Recover 仍要读取 player/operation，退款与广播仍全在调用方。若新 module 只把按 key attach/drop 转发给 Dock，它就是 **shallow**：interface 增加 key、phase、所有者查询和清理原因等知识，implementation 却没有吞掉复杂度。不推荐。

### keyed route 所有权承接阶段与终局分流

若收拢后，调用方不再分别理解 BoardPending／Flights，也不再从“表项被删”推断取消；同一所有权 implementation 集中保持对象身份、pending/active 占用、正常到期、玩家取消和恢复查询，那么删除它会让这些判断重新散入 Board、Update、OnPlayerRemoving、Recover，才通过 **deletion test**，形成更深的 module 与 locality。

即使采用此方向，spoke 仍不是必需品；in-process 的单 keyed route record 收拢可先独立证明业务收益。若只把两表改成一表、所有终局判断仍留在原调用点，depth 与 leverage 都有限，推荐强度仍偏低。

明确避免：不为六条 route 建通用 entity/framework 层；不把 Dock replace 当业务仲裁；不把 cleanup 当 RemoteEvent 发布器；不为测试暴露 Dock slot、epoch 或新 registry。

## 6. locality／leverage／测试收益

### locality 与 leverage

真正值得集中的是“同一 route 当前由哪个 operation 占用、处于落账还是倒计时、以何种业务原因结束”。当前这些知识分布在 PendingFlight、异步回调、Update、退出和恢复中（server/Mgr/MgrFerry.lua:85-117，server/Mgr/MgrFerry.lua:200-202，server/Mgr/MgrFerry.lua:272-301，server/Mgr/MgrFerry.lua:313-325）。

正确的所有权 implementation 可服务交票、到期、退出、恢复四处调用；但 Dock 只提供 keyed attach/drop，不提供业务结果。因此 leverage 必须来自业务 module 的 depth，而不是“用了 spoke”。

### seam 与 adapter

- 保留 server/main.lua 的 MgrMap 组装／分发 seam，不另建生命周期入口（server/main.lua:14-47，server/main.lua:260-330）。
- 保留 World:GetServerTime() 与 Save:Execute adapter；它们已有测试替身和真实生产实现两种适配，无需为 spoke 新增抽象（server/Mgr/MgrFerry.lua:71-83，server/Mgr/MgrFerry.lua:121-123，tests/native/ferry_test.lua:121-160）。
- 测试与调用方应跨同一业务 interface；不要为内部 Dock 再开测试专用 seam。现有测试直接观察 Flights，与内部结构耦合；未来应把证明重点放到回复、广播、存档与传送等可观察结果，而不是复制新内部结构断言（tests/native/ferry_test.lua:241-268，tests/native/ferry_test.lua:644-679）。

收益是可在一个 seam 下验证“占用→发布→终局／取消→恢复”的完整序列，堵上多次广播、旧回调清新航班、重复退款。成本是现有不少测试直接读写 Flights，首次业务引入 spoke 还要证明树总销毁归属。若这些成本只为替换两张小表，收益不成比例。

## 7. 最小可证伪验证

以下是未来实施前后的最小行为矩阵，不是本次已执行的测试。任一 cancelled 多播、旧回调影响新航班、跨 route 误清理或重复退款，都应判定候选不成立。

| 场景 | 必须保持的可观察结果 | 现有证据／缺口 |
|---|---|---|
| 落账未完成 | 无 countdown、无成功回复、无 active；drain 后只发布一次 countdown | 已有：tests/native/ferry_test.lua:255-268 |
| pending 交票人退出，另一玩家接管 | 旧 pending 不广播 cancelled；旧回调不得清新航班；只让新 operation 开 countdown | 接管已覆盖，无 cancelled 序列待补：tests/native/ferry_test.lua:428-439 |
| active 交票人退出，另一 route 倒计时 | 仅退出者 route cancelled 一次；另一 route 正常 departed | 基础覆盖：tests/native/ferry_test.lua:474-491 |
| 正常到期出发 | 完整相位序列不得含 cancelled；只搬运一次；最终 departed | **关键新反例**；现只查最后广播：tests/native/ferry_test.lua:348-362 |
| 到期缺锚点 | 不传送；cancelled 恰一次；退款最终持久且重试不重复 | tests/native/ferry_test.lua:270-288，tests/native/ferry_test.lua:441-450 |
| 同 key 旧回调／cleanup 交错 | 旧 operation 不得删除、取消或退款新 operation | server/Mgr/MgrFerry.lua:103-107，tests/native/ferry_test.lua:428-439 |
| 同 route 第二人交票 | 拒绝 sailing，不扣第二人的票，不替换当前航班 | tests/native/ferry_test.lua:682-690 |
| 两 route 错时到期 | 各自使用宿主 DepartAt，互不提前清理或广播 | tests/native/ferry_test.lua:644-679 |
| 重进恢复 | 不重放传送、不重启已取消航班、不重复退款 | tests/native/ferry_test.lua:509-523 |
| 未到期／恰好到期 | 未到期不动；now >= DepartAt 后只出发一次 | tests/native/ferry_test.lua:465-472；恰好到期由 sail 路径间接覆盖 |

最小新增反例应优先是：**正常 drop/detach 路径不产生 cancelled**。它能直接证伪“cleanup 无条件广播”的错误设计，而不是复述 Dock implementation。

## 8. ADR 与玩法约束

1. **ADR-0022／0024：上游包不得就地改。** spoke 与 spoke_eggy 整包复制、独立升级，不搬上游测试；缺行为时在业务侧重新评估，不在 common/packages/spoke* 内补业务查询或取消原因（docs/adr/0022-introduce-spoke-runtime.md:9-14，docs/adr/0024-introduce-spoke-eggy-host-package.md:9-17，docs/packages-reference.md:71-94）。
2. **ADR-0026：不建全局 unit factory/container。** 本对象是纯 Lua 航班，不是 ADR 定义的 Unit；保留 CreateUnit／OwnedUnits 原职责，不把 keyed route 所有权扩大成全局容器（docs/adr/0026-no-global-unit-factory.md:5-20，docs/adr/0026-no-global-unit-factory.md:45-55）。
3. **架构层归属不变。** MgrFerry 属 L2 应用流程，spoke 属 L6 包；依赖方向允许业务向包，包不得反向依赖业务。不要再建 Domain、Engine、Adapters 根包（docs/architecture.md:9-25）。
4. **共享世界与独立 route 不可倒退。** 六条去程／返程各有独立 id 与状态，重复交票不扣，搭便船合法（docs/GameSpec.md:329-335，docs/acceptance/08-npc-exchange-ferry.md:17-23，docs/acceptance/08-npc-exchange-ferry.md:34-39）。
5. **退款不是 detach 的通用副作用。** 缺锚点、传送失败、中断恢复各有 Save 记录、operation 去重和原因；正常到期、未赶上船采用不同结果（server/Mgr/MgrFerry.lua:119-143，server/Mgr/MgrFerry.lua:227-269，server/Mgr/MgrFerry.lua:272-285）。

## 9. 仍开放问题／未核对项

1. **待决策：范围外交票人的船票。** 实现注释与 Depart 明确“未赶上船不退票”（server/Mgr/MgrFerry.lua:5，server/Mgr/MgrFerry.lua:253-258），验收 8-31 却写不在范围内的玩家“也不因此损失船票”（docs/acceptance/08-npc-exchange-ferry.md:37）。两者对交票人未上船存在文字冲突；重构不得顺手改规则。
2. **待决策：断线重连的倒计时存续范围。** 当前是交票人退出即取消 route（server/Mgr/MgrFerry.lua:313-325），验收 8-33 要求重连后的进行中倒计时、所在区与服务端一致且不二次搬运／扣费（docs/acceptance/08-npc-exchange-ferry.md:39）。需明确该条款是否仅指未取消航班或搭便船者，不能把 keyed 所有权解释成恢复整个共享航班。
3. **未核对：真实关局／换场景清理。** 未运行宿主，不能声称关局会触发 OnPlayerRemoving、Destroying 或 tree dispose；若引入长寿命 SpokeTree，必须另取触发点证据。
4. **未核对：上游 docs/spec.md 原文。** 可核依据是当前仓 common/packages/spoke/ 的实际 implementation、随仓 spoke 契约说明及 ADR；未把未读到的上游文档当事实来源。
5. **资料缺口：** 当前工作区 design 路径不存在，未读到符号链接指向的策划原案；玩法结论仅采用 docs/GameSpec.md 与验收矩阵。
6. **未执行：** 按任务要求未运行任何测试或试玩，未测量性能，也未验证 spoke 在真实宿主中的新业务集成。

## 10. 最终建议与推荐强度调整

- **先做业务证明，不以采用 spoke 为目标。** 只有 keyed route 所有权能集中 pending/active 占用、operation 身份、取消原因与恢复查询，并通过 deletion test，才值得局部 deepening；否则保持现状比 shallow wrapper 更好。
- **spoke Dock 推荐强度下调为弱／暂缓。** 它缺少业务查询与终局原因，同 key replace 与拒单规则相反；首次业务引入还新增树总销毁问题，当前 leverage 不足。
- **若后续仍采用 spoke，广播与退款留在显式业务终局路径。** 正常到期、缺锚点、active 退出、pending 清理、恢复各自决定结果；通用 detach/cleanup 只清资源，绝不无条件发布 cancelled。
- **最小门槛不是“现有测试变绿”，而是新增反例能失败。** 正常出发完整广播序列不得含 cancelled，pending 退出不得取消新接管者航班。未补这两个可证伪点之前，不建议实施。
