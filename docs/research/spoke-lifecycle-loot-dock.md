# LocalLoot 生命周期与 spoke Dock 适配研究

- **日期**：2026-11-22（Asia/Shanghai）
- **证据口径**：当前仓库业务源码、测试、ADR 与 `common/packages/spoke*` 实际实现；技能文档只作导航。
- **本次动作**：只读研究；未运行测试、未启动试玩，未修改业务代码、测试、ADR、`GLOSSARY.md`、上游包或 HTML。

## 1. 结论与推荐强度

**若原建议是“用 Dock 直接替换 `Nodes[id] + alive`，从而删掉 `Show` 的手工差集”，推荐强度应下调为「中等、附条件」。三个宿主连接与整体收尾所有权则是「高优先级、独立于 Dock」的问题。**

1. Dock 提供 keyed child 的 attach、replace、drop 和整体 detach，与 `Nodes[id]` 的**节点资源寿命**部分匹配；但它不消费 `LootState` 快照，也不自动计算新增、保留、消失集合。`alive` 是业务 reconciliation，不是重复库功能。依据：`common/packages/spoke/runtime/dock.lua:50-79`、`common/packages/spoke/runtime/dock.lua:99-123`，对照 `client/LocalLoot.lua:45-55`。
2. 当前同 id 再出现会保留原节点，只更新 `Warning`；`Dock:call` 对同 key 会先 drop 旧 child 再 attach 新 child。逐快照无条件 call 会改变节点身份。依据：`client/LocalLoot.lua:47-51`、`common/packages/spoke/runtime/dock.lua:50-59`。
3. 三个宿主连接没有保存者，module 没有 `Stop`，重复 `Start` 会叠加连接。这是当前最明确、可证伪的 lifecycle 缺口；Dock 本身不会退订 RemoteEvent 或 Heartbeat。依据：`client/LocalLoot.lua:85-96`。
4. `LocalLoot` 已是单一的 96 行 L2 module，节点创建、显隐与清理 locality 本来就集中。只有同时吸收手工节点所有权和分散 cleanup，Dock/SpokeTree 才形成 depth；保留 `Nodes`、`Clear` 和手工销毁再包一层，就是 shallow wrapper。

**建议顺序**：先以可观察行为明确 Start/Stop/重入和节点身份契约，再判断 keyed child 是否足以吸收节点创建、状态与销毁。不先引入通用生命周期框架，不为了 Dock 改上游包。

## 2. 范围与非目标

### 范围

- `LocalLoot.Nodes` 的身份索引、快照差集、节点销毁与预警状态。
- `LootState.OnClientEvent`、`LootResult.OnClientEvent`、`RunService.Heartbeat` 三条连接的拥有者。
- `Start` 内顺序、重复 `Start`、缺失的 `Stop`、启动中途失败后的清理。
- `tests/native/loot_client_test.lua` 对 `Nodes` 和直接 `Update` 调用的耦合，以及外部行为验证方向。
- `Dock`、`SpokeTree`、attachment cleanup 与 `spoke_eggy` 是否匹配。

### 非目标

- 不设计新 interface、函数签名、类层级或补丁。
- 不修改 `common/packages/spoke/`、`common/packages/spoke_eggy/`；ADR-0022/0024 要求回上游变更后整包同步，见 `docs/adr/0022-introduce-spoke-runtime.md:9-14`、`docs/adr/0024-introduce-spoke-eggy-host-package.md:9-13`。
- 不建立全局 unit factory/container，不迁移 `CreateUnit`，不删除 `OwnedUnits`；见 `docs/adr/0026-no-global-unit-factory.md:12-21`。
- 不改变服务端权威掉落、拾取、预算、回收和预警玩法，不把客户端表现状态变成权威状态。
- 不重复测试 spoke 上游负责的 Dock 内部算法；业务验证只观察 LocalLoot 的外部行为。

## 3. 现有寿命与所有权时间线

