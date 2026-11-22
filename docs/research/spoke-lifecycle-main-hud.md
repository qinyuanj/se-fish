# ScreenMain 的 RootNode 重建寿命与 Open/Close 寿命：spoke 适配研究

## 结论摘要

- **强推荐只做局部分解**：把 RootNode 身份变化对应的 `Init/Cleanup` 与界面显示变化对应的 `OpenScreen/CloseScreen` 分开核对；不做全量 `ScreenMain` 响应式重写。
- **对“为此引入 spoke”的推荐强度下调为有条件、弱推荐**。若只是把 `Connections` 数组换成一批 `on_cleanup`，它是 shallow wrapper，不增加 depth；只有逆序清理、失败隔离、Open 子结构挂载与代次失效成为真实保证时才有 leverage。
- 不能把现有监听整体迁到 Open/Close 寿命。多条 RemoteEvent、玩家属性和 Heartbeat 在关屏后仍连接，部分回调用 `IsOpen` 选择是否更新；关屏明确保留收线会话，见 `client/ScreenHandlers/ScreenMain.lua:1469-1587`、`client/ScreenHandlers/ScreenMain.lua:1591-1606`、`client/ScreenHandlers/ScreenMain.lua:1668-1672`。
- `spoke_eggy` 只覆盖 Unit 显式销毁，不覆盖 Visible 开关或关局，见 `common/packages/spoke_eggy/api.lua:16-19`、`common/packages/spoke_eggy/api.lua:189-197`。MgrGameUI 的 Open/Close 只改 Visible，见 `client/MgrGameUI.lua:67-88`、`client/MgrGameUI.lua:95-111`。
- 本次仅研究；**未运行测试，未修改业务代码、测试、ADR、上游包或 HTML**。

## 1. 范围与非目标

### 范围

1. `client/MgrGameUI.lua:27-60`：GetScreen 查找/赋值 RootNode、按根身份决定是否 Init。
2. `client/MgrGameUI.lua:63-112`：Open/Close 的 Visible、动画回调与 handler 调用顺序。
3. `client/ScreenHandlers/ScreenMain.lua:1174-1249`：连接登记与 Cleanup。
4. `client/ScreenHandlers/ScreenMain.lua:1260-1624`：RootNode 绑定、建点、监听、Heartbeat、延迟任务。
5. `client/ScreenHandlers/ScreenMain.lua:1626-1678`：Open/Close/Destroy。
6. spoke/spoke_eggy 当前实现及已存在的 main HUD 原生测试 seam。

### 非目标

- 不重写道具栏、背包、任务、对话、战斗、瞄准或收线逻辑；不把所有字段改成 State、所有渲染改成 Effect。
- 不设计通用 UI 生命周期框架，不设计新 interface、函数签名或补丁。
- 不迁移 `CreateUnit`，不引入全局 unit factory/container；保留 `OwnedUnits`。
- 不处理无关动画问题；旧动画回调只登记重入风险。

## 2. 现有寿命与所有权时间线

### 2.1 RootNode 获取、同根复用与换根重建

MgrGameUI:GetScreen 的实际顺序：

1. 从当前 UIRoot 找节点，找不到返回，见 `client/MgrGameUI.lua:27-38`。
2. 从 `ScreenHandlerLoaders` 取 handler，先写 `ScreenName`、`RootNode`，见 `client/MgrGameUI.lua:39-46`。
3. 未初始化或 `BoundRootNode ~= screenNode` 时进入 Init；否则不调用，见 `client/MgrGameUI.lua:47-58`。
4. ScreenMain:Init 同根直接返回；换根先 Cleanup，再绑定新根，见 `client/ScreenHandlers/ScreenMain.lua:1260-1271`。
5. 建点、监听和延迟任务安装后，才写 `BoundRootNode`、`Inited=true`、`IsOpen=false`，见 `client/ScreenHandlers/ScreenMain.lua:1618-1623`。

因此 handler 表可复用，**RootNode 身份决定一轮根寿命**。Cleanup 前 RootNode 已被换成新节点；清理仍持有上一轮节点引用和连接表，但 `self.RootNode` 已是新根，这是必须显式保留的顺序约束。

