# 单个投掷飞行物寿命与 spoke 适配研究

- 调查日期：2026-11-22（Asia/Shanghai）
- 调查范围：`server/Mgr/MgrWeapon.lua` 中单个投掷飞行物的 `Launch` / `Flying` / `Update` / 视觉单位销毁 / `OnPlayerRemoving`
- 调查方式：只读当前仓库源码、测试、ADR 与 spoke 实际实现；未修改业务代码、测试、上游包，未运行测试或试玩
- 结论口径：源码能证明的是调用与状态转移；宿主对离线玩家、已销毁单位和关局的实际行为，未核实的不作推断

## 一、结论摘要与推荐强度

**建议把“用 spoke 收编单个投掷飞行物寿命”的推荐强度下调为低优先、暂缓。** 当前正常到期路径已经在同一处依次完成逻辑记录摘除、视觉销毁和爆炸结算，尚未证明存在必须用 spoke 才能修复的寿命缺陷（`server/Mgr/MgrWeapon.lua:625-637`）。真正未决的是玩家退出后的玩法语义，以及取消、外部视觉销毁等尚不存在的路径；在这些决策完成前引入树生命周期，容易把玩法选择误写成框架默认行为。

spoke 核心的 Epoch cleanup 与“一个飞行记录拥有一个可选视觉单位”的所有权关系**局部匹配**，但它不提供 SE 心跳，也不决定玩家退出策略。若仍由 `MgrWeapon:Update` 驱动 Manual 树、由 `OnPlayerRemoving` 决定收尾，再让树执行同样的清理，deletion test 显示：删掉 spoke、保留同一个本地收尾过程，现有可观察行为可以完全不变。因此当前形状更像 shallow wrapper，而不是 deep module。

可以保留一个更窄的后续候选：仅当实现同时收拢“到期、取消、玩家退出”的终态去重、视觉所有权和结算顺序，使调用者不再分别理解这些不变量时，才可能形成有 depth 的 module。那是玩法决策后的局部寿命整理，不是 spoke 迁移，也不应扩展为整个 `MgrWeapon` 改造。

## 二、范围与非目标

### 范围

1. `Flying` 的所有写入、读取和删除。
2. 发射、逐帧位置更新、到期爆炸、视觉单位创建与销毁。
3. `OnPlayerRemoving` 对飞行记录的直接或间接影响。
4. 现有 native 测试的 seam、adapter 与最小回归缺口。
5. spoke 核心 Epoch / SpokeTree 及 spoke_eggy 的寿命语义是否匹配。

### 非目标

- 不迁移整个 `MgrWeapon`，不讨论近战、枪械、弹匣、动画或存档协议重构。
- 不设计新 interface、函数签名、补丁或通用飞行物框架。
- 不决定玩家退出后继续飞行、取消还是立即引爆。
- 不修改 `common/packages/spoke/`、`common/packages/spoke_eggy/`，不新增全局 unit factory/container。
- 不把 native fake 的结果当作宿主真实销毁、离线玩家或关局行为证据。

## 三、现有寿命与所有权时间线

