# ScreenParty 生命周期与 spoke 适配研究

- 日期：2026-11-22
- 范围：`client/ScreenHandlers/ScreenParty.lua` 的 `Start/Clear` 重入，`PartyState`、`PartyResult`、`Heartbeat` 连接清理，以及 `MgrGameUI`、固定队友行、现有 native spec 与 spoke 的匹配度。
- 证据口径：结论来自当前仓库业务源码、测试、ADR、`common/packages/spoke*` 实际实现与随包契约。未运行测试、未试玩、未修改业务代码；宿主真实销毁行为不以替身行为代替。

## 1. 结论摘要与推荐强度

**推荐强度需要拆分并调整，而不是把“Party HUD 引入 spoke + Dock”整体列为强推荐：**

1. **重入清理缺陷：高推荐先处理。** `Start` 明确试图支持重入并调用 `Clear`，但 `Clear` 只清单位节点；三条宿主连接随后持续追加，没有对应 `Disconnect`（`client/ScreenHandlers/ScreenParty.lua:44-48`、`client/ScreenHandlers/ScreenParty.lua:209-210`、`client/ScreenHandlers/ScreenParty.lua:249-256`）。这是 implementation 中可静态证明的重入所有权缺口。
2. **当前玩法可达性：未被证实。** 仓内生产启动点是 `client/main.lua` 的一次 `Task:Spawn`（`client/main.lua:25`、`client/main.lua:63`）。`MgrGameUI.OpenScreen/CloseScreen` 不调用 `ScreenParty.Start/Clear`（`client/MgrGameUI.lua:63-112`），所以不能把“开关 ScreenParty”写成当前已证实的重复订阅触发器。
3. **spoke：条件性中低推荐，不宜只为三条连接引入。** spoke 的 tree/attachment 语义确实能承载连接所有权与统一 teardown；但若只把三次 `Connect` 搬入树，收益接近换一个连接容器，depth 不足。只有同时收敛快照到渲染的响应式 implementation、并保持既有公共 seam 时，才值得重新评估。
4. **Dock：不推荐。** 当前是两条固定位置行，不是按队友身份动态增删的子树；Dock 会增加 key、replace/drop 与 slot 生命周期知识，却不消除现有复杂性（`common/GameCfg.lua:174-181`、`client/ScreenHandlers/ScreenParty.lua:214-228`）。
5. **spoke_eggy：不匹配当前所有权。** HUD 由 `Panel` 统一拥有多个运行时节点，而非一个 Unit 拥有整棵行为；并且关局不会自动触发 `Destroying`（`client/ScreenHandlers/ScreenParty.lua:18-29`、`docs/adr/0024-introduce-spoke-eggy-host-package.md:21-24`）。若采用 spoke，应评估消费方显式持有的树与明确退出点，而不是借 `spoke_eggy` 推断自动清理。

## 2. 范围与非目标

### 范围内

- 现有寿命、节点和事件连接所有权时间线。
- 所有源码中可见的清理路径、重入与失败路径缺口。
- `MgrGameUI.GetScreen/OpenScreen/CloseScreen` 的实际调用关系。
- spoke 的 `on_cleanup`、`detach/dispose`、Dock 与 `spoke_eggy` 是否匹配。
- 既有 `Start/NoteState/Tick/View` 公共 seam 上的最小可证伪验证。

### 非目标

- 不设计新 interface、函数签名、补丁或通用 UI 生命周期框架。
- 不修改 `spoke/spoke_eggy`，不引入全局 unit factory/container，不改变 `CreateUnit/OwnedUnits`。
- 不把客户端 HUD 生命周期挪进 `server/main.lua`，不改变 `MgrMap` 分发 seam。
- 不以 native fake 的结果声称宿主 `Disconnect`、节点 `Destroy` 或关局行为已获真机证明。

## 3. 现有寿命与所有权时间线