### 2.2 Open 与 Close

Open：

1. MgrGameUI 必要时先设 Visible，再写 `curShowMap`，最后调用 handler OpenScreen，见 `client/MgrGameUI.lua:63-88`。
2. ScreenMain 先 Bind 两个浮动表现模块，再置 `IsOpen=true`、打开攻击键，随后刷新显示并发送状态请求，见 `client/ScreenHandlers/ScreenMain.lua:1626-1639`。
3. 最后建立本轮 `CombatRequest` token 和 0.6 秒延迟补取，再请求 Story，见 `client/ScreenHandlers/ScreenMain.lua:1640-1652`。

Close：

1. MgrGameUI 必要时设不可见，再清 `curShowMap`，最后调用 CloseScreen，见 `client/MgrGameUI.lua:91-111`。
2. ScreenMain 先收对话、失效 CombatRequest、清浮动表现，然后才置 `IsOpen=false`；之后清临时提示、结束瞄准、关弹窗、关攻击键，见 `client/ScreenHandlers/ScreenMain.lua:1655-1667`。
3. 最后 Suspend 本地收线、清 `CastState/SplashUntil` 并刷新 Cast 表现，见 `client/ScreenHandlers/ScreenMain.lua:1668-1672`。

**MgrGameUI 即使已 Visible 也仍调用 OpenScreen，即使已不可见也仍调用 CloseScreen**，因为调用在 Visible 条件块之外，见 `client/MgrGameUI.lua:67-88`、`client/MgrGameUI.lua:95-111`。两者都是重复可进入流程。

### 2.3 Destroy

`ScreenMain:Destroy` 调 Cleanup，再把 `RootNode=nil`，见 `client/ScreenHandlers/ScreenMain.lua:1675-1678`。本次对 `client/` 的定向搜索未发现 screenHandler/handler 的 Destroy/Cleanup 生产调用；动态宿主调用未核对，不能据此宣称永不调用。

## 3. 连接、计时器与状态的寿命归属

### 3.1 RootNode 重建寿命

| 资源/状态 | 当前依据 | 应守住的语义 |
| --- | --- | --- |
| BoundRootNode、Inited、节点引用、Slots、HudLayout、LayoutKey | 建立于 `client/ScreenHandlers/ScreenMain.lua:1260-1435`，清于 `client/ScreenHandlers/ScreenMain.lua:1189-1248` | 跟 RootNode 身份走；Close 不拆 |
| Connections 及所有经 Listen 登记的连接 | `client/ScreenHandlers/ScreenMain.lua:1174-1176`、`client/ScreenHandlers/ScreenMain.lua:1285-1288`、`client/ScreenHandlers/ScreenMain.lua:1183-1189` | 当前全是根寿命；不能因 Close 全断 |
| 道具、任务、对话按钮连接 | `client/ScreenHandlers/ScreenMain.lua:1308-1313`、`client/ScreenHandlers/ScreenMain.lua:1372-1375`、`client/ScreenHandlers/ScreenMain.lua:1404-1416` | 跟其子节点走 |
| ItemBar、SpecialItem、Weapon、Cast、Quest、Story 等 RemoteEvent | `client/ScreenHandlers/ScreenMain.lua:1469-1587` | 当前根寿命；是否处理 payload 另由 IsOpen 等条件决定 |
| RunService Heartbeat | `client/ScreenHandlers/ScreenMain.lua:1588-1606` | 当前根寿命，Close 后仍连接 |
| FishCoin/Health/Hunger 属性连接 | `client/ScreenHandlers/ScreenMain.lua:1251-1257`，由 `client/ScreenHandlers/ScreenMain.lua:1608-1616` 延迟安装 | 根寿命；旧根延迟回调必须失效 |
| OwnedUnits.Track(self, ...) 节点与 AIM_OWNER | 例见 `client/ScreenHandlers/ScreenMain.lua:1290-1305`、`client/ScreenHandlers/ScreenMain.lua:1359-1366`；清于 `client/ScreenHandlers/ScreenMain.lua:1184-1188` | 根寿命；瞄准层另有即时回收 |
| LocalAttackButton Start/Destroy | `client/ScreenHandlers/ScreenMain.lua:1618`、`client/ScreenHandlers/ScreenMain.lua:1182` | Start/Destroy 根寿命；SetOpen 开屏寿命 |
| DamageFloat、FishCombatLabel Bind/Clear | `client/ScreenHandlers/ScreenMain.lua:1270-1271`、`client/ScreenHandlers/ScreenMain.lua:1626-1628`、`client/ScreenHandlers/ScreenMain.lua:1658-1659` | 跨两种寿命，不能机械归类 |

