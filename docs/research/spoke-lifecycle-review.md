# 服务端／客户端生命周期：spoke 五项深研汇总

- **日期**：2026-11-22（Asia/Shanghai）
- **方式**：5 个 subagent 并行研究，lead 交叉复核关键源码与结论。
- **边界**：只读业务实现与测试；未运行测试、未试玩、未修改业务代码、测试、ADR、GLOSSARY 或上游包。
- **证据口径**：下文“当前会失败”均为源码控制流导出的可证伪预测，不冒充实测结果；宿主真实销毁、关局和换场景行为另行核对。

## 一、总判断

初评把“生命周期缺陷值得修”和“值得引入 spoke”混在了一起。深研后应拆成两条独立排序：

1. **缺陷与分解优先级**：ScreenParty、LocalLoot 的重入清理缺口优先；ScreenMain 的双寿命局部分解有明确价值，但影响面更大。
2. **spoke 采用优先级**：五项中没有一项支持“直接换成就算深化”。LocalLoot 仅在 keyed child 真正吸收节点所有权时保留条件性中等推荐；其余为条件性中低、弱或暂缓。

**首要建议调整为：先修 ScreenParty 的真实重入与失败路径，再决定是否采用 spoke；不再把 spoke 本身列为强推荐。** 当前生产只发现一次入口启动，因此“开关屏已经导致重复订阅”没有证据；但 Start 明确考虑重入，而 Clear 没有连接所有权，implementation 缺陷仍然成立（client/ScreenHandlers/ScreenParty.lua:44-48、209-210、249-256；client/main.lua:63；client/MgrGameUI.lua:63-120）。

## 二、五项结论对照

| 候选 | 已证实的生命周期问题 | spoke / Dock 深研结论 | 修正后的推荐强度 | 详报 |
|---|---|---|---|---|
| ScreenParty | Start 重入追加 PartyState、PartyResult、Heartbeat；Clear 只清节点。EUI 早退与建点失败也缺统一回滚。 | tree 可拥有连接，但只搬三次 Connect 是 shallow wrapper；固定两行不需要 Dock，spoke_eggy 不代表多节点 HUD 或关局寿命。 | **缺陷修复：高；spoke：条件性中低；Dock：不推荐。** | [详报](spoke-lifecycle-party-hud.md) |
| 单个投掷飞行物 | 正常到期已在同一 Update 内摘记录、销毁视觉、Detonate；没有取消或提前命中入口。玩家退出后的继续／取消／引爆未决。 | 外部时钟、Update 和玩法终局仍需原 seam；只换树没有删除实质复杂性。spoke_eggy 主从方向也不匹配“逻辑拥有可选视觉”。 | **spoke：低优先、暂缓。** 玩法确认后再评估 exactly-once 局部深化。 | [详报](spoke-lifecycle-throw-flight.md) |
| LocalLoot | 三个宿主连接无 Stop；重复 Start 会叠加回调。节点 Clear 先摘索引再静默 pcall Destroy，失败会留下不受管根。 | Dock 不会自动做 alive 快照 reconciliation；同 key call 会 replace，不能逐快照无条件调用。只有删除 Nodes/Clear 的第二套资源所有权才有 depth。 | **连接与 Stop：高；Dock：中等、附条件。** | [详报](spoke-lifecycle-loot-dock.md) |
| ScreenMain | RootNode 与 Open/Close 已是两种寿命；部分初始化、Cleanup 失败阻断、两类 Delay 代次是具体风险。 | 只把 Connections 换成 on_cleanup 是 shallow wrapper；所有监听不能整体搬进 Open Phase，Close 后仍有根寿命工作。 | **局部分解：强；spoke：有条件弱推荐／最小试点；全量重写：不推荐。** | [详报](spoke-lifecycle-main-hud.md) |
| 摆渡航班 | BoardPending 与 Flights 表达同一 route 的不同阶段；退出扫描与业务终局分散，但只有六条 route，无性能问题证据。 | Dock 缺业务查询、operation 身份和取消原因；同 key replace 与拒单规则相反。cleanup 不等于 cancelled，退款也不能成为通用 detach 副作用。 | **keyed route 所有权：有条件中等；直接 Dock：弱／暂缓。** | [详报](spoke-lifecycle-ferry-flight.md) |

## 三、逐项核心证据与最小反例

### 1. ScreenParty：先证明重入缺陷，再选实现

- 生产可见启动只有 client/main.lua 的一次 Task:Spawn；MgrGameUI 不调用 ScreenParty.Start/Clear。不能把当前缺陷夸大为已经由开关屏触发（client/main.lua:63；client/MgrGameUI.lua:63-120）。
- Start 的注释与控制流明确考虑重入，PartyState、PartyResult、Heartbeat 却没有 Disconnect；这是所有权问题，不是 fake 造成的生产根因（client/ScreenHandlers/ScreenParty.lua:209-210、249-256）。
- **最小 P0**：同一 panel Start→Start 后，各发一次失败 PartyResult 与带 notice 的 PartyState；玩家应各只看到一条通知，当前预测为两条。再让 fake Disconnect 真正移除监听，观察三类 active listener 各为一（tests/native/spec/09_party_hud_test.lua:11-19、62-64、191-202）。
- 若 Clear 被定义为完整 teardown，Start→Clear 后三连接应为零；若仍只清节点，必须另指认完整退出点，不能偷偷改合同。

### 2. 投掷飞行物：正常路径已集中，先暂缓迁移