| 时点 | 当前行为 | 证据 |
|---|---|---|
| 模块加载 | 单例表带 `Nodes = {}`；加载时取得 `Players` service。 | `client/LocalLoot.lua:5-12` |
| 客户端入口启动 | `client/main.lua` 在一个 `Task:Spawn` 中启动若干模块、打开主界面，再调用 `LocalLoot:Start()`；没有对应 LocalLoot 收尾调用。 | `client/main.lua:43-51` |
| Start 第 1 步 | 连接 `LootState.OnClientEvent`，回调执行 `Show(list)`；返回值未保存。 | `client/LocalLoot.lua:85-86` |
| Start 第 2 步 | 连接 `LootResult.OnClientEvent`，`reason == 'full'` 时显示“背包已满”；返回值未保存。 | `client/LocalLoot.lua:87-91` |
| Start 第 3 步 | 连接 `RunService.Heartbeat`，回调执行 `Update(dt)`；返回值未保存。 | `client/LocalLoot.lua:92` |
| Start 最后 | 三条连接建立后才 `RequestLoot:FireServer()`；服务端只向请求玩家回当前快照。 | `client/LocalLoot.lua:93`、`server/Mgr/MgrLoot.lua:596-600` |
| 快照含新 id | 创建场景根、按钮和文字，根初始隐藏，再把 `{Node, Position, Warning}` 写入 `Nodes[id]`。 | `client/LocalLoot.lua:25-42` |
| 快照保留 id | 不重建节点，只更新 `Warning`；`Position` 保留首次创建时的整份 `loot`。 | `client/LocalLoot.lua:42`、`client/LocalLoot.lua:47-51` |
| 快照缺少旧 id | 从 `Nodes` 摘除该 id，然后对根节点 `Destroy()`。 | `client/LocalLoot.lua:19-23`、`client/LocalLoot.lua:53-55` |
| Heartbeat | 遍历 `Nodes`，按本地角色距离、`Warning` 和 `Blink` 决定根节点显隐。 | `client/LocalLoot.lua:59-82` |
| 点击 | 只发 `ItemBarAction{action='Pickup', value=loot.id}`，结果以服务端为准。 | `client/LocalLoot.lua:34-36`、`server/Mgr/MgrLoot.lua:480-504` |
| 服务端移除后广播 | 拾取成功摘权威记录、销毁服务端单位并广播；回收后也广播新快照，客户端再经差集清理。 | `server/Mgr/MgrLoot.lua:489-504`、`server/Mgr/MgrLoot.lua:208-229`、`server/Mgr/MgrLoot.lua:631-633` |
| Stop / 整体退出 | **当前文件没有 `Stop` 或全量清理入口，文件在 `Start` 后直接 return。** | `client/LocalLoot.lua:85-96` |

`MgrLoot.Snapshot()` 每次从权威 `Loots` 重建列表并附带 `warn`，不是客户端本地增量真源，见 `server/Mgr/MgrLoot.lua:42-52`。客户端应按完整快照 reconcile，不能把一次 `warn` 变化当作销毁事件。

## 4. 所有清理路径与缺口

### 4.1 已存在的清理路径

1. **正常快照移除**：`Clear(id)` 先清索引再 `pcall(Node:Destroy())`；调用点只有 `Show` 的差集分支。`client/LocalLoot.lua:19-23`、`client/LocalLoot.lua:53-55`。
2. **场景根创建失败**：没有 EUI 或 `CreateSceneNodeAtPosition` 失败/返回空时直接返回，尚未写入 `Nodes`。`client/LocalLoot.lua:25-33`。
3. **按钮创建失败**：`LocalLoot.Create` 销毁已经创建的场景根，不写索引。`client/LocalLoot.lua:34-42`。
4. **Bubble 部分创建失败**：`InteractionBubble` 销毁已创建的文字和按钮并返回 nil，随后由上一项清根。`client/InteractionBubble.lua:6-35`。
5. **正常按钮/文字回收**：正常路径只显式销毁场景根；按钮、文字以根为 `Parent`，按钮的 `OnClicked` 连接没有单独 Disconnect。注释声明它们随根销毁，但本次没有宿主级联销毁证据。`client/InteractionBubble.lua:1`、`client/InteractionBubble.lua:10-27`。

### 4.2 明确缺口