候选段没有 `TimerService:CreateTimer`；实际异步资源是两个 `Task:Delay` 加一个 Heartbeat 连接，不能统称 Timer。

### 3.2 Open/Close 寿命

| 资源/状态 | 当前依据 | 寿命语义 |
| --- | --- | --- |
| IsOpen、攻击键 SetOpen | `client/ScreenHandlers/ScreenMain.lua:1629-1630`、`client/ScreenHandlers/ScreenMain.lua:1660-1667` | 每次显示/隐藏切换 |
| CombatRequest 与 0.6 秒补取 | `client/ScreenHandlers/ScreenMain.lua:1640-1649`、`client/ScreenHandlers/ScreenMain.lua:1655-1657` | Open 代次；旧任务不得污染新一轮 |
| FailureUntil、FailureLanding、FailureNotice | `client/ScreenHandlers/ScreenMain.lua:1661-1664` | 开屏轮次临时提示 |
| 对话、弹窗、瞄准开放状态 | `client/ScreenHandlers/ScreenMain.lua:1655-1666` | Close 收尾；节点和监听仍属根寿命 |
| CastState、SplashUntil | `client/ScreenHandlers/ScreenMain.lua:1670-1672` | Close 清本地显示快照；不取消服务端收线 |
| Open 状态补取 | `client/ScreenHandlers/ScreenMain.lua:1635-1639`、`client/ScreenHandlers/ScreenMain.lua:1651-1652` | 每次 OpenScreen 执行，包括重复 Open |

### 3.3 跨开关或跨根状态

- 收线客户端会话 Close 只 Suspend，不主动取消；重开也不重建会话，见 `client/ScreenHandlers/ScreenMain.lua:1537-1539`、`client/ScreenHandlers/ScreenMain.lua:1631-1632`、`client/ScreenHandlers/ScreenMain.lua:1668-1669`。
- `QuestCollapsed` 跨 RootNode 重建保留，已有测试作为可观察契约，见 `tests/native/main_hud_wiring_test.lua:184-208`。不能“换根清空所有 self 字段”。
- `SpecialEffect`、`BreathCooldownUntil` 由服务端状态包更新，见 `client/ScreenHandlers/ScreenMain.lua:1471-1479`；不在 Close 清单中。保留是否明确玩法意图未核对。
- Root Cleanup 会清 `Snapshot`、`OpSeq` 等，见 `client/ScreenHandlers/ScreenMain.lua:1199-1202`、`client/ScreenHandlers/ScreenMain.lua:1245-1247`；现状不能证明产品意图。

## 4. 清理路径、调用顺序与缺口

### 4.1 正常 Close

MgrGameUI:CloseScreen → ScreenMain:CloseScreen，只收开屏表现和临时状态，不断根连接、不 Clear 主 HUD 的 OwnedUnits，见 `client/MgrGameUI.lua:91-111`、`client/ScreenHandlers/ScreenMain.lua:1655-1673`。

### 4.2 换根 Cleanup

GetScreen 赋新 RootNode → Init 检测身份不同 → Cleanup → 新根初始化，见 `client/MgrGameUI.lua:43-58`、`client/ScreenHandlers/ScreenMain.lua:1260-1271`。

