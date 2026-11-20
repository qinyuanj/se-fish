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

### 第 5 节 七区鱼种完整数据（18 条）

| 条款 | 代码落点 | 关联测试 | 正常流程 | 失败流程 | 退出重进 | 存档恢复 | 等级 |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 5-01 | common/cfg/Fish.lua、common/GameCfg.lua | tests/native/spec/05_zone_fish_data_test.lua、tests/native/cfg_fish_items_test.lua | 有 | 缺 | 缺 | 缺 | A |
| 5-02 | common/cfg/Fish.lua、common/ContentValidation.lua | tests/native/cfg_fish_items_test.lua、tests/native/content_validation_test.lua | 缺 | 缺 | 缺 | 缺 | A |
| 5-03 | common/cfg/Fish.lua、common/GameCfg.lua | tests/native/spec/05_zone_fish_data_test.lua、tests/native/cfg_fish_items_test.lua | 有 | 缺 | 缺 | 缺 | A |
| 5-04 | common/cfg/Fish.lua | tests/native/cfg_fish_items_test.lua | 缺 | 缺 | 缺 | 缺 | A |
| 5-05 | common/cfg/Fish.lua、common/ContentValidation.lua | tests/native/content_validation_test.lua | 缺 | 缺 | 缺 | 缺 | A |
| 5-06 | common/cfg/Fish.lua、common/ContentValidation.lua | tests/native/content_validation_test.lua | 缺 | 缺 | 缺 | 缺 | A |
| 5-07 | common/cfg/Fish.lua、common/ContentValidation.lua | tests/native/content_validation_test.lua | 缺 | 缺 | 缺 | 缺 | A |
| 5-08 | common/cfg/Fish.lua、common/ContentValidation.lua | tests/native/content_validation_test.lua | 缺 | 缺 | 缺 | 缺 | A |
| 5-09 | common/cfg/Fish.lua、common/ContentValidation.lua | tests/native/content_validation_test.lua | 缺 | 缺 | 缺 | 缺 | A |
| 5-10 | common/cfg/Fish.lua、common/GameCfg.lua | tests/native/cfg_fish_items_test.lua | 缺 | 缺 | 缺 | 缺 | A |
| 5-11 | common/cfg/Fish.lua、common/ContentValidation.lua | tests/native/content_validation_test.lua | 缺 | 缺 | 缺 | 缺 | A |
| 5-12 | common/cfg/Fish.lua、server/Mgr/MgrLoot.lua | tests/native/fish_loot_test.lua | 缺 | 缺 | 缺 | 缺 | A |
| 5-13 | common/cfg/Fish.lua、common/cfg/Items.lua | tests/native/cfg_fish_items_test.lua | 缺 | 缺 | 缺 | 缺 | A |
| 5-14 | common/cfg/Fish.lua | tests/native/cfg_fish_items_test.lua | 缺 | 缺 | 缺 | 缺 | A |
| 5-15 | common/cfg/Fish.lua | tests/native/cfg_fish_items_test.lua | 缺 | 缺 | 缺 | 缺 | A |
| 5-16 | common/cfg/Fish.lua、common/ContentValidation.lua | tests/native/content_validation_test.lua | 缺 | 缺 | 缺 | 缺 | A |
| 5-17 | common/cfg/Fish.lua、common/cfg/Items.lua、server/Mgr/MgrLoot.lua | tests/native/fish_loot_test.lua、tests/native/cfg_fish_items_test.lua | 缺 | 缺 | 缺 | 缺 | A |
| 5-18 | common/cfg/Fish.lua、server/Mgr/MgrFishUnit.lua | tests/native/fish_air_escape_test.lua、tests/native/island_content_test.lua | 缺 | 缺 | 缺 | 缺 | A |

第 5 节的 5-01 与 5-03 已由图鉴客户端的公开显示快照取证：tests/native/spec/05_zone_fish_data_test.lua 翻满七页，
断言每页 14 条、总数 98、七区 6/6/1/1 品级分布；其余条款待后续断言。

