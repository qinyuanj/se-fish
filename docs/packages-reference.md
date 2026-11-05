# 官方包接入参考

三端 `packages/` 保存网易官方作者版包；包内模块路径依赖 `server/`、`client/`、`common/` 同名子树布局。

## 镜像与升级

- `deploy` 以仓库为源，三端 `packages/` 与业务一级子树一起字节镜像；宿主多余文件会删除。`deploy --clean` 也删除对应包子树。
- `sync --packages` 以宿主为源，按原始字节回灌三端包并删除仓库多余文件，根 `README.md` 同样参与镜像。任一端来源缺失或为空时，整次同步在写入前失败；普通 `sync` 不回灌包。
- 回灌前先确认工作区已提交。部署前确认需要保留的宿主包修改已回灌，避免被仓库覆盖。
- 部署收尾执行 validate → 有差异时 push → diff 复核。push 后复核失败、离线、无 changelist 或仍有差异均返回失败；三端内本地已删的地图文件随 `--delete --yes` 删除，三端外的地图独有文件只提示保留，两类混杂时不推送。
- 包内没有版本号、变更记录或来源 URL，升级以整包导入为准，替换后 diff 三端子树确认改动面。
- 业务层直接 require 对应端的包内 `api.lua`；不在上一层复制导出名单、拍平 `Funcs` 或逐函数转发。属性和 AI 包使用原生 `Funcs` 函数表，`Enums` / `Configs` / `Prefabs` 保持包内结构。升级后通过真实包回归核对调用契约（属性：`attr_migration_test.lua`、`attr_rule_probe_test.lua`；效果：`modifier_system_probe_test.lua`；AI 与技能桥：`ai_migration_test.lua`、`official_ai_probe_test.lua`）。
- `server/AbilityAPI.lua` 仅保留本图业务：施法守卫、体型、挂点与锚点补挂。需要守卫的业务施法继续调用它；装配、停止和查询技能直接调用包。锚点行为所需的管理器由 `server/main.lua` 通过 `BehaviorServices` 注入，行为不反向加载 `server.Mgr`。AI 位移生命周期查询由 `MgrAi` 持有，不另建 AI 转发入口。挥砍登记由 `server/SwingRegistry.lua` 独立持有，武器入口与近战行为共同依赖它。

## 导入不可逆

本图的 `ability_system`、`attr_rule`、`modifier_system`、`official_ai_feature` 都是**导入**（见 `GLOSSARY.md`），资源包面板显示「已导入」。官方手册写明导入后不能取消；2026-11-03 实测确认没有本地退路：

- 从宿主删掉三端 `packages/`，再存盘、reopen，面板仍是「已导入」。删代码不会让包退回引用，只会让地图缺代码；业务代码还 require 包内模块，此时试玩必然报错。
- 本地存档缓存 `etc/help_build_gmps/<地图>__pc/` 里有两份登记：`packageinfo.mm` 的 `__official_refs__` 与 `mapcustomize.mm` 的 `se_official_package_refs`，都写着 `mode=imported`。把两份都改成 `off` 后从本地目录启动，编辑器确实读了改过的文件，面板仍是「已导入」。所以状态另有来源（加密的 `.gmp` 或服务端），本地改不到。
- 编辑时 Lua API 只有 `is_official_asset_id` 这类只读判断，没有切换引用或导入的入口。

因此：不要从宿主删除导入过的包；包的升级与删除都走仓库加 `deploy`。真要改回引用，只能请官方在服务端重置该地图的导入状态，并且要先确认引用模式下业务代码 require 的包内模块仍然可用。

## 引擎 bootstrap 钩子

2026-11-05 实测发现：引擎在 `unit_scripts/World/__OfficialPackageBootstrap__.lua` 生成启动脚本，新建空图里也有。据生成文件，它对列表里的 `server.packages.<包名>.bootstrap` 做 `pcall(require)`，再按函数名排序依次调用表里的函数。本图的列表只有 `modifier_system`（`sdk_extend` 已于 2026-10-09 删除）；空图的列表是 `modifier_system`、`sdk_extend`。引擎从哪个版本开始生成这份脚本未查证，宿主日志里这条报错 2026-11-05 才首次出现。

本图导入的 `modifier_system`（2026-10-08，#153）里没有 `bootstrap.lua`；缺这个文件时，每次试玩服务端都会报 `module not found`。仓库因此补了一个返回空表的 `server/packages/modifier_system/bootstrap.lua`（#176），没有函数可调，行为与缺文件时相同。`tests/native/official_package_bootstrap_test.lua` 保证它可加载且不含启动函数。

官方新版（2026-11-05 在空图导入后读到）带 `bootstrap.lua`，导出 4 个启动函数：为全部蛋仔预建「即将获得效果」事件单位、为编辑器预放置的效果预建事件信号、为仍生效的预放置效果补发一次「获得」事件、监听新出现的蛋仔补建事件单位。这些服务于 ECA 绑定和预放置效果；本图业务只经 `api` 调用效果系统，不用 ECA，也没有预放置效果，旧包又会在触发时按需建事件单位，所以空钩子不缺功能。新版 bootstrap 属于整包升级的一部分（三端多个文件改动，另有 `eca.lua` 与客户端 `ui/`），不单独拷入旧包。

- 整包升级后以官方 `bootstrap.lua` 为准，跑上文的真实包回归测试，并按新文件改写该测试。
- 回灌来源的包仍没有它时，`sync --packages` 会把这个空钩子当作多余文件删掉。回灌后要恢复它，再提交。

## 包清单

| 包 | 用途 | 导入时间 | 真实包接口 |
|---|---|---|---|
| `ability_system` | 技能系统 | 2026-09-19（commit `9382ad8`） | `server.packages.ability_system.api`、`client.packages.ability_system.api`，函数平铺 |
| `attr_rule` | 属性规则 | 2026-10-08（#153） | `server.packages.attr_rule.api`、`client.packages.attr_rule.api`，函数在 `Funcs`，另有 `Enums` / `Prefabs` |
| `modifier_system` | 效果（Buff）系统 | 2026-10-08（#153） | `server.packages.modifier_system.api`、`client.packages.modifier_system.api`，函数平铺 |
| `official_ai_feature` | 生物 AI | 2026-10-08（#153） | `server.packages.official_ai_feature.api`，函数在 `Funcs`，另有 `Configs`；client 侧无 api.lua |

`win_rule` 于 2026-10-09 从宿主删除并经回灌移除，删除前未接入业务聚合入口或正式结算。原包有结算枚举遮蔽（[GitHub #58](https://github.com/qinyuanj/se-fish/issues/58)）及未结算玩家离开后缺少全员结算重判（[GitHub #59](https://github.com/qinyuanj/se-fish/issues/59)）的问题。删除不代表缺陷已修复，重新引入须取得官方修正版并验证结算与玩家离开时序。

## 架构图上的位置

三端 `packages/` 属于业务范围：在图上按真实命名空间（如 `server.packages.<包名>.*`）建类，与其他业务模块一样连依赖、上指标；`policy.edn` 不为包写 `:foreign` 或排除项，新增包无需改 policy。包内类不跑 mutation 基线，缺快照显红属已接受的代价。决策与后果见 [ADR-0010](adr/0010-packages-as-business-code.md)（取代 ADR-0005）。

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

预设丢失时按上表类型在编辑器重建；技能包可用 `lua5.4 tools/cli.lua ability-presets`，规格见 `tools/ability_presets.lua`。