Cleanup 顺序：清两个浮动模块 → CloseScreen → Destroy 攻击键 → Disconnect 全部连接 → Clear AIM_OWNER/self → 清字段 → Inited=false，见 `client/ScreenHandlers/ScreenMain.lua:1178-1249`。DamageFloat/FishCombatLabel 会在 Cleanup 开头和 CloseScreen 内各 Clear 一次，见 `client/ScreenHandlers/ScreenMain.lua:1178-1182`、`client/ScreenHandlers/ScreenMain.lua:1658-1659`；这是局部重复，不足以证明需全量响应式化。

### 4.3 显式 Destroy

Destroy 复用 Cleanup 并额外清 RootNode，见 `client/ScreenHandlers/ScreenMain.lua:1675-1678`。重复 Destroy 的幂等契约未核对，不能假设安全。

### 4.4 缺口与重入风险

1. **候选内没有 RootNode.Destroying 收尾。** ScreenMain 登记 UI、RemoteEvent、属性和 Heartbeat，没有 RootNode.Destroying，见 `client/ScreenHandlers/ScreenMain.lua:1174-1176`、`client/ScreenHandlers/ScreenMain.lua:1260-1624`。若旧根销毁后不再 GetScreen/Init/Destroy，本候选无另一清理入口；宿主真实路径未核对。
2. **Init 中途抛错会留下部分资源。** 建点和连接从 `client/ScreenHandlers/ScreenMain.lua:1285-1313` 起产生，`Inited=true` 到 `client/ScreenHandlers/ScreenMain.lua:1621` 才设置。若中途抛错，下次 Init 因 Inited=false 不走 `client/ScreenHandlers/ScreenMain.lua:1261-1264` 的 Cleanup，并在 `client/ScreenHandlers/ScreenMain.lua:1287` 重建 Connections，旧句柄失去登记。未做真实故障注入。
3. **Cleanup 没有失败隔离。** CloseScreen、Destroy、Disconnect、OwnedUnits.Clear 在同一顺序体中，无 pcall，见 `client/ScreenHandlers/ScreenMain.lua:1178-1189`。前面抛错会阻止该调用执行后续步骤。
4. **Close 的 IsOpen 翻转偏晚。** HideDialogue、token 失效和 Clear 在 IsOpen=false 前，见 `client/ScreenHandlers/ScreenMain.lua:1655-1660`。若同步重入，重入方仍看到 true；是否真实发生未核对。
5. **MgrGameUI 动画回调读 handler 当前 RootNode。** Open 回调 `client/MgrGameUI.lua:73-77`，Close 回调 `client/MgrGameUI.lua:99-103`，均未捕获根身份或代次。若旧根回调晚于换根，会写新根；真实 Tween 时序未核对。
6. **两个 Delay 的 guard 不可丢。** 属性监听用 Inited + BoundRootNode==root，见 `client/ScreenHandlers/ScreenMain.lua:1611-1616`；战斗补取用 IsOpen + CombatRequest token，见 `client/ScreenHandlers/ScreenMain.lua:1641-1649`。

## 5. spoke 语义匹配度

### 匹配部分

- `SpokeTree.spawn` 建 Auto 树，bootstrap 在返回路径同步 flush，见 `common/packages/spoke/runtime/spoke_tree.lua:20-40`、`common/packages/spoke/runtime/spoke_tree.lua:100-103`。局部 adapter 不需要 Manual 帧泵。
- Epoch attachments 逆序释放；单项 release 抛错会报告并继续其余项，见 `common/packages/spoke/runtime/epoch_teardown.lua:1-3`、`common/packages/spoke/runtime/epoch_teardown.lua:49-61`。相比长 Cleanup，这里可提供真实 leverage 和 locality。
- `on_cleanup` 把清理登记为当前 Epoch attachment，见 `common/packages/spoke/runtime/epoch_builder.lua:83-89`；但它本身不决定根或开屏寿命。
- `Phase` 仅条件 true 时挂载 block，false 清上一轮并移除动态依赖，见 `common/packages/spoke/reactive/phase.lua:9-13`、`common/packages/spoke/reactive/phase.lua:29-38`。只适用于真正属于 Open/Close 的资源。

### 不匹配或不足以覆盖