| 缺口 | 源码后果 | 严重性 |
|---|---|---|
| 三个连接均无句柄、无统一 owner | 无法在该 module 内显式 Disconnect；Dock 也不知道这些宿主资源。 | 高 |
| 没有 `Stop`/全量节点清理 | 连接与节点没有共同业务收尾入口；宿主关局是否兜底不能据此推断。 | 高 |
| 重复 `Start` 无 guard | 每再调用一次就新增三条连接并再发一次 `RequestLoot`。重复 Heartbeat 会对同一 `entry.Blink` 多次累加，重复 full 回包会重复通知。 | 高 |
| 启动中途失败无反向清理 | 任一次 Connect 或最后 FireServer 若抛错，之前成功的连接没有句柄可回滚；不声称宿主一定抛错。 | 高 |
| 根 Destroy 失败被静默吞掉 | `Nodes[id]` 已先摘除，`pcall` 失败后没有日志或重试；若 Destroy 抛错，该根不再受 module 管理。 | 中 |
| 整体与局部清理没有同一生命周期 seam | 快照能删单个节点，却没有可验证顺序覆盖“停止事件 → 清节点 → 可重启”。 | 高 |

根销毁缺口依据：`client/LocalLoot.lua:19-23`；服务端 `MgrLoot.Recycle` 则有失败日志和重试，见 `server/Mgr/MgrLoot.lua:208-220`。项目规范要求可重入口连接保存并断开、启动失败反向清理，见 `CODING_STANDARDS.md:50-55`。

## 5. spoke 语义是否匹配

### 5.1 匹配矩阵

| LocalLoot 责任 | spoke 实际语义 | 判定 |
|---|---|---|
| 以掉落 id 持有 child | Dock key 必须是**非空字符串**；当前服务端拾取 id 按 number 校验。需要稳定 key 适配，不能原样使用 number。 | **部分匹配**。`common/packages/spoke/runtime/dock.lua:19-24`、`server/Mgr/MgrLoot.lua:481-483`。 |
| 新 id 建节点，旧 id 保留 | `Dock:call` 是同 key replace；当前 `Show` 是同 id 保留。 | **不能直接映射**。`common/packages/spoke/runtime/dock.lua:50-59`、`client/LocalLoot.lua:47-51`。 |
| 消失 id 销毁节点 | `drop` 找到 child 后 detach 并释放 key；活动 frame 内延迟到 frame pop。 | **匹配节点寿命**，但根 Destroy 必须确实归 child cleanup 所有。`common/packages/spoke/runtime/dock.lua:99-123`。 |
| 整体清空 | Dock 初始化注册 cleanup，整体 detach 时按最新到最旧拆除全部 live children 并 reset。 | **匹配**，但当前没有整体 dispose 出口。`common/packages/spoke/runtime/dock.lua:42-46`、`common/packages/spoke/runtime/dock_slots.lua:99-107`。 |
| 从完整快照算 `alive` 差集 | Dock 提供 call/effect/drop，不提供“消费列表并 reconcile”的 public 行为。 | **不匹配；仍是业务 implementation**。`common/packages/spoke/runtime/dock.lua:36-143`。 |
| `Position`、`Warning`、`Blink`、距离显隐 | Dock 管 keyed Epoch 寿命，不管这些表现状态，也不自动连接 Heartbeat。 | **不匹配，仍需业务 owner**。`client/LocalLoot.lua:59-82`。 |
| 两条 RemoteEvent 与 Heartbeat 退订 | Epoch attachment 可拥有 cleanup，逆序释放，单项失败记录并继续；Connection 不会自动被 Dock 发现。 | **树可承接，Dock 不能单独承接**。`common/packages/spoke/runtime/epoch_builder.lua:83-100`、`common/packages/spoke/runtime/epoch_teardown.lua:19-36`。 |
| Start/Stop 重入 | `SpokeTree:dispose()` 转为 detach；`Epoch:detach()` 幂等，活动 frame 中延迟。 | **提供收尾原语，不决定谁调用 Start/Stop**。`common/packages/spoke/runtime/spoke_tree.lua:177-179`、`common/packages/spoke/runtime/epoch.lua:115-138`。 |

现有 `LocalReelIn` 已证明本仓可用的宿主 adapter 形状：Connection 通过 `s:on_cleanup` Disconnect，重复 `Start` 不叠树，`Stop` 拆树并清引用；Heartbeat 也由树内 cleanup 拥有。这里只把它作为 lifecycle precedent，不要求照搬其 interface。证据：`client/LocalReelIn.lua:94-110`、`client/LocalReelIn.lua:119-143`。

### 5.2 `spoke_eggy` 不是默认答案

`spoke_eggy.behaviour` 把一棵树绑到**某个 Unit.Destroying**；没有 Unit 生命周期时应直接使用 `SpokeTree`，退出点仍需显式 dispose。`LocalLoot` 是客户端单例 module，三个连接不属于某一个掉落根 Unit，因此不能仅借 `spoke_eggy` 解决整体 Start/Stop。包内也明确把 Heartbeat pump 留给消费方，见 `common/packages/spoke_eggy/api.lua:1-7`、`common/packages/spoke_eggy/api.lua:129-137`。

