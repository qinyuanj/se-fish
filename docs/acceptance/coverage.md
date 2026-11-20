# 实现覆盖表

> 本文件把每条条款接到它的**代码落点**、**关联测试**、**四类证据**与**证据等级**，是《渔力全开》「玩法实现」的台账。
> 口径见 [ADR-0029](../adr/0029-scope-completeness-and-placeholder-first.md) 第五节；静态校验在 `tools/acceptance.lua`，随 `lua tools/cli.lua acceptance --check` 与 fast 车道运行，空落点即判红。
> **Coverage / 实现覆盖表**：_Avoid_: 覆盖率表、实现清单、coverage report

## 一、字段

| 列 | 允许值 | 写法 |
| --- | --- | --- |
| 条款 | 验收矩阵里存在的条款 ID | 如 `1-12` |
| 代码落点 | 至少一个仓库相对路径，用顿号分隔；每个都必须是真实存在的文件 | `server/Mgr/MgrPlatform.lua` |
| 关联测试 | 仓库相对路径（顿号分隔）或 `—`；写了路径就必须真实存在 | `tests/native/platform_seam_test.lua` |
| 正常流程 / 失败流程 / 退出重进 / 存档恢复 | 只有 `有` 与 `缺` 两个取值（四类证据见 [ADR-0028](../adr/0028-solo-clear-on-shared-world.md)） | `缺` |
| 等级 | `A`、`B`、`C`，必须与矩阵里那条的证据等级一致 | `A` |

**关联测试是实现自检，不是条款证据。** 它只说「这段代码有测试守着」，不代表条款成立：
条款转 `evidenced` 仍然只认矩阵证据列里那条走业务入口的断言（见[证据分级](evidence-levels.md)）。
四类证据列记的是「这一栏有没有真的取到证」，与矩阵的证据列分工不重复：矩阵记那条证据本身，这里记四栏覆盖到哪。

## 二、已贯通小节

已贯通 = 本节条款全部登记、代码落点全部真实存在、门禁全绿。逐节扩大（`M.COVERAGE_SECTIONS` 里加一节就要补齐该节落点）。

### 第 1 节 概述与范围（19 条）

| 条款 | 代码落点 | 关联测试 | 正常流程 | 失败流程 | 退出重进 | 存档恢复 | 等级 |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 1-01 | AGENTS.md、docs/GameSpec.md | — | 缺 | 缺 | 缺 | 缺 | A |
| 1-02 | server/main.lua、server/Mgr/MgrPlayer.lua | tests/native/player_leave_rejoin_test.lua | 缺 | 缺 | 缺 | 缺 | A |
| 1-03 | server/main.lua、server/Mgr/MgrPlayer.lua、server/Mgr/MgrSave.lua | tests/native/player_leave_rejoin_test.lua、tests/native/fixture_lifecycle_test.lua | 缺 | 缺 | 缺 | 缺 | B |
| 1-04 | server/main.lua、server/Mgr/MgrPlayer.lua | tests/native/fixture_lifecycle_test.lua | 缺 | 缺 | 缺 | 缺 | B |
| 1-05 | common/GameCfg.lua、common/cfg/Shop.lua、common/cfg/Fish.lua | tests/native/shop_test.lua | 缺 | 缺 | 缺 | 缺 | A |
| 1-06 | server/Mgr/MgrShop.lua、server/Mgr/MgrFishUnit.lua、common/cfg/Shop.lua | tests/native/shop_test.lua、tests/native/fish_loot_test.lua | 缺 | 缺 | 缺 | 缺 | A |
| 1-07 | server/Data/PlayerData.lua、server/Mgr/MgrPlayerData.lua | tests/native/save_test.lua | 缺 | 缺 | 缺 | 缺 | A |
| 1-08 | server/Mgr/MgrFishUnit.lua、server/Mgr/MgrLoot.lua、server/Mgr/MgrFerry.lua | tests/native/fish_lift_test.lua、tests/native/ferry_test.lua | 缺 | 缺 | 缺 | 缺 | B |
| 1-09 | server/Mgr/MgrSave.lua、common/RateLimit.lua | tests/native/rate_limit_test.lua、tests/native/economy_persistence_test.lua | 缺 | 缺 | 缺 | 缺 | B |
| 1-10 | server/Mgr/MgrWeapon.lua、server/Mgr/MgrSurvival.lua | tests/native/weapon_system_test.lua、tests/native/revive_callback_test.lua | 缺 | 缺 | 缺 | 缺 | A |
| 1-11 | server/Mgr/MgrPlatform.lua、client/ScreenHandlers/ScreenPlatform.lua | tests/native/platform_seam_test.lua、tests/native/platform_screens_test.lua | 缺 | 缺 | 缺 | 缺 | A |
| 1-12 | server/Mgr/MgrPlatform.lua、server/Mgr/MgrSave.lua | tests/native/spec/01_platform_adapter_failure_test.lua | 缺 | 有 | 缺 | 缺 | A |
| 1-13 | server/Mgr/MgrPlatform.lua | tests/native/platform_seam_test.lua | 缺 | 缺 | 缺 | 缺 | A |
| 1-14 | common/cfg/PlaceholderAssets.lua | tests/native/placeholder_assets_test.lua | 缺 | 缺 | 缺 | 缺 | A |
| 1-15 | common/cfg/PlaceholderAssets.lua、server/FishBehaviors.lua | tests/native/placeholder_assets_test.lua、tests/native/fish_lift_test.lua | 缺 | 缺 | 缺 | 缺 | C |
| 1-16 | common/cfg/Shop.lua、common/GameCfg.lua | tests/native/shop_test.lua、tests/native/quest_test.lua | 缺 | 缺 | 缺 | 缺 | C |
| 1-17 | server/FishBehaviors.lua、server/Mgr/MgrFishUnit.lua | tests/native/fish_carrier_test.lua、tests/native/fish_air_escape_test.lua | 缺 | 缺 | 缺 | 缺 | C |
| 1-18 | common/ZoneMarkers.lua、server/Mgr/MgrInteract.lua | tests/native/zone_layout_plan_test.lua | 缺 | 缺 | 缺 | 缺 | C |
| 1-19 | common/ZoneMarkers.lua、common/BodyScale.lua | tests/native/zone_scene_125_test.lua | 缺 | 缺 | 缺 | 缺 | C |

