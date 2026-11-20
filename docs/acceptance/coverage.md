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

### 第 2 节 玩家属性（17 条）

| 条款 | 代码落点 | 关联测试 | 正常流程 | 失败流程 | 退出重进 | 存档恢复 | 等级 |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 2-01 | common/GameCfg.lua、server/Mgr/MgrVitals.lua | tests/native/vitals_test.lua、tests/native/attr_growth_test.lua | 缺 | 缺 | 缺 | 缺 | A |
| 2-02 | common/AttrModel.lua、server/Mgr/MgrAttr.lua | tests/native/vitals_test.lua、tests/native/attr_growth_test.lua | 缺 | 缺 | 缺 | 缺 | A |
| 2-03 | common/AttrModel.lua、common/GameCfg.lua | tests/native/attr_growth_test.lua | 缺 | 缺 | 缺 | 缺 | A |
| 2-04 | common/AttrModel.lua、common/BodyScale.lua、server/Mgr/MgrAttr.lua | tests/native/vitals_test.lua、tests/native/attr_growth_test.lua | 缺 | 缺 | 缺 | 缺 | A |
| 2-05 | common/AttrModel.lua、server/Mgr/MgrAttr.lua | tests/native/vitals_test.lua、tests/native/attr_growth_test.lua | 缺 | 缺 | 缺 | 缺 | A |
| 2-06 | common/AttrModel.lua、common/GameCfg.lua | tests/native/vitals_test.lua、tests/native/attr_growth_test.lua | 缺 | 缺 | 缺 | 缺 | A |
| 2-07 | common/Vitals.lua、server/Mgr/MgrVitals.lua | tests/native/vitals_test.lua、tests/native/attr_growth_test.lua | 缺 | 缺 | 缺 | 缺 | A |
| 2-08 | common/Vitals.lua、server/Mgr/MgrVitals.lua | tests/native/vitals_test.lua、tests/native/attr_growth_test.lua | 缺 | 缺 | 缺 | 缺 | A |
| 2-09 | server/Mgr/MgrSave.lua、server/Data/PlayerData.lua、server/Mgr/MgrAttr.lua | tests/native/attr_migration_test.lua、tests/native/save_test.lua | 缺 | 缺 | 缺 | 缺 | B |
| 2-10 | server/Mgr/MgrPlayerData.lua、server/Mgr/MgrAttr.lua | tests/native/attr_growth_test.lua、tests/native/item_bar_flow_test.lua | 缺 | 缺 | 缺 | 缺 | A |
| 2-11 | server/Mgr/MgrPlayerData.lua、server/Mgr/MgrLoot.lua | tests/native/loot_drop_test.lua | 缺 | 缺 | 缺 | 缺 | B |
| 2-12 | common/AttrModel.lua、server/Mgr/MgrAttr.lua | tests/native/attr_presentation_test.lua | 缺 | 缺 | 缺 | 缺 | A |
| 2-13 | server/Mgr/MgrVitals.lua、common/GameCfg.lua | tests/native/vitals_growth_test.lua、tests/native/vitals_test.lua | 缺 | 缺 | 缺 | 缺 | A |
| 2-14 | server/Mgr/MgrVitals.lua、common/GameCfg.lua | tests/native/vitals_growth_test.lua、tests/native/vitals_test.lua | 缺 | 缺 | 缺 | 缺 | A |
| 2-15 | server/Mgr/MgrVitals.lua、common/GameCfg.lua | tests/native/vitals_test.lua、tests/native/attr_growth_test.lua | 缺 | 缺 | 缺 | 缺 | A |
| 2-16 | server/Mgr/MgrSurvival.lua、server/Mgr/MgrVitals.lua | tests/native/vitals_test.lua、tests/native/attr_growth_test.lua | 缺 | 缺 | 缺 | 缺 | A |
| 2-17 | common/AttrModel.lua、server/Mgr/MgrAttr.lua | tests/native/vitals_test.lua、tests/native/attr_growth_test.lua | 缺 | 缺 | 缺 | 缺 | A |

2-11 的「赠送」目前在代码里没有独立协议：跨玩家转移只有丢弃→拾取一条通路，药水成长值只在使用者身上生效，因此这条保持 unverified，缺口记在 [策划案内部矛盾](../to-questionnaire-策划案内部矛盾.md)。其余条款的数值全部集中在 common/GameCfg.lua 的 Vitals 与 common/AttrModel.lua。

### 第 3 节 持有与操作（22 条）

| 条款 | 代码落点 | 关联测试 | 正常流程 | 失败流程 | 退出重进 | 存档恢复 | 等级 |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 3-01 | client/ScreenHandlers/ScreenMain.lua、client/MainHudLayout.lua | tests/native/main_hud_layout_test.lua、tests/native/hold_operate_ui_test.lua | 缺 | 缺 | 缺 | 缺 | A |
| 3-02 | client/MainHudLayout.lua、server/Mgr/MgrPlatform.lua | tests/native/main_hud_layout_test.lua、tests/native/hold_operate_ui_test.lua | 缺 | 缺 | 缺 | 缺 | A |
| 3-03 | client/ScreenHandlers/ScreenMain.lua、client/MainHudLayout.lua | tests/native/main_hud_layout_test.lua、tests/native/hold_operate_ui_test.lua | 缺 | 缺 | 缺 | 缺 | A |
| 3-04 | client/ScreenHandlers/ScreenMain.lua、client/MainHudLayout.lua | tests/native/main_hud_layout_test.lua、tests/native/hold_operate_ui_test.lua | 缺 | 缺 | 缺 | 缺 | A |
| 3-05 | common/GameCfg.lua、server/Mgr/MgrShop.lua、server/Data/PlayerData.lua | tests/native/build_site_inventory_test.lua、tests/native/shop_test.lua | 缺 | 缺 | 缺 | 缺 | A |
| 3-06 | common/GameCfg.lua、server/Mgr/MgrShop.lua、server/Data/PlayerData.lua | tests/native/build_site_inventory_test.lua、tests/native/shop_test.lua | 缺 | 缺 | 缺 | 缺 | A |
| 3-07 | server/Mgr/MgrLoot.lua、server/Data/PlayerData.lua | tests/native/item_bar_test.lua、tests/native/item_bar_flow_test.lua | 缺 | 缺 | 缺 | 缺 | A |
| 3-08 | server/Data/PlayerData.lua | tests/native/item_bar_test.lua、tests/native/item_bar_flow_test.lua | 缺 | 缺 | 缺 | 缺 | A |
| 3-09 | server/Mgr/MgrPlayerData.lua、server/Data/PlayerData.lua | tests/native/hold_operate_mgr_test.lua、tests/native/item_bar_flow_test.lua | 缺 | 缺 | 缺 | 缺 | A |
| 3-10 | server/Mgr/MgrPlayerData.lua、server/Data/PlayerData.lua | tests/native/hold_operate_mgr_test.lua、tests/native/item_bar_flow_test.lua | 缺 | 缺 | 缺 | 缺 | A |
| 3-11 | server/Data/PlayerData.lua、server/Mgr/MgrWeapon.lua | tests/native/weapon_system_test.lua | 缺 | 缺 | 缺 | 缺 | A |
| 3-12 | server/Data/PlayerData.lua、common/GameCfg.lua | tests/native/item_bar_test.lua、tests/native/item_bar_flow_test.lua | 缺 | 缺 | 缺 | 缺 | A |
| 3-13 | server/Data/PlayerData.lua | tests/native/item_bar_test.lua、tests/native/item_bar_flow_test.lua | 缺 | 缺 | 缺 | 缺 | A |
| 3-14 | server/Mgr/MgrCast.lua、server/Mgr/MgrInteract.lua | tests/native/item_bar_test.lua、tests/native/item_bar_flow_test.lua | 缺 | 缺 | 缺 | 缺 | A |
| 3-15 | server/Mgr/MgrCast.lua、server/Mgr/MgrPlayerData.lua | tests/native/item_bar_test.lua、tests/native/item_bar_flow_test.lua | 缺 | 缺 | 缺 | 缺 | A |
| 3-16 | server/Mgr/MgrSurvival.lua | tests/native/survival_test.lua | 缺 | 缺 | 缺 | 缺 | A |
| 3-17 | server/Mgr/MgrPlayerData.lua、client/LocalAttackButton.lua | tests/native/hold_operate_mgr_test.lua、tests/native/item_bar_flow_test.lua | 缺 | 缺 | 缺 | 缺 | A |
| 3-18 | server/Mgr/MgrSpecialItem.lua、common/SpecialItem.lua | tests/native/special_item_mgr_test.lua、tests/native/hold_operate_test.lua | 缺 | 缺 | 缺 | 缺 | A |
| 3-19 | server/Mgr/MgrPlayerData.lua、server/Mgr/MgrLoot.lua | tests/native/loot_drop_test.lua | 缺 | 缺 | 缺 | 缺 | A |
| 3-20 | server/Mgr/MgrLoot.lua | tests/native/loot_drop_test.lua | 缺 | 缺 | 缺 | 缺 | A |
| 3-21 | server/Mgr/MgrLoot.lua、server/Data/PlayerData.lua | tests/native/loot_recycle_test.lua | 缺 | 缺 | 缺 | 缺 | A |
| 3-22 | server/Data/PlayerData.lua、server/Mgr/MgrSave.lua | tests/native/economy_persistence_test.lua | 缺 | 缺 | 缺 | 缺 | B |

道具栏与背包容量、升级价在 common/GameCfg.lua 的 Items 段，升级入口是 MgrShop 的 UpgradeStorage；格位进出与选中/手持分离由 MgrPlayerData 与 PlayerData 共同持有。

### 第 4 节 钓鱼系统（28 条）