| 阶段 | 当前实现事实 | 所有权 / 寿命含义 |
|---|---|---|
| 消耗与发射 | 无存档路径扣减物品后直接调用 `Launch`（`server/Mgr/MgrWeapon.lua:507-523`）；持久模式只在 `Save:Execute` 成功回调中发射，重放不再次发射（`server/Mgr/MgrWeapon.lua:526-548`、`server/Mgr/MgrWeapon.lua:550-566`） | 飞行物寿命始于消费成功之后，不是客户端请求到达时 |
| 逻辑记录创建 | `Launch` 解析落点，并捕获 `player`、`itemId`、起点、落点、水区、`startAt`、`flightSec`（`server/Mgr/MgrWeapon.lua:603-609`） | 每条记录独立持有投掷者引用；没有按玩家建立二级索引 |
| 视觉创建 | 先递增模块内 `ThrowSeq`，名字含 `UserId` 与序号；`CreateUnit('TriggerUnit', ...)` 由 `pcall` 包裹（`server/Mgr/MgrWeapon.lua:586-600`） | 视觉是逻辑记录的 optional 字段；创建失败只打印，不阻断结算（`server/Mgr/MgrWeapon.lua:598-600`、`server/Mgr/MgrWeapon.lua:610`） |
| 登记 | 视觉创建之后才追加到 `self.Flying`（`server/Mgr/MgrWeapon.lua:610-611`） | `Flying` 是逻辑记录的唯一仓库内登记处；当前没有 `OwnedUnits` 登记 |
| 推进 | `server.main` 的 Heartbeat 遍历 `MgrMap` 调用各管理器 `Update`（`server/main.lua:302-307`、`server/main.lua:330`）；`MgrWeapon:Update` 用 `World:GetServerTime` 计算 `t`（`server/Mgr/MgrWeapon.lua:42-45`、`server/Mgr/MgrWeapon.lua:625-629`） | 时间由服务端墙钟推进，不依赖 `deltaTime` 累加；现有 MgrMap 分发就是必须保留的 seam |
| 飞行中 | `t < 1` 时只更新视觉 `Position`，写入由 `pcall` 包裹（`server/Mgr/MgrWeapon.lua:618-623`、`server/Mgr/MgrWeapon.lua:634-635`） | 视觉更新失败不改变逻辑记录寿命 |
| 正常到期 | `t >= 1` 时顺序为 `table.remove` → `visual:Destroy()` → `Detonate`（`server/Mgr/MgrWeapon.lua:630-633`） | **正常代码路径中视觉与逻辑记录同一次 Update 收尾，但不是原子操作**；记录先摘除，视觉销毁与爆炸随后发生 |
| 爆炸结算 | `Detonate` 读取爆炸物配置与伤害倍率，水中先生成保底鱼，再做径向伤害（`server/Mgr/MgrWeapon.lua:456-473`） | 没有飞行途中碰撞命中入口；“命中”发生在到期后的 `RadialDamage`，其玩家与鱼遍历见 `server/Mgr/MgrWeapon.lua:437-453` |

`Flying` 在业务源码中的全部引用只有声明（`server/Mgr/MgrWeapon.lua:20`）、追加（`server/Mgr/MgrWeapon.lua:611`）、倒序遍历读取（`server/Mgr/MgrWeapon.lua:627-628`）和到期删除（`server/Mgr/MgrWeapon.lua:631`）。因此当前不存在第二条逻辑删除路径，也不存在提前命中、主动取消或玩家退出清理 `Flying` 的 implementation。

## 四、所有清理路径与缺口

### 已有路径

1. **正常到期**：唯一同时清理逻辑记录和视觉单位的路径，见 `server/Mgr/MgrWeapon.lua:630-633`。
2. **视觉创建失败**：没有视觉可清理；逻辑飞行仍继续，符合源码注释“不影响结算”，见 `server/Mgr/MgrWeapon.lua:590-600`、`server/Mgr/MgrWeapon.lua:610-614`。
3. **玩家退出**：仅清除挥砍登记与 `States[userId]`，不触碰 `Flying`，见 `server/Mgr/MgrWeapon.lua:681-684`。入口确实会把 `OnPlayerRemoving` 分发给 `MgrWeapon`，见 `server/main.lua:275-278`。

### 缺口与不能混淆的事实