- `spoke_eggy.behaviour` 只连接 Unit.Destroying，见 `common/packages/spoke_eggy/api.lua:137-146`、`common/packages/spoke_eggy/api.lua:189-197`。开关只改 Visible，所以 is_alive 不是 IsOpen。
- spoke_eggy 不覆盖关局，见 `common/packages/spoke_eggy/api.lua:16-19`、`docs/adr/0024-introduce-spoke-eggy-host-package.md:23-24`。
- RootNode **身份替换**不等于旧 Unit 已触发 Destroying。当前 MgrGameUI 用引用不等重建，见 `client/MgrGameUI.lua:45-58`；这个 seam 不能删。
- spoke_eggy 销毁时先 is_alive=false 并 Auto flush，再 dispose 树、断 Destroying，见 `common/packages/spoke_eggy/api.lua:217-227`、`common/packages/spoke_eggy/api.lua:233-250`。用于根寿命前需验证最后一次 Effect 不写旧根或重建开屏资源。
- 当前 Cleanup 是显式业务顺序，spoke attachments 是逆序，见 `client/ScreenHandlers/ScreenMain.lua:1178-1189` 与 `common/packages/spoke/runtime/epoch_teardown.lua:49-61`。不能无意改变 Close、Destroy、Disconnect、OwnedUnits.Clear 的先后。

## 6. deletion test：何时真正加深 module

### 不通过：shallow wrapper

若只把 Listen 的连接数组换成 on_cleanup(Disconnect)，再搬走 Cleanup 的字段 nil 清单，删除 spoke 后没有行为契约消失；现有 Listen/Cleanup 已能做到，见 `client/ScreenHandlers/ScreenMain.lua:1174-1189`。这是浅包装。

### 通过：在现有 seam 后形成 deep module

局部 implementation 必须真正隐藏并保证：同根复用不重复建点/连接；换根完整收尾；重复 Open/Close 不叠加资源且旧 Delay 失效；根监听不被 Phase 卸掉；初始化或清理单项失败不留半轮资源；CreateUnit/OwnedUnits、收线和任务折叠行为不变。

caller 仍走 MgrGameUI 现有 GetScreen/OpenScreen/CloseScreen seam，interface 不扩大，才同时提高 locality、测试能力与 leverage。若为这些规则另建通用响应式 UI 框架，超出候选且扩散 shallow interface，应拒绝。

## 7. locality、leverage 与测试 seam

- 根资源建立在 Init，清理集中在长 Cleanup，字段归属需交叉阅读，见 `client/ScreenHandlers/ScreenMain.lua:1178-1248`、`client/ScreenHandlers/ScreenMain.lua:1260-1624`。setup/cleanup 同址是主要 locality 收益。
- 假 Signal 已支持 Connect/Disconnect/Fire，见 `tests/native/main_hud_wiring_test.lua:19-31`；测试直接 loadfile handler 并 Init，见 `tests/native/main_hud_wiring_test.lua:84-86`。可观察重复连接、旧事件和换根，无需生产专用测试分支。
- OwnedUnits 测试已验证 Cleanup 后计数归零、节点均销毁，见 `tests/native/main_hud_owned_units_test.lua:102-117`；瞄准层只销毁一次见 `tests/native/main_hud_owned_units_test.lua:120-141`。应复用这些结果，不断言内部树形状。
- 任务折叠跨换根已有测试，见 `tests/native/main_hud_wiring_test.lua:202-208`，可阻止清空所有 self 字段。
- 这些测试直接驱动 handler，不等于覆盖 MgrGameUI 重复 Open/Close、动画回调或真实 Unit.Destroying；后者未核对。

## 8. 最小可证伪验证（仅方案，未运行）