| 条款 | 代码落点 | 关联测试 | 正常流程 | 失败流程 | 退出重进 | 存档恢复 | 等级 |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 4-01 | server/Mgr/MgrCast.lua、common/MathWaterJudge.lua | tests/native/cast_waiting_test.lua | 缺 | 缺 | 缺 | 缺 | A |
| 4-02 | server/Mgr/MgrCast.lua、server/Data/PlayerData.lua | tests/native/cast_waiting_test.lua | 缺 | 缺 | 缺 | 缺 | A |
| 4-03 | server/Mgr/MgrCast.lua、common/FishCatch.lua | tests/native/cast_waiting_test.lua、tests/native/fish_loot_test.lua | 缺 | 缺 | 缺 | 缺 | B |
| 4-04 | server/Mgr/MgrCast.lua | tests/native/cast_waiting_test.lua | 缺 | 缺 | 缺 | 缺 | A |
| 4-05 | server/Mgr/MgrReelIn.lua、client/LocalReelIn.lua | tests/native/cast_waiting_test.lua、tests/native/reel_session_test.lua | 缺 | 缺 | 缺 | 缺 | A |
| 4-06 | common/ReelProgress.lua、common/GameCfg.lua | tests/native/cast_waiting_test.lua、tests/native/reel_session_test.lua、tests/native/spec/04_fishing_reel_rules_test.lua | 有 | 缺 | 缺 | 缺 | A |
| 4-07 | common/ReelProgress.lua、common/GameCfg.lua | tests/native/cast_waiting_test.lua、tests/native/reel_session_test.lua、tests/native/spec/04_fishing_reel_rules_test.lua | 有 | 缺 | 缺 | 缺 | A |
| 4-08 | common/ReelProgress.lua、common/GameCfg.lua | tests/native/cast_waiting_test.lua、tests/native/reel_session_test.lua | 缺 | 缺 | 缺 | 缺 | A |
| 4-09 | client/LocalReelIn.lua、common/ReelDisplay.lua | tests/native/cast_waiting_test.lua、tests/native/reel_session_test.lua | 缺 | 缺 | 缺 | 缺 | A |
| 4-10 | common/ReelProgress.lua、common/GameCfg.lua | tests/native/cast_waiting_test.lua、tests/native/reel_session_test.lua | 缺 | 缺 | 缺 | 缺 | B |
| 4-11 | server/Mgr/MgrReelIn.lua、common/ReelProgress.lua | tests/native/cast_waiting_test.lua、tests/native/reel_session_test.lua、tests/native/spec/04_fishing_reel_rules_test.lua | 缺 | 有 | 缺 | 缺 | A |
| 4-12 | server/Mgr/MgrCast.lua、client/LocalCastSource.lua | tests/native/landing_test.lua、tests/native/fish_lift_test.lua | 缺 | 缺 | 缺 | 缺 | A |
| 4-13 | server/Mgr/MgrFishUnit.lua、server/Mgr/MgrFishCarrier.lua | tests/native/landing_test.lua、tests/native/fish_lift_test.lua | 缺 | 缺 | 缺 | 缺 | A |
| 4-14 | common/FishCatch.lua | tests/native/cfg_fish_items_test.lua、tests/native/fish_loot_test.lua | 缺 | 缺 | 缺 | 缺 | A |
| 4-15 | common/FishCatch.lua | tests/native/cfg_fish_items_test.lua、tests/native/fish_loot_test.lua | 缺 | 缺 | 缺 | 缺 | A |
| 4-16 | common/FishCatch.lua | tests/native/cfg_fish_items_test.lua、tests/native/fish_loot_test.lua | 缺 | 缺 | 缺 | 缺 | A |
| 4-17 | server/Mgr/MgrCast.lua、common/FishCatch.lua | tests/native/boss_bait_test.lua | 缺 | 缺 | 缺 | 缺 | A |
| 4-18 | server/Mgr/MgrCast.lua、common/FishCatch.lua | tests/native/boss_bait_test.lua | 缺 | 缺 | 缺 | 缺 | A |
| 4-19 | common/FishCatch.lua | tests/native/cfg_fish_items_test.lua、tests/native/fish_loot_test.lua | 缺 | 缺 | 缺 | 缺 | A |
| 4-20 | common/FishCatch.lua | tests/native/cfg_fish_items_test.lua、tests/native/fish_loot_test.lua | 缺 | 缺 | 缺 | 缺 | A |
| 4-21 | common/FishCatch.lua | tests/native/cfg_fish_items_test.lua、tests/native/fish_loot_test.lua | 缺 | 缺 | 缺 | 缺 | A |
| 4-22 | common/FishCatch.lua、server/Mgr/MgrGrill.lua | tests/native/cfg_fish_items_test.lua、tests/native/fish_loot_test.lua | 缺 | 缺 | 缺 | 缺 | A |
| 4-23 | server/Mgr/MgrLottery.lua、common/LotteryDraw.lua | tests/native/lottery_settle_test.lua | 缺 | 缺 | 缺 | 缺 | A |
| 4-24 | server/Mgr/MgrFishCarrier.lua、common/GameCfg.lua | tests/native/fish_escape_test.lua、tests/native/fish_carrier_test.lua | 缺 | 缺 | 缺 | 缺 | A |
| 4-25 | server/Mgr/MgrFishCarrier.lua、common/GameCfg.lua | tests/native/fish_escape_test.lua、tests/native/fish_carrier_test.lua | 缺 | 缺 | 缺 | 缺 | A |
| 4-26 | server/Mgr/MgrFishCarrier.lua、common/GameCfg.lua | tests/native/fish_escape_test.lua、tests/native/fish_carrier_test.lua | 缺 | 缺 | 缺 | 缺 | A |
| 4-27 | server/Mgr/MgrCast.lua | tests/native/cast_waiting_test.lua | 缺 | 缺 | 缺 | 缺 | B |
| 4-28 | common/FishCatch.lua、server/Mgr/MgrLoot.lua、server/Data/PlayerData.lua | tests/native/loot_recycle_test.lua、tests/native/fish_loot_test.lua | 缺 | 缺 | 缺 | 缺 | A |

个体倍率、重量、价格与取整都从 common/FishCatch.lua 一处派生（重量与金币都按基础值一次乘算），收线节奏在 common/ReelProgress.lua，抛竿与选鱼在 MgrCast。

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

### 第 6 节 战斗与成长（34 条）

> #260 目标选择接线：6-26 / 6-29 / 6-30 / 6-31 的规格断言在 tests/native/spec/06_ai_target_test.lua；
> 属性与效果投影的接线验收同在该文件（AttrModel → attr_rule、modifier_system → 移速倍率）。