其 dispose 顺序是 `is_alive:false` → 拆树 → 断开 Destroying，且幂等，见 `common/packages/spoke_eggy/api.lua:233-250`。这证明宿主 adapter 能集中寿命，不证明 LocalLoot 已有合适的 Unit owner。

### 5.3 Deletion test：是否真的加深 module

**方案 A：只把 `Nodes` 换成 Dock，同时保留 Nodes 镜像、`alive` 差集、`Clear`、手工 Node.Destroy 和连接管理。**

- 删除 Dock 后，原手工路径仍能完成同样工作。
- Dock 没吸收可删除的 implementation，反而增加 key 转换、Init/Tick、detach 顺序等 interface 知识。
- **deletion test 失败：shallow wrapper，不推荐。**

**方案 B：keyed child 真正拥有场景根及 cleanup，树拥有三个宿主连接；`Nodes` 作为第二套资源索引和手工 Destroy 路径被删除。**

- 删除 Dock/树后，单 key/整体拆除和连接 cleanup 会失去实际承担者，需要重新写回。
- `alive` reconciliation 可以保留；它是快照到 keyed 结构变化的业务映射，不应为了“全删手工差集”伪造通用框架。
- **只有这种情况 deletion test 才通过，module 才更 deep。**

**方案 C：新建面向所有 Local* 的通用生命周期容器/单位工厂。** 当前只有一个 96 行候选，证据不足以证明跨模块通用 leverage，并与 ADR-0026 冲突，**不推荐**。

## 6. locality、leverage 与测试收益

### locality

- **现有优点**：创建、差集、显隐、单节点清理已集中在 `LocalLoot`。
- **现有缺口**：连接 setup 在 `Start`，没有对应 teardown locality；根与子按钮正常销毁跨 `LocalLoot`/`InteractionBubble` 两层。
- **潜在收益**：树/child cleanup 可把 setup 与 teardown 放在同一生命周期作用域。
- **潜在反收益**：若 `Nodes`、Dock slot、Epoch attachment、OwnedUnits 同时成为真实 owner，locality 反而下降。

### leverage

- Dock 的 leverage 是 keyed detach、replace、整体逆序 cleanup，不是快照 diff，也不是宿主事件 adapter。
- `Show` 仍需遍历完整快照，Dock 不消除 O(n) reconciliation；没有证据证明性能收益。
- 每区 200 件不是全局 200 件，跨区快照可能超过 255 个 key；Dock 在 slot 超坐标范围且空洞足够时会 compact/reindex。是否影响业务需测量。玩法上限见 `docs/GameSpec.md:337-341`，compact 实现见 `common/packages/spoke/runtime/dock_slots.lua:17-21`、`common/packages/spoke/runtime/dock_slots.lua:71-85`。

### 测试收益

1. 用公开宿主输入驱动，无需知道 `Nodes`。
2. 区分“同 id 保留身份”和“同 key 被 replace”。
3. 证明 Disconnect 真生效，而非只检查句柄字段为 nil。
4. 用同一组外部行为比较手工与 spoke implementation，形成可替换 seam。

## 7. 当前测试的实现耦合

### 7.1 对 Nodes 的耦合

`entry(id)` 直接返回 `ctx.client.Nodes[id]`，见 `tests/native/loot_client_test.lua:78-80`。随后：

- 消失清理用 `entry(3).Node` 和 `entry(3) == nil`：`tests/native/loot_client_test.lua:98-105`。
- 距离显隐读取 `entry(1).Node`：`tests/native/loot_client_test.lua:107-120`。
- 预警闪烁读取 `entry(7).Node`：`tests/native/loot_client_test.lua:122-136`。
- 预警解除读取 `entry(5).Node`：`tests/native/loot_client_test.lua:138-146`。

这把 `Nodes` 的形状变成测试必须学习的 interface；即使外部行为不变，改成 Dock 也会先破坏测试。点击用例相对更好：按外部单位名 `BtnPickup_9` 找按钮、触发 `OnClicked`、断言上行请求，没有读 `Nodes`，见 `tests/native/loot_client_test.lua:82-96`。