| 时点 | 实际行为 | 所有权/后果 |
|---|---|---|
| 模块加载 | 单例 `Panel` 初始化 `Teammates`、`PartyState`、`Rows`、`Connections`（`client/ScreenHandlers/ScreenParty.lua:10`）。 | `Panel` 同时是状态、节点和连接的表面所有者。 |
| 客户端入口 | `client/main.lua` require 后在独立协程调用一次 `Start`（`client/main.lua:25`、`client/main.lua:63`）。 | 当前可见生产路径不是每次开窗启动。 |
| `Start` 取 EUI | 先取根节点与分辨率；失败或无根节点直接返回（`client/ScreenHandlers/ScreenParty.lua:200-208`）。 | 此返回早于 `Clear`，重入时旧节点和旧连接都不会清。 |
| `Start` 重建前 | 调用 `Clear`；`Clear` 执行 `OwnedUnits.Clear(self)` 并复位 `Root/InvitePanel/Rows`（`client/ScreenHandlers/ScreenParty.lua:44-48`、`client/ScreenHandlers/ScreenParty.lua:209-210`）。 | 只覆盖单位节点，不覆盖事件连接和全部业务状态。 |
| 建固定 HUD | `create` 保持现址 `World:CreateUnit`，再 `OwnedUnits.Track(Panel,node)`（`client/ScreenHandlers/ScreenParty.lua:18-29`）。 | 符合 ADR-0026 的归属登记，不需要全局 factory/container。 |
| 建队友行 | 按 `MaxRows` 循环建行；`MaxMembers=3`、`MaxRows=2`（`client/ScreenHandlers/ScreenParty.lua:214-228`、`common/GameCfg.lua:164-180`）。 | 行身份是固定槽位 `1..MaxRows`，不是动态 teammate epoch。 |
| 建邀请按钮 | 两个按钮各自 `OnClicked:Connect`，句柄未入 `Connections`（`client/ScreenHandlers/ScreenParty.lua:236-247`）。 | 节点由 `OwnedUnits` 销毁；节点销毁是否级联断开按钮信号，本次未核对宿主。 |
| 建三条长寿命连接 | `PartyState`、`PartyResult`、`Heartbeat` 的句柄追加到既有 `Connections`（`client/ScreenHandlers/ScreenParty.lua:249-256`）。 | `self.Connections = self.Connections or {}` 不会清掉旧数组；没有断开循环。 |
| 快照与心跳 | `PartyState` 调 `NoteState`，后者校验、更新并 `Render`；`Heartbeat` 调 `Tick` 更新邀请倒计时（`client/ScreenHandlers/ScreenParty.lua:84-113`、`client/ScreenHandlers/ScreenParty.lua:155-163`）。 | 重入后同一事件可能进入多份等价回调；部分输出幂等不等于订阅未泄漏。 |
| 状态请求 | 每次成功建面板后请求一次 `PartyStateRequest`（`client/ScreenHandlers/ScreenParty.lua:257-259`）。 | 注释提到“界面重开”，但现有 `MgrGameUI.OpenScreen` 并不会触发这段 `Start`。 |

## 4. 清理路径与缺口

### 4.1 已存在的清理路径

- **显式节点清理**：`OwnedUnits.Clear` 先摘登记，再逐个 `Destroy`；单个失败会记录且继续，重复调用为空操作（`common/OwnedUnits.lua:33-47`）。
- **Start 重入时节点重建**：`Start` 在 EUI 可用时先 `Clear`（`client/ScreenHandlers/ScreenParty.lua:201-210`）。
- **测试里的节点 Destroy 只是 fake**：测试节点把 `Destroyed=true`（`tests/native/spec/09_party_hud_test.lua:39-45`），只能证明业务调用了替身，不证明宿主级联行为。

### 4.2 缺口及分类