| 条款 | 代码落点 | 关联测试 | 正常流程 | 失败流程 | 退出重进 | 存档恢复 | 等级 |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 6-01 | server/Mgr/MgrWeapon.lua、common/GameCfg.lua | tests/native/weapon_system_test.lua、tests/native/combat_behavior_test.lua | 缺 | 缺 | 缺 | 缺 | A |
| 6-02 | server/Mgr/MgrWeapon.lua、common/GameCfg.lua、common/cfg/Items.lua | tests/native/weapon_system_test.lua、tests/native/combat_behavior_test.lua | 缺 | 缺 | 缺 | 缺 | A |
| 6-03 | server/Mgr/MgrWeapon.lua、common/GameCfg.lua | tests/native/weapon_system_test.lua、tests/native/combat_behavior_test.lua | 缺 | 缺 | 缺 | 缺 | A |
| 6-04 | server/Mgr/MgrWeapon.lua、common/GameCfg.lua | tests/native/weapon_system_test.lua、tests/native/combat_behavior_test.lua | 缺 | 缺 | 缺 | 缺 | A |
| 6-05 | server/Mgr/MgrWeapon.lua、client/packages/ability_system/strategy/HoldStrategy.lua、client/WeaponAim.lua | tests/native/weapon_system_test.lua、tests/native/combat_behavior_test.lua | 缺 | 缺 | 缺 | 缺 | A |
| 6-06 | common/cfg/Shop.lua、server/Mgr/MgrWeapon.lua、common/GameCfg.lua | tests/native/weapon_system_test.lua、tests/native/combat_behavior_test.lua | 缺 | 缺 | 缺 | 缺 | A |
| 6-07 | common/cfg/Items.lua、common/GameCfg.lua | tests/native/cfg_fish_items_test.lua、tests/native/prize_weapon_effect_test.lua、tests/native/prize_weapon_cfg_test.lua | 缺 | 缺 | 缺 | 缺 | A |
| 6-08 | common/cfg/Shop.lua、server/Mgr/MgrWeapon.lua | tests/native/weapon_system_test.lua、tests/native/combat_behavior_test.lua | 缺 | 缺 | 缺 | 缺 | A |
| 6-09 | server/Mgr/MgrWeapon.lua、server/Mgr/MgrVitals.lua | tests/native/weapon_system_test.lua、tests/native/combat_behavior_test.lua | 缺 | 缺 | 缺 | 缺 | A |
| 6-10 | server/Mgr/MgrWeapon.lua | tests/native/weapon_system_test.lua、tests/native/combat_behavior_test.lua | 缺 | 缺 | 缺 | 缺 | A |
| 6-11 | server/Mgr/MgrWeapon.lua、client/WeaponAim.lua | tests/native/weapon_system_test.lua、tests/native/combat_behavior_test.lua | 缺 | 缺 | 缺 | 缺 | A |
| 6-12 | server/Mgr/MgrWeapon.lua | tests/native/weapon_system_test.lua、tests/native/combat_behavior_test.lua | 缺 | 缺 | 缺 | 缺 | A |
| 6-13 | server/Mgr/MgrWeapon.lua、common/FishCatch.lua、server/Mgr/MgrFishUnit.lua | tests/native/weapon_system_test.lua、tests/native/combat_behavior_test.lua | 缺 | 缺 | 缺 | 缺 | A |
| 6-14 | common/cfg/Shop.lua、server/Mgr/MgrShop.lua、server/Mgr/MgrWeapon.lua、common/AttrModel.lua、server/Mgr/MgrAttr.lua | tests/native/prize_growth_wiring_test.lua、tests/native/shop_test.lua、tests/native/attr_migration_test.lua | 缺 | 缺 | 缺 | 缺 | A |
| 6-15 | common/cfg/Shop.lua、server/Mgr/MgrShop.lua、server/Mgr/MgrWeapon.lua、common/AttrModel.lua、server/Mgr/MgrAttr.lua | tests/native/prize_growth_wiring_test.lua、tests/native/shop_test.lua、tests/native/attr_migration_test.lua | 缺 | 缺 | 缺 | 缺 | A |
| 6-16 | common/cfg/Shop.lua、server/Mgr/MgrShop.lua、server/Mgr/MgrWeapon.lua、common/AttrModel.lua、server/Mgr/MgrAttr.lua | tests/native/prize_growth_wiring_test.lua、tests/native/shop_test.lua、tests/native/attr_migration_test.lua | 缺 | 缺 | 缺 | 缺 | A |
| 6-17 | server/Mgr/MgrShop.lua、server/Mgr/MgrWeapon.lua、common/AttrModel.lua、server/Mgr/MgrAttr.lua | tests/native/prize_growth_wiring_test.lua、tests/native/shop_test.lua、tests/native/attr_migration_test.lua | 缺 | 缺 | 缺 | 缺 | A |
| 6-18 | server/Mgr/MgrWeapon.lua、server/Mgr/MgrShop.lua、common/AttrModel.lua、server/Mgr/MgrAttr.lua | tests/native/prize_weapon_effect_test.lua、tests/native/special_item_mgr_test.lua | 缺 | 缺 | 缺 | 缺 | A |
| 6-19 | server/Mgr/MgrWeapon.lua、server/Mgr/MgrAttr.lua、common/AttrModel.lua | tests/native/prize_weapon_effect_test.lua、tests/native/special_item_mgr_test.lua、tests/native/prize_growth_wiring_test.lua | 缺 | 缺 | 缺 | 缺 | A |
| 6-20 | server/Mgr/MgrSpecialItem.lua、common/SpecialItem.lua、common/AttrModel.lua、server/Mgr/MgrAttr.lua | tests/native/prize_weapon_effect_test.lua、tests/native/special_item_mgr_test.lua | 缺 | 缺 | 缺 | 缺 | A |
| 6-21 | common/cfg/Items.lua、common/cfg/Lottery.lua、common/GameCfg.lua | tests/native/cfg_fish_items_test.lua、tests/native/prize_weapon_effect_test.lua、tests/native/prize_weapon_cfg_test.lua | 缺 | 缺 | 缺 | 缺 | A |
| 6-22 | server/Mgr/MgrLottery.lua、common/LotteryDraw.lua、common/cfg/Lottery.lua | tests/native/prize_weapon_effect_test.lua、tests/native/lottery_draw_test.lua | 缺 | 缺 | 缺 | 缺 | A |
| 6-23 | common/cfg/Items.lua、common/GameCfg.lua | tests/native/cfg_fish_items_test.lua、tests/native/prize_weapon_effect_test.lua、tests/native/prize_weapon_cfg_test.lua | 缺 | 缺 | 缺 | 缺 | A |
| 6-24 | server/Mgr/MgrWeapon.lua、common/cfg/Items.lua、server/AbilityBehaviors/melee_hit.lua、server/Mgr/MgrModifier.lua、common/GameCfg.lua | tests/native/prize_weapon_effect_test.lua、tests/native/weapon_system_test.lua、tests/native/status_effect_test.lua | 缺 | 缺 | 缺 | 缺 | A |
| 6-25 | server/Mgr/MgrWeapon.lua、common/cfg/Items.lua、server/AbilityBehaviors/melee_hit.lua、server/Mgr/MgrModifier.lua、common/GameCfg.lua | tests/native/prize_weapon_effect_test.lua、tests/native/weapon_system_test.lua、tests/native/status_effect_test.lua | 缺 | 缺 | 缺 | 缺 | A |
| 6-26 | server/Mgr/MgrWeapon.lua、common/cfg/Items.lua、server/AbilityBehaviors/melee_hit.lua、server/Mgr/MgrModifier.lua、server/Mgr/MgrAttr.lua | tests/native/prize_weapon_effect_test.lua、tests/native/weapon_system_test.lua、tests/native/status_effect_test.lua、tests/native/spec/06_ai_target_test.lua | 有 | 缺 | 缺 | 缺 | A |
| 6-27 | server/Mgr/MgrWeapon.lua、common/cfg/Items.lua、server/AbilityBehaviors/melee_hit.lua、server/Mgr/MgrModifier.lua、common/GameCfg.lua | tests/native/prize_weapon_effect_test.lua、tests/native/weapon_system_test.lua、tests/native/status_effect_test.lua | 缺 | 缺 | 缺 | 缺 | A |
| 6-28 | common/cfg/Items.lua、server/Mgr/MgrWeapon.lua、common/GameCfg.lua | tests/native/prize_weapon_effect_test.lua、tests/native/weapon_system_test.lua、tests/native/prize_weapon_cfg_test.lua | 缺 | 缺 | 缺 | 缺 | A |
| 6-29 | server/Mgr/MgrAi.lua、server/Mgr/MgrFishUnit.lua、server/Mgr/MgrAiTarget.lua、common/AiTargetPolicy.lua | tests/native/ai_migration_test.lua、tests/native/spec/06_ai_target_test.lua | 有 | 有 | 缺 | 缺 | A |
| 6-30 | server/Mgr/MgrAi.lua、server/Mgr/MgrFishUnit.lua、server/Mgr/MgrAiTarget.lua | tests/native/ai_migration_test.lua、tests/native/spec/06_ai_target_test.lua | 缺 | 有 | 缺 | 缺 | A |
| 6-31 | server/Mgr/MgrAi.lua、common/BossPhase.lua、server/Mgr/MgrFishUnit.lua、server/Mgr/MgrAiTarget.lua | tests/native/ai_migration_test.lua、tests/native/spec/06_ai_target_test.lua | 有 | 有 | 缺 | 缺 | A |
| 6-32 | server/Mgr/MgrVitals.lua、server/Mgr/MgrWeapon.lua | tests/native/combat_base_test.lua、tests/native/damage_float_test.lua | 缺 | 缺 | 缺 | 缺 | B |
| 6-33 | common/DamageNotice.lua、client/DamageFloat.lua、server/Mgr/MgrVitals.lua | tests/native/combat_base_test.lua、tests/native/damage_float_test.lua | 缺 | 缺 | 缺 | 缺 | B |
| 6-34 | server/Mgr/MgrVitals.lua、server/Mgr/MgrSurvival.lua | tests/native/combat_base_test.lua、tests/native/damage_float_test.lua | 缺 | 缺 | 缺 | 缺 | B |

### 第 7 节 经济与钓场商店（25 条）

| 条款 | 代码落点 | 关联测试 | 正常流程 | 失败流程 | 退出重进 | 存档恢复 | 等级 |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 7-01 | server/Mgr/MgrInteract.lua、server/Mgr/MgrLottery.lua | tests/native/feed_exchange_test.lua、tests/native/lottery_settle_test.lua | 缺 | 缺 | 缺 | 缺 | A |
| 7-02 | server/Mgr/MgrShop.lua、server/Mgr/MgrFerry.lua | tests/native/shop_test.lua、tests/native/ferry_test.lua | 缺 | 缺 | 缺 | 缺 | A |
| 7-03 | server/Mgr/MgrBlindbox.lua、common/BlindboxDraw.lua | tests/native/blindbox_settle_test.lua | 缺 | 缺 | 缺 | 缺 | A |
| 7-04 | common/GameCfg.lua、server/Mgr/MgrPlatform.lua | tests/native/platform_seam_test.lua | 缺 | 缺 | 缺 | 缺 | A |
| 7-05 | server/Mgr/MgrShop.lua | tests/native/shop_test.lua | 缺 | 缺 | 缺 | 缺 | A |
| 7-06 | server/Mgr/MgrInteract.lua、server/Mgr/MgrLoot.lua | tests/native/feed_exchange_test.lua、tests/native/loot_recycle_test.lua | 缺 | 缺 | 缺 | 缺 | A |
| 7-07 | common/cfg/Shop.lua、server/Mgr/MgrShop.lua | tests/native/shop_test.lua | 缺 | 缺 | 缺 | 缺 | A |
| 7-08 | common/cfg/Shop.lua、server/Mgr/MgrShop.lua | tests/native/shop_test.lua | 缺 | 缺 | 缺 | 缺 | A |
| 7-09 | common/cfg/Shop.lua、client/ScreenHandlers/ScreenShop.lua | tests/native/shop_ui_test.lua | 缺 | 缺 | 缺 | 缺 | A |
| 7-10 | common/cfg/Shop.lua | tests/native/cfg_shop_lottery_test.lua | 缺 | 缺 | 缺 | 缺 | A |
| 7-11 | server/Mgr/MgrShop.lua、server/Data/PlayerData.lua | tests/native/spec/07_shop_purchase_limit_test.lua | 有 | 缺 | 缺 | 缺 | A |
| 7-12 | common/cfg/Shop.lua、common/GameCfg.lua | tests/native/cfg_shop_lottery_test.lua | 缺 | 缺 | 缺 | 缺 | A |
| 7-13 | server/Mgr/MgrShop.lua、client/ScreenHandlers/ScreenShop.lua | tests/native/shop_ui_test.lua | 缺 | 缺 | 缺 | 缺 | A |
| 7-14 | server/Mgr/MgrShop.lua、client/ScreenHandlers/ScreenShop.lua | tests/native/shop_ui_test.lua | 缺 | 缺 | 缺 | 缺 | A |
| 7-15 | client/ScreenHandlers/ScreenShop.lua | tests/native/shop_ui_test.lua | 缺 | 有 | 缺 | 缺 | A |
| 7-16 | server/Mgr/MgrPlatform.lua、client/ScreenHandlers/ScreenPlatform.lua、common/GameCfg.lua | tests/native/spec/07_coin_page_placeholder_test.lua | 有 | 有 | 缺 | 缺 | A |
| 7-17 | server/Mgr/MgrShop.lua、server/Mgr/MgrSave.lua、server/Data/PlayerData.lua | tests/native/spec/07_shop_settlement_atomic_test.lua | 有 | 有 | 缺 | 缺 | A |
| 7-18 | server/Mgr/MgrSave.lua、server/Mgr/MgrShop.lua | tests/native/spec/18_session_settlement_contract_test.lua | 缺 | 缺 | 有 | 缺 | B |
| 7-19 | server/Mgr/MgrShop.lua、server/Data/PlayerData.lua | tests/native/spec/07_shop_purchase_limit_test.lua | 缺 | 有 | 缺 | 缺 | B |
| 7-20 | server/Data/PlayerData.lua、client/ScreenHandlers/ScreenShop.lua | tests/native/shop_test.lua | 缺 | 缺 | 缺 | 缺 | B |
| 7-21 | server/Mgr/MgrSave.lua、server/Data/PlayerData.lua | tests/native/economy_persistence_test.lua | 缺 | 缺 | 缺 | 有 | B |
| 7-22 | server/Data/PlayerData.lua、client/ScreenHandlers/ScreenShop.lua | tests/native/shop_ui_test.lua | 缺 | 缺 | 缺 | 缺 | B |
| 7-23 | server/Data/PlayerData.lua、server/Mgr/MgrShop.lua、server/Mgr/MgrFerry.lua | tests/native/economy_persistence_test.lua | 缺 | 缺 | 缺 | 缺 | B |
| 7-24 | client/ScreenHandlers/ScreenShop.lua、client/ScreenHandlers/ScreenPlatform.lua | tests/native/shop_ui_test.lua | 缺 | 有 | 缺 | 缺 | B |
| 7-25 | common/GameCfg.lua、server/Mgr/MgrPlatform.lua | tests/native/spec/07_coin_page_placeholder_test.lua | 有 | 有 | 缺 | 缺 | A |

