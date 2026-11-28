# 官方包接入参考

三端 `packages/` 保存整包交付的库：官方包随官方整包更新，自研包由本仓维护；包内模块路径依赖 `server/`、`client/`、`common/` 同名子树布局。

## 术语辨析

- **Ability / 技能**：玩家武器攻击或鱼攻击行为背后的施法单元，仅用于系统层描述；玩家文案使用对应攻击名称。
  _Avoid_: 招式、spell（指技能时）
- **Ability manager / 技能管理器**：管理技能的容器，官方预设名「技能背包」；不是物品「背包」。
  _Avoid_: 背包（省略「技能」时）、skill bar
- **Ability anchor / 技能锚点**：技能时间轴上的动作单元；与 **Anchor name / 锚点名**同名不同义。
  _Avoid_: 锚点（单说时与场景锚点名混淆）
- **Anchor name / 锚点名**：场景实体在编辑器里的位置节点名，属区域标记的落地形式，代码中为 `AnchorName`，如 `Interact.Fishermen[i].AnchorNames`；与 **Ability anchor / 技能锚点**同名不同义。
- **Reference / 引用**：挂接官方托管、随官方更新且可取消的包。
  _Avoid_: 开启、安装（指引用时）、link
- **Import / 导入**：一次性拷入地图、由本图维护的包，不能撤销回引用。
  _Avoid_: vendor、de-init、取消导入（指编辑器状态时）、copy-in