### 第 16 节 物品基础数据（17 条）

| 条款 | 代码落点 | 关联测试 | 正常流程 | 失败流程 | 退出重进 | 存档恢复 | 等级 |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 16-01 | common/cfg/Items.lua、common/ContentValidation.lua | tests/native/cfg_fish_items_test.lua、tests/native/content_validation_test.lua | 缺 | 缺 | 缺 | 缺 | A |
| 16-02 | common/cfg/Items.lua | tests/native/cfg_fish_items_test.lua | 缺 | 缺 | 缺 | 缺 | A |
| 16-03 | common/cfg/Items.lua | tests/native/cfg_fish_items_test.lua | 缺 | 缺 | 缺 | 缺 | A |
| 16-04 | common/cfg/Items.lua、server/Mgr/MgrVitals.lua | tests/native/spec/16_item_base_data_test.lua、tests/native/vitals_test.lua | 有 | 缺 | 缺 | 缺 | A |
| 16-05 | common/cfg/Items.lua、server/Mgr/MgrSpecialItem.lua | tests/native/special_item_mgr_test.lua | 缺 | 缺 | 缺 | 缺 | A |
| 16-06 | common/cfg/Items.lua、server/Mgr/MgrVitals.lua | tests/native/spec/16_item_base_data_test.lua、tests/native/vitals_test.lua | 缺 | 有 | 缺 | 缺 | A |
| 16-07 | common/cfg/Items.lua、server/Mgr/MgrVitals.lua | tests/native/spec/16_item_base_data_test.lua、tests/native/vitals_test.lua | 有 | 缺 | 缺 | 缺 | A |
| 16-08 | common/cfg/Items.lua、common/ContentValidation.lua | tests/native/content_validation_test.lua | 缺 | 缺 | 缺 | 缺 | A |
| 16-09 | common/cfg/Items.lua、server/Mgr/MgrInteract.lua | — | 缺 | 缺 | 缺 | 缺 | A |
| 16-10 | common/cfg/Items.lua | tests/native/cfg_fish_items_test.lua | 缺 | 缺 | 缺 | 缺 | A |
| 16-11 | common/cfg/Items.lua | tests/native/cfg_fish_items_test.lua | 缺 | 缺 | 缺 | 缺 | A |
| 16-12 | common/cfg/Items.lua | tests/native/cfg_fish_items_test.lua | 缺 | 缺 | 缺 | 缺 | A |
| 16-13 | common/cfg/Items.lua、common/GameCfg.lua、common/cfg/ContentLedger.lua | tests/native/cfg_fish_items_test.lua、tests/native/content_validation_test.lua | 缺 | 缺 | 缺 | 缺 | B |
| 16-14 | common/cfg/Items.lua、common/ContentValidation.lua | tests/native/content_validation_test.lua | 缺 | 缺 | 缺 | 缺 | B |
| 16-15 | common/cfg/Items.lua、server/Mgr/MgrLoot.lua | tests/native/fish_loot_test.lua | 缺 | 缺 | 缺 | 缺 | B |
| 16-16 | common/cfg/Items.lua、common/cfg/PlaceholderAssets.lua | tests/native/placeholder_assets_test.lua | 缺 | 缺 | 缺 | 缺 | B |
| 16-17 | common/cfg/Items.lua、common/GameCfg.lua | tests/native/cfg_fish_items_test.lua | 缺 | 缺 | 缺 | 缺 | B |

第 16 节的 16-04、16-06、16-07 已由服务端 MgrVitals 的公开食用入口取证：食物 / 极品食物 / 鱼饵全部可吃，
其余类别一律拒绝；负恢复项吃后扣饥饿并扣血。16-13 的「实现标记只有一份真源」由 common/cfg/ContentLedger.lua
与 common/ContentValidation.lua 的一致性门禁守住。