第 7 节的 7-16、7-17、7-25 已由适配层与商店结算的公开入口取证：金币页占位购买「先开通道、确认才到账」，
取消/超时不到账也不扣金币；商店一笔购买的成功与两类失败都在同一次结算里落地。7-24 只到客户端失败流程一栏。

### 第 8 节 NPC、兑换与摆渡（34 条）

| 条款 | 代码落点 | 关联测试 | 正常流程 | 失败流程 | 退出重进 | 存档恢复 | 等级 |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 8-01 | server/Mgr/MgrInteract.lua、common/NpcDialogue.lua | tests/native/feed_exchange_test.lua、tests/native/exchange_zones_127_test.lua | 缺 | 缺 | 缺 | 缺 | A |
| 8-02 | server/Mgr/MgrInteract.lua、common/cfg/Items.lua | tests/native/feed_exchange_test.lua、tests/native/exchange_zones_127_test.lua | 缺 | 缺 | 缺 | 缺 | A |
| 8-03 | server/Mgr/MgrInteract.lua、server/Data/PlayerData.lua | tests/native/feed_exchange_test.lua、tests/native/exchange_zones_127_test.lua | 缺 | 缺 | 缺 | 缺 | A |
| 8-04 | server/Mgr/MgrInteract.lua、common/GameCfg.lua | tests/native/feed_exchange_test.lua、tests/native/exchange_zones_127_test.lua | 缺 | 缺 | 缺 | 缺 | A |
| 8-05 | server/Mgr/MgrInteract.lua、server/Mgr/MgrGrill.lua | tests/native/feed_exchange_test.lua、tests/native/exchange_zones_127_test.lua | 缺 | 缺 | 缺 | 缺 | A |
| 8-06 | common/GameCfg.lua、common/ContentValidation.lua | tests/native/feed_exchange_test.lua、tests/native/exchange_zones_127_test.lua | 缺 | 缺 | 缺 | 缺 | A |
| 8-07 | server/Mgr/MgrInteract.lua、common/GameCfg.lua | tests/native/feed_exchange_test.lua、tests/native/exchange_zones_127_test.lua | 缺 | 缺 | 缺 | 缺 | A |
| 8-08 | server/Mgr/MgrInteract.lua、common/GameCfg.lua | tests/native/feed_exchange_test.lua、tests/native/exchange_zones_127_test.lua | 缺 | 缺 | 缺 | 缺 | A |
| 8-09 | server/Mgr/MgrInteract.lua、common/GameCfg.lua | tests/native/feed_exchange_test.lua、tests/native/exchange_zones_127_test.lua | 缺 | 缺 | 缺 | 缺 | A |
| 8-10 | common/GameCfg.lua、common/ContentValidation.lua | tests/native/feed_exchange_test.lua、tests/native/exchange_zones_127_test.lua | 缺 | 缺 | 缺 | 缺 | A |
| 8-11 | server/Mgr/MgrFerry.lua | tests/native/ferry_test.lua、tests/native/ferry_ui_test.lua | 缺 | 缺 | 缺 | 缺 | A |
| 8-12 | server/Mgr/MgrFerry.lua | tests/native/ferry_test.lua、tests/native/ferry_ui_test.lua | 缺 | 缺 | 缺 | 缺 | A |
| 8-13 | server/Mgr/MgrFerry.lua | tests/native/ferry_test.lua、tests/native/ferry_ui_test.lua | 缺 | 缺 | 缺 | 缺 | A |
| 8-14 | common/GameCfg.lua、server/Mgr/MgrFerry.lua | tests/native/ferry_test.lua、tests/native/ferry_ui_test.lua | 缺 | 缺 | 缺 | 缺 | A |
| 8-15 | server/Mgr/MgrFerry.lua | tests/native/ferry_test.lua、tests/native/ferry_ui_test.lua | 缺 | 缺 | 缺 | 缺 | A |
| 8-16 | server/Mgr/MgrFerry.lua | tests/native/ferry_test.lua、tests/native/ferry_ui_test.lua | 缺 | 缺 | 缺 | 缺 | A |
| 8-17 | common/NpcDialogue.lua、client/ScreenHandlers/ScreenFerry.lua | tests/native/ferry_test.lua、tests/native/ferry_ui_test.lua | 缺 | 缺 | 缺 | 缺 | A |
| 8-18 | server/Mgr/MgrLoot.lua、server/Mgr/MgrFishCarrier.lua | tests/native/loot_drop_test.lua | 缺 | 缺 | 缺 | 缺 | A |
| 8-19 | server/Mgr/MgrLoot.lua、client/LocalLoot.lua | tests/native/loot_client_test.lua | 缺 | 缺 | 缺 | 缺 | A |
| 8-20 | server/Mgr/MgrLoot.lua、server/Data/PlayerData.lua | tests/native/loot_drop_test.lua | 缺 | 缺 | 缺 | 缺 | A |
| 8-21 | server/Mgr/MgrLoot.lua、common/GameCfg.lua | tests/native/loot_recycle_test.lua | 缺 | 缺 | 缺 | 缺 | A |
| 8-22 | server/Mgr/MgrLoot.lua、common/GameCfg.lua | tests/native/loot_recycle_test.lua | 缺 | 缺 | 缺 | 缺 | A |
| 8-23 | server/Mgr/MgrLoot.lua、common/GameCfg.lua | tests/native/loot_recycle_test.lua | 缺 | 缺 | 缺 | 缺 | A |
| 8-24 | common/GameCfg.lua、server/Mgr/MgrLoot.lua、common/ZoneMarkers.lua | tests/native/bait_spot_test.lua | 缺 | 缺 | 缺 | 缺 | A |
| 8-25 | common/GameCfg.lua、server/Mgr/MgrCast.lua | tests/native/bait_spot_test.lua | 缺 | 缺 | 缺 | 缺 | A |
| 8-26 | server/Mgr/MgrInteract.lua、server/Mgr/MgrSave.lua | tests/native/economy_persistence_test.lua、tests/native/feed_exchange_test.lua | 缺 | 缺 | 缺 | 缺 | B |
| 8-27 | server/Mgr/MgrInteract.lua、server/Mgr/MgrSave.lua | tests/native/economy_persistence_test.lua、tests/native/feed_exchange_test.lua | 缺 | 缺 | 缺 | 缺 | B |
| 8-28 | server/Mgr/MgrFerry.lua | tests/native/ferry_test.lua | 缺 | 缺 | 缺 | 缺 | B |
| 8-29 | server/Mgr/MgrFerry.lua | tests/native/ferry_test.lua | 缺 | 缺 | 缺 | 缺 | B |
| 8-30 | server/Mgr/MgrFerry.lua、server/Data/PlayerData.lua | tests/native/ferry_test.lua | 缺 | 缺 | 缺 | 缺 | B |
| 8-31 | server/Mgr/MgrFerry.lua | tests/native/ferry_test.lua | 缺 | 缺 | 缺 | 缺 | B |
| 8-32 | server/Mgr/MgrFerry.lua | tests/native/ferry_test.lua | 缺 | 缺 | 缺 | 缺 | B |
| 8-33 | server/Mgr/MgrFerry.lua、server/Mgr/MgrSave.lua | tests/native/ferry_test.lua | 缺 | 缺 | 缺 | 缺 | B |
| 8-34 | server/Mgr/MgrLoot.lua、common/GameCfg.lua | tests/native/loot_recycle_test.lua | 缺 | 缺 | 缺 | 缺 | B |

返程票价由 GameCfg.Ferry.Routes 按区号生成（10×3^(区号−2)），兑换表在 GameCfg.Content.Exchanges；掉落预算与回收在 MgrLoot。

### 第 9 节 多人规则（25 条，其中 9-23～9-25 是 C 级试玩条款）