- **Official package / 官方包**：定义见下文[镜像与升级](#镜像与升级)。
  _Avoid_: 官方库、官方资源包、third-party package
- **In-house package / 自研包**：定义见下文[自研包](#自研包)。
  _Avoid_: 自研库、第三方库、内置库、vendor 包、内部包

## 镜像与升级

- `deploy` 以仓库为源，三端 `packages/` 与业务一级子树一起字节镜像；宿主多余文件会删除。`deploy --clean` 也删除对应包子树。
- 三端包由仓库管理，`sync` 不回灌。宿主侧对包的修改会被下次 `deploy` 覆盖，需要保留的修改改进仓库。
- 部署收尾执行 validate → 有差异时 push → diff 复核。push 后复核失败、离线、无 changelist 或仍有差异均返回失败；三端内本地已删的地图文件随 `--delete --yes` 删除，三端外的地图独有文件只提示保留，两类混杂时不推送。
- 包内没有版本号、变更记录或来源 URL，升级以整包导入为准，替换后 diff 三端子树确认改动面。
- 升级来源用官方资源包空图（新建空图导入四个包后的宿主目录）：三端 `packages/<包>/` 按原始字节整包覆盖并删除旧包多余文件。2026-11-05 的全量升级与逐包差异摘要见 [GitHub #177](https://github.com/qinyuanj/se-fish/issues/177)。
- 业务层直接 require 对应端的包内 `api.lua`；不在上一层复制导出名单、拍平 `Funcs` 或逐函数转发。属性和 AI 包使用原生 `Funcs` 函数表，`Enums` / `Configs` / `Prefabs` 保持包内结构。升级后通过真实包回归核对调用契约（属性：`attr_migration_test.lua`、`attr_rule_probe_test.lua`；效果：`modifier_system_probe_test.lua`；AI 与技能桥：`ai_migration_test.lua`、`official_ai_probe_test.lua`）。
- `server/ability_api.lua` 仅保留本图业务：施法守卫、体型、挂点与锚点补挂。需要守卫的业务施法继续调用它；装配、停止和查询技能直接调用包。锚点行为所需的管理器由 `server/main.lua` 通过 `BehaviorServices` 注入，行为不反向加载宿主组合根。AI 位移生命周期查询由 `server/world_host/fish_ai.lua`（`FishAi`）持有，不另建 AI 转发入口。挥砍登记由 `server/swing_registry.lua` 独立持有，武器入口与近战行为共同依赖它。

## 新版包的默认行为（2026-11-05 版）

以下行为随 #177 升级进来，业务依赖它们时以此为准：

- **效果清除规则**：效果预设壳新增「清除规则」`RemoveMode`，默认 `1`（击败后清除），拥有者触发引擎死亡信号时移除效果。本图生死由 `server/world_host/player_life.lua`（`PlayerLife`）管理，`server/world_host/modifier_leaf.lua`（`ModifierLeaf`）获得效果时显式传 `removeMode = 0`，保持旧包「死亡不清效果」的行为。
- **效果阻断与打断**：预设的 `ForbidTags` 命中已有效果时获得结果为 `Blocked`，`RemoveTags` 会移除带对应标签的已有效果；本图预设未配置这两项。`ModifierLeaf` 把 `Added` / `Reobtained` 以外的结果都当失败处理。
- **效果状态栏 UI**：客户端效果管理器启动后自动拉起 `ui/EffectStatusBarUI`，按 `UIType=EffectStatusBar` 或节点名「效果状态栏」找界面节点。本图没有这个节点，界面不显示；循环每 0.5 秒重查一次，约 30 秒后打一条「未找到可用的效果状态栏」提示，属预期。
- **技能覆盖装配**：`add_ability` 指定的槽位被另一预设占用时，旧包返回失败，新包先移除旧技能再装配。本图初始技能与鱼技能各占一个槽位，不触发覆盖。
- **客户端施法竞态守卫**：包内 `cast_ability` 新增末参数 `fromClient`，只有包自带的客户端施法请求传 `true`；`server/ability_api.lua` 的守卫转发不传，行为与旧包一致。
- ECA（两个包的 `eca.lua`）、技能 `event_bridge.lua` 与 `common/.../enums.lua` 随包进来，本图未接入；锚点 `caster_add_buff` 按惯例在 `AnchorBehaviorLoaders` 登记，未配置使用。

## 导入不可逆

本图的 `ability_system`、`attr_rule`、`modifier_system`、`official_ai_feature` 都是**导入**（见上文[术语辨析](#术语辨析)），资源包面板显示「已导入」。官方手册写明导入后不能取消；2026-11-03 实测确认没有本地退路：

- 从宿主删掉三端 `packages/`，再存盘、reopen，面板仍是「已导入」。删代码不会让包退回引用，只会让地图缺代码；业务代码还 require 包内模块，此时试玩必然报错。
- 本地存档缓存 `etc/help_build_gmps/<地图>__pc/` 里有两份登记：`packageinfo.mm` 的 `__official_refs__` 与 `mapcustomize.mm` 的 `se_official_package_refs`，都写着 `mode=imported`。把两份都改成 `off` 后从本地目录启动，编辑器确实读了改过的文件，面板仍是「已导入」。所以状态另有来源（加密的 `.gmp` 或服务端），本地改不到。
- 编辑时 Lua API 只有 `is_official_asset_id` 这类只读判断，没有切换引用或导入的入口。

因此：不要从宿主删除导入过的包；包的升级与删除都走仓库加 `deploy`。真要改回引用，只能请官方在服务端重置该地图的导入状态，并且要先确认引用模式下业务代码 require 的包内模块仍然可用。

## 引擎 bootstrap 钩子

2026-11-05 实测发现：引擎在 `unit_scripts/World/__OfficialPackageBootstrap__.lua` 生成启动脚本，新建空图里也有。据生成文件，它对列表里的 `server.packages.<包名>.bootstrap` 做 `pcall(require)`，再按函数名排序依次调用表里的函数。本图的列表只有 `modifier_system`（`sdk_extend` 已于 2026-10-09 删除）；空图的列表是 `modifier_system`、`sdk_extend`。`ability_system` 没有 bootstrap。

旧包（2026-10-08，#153）缺 `bootstrap.lua`，试玩服务端报 `module not found`，#176 曾补过一个返回空表的钩子。#177 整包升级后改用官方 `bootstrap.lua`，导出 4 个启动函数：为全部蛋仔预建「即将获得效果」事件单位、为编辑器预放置的效果预建事件信号、为仍生效的预放置效果补发一次「获得」事件、监听新出现的蛋仔补建事件单位。前两个会遍历 World 全部后代，并在服务端日志打出 `[modifier_system] ensure scan: total=… eggy=…` 与 `ensure modifier events: total=… modifier=…`。本图不用 ECA，也没有预放置效果，这些函数只做预建，不改变业务调用效果系统的结果。`tests/native/official_package_bootstrap_test.lua` 保证它可加载，且导出的启动函数清单与官方一致。

## 包清单

| 包 | 用途 | 导入时间 | 真实包接口 |
|---|---|---|---|
| `ability_system` | 技能系统 | 2026-09-19（commit `9382ad8`），2026-11-05 升级（#177） | `server.packages.ability_system.api`、`client.packages.ability_system.api`，函数平铺 |
| `attr_rule` | 属性规则 | 2026-10-08（#153），2026-11-05 复核与官方一致（#177） | `server.packages.attr_rule.api`、`client.packages.attr_rule.api`，函数在 `Funcs`，另有 `Enums` / `Prefabs` |
| `modifier_system` | 效果（Buff）系统 | 2026-10-08（#153），2026-11-05 升级（#177） | `server.packages.modifier_system.api`、`client.packages.modifier_system.api`，函数平铺 |
| `official_ai_feature` | 生物 AI | 2026-10-08（#153），2026-11-05 复核与官方一致（#177） | `server.packages.official_ai_feature.api`，函数在 `Funcs`，另有 `Configs`；client 侧无 api.lua |

`win_rule` 于 2026-10-09 从宿主删除并经回灌移除，删除前未接入业务聚合入口或正式结算。原包有结算枚举遮蔽（[GitHub #58](https://github.com/qinyuanj/se-fish/issues/58)）及未结算玩家离开后缺少全员结算重判（[GitHub #59](https://github.com/qinyuanj/se-fish/issues/59)）的问题。删除不代表缺陷已修复，重新引入须取得官方修正版并验证结算与玩家离开时序。

## 自研包

`spoke` 是第一个自研包，也是第一个非官方来源的 `packages/` 条目，引入方式见 [ADR-0022](adr/0022-introduce-spoke-runtime.md)。

| 项 | 值 |
|---|---|
| 用途 | 响应式运行时与生命周期管理（Epoch / Ticker / SpokeTree / Dock / Trigger / State / Effect / Memo / Phase） |
| 落位 | `common/packages/spoke/`，门面 `require("common.packages.spoke.api")` |
| 上游 | 同级仓库 `spoke` |
| 上游 commit | `f3c6d5c2cdcc900b6ddbef3d141bba454a29619a`（2026-11-28）；纯拷贝，一次同步记一个 SHA；库与 `.dsh/skills/spoke/` 技能必须同源 |
| 升级 | 从上游检出整体重拷 `common/packages/spoke/` 与技能，再更新本表 SHA |
| 约束 | 不就地修改包内文件；不搬上游 `tests/`；不改写上游技能 |

`spoke_eggy` 是同一次同步引入的 SE 宿主层，独立成包、不嵌进核心，边界见 [ADR-0022](adr/0022-introduce-spoke-runtime.md)。

| 项 | 值 |
|---|---|
| 用途 | SE 宿主装配：树随 `Unit.Destroying` 销毁（先翻 `is_alive` 再 detach）、带树名前缀的 logger、`State<boolean> is_alive` |
| 落位 | `common/packages/spoke_eggy/`，门面 `require("common.packages.spoke_eggy.api")`；不进核心 `api.lua` 的 13 类 |
| 上游 | 同 `spoke` 仓，与核心包同一次同步 |
| 上游 commit | 与 `spoke` 相同：`f3c6d5c2cdcc900b6ddbef3d141bba454a29619a`（2026-11-28） |
| 依赖 | 只 require `common.packages.spoke.*`（门面与 `runtime.spoke_error`）；核心不反向 require |
| 升级 | 与 `spoke` 一起整体重拷，不单独记 SHA |
| 约束 | 不就地修改；不搬上游 `tests/host/spoke_eggy_spec.lua`，加载与生命周期由 `tests/probes/spoke_eggy_load.lua` 覆盖 |

2026-11-22 两次连续同步：`7605d7b` → `7f77843df400e1322d92c96728938f358a1f6c07` → `ae94f086cb3eac8b51445483d819a3d648ce1db3`。这轮包内只动 4 个 runtime 文件（Ticker 接入上游 1.3.2 loop guard），技能动 `references/runtime.md` 与 `evals/evals.json`（上游 [#34](https://github.com/qinyuanj/spoke/issues/34) / [#35](https://github.com/qinyuanj/spoke/pull/35) 修 SE 节拍口径）；`spoke_eggy/api.lua` 与其余技能文件字节未变，过程与验证见 PR #282。

2026-11-24 同步到 `7b822fe3fa0df940e5048320f1f162657e4fff28`：上游 `4e614ba`（[#44](https://github.com/qinyuanj/spoke/pull/44)）清掉包内复述式注释，并把 `Epoch:_compare_to` 内联进 `Epoch:compare_to`；`5d1af3a`（[#45](https://github.com/qinyuanj/spoke/pull/45)）只改上游 `.gitignore`，不进同步目录。核心包 33 个文件与 `spoke_eggy/api.lua` 按原始字节整包重拷，技能字节未变。

2026-11-28 同步到 `f3c6d5c2cdcc900b6ddbef3d141bba454a29619a`：纳入 LuaLS 类型标注、运行时与响应式内部封装调整，以及独立 Epoch 比较/销毁和 Dock 重入 drop 防护。核心包与 `spoke_eggy` 共 36 个文件按原始字节更新；技能 5 个文件逐字节复核未变。

## 架构图上的位置

三端 `packages/` 纳入业务范围：`uml-quality.json` 不再排除包目录，`policy.edn` 也不再把包折叠为外部节点；质量工具度量包源码，架构图直接建立包内模块与真实依赖边。`tools/arch_policy.lua` 仍要求包内每个模块可分类，包内循环照旧豁免；纳入 UML 管理不改变整包升级与不就地修改约束。决策与后果见 [ADR-0043](adr/0043-packages-inside-business-scope.md)。

## 编辑器预设依赖

包通过 `map://preset/...` AssetKey 引用地图内预设；预设随地图存档，不进 git。代码部署不能替代预设创建。

| 包 | 预设类型 | 标题 | template_id |
|---|---|---|---|
| `ability_system` | `ability` | 技能 | `map://preset/uc57b9f26db1463083f9ace34d6db0d5` |
| `ability_system` | `ability_manager` | 技能背包 | `map://preset/u014968df4aa4427aebac4388ed79bf7` |
| `ability_system` | `ability_anchor` | 锚点 | `map://preset/uccfb9dbe3f4428bb972096ba01f1f25` |
| `attr_rule` | `AttrUnit` | 属性单位 | `map://preset/u801ef1a3a924db391741602e6eee295` |
| `attr_rule` | `AttrBuffUnit` | 属性Buff单位 | `map://preset/u95e3ac002304b8483aa099a955e14a8` |
| `modifier_system` | `modifier` | 效果 | `map://preset/u1b5be6f141c4898956df10e229c33c3` |

`attr_rule` 还需编辑器导出的「全局默认属性」（`List<attr_rule.AttrConfig>`）；`official_ai_feature` 无预设引用。

预设丢失时按上表类型在编辑器重建；技能包可用 `lua tools/cli.lua ability-presets`，规格见 `tools/ability_presets.lua`。
