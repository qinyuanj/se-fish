# 0032 以 Spoke 原生架构重构服务端与客户端生命周期，棘轮淘汰既有债务

**Status**: accepted

`spoke`（[ADR-0022](0022-introduce-spoke-runtime.md)）与 `spoke_eggy`（[ADR-0024](0024-introduce-spoke-eggy-host-package.md)）是在代码库成型之后引入的。存量业务代码的生命周期复杂度集中在四处：`server/main.lua` 用 32 个平级 `MgrMap` 单例互相注入，靠分散的 `OnDied` / `Interrupt` / `BeforeLeave` 与每帧 `Reconcile` 维持状态一致；客户端分裂为 `MgrGameUI` 预置节点屏与 9 个 `Task:Spawn` 自绘屏加 10 个 `Local*` 控制器；运行期单位销毁依赖外部登记表 `common/OwnedUnits.lua`（[ADR-0026](0026-no-global-unit-factory.md)）；官方包内部各自持有黑盒状态与计时器。

本 ADR 决定**不在旧管理器外壳上零敲碎打地包 Spoke**，而是直接从 [GameSpec](../GameSpec.md) 的玩法语义重新设计基于 Spoke Runtime 的目标架构，将既有命令式生命周期代码一律视作可淘汰债务，通过单向棘轮逐步切换。

它部分取代 [ADR-0026](0026-no-global-unit-factory.md) 中以 `OwnedUnits.lua` 为唯一单位回收方案的决定：新代码与已迁移切片改由 Spoke 作用域 `on_cleanup` 负责销毁，`OwnedUnits.lua` 已在 #316 删除（原 ADR-0026 的单位命名规范与「不建全局单位工厂、不新增第四套事件桥」继续有效）。

## 决定

### 一、三类服务端树拓扑与客户端响应式投影

服务端严格按 [GameSpec](../GameSpec.md) §1 的「共享世界 / 玩家隔离 / 活鱼实体」切分出三类独立的 Auto `SpokeTree`（利用树级故障隔离，防止单个玩家或一条活鱼的异常导致全服停转）：

1. **`SharedWorldTree`（全局 1 棵）**：下挂 7 个钓鱼区的 `FishingZoneEpoch`（各自用 `Dock` 管理单区 200 件上限的地面物品与 30 秒闪烁回收相位、15 秒鱼饵刷新点 `BaitSpotEpoch`、六条去程 5 秒倒计时 `FerryRouteEpoch`）与全局小队 `SquadDock`。
2. **`PlayerTree`（每名在场玩家 1 棵）**：在存档 `OnReady` 时 `SpokeTree.spawn`，离场排空前 `dispose()`。树内按**源码声明顺序**严格排列因果流，利用 Spoke 的 tree coordinate 保证同一宿主事件内上游先算、下游后跑：
   - `1. 存档与库存 State`（金币、道具栏/背包、武器/鱼饵库存、选中槽、药水/升级、图鉴/任务/冷却）
   - `2. 属性与效果派生 Memo / ModifierDock`（血量上限、体型缩放、移速倍率、虚弱/中毒/灼烧/霜冻/麻痹计时槽位）
   - `3. 生命与生存 Phase`（血量、饥饿、`alive` / `downed` / `dead` 相位）
   - `4. 动作、特殊道具与设施会话 Phase`（抛竿/收线/举鱼、武器换弹、风神之翼/哥斯拉、烧烤/抽奖会话）
3. **`FishTree`（每条活鱼 1 棵）**：按品级与生命阶段建立嵌套 `Phase`：`Lifted` → `Combat`（含精英 180 秒 / 首领 300 秒逃跑倒计时、招式激活与眩晕/睡眠交替，以及哥斯拉 `hp > 60%` / `20% < hp <= 60%` / `hp <= 20%` 三阶段）→ `Escaping`。阶段切换或鱼死亡/入水时，`on_cleanup` 自动拆除预警贴花、叼人挂点（`CarryMount`）、碰撞隔离与载体单位。

客户端废除 `MgrGameUI` 预置屏与 `Task:Spawn` 自绘屏的双轨割裂：
- 外围将服务端下发的 `RemoteEvent` 快照与本地角色位置/所属钓鱼区传感器收敛为只读 **Client Reactive Store**（纯 Spoke `State` / `Trigger`）；
- 所有界面与场景文字泡统一写成订阅 Store 的 Spoke 视图树——常驻 HUD 挂在树根，弹窗（钓场商店、图鉴、盲盒、抽奖机、对话）与蒙版（濒死/死亡、收线、瞄准拾取层）由 `Phase` 控制建拆，动态列表（容器格位、队友血量行、附近钓鱼佬/摊位/抢救气泡）由 `Dock` 管理身份与回收。

### 二、玩家双层 `Phase` 状态机与离场三步协议

在 `PlayerTree` 内用两层嵌套表达行动与持续会话边界，彻底消灭散落各模块的 `OnDied` / `Interrupt` / `Reconcile`：