1. **同根复用**：RootNode A 初始化后再获取同根；建点、连接不增长，请求次数保持定义好的现状。
2. **Close 不拆根**：A 打开后 Close；OwnedUnits 不归零、根监听仍连接、攻击键关闭、CombatRequest 失效。ItemBarState 与 CastState 保持当前差异：根监听仍收，非 result Cast 关屏不更新，依据 `client/ScreenHandlers/ScreenMain.lua:1469`、`client/ScreenHandlers/ScreenMain.lua:1536-1539`。
3. **重复 Open/Close**：不叠加连接/节点；0.6 秒补取只有最新有效代次能发。
4. **换根 A→B**：A 连接各断一次、OwnedUnits 清空、攻击键根资源 Destroy 一次；A 的 1 秒属性 Delay 不得给 B 加旧任务监听；B 再正常 Open。
5. **跨根保留**：QuestCollapsed 保留；收线 Close 只 Suspend。
6. **故障注入**：Init 建点/连接中点失败后重进，不得出现匿名旧连接或重复建点；某 cleanup 失败后其他资源仍按选定顺序收尾。若采用 spoke 却不能提供这些可观察保证，其 depth 主张被证伪。
7. **显式销毁（条件项）**：取得 RootNode.Destroying 宿主证据后才验收 spoke_eggy；验证销毁顺序、重复 dispose 和最后一次 Auto flush 不写新根。假 Destroying 成功不等于真宿主结论。

## 9. ADR 与玩法约束

- ADR-0022：spoke 整包只读拷贝，不就地修改，见 `docs/adr/0022-introduce-spoke-runtime.md:9-14`。
- ADR-0024：spoke_eggy 与 spoke 平级、依赖单向、不就地修改，见 `docs/adr/0024-introduce-spoke-eggy-host-package.md:9-13`。
- ADR-0026：CreateUnit 保持现址，不建全局 factory 或统一挂载容器，使用 OwnedUnits，见 `docs/adr/0026-no-global-unit-factory.md:12-21`。spoke 树不得成为第二套单位所有权系统。
- handler 仍由 ScreenHandlerLoaders 登记、MgrGameUI 按节点名加载，见 `client/MgrGameUI.lua:9-25`、`client/MgrGameUI.lua:27-60`；无需新全局 container。
- MgrGameUI、ScreenHandlers 属 L2，包属 L6，见 `docs/architecture.md:9-16`。只消费现有包，无需调整层级或 `server/main.lua` 的 MgrMap 分发 seam。
- 客户端先监听再请求，见 `CODING_STANDARDS.md:41-43`；当前 SpecialItem 首包请求在监听后，见 `client/ScreenHandlers/ScreenMain.lua:1469-1483`，不能倒置。
- 可重入连接句柄、失败清理和延迟回调代次是项目规则，见 `CODING_STANDARDS.md:50-56`。
- 收线跨关屏继续、任务折叠跨换根保留，是已有玩法/测试约束。

## 10. 仍开放与未核对问题

1. 宿主实际如何销毁/替换 RootNode；旧根是否必发 Destroying，换根与销毁谁先，未做真机探针。
2. 旧根销毁后若不再 Open，是否要求立即 Disconnect/Clear，触发路径与玩法寿命待决策。
3. SpecialEffect、BreathCooldownUntil、OpSeq、Snapshot 等跨根保留/清空是否刻意，未核对策划意图。
4. 重复 Open 的请求和重复 Close 的完整收尾应兼容现状还是去重，未核对；最小分解先保持现状。
5. TweenOpacity 在 Close→Open 或换根后的真实时序未核对。
6. spoke 初始化故障时各阶段 attachment 的回收范围、raw SpokeTree 在本用法下重复 dispose 行为，未跑探针，不作为已证实收益。
7. 不支持“关局时 spoke_eggy 自动清理”的假设；包与 ADR 明确不支持。

## 11. 推荐强度调整

- **两种寿命局部分解：强推荐。** Close 与 Cleanup 已承担不同职责，且有部分初始化、清理失败隔离和两种 Delay 代次的具体验证需求。
- **spoke 引入：若原建议是推荐/强推荐 spoke 化 ScreenMain，下调为有条件弱推荐，只做最小试点。** 先证明逆序清理、失败隔离和 Open 子结构挂载的真实 depth，否则删除 spoke，避免 shallow wrapper。
- **spoke_eggy：暂不据此候选强推荐。** 只适合已取证的 Unit 显式销毁，不能替代换根检测，也不能表达 Open/Close。
- **全量 ScreenMain 响应式重写：不推荐。** 证据只支持寿命与资源所有权的局部问题。
