# 0032 以 Spoke 原生架构重构服务端与客户端生命周期

**Status**: accepted（吸收原 ADR-0026 剩余规则：不建全局单位工厂、单位命名、不新增事件桥）

存量命令式架构曾将生命周期复杂度分散在 32 个 `MgrMap` 单例、`MgrGameUI` + 自绘屏双轨 UI、`OwnedUnits` 外部登记表与官方包黑盒计时器中。本 ADR 确立基于 Spoke Runtime 的服务端/客户端目标架构与运行期单位所有权规则，原有 `MgrMap`、`MgrGameUI`、`OwnedUnits` 已在 #316 清零并由门禁阻止回归。

## 决定

### 1. 三类服务端树拓扑与客户端响应式投影
服务端按「共享世界 / 玩家隔离 / 活鱼实体」切分为三类独立 Auto `SpokeTree`（树级故障隔离，防止单玩家或单条鱼异常拖垮全服）：

1. **`SharedWorldTree`（全局 1 棵）**：承载 7 个钓鱼区的地面物品 `Dock`、鱼饵刷新点、摆渡航线与全局小队 `SquadDock`。
2. **`PlayerTree`（每名在场玩家 1 棵）**：存档 `OnReady` 时 `spawn`，离场排空前 `dispose()`。树内按**源码声明顺序**排列因果流，确保同宿主事件内上游先算、下游后跑：
   - 存档与库存 `State` → 属性与效果派生 `Memo` / `ModifierDock` → 生命与生存 `Phase` → 动作、特殊道具与设施会话 `Phase`。
3. **`FishTree`（每条活鱼 1 棵）**：按生命阶段嵌套 `Phase`（`Lifted` → `Combat` → `Escaping`）；阶段切换或鱼死亡/入水时，`on_cleanup` 自动拆除预警贴花、叼人挂点、碰撞隔离与载体单位。

客户端统一为单轨响应式视图：
- 外围将 `RemoteEvent` 快照与本地位置/区域传感器收敛为只读 `ClientStore`（`client/store/`，纯 Spoke `State` / `Trigger`）；
- 所有界面与场景文字泡写成 `client/views/` 下的 Spoke 视图树——常驻 HUD 挂树根，弹窗与蒙版由 `Phase` 控制建拆，动态列表由 `Dock` 管理身份与回收。

### 2. 玩家双层 `Phase` 状态机与离场三步协议
- **外层生命相位 `Phase(life_phase == 'alive')`**：挂载饥饿、环境扣血、钓鱼、特殊道具接管与烧烤活跃会话；进入濒死、死亡或离场时逆序 `on_cleanup` 自动收尾。
- **濒死/死亡相位**：`downed` / `dead` 内嵌 `Phase(not platform_pending)`，发起付费/广告复活时暂停倒计时，取消/失败/超时即恢复。
- **内层行动守卫 `Memo(can_act = is_alive and not is_paralyzed)`**：门控主动输入；短暂麻痹只令 `can_act = false`，不退出外层 `alive` 相位。
- **离场三步协议**：根部持有 `session_alive`（`State<boolean>`）。`Players.PlayerRemoving` 在前置脏写后固定执行：
  1. `session_alive:set(false)`（触发离场终镜像与烧烤离场结算）；
  2. `PlayerTree:dispose()`（逆序拆除在场资源、外观绑定与连接）；
  3. 宿主执行 `SaveLeaving` 序列化与 `AfterIdle` 异步排空栅栏（异步 I/O 栅栏不塞进 Spoke 同步 teardown）。

### 3. 跨树协作、事务模型与官方包降级
- **跨树只读联动走 `s:d(signal)`**：下游树直接观察上游树的只读 `State` / `Memo`，禁止上游改完状态再命令式回调下游。
- **跨树原子写入与离散业务走 `SpokeRuntime.batch`**：先校验条件与容量，再在同一 batch 内原子更新相关树 `State`；树底 `Reaction` 自动合并下发 `RemoteEvent` 与存档镜像。
- **四个官方包降级为叶子投影层（Leaf Sink）**：`ability_system`、`attr_rule`、`modifier_system`、`official_ai_feature` 不持有玩法状态与计时主权，仅在树底层用纯输出 `Effect` 单向写入并在 `on_cleanup` 注销。

### 4. 双包零扩展、单位所有权与 `SpokeClock`
- **双包零扩展**：`spoke` 与 `spoke_eggy` 公共面保持原样，不向宿主包塞入帧泵或宿主全局读取（[ADR-0022](0022-introduce-spoke-runtime.md)）。
- **单位所有权严格二分**：
  - `Unit → Tree`（宿主单位销毁决定树生命期）：用 `spoke_eggy.behaviour(unit, init, options)`；
  - `Epoch → Unit`（Spoke 作用域决定动态单位生命期）：在 `CreateUnit` 同作用域注册 `s:on_cleanup(function() unit:Destroy() end)`，不依赖父子级联。
- **不建全局单位工厂、不建统一挂载容器、不新增事件桥**：`CreateUnit` 保持现址调用（参数差异大，统一包装只是假统一）；新创建的运行期单位名必须带模块前缀与实例/所有者标识（禁止裸固定名）；官方包既有的三套事件桥原样保留，不新增第四套。
- **宿主信号边界**：常驻宿主信号（`RemoteEvent`、`Players`）在入口一次性 `Connect` 并翻译为 `State` / `Trigger`；动态 `Unit` 局部信号随该 `Unit` 在同一 `on_cleanup` 断开。
- **纯消费方时钟 `common/spoke_clock.lua`（L4）**：不读引擎全局，由 L1 入口泵入 `clock:step(dt, now)`，只暴露 `clock.second` / `clock.on_second`（1 Hz）、`clock.on_frame`（仅短寿命活跃 `Phase` 经 `s:subscribe` 按需订阅）与 `clock.now()` 只读函数；**严禁**暴露每帧刷新的 `State<now>`。

### 5. 分层与单向门禁
- `common.spoke_clock` 归 L4，`client.store` 归 L3，`server.world_host` 与 `client.views` 归 L2（[ADR-0012](0012-six-layer-architecture.md)）。
- `tests/native/guards/spoke_ratchet_guard_test.lua` 守卫 `OwnedUnits` 调用、旧式裸 `:Connect(`、`MgrMap` 成员均为 0，禁止回归。

## 拒绝的方案

1. **在旧 `MgrMap` / `MgrGameUI` / `OwnedUnits` 外壳上局部套用 Spoke**：无法消除网状回调与双轨 UI。
2. **全服合并为单一根 `SpokeTree`**：单玩家或首领异常会拖垮整棵树 flush。
3. **全局单位工厂**：参数形态差异过大，退化为 `CreateUnit` 透传壳，解决不了归属回收问题。
4. **把每帧 `now` 暴露为 `State<number>`**：导致 30–60 FPS 下每帧拆除重建 `Effect` attachments。
