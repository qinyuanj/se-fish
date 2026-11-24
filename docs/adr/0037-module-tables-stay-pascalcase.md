# 0037 模块表与类型名保持 PascalCase（L2 回退）

**Status**: accepted（2026-11-24；取代 [ADR-0034](0034-self-written-code-snake-case.md) 的 L2 行）

## 背景

[ADR-0034](0034-self-written-code-snake-case.md) 把命名统一到 snake_case，分三层迁移：L1 文件与 `require` 命名空间、L2 模块表变量、L3 方法与自研字段。L1 与 L2 已按此合入（PR #327、#328）。

L2 合入后复查上游 `spoke` 包，发现它的口径不是「全 snake_case」，而是**类型与成员分开**：

```lua
common/packages/spoke/runtime/ordering.lua:1        local Ordering = {}            -- 文件 snake，模块表 Pascal
common/packages/spoke/runtime/spoke_runtime.lua:9   local SpokeRuntime = {         -- 同上
common/packages/spoke/runtime/epoch.lua             function Epoch:compare_to()    -- 方法 snake
                                                    function Epoch:_tick()
```

三件事同时成立：**文件名 snake_case**、**模块表（类型）PascalCase**（连 `Ordering`、`Heap` 这种纯工具模块也是 Pascal）、**方法与字段 snake_case**。ADR-0034 在背景里引 spoke 证明的是「文件名该 snake」——这一条成立；但把模块表变量也压成 snake 是过度推断，与上游相反。

## 决定

| 层 | 口径 | 依据 |
| --- | --- | --- |
| L1 文件、目录、`require` 命名空间 | snake_case | 手册示例与 spoke 整包文件名；ADR-0034 保留 |
| L2 模块表 / 类型名 | **PascalCase**，取文件名的驼峰形 | `spoke_runtime.lua` → `local SpokeRuntime` |
| L3 方法、自研字段、局部、参数 | snake_case | `Epoch:compare_to`、`Epoch:_tick` |

读代码时能一眼分出**类型**与**值**：`local DamageFloat = require("client.views.damage_float")` 与 `local fish_count = 0` 不同形。ADR-0034 里当特例豁免的 `local State = spoke.State`、`local World = game:GetService("World")` 也不再是特例。

## 后果

- L2 的改名（提交 `1a12310`，384 文件 / 1159 处绑定）整支回退；L1 不动。
- 回退用 `git revert` 完成，而不是反向脚本：旧名里有 `REUtil`、`UIManager`、`UIConsts` 这类连续大写，snake→Pascal 机械反推会推错成 `ReUtil`。
- 新增守卫：`local X = require(...)` 的 `X` 必须是 Pascal 形，否则口径会漂回 snake（原 L2 的门禁只有文件名）。
- 正反例随之更新：`DamageFloat:Show` → `DamageFloat:show`（自研：类型留 Pascal、方法改 snake）；引擎键与官方名清单见 [ADR-0034 附录](0034-self-written-code-snake-case.md)。
- **`*/packages/` 整包一律不参与命名迁移**（三个端各一个）：上游整包与本仓维护的自研包同等处理，包内文件、模块表、方法名都保持原样，跟随各自上游口径。命名门禁本来就跳过这些目录，这条把口径写死，避免「自研包要不要跟进」反复讨论。
- **实现官方/包内接口的方法名跟随接口**：自研模块若实现包内声明的接口方法（如 ability 锚点接口的 `M.Attach`），该方法名保持接口原样；语义不同的自研同名方法照常改 snake，两者同名不冲突。L3b 落地时 `Attach` 就按这条处理：包内接口一侧 7 处保持，自研 `CarryMount.attach`/`FishAi:attach` 改 snake。
- **字段名与引号里的运行期字符串绑定的，保持原样**（L4a 确认 25 个）：11 个冻结计时动态键（`ActiveUntil/SpecialAt/JabAt/PinchAt/ChargeAt/JumpAt/RoarAt/TailAt/ClawAt/NextReefDiveAt/NextThrowAt`，`fish_tree.lua` 用 `for key in ipairs({'…'}) do fish[key]`）、7 个 `layout.Regions[region]` 区域名、6 个 `nodes[node.Name]`/`Rects[kind.."Bar"]` 节点名、包内 `Enums.CreateResult`。改字段不改字符串就是静默 nil，收益不抵风险。
- **74 个「定义待核」名字的判定**（`tmp/l4d_pending_fields.md`）：应改 7 个（`Root/Msg/CallBack/Ref/LastReason/CombatRE/BindCombatChannel`，已改）；豁免 44 个（包内 34 / 官方 5 / 配置 5）；23 个不是字段。`Ok`/`Reason` 两套结果约定的统一属 API 设计，另行处理，不在命名迁移范围内。

## 拒绝的备选

- **全部 snake_case（维持 ADR-0034 原口径）**：与上游 spoke 相反，同一次 `require` 里 `State` 与 `game_cfg` 两种风格并存，且要为一堆官方类型名反复解释豁免。
- **文件也改回 PascalCase**：ADR-0034 已证伪（手册示例、spoke 整包、与内置服务名同形撞名），不回退。