### 7.2 假连接无法证明退订

当前 `signal()` 的 `Disconnect` 是空操作，`Fire` 永远遍历全部历史 callbacks，见 `tests/native/loot_client_test.lua:10-17`。每个用例执行 `Start`，`after_each` 只恢复全局与 package cache，没有 Stop，见 `tests/native/loot_client_test.lua:64-76`。假环境随用例丢弃，旧连接泄漏不可见。

仓库已有对照：`tests/support/reel_env.lua` 让 Disconnect 真生效、Fire 只送当前存活连接，并暴露存活计数，见 `tests/support/reel_env.lua:1-5`、`tests/support/reel_env.lua:21-27`。业务测试通过外部计数和迟到事件验证重入/停止，见 `tests/native/reel_client_test.lua:71-95`。

### 7.3 外部可观察行为方向

不设计新 interface，只调整观察点：

- 从 `ctx.sceneNodes` 取得场景根；该列表已由 `CreateSceneNodeAtPosition` adapter 记录，每个根有 `Visible`、`Destroyed`，见 `tests/native/loot_client_test.lua:36-44`。
- 从 `ctx.created` 和按钮 `Name`/`OnClicked` 观察按钮身份与点击结果，见 `tests/native/loot_client_test.lua:47-54`、`tests/native/loot_client_test.lua:82-96`。
- 用 Heartbeat `Fire` 驱动显隐，而不是直接调用 `Update`，把宿主连接纳入同一行为链。
- 用真实可断开的 signal 观察存活订阅数和迟到事件，不读内部连接字段。
- 真实 EUI 父子级联必须另以编辑器试玩取证；不能把 fake 的 `Destroyed = true` 扩张成宿主真实行为。

## 8. 最小可证伪验证

| 场景 | 外部操作与观察 | 能推翻什么 |
|---|---|---|
| 同 id 重复快照 | 连续发送两份都含 id 7 的快照；应仍是同一根，未销毁/重建。 | 推翻“每份快照无条件 `Dock:call`”的朴素替换。 |
| id 消失再出现 | 先发 id 7，再发空快照，再发 id 7；旧根 Destroyed，新根是不同实例，只有新根存活。 | 推翻只摘索引不销毁、重复销毁旧根、错误复用旧节点。 |
| 多 id 选择性移除 | 建立 id 3、7，再只保留 7；只销毁 3，7 的身份与显隐连续。 | 推翻全量重建或错误 key 适配。 |
| 预警与距离不回归 | 通过 LootState 和 Heartbeat 驱动 warn 开关、2 米内外；观察根 Visible，点击命名按钮检查只发对应 id。 | 证明迁移没吞掉玩法行为；条款见 `docs/acceptance/08-npc-exchange-ferry.md:24-29`。 |
| 重复 Start | 记录三条连接存活数和 RequestLoot 次数，再次 Start；不应叠加旧 generation 回调，full 通知和 Blink 累加不能倍增。 | 直接使当前实现失败，证明重入缺口被修复。 |
| Stop 后迟到事件 | 建立节点后 Stop；三条连接归零、全部场景根销毁。再 Fire 旧事件，不应创建、通知或改写节点。 | 推翻只把 Tree 字段置空、Disconnect 未真实生效的假清理。 |
| Stop 幂等与重启 | 连续 Stop 不报错或重复销毁；重新 Start 后只有一套连接，能接收新快照，旧事件不能改写新 generation。 | 推翻只处理单向退出的实现。 |
| 启动中途故障注入 | 分别让第 2/3 次 Connect 或最后请求失败；此前连接被反向清理，后续 Start 不残留上一轮。 | 证明失败路径满足 `CODING_STANDARDS.md:50-55`。 |
| 根销毁失败 | 让根 Destroy 抛错；观察错误是否可诊断，module 是否仍谎称清理完整。 | 暴露当前 `pcall` 静默摘索引的缺口；预期策略需实施前定案。 |
| 编辑器试玩 | 对真实根、按钮、文字执行出现/消失/重启，观察实际销毁与点击失效，保留日志/截图。 | 补足 native fake 无法证明的 SE 级联和宿主连接行为。 |

业务测试无需再次断言 Dock slot compaction、frame stack 或逆序释放算法；只需证明 LocalLoot 的可观察节点身份和宿主清理结果。

## 9. ADR、架构与玩法约束