### 第 18 节 存档与恢复契约（32 条）

| 条款 | 代码落点 | 关联测试 | 正常流程 | 失败流程 | 退出重进 | 存档恢复 | 等级 |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 18-01 | server/Data/PlayerData.lua、server/Mgr/MgrSave.lua | tests/native/spec/18_session_settlement_contract_test.lua | 有 | 有 | 有 | 有 | B |
| 18-02 | server/Data/PlayerData.lua、server/Mgr/MgrSave.lua | tests/native/spec/18_session_settlement_contract_test.lua | 有 | 缺 | 缺 | 有 | B |
| 18-03 | server/Data/PlayerData.lua、server/Mgr/MgrWeapon.lua | — | 缺 | 缺 | 缺 | 缺 | B |
| 18-04 | server/Data/PlayerData.lua、server/Mgr/MgrShop.lua | tests/native/spec/18_session_settlement_contract_test.lua | 有 | 缺 | 缺 | 有 | B |
| 18-05 | server/Data/PlayerData.lua、server/Mgr/MgrSurvival.lua | tests/native/spec/18_session_settlement_contract_test.lua | 有 | 缺 | 有 | 有 | B |
| 18-06 | server/Mgr/MgrSurvival.lua、server/Data/PlayerData.lua | tests/native/spec/18_session_settlement_contract_test.lua | 有 | 缺 | 缺 | 有 | B |
| 18-07 | server/Mgr/MgrCompendium.lua、server/Data/PlayerData.lua | tests/native/spec/18_session_settlement_contract_test.lua | 有 | 缺 | 缺 | 有 | B |
| 18-08 | server/Mgr/MgrQuest.lua、server/Mgr/MgrStory.lua | tests/native/spec/18_session_settlement_contract_test.lua | 有 | 缺 | 缺 | 有 | B |
| 18-09 | server/Mgr/MgrFerry.lua、server/Data/PlayerData.lua | tests/native/spec/18_session_settlement_contract_test.lua | 有 | 缺 | 缺 | 有 | B |
| 18-10 | server/Data/PlayerData.lua、server/Mgr/MgrSave.lua | tests/native/spec/18_session_settlement_contract_test.lua | 有 | 有 | 有 | 有 | B |
| 18-11 | server/Mgr/MgrBlindbox.lua、server/Data/PlayerData.lua | tests/native/spec/18_session_settlement_contract_test.lua | 有 | 缺 | 缺 | 有 | B |
| 18-12 | server/Mgr/MgrAchievements.lua、server/Data/PlayerData.lua | tests/native/spec/18_session_settlement_contract_test.lua | 有 | 缺 | 缺 | 有 | B |
| 18-13 | server/Mgr/MgrSave.lua、server/Mgr/MgrFerry.lua | tests/native/spec/18_session_settlement_contract_test.lua | 有 | 有 | 有 | 有 | B |
| 18-14 | server/Mgr/MgrWeapon.lua、server/Data/PlayerData.lua | — | 缺 | 缺 | 缺 | 缺 | B |
| 18-15 | server/Mgr/MgrWeapon.lua、server/Mgr/MgrSave.lua | tests/native/weapon_system_test.lua | 缺 | 缺 | 缺 | 缺 | B |
| 18-16 | server/Data/PlayerData.lua | tests/native/spec/18_session_settlement_contract_test.lua | 有 | 缺 | 缺 | 有 | B |
| 18-17 | server/Data/PlayerData.lua | tests/native/spec/18_session_settlement_contract_test.lua | 有 | 缺 | 缺 | 有 | B |
| 18-18 | server/Data/PlayerData.lua、server/Mgr/MgrSave.lua | tests/native/spec/18_session_settlement_contract_test.lua | 有 | 有 | 缺 | 有 | B |
| 18-19 | server/main.lua、server/Mgr/MgrSave.lua | tests/native/spec/18_session_settlement_contract_test.lua | 有 | 有 | 缺 | 缺 | B |
| 18-20 | server/Mgr/MgrSave.lua、server/main.lua | tests/native/spec/18_session_settlement_contract_test.lua | 有 | 有 | 有 | 有 | B |
| 18-21 | server/Mgr/MgrSave.lua | tests/native/spec/18_session_settlement_contract_test.lua | 有 | 有 | 缺 | 有 | B |
| 18-22 | server/Mgr/MgrSave.lua | tests/native/spec/18_session_settlement_contract_test.lua | 有 | 有 | 缺 | 有 | B |
| 18-23 | server/Mgr/MgrSave.lua、server/Mgr/MgrShop.lua | tests/native/spec/18_session_settlement_contract_test.lua | 有 | 有 | 有 | 有 | B |
| 18-24 | server/Mgr/MgrSave.lua、server/Mgr/MgrFerry.lua | tests/native/spec/18_session_settlement_contract_test.lua | 有 | 有 | 有 | 有 | B |
| 18-25 | server/Mgr/MgrFerry.lua、server/Mgr/MgrSave.lua | tests/native/ferry_test.lua | 缺 | 缺 | 缺 | 缺 | B |
| 18-26 | server/Mgr/MgrPlatform.lua | — | 缺 | 缺 | 缺 | 缺 | B |
| 18-27 | server/Data/PlayerData.lua、server/Mgr/MgrLoot.lua | tests/native/spec/18_session_settlement_contract_test.lua | 有 | 缺 | 缺 | 有 | B |
| 18-28 | server/Mgr/MgrLottery.lua、server/Mgr/MgrSave.lua | tests/native/lottery_settle_test.lua | 缺 | 缺 | 缺 | 缺 | B |
| 18-29 | server/Mgr/MgrInteract.lua、server/Mgr/MgrSave.lua | tests/native/economy_persistence_test.lua | 缺 | 缺 | 缺 | 缺 | B |
| 18-30 | server/Mgr/MgrGrill.lua、server/main.lua | tests/native/grill_test.lua | 缺 | 缺 | 缺 | 缺 | B |
| 18-31 | server/Mgr/MgrSave.lua、server/Data/PlayerData.lua | tests/native/spec/18_session_settlement_contract_test.lua | 有 | 有 | 有 | 有 | B |
| 18-32 | server/main.lua、server/Mgr/MgrPlayerData.lua | tests/native/player_leave_rejoin_test.lua | 缺 | 缺 | 缺 | 缺 | B |