| 条款 | 代码落点 | 关联测试 | 正常流程 | 失败流程 | 退出重进 | 存档恢复 | 等级 |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 9-01 | server/Mgr/MgrVitals.lua、server/Mgr/MgrPkFilter.lua、server/main.lua | tests/native/spec/09_pk_damage_filter_test.lua | 有 | 有 | 缺 | 缺 | B |
| 9-02 | server/Mgr/MgrParty.lua、server/main.lua | tests/native/spec/09_party_authority_test.lua | 缺 | 有 | 缺 | 缺 | A |
| 9-03 | server/Mgr/MgrSurvival.lua、server/Mgr/MgrVitals.lua、server/Mgr/MgrInteract.lua | tests/native/spec/09_rescue_test.lua | 缺 | 有 | 缺 | 缺 | B |
| 9-04 | server/Mgr/MgrFishUnit.lua、server/Mgr/MgrLoot.lua、server/Mgr/MgrFerry.lua | tests/native/fish_lift_test.lua、tests/native/ferry_test.lua | 缺 | 缺 | 缺 | 缺 | B |
| 9-05 | server/Mgr/MgrSurvival.lua、server/Mgr/MgrSave.lua、server/Mgr/MgrInteract.lua | tests/native/spec/09_rescue_test.lua | 有 | 有 | 有 | 缺 | B |
| 9-06 | server/Mgr/MgrParty.lua、common/GameCfg.lua | tests/native/spec/09_party_authority_test.lua | 有 | 有 | 缺 | 缺 | A |
| 9-07 | server/Mgr/MgrParty.lua、common/GameCfg.lua | tests/native/spec/09_party_authority_test.lua | 有 | 有 | 缺 | 缺 | A |
| 9-08 | server/Mgr/MgrParty.lua、common/GameCfg.lua | tests/native/spec/09_party_authority_test.lua | 有 | 有 | 缺 | 缺 | B |
| 9-09 | server/Mgr/MgrParty.lua、common/GameCfg.lua | tests/native/spec/09_party_authority_test.lua | 有 | 缺 | 有 | 缺 | B |
| 9-10 | server/Mgr/MgrParty.lua、common/GameCfg.lua | tests/native/spec/09_party_authority_test.lua | 有 | 缺 | 有 | 缺 | A |
| 9-11 | server/Mgr/MgrParty.lua、common/GameCfg.lua | tests/native/spec/09_party_authority_test.lua | 有 | 缺 | 缺 | 缺 | A |
| 9-12 | server/Mgr/MgrVitals.lua、server/Mgr/MgrPkFilter.lua、server/main.lua | tests/native/spec/09_pk_damage_filter_test.lua | 有 | 有 | 缺 | 缺 | A |
| 9-13 | server/Mgr/MgrVitals.lua、server/Mgr/MgrPkFilter.lua、common/ZoneMarkers.lua | tests/native/spec/09_pk_damage_filter_test.lua | 有 | 有 | 缺 | 缺 | A |
| 9-14 | server/Mgr/MgrVitals.lua、server/Mgr/MgrPkFilter.lua、common/ZoneMarkers.lua | tests/native/spec/09_pk_damage_filter_test.lua | 有 | 有 | 缺 | 缺 | A |
| 9-15 | server/Mgr/MgrVitals.lua、server/Mgr/MgrPkFilter.lua | tests/native/spec/09_pk_damage_filter_test.lua | 有 | 缺 | 缺 | 缺 | A |
| 9-16 | server/Mgr/MgrVitals.lua、server/Mgr/MgrPkFilter.lua、server/Mgr/MgrFishUnit.lua | tests/native/spec/09_pk_damage_filter_test.lua | 有 | 有 | 缺 | 缺 | A |
| 9-17 | server/Mgr/MgrInteract.lua、server/Mgr/MgrSurvival.lua、client/LocalInteract.lua | tests/native/spec/09_rescue_test.lua | 有 | 有 | 缺 | 缺 | A |
| 9-18 | server/Mgr/MgrSurvival.lua、server/Mgr/MgrVitals.lua、common/GameCfg.lua | tests/native/spec/09_rescue_test.lua | 有 | 缺 | 缺 | 缺 | A |
| 9-19 | server/Mgr/MgrParty.lua、common/GameCfg.lua、client/ScreenHandlers/ScreenParty.lua | tests/native/spec/09_party_authority_test.lua、tests/native/spec/09_party_hud_test.lua | 有 | 有 | 缺 | 缺 | A |
| 9-20 | client/ScreenHandlers/ScreenParty.lua、client/MgrGameUI.lua、server/Mgr/MgrParty.lua | tests/native/spec/09_party_hud_test.lua | 有 | 有 | 缺 | 缺 | A |
| 9-21 | client/ScreenHandlers/ScreenParty.lua、server/Mgr/MgrParty.lua | tests/native/spec/09_party_hud_test.lua | 有 | 有 | 缺 | 缺 | A |
| 9-22 | server/Mgr/MgrParty.lua、server/Data/PlayerData.lua、server/Mgr/MgrSave.lua | tests/native/spec/09_party_authority_test.lua | 缺 | 缺 | 有 | 有 | B |

第 9 节由小队子单先贯通：9-02、9-06～9-11、9-19～9-22 的代码落点是 `server/Mgr/MgrParty.lua`（服务端唯一权威的归属与名单）
与 `client/ScreenHandlers/ScreenParty.lua`（队友血量与邀请倒计时），证据是两份 spec 断言。
9-01、9-12～9-16 经统一伤害入口与 PK 过滤接缝落地，spec 断言覆盖同队全武器免伤、鱼塘豁免、鱼塘外 PK、人数不足与鱼攻击；9-03、9-17、9-18 已由抢救子单取证。
三者共用同一份矩阵小节，因此本表一次登记到位，四类证据只勾已经真取到的那几栏。

### 第 10 节 烧烤（25 条）

| 条款 | 代码落点 | 关联测试 | 正常流程 | 失败流程 | 退出重进 | 存档恢复 | 等级 |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 10-01 | common/GameCfg.lua、common/ZoneMarkers.lua | tests/native/grill_test.lua | 缺 | 缺 | 缺 | 缺 | A |
| 10-02 | server/Mgr/MgrGrill.lua | tests/native/grill_test.lua | 缺 | 缺 | 缺 | 缺 | A |
| 10-03 | server/Mgr/MgrGrill.lua | tests/native/grill_test.lua、tests/native/spec/10_grill_curve_test.lua | 缺 | 有 | 缺 | 缺 | A |
| 10-04 | server/Mgr/MgrGrill.lua | tests/native/grill_test.lua | 缺 | 缺 | 缺 | 缺 | A |
| 10-05 | server/Mgr/MgrGrill.lua | tests/native/grill_test.lua | 缺 | 缺 | 缺 | 缺 | A |
| 10-06 | common/GrillCurve.lua、common/GameCfg.lua | tests/native/grill_test.lua、tests/native/spec/10_grill_curve_test.lua | 有 | 缺 | 缺 | 缺 | A |
| 10-07 | common/GrillCurve.lua、common/GameCfg.lua | tests/native/grill_test.lua、tests/native/spec/10_grill_curve_test.lua | 有 | 缺 | 缺 | 缺 | A |
| 10-08 | common/GrillCurve.lua、common/GameCfg.lua | tests/native/grill_test.lua、tests/native/spec/10_grill_curve_test.lua | 有 | 缺 | 缺 | 缺 | A |
| 10-09 | client/ScreenHandlers/ScreenGrill.lua、common/GrillCurve.lua | tests/native/grill_test.lua | 缺 | 缺 | 缺 | 缺 | A |
| 10-10 | server/Mgr/MgrGrill.lua、common/GrillCurve.lua | tests/native/grill_test.lua、tests/native/spec/10_grill_curve_test.lua | 有 | 缺 | 缺 | 缺 | A |
| 10-11 | server/Mgr/MgrGrill.lua、common/GrillCurve.lua | tests/native/grill_test.lua、tests/native/spec/10_grill_curve_test.lua | 缺 | 有 | 缺 | 缺 | A |
| 10-12 | server/Mgr/MgrGrill.lua、server/Mgr/MgrVitals.lua | tests/native/grill_test.lua、tests/native/spec/10_grill_curve_test.lua | 缺 | 有 | 缺 | 缺 | A |
| 10-13 | client/ScreenHandlers/ScreenGrill.lua、server/Mgr/MgrGrill.lua | tests/native/grill_test.lua、tests/native/spec/10_grill_curve_test.lua | 缺 | 有 | 缺 | 缺 | A |
| 10-14 | server/Mgr/MgrGrill.lua | tests/native/grill_test.lua、tests/native/spec/10_grill_curve_test.lua | 有 | 缺 | 缺 | 缺 | A |
| 10-15 | server/Mgr/MgrGrill.lua | tests/native/grill_test.lua、tests/native/spec/10_grill_curve_test.lua | 缺 | 有 | 缺 | 缺 | A |
| 10-16 | server/Mgr/MgrLottery.lua、common/LotteryEligibility.lua | tests/native/lottery_eligibility_test.lua、tests/native/grill_test.lua | 缺 | 缺 | 缺 | 缺 | A |
| 10-17 | server/Mgr/MgrInteract.lua、server/Mgr/MgrGrill.lua | tests/native/feed_exchange_test.lua、tests/native/grill_test.lua | 缺 | 缺 | 缺 | 缺 | A |
| 10-18 | server/Mgr/MgrGrill.lua | tests/native/grill_test.lua | 缺 | 缺 | 缺 | 缺 | B |
| 10-19 | server/Mgr/MgrGrill.lua | tests/native/grill_test.lua | 缺 | 缺 | 缺 | 缺 | B |
| 10-20 | server/Mgr/MgrGrill.lua | tests/native/grill_test.lua | 缺 | 缺 | 缺 | 缺 | B |
| 10-21 | server/Mgr/MgrGrill.lua、server/Mgr/MgrSave.lua | tests/native/grill_test.lua | 缺 | 缺 | 缺 | 缺 | B |
| 10-22 | server/Mgr/MgrGrill.lua、server/Mgr/MgrSurvival.lua | tests/native/grill_test.lua | 缺 | 缺 | 缺 | 缺 | B |
| 10-23 | server/Mgr/MgrGrill.lua、server/Mgr/MgrSave.lua | tests/native/grill_test.lua | 缺 | 缺 | 缺 | 缺 | B |
| 10-24 | server/Mgr/MgrGrill.lua、server/Data/PlayerData.lua | tests/native/grill_test.lua | 缺 | 缺 | 缺 | 缺 | B |
| 10-25 | server/Mgr/MgrGrill.lua、server/Data/PlayerData.lua | tests/native/grill_test.lua | 缺 | 缺 | 缺 | 缺 | B |

倍率曲线是纯函数 common/GrillCurve.lua，计时由 MgrGrill 按 World:GetServerTime 的投入时长一次算出，不按帧累加。

### 第 12 节 精英与首领行为（48 条）