- **退出后的源码路径**：由于退出不删记录，后续 Heartbeat 仍会推进该记录；到期会把之前捕获的 `player` 传进 `Detonate`（`server/Mgr/MgrWeapon.lua:606-611`、`server/Mgr/MgrWeapon.lua:625-633`）。这只是当前控制流事实，不代表“继续飞行”已被策划确认，也不证明离线玩家对象在宿主中仍可安全用于数据、倍率、命中归属和鱼生成。
- **视觉销毁失败**：`Destroy` 的 `pcall` 没有日志、重试或归属登记，且记录已先摘除（`server/Mgr/MgrWeapon.lua:631-632`）。源码只能证明失败后不再由该记录重试；单位是否真实残留未在宿主核实。
- **视觉被外部销毁**：仓库内没有 `flight.visual.Destroying` 监听，也没有其他 `ThrowProjectile` 销毁点；视觉显式销毁不会由现有业务代码反向删除 `Flying`。宿主是否有额外级联清理未核实。
- **取消与提前命中**：没有对应入口，因而不存在可复用的取消清理路径。不能把正常到期路径改个名字就宣称这些语义已覆盖。
- **异常顺序**：记录摘除和视觉销毁均先于 `Detonate`；爆炸异常不会恢复飞行记录。入口对整个管理器 `Update` 使用 `pcall`（`server/main.lua:302-307`），实际错误表现未在本轮运行验证。
- **所有权登记缺口**：视觉仅挂在 `flight.visual`，当前文件没有 `OwnedUnits` 引用。若后续触及该建点，必须同时落实 ADR-0026 的归属登记与回收规则，不能用 SpokeTree 代替 `OwnedUnits`。

## 五、spoke 语义是否匹配

### 1. spoke 核心：cleanup 匹配，时间与玩法决策不匹配

- `EpochBuilder:on_cleanup` 把清理函数记录到 owning Epoch（`common/packages/spoke/runtime/epoch_builder.lua:83-89`）；`s:use` 也可持有 disposable（`common/packages/spoke/runtime/epoch_builder.lua:91-100`）。这符合“资源由单个飞行 Epoch 所有”的方向。
- teardown 按 attachment 逆序释放，单个 cleanup 失败会记录并继续其余清理（`common/packages/spoke/runtime/epoch_teardown.lua:1-5`、`common/packages/spoke/runtime/epoch_teardown.lua:19-36`、`common/packages/spoke/runtime/epoch_teardown.lua:49-61`）。这比当前分散 `pcall` 更明确地表达清理顺序。
- `Epoch:detach` 幂等，活动 frame 中延迟拆除（`common/packages/spoke/runtime/epoch.lua:115-138`）；`SpokeTree:dispose` 只是 detach（`common/packages/spoke/runtime/spoke_tree.lua:177-178`）。这能支持未来多个终态入口的去重，但**不会自行决定哪个终态应该发生**。
- Auto 树由 `SpokeRuntime` 同步 schedule / flush，不是 SE Heartbeat adapter（`common/packages/spoke/runtime/spoke_tree.lua:100-112`、`common/packages/spoke/runtime/spoke_runtime.lua:99-107`、`common/packages/spoke/runtime/spoke_runtime.lua:155-176`）。Manual 树只能由消费方显式 `tick` / `flush`（`common/packages/spoke/runtime/spoke_tree.lua:152-175`）。所以逐帧视觉推进仍需现有 `MgrMap.Update` 节拍；引入树不会删掉这层调用知识。

**判定：局部语义匹配，整体 leverage 不足。** 若每发一棵 Manual 树而 `MgrWeapon` 仍保存、遍历、驱动并决定退出行为，interface 增加的内容接近被隐藏的 implementation，属于 shallow。若改用 Auto 让 Epoch 自行连续 request Tick，也不能把它解释为“一帧一次”；这不是当前 Heartbeat 寿命模型的等价替换。

### 2. spoke_eggy：主从方向不适合直接套用

spoke_eggy 把 Auto 树绑定到 `Unit.Destroying`，dispose 时先翻 `is_alive`，再拆树并断开连接（`common/packages/spoke_eggy/api.lua:137-145`、`common/packages/spoke_eggy/api.lua:190-196`、`common/packages/spoke_eggy/api.lua:233-249`）。但当前业务是**逻辑到期拥有并销毁视觉**，视觉还允许创建失败；把逻辑树寿命反过来绑定到 optional 视觉，会引入“视觉外部销毁是否取消或引爆”的新问题。

此外 ADR-0024 明确 `is_alive` 只覆盖显式销毁，不覆盖关局（`docs/adr/0024-introduce-spoke-eggy-host-package.md:21-24`）。它更不能替代 `OnPlayerRemoving` 的玩法决策。因此本候选不应以 spoke_eggy 作为默认 adapter。