1. **上游包不可就地改**：即使认为缺少快照 reconciliation，也不能在 `common/packages/spoke*` 内补方法。本研究没有证明确有通用库缺口。`docs/adr/0022-introduce-spoke-runtime.md:12-14`、`docs/adr/0024-introduce-spoke-eggy-host-package.md:12-13`。
2. **不建全局 unit factory/container**：`InteractionBubble` 的 `World:CreateUnit` 保持原址。`client/InteractionBubble.lua:6-20`、`docs/adr/0026-no-global-unit-factory.md:37-54`。
3. **OwnedUnits 必须保留**：新触及代码需明确 owner、命名与回收路径。若与 Dock child cleanup 组合，必须避免同一根被两套 owner 重复销毁，不能借 Dock 删除 OwnedUnits。`docs/adr/0026-no-global-unit-factory.md:14-21`、`common/OwnedUnits.lua:1-9`。
4. **层依赖不变**：`client.Local*` 属 L2，`common.packages` 属 L6，业务向包依赖允许；无需新建层或移动 LocalLoot。`docs/architecture.md:9-18`。
5. **保留 `server/main.lua` 的 MgrMap seam**：`MgrLoot` 已登记，由入口统一 `Start`/`Update` 分发；客户端候选不应绕开或复制服务端分发。`server/main.lua:14-23`、`server/main.lua:302-312`。
6. **服务端仍是权威**：2 米内显示只是客户端表现，拾取由服务端复验；满格保留地面物品。`docs/GameSpec.md:337-340`、`server/Mgr/MgrLoot.lua:480-504`。
7. **预警不是删除**：回收前闪烁 30 秒，预警期间仍可拾取；不能因 `warn=true` 提前 drop child。`client/LocalLoot.lua:1-4`、`docs/GameSpec.md:339-340`。
8. **现有标识保持可观察**：`BtnPickup_<loot.id>` 是当前点击测试和业务识别依据，不应无谓改名。`client/LocalLoot.lua:34-36`。

## 10. 仍开放问题与未核对项

1. **整体 Stop 的真实调用者**：`client/main.lua` 当前只有 Start，没有 LocalLoot Stop 分发。是局内重开、测试重启还是其他宿主时点，尚需已取证依据；不能虚构关局事件。
2. **SE 关局是否兜底这些连接和场景根**：本次未做真机探针。ADR-0024 只记录 Unit.Destroying 在关局不触发，不能推导其他资源一定自动清理或一定泄漏，见 `docs/adr/0024-introduce-spoke-eggy-host-package.md:21-24`。
3. **真实 EUI 父子级联**：`InteractionBubble` 注释声明按钮和文字随根销毁，但本次未证明真实宿主中级联及 OnClicked 失效时点。
4. **同 id 的 Position 是否允许变化**：当前只更新 Warning、保留首次 Position；Dock replace 会带来新 child。需先定契约，不能无意改变。`client/LocalLoot.lua:42`、`client/LocalLoot.lua:47-51`。
5. **根 Destroy 失败的处理目标**：当前无日志/重试；是否对齐服务端重试策略属于后续决策。
6. **启动失败的宿主可达性**：fault injection 能验证回滚逻辑，但真实 SE Connect/FireServer 哪些失败可达，本次未核对。
7. **多区大量 key 的 compact 成本**：没有性能测量，不能声称 Dock 更快或更慢。
8. **测试与试玩证据**：本次未运行任何测试；以上“当前会失败”是源码控制流导出的可证伪预测，不冒充实测结果。

## 11. 最终建议

- **高优先级**：明确三个宿主连接与全部场景根的共同 owner、Stop 顺序、重复 Start 和启动失败回滚，并用真实 Disconnect 的外部行为测试封口。收益不依赖 Dock。
- **中等、附条件**：仅当 keyed child 能实际吸收场景根寿命、删除 `Nodes` 的第二套资源所有权和手工 `Clear/Destroy`，并保留同 id 节点身份时，才采用 Dock。保留 `alive` reconciliation 不构成失败。
- **不推荐**：Dock 外加原 Nodes 镜像的双层结构、为 LocalLoot 发明通用框架、把 `spoke_eggy` 当作无 Unit owner 的清理总线、就地修改 spoke/spoke_eggy。
- **验收重心**：外部根节点身份、销毁、点击、显隐、连接存活数和迟到事件，而不是 `Nodes`、Dock slot 或 Epoch 内部字段。