| 条款 | 代码落点 | 关联测试 | 正常流程 | 失败流程 | 退出重进 | 存档恢复 | 等级 |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 12-01 | common/cfg/BossMoves.lua、common/GameCfg.lua | tests/native/spec/12_boss_moves_test.lua | 有 | 缺 | 缺 | 缺 | A |
| 12-02 | common/cfg/BossMoves.lua | tests/native/spec/12_boss_moves_test.lua | 有 | 缺 | 缺 | 缺 | A |
| 12-03 | common/cfg/BossMoves.lua | tests/native/spec/12_boss_moves_test.lua | 有 | 缺 | 缺 | 缺 | A |
| 12-04 | common/cfg/BossMoves.lua、server/Mgr/MgrFishUnit.lua | tests/native/spec/12_boss_moves_test.lua | 有 | 缺 | 缺 | 缺 | A |
| 12-05 | common/cfg/BossMoves.lua | tests/native/spec/12_boss_moves_test.lua | 有 | 缺 | 缺 | 缺 | A |
| 12-06 | server/Mgr/MgrFishUnit.lua、common/GameCfg.lua | tests/native/boss_bait_test.lua | 缺 | 缺 | 缺 | 缺 | A |
| 12-07 | common/cfg/BossMoves.lua、common/GameCfg.lua、server/Mgr/MgrFishUnit.lua| tests/native/spec/12_boss_moves_melee_aoe_test.lua、tests/native/eel_combat_test.lua| 有| 缺 | 缺 | 缺 | A |
| 12-08 | common/cfg/BossMoves.lua、common/GameCfg.lua、server/Mgr/MgrFishUnit.lua、common/GarBiteNotice.lua| tests/native/spec/12_boss_moves_melee_aoe_test.lua、tests/native/gar_combat_test.lua| 有| 缺 | 缺 | 缺 | A |
| 12-09 | common/cfg/BossMoves.lua、server/Mgr/MgrFishUnit.lua| tests/native/spec/12_boss_moves_melee_aoe_test.lua、tests/native/gar_combat_test.lua| 有| 有| 缺 | 缺 | A |
| 12-10 | common/cfg/BossMoves.lua、common/GameCfg.lua、server/Mgr/MgrFishUnit.lua| tests/native/spec/12_boss_moves_melee_aoe_test.lua、tests/native/shrimp_combat_test.lua| 有| 缺 | 缺 | 缺 | A |
| 12-11 | common/cfg/BossMoves.lua、common/GameCfg.lua、server/Mgr/MgrFishUnit.lua| tests/native/spec/12_boss_moves_melee_aoe_test.lua、tests/native/shrimp_combat_test.lua| 有| 缺 | 缺 | 缺 | A |
| 12-12 | common/GameCfg.lua、server/Mgr/MgrFishUnit.lua | tests/native/shrimp_combat_test.lua | 缺 | 缺 | 缺 | 缺 | A |
| 12-13 | common/GameCfg.lua、server/Mgr/MgrFishUnit.lua | tests/native/shrimp_combat_test.lua | 缺 | 缺 | 缺 | 缺 | A |
| 12-14 | common/GameCfg.lua、server/Mgr/MgrFishUnit.lua | tests/native/shrimp_combat_test.lua | 缺 | 缺 | 缺 | 缺 | A |
| 12-15 | common/cfg/BossMoves.lua、common/GameCfg.lua、server/Mgr/MgrFishUnit.lua| tests/native/spec/12_boss_moves_melee_aoe_test.lua、tests/native/king_crab_combat_test.lua| 有| 缺 | 缺 | 缺 | A |
| 12-16 | common/cfg/BossMoves.lua、common/GameCfg.lua、server/Mgr/MgrFishUnit.lua| tests/native/spec/12_boss_moves_melee_aoe_test.lua、tests/native/king_crab_combat_test.lua| 有| 缺 | 缺 | 缺 | A |
| 12-17 | common/cfg/BossMoves.lua、common/GameCfg.lua、server/Mgr/MgrFishUnit.lua| tests/native/spec/12_boss_moves_melee_aoe_test.lua、tests/native/crab_boss_combat_test.lua| 有| 缺 | 缺 | 缺 | A |
| 12-18 | common/cfg/BossMoves.lua、common/GameCfg.lua、server/Mgr/MgrFishUnit.lua| tests/native/spec/12_boss_moves_melee_aoe_test.lua、tests/native/crab_boss_combat_test.lua| 有| 缺 | 缺 | 缺 | A |
| 12-19 | common/cfg/BossMoves.lua、common/GameCfg.lua、server/Mgr/MgrFishUnit.lua| tests/native/spec/12_boss_moves_melee_aoe_test.lua、tests/native/crab_boss_combat_test.lua| 有| 缺 | 缺 | 缺 | A |
| 12-20 | common/GameCfg.lua、server/Mgr/MgrFishUnit.lua | tests/native/forest_combat_test.lua | 缺 | 缺 | 缺 | 缺 | A |
| 12-21 | common/cfg/BossMoves.lua、common/GameCfg.lua、server/Mgr/MgrFishUnit.lua | tests/native/spec/12_boss_moves_ranged_dive_test.lua | 有 | 缺 | 缺 | 缺 | A |
| 12-22 | common/GameCfg.lua、server/Mgr/MgrFishUnit.lua | tests/native/forest_combat_test.lua | 缺 | 缺 | 缺 | 缺 | A |
| 12-23 | common/GameCfg.lua、server/Mgr/MgrFishUnit.lua | tests/native/forest_combat_test.lua | 缺 | 缺 | 缺 | 缺 | A |
| 12-24 | common/cfg/BossMoves.lua、common/GameCfg.lua、server/Mgr/MgrFishUnit.lua | tests/native/spec/12_boss_moves_ranged_dive_test.lua | 有 | 缺 | 缺 | 缺 | A |
| 12-25 | common/GameCfg.lua、server/Mgr/MgrFishUnit.lua | tests/native/beach_combat_test.lua | 缺 | 缺 | 缺 | 缺 | A |
| 12-26 | common/cfg/BossMoves.lua、common/GameCfg.lua、server/Mgr/MgrFishUnit.lua | tests/native/spec/12_boss_moves_ranged_dive_test.lua | 有 | 缺 | 缺 | 缺 | A |
| 12-27 | common/GameCfg.lua、server/Mgr/MgrFishUnit.lua | tests/native/beach_combat_test.lua | 缺 | 缺 | 缺 | 缺 | A |
| 12-28 | common/cfg/BossMoves.lua、common/GameCfg.lua、server/Mgr/MgrFishUnit.lua | tests/native/spec/12_boss_moves_ranged_dive_test.lua | 有 | 缺 | 缺 | 缺 | A |
| 12-29 | common/GameCfg.lua、server/Mgr/MgrFishUnit.lua | tests/native/beach_combat_test.lua | 缺 | 缺 | 缺 | 缺 | A |
| 12-30 | common/cfg/BossMoves.lua、common/GameCfg.lua、server/Mgr/MgrFishUnit.lua | tests/native/spec/12_boss_moves_ranged_dive_test.lua | 有 | 缺 | 缺 | 缺 | A |
| 12-31 | common/cfg/BossMoves.lua、common/GameCfg.lua、server/Mgr/MgrFishUnit.lua | tests/native/spec/12_boss_moves_ranged_dive_test.lua | 有 | 缺 | 缺 | 缺 | A |
| 12-32 | common/cfg/BossMoves.lua、common/GameCfg.lua、server/Mgr/MgrFishUnit.lua | tests/native/spec/12_boss_moves_ranged_dive_test.lua | 有 | 缺 | 缺 | 缺 | A |
| 12-33 | common/cfg/BossMoves.lua、common/GameCfg.lua、server/Mgr/MgrFishUnit.lua | tests/native/spec/12_boss_moves_ranged_dive_test.lua | 有 | 缺 | 缺 | 缺 | A |
| 12-34 | common/cfg/BossMoves.lua、common/GameCfg.lua、server/Mgr/MgrFishUnit.lua | tests/native/spec/12_boss_moves_ranged_dive_test.lua | 有 | 缺 | 缺 | 缺 | B |
| 12-35 | common/cfg/BossMoves.lua、server/Mgr/MgrFishUnit.lua | tests/native/spec/12_boss_moves_phase_test.lua | 有 | 缺 | 缺 | 缺 | A |
| 12-36 | common/cfg/BossMoves.lua、common/GameCfg.lua、server/Mgr/MgrFishUnit.lua | tests/native/spec/12_boss_moves_phase_test.lua | 有 | 缺 | 缺 | 缺 | A |
| 12-37 | common/cfg/BossMoves.lua、server/Mgr/MgrFishUnit.lua | tests/native/spec/12_boss_moves_phase_test.lua | 有 | 缺 | 缺 | 缺 | A |
| 12-38 | common/cfg/BossMoves.lua、common/GameCfg.lua、server/Mgr/MgrFishUnit.lua | tests/native/spec/12_boss_moves_phase_test.lua | 有 | 缺 | 缺 | 缺 | A |
| 12-39 | common/cfg/Fish.lua、common/cfg/BossMoves.lua | tests/native/spec/12_boss_moves_test.lua | 有 | 缺 | 缺 | 缺 | A |
| 12-40 | common/cfg/BossMoves.lua、common/BossPhase.lua | tests/native/spec/12_boss_moves_test.lua | 有 | 缺 | 缺 | 缺 | A |
| 12-41 | common/cfg/BossMoves.lua、server/Mgr/MgrFishUnit.lua | tests/native/spec/12_boss_moves_test.lua | 有 | 缺 | 缺 | 缺 | A |
| 12-42 | common/cfg/BossMoves.lua、server/Mgr/MgrFishUnit.lua | tests/native/spec/12_boss_moves_test.lua | 有 | 缺 | 缺 | 缺 | A |
| 12-43 | common/GameCfg.lua、common/BossPhase.lua、server/Mgr/MgrFishUnit.lua | tests/native/spec/12_boss_moves_test.lua | 有 | 缺 | 缺 | 缺 | A |
| 12-44 | common/GameCfg.lua、common/BossPhase.lua、server/Mgr/MgrFishUnit.lua | tests/native/spec/12_boss_moves_test.lua | 有 | 缺 | 缺 | 缺 | A |
| 12-45 | common/cfg/BossMoves.lua、common/GameCfg.lua、common/BossPhase.lua、server/Mgr/MgrFishUnit.lua | tests/native/spec/12_boss_moves_test.lua、tests/native/spec/12_boss_moves_phase_test.lua | 有 | 缺 | 缺 | 缺 | B |
| 12-46 | common/cfg/BossMoves.lua | tests/native/spec/12_boss_moves_test.lua | 有 | 缺 | 缺 | 缺 | A |
| 12-47 | common/GameCfg.lua、server/Mgr/MgrFishUnit.lua | — | 缺 | 缺 | 缺 | 缺 | A |
| 12-48 | common/GameCfg.lua | — | 缺 | 缺 | 缺 | 缺 | A |

第 12 节先建逐招表，再用火山岛首领哥斯拉贯通「配置 → 服务端调度 → 客户端预警 → 断言」：
12-04、12-05、12-39～12-46 已由 tests/native/spec/12_boss_moves_test.lua 走 MgrFishUnit 的业务入口取证；
其余条款的落点与关联测试都是实现自检，状态仍是 unverified。

远程与俯冲组（#258）另由 tests/native/spec/12_boss_moves_ranged_dive_test.lua 走同一业务入口取证：
小白龙雨云 / 俯冲、剑鱼与三头鲨高跃、海象直线突击、虎鲸虎啸 / 鲸跃、白头鹰俯冲、
风神翼龙投掷 / 追踪俯冲共 11 条（12-13、12-14、12-21、12-24、12-26、12-28、12-30、12-31～12-34）。
断言改逐招表哨兵值后观察服务端结算，证明表是唯一数值来源；预警载荷带落点、范围与投送方式，
伤害只由服务端在锁定落点结算，测试进程没有加载客户端命中代码。

阶段与复合组（#259）另有一组 A/B 证据：沧龙用逐招表的 patrol / leap / head / bite / contact 五行区分绕岛巡航、命中段与叼走过程接触段，哥斯拉的阶段阈值单独放在 `M.Phases`（普通招式表仍是 `M.Rows`），由 tests/native/spec/12_boss_moves_phase_test.lua 走 MgrFishUnit 的业务入口断言移速上限、砸击/甩头、最近岛中心目标、叼走入海、两段伤害与同帧阈值优先；四类证据只勾「正常流程」，失败 / 退出重进 / 存档恢复仍缺。

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