### 3. Deletion test

| 删除对象 | 若其余代码保留什么 | 可观察行为是否必然受损 | 判断 |
|---|---|---|---|
| 只删除 SpokeTree / Epoch | 保留同一飞行记录、同一个终态收尾过程和现有 Heartbeat 驱动 | 正常到期、视觉销毁、爆炸都可保持完全一致 | spoke 当前不是 depth 的来源 |
| 删除候选 module、回到现有分散入口 | 若候选只包装 `Launch` / `StepVisual` / `Update` | 不损失新业务行为 | shallow wrapper，应拒绝 |
| 删除一个真正收拢终态去重、视觉所有权、退出策略的 module | 调用者需重新分别处理到期、取消、退出及顺序 | 会损失实质行为与 locality | 才可能成为 deep module；前置条件是先定玩法 |

## 六、locality、leverage 与测试收益

- **现状 locality 并不差**：`FlightPosition`、视觉创建、`Launch`、`StepVisual`、`Update` 已连续放在 `server/Mgr/MgrWeapon.lua:573-638`。把这几行换成树声明，主要改变 implementation 形状，不自动提升 locality。
- **潜在 locality 收益在终态而非轨迹**：未来若到期、取消、退出都有入口，统一“只收尾一次、视觉只清一次、结算是否发生”的不变量才有价值。玩家退出策略未定时，无法证明这项收益。
- **leverage 不应按代码行数计算**：如果调用者仍须理解树模式、节拍、dispose 时机、视觉外部销毁和玩家退出，新的 interface 不比现有 `Flying` 记录更简单。只有隐藏这些终态不变量才增加 depth。
- **adapter 已存在**：native 测试用 fake `World` 提供可控时钟和 `CreateUnit`（`tests/native/weapon_system_test.lua:420-442`），用 fake `Vitals` / `FishUnit` 观察结算（`tests/native/weapon_system_test.lua:448-465`）。这些已构成测试 seam，不需要为 spoke 再增加生产专用 adapter。
- **测试收益目前有限**：现有测试已证明到期后 `Flying` 从 1 变 0 并生成保底鱼（`tests/native/weapon_system_test.lua:538-551`），也证明两发在飞时名称可区分（`tests/native/weapon_system_test.lua:553-566`）。但 fake `Destroy` 是空函数（`tests/native/weapon_system_test.lua:432-437`），未断言视觉销毁次数，也没有飞行中的 `OnPlayerRemoving` 用例。

## 七、最小可证伪验证

以下只在后续实际改动时实施，本轮未运行：

1. **先补现有到期用例的视觉观察，不另造一套树测试。** 在现有 `TestMgrWeaponThrow` adapter 中保留返回的视觉 fake 并记录 `Destroy` 次数；沿 `Launch → Update` 公共入口断言：到期前不销毁，到期后记录摘除、每个视觉销毁一次、爆炸只发生一次。它直接证伪“视觉与逻辑不同寿命”和“重复终态”两类回归，且不会与现有 `test_projectile_flies_then_detonates_in_water` 重复记录/结算覆盖。
2. **玩家退出用例必须先选择一种已确认玩法，再写对应期望。** 用同一测试 seam 发射退出发起者与另一玩家各一发，调用现有 `OnPlayerRemoving`，再推进时间；只断言被确认的继续 / 取消 / 引爆之一，并验证另一发不受影响、后续 Update 不二次结算。三种互斥期望不应同时写成“覆盖”。
3. **保留视觉可缺失契约。** 让 `CreateUnit` 失败，验证逻辑记录仍能到期并按既有规则结算；否则 refactor 会把当前明确的“视觉失败不影响结算”悄悄改成新约束。
4. **若新增取消路径，再补取消与到期竞争的最小用例。** 先取消再推进到原到期时刻，验证既定取消语义和 exactly-once 清理；当前没有取消入口，不应提前编写实现耦合测试。
5. **宿主验证另列。** native fake 只能证明调用次数，不能证明真实 `TriggerUnit` 已销毁、离线 `Player` 可用或关局已清理。涉及这些结论时需试玩 / 日志取证，不能由 spoke_eggy 的 `is_alive` 推断。