- **外层生命相位 `Phase(life_phase == 'alive')`**：内部挂载每秒 -1 饥饿与核废料桶每秒 -1 血、钓鱼流程、特殊道具外观与飞行接管（`Phase(selected == 'wings')`、`Phase(selected == 'godzilla')`）、烧烤炉活跃会话。一旦进入濒死、死亡或离场，外层 `Phase` 卸载，Spoke 按逆序 `on_cleanup` 自动停饥饿、断线收竿、卸翅膀/皮肤/恢复重力、按当前倍率结算烧烤鱼获。
- **濒死与死亡相位**：`Phase(life_phase == 'downed')`（15 秒）与 `Phase(life_phase == 'dead')`（30 秒）均内嵌 `Phase(not platform_pending)`，发起看广告或金豆满血复活时自动暂停倒计时，取消/失败/超时即恢复。
- **内层行动守卫 `Memo(can_act = is_alive and not is_paralyzed)`**：门控攻击、投掷、点收线、吃药等主动输入与读条动作。雷霆之力 0.5 秒麻痹只令 `can_act = false`，不退出外层 `Phase(is_alive)`，避免麻痹误触发脱钩或解除哥斯拉变身。
- **离场三步协议（区分离场与正常相位切换）**：`PlayerTree` 根部持有 `session_alive`（`State<boolean>`，初始 `true`）。`Players.PlayerRemoving` 在完成异步前置脏写（任务/剧情）后，固定执行三步：
  1. `session_alive:set(false)`：触发离场终镜像（写入濒死/死亡/虚弱剩余秒数、吐息剩余冷却）与烧烤离场结算；
  2. `PlayerTree:dispose()`：按逆序拆除全部在场资源、外观绑定与事件连接；
  3. 宿主执行 `SaveLeaving` 序列化与 `AfterIdle` 异步排空栅栏（保留 `LeavingPlayers.Waiting` 防同 `UserId` 重进覆盖旧会话，异步 I/O 栅栏不塞进 Spoke 同步 teardown）。

### 三、跨树协作铁律、事务模型与官方包降级

1. **跨树只读联动走 `s:d(signal)`**：下游树直接观察上游树的只读 `State` / `Memo`（例如活鱼 `LiftedPhase` 直接 `s:d(ownerPlayerTree.is_alive)`，持有者濒死或离场时活鱼树自发转入落地状态；小队 `SquadEpoch` 直接 `s:d(memberTree.health)` 聚合快照），禁止上游改完状态再命令式回调下游。
2. **跨树原子写入与离散业务走 `SpokeRuntime.batch` 事务**：扣费发奖、喂食兑换、交船票启动摆渡、地面物品拾取/丢弃、抽奖、盲盒、烧烤投入/取出等离散操作，先校验条件与容量，再在同一个 `SpokeRuntime.batch(fn)` 内原子更新相关树的 `State` 并落入操作日志。树底部的 `Reaction` 自动合并下发客户端 `RemoteEvent` 并同步存档镜像，业务函数不再手写 `SendState` / `Mirror`。
3. **四个官方包降级为叶子投影层（Leaf Sink）**：`ability_system`、`attr_rule`、`modifier_system`、`official_ai_feature` 不再持有任何玩法状态与计时主权。所有持续效果计时与层数、属性倍率、仇恨与阶段全部在 Spoke 树内计算，仅在树底层用纯输出 `Effect` 单向写入官方包或 `Character.Controller`，并在 `on_cleanup` 注销。

### 四、`spoke` 与 `spoke_eggy` 零扩展边界、所有权二分与 `SpokeClock`

- **双包零扩展**：`common/packages/spoke/`（13 个核心类）与 `common/packages/spoke_eggy/`（`behaviour(unit, init, options)`）均保持现有公共面原样不动，严格遵守上游 `#22`「宿主包只管树生命周期，不持有帧泵，不读宿主全局」的边界。
- **单位所有权严格二分**：
  - `Unit → Tree`（宿主 `Unit` 的销毁决定树生命期）：使用 `spoke_eggy.behaviour(unit, init, options)`；
  - `Epoch → Unit`（Spoke 的 `Phase` / `Dock` / `Effect` 决定动态创建 `Unit` 的生命期）：在 `CreateUnit` 的同一作用域直接注册 `s:on_cleanup(function() unit:Destroy() end)`，不再登记进 `OwnedUnits`。