### 第 14 节 抽奖机（23 条）

| 条款 | 代码落点 | 关联测试 | 正常流程 | 失败流程 | 退出重进 | 存档恢复 | 等级 |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 14-01 | common/GameCfg.lua、server/Mgr/MgrLottery.lua | tests/native/lottery_settle_test.lua、tests/native/lottery_draw_test.lua | 缺 | 缺 | 缺 | 缺 | A |
| 14-02 | common/LotteryEligibility.lua、server/Mgr/MgrLottery.lua | tests/native/lottery_eligibility_test.lua、tests/native/lottery_ui_test.lua | 缺 | 缺 | 缺 | 缺 | A |
| 14-03 | common/LotteryDraw.lua、common/cfg/Lottery.lua | tests/native/lottery_settle_test.lua、tests/native/lottery_draw_test.lua、tests/native/spec/14_lottery_rules_test.lua | 有 | 缺 | 缺 | 缺 | A |
| 14-04 | common/LotteryDraw.lua、server/Mgr/MgrLottery.lua | tests/native/lottery_settle_test.lua、tests/native/lottery_draw_test.lua、tests/native/spec/14_lottery_rules_test.lua | 有 | 缺 | 缺 | 缺 | A |
| 14-05 | common/LotteryDraw.lua、server/Mgr/MgrLottery.lua | tests/native/lottery_settle_test.lua、tests/native/lottery_draw_test.lua、tests/native/spec/14_lottery_rules_test.lua | 有 | 缺 | 缺 | 缺 | A |
| 14-06 | common/LotteryDraw.lua、common/cfg/Lottery.lua | tests/native/lottery_settle_test.lua、tests/native/lottery_draw_test.lua、tests/native/spec/14_lottery_rules_test.lua | 有 | 缺 | 缺 | 缺 | A |
| 14-07 | common/cfg/Lottery.lua、common/LotteryDraw.lua | tests/native/lottery_settle_test.lua、tests/native/lottery_draw_test.lua | 缺 | 缺 | 缺 | 缺 | A |
| 14-08 | common/cfg/Lottery.lua、common/LotteryDraw.lua | tests/native/lottery_settle_test.lua、tests/native/lottery_draw_test.lua | 缺 | 缺 | 缺 | 缺 | A |
| 14-09 | common/LotteryDraw.lua、server/Mgr/MgrLottery.lua | tests/native/lottery_settle_test.lua、tests/native/lottery_draw_test.lua、tests/native/spec/14_lottery_rules_test.lua | 有 | 缺 | 缺 | 缺 | A |
| 14-10 | common/LotteryDraw.lua、server/Mgr/MgrLottery.lua | tests/native/lottery_settle_test.lua、tests/native/lottery_draw_test.lua、tests/native/spec/14_lottery_rules_test.lua | 有 | 缺 | 缺 | 缺 | A |
| 14-11 | common/GameCfg.lua、client/ScreenHandlers/ScreenLottery.lua | tests/native/lottery_local_test.lua、tests/native/lottery_ui_test.lua | 缺 | 缺 | 缺 | 缺 | A |
| 14-12 | server/Mgr/MgrLottery.lua、server/Mgr/MgrSave.lua | tests/native/lottery_settle_test.lua | 缺 | 缺 | 缺 | 缺 | B |
| 14-13 | server/Mgr/MgrLottery.lua | tests/native/lottery_settle_test.lua、tests/native/lottery_draw_test.lua、tests/native/spec/14_lottery_rules_test.lua | 有 | 缺 | 缺 | 缺 | A |
| 14-14 | server/Mgr/MgrLottery.lua、server/Data/PlayerData.lua | tests/native/lottery_settle_test.lua、tests/native/lottery_ui_test.lua | 缺 | 缺 | 缺 | 缺 | B |
| 14-15 | server/Mgr/MgrLottery.lua、server/Data/PlayerData.lua | tests/native/lottery_settle_test.lua、tests/native/lottery_draw_test.lua、tests/native/spec/14_lottery_rules_test.lua | 有 | 缺 | 缺 | 缺 | A |
| 14-16 | client/ScreenHandlers/ScreenLottery.lua | tests/native/lottery_eligibility_test.lua、tests/native/lottery_ui_test.lua | 缺 | 缺 | 缺 | 缺 | A |
| 14-17 | server/Mgr/MgrLottery.lua、server/Mgr/MgrSave.lua | tests/native/lottery_settle_test.lua | 缺 | 缺 | 缺 | 缺 | B |
| 14-18 | server/Mgr/MgrLottery.lua、server/Mgr/MgrSave.lua | tests/native/lottery_settle_test.lua | 缺 | 缺 | 缺 | 缺 | B |
| 14-19 | server/Mgr/MgrLottery.lua、server/Mgr/MgrSave.lua | tests/native/lottery_settle_test.lua | 缺 | 缺 | 缺 | 缺 | B |
| 14-20 | common/SpecialItem.lua、server/Mgr/MgrSpecialItem.lua | tests/native/special_item_mgr_test.lua | 缺 | 缺 | 缺 | 缺 | A |
| 14-21 | common/SpecialItem.lua、common/FlightPath.lua | tests/native/special_item_mgr_test.lua | 缺 | 缺 | 缺 | 缺 | A |
| 14-22 | common/SpecialItem.lua、server/Mgr/MgrSpecialItem.lua | tests/native/special_item_mgr_test.lua | 缺 | 缺 | 缺 | 缺 | A |
| 14-23 | common/SpecialItem.lua、common/BossPhase.lua | tests/native/special_item_mgr_test.lua | 缺 | 缺 | 缺 | 缺 | B |

图案权重与两同倍数在 common/cfg/Lottery.lua，抽样与判奖在 common/LotteryDraw.lua，扣物发奖与落位在 MgrLottery。

### 第 15 节 地图盲盒（18 条）

| 条款 | 代码落点 | 关联测试 | 正常流程 | 失败流程 | 退出重进 | 存档恢复 | 等级 |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 15-01 | common/GameCfg.lua、server/Mgr/MgrBlindbox.lua | tests/native/spec/15_blindbox_placeholder_settlement_test.lua | 有 | 缺 | 缺 | 缺 | A |
| 15-02 | common/GameCfg.lua、server/Mgr/MgrBlindbox.lua | tests/native/blindbox_draw_test.lua | 缺 | 缺 | 缺 | 缺 | A |
| 15-03 | common/BlindboxDraw.lua、common/GameCfg.lua | tests/native/blindbox_draw_test.lua | 缺 | 缺 | 缺 | 缺 | A |
| 15-04 | server/Data/PlayerData.lua、server/Mgr/MgrBlindbox.lua | tests/native/blindbox_settle_test.lua | 缺 | 缺 | 缺 | 缺 | A |
| 15-05 | server/Mgr/MgrLoot.lua、server/Mgr/MgrBlindbox.lua | tests/native/blindbox_settle_test.lua | 缺 | 有 | 缺 | 缺 | A |
| 15-06 | server/Mgr/MgrLoot.lua | tests/native/loot_drop_test.lua | 缺 | 缺 | 缺 | 缺 | A |
| 15-07 | server/Mgr/MgrBlindbox.lua、client/ScreenHandlers/ScreenBlindbox.lua | tests/native/platform_screens_test.lua | 缺 | 缺 | 缺 | 缺 | A |
| 15-08 | server/Data/PlayerData.lua | tests/native/blindbox_settle_test.lua | 缺 | 有 | 缺 | 缺 | B |
| 15-09 | common/BlindboxDraw.lua、common/GameCfg.lua | tests/native/spec/15_blindbox_placeholder_settlement_test.lua、tests/native/blindbox_draw_test.lua | 有 | 缺 | 缺 | 缺 | A |
| 15-10 | common/BlindboxDraw.lua、common/GameCfg.lua | tests/native/spec/15_blindbox_placeholder_settlement_test.lua | 有 | 缺 | 缺 | 缺 | A |
| 15-11 | common/BlindboxDraw.lua、common/GameCfg.lua | tests/native/spec/15_blindbox_placeholder_settlement_test.lua | 有 | 缺 | 缺 | 缺 | A |
| 15-12 | server/Mgr/MgrBlindbox.lua、server/Mgr/MgrSave.lua | tests/native/blindbox_settle_test.lua | 缺 | 缺 | 缺 | 缺 | B |
| 15-13 | common/GameCfg.lua、common/BlindboxDraw.lua | tests/native/blindbox_draw_test.lua、tests/native/cfg_shop_lottery_test.lua | 缺 | 缺 | 缺 | 缺 | A |
| 15-14 | common/GameCfg.lua、common/BlindboxDraw.lua | tests/native/blindbox_draw_test.lua | 缺 | 缺 | 缺 | 缺 | A |
| 15-15 | server/Mgr/MgrBlindbox.lua、server/Mgr/MgrSave.lua | tests/native/blindbox_settle_test.lua | 缺 | 缺 | 有 | 缺 | B |
| 15-16 | server/Mgr/MgrBlindbox.lua、server/Mgr/MgrLoot.lua | tests/native/blindbox_settle_test.lua | 缺 | 缺 | 缺 | 有 | B |
| 15-17 | common/GameCfg.lua、server/Mgr/MgrBlindbox.lua | tests/native/content_validation_test.lua | 缺 | 缺 | 缺 | 缺 | A |
| 15-21 | common/GameCfg.lua、server/Mgr/MgrPlatform.lua、client/ScreenHandlers/ScreenPlatform.lua | tests/native/spec/15_blindbox_placeholder_settlement_test.lua | 有 | 有 | 缺 | 缺 | A |

第 15 节的 15-01、15-09～15-11、15-21 已由占位支付通道的公开入口取证（价目 10 / 90 金豆同一通道收费、
确认前不发奖、取消与超时不到账、第 50 抽强制保底、大奖清零计数）。15-21 原挂 C 级试玩口径，
按 ADR-0029 生产开关把「占位通道」判给 agent，真实平台支付通道作为生产开关单列。

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

### 第 11 节 濒死、死亡与复活（39 条非试玩条款）