### 第 13 节 图鉴与成就（16 条）

| 条款 | 代码落点 | 关联测试 | 正常流程 | 失败流程 | 退出重进 | 存档恢复 | 等级 |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 13-01 | common/cfg/Fish.lua、client/ScreenHandlers/ScreenCompendium.lua | tests/native/compendium_test.lua、tests/native/compendium_ui_test.lua | 缺 | 缺 | 缺 | 缺 | A |
| 13-02 | client/ScreenHandlers/ScreenCompendium.lua、common/GameCfg.lua | tests/native/compendium_ui_test.lua | 缺 | 缺 | 缺 | 缺 | A |
| 13-03 | client/ScreenHandlers/ScreenCompendium.lua | tests/native/compendium_ui_test.lua | 缺 | 缺 | 缺 | 缺 | A |
| 13-04 | server/Mgr/MgrCompendium.lua、server/Mgr/MgrReelIn.lua、server/Mgr/MgrFishUnit.lua | tests/native/compendium_test.lua | 缺 | 缺 | 缺 | 缺 | A |
| 13-05 | server/Mgr/MgrCompendium.lua | tests/native/compendium_test.lua | 缺 | 缺 | 缺 | 缺 | B |
| 13-06 | server/Mgr/MgrCompendium.lua、server/Data/PlayerData.lua | tests/native/compendium_test.lua | 缺 | 缺 | 缺 | 缺 | A |
| 13-07 | client/ScreenHandlers/ScreenCompendium.lua、server/Mgr/MgrRecords.lua、common/Records.lua | tests/native/spec/13_record_display_placeholder_test.lua | 有 | 缺 | 缺 | 缺 | A |
| 13-08 | client/ScreenHandlers/ScreenCompendium.lua、server/Mgr/MgrRecords.lua、common/Records.lua | tests/native/spec/13_record_display_placeholder_test.lua | 有 | 缺 | 缺 | 缺 | A |
| 13-09 | server/Mgr/MgrCompendium.lua、server/Mgr/MgrBlindbox.lua、server/Mgr/MgrInteract.lua | tests/native/compendium_test.lua | 缺 | 缺 | 缺 | 缺 | B |
| 13-10 | server/Mgr/MgrInteract.lua、common/GameCfg.lua、server/Mgr/MgrAchievements.lua | tests/native/exchange_zones_127_test.lua | 缺 | 缺 | 缺 | 缺 | A |
| 13-11 | server/Mgr/MgrCompendium.lua、server/Mgr/MgrInteract.lua | tests/native/compendium_test.lua、tests/native/exchange_zones_127_test.lua | 缺 | 缺 | 缺 | 缺 | A |
| 13-12 | server/Mgr/MgrAchievements.lua、common/GameCfg.lua | tests/native/spec/13_achievement_delivery_placeholder_test.lua | 有 | 缺 | 有 | 有 | B |
| 13-13 | server/Mgr/MgrAchievements.lua | tests/native/spec/13_achievement_delivery_placeholder_test.lua | 有 | 缺 | 有 | 有 | B |
| 13-14 | server/Mgr/MgrAchievements.lua、server/Mgr/MgrSave.lua | tests/native/spec/13_achievement_delivery_placeholder_test.lua | 有 | 有 | 缺 | 缺 | B |
| 13-17 | server/Mgr/MgrRecords.lua、server/Data/RecordsAdapter.lua、common/Records.lua、client/ScreenHandlers/ScreenCompendium.lua | tests/native/spec/13_record_display_placeholder_test.lua、tests/native/records_test.lua | 缺 | 有 | 缺 | 缺 | B |
| 13-18 | server/Mgr/MgrAchievements.lua、common/GameCfg.lua | tests/native/spec/13_achievement_delivery_placeholder_test.lua、tests/native/spec/17_platform_achievement_id_test.lua | 有 | 有 | 有 | 有 | B |