- Flying 只有发射追加与到期删除；正常到期顺序是“摘记录 → 销毁视觉 → Detonate”，不存在飞行中碰撞命中入口（server/Mgr/MgrWeapon.lua:610-633、437-473）。
- OnPlayerRemoving 只清挥砍和 States，不清 Flying；继续、取消或立即引爆是玩法选择，不由框架决定（server/Mgr/MgrWeapon.lua:681-684）。
- **最小补证**：在现有 weapon_system_test seam 记录视觉 Destroy 次数，验证到期前不销毁、到期后记录／视觉／爆炸各一次；CreateUnit 失败仍须保持逻辑到期结算（tests/native/weapon_system_test.lua:420-465、538-566）。
- 玩家退出测试必须先有已确认玩法，再写继续／取消／引爆三种互斥期望之一。

### 3. LocalLoot：保留业务差集，区分 keyed 身份与整体 Stop

- alive 是 LootState 快照的业务 reconciliation，不是 Dock 已提供的功能；同 id 当前保留节点，只更新 Warning，而无条件 Dock:call 会 drop 旧 child 再 attach（client/LocalLoot.lua:45-55；common/packages/spoke/runtime/dock.lua:50-59）。
- 三个 Start 连接无保存者，Heartbeat 重复会累加 Blink；Dock 不负责这些连接的退订（client/LocalLoot.lua:85-96）。
- **最小反例**：同 id 重复快照不得重建；id 消失再出现必须销毁旧根并创建新根；重复 Start 不得倍增通知／Blink；Stop 后旧事件不得创建或修改节点。
- 只有 keyed child 真拥有场景根并删除第二套 Nodes/Clear 所有权时才采用 Dock；保留 alive 不是失败。

### 4. ScreenMain：按两种寿命分解，不能整体迁到 Open Phase

- MgrGameUI 按 RootNode 身份触发 Init；ScreenMain 换根先 Cleanup。OpenScreen/CloseScreen 则每次都会调用，即使 Visible 没变化（client/MgrGameUI.lua:43-58、67-111；client/ScreenHandlers/ScreenMain.lua:1260-1271）。
- RemoteEvent、属性和 Heartbeat 当前属于根寿命；Close 保留这些连接和收线会话，不能全部变成 Open 条件寿命（client/ScreenHandlers/ScreenMain.lua:1174-1189、1469-1616、1668-1672）。
- 属性 Delay 依赖 Inited+BoundRootNode，战斗 Delay 依赖 IsOpen+CombatRequest token；两种代次保护都必须保留（client/ScreenHandlers/ScreenMain.lua:1611-1616、1641-1649）。
- **最小反例**：A→B 换根后，A 的连接只断一次、OwnedUnits 清空，A 的延迟回调不得给 B 安装监听；重复 Open/Close 不叠加节点与连接；故障注入后旧匿名连接不得失联。

### 5. 摆渡航班：drop 不是业务终局

- 正常到期先删 Flights 再 Depart，Depart 可能 departed，也可能缺锚点 cancelled；active 玩家退出也删除并 cancelled。因此通用 detach 绝不能无条件广播 cancelled（server/Mgr/MgrFerry.lua:227-245、269-270、288-301、313-325）。
- pending 退出只删除不广播；旧 Save 回调通过 flight 对象与 operation 身份避免删除新航班（server/Mgr/MgrFerry.lua:102-116、313-325）。
- **关键新反例**：正常出发的完整广播序列不得含 cancelled；现有测试只查最后一条是 departed，会漏掉“先 cancelled 后 departed”（tests/native/ferry_test.lua:348-362）。pending 退出也要精确断言无 cancelled 且旧回调不影响接管者（tests/native/ferry_test.lua:428-439）。
- “未上船是否退票”和“重连倒计时存续范围”存在待澄清规则，重构不得顺手改变（server/Mgr/MgrFerry.lua:253-258；docs/acceptance/08-npc-exchange-ferry.md:37-39）。

## 四、统一约束

- ADR-0022／0024：common/packages/spoke 与 spoke_eggy 为上游整包拷贝，不就地修改。
- ADR-0026：保留 CreateUnit 调用点与 OwnedUnits，不新增全局 unit factory/container；树不得成为第二套单位所有权。
- server/main.lua 的 MgrMap 继续拥有 manager Start／join／leave／Update 分发 seam；spoke 不替代 Heartbeat、宿主时钟、Save 或 Task.Delay。
- spoke_eggy.behaviour 绑定显式 Unit.Destroying，不覆盖 Visible 开关、关局或所有多节点 module；非 Unit 树需要明确 dispose 所有者。
- 不因采用 Dock 而复制一套 registry；不为了“统一”引入通用生命周期框架。

## 五、建议顺序

1. **ScreenParty**：先用现有公共 seam 钉住重入通知与连接反例，修共同所有权和失败回滚；spoke 是否采用另过 deletion test。
2. **LocalLoot**：并行明确 Stop 调用者、重复 Start、迟到事件和 Destroy 失败策略；之后再判断 keyed child 是否真实吸收根寿命。
3. **ScreenMain**：只把 RootNode 与 Open/Close 的资源归属、失败隔离和代次保护整理清楚，不做全量响应式重写。
4. **摆渡**：先补 cancelled 精确反例并澄清退款／重连规则，再评估 keyed route 深化；不直接 Dock 化。
5. **投掷飞行物**：暂缓 spoke；先补视觉 exactly-once 观察，等退出／取消玩法定案后再评审。

这五份报告是后续 grilling 的输入，不是实施计划，也尚未设计具体 interface。选择某一项后，再逐项确认合同、宿主触发点、玩法分支与测试口径。

## 六、定案与实施合同

五项合同、公共测试 seam、宿主证据边界及“本轮不采用 spoke”的 deletion test 结论见 [spoke 生命周期五项定案与实施合同](spoke-lifecycle-decisions.md)。Q1～Q27 由用户按推荐确认；Q28～Q31 和其余细节由用户授权 lead 按推荐定案。