第 1 节里 1-12 是第一条走完「条款 → 代码落点 → A 级断言 → 矩阵状态 → 门禁」整条纵路的样本：
代码落点是 `server/Mgr/MgrPlatform.lua`，断言是 `tests/native/spec/01_platform_adapter_failure_test.lua`，
矩阵里那条已转 `evidenced`，四类证据只勾了「失败流程」——其余三类仍是 `缺`，不预先填。

### 第 18 节 存档与恢复契约（32 条）

| 条款 | 代码落点 | 关联测试 | 正常流程 | 失败流程 | 退出重进 | 存档恢复 | 等级 |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 18-01 | server/Data/PlayerData.lua、server/Mgr/MgrSave.lua | tests/native/spec/18_session_settlement_contract_test.lua、tests/native/save_test.lua | 有 | 有 | 有 | 有 | B |
| 18-02 | server/Data/PlayerData.lua、server/Mgr/MgrSave.lua | tests/native/save_test.lua、tests/native/grill_test.lua | 有 | 缺 | 缺 | 有 | B |
| 18-03 | server/Data/PlayerData.lua、server/Mgr/MgrWeapon.lua | — | 缺 | 缺 | 缺 | 缺 | B |
| 18-04 | server/Data/PlayerData.lua、server/Mgr/MgrShop.lua | tests/native/economy_persistence_test.lua | 有 | 缺 | 缺 | 有 | B |
| 18-05 | server/Data/PlayerData.lua、server/Mgr/MgrSurvival.lua | tests/native/spec/18_session_settlement_contract_test.lua、tests/native/survival_test.lua | 有 | 缺 | 有 | 有 | B |
| 18-06 | server/Mgr/MgrSurvival.lua、server/Data/PlayerData.lua | tests/native/survival_test.lua | 缺 | 缺 | 有 | 有 | B |
| 18-07 | server/Mgr/MgrCompendium.lua、server/Data/PlayerData.lua | tests/native/compendium_test.lua、tests/native/records_test.lua | 有 | 缺 | 有 | 有 | B |
| 18-08 | server/Mgr/MgrQuest.lua、server/Mgr/MgrStory.lua | tests/native/player_leave_rejoin_test.lua | 有 | 缺 | 有 | 有 | B |
| 18-09 | server/Mgr/MgrFerry.lua、server/Data/PlayerData.lua | tests/native/ferry_test.lua | 有 | 缺 | 有 | 有 | B |
| 18-10 | server/Data/PlayerData.lua、server/Mgr/MgrSave.lua | tests/native/spec/18_session_settlement_contract_test.lua | 有 | 有 | 有 | 有 | B |
| 18-11 | server/Mgr/MgrBlindbox.lua、server/Data/PlayerData.lua | tests/native/blindbox_settle_test.lua | 有 | 缺 | 缺 | 有 | B |
| 18-12 | server/Mgr/MgrAchievements.lua、server/Data/PlayerData.lua | tests/native/achievement_delivery_test.lua、tests/native/compendium_test.lua | 有 | 缺 | 有 | 有 | B |
| 18-13 | server/Mgr/MgrSave.lua、server/Mgr/MgrFerry.lua | tests/native/spec/18_session_settlement_contract_test.lua、tests/native/ferry_test.lua | 有 | 有 | 有 | 有 | B |
| 18-14 | server/Mgr/MgrWeapon.lua、server/Data/PlayerData.lua | — | 缺 | 缺 | 缺 | 缺 | B |
| 18-15 | server/Mgr/MgrWeapon.lua、server/Mgr/MgrSave.lua | tests/native/weapon_system_test.lua | 有 | 有 | 缺 | 缺 | B |
| 18-16 | server/Data/PlayerData.lua | tests/native/spec/18_session_settlement_contract_test.lua | 有 | 缺 | 缺 | 有 | B |
| 18-17 | server/Data/PlayerData.lua | tests/native/spec/18_session_settlement_contract_test.lua | 有 | 缺 | 缺 | 有 | B |
| 18-18 | server/Data/PlayerData.lua、server/Mgr/MgrSave.lua | tests/native/spec/18_session_settlement_contract_test.lua | 有 | 有 | 缺 | 有 | B |
| 18-19 | server/main.lua、server/Mgr/MgrSave.lua | tests/native/spec/18_session_settlement_contract_test.lua | 有 | 有 | 缺 | 缺 | B |
| 18-20 | server/Mgr/MgrSave.lua、server/main.lua | tests/native/spec/18_session_settlement_contract_test.lua | 有 | 有 | 有 | 有 | B |
| 18-21 | server/Mgr/MgrSave.lua | tests/native/spec/18_session_settlement_contract_test.lua | 有 | 有 | 缺 | 有 | B |
| 18-22 | server/Mgr/MgrSave.lua | tests/native/spec/18_session_settlement_contract_test.lua | 有 | 有 | 缺 | 有 | B |
| 18-23 | server/Mgr/MgrSave.lua、server/Mgr/MgrShop.lua | tests/native/spec/18_session_settlement_contract_test.lua、tests/native/economy_persistence_test.lua | 有 | 有 | 有 | 有 | B |
| 18-24 | server/Mgr/MgrSave.lua、server/Mgr/MgrFerry.lua | tests/native/spec/18_session_settlement_contract_test.lua | 有 | 有 | 有 | 有 | B |
| 18-25 | server/Mgr/MgrFerry.lua、server/Mgr/MgrSave.lua | tests/native/spec/18_session_settlement_contract_test.lua、tests/native/ferry_test.lua | 有 | 有 | 有 | 有 | B |
| 18-26 | server/Mgr/MgrPlatform.lua | — | 缺 | 缺 | 缺 | 缺 | B |
| 18-27 | server/Data/PlayerData.lua、server/Mgr/MgrLoot.lua | tests/native/spec/18_session_settlement_contract_test.lua | 有 | 缺 | 缺 | 有 | B |
| 18-28 | server/Mgr/MgrLottery.lua、server/Mgr/MgrSave.lua | tests/native/lottery_settle_test.lua | 有 | 缺 | 有 | 有 | B |
| 18-29 | server/Mgr/MgrInteract.lua、server/Mgr/MgrSave.lua | tests/native/economy_persistence_test.lua | 有 | 缺 | 有 | 有 | B |
| 18-30 | server/Mgr/MgrGrill.lua、server/main.lua | tests/native/grill_test.lua | 有 | 缺 | 有 | 有 | B |
| 18-31 | server/Mgr/MgrSave.lua、server/Data/PlayerData.lua | tests/native/spec/18_session_settlement_contract_test.lua | 有 | 有 | 有 | 有 | B |
| 18-32 | server/main.lua、server/Mgr/MgrPlayerData.lua | tests/native/player_leave_rejoin_test.lua | 缺 | 缺 | 有 | 有 | B |
## 三、待登记小节

第 2～17、19 节尚未登记。按依赖顺序逐节扩大，每节登记时同时补齐该节的代码落点与既有测试，
并把该节加进 `tools/acceptance.lua` 的 `M.COVERAGE_SECTIONS`。