第 13 节的 13-07、13-08、13-17 由图鉴客户端与服务端纪录查询的公开入口取证：`tests/native/spec/13_record_display_placeholder_test.lua` 
翻到「没有纪录」与「纪录服务未接入」两种回包，断言该列只显示「未取得数据」、不出现任何数字与保持者；13-12～13-14、13-18 由
成就交付队列取证。13-15、13-16 是试玩条款，不在本表登记。

### 第 17 节 新手任务、剧情与平台边界（22 条）

| 条款 | 代码落点 | 关联测试 | 正常流程 | 失败流程 | 退出重进 | 存档恢复 | 等级 |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 17-01 | common/GameCfg.lua、server/Mgr/MgrQuest.lua | tests/native/quest_test.lua | 缺 | 缺 | 缺 | 缺 | A |
| 17-02 | common/GameCfg.lua、server/Mgr/MgrQuest.lua | tests/native/quest_test.lua | 缺 | 缺 | 缺 | 缺 | A |
| 17-03 | server/Mgr/MgrQuest.lua | tests/native/quest_test.lua | 缺 | 缺 | 缺 | 缺 | A |
| 17-04 | server/Mgr/MgrQuest.lua、server/Mgr/MgrSave.lua、server/Data/PlayerData.lua | tests/native/quest_test.lua、tests/native/save_test.lua | 缺 | 缺 | 缺 | 缺 | B |
| 17-05 | server/Mgr/MgrQuest.lua | tests/native/quest_test.lua | 缺 | 缺 | 缺 | 缺 | A |
| 17-06 | common/GameCfg.lua、server/Mgr/MgrPlayerData.lua | tests/native/gm_panel_test.lua | 缺 | 缺 | 缺 | 缺 | A |
| 17-07 | common/GameCfg.lua、common/cfg/Shop.lua、server/Mgr/MgrShop.lua | tests/native/quest_test.lua、tests/native/shop_test.lua | 缺 | 缺 | 缺 | 缺 | A |
| 17-08 | server/Mgr/MgrStory.lua、client/ScreenHandlers/ScreenMain.lua | tests/native/guide_persistence_test.lua | 缺 | 缺 | 缺 | 缺 | A |
| 17-09 | server/Mgr/MgrStory.lua、client/ScreenHandlers/ScreenMain.lua | tests/native/guide_persistence_test.lua | 缺 | 缺 | 缺 | 缺 | A |
| 17-10 | server/Mgr/MgrStory.lua、server/Data/PlayerData.lua | tests/native/guide_persistence_test.lua | 缺 | 缺 | 缺 | 缺 | B |
| 17-11 | common/NpcDialogue.lua、server/Mgr/MgrStory.lua | — | 缺 | 缺 | 缺 | 缺 | A |
| 17-12 | common/NpcDialogue.lua、server/Mgr/MgrStory.lua | — | 缺 | 缺 | 缺 | 缺 | A |
| 17-13 | common/NpcDialogue.lua、server/Mgr/MgrStory.lua | — | 缺 | 缺 | 缺 | 缺 | A |
| 17-14 | server/Mgr/MgrStory.lua | — | 缺 | 缺 | 缺 | 缺 | B |
| 17-15 | server/Mgr/MgrShop.lua、server/Mgr/MgrPlatform.lua、common/GameCfg.lua | tests/native/shop_test.lua、tests/native/platform_seam_test.lua | 缺 | 缺 | 缺 | 缺 | B |
| 17-16 | server/Mgr/MgrPlatform.lua、common/GameCfg.lua | tests/native/platform_seam_test.lua | 缺 | 缺 | 缺 | 缺 | B |
| 17-17 | server/Mgr/MgrAchievements.lua、common/GameCfg.lua | tests/native/spec/17_platform_achievement_id_test.lua | 有 | 有 | 缺 | 缺 | B |
| 17-18 | server/Mgr/MgrPlatform.lua、common/GameCfg.lua | tests/native/spec/17_platform_boundary_placeholder_test.lua | 有 | 有 | 缺 | 缺 | B |
| 17-19 | common/cfg/PlaceholderAssets.lua | tests/native/placeholder_assets_test.lua | 缺 | 缺 | 缺 | 缺 | A |
| 17-20 | server/Mgr/MgrPlatform.lua、server/Mgr/MgrRecords.lua | tests/native/platform_seam_test.lua、tests/native/records_test.lua | 缺 | 缺 | 缺 | 缺 | B |
| 17-21 | server/Mgr/MgrPlatform.lua、common/GameCfg.lua | tests/native/platform_seam_test.lua | 缺 | 缺 | 缺 | 缺 | A |
| 17-22 | server/Mgr/MgrPlatform.lua、common/GameCfg.lua | tests/native/platform_seam_test.lua | 缺 | 缺 | 缺 | 缺 | A |

第 17 节的 17-17 由平台成就占位 ID 的完成与补交换配置取证，17-18 由分享占位入口取证；其余条款先登记落点，断言待后续。

## 三、待登记小节

第 2～4、6～12、14～15、19 节尚未登记。按依赖顺序逐节扩大，每节登记时同时补齐该节的代码落点与既有测试，
并把该节加进 `tools/acceptance.lua` 的 `M.COVERAGE_SECTIONS`。