| 路径 | 缺口 | 分类 |
|---|---|---|
| `Start → Start` | 旧的三条连接没有 `Disconnect`，新连接继续追加（`client/ScreenHandlers/ScreenParty.lua:249-256`）。 | **真实 implementation 缺陷**；但当前生产触达重入的路径未证实。 |
| 直接 `Clear` | 清节点后，`PartyState/PartyResult/Heartbeat` 仍可回调同一 `Panel`（`client/ScreenHandlers/ScreenParty.lua:44-48`、`client/ScreenHandlers/ScreenParty.lua:251-256`）。 | **所有权缺口**；`Clear` 是否应成为完整退出点仍待决策。 |
| EUI 不可用时重入 | `Start` 在 `Clear` 前返回（`client/ScreenHandlers/ScreenParty.lua:201-210`）。 | **失败路径缺口**；会保留上一轮资源，不能以“重建前先 Clear”覆盖此分支。 |
| 建节点中途抛错 | `create` 会对 nil 节点报错，而 `Start` 建段没有整体失败回滚（`client/ScreenHandlers/ScreenParty.lua:24-28`、`client/ScreenHandlers/ScreenParty.lua:214-249`）。 | **失败路径缺口**；部分新节点留待下一次成功走到 `Clear`，旧连接仍在。 |
| `MgrGameUI.CloseScreen` | 仅在 handler 有 `CloseScreen` 时回调（`client/MgrGameUI.lua:91-111`）；`ScreenParty` 当前只定义 `Clear/Start`，没有该回调。 | **不是当前开关重入缺陷证据**；是否要求关屏销毁 HUD 属待决策。 |
| 测试 `after_each` | 只恢复全局与 `REUtil`，不调用 `Clear`，也不断开连接（`tests/native/spec/09_party_hud_test.lua:66-74`）。 | **测试验证缺口**，不是生产清理路径。 |
| 关局/换场景 | 没有本模块退出接线；`spoke_eggy.is_alive` 明确不覆盖关局（`docs/adr/0024-introduce-spoke-eggy-host-package.md:21-24`）。 | **未核对/待决策**，不能宣称宿主会自动清。 |

## 5. MgrGameUI 调用链：它证明什么、不证明什么

1. `GetScreen` 找设计器中的 `screenNode`，加载 handler，写入 `ScreenName/RootNode`；仅在满足 `UINodes/UINodeMap` 等条件时调用 `Init`（`client/MgrGameUI.lua:27-60`）。
2. `OpenScreen` 操作的是这个 `RootNode`，随后只在 handler 有 `OpenScreen` 时回调（`client/MgrGameUI.lua:63-89`）。
3. `CloseScreen` 同样操作 `RootNode`，随后条件调用 `CloseScreen`（`client/MgrGameUI.lua:91-112`）。
4. 两条 RemoteEvent 只是转入上述方法（`client/MgrGameUI.lua:114-120`）。
5. `ScreenParty` 自绘节点保存到自有 `Root`，并非上述 `RootNode`（`client/ScreenHandlers/ScreenParty.lua:214-215`）；它没有 `OpenScreen/CloseScreen`，当前只有 `Clear/Start` 两个相关生命周期入口（`client/ScreenHandlers/ScreenParty.lua:45`、`client/ScreenHandlers/ScreenParty.lua:180`）。

因此，**不能从 MgrGameUI 推出“每次 OpenScreen 都 Start”或“CloseScreen 已清理 Party 连接”**。它反而说明这两件事当前都不存在。是否应把自绘 HUD 纳入开关生命周期，是另一项产品/架构决策，不应为了吻合候选而改写成事实。

## 6. spoke 语义匹配与依据

### 6.1 匹配的部分：统一 attachment teardown

- `EpochBuilder:on_cleanup` 把清理函数登记为 attachment（`common/packages/spoke/runtime/epoch_builder.lua:83-89`）。
- `SpokeTree:dispose()` 委托 `detach`；`detach` 对已拆除对象直接返回，活动 frame 中则延迟请求（`common/packages/spoke/runtime/spoke_tree.lua:177-179`、`common/packages/spoke/runtime/epoch.lua:115-138`）。
- teardown 从数组尾部逆序释放，单项失败会报告并继续剩余项（`common/packages/spoke/runtime/epoch_teardown.lua:49-61`）。
- 本仓 `LocalReelIn` 已有相同宿主连接模式：显式 `Disconnect` 放进 `on_cleanup`，`Stop` 拆树，重复 `Start` 由既有树守卫（`client/LocalReelIn.lua:94-110`、`client/LocalReelIn.lua:119-143`）。这是可复用范式证据，不是另造框架的理由。