| 条款 | 代码落点 | 关联测试 | 正常流程 | 失败流程 | 退出重进 | 存档恢复 | 等级 |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 11-01 | server/Mgr/MgrVitals.lua、server/Mgr/MgrSurvival.lua | tests/native/spec/09_rescue_test.lua | 有 | 缺 | 缺 | 缺 | A |
| 11-02 | server/Mgr/MgrSurvival.lua、client/ScreenHandlers/ScreenSurvival.lua | tests/native/survival_test.lua | 缺 | 缺 | 缺 | 缺 | A |
| 11-03 | server/Mgr/MgrVitals.lua、server/Mgr/MgrSurvival.lua | tests/native/spec/09_rescue_test.lua | 缺 | 有 | 缺 | 缺 | A |
| 11-04 | common/GameCfg.lua、server/Mgr/MgrSurvival.lua | tests/native/survival_test.lua | 缺 | 缺 | 缺 | 缺 | A |
| 11-05 | server/Mgr/MgrVitals.lua、server/Mgr/MgrSurvival.lua | tests/native/survival_test.lua | 缺 | 缺 | 缺 | 缺 | A |
| 11-06 | server/Mgr/MgrSurvival.lua、common/GameCfg.lua | tests/native/spec/09_rescue_test.lua | 有 | 缺 | 缺 | 缺 | A |
| 11-07 | server/Mgr/MgrSurvival.lua、server/Mgr/MgrPlayerData.lua | tests/native/survival_test.lua | 缺 | 缺 | 缺 | 缺 | A |
| 11-08 | client/ScreenHandlers/ScreenSurvival.lua、server/Mgr/MgrPlatform.lua | tests/native/platform_screens_test.lua | 缺 | 缺 | 缺 | 缺 | A |
| 11-09 | client/ScreenHandlers/ScreenSurvival.lua、server/Mgr/MgrSurvival.lua | tests/native/survival_test.lua | 缺 | 缺 | 缺 | 缺 | A |
| 11-10 | server/Mgr/MgrSurvival.lua、common/GameCfg.lua | tests/native/survival_test.lua | 缺 | 缺 | 缺 | 缺 | A |
| 11-11 | server/Mgr/MgrSurvival.lua、common/GameCfg.lua | tests/native/survival_test.lua | 缺 | 缺 | 缺 | 缺 | A |
| 11-12 | server/Mgr/MgrSurvival.lua、server/Mgr/MgrVitals.lua、common/GameCfg.lua | tests/native/survival_test.lua | 缺 | 缺 | 缺 | 缺 | A |
| 11-13 | server/Mgr/MgrSurvival.lua、server/Mgr/MgrVitals.lua、common/GameCfg.lua | tests/native/survival_test.lua | 缺 | 缺 | 缺 | 缺 | A |
| 11-14 | server/Mgr/MgrSurvival.lua、server/Mgr/MgrModifier.lua、common/GameCfg.lua | tests/native/survival_test.lua | 缺 | 缺 | 缺 | 缺 | A |
| 11-15 | server/Mgr/MgrVitals.lua、server/Mgr/MgrSurvival.lua | tests/native/survival_test.lua | 缺 | 缺 | 缺 | 缺 | A |
| 11-16 | server/Mgr/MgrPlayerData.lua、server/Mgr/MgrSave.lua、server/Mgr/MgrSurvival.lua | tests/native/spec/18_session_settlement_contract_test.lua | 缺 | 缺 | 缺 | 有 | A |
| 11-17 | server/Mgr/MgrReelIn.lua、server/Mgr/MgrFishUnit.lua、server/Mgr/MgrSurvival.lua | tests/native/fish_lift_test.lua | 缺 | 缺 | 缺 | 缺 | A |
| 11-18 | server/Mgr/MgrFishCarrier.lua、server/Mgr/MgrFishUnit.lua、server/Mgr/MgrSurvival.lua | tests/native/fish_lift_test.lua | 缺 | 缺 | 缺 | 缺 | A |
| 11-19 | client/ScreenHandlers/ScreenSurvival.lua、server/Mgr/MgrSurvival.lua、server/Mgr/MgrPlatform.lua、common/GameCfg.lua | tests/native/spec/11_ad_revive_placeholder_test.lua | 有 | 有 | 缺 | 缺 | A |
| 11-20 | client/ScreenHandlers/ScreenSurvival.lua、server/Mgr/MgrPlatform.lua、server/Mgr/MgrShop.lua | tests/native/platform_screens_test.lua | 缺 | 缺 | 缺 | 缺 | A |
| 11-21 | server/Mgr/MgrSurvival.lua、server/Mgr/MgrVitals.lua、common/GameCfg.lua | tests/native/spec/11_ad_revive_placeholder_test.lua | 有 | 缺 | 缺 | 缺 | A |
| 11-22 | server/Mgr/MgrSurvival.lua、server/Mgr/MgrModifier.lua | tests/native/spec/11_ad_revive_placeholder_test.lua | 有 | 缺 | 缺 | 缺 | A |
| 11-23 | common/cfg/Shop.lua、server/Mgr/MgrShop.lua | tests/native/shop_test.lua | 缺 | 缺 | 缺 | 缺 | A |
| 11-24 | common/cfg/Shop.lua、server/Mgr/MgrShop.lua | tests/native/shop_test.lua | 缺 | 缺 | 缺 | 缺 | A |
| 11-25 | server/Mgr/MgrSurvival.lua、server/Mgr/MgrSave.lua、server/Data/PlayerData.lua | tests/native/spec/09_rescue_test.lua | 缺 | 缺 | 有 | 有 | A |
| 11-26 | server/Mgr/MgrFerry.lua、server/Mgr/MgrSurvival.lua、server/Data/PlayerData.lua | tests/native/spec/18_session_settlement_contract_test.lua | 缺 | 缺 | 有 | 有 | A |
| 11-27 | server/Mgr/MgrSurvival.lua、server/Mgr/MgrModifier.lua、server/Data/PlayerData.lua | tests/native/survival_test.lua | 缺 | 缺 | 有 | 有 | A |
| 11-28 | server/Mgr/MgrSurvival.lua、server/Mgr/MgrPlatform.lua | tests/native/spec/11_ad_revive_placeholder_test.lua | 有 | 有 | 缺 | 缺 | B |
| 11-29 | server/Mgr/MgrSurvival.lua、server/Mgr/MgrPlatform.lua、common/GameCfg.lua | tests/native/spec/11_ad_revive_placeholder_test.lua | 有 | 有 | 缺 | 缺 | B |
| 11-30 | server/Mgr/MgrSurvival.lua、server/Mgr/MgrPlatform.lua | tests/native/spec/11_ad_revive_placeholder_test.lua | 有 | 有 | 缺 | 缺 | B |
| 11-31 | server/Mgr/MgrPlatform.lua、server/Mgr/MgrSurvival.lua、common/GameCfg.lua | tests/native/spec/11_ad_revive_placeholder_test.lua | 有 | 有 | 缺 | 缺 | B |
| 11-32 | server/Mgr/MgrSurvival.lua、server/Mgr/MgrPlatform.lua、common/RateLimit.lua | tests/native/spec/11_ad_revive_placeholder_test.lua | 有 | 有 | 缺 | 缺 | B |
| 11-33 | server/Mgr/MgrSurvival.lua、server/Mgr/MgrPlatform.lua | tests/native/revive_callback_test.lua | 缺 | 缺 | 缺 | 缺 | B |
| 11-34 | server/Mgr/MgrVitals.lua、server/Mgr/MgrSurvival.lua、common/GameCfg.lua | tests/native/spec/09_rescue_test.lua | 缺 | 有 | 缺 | 缺 | B |
| 11-35 | server/Mgr/MgrSurvival.lua、server/Mgr/MgrSave.lua、server/Data/PlayerData.lua | tests/native/spec/09_rescue_test.lua | 缺 | 缺 | 有 | 有 | B |
| 11-36 | server/Mgr/MgrVitals.lua、server/Mgr/MgrSurvival.lua | tests/native/spec/09_rescue_test.lua | 有 | 缺 | 缺 | 缺 | B |
| 11-37 | server/Mgr/MgrPlatform.lua、server/Mgr/MgrSurvival.lua、common/GameCfg.lua | tests/native/spec/11_ad_revive_placeholder_test.lua | 有 | 有 | 缺 | 缺 | B |
| 11-38 | server/Mgr/MgrPlatform.lua、common/GameCfg.lua | tests/native/spec/11_ad_revive_placeholder_test.lua | 有 | 有 | 缺 | 缺 | A |
| 11-39 | server/Mgr/MgrPlatform.lua、server/Mgr/MgrSave.lua、common/GameCfg.lua | tests/native/platform_seam_test.lua | 缺 | 有 | 缺 | 缺 | A |

第 11 节由 #254 抢救子单整节登记：11-01、11-03、11-06、11-34、11-35、11-36 的证据走 `tests/native/spec/09_rescue_test.lua`
（致命伤害锁血、濒死免伤、呼救、其它伤害来源豁免、断线重连结算与血量夹取）；其余条款的代码落点与关联测试是实现自检，
状态仍是 unverified，等各自实现与断言。抢救耗时与打断规则的占位值集中在 `common/GameCfg.lua` 的 `GameCfg.Rescue`，
带 [未查证] 标记，待决题见 docs/to-questionnaire-策划案内部矛盾.md。

广告满血复活一组由 #262 登记：11-19、11-21、11-22、11-28～11-32、11-37、11-38 的证据统一走
`tests/native/spec/11_ad_revive_placeholder_test.lua`（濒死与死亡两个界面的广告入口、满血与饥饿下限、
倒计时暂停与平移、三条复活路径互斥、失败不扣费、重复点击与迟到回调、适配层成功与失败两条路径）。
占位广告位与广告文案集中在 `common/GameCfg.lua` 的 `GameCfg.Platform.Placeholder.Ads`、`GameCfg.Platform.Ads`
与 `GameCfg.Survival.AdReviveText`；真实广告位到位只替换那两处参数，判定不动，参数缺口记在
docs/to-questionnaire-策划案内部矛盾.md。金豆入口（11-20）、迟到回调补发（11-33）与占位对称结算（11-39）不归本单，
仍是 unverified，四类证据列只勾该断言真正跑过的场景。

## 三、待登记小节

第 19 节尚未登记。按依赖顺序逐节扩大，每节登记时同时补齐该节的代码落点与既有测试，
并把该节加进 `tools/acceptance.lua` 的 `M.COVERAGE_SECTIONS`；第 11 节已登记完毕（#254 抢救组整节 + #262 广告复活组）。