- **宿主信号边界**：常驻宿主信号（`RemoteEvent`、`Players`）在树外围入口处一次性 `Connect` 并翻译为 `spoke.State` / `spoke.Trigger`，树内业务只用原生 `s:d` 与 `s:subscribe`；动态 `Unit` 自身的局部信号（按钮 `OnClicked`、活鱼 `OnLiftedBegin`）随该 `Unit` 写在同一个 `s:on_cleanup` 中断开。
- **纯 Spoke 消费方时钟 `common/SpokeClock.lua`（L4 共享规则）**：不读任何引擎全局，由 `server/main.lua` 与 `client/main.lua` 在 L1 入口把 `RunService.Heartbeat` 与 `World:GetServerTime()` 泵入 `clock:step(dt, now)`（单测直接调 `clock:advance(sec)`），只暴露 3 类成员：
  1. `clock.second`（`State<number>`，整秒 1 Hz）与 `clock.on_second`（`Trigger`，1 Hz，自动处于 `Trigger:invoke` batch 中）：用于秒级倒计时 `Memo` 与周期结算（饥饿、核废料桶、收线 -5%/秒、中毒/灼烧、电鳗放电）；
  2. `clock.on_frame`（`Trigger`，每帧 `invoke(dt, now)`）：**仅供短寿命活跃 `Phase`**（活鱼位移、飞行、4.5 秒烧烤曲线、0.5 秒麻痹或亚秒招式冷却）通过 `s:subscribe` 按需订阅，不重建 `Effect` 节点；
  3. `clock.now()`（普通只读函数）：随时读取精确服务器时刻，**严禁**暴露每帧刷新的 `State<now>`，防止 60 FPS 重建 `Effect` attachments。

### 五、分层落位、单向棘轮路径与机械门禁

1. **命名空间与分层（配合 [ADR-0012](0012-six-layer-architecture.md) 与 `tools/arch_policy.lua`）**：
   - `common/SpokeClock.lua` 归 **L4（共享规则）**；
   - 服务端新建 `server/World/`（承载 `SharedWorldTree`、`PlayerTree`、`FishTree` 及领域子 Epoch），客户端新建 `client/Store/`（Reactive Store）与 `client/Views/`（Spoke 视图树），登记入 `tools/arch_policy.lua` 并同步投影到 `policy.edn`。
   - **过渡期单向依赖铁律**：只允许存量债务模块（`server.Mgr`、`client.ScreenHandlers`、`client.Local*`）单向读取新 Spoke 命名空间，**严禁新 Spoke 代码反向 `require` 旧模块**（必须调用的过渡接缝仅在 L1 入口以回调注入，切片完成后即删），防止触发 `arch_policy` 的命名空间投影环检查。
2. **分步棘轮迁移**：
   - **第 0 步（立主干）**：落地 `common/SpokeClock.lua`、`SharedWorldTree` / `PlayerTree` 主干与客户端 `ClientStore` 根视图树；
   - **第一批切片（玩家生命与状态调和）**：属性/药水/升级 + 生命/饥饿/濒死/死亡/复活 + 特殊道具（风神之翼/哥斯拉）+ 客户端生存蒙版与主 HUD 血球/道具栏；
   - **第二批切片（核心钓鱼与活鱼）**：抛竿/咬钩/收线 + 活鱼与首领三阶段 + 地面掉落与鱼饵刷新点；
   - **第三批切片（设施、经济与多人）**：烧烤、抽奖机、钓鱼佬/钓场商店/摆渡、小队与抢救气泡、图鉴/纪录/盲盒/新手任务。
3. **机械棘轮门禁**：在 `tests/native/guards/spoke_ratchet_guard_test.lua` 为旧债务（`OwnedUnits.` 调用数、旧式裸 `:Connect(` 数、`MgrMap` 成员数）设立只减不增的水位线断言。#316 已将三类水位全部降为 0，并删除 `common/OwnedUnits.lua` 与旧入口分发；守卫继续阻止回归。

## 拒绝的方案

1. **保留 `MgrMap` / `MgrGameUI` / `OwnedUnits` 外壳，仅在内部局部套用 Spoke**：虽然改动风险最低，但会永久保留 32 个平级管理器之间的网状回调、`OwnedUnits` 双重账本与客户端双轨 UI，无法根治生命周期复杂度。
2. **全服合并为单一根 `SpokeTree`**：Spoke 的未捕获故障会令整棵树停止 flush；不按玩家与活鱼拆分独立树，单个玩家或首领的异常会波及全场。
3. **扩展 `spoke_eggy` 增加 `connect` / `own_unit` / 帧泵定时调度器**：违反上游 `#22`「宿主包不持有帧泵」边界，且与 Spoke 原生 `s:subscribe(trigger)`、`s:on_cleanup` 职责重叠。
4. **把每帧 `now` 暴露为响应式 `State<number>`**：任何 `s:d(now)` 的 `Effect` 都会在 30–60 FPS 下每帧拆除并重建 attachments，违背 Spoke「编排长寿命行为、不承载高频逐帧重建」的性能边界。

## 后果

- 每次迁移须按垂直切片同时替换服务端与客户端并下调源码守卫水位线，不允许长期滞留在半迁移态。
- 新增 `common/SpokeClock.lua`、`server/World/`、`client/Store/`、`client/Views/` 时须同步更新 `tools/arch_policy.lua`、`policy.edn` 并重生成 `docs/uml/se-fish.edn`，确保 `arch_policy_test.lua` 持续全绿。
- 既有 `docs/acceptance/README.md` 验收矩阵与 `fast`/`full` 测试车道在每一批切片迁移期间均须保持不退化。
- 当 `OwnedUnits.` 水位线归零后，[ADR-0026](0026-no-global-unit-factory.md) 的归属登记条款完全退出历史舞台，仅保留命名规范与事件桥约束。