**判定**：spoke 能解决“连接与树同寿命”的 ownership 问题，但仍要求消费方在重入/退出点明确 dispose 或保留树；它不会自动决定 `Start/Clear/CloseScreen` 的业务语义。随包契约也明确要求无 Unit 寿命时由消费方显式 `dispose`，关局不能挂在 `is_alive` 上（`.dsh/skills/spoke/SKILL.md:71-87`）。

### 6.2 Auto/Manual 与渲染

随包契约默认 EUI 面板使用 Auto；Manual 只针对同帧多次写合并、大计算分帧、单步调试（`.dsh/skills/spoke/SKILL.md:53-59`）。当前 Party 快照一次校验后同步渲染，心跳只做倒计时（`client/ScreenHandlers/ScreenParty.lua:84-113`、`client/ScreenHandlers/ScreenParty.lua:155-163`），没有证据要求 Manual。

若未来把一次快照拆成多个 State，需核对多状态写入的 batch，避免 Effect 观察中间组合；契约明确普通 subscriber 通知并不被 batch 合并（`.dsh/skills/spoke/references/reactive.md:22-24`）。这属于采用响应式 implementation 后的成本，不是当前缺陷已经获得的收益。

### 6.3 Dock：固定行无需动态 keyed 子树

`Render` 遍历已有 `Rows`，只改 `Visible`、名称、血量文本和条宽（`client/ScreenHandlers/ScreenParty.lua:135-153`）。队友集合变化不会创建或销毁行；固定两行由 `Start` 一次建好（`client/ScreenHandlers/ScreenParty.lua:214-228`）。Dock 的实际价值是 key 替换时 drop/detach 旧 child，再安装新 child（`common/packages/spoke/runtime/dock.lua:50-79`、`common/packages/spoke/runtime/dock.lua:99-123`），当前没有对应需求。

**deletion test**：删去假设中的 Dock，不会把 key 管理、身份协调或逐行 teardown 复杂性重新散到多个 caller；这些复杂性本来就没有。因此 Dock 在这里会是 shallow wrapper，不推荐。

### 6.4 spoke_eggy：没有一个 Unit 能代表整份 HUD 寿命

`spoke_eggy.behaviour` 为一个 Unit 建一棵树并连接该 Unit 的 `Destroying`（`common/packages/spoke_eggy/api.lua:175-197`），dispose 只负责该树和该连接（`common/packages/spoke_eggy/api.lua:233-250`）。当前 `PartyRoot` 与 `PartyInvite` 都是同一 `Panel` 下登记的兄弟节点（`client/ScreenHandlers/ScreenParty.lua:214-249`）。把树绑到其中一个节点，不能自动证明另一个节点、远程事件和关局都获得正确寿命。

## 7. depth、locality、leverage 与测试收益

### 7.1 最小深化：现有 Panel 内部统一资源寿命，而非新增浅包装

优先候选是让现有 `Start/Clear` 的所有权语义完整覆盖节点与三条连接，并覆盖 EUI 早退和半初始化失败。公共 seam 仍是现有 `Start/NoteState/Tick/View`，不要求测试学习另一套框架。

**deletion test**：若删除这份所有权 implementation，调用方就必须重新知道三个连接、节点登记、重入顺序和失败回滚；复杂性会重新出现在 `Start` 的调用与测试里。因此这是有实际 depth 的深化。相反，只新增一个“保存连接并遍历 Disconnect”的通用 module，在当前只有一个使用点时，interface 与 implementation 几乎同大，容易成为 shallow wrapper。

### 7.2 spoke 的 leverage 有条件成立