测试应继续通过现有 `MgrWeapon` interface 观察行为，不断言 Epoch 内部 attachment、坐标或树状态，符合“interface 是测试面”和 replace-don't-layer 原则。仓库测试纪律也要求只写有明确失败方式的行为用例（`docs/agents/workflow.md:91-98`）。

## 八、ADR、架构与玩法约束

1. **ADR-0022 / ADR-0024**：spoke 与 spoke_eggy 都是上游整包拷贝，不得就地修改；需要库行为变化必须回上游（`docs/adr/0022-introduce-spoke-runtime.md:7-14`、`docs/adr/0024-introduce-spoke-eggy-host-package.md:7-13`）。本候选没有已证明需要上游新行为的缺口。
2. **ADR-0026**：不得新增全局 unit factory 或统一挂载容器；`CreateUnit` 保留局部建点，`OwnedUnits.Track/Clear` 负责“谁建谁拆”（`docs/adr/0026-no-global-unit-factory.md:12-21`）。正在改的建点需登记并写清回收路径，不能以树、父节点或全局容器替代（`docs/adr/0026-no-global-unit-factory.md:37-54`）。
3. **MgrMap seam**：`MgrWeapon` 已在 `MgrMap` 登记（`server/main.lua:14-34`），Heartbeat 与退出统一分发（`server/main.lua:275-278`、`server/main.lua:302-307`）。若未来提取内部 module，也不应新增管理器或绕过该入口。
4. **分层方向**：`server.Mgr` 属 L2，`common.packages` 属 L6，业务向包依赖方向允许；包不得反向依赖业务（`docs/architecture.md:7-23`）。这不构成必须引入包的理由。
5. **玩法未定**：已确认结论只明确爆炸物按件消耗等规则（`docs/策划案已确认结论.md:122-123`），未找到玩家退出时飞行物处理的已定结论。`Throw.FlightSec` 与 `ArcHeight` 也仍标为待策划确认的暂取值（`common/GameCfg.lua:1045-1048`、`common/GameCfg.lua:1122-1129`）。不得借技术重构偷偷确定退出语义或数值。

## 九、未核对项与仍开放问题

### 未核对的宿主行为

- 玩家退出后，被捕获的旧 `player` 在 `PlayerData`、`Attr`、`Vitals:NewHit`、`SpawnBlastFish` 中的真实表现。
- `TriggerUnit:Destroy()` 抛错时宿主是否仍销毁单位，以及世界根单位在关局 / 换场景时的实际回收。
- 视觉被外部或级联销毁时，当前地图是否存在仓库 Lua 之外的触发逻辑。
- 当前 Heartbeat 下 `Update` 内异常的实际日志与后续帧表现；本轮未运行测试或试玩。

### 待玩法 / 设计决策

1. 投掷者退出后，在飞记录应继续、取消还是立即引爆？若继续，伤害来源、升级倍率和水中保底鱼归属采用哪个会话？
2. 视觉被提前销毁时，逻辑飞行应不受影响、取消还是引爆？视觉只是表现还是寿命所有者？
3. 未来是否需要主动取消；若需要，取消是否结算、是否返还物品，均不能从当前代码推定。
4. 视觉销毁失败是否需要可观察日志、补偿或仅按现有 best-effort 处理。

## 十、最终建议

- **spoke 迁移：低优先、暂缓，较“可尝试的中等推荐”明显下调。**
- **局部寿命缺口整理：可保留为候选，但必须先定退出与取消玩法，再以 exactly-once 终态和 `OwnedUnits` 归属为验收中心。**
- **不接受只把 `Flying` 数组换成若干树、却仍保留同样外部节拍与清理知识的 shallow wrapper；也不为此建设通用 Ticker、unit factory 或 container。**
- 后续评审应要求候选通过 deletion test：删掉候选 module 后，若只是少了一层调度包装而没有重新分散实质终态行为，就不应实施。
