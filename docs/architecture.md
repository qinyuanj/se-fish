# 架构分层与依赖门禁

本图采用六层，保留 `client/`、`server/`、`common/` 三个运行端目录。运行端不是高低层，层归属落实到真实模块或现有命名空间；不新增 `Domain`、`Engine`、`Adapters` 根包，也不为贴层名搬移文件。

## 层级

下表由外到内排列。依赖只能指向同层或更内层，允许跨层向下调用。

| 层 | 真实命名空间 | 职责 |
|---|---|---|
| L1 入口 | `client.main`、`server.main` | 唯一组合根：启动、宿主适配器与玩法服务装配、引擎事件翻译和依赖注入 |
| L2 应用流程与宿主 | `server.World`、`server.AbilityAPI`、`server.AbilityBehaviors`、`server.PlayerDataHost`、`server.SaveHost`、`server.PlatformHost`、`server.FishAbility`；`client.Views` | 服务端 Spoke 世界/玩家/活鱼树与持久化、平台、能力宿主；客户端 Spoke 视图树与输入、交互流程 |
| L3 展示与运行端支撑 | `client.Store`、`client.GameUI` 等展示基元；`server.FishBehaviors`；`common.REUtil`、`Util`、`TeleportUtil`、`DamageNotice`、`GarBiteNotice` | 客户端只读响应式状态仓库、展示、主界面布局、手势与瞄准；行为分发；引擎和协议适配 |
| L4 共享规则与业务状态 | `server.Data`、`server.SwingRegistry`；`common.SpokeClock`、`common.GameCfg`、`AttrModel`、`FishCatch`、`Vitals` 等规则模块 | 存档与记录、一次性挥砍登记、消费方确定性时钟、配置解析与共享玩法计算 |
| L5 配置内容 | `common.cfg` | 鱼、物品、商店、抽奖、盲盒与占位资产数据 |
| L6 包 | `client.packages`、`server.packages`、`common.packages` | 整包交付的库：**官方包**与**自研包**。门禁仍要求可分类，但架构图不画、质量工具不度量（[ADR-0021](adr/0021-packages-outside-business-scope.md)） |

完整模块名单只有一份：`tools/arch_policy.lua` 的 `M.policy.levels`。已有命名空间的后代继承归属；独立根模块逐个登记，未分类模块会使门禁失败。

## 关键边界

- 三端 `packages` 同属 L6，且不进架构图与质量工具；业务对包的 `require` 在图上收成外部椭圆。门禁仍扫描包源码并保留原有规则：包不得依赖包外业务，包与包外业务共同形成的循环依赖同样被拒绝（[ADR-0021](adr/0021-packages-outside-business-scope.md)）。
- `client` 与 `server` 互不加载，`common` 不依赖任一端专属模块。
- `common.Util` 含引擎等待、通知和 `REUtil` 依赖，不是纯 foundation；它与 `REUtil` 同处 L3。
- `common.GameCfg` 含配置解析与玩法计算，归 L4；纯配置内容归 L5 的 `common.cfg`。
- `server.AbilityAPI` 与本图技能行为同属 L2。行为需要的 `Vitals`、`FishCarrier`、`GM`、`Modifier` 由 `server/main.lua` 通过 `AbilityAPI.BehaviorServices` 注入，行为不得反向加载宿主组合根。
- `server.SwingRegistry` 独立持有带 TTL、一次性消费的挥砍登记，`server.World.PlayerWeapon` 与 `melee_hit` 共同依赖它。时钟异常时拒绝登记与消费；失效读取、施法失败及玩家退出时清除登记，施法失败回复失败。
- 武器持续效果由 `server/World/ModifierLeaf.lua`（经 `PlayerTree`/`PlayerEffects` 与 `entity_modifiers`）实现，近战行为与枪击不经过 `FishAbility` 转发。
- Spoke 原生重构单向棘轮（[ADR-0032](adr/0032-spoke-native-lifecycle-architecture.md)）：`common.SpokeClock` 归 L4、`client.Store` 归 L3、`server.World` 与 `client.Views` 归 L2；新 Spoke 命名空间严禁反向 `require` `server.AbilityAPI` / `server.AbilityBehaviors` 等上层模块。`OwnedUnits`、`MgrMap`、旧客户端双轨 UI 已在 #316 删除；`OwnedUnits` 调用、旧式裸 `:Connect(`、`MgrMap` 成员三类水位均为 0，禁止恢复。

## 可执行门禁

`tests/native/guards/arch_policy_test.lua`（guards 车道）随 fast 与 full 车道运行，检查：

1. 未分类模块；
2. 向内层到外层、包到业务、跨运行端的依赖；
3. 模块循环依赖，以及模块无环但命名空间投影成环的情况；
4. 注释或字符串中的伪 `require` 和 `server/_trigger` 的误纳入；
5. `policy.edn` 的 `:levels` 与 `M.policy.levels` 不一致，或三端包不再最底。

官方包内部的既有循环依赖按包前缀豁免，因为包以官方整包升级为准。任何包含包外业务模块的循环都不豁免。门禁只分析静态 `require`；入口注入、`_G` 与 RemoteEvent 协作不伪装成静态依赖，仍由对应行为测试和入口接线测试约束。

定向检查与完整收尾：

```sh
lua tools/cli.lua test guards -- tests/native/guards/arch_policy_test.lua
lua tools/cli.lua test full
```

修改分层声明后，用下列命令取得应写入 `policy.edn` 的唯一投影；同步测试会阻止两处漂移。删除模块时一并删掉它的声明，否则残留检查失败：

```sh
lua -e 'local a = require("tools.arch_policy"); io.write(a.levels_edn(a.policy)); os.exit(0)'
```

写回 `policy.edn` 后，用 dsh-uml-viewer 插件工具 `uml_ir` 重新生成 `docs/uml/se-fish.edn`。

决策理由见 [ADR-0012](adr/0012-six-layer-architecture.md)，包职责见 [官方包接入参考](packages-reference.md)。