- **locality**：最小修复可把节点、连接和失败清理留在 `ScreenParty.lua`，无需把职责泄到 `MgrGameUI` 或服务端。
- **spoke leverage**：若采用树同时拥有远程连接、心跳和响应式渲染， teardown 顺序与单项失败继续清理由库统一承担，测试仍从现有 seam 观察行为。
- **不成立的 leverage**：只把三条连接搬进树，却仍由 `Panel` 手工管理全部状态与固定节点，新增概念多、消除的决策少。此时删除 spoke 只会把几次显式断开移回原模块，并未证明足够 depth。

### 7.3 当前测试 seam 的价值与盲区

测试声明只走 `Start/NoteState/Tick/View` 及接线（`tests/native/spec/09_party_hud_test.lua:1-10`），这是正确的公共 seam：无需为 spoke 增加测试专用 production 分支。

但 fake `signal` 的 `Connect` 只追加 listener，返回的 `Disconnect` 是 no-op（`tests/native/spec/09_party_hud_test.lua:11-19`）。`before_each` 已 Start 一次（`tests/native/spec/09_party_hud_test.lua:62-64`），资产用例又 Start 一次，却只检查新图片，不再发事件（`tests/native/spec/09_party_hud_test.lua:191-202`）。所以它既未暴露重复回调，也无法验证未来“调用 Disconnect”是否真的移除 listener。

**严格区分**：no-op 是测试 adapter 缺陷；重复追加且从不调用 Disconnect 才是生产 implementation 缺陷。只修 fake 不会修生产；只修生产而不修 fake，则断开行为仍无法被该套件可信验证。

## 8. 最小可证伪验证路径（本次未运行）

### P0：先用现有公共 seam 证明真实重入缺陷

1. 在同一 panel 上执行 `Start → Start`，再从 `PartyResult` fake 发一次失败回执；预期玩家只得到一条通知。按当前 `Connect` 追加语义，预测实际为两条：一次旧回调、一次新回调（`tests/native/spec/09_party_hud_test.lua:11-19`、`client/ScreenHandlers/ScreenParty.lua:250-256`）。断言玩家可见通知数量，不断言 `Connections` 数组长度。
2. 对 `PartyState` 使用带一次性 `notice` 的合法快照重复上述实验，预期一条通知；这能把“重复渲染恰好幂等”与“重复订阅”分开。通知入口和快照入口分别见 `client/ScreenHandlers/ScreenParty.lua:106-112`、`client/ScreenHandlers/ScreenParty.lua:251-254`。
3. 心跳的重复 `Tick` 多数输出幂等，单靠倒计时文本不能证伪。让 fake signal 的 `Disconnect` 真正实现幂等移除，并在 adapter 侧观察 active listener 数；重入后 `PartyState/PartyResult/Heartbeat` 应各只有一个 active listener。不要为此新增 production 测试接口。

**判定方式**：若 P0 在当前实现出现重复通知，则确认的是业务 implementation 的重入缺陷，不是 fake 自己制造的通知；fake 只是忠实保留所有 `Connect`。若把 fake 改成真实 Disconnect 而业务仍不调用它，P0 仍应失败。

### P1：验证清理与失败路径

- 若决策 `Clear` 是完整 teardown：`Start → Clear` 后三个 active listener 应为零，旧事件不再改 `View` 或发通知；同时已有节点仍由 `OwnedUnits.Clear` 销毁。若 `Clear` 继续只表示节点清理，则必须另指认完整退出点，此项不能强行写成现有合同。
- 模拟第二次 `Start` 时 EUI 根不可用，验证不会保留旧连接/旧节点；当前早退顺序预测此用例会暴露缺口（`client/ScreenHandlers/ScreenParty.lua:201-210`）。
- 让第 N 次 `CreateUnit` fake 抛错，验证半初始化资源按既定所有权回收，下一次 `Start` 不叠连接。该用例对应现有未覆盖失败方式，不是复述实现。

### 真机边界

native 验证只能证明业务对事件 adapter 的调用与可观察输出。宿主 `Disconnect` 的真实退订、按钮节点 `Destroy` 是否级联断开、关局/换场景清理均未核对。现有条款 9-23 的实机可读性仍为 blocked，不能借本次研究宣称试玩通过（`docs/acceptance/09-multiplayer-rules.md:44-48`）。

