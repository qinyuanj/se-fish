# 0030 鱼本体与受击体分离的双单位载体

**Status**: accepted

鱼同时需要原生抓举和技能伤害，但 SE 引擎把这两项能力放在不同单位类型上：`WorldUnit` 支持 `Liftable`，没有可用 `Controller`；脚本可创建的 `EggyUnit(EnableController=true)` 提供 `Controller.Health/TakeDamage`，却不满足鱼本体的抓举要求。给 `WorldUnit` 补 `Controller`、修改单位元表或只保留一种单位都不能形成完整玩法路径。实测依据为 #25 台账 §1 的引擎内成员探测与 M18 复证。

## 决定

- 一条鱼由一个 `WorldUnit` 鱼本体和一个 `EggyUnit` 受击体组成，统一由 `server/world_host/fish_carrier.lua` 创建、登记和解析。
- 鱼本体负责模型、抓举、逃脱和业务轨迹；受击体负责技能命中、血量与死亡信号。业务不得再把 `Body`、`Receiver` 或 `Controller` 当作可互换目标。
- 每个时刻只有一个位移写入口：业务轨迹拥有本体位置时，由 `MgrFishCarrier` 同步受击体；官方 AI 拥有受击体位置时，由 `MgrAi.Sync` 镜像回本体。切换模式先停止旧指令，再交换写入权。
- `HealthChanged` 与 `Died` 都进入同一死亡收口。通知订阅者前先读取控制器真实血量，`carrier.Dead` 保证一次死亡只发布一次。
- 本体与受击体保持碰撞隔离，避免同位动态单位互推。创建受击体失败时整条鱼载体创建失败，不交付只能看、不能受伤的鱼。

## 备选方案（拒绝）

1. **只用 `WorldUnit`**：没有可用 `Controller`，技能包命中后不能可靠扣血。
2. **只用 `EggyUnit` / `HumanUnit`**：不满足原生抓举鱼本体的能力组合。
3. **运行时给单位注入方法或元表**：引擎内部单位不是普通 Lua table，该路径不受支持。
4. **让两个位移系统同时写两个单位**：会产生双向覆盖和帧序依赖；写入权必须显式切换。

## 后果

- 伤害、抓举、AI 和鱼获逻辑都经 `MgrFishCarrier` 解释目标身份，不各自猜测单位类型。
- 双单位带来同步与死亡去重成本，这是引擎能力边界强制的结果，不再靠模块头注释重复解释。
- `Despawn` 已负责断信号、摘登记和销毁本体；受击体回收须遵守 [ADR-0032](0032-spoke-native-lifecycle-architecture.md) 的显式所有权原则，在创建作用域 `on_cleanup` 中销毁，不依赖父子销毁级联。