## 9. ADR 与玩法约束

- **ADR-0022/0024**：`spoke` 与 `spoke_eggy` 都是纯拷贝，不就地修改；需要库行为应回上游（`docs/adr/0022-introduce-spoke-runtime.md:9-14`、`docs/adr/0024-introduce-spoke-eggy-host-package.md:9-13`）。
- **ADR-0026**：保留 `CreateUnit` 现址调用与 `OwnedUnits.Track/Clear`；不建全局 unit factory 或统一挂载容器（`docs/adr/0026-no-global-unit-factory.md:12-21`）。spoke 树若采用，应与这份节点 ownership 协作，而不是取代它。
- **MgrMap seam**：服务端依赖仍由 `server/main.lua` 注入，例如 `MgrParty.PlayerData/Save/Vitals`（`server/main.lua:205-207`），`Start` 由入口遍历 `MgrMap` 分发（`server/main.lua:310-312`）。本候选只涉及 client HUD，不应绕过或复制这条 seam。
- **编码规范**：可重入口里的连接必须存句柄并在关闭或重建时断开；中途失败要反向清理，再次启动不得残留上一轮连接（`CODING_STANDARDS.md:46-56`）。当前 `ScreenParty.Start` 与此项目规则存在直接差距。
- **玩法**：9-20 要求 HUD 显示同队队友当前血量，9-21 要求邀请和 10 秒倒计时（`docs/acceptance/09-multiplayer-rules.md:35-42`）。服务端仍是权威，客户端只渲染快照和发意图（`client/ScreenHandlers/ScreenParty.lua:1-4`）；生命周期调整不得变成本地组队判定。
- **术语与布局**：领域术语用 **Squad / 小队**，但代码标识符 `Party*` 原样保留（`GLOSSARY.md:33-34`）。`MaxRows=2` 的布局仍标 `[未查证]`，本研究不替策划确认（`common/GameCfg.lua:172-180`）。

## 10. 仍开放问题与未核对项

1. **Start 的正式合同**：它是允许任意重入，还是仅入口一次？源码注释明确考虑“Start 重入”（`client/ScreenHandlers/ScreenParty.lua:209-210`），但当前生产只见一次启动；需要保留并验证重入，还是另加一次性合同，待决策。
2. **Clear 的合同**：只清节点，还是完整停止响应？当前注释只承诺节点与引用复位（`client/ScreenHandlers/ScreenParty.lua:44-48`），不能擅自把它当 Close/Dispose。
3. **HUD 与 MgrGameUI 的关系**：注册在 loader 是否意味着未来会有开关入口？仓内没有 `ScreenParty` 的开关调用证据；是否让关屏销毁或仅隐藏，待玩法/界面决策。
4. **宿主行为**：真实 `Disconnect` 退订顺序、`Destroy` 对按钮信号与后代的级联、EUI 根暂时不可用后的重试、关局/换场景触发点均未核对。
5. **spoke 采用的 depth 门槛**：若只是连接容器则不推荐；是否以同一公共 seam 收敛快照渲染，需要单独证明 leverage，不能预先当成收益。
6. **验证状态**：本研究未运行任何测试或试玩；上述 P0/P1 是最小验证设计，不是已取得的运行结果。

## 11. 最终建议

先以**高推荐强度**处理现有 `Start/Clear` 的节点与连接共同所有权及失败路径，并用 P0 把真实 implementation 缺陷与 fake Disconnect 缺陷同时钉住。**下调“为此引入 spoke”的推荐强度至条件性中低**，只有能证明响应式 implementation 带来实际 depth 才采用；**不推荐 Dock 或 spoke_eggy**，也不新增通用框架。无论是否采用 spoke，都保持 `Start/NoteState/Tick/View` 公共 seam、`CreateUnit/OwnedUnits`、`MgrGameUI` 的实际职责与 `server/main.lua` 的 `MgrMap` 分发不变。
