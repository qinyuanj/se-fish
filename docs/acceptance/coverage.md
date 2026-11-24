# 实现覆盖表

> 本文件把每条条款接到它的**代码落点**、**关联测试**、**四类证据**与**证据等级**，是《渔力全开》「玩法实现」的台账。
> 口径见 [ADR-0029](../adr/0029-scope-completeness-and-placeholder-first.md) 第五节；静态校验在 `tools/acceptance.lua`，随 `lua tools/cli.lua acceptance --check` 与 fast 车道运行，空落点即判红。
> **Coverage / 实现覆盖表**：_Avoid_: 覆盖率表、实现清单、coverage report

## 一、字段

| 列 | 允许值 | 写法 |
| --- | --- | --- |
| 条款 | 验收矩阵里存在的条款 ID | 如 `1-12` |
| 代码落点 | 至少一个仓库相对路径，用顿号分隔；每个都必须是真实存在的文件 | `server/platform_host.lua` |
| 关联测试 | 仓库相对路径（顿号分隔）或 `—`；写了路径就必须真实存在 | `tests/native/platform_seam_test.lua` |
| 正常流程 / 失败流程 / 退出重进 / 存档恢复 | 只有 `有` 与 `缺` 两个取值（四类证据见 [ADR-0028](../adr/0028-solo-clear-on-shared-world.md)） | `缺` |
| 等级 | `a`、`b`、`C`，必须与矩阵里那条的证据等级一致 | `a` |

**关联测试是实现自检，不是条款证据。** 它只说「这段代码有测试守着」，不代表条款成立：
条款转 `evidenced` 仍然只认矩阵证据列里那条走业务入口的断言（见[证据分级](evidence-levels.md)）。
四类证据列记的是「这一栏有没有真的取到证」，与矩阵的证据列分工不重复：矩阵记那条证据本身，这里记四栏覆盖到哪。

## 二、已贯通小节

已贯通 = 本节条款全部登记、代码落点全部真实存在、门禁全绿。逐节扩大（`M.COVERAGE_SECTIONS` 里加一节就要补齐该节落点）。

### 第 1 节 概述与范围（19 条）

| 条款 | 代码落点 | 关联测试 | 正常流程 | 失败流程 | 退出重进 | 存档恢复 | 等级 |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 1-01 | AGENTS.md、docs/GameSpec.md | — | 缺 | 缺 | 缺 | 缺 | a |
| 1-02 | server/main.lua、server/world_host/server_runtime.lua | tests/native/player_leave_rejoin_test.lua | 缺 | 缺 | 缺 | 缺 | a |
| 1-03 | server/main.lua、server/world_host/server_runtime.lua、server/save_host.lua | tests/native/player_leave_rejoin_test.lua | 缺 | 缺 | 缺 | 缺 | b |
| 1-04 | server/main.lua、server/world_host/server_runtime.lua | tests/native/spec/01_capacity_local_link_test.lua、tests/probes/local_link_runtime.lua | 有 | 有 | 有 | 有 | b |
| 1-05 | common/game_cfg.lua、common/cfg/shop.lua、common/cfg/fish.lua | tests/native/shop_test.lua | 缺 | 缺 | 缺 | 缺 | a |
| 1-06 | server/world_host/player_shop.lua、server/world_host/fish_tree.lua、common/cfg/shop.lua | tests/native/shop_test.lua、tests/native/fish_loot_test.lua | 缺 | 缺 | 缺 | 缺 | a |
| 1-07 | server/data/player_data.lua、server/player_data_host.lua | tests/native/save_test.lua | 缺 | 缺 | 缺 | 缺 | a |
| 1-08 | server/world_host/fish_tree.lua、server/world_host/ground_loot.lua、server/world_host/ferry_route.lua | tests/native/fish_lift_test.lua、tests/native/ferry_test.lua | 缺 | 缺 | 缺 | 缺 | b |
| 1-09 | server/save_host.lua、common/rate_limit.lua | tests/native/rate_limit_test.lua、tests/native/economy_persistence_test.lua | 缺 | 缺 | 缺 | 缺 | b |
| 1-10 | server/world_host/player_weapon.lua、server/world_host/player_life.lua | tests/native/weapon_system_test.lua、tests/native/spec/server_life_phase_298_test.lua | 缺 | 缺 | 缺 | 缺 | a |
| 1-11 | server/platform_host.lua、client/views/platform_shop_view.lua | tests/native/platform_seam_test.lua、tests/native/platform_screens_test.lua | 缺 | 缺 | 缺 | 缺 | a |
| 1-12 | server/platform_host.lua、server/save_host.lua | tests/native/spec/01_platform_adapter_failure_test.lua | 缺 | 有 | 缺 | 缺 | a |
| 1-13 | server/platform_host.lua | tests/native/platform_seam_test.lua | 缺 | 缺 | 缺 | 缺 | a |
| 1-14 | common/cfg/placeholder_assets.lua、common/game_cfg.lua | tests/native/spec/01_placeholder_asset_visual_test.lua、tests/native/placeholder_assets_test.lua | 有 | 缺 | 缺 | 缺 | a |
| 1-15 | common/cfg/placeholder_assets.lua、server/fish_behaviors.lua | tests/native/spec/01_placeholder_asset_visual_test.lua、tests/native/placeholder_assets_test.lua、tests/native/fish_lift_test.lua | 有 | 缺 | 缺 | 缺 | C |
| 1-16 | common/cfg/shop.lua、common/game_cfg.lua | tests/native/shop_test.lua、tests/native/spec/server_progress_315_test.lua | 缺 | 缺 | 缺 | 缺 | C |
| 1-17 | server/fish_behaviors.lua、server/world_host/fish_tree.lua | tests/native/fish_carrier_test.lua、tests/native/fish_air_escape_test.lua | 缺 | 缺 | 缺 | 缺 | C |
| 1-18 | common/zone_markers.lua、server/world_host/player_fisherman.lua | tests/native/zone_layout_plan_test.lua | 缺 | 缺 | 缺 | 缺 | C |
| 1-19 | common/zone_markers.lua、common/body_scale.lua | tests/native/zone_scene_125_test.lua | 缺 | 缺 | 缺 | 缺 | C |

第 1 节里 1-12 是第一条走完「条款 → 代码落点 → a 级断言 → 矩阵状态 → 门禁」整条纵路的样本：
代码落点是 `server/platform_host.lua`，断言是 `tests/native/spec/01_platform_adapter_failure_test.lua`，
矩阵里那条已转 `evidenced`，四类证据只勾了「失败流程」——其余三类仍是 `缺`，不预先填。

### 第 2 节 玩家属性（17 条）

| 条款 | 代码落点 | 关联测试 | 正常流程 | 失败流程 | 退出重进 | 存档恢复 | 等级 |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 2-01 | common/game_cfg.lua、server/world_host/player_life.lua | tests/native/spec/server_life_phase_298_test.lua、tests/native/attr_growth_test.lua | 缺 | 缺 | 缺 | 缺 | a |
| 2-02 | common/attr_model.lua、server/world_host/attr_leaf.lua | tests/native/spec/server_life_phase_298_test.lua、tests/native/attr_growth_test.lua | 缺 | 缺 | 缺 | 缺 | a |
| 2-03 | common/attr_model.lua、common/game_cfg.lua | tests/native/attr_growth_test.lua | 缺 | 缺 | 缺 | 缺 | a |
| 2-04 | common/attr_model.lua、common/body_scale.lua、server/world_host/attr_leaf.lua | tests/native/spec/server_life_phase_298_test.lua、tests/native/attr_growth_test.lua | 缺 | 缺 | 缺 | 缺 | a |
| 2-05 | common/attr_model.lua、server/world_host/attr_leaf.lua | tests/native/spec/server_life_phase_298_test.lua、tests/native/attr_growth_test.lua | 缺 | 缺 | 缺 | 缺 | a |
| 2-06 | common/attr_model.lua、common/game_cfg.lua | tests/native/spec/server_life_phase_298_test.lua、tests/native/attr_growth_test.lua | 缺 | 缺 | 缺 | 缺 | a |
| 2-07 | common/vitals.lua、server/world_host/player_life.lua | tests/native/spec/server_life_phase_298_test.lua、tests/native/attr_growth_test.lua | 缺 | 缺 | 缺 | 缺 | a |
| 2-08 | common/vitals.lua、server/world_host/player_life.lua | tests/native/spec/server_life_phase_298_test.lua、tests/native/attr_growth_test.lua | 缺 | 缺 | 缺 | 缺 | a |
| 2-09 | server/save_host.lua、server/data/player_data.lua、server/world_host/attr_leaf.lua | tests/native/attr_migration_test.lua、tests/native/save_test.lua | 缺 | 缺 | 缺 | 缺 | b |
| 2-10 | server/player_data_host.lua、server/world_host/attr_leaf.lua | tests/native/attr_growth_test.lua、tests/native/item_bar_flow_test.lua | 缺 | 缺 | 缺 | 缺 | a |
| 2-11 | server/player_data_host.lua、server/world_host/ground_loot.lua | tests/native/loot_drop_test.lua | 缺 | 缺 | 缺 | 缺 | b |
| 2-12 | common/attr_model.lua、server/world_host/attr_leaf.lua | tests/native/attr_presentation_test.lua | 缺 | 缺 | 缺 | 缺 | a |
| 2-13 | server/world_host/player_life.lua、common/game_cfg.lua | tests/native/attr_migration_test.lua、tests/native/spec/server_life_phase_298_test.lua | 缺 | 缺 | 缺 | 缺 | a |
| 2-14 | server/world_host/player_life.lua、common/game_cfg.lua | tests/native/attr_migration_test.lua、tests/native/spec/server_life_phase_298_test.lua | 缺 | 缺 | 缺 | 缺 | a |
| 2-15 | server/world_host/player_life.lua、common/game_cfg.lua | tests/native/spec/server_life_phase_298_test.lua、tests/native/attr_growth_test.lua | 缺 | 缺 | 缺 | 缺 | a |
| 2-16 | server/world_host/player_life.lua、server/world_host/player_life.lua | tests/native/spec/server_life_phase_298_test.lua、tests/native/attr_growth_test.lua | 缺 | 缺 | 缺 | 缺 | a |
| 2-17 | common/attr_model.lua、server/world_host/attr_leaf.lua | tests/native/spec/server_life_phase_298_test.lua、tests/native/attr_growth_test.lua | 缺 | 缺 | 缺 | 缺 | a |

2-11 的「赠送」目前在代码里没有独立协议：跨玩家转移只有丢弃→拾取一条通路，药水成长值只在使用者身上生效，因此这条保持 unverified，缺口记在 [策划案内部矛盾](../to-questionnaire-策划案内部矛盾.md)。其余条款的数值全部集中在 common/game_cfg.lua 的 vitals 与 common/attr_model.lua。

### 第 3 节 持有与操作（22 条）

| 条款 | 代码落点 | 关联测试 | 正常流程 | 失败流程 | 退出重进 | 存档恢复 | 等级 |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 3-01 | client/views/root_view.lua、client/main_hud_layout.lua | tests/native/main_hud_layout_test.lua、tests/native/spec/client_main_hud_action_buttons_test.lua | 缺 | 缺 | 缺 | 缺 | a |
| 3-02 | client/main_hud_layout.lua、server/platform_host.lua | tests/native/main_hud_layout_test.lua、tests/native/spec/client_main_hud_action_buttons_test.lua | 缺 | 缺 | 缺 | 缺 | a |
| 3-03 | client/views/root_view.lua、client/main_hud_layout.lua | tests/native/main_hud_layout_test.lua、tests/native/spec/client_main_hud_action_buttons_test.lua | 缺 | 缺 | 缺 | 缺 | a |
| 3-04 | client/views/root_view.lua、client/main_hud_layout.lua | tests/native/main_hud_layout_test.lua、tests/native/spec/client_main_hud_action_buttons_test.lua | 缺 | 缺 | 缺 | 缺 | a |
| 3-05 | common/game_cfg.lua、server/world_host/player_shop.lua、server/data/player_data.lua | tests/native/build_site_inventory_test.lua、tests/native/shop_test.lua | 缺 | 缺 | 缺 | 缺 | a |
| 3-06 | common/game_cfg.lua、server/world_host/player_shop.lua、server/data/player_data.lua | tests/native/build_site_inventory_test.lua、tests/native/shop_test.lua | 缺 | 缺 | 缺 | 缺 | a |
| 3-07 | server/world_host/ground_loot.lua、server/data/player_data.lua | tests/native/item_bar_test.lua、tests/native/item_bar_flow_test.lua | 缺 | 缺 | 缺 | 缺 | a |
| 3-08 | server/data/player_data.lua | tests/native/item_bar_test.lua、tests/native/item_bar_flow_test.lua | 缺 | 缺 | 缺 | 缺 | a |
| 3-09 | server/player_data_host.lua、server/data/player_data.lua | tests/native/hold_operate_mgr_test.lua、tests/native/item_bar_flow_test.lua | 缺 | 缺 | 缺 | 缺 | a |
| 3-10 | server/player_data_host.lua、server/data/player_data.lua | tests/native/hold_operate_mgr_test.lua、tests/native/item_bar_flow_test.lua | 缺 | 缺 | 缺 | 缺 | a |
| 3-11 | server/data/player_data.lua、server/world_host/player_weapon.lua | tests/native/weapon_system_test.lua | 缺 | 缺 | 缺 | 缺 | a |
| 3-12 | server/data/player_data.lua、common/game_cfg.lua | tests/native/item_bar_test.lua、tests/native/item_bar_flow_test.lua | 缺 | 缺 | 缺 | 缺 | a |
| 3-13 | server/data/player_data.lua | tests/native/item_bar_test.lua、tests/native/item_bar_flow_test.lua | 缺 | 缺 | 缺 | 缺 | a |
| 3-14 | server/world_host/fishing_phase.lua、server/world_host/player_fisherman.lua | tests/native/item_bar_test.lua、tests/native/item_bar_flow_test.lua | 缺 | 缺 | 缺 | 缺 | a |
| 3-15 | server/world_host/fishing_phase.lua、server/player_data_host.lua | tests/native/item_bar_test.lua、tests/native/item_bar_flow_test.lua | 缺 | 缺 | 缺 | 缺 | a |
| 3-16 | server/world_host/player_life.lua | tests/native/spec/server_life_phase_298_test.lua | 缺 | 缺 | 缺 | 缺 | a |
| 3-17 | server/player_data_host.lua、client/views/attack_view.lua | tests/native/hold_operate_mgr_test.lua、tests/native/item_bar_flow_test.lua | 缺 | 缺 | 缺 | 缺 | a |
| 3-18 | server/world_host/special_item_phase.lua、common/special_item.lua | tests/native/spec/server_special_item_299_test.lua、tests/native/hold_operate_test.lua | 缺 | 缺 | 缺 | 缺 | a |
| 3-19 | server/player_data_host.lua、server/world_host/ground_loot.lua | tests/native/loot_drop_test.lua | 缺 | 缺 | 缺 | 缺 | a |
| 3-20 | server/world_host/ground_loot.lua | tests/native/loot_drop_test.lua | 缺 | 缺 | 缺 | 缺 | a |
| 3-21 | server/world_host/ground_loot.lua、server/data/player_data.lua | tests/native/loot_recycle_test.lua | 缺 | 缺 | 缺 | 缺 | a |
| 3-22 | server/data/player_data.lua、server/save_host.lua | tests/native/economy_persistence_test.lua | 缺 | 缺 | 缺 | 缺 | b |

道具栏与背包容量、升级价在 common/game_cfg.lua 的 Items 段，升级入口是 player_shop 的 UpgradeStorage；格位进出与选中/手持分离由 player_data_host 与 player_data 共同持有。

### 第 4 节 钓鱼系统（28 条）

| 条款 | 代码落点 | 关联测试 | 正常流程 | 失败流程 | 退出重进 | 存档恢复 | 等级 |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 4-01 | server/world_host/fishing_phase.lua、common/math_water_judge.lua | tests/native/cast_waiting_test.lua | 缺 | 缺 | 缺 | 缺 | a |
| 4-02 | server/world_host/fishing_phase.lua、server/data/player_data.lua | tests/native/cast_waiting_test.lua | 缺 | 缺 | 缺 | 缺 | a |
| 4-03 | server/world_host/fishing_phase.lua、common/fish_catch.lua | tests/native/cast_waiting_test.lua、tests/native/fish_loot_test.lua | 缺 | 缺 | 缺 | 缺 | b |
| 4-04 | server/world_host/fishing_phase.lua | tests/native/cast_waiting_test.lua | 缺 | 缺 | 缺 | 缺 | a |
| 4-05 | server/world_host/fishing_phase.lua、client/views/reel_overlay_view.lua | tests/native/cast_waiting_test.lua、tests/native/reel_session_test.lua | 缺 | 缺 | 缺 | 缺 | a |
| 4-06 | server/world_host/fishing_phase.lua、common/reel_progress.lua、common/game_cfg.lua | tests/native/cast_waiting_test.lua、tests/native/reel_session_test.lua、tests/native/spec/04_fishing_reel_rules_test.lua | 有 | 缺 | 缺 | 缺 | a |
| 4-07 | server/world_host/fishing_phase.lua、common/reel_progress.lua、common/game_cfg.lua | tests/native/cast_waiting_test.lua、tests/native/reel_session_test.lua、tests/native/spec/04_fishing_reel_rules_test.lua | 有 | 缺 | 缺 | 缺 | a |
| 4-08 | common/reel_progress.lua、common/game_cfg.lua | tests/native/cast_waiting_test.lua、tests/native/reel_session_test.lua | 缺 | 缺 | 缺 | 缺 | a |
| 4-09 | client/views/reel_overlay_view.lua、common/reel_display.lua | tests/native/cast_waiting_test.lua、tests/native/reel_session_test.lua | 缺 | 缺 | 缺 | 缺 | a |
| 4-10 | common/reel_progress.lua、common/game_cfg.lua | tests/native/cast_waiting_test.lua、tests/native/reel_session_test.lua | 缺 | 缺 | 缺 | 缺 | b |
| 4-11 | server/world_host/fishing_phase.lua、common/reel_progress.lua | tests/native/cast_waiting_test.lua、tests/native/reel_session_test.lua、tests/native/spec/04_fishing_reel_rules_test.lua | 缺 | 有 | 缺 | 缺 | a |
| 4-12 | server/world_host/fishing_phase.lua、client/views/cast_source_view.lua | tests/native/landing_test.lua、tests/native/fish_lift_test.lua | 缺 | 缺 | 缺 | 缺 | a |
| 4-13 | server/world_host/fish_tree.lua | tests/native/landing_test.lua、tests/native/fish_lift_test.lua | 缺 | 缺 | 缺 | 缺 | a |
| 4-14 | common/fish_catch.lua | tests/native/cfg_fish_items_test.lua、tests/native/fish_loot_test.lua | 缺 | 缺 | 缺 | 缺 | a |
| 4-15 | common/fish_catch.lua | tests/native/cfg_fish_items_test.lua、tests/native/fish_loot_test.lua | 缺 | 缺 | 缺 | 缺 | a |
| 4-16 | common/fish_catch.lua | tests/native/cfg_fish_items_test.lua、tests/native/fish_loot_test.lua | 缺 | 缺 | 缺 | 缺 | a |
| 4-17 | server/world_host/fishing_phase.lua、common/fish_catch.lua | tests/native/boss_bait_test.lua | 缺 | 缺 | 缺 | 缺 | a |
| 4-18 | server/world_host/fishing_phase.lua、common/fish_catch.lua | tests/native/boss_bait_test.lua | 缺 | 缺 | 缺 | 缺 | a |
| 4-19 | common/fish_catch.lua | tests/native/cfg_fish_items_test.lua、tests/native/fish_loot_test.lua | 缺 | 缺 | 缺 | 缺 | a |
| 4-20 | common/fish_catch.lua | tests/native/cfg_fish_items_test.lua、tests/native/fish_loot_test.lua | 缺 | 缺 | 缺 | 缺 | a |
| 4-21 | common/fish_catch.lua | tests/native/cfg_fish_items_test.lua、tests/native/fish_loot_test.lua | 缺 | 缺 | 缺 | 缺 | a |
| 4-22 | common/fish_catch.lua、server/world_host/player_grill.lua | tests/native/cfg_fish_items_test.lua、tests/native/fish_loot_test.lua | 缺 | 缺 | 缺 | 缺 | a |
| 4-23 | server/world_host/player_lottery.lua、common/lottery_draw.lua | tests/native/lottery_settle_test.lua | 缺 | 缺 | 缺 | 缺 | a |
| 4-24 | server/world_host/fish_tree.lua、common/game_cfg.lua | tests/native/fish_escape_test.lua、tests/native/fish_carrier_test.lua | 缺 | 缺 | 缺 | 缺 | a |
| 4-25 | server/world_host/fish_tree.lua、common/game_cfg.lua | tests/native/fish_escape_test.lua、tests/native/fish_carrier_test.lua | 缺 | 缺 | 缺 | 缺 | a |
| 4-26 | server/world_host/fish_tree.lua、common/game_cfg.lua | tests/native/fish_escape_test.lua、tests/native/fish_carrier_test.lua | 缺 | 缺 | 缺 | 缺 | a |
| 4-27 | server/world_host/fishing_phase.lua | tests/native/cast_waiting_test.lua | 缺 | 缺 | 缺 | 缺 | b |
| 4-28 | common/fish_catch.lua、server/world_host/ground_loot.lua、server/data/player_data.lua | tests/native/loot_recycle_test.lua、tests/native/fish_loot_test.lua | 缺 | 缺 | 缺 | 缺 | a |

个体倍率、重量、价格与取整都从 common/fish_catch.lua 一处派生（重量与金币都按基础值一次乘算），收线节奏在 common/reel_progress.lua，抛竿与选鱼在 server/world_host/fishing_phase.lua。

### 第 5 节 七区鱼种完整数据（18 条）

| 条款 | 代码落点 | 关联测试 | 正常流程 | 失败流程 | 退出重进 | 存档恢复 | 等级 |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 5-01 | common/cfg/fish.lua、common/game_cfg.lua | tests/native/spec/05_zone_fish_data_test.lua、tests/native/cfg_fish_items_test.lua | 有 | 缺 | 缺 | 缺 | a |
| 5-02 | common/cfg/fish.lua、common/content_validation.lua | tests/native/cfg_fish_items_test.lua、tests/native/content_validation_test.lua | 缺 | 缺 | 缺 | 缺 | a |
| 5-03 | common/cfg/fish.lua、common/game_cfg.lua | tests/native/spec/05_zone_fish_data_test.lua、tests/native/cfg_fish_items_test.lua | 有 | 缺 | 缺 | 缺 | a |
| 5-04 | common/cfg/fish.lua | tests/native/cfg_fish_items_test.lua | 缺 | 缺 | 缺 | 缺 | a |
| 5-05 | common/cfg/fish.lua、common/content_validation.lua | tests/native/content_validation_test.lua | 缺 | 缺 | 缺 | 缺 | a |
| 5-06 | common/cfg/fish.lua、common/content_validation.lua | tests/native/content_validation_test.lua | 缺 | 缺 | 缺 | 缺 | a |
| 5-07 | common/cfg/fish.lua、common/content_validation.lua | tests/native/content_validation_test.lua | 缺 | 缺 | 缺 | 缺 | a |
| 5-08 | common/cfg/fish.lua、common/content_validation.lua | tests/native/content_validation_test.lua | 缺 | 缺 | 缺 | 缺 | a |
| 5-09 | common/cfg/fish.lua、common/content_validation.lua | tests/native/content_validation_test.lua | 缺 | 缺 | 缺 | 缺 | a |
| 5-10 | common/cfg/fish.lua、common/game_cfg.lua | tests/native/cfg_fish_items_test.lua | 缺 | 缺 | 缺 | 缺 | a |
| 5-11 | common/cfg/fish.lua、common/content_validation.lua | tests/native/content_validation_test.lua | 缺 | 缺 | 缺 | 缺 | a |
| 5-12 | common/cfg/fish.lua、server/world_host/ground_loot.lua | tests/native/fish_loot_test.lua | 缺 | 缺 | 缺 | 缺 | a |
| 5-13 | common/cfg/fish.lua、common/cfg/items.lua | tests/native/cfg_fish_items_test.lua | 缺 | 缺 | 缺 | 缺 | a |
| 5-14 | common/cfg/fish.lua | tests/native/cfg_fish_items_test.lua | 缺 | 缺 | 缺 | 缺 | a |
| 5-15 | common/cfg/fish.lua | tests/native/cfg_fish_items_test.lua | 缺 | 缺 | 缺 | 缺 | a |
| 5-16 | common/cfg/fish.lua、common/content_validation.lua | tests/native/content_validation_test.lua | 缺 | 缺 | 缺 | 缺 | a |
| 5-17 | common/cfg/fish.lua、common/cfg/items.lua、server/world_host/ground_loot.lua | tests/native/fish_loot_test.lua、tests/native/cfg_fish_items_test.lua | 缺 | 缺 | 缺 | 缺 | a |
| 5-18 | common/cfg/fish.lua、server/world_host/fish_tree.lua | tests/native/fish_air_escape_test.lua、tests/native/island_content_test.lua | 缺 | 缺 | 缺 | 缺 | a |

第 5 节的 5-01 与 5-03 已由图鉴客户端的公开显示快照取证：tests/native/spec/05_zone_fish_data_test.lua 翻满七页，
断言每页 14 条、总数 98、七区 6/6/1/1 品级分布；其余条款待后续断言。

### 第 6 节 战斗与成长（35 条）

> #260 目标选择接线：6-26 / 6-29 / 6-30 / 6-31 的规格断言在 tests/native/spec/06_ai_target_test.lua；
> 属性与效果投影的接线验收同在该文件（attr_model → attr_rule、modifier_system → 移速倍率）。
> 6-29 的 evidenced 只覆盖业务伤害排序与结果登记；官方 AI 按伤害接管由 6-38 单独跟踪，当前 unverified。

| 条款 | 代码落点 | 关联测试 | 正常流程 | 失败流程 | 退出重进 | 存档恢复 | 等级 |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 6-01 | server/world_host/player_weapon.lua、common/game_cfg.lua | tests/native/weapon_system_test.lua、tests/native/combat_behavior_test.lua | 缺 | 缺 | 缺 | 缺 | a |
| 6-02 | server/world_host/player_weapon.lua、common/game_cfg.lua、common/cfg/items.lua | tests/native/weapon_system_test.lua、tests/native/combat_behavior_test.lua | 缺 | 缺 | 缺 | 缺 | a |
| 6-03 | server/world_host/player_weapon.lua、common/game_cfg.lua | tests/native/weapon_system_test.lua、tests/native/combat_behavior_test.lua | 缺 | 缺 | 缺 | 缺 | a |
| 6-04 | server/world_host/player_weapon.lua、common/game_cfg.lua | tests/native/weapon_system_test.lua、tests/native/combat_behavior_test.lua | 缺 | 缺 | 缺 | 缺 | a |
| 6-05 | server/world_host/player_weapon.lua、client/packages/ability_system/strategy/HoldStrategy.lua、client/weapon_aim.lua | tests/native/weapon_system_test.lua、tests/native/combat_behavior_test.lua | 缺 | 缺 | 缺 | 缺 | a |
| 6-06 | common/cfg/shop.lua、server/world_host/player_weapon.lua、common/game_cfg.lua | tests/native/weapon_system_test.lua、tests/native/combat_behavior_test.lua | 缺 | 缺 | 缺 | 缺 | a |
| 6-07 | common/cfg/items.lua、common/game_cfg.lua | tests/native/cfg_fish_items_test.lua、tests/native/prize_weapon_effect_test.lua、tests/native/prize_weapon_cfg_test.lua | 缺 | 缺 | 缺 | 缺 | a |
| 6-08 | common/cfg/shop.lua、server/world_host/player_weapon.lua | tests/native/weapon_system_test.lua、tests/native/combat_behavior_test.lua | 缺 | 缺 | 缺 | 缺 | a |
| 6-09 | server/world_host/player_weapon.lua、server/world_host/player_life.lua | tests/native/weapon_system_test.lua、tests/native/combat_behavior_test.lua | 缺 | 缺 | 缺 | 缺 | a |
| 6-10 | server/world_host/player_weapon.lua | tests/native/weapon_system_test.lua、tests/native/combat_behavior_test.lua | 缺 | 缺 | 缺 | 缺 | a |
| 6-11 | server/world_host/player_weapon.lua、client/weapon_aim.lua | tests/native/weapon_system_test.lua、tests/native/combat_behavior_test.lua | 缺 | 缺 | 缺 | 缺 | a |
| 6-12 | server/world_host/player_weapon.lua | tests/native/weapon_system_test.lua、tests/native/combat_behavior_test.lua | 缺 | 缺 | 缺 | 缺 | a |
| 6-13 | server/world_host/player_weapon.lua、common/fish_catch.lua、server/world_host/fish_tree.lua | tests/native/weapon_system_test.lua、tests/native/combat_behavior_test.lua | 缺 | 缺 | 缺 | 缺 | a |
| 6-14 | common/cfg/shop.lua、server/world_host/player_shop.lua、server/world_host/player_weapon.lua、common/attr_model.lua、server/world_host/attr_leaf.lua | tests/native/prize_growth_wiring_test.lua、tests/native/shop_test.lua、tests/native/attr_migration_test.lua | 缺 | 缺 | 缺 | 缺 | a |
| 6-15 | common/cfg/shop.lua、server/world_host/player_shop.lua、server/world_host/player_weapon.lua、common/attr_model.lua、server/world_host/attr_leaf.lua | tests/native/prize_growth_wiring_test.lua、tests/native/shop_test.lua、tests/native/attr_migration_test.lua | 缺 | 缺 | 缺 | 缺 | a |
| 6-16 | common/cfg/shop.lua、server/world_host/player_shop.lua、server/world_host/player_weapon.lua、common/attr_model.lua、server/world_host/attr_leaf.lua | tests/native/prize_growth_wiring_test.lua、tests/native/shop_test.lua、tests/native/attr_migration_test.lua | 缺 | 缺 | 缺 | 缺 | a |
| 6-17 | server/world_host/player_shop.lua、server/world_host/player_weapon.lua、common/attr_model.lua、server/world_host/attr_leaf.lua | tests/native/prize_growth_wiring_test.lua、tests/native/shop_test.lua、tests/native/attr_migration_test.lua | 缺 | 缺 | 缺 | 缺 | a |
| 6-18 | server/world_host/player_weapon.lua、server/world_host/player_shop.lua、common/attr_model.lua、server/world_host/attr_leaf.lua | tests/native/prize_weapon_effect_test.lua、tests/native/spec/server_special_item_299_test.lua | 缺 | 缺 | 缺 | 缺 | a |
| 6-19 | server/world_host/player_weapon.lua、server/world_host/attr_leaf.lua、common/attr_model.lua | tests/native/prize_weapon_effect_test.lua、tests/native/spec/server_special_item_299_test.lua、tests/native/prize_growth_wiring_test.lua | 缺 | 缺 | 缺 | 缺 | a |
| 6-20 | server/world_host/special_item_phase.lua、common/special_item.lua、common/attr_model.lua、server/world_host/attr_leaf.lua | tests/native/prize_weapon_effect_test.lua、tests/native/spec/server_special_item_299_test.lua | 缺 | 缺 | 缺 | 缺 | a |
| 6-21 | common/cfg/items.lua、common/cfg/lottery.lua、common/game_cfg.lua | tests/native/cfg_fish_items_test.lua、tests/native/prize_weapon_effect_test.lua、tests/native/prize_weapon_cfg_test.lua | 缺 | 缺 | 缺 | 缺 | a |
| 6-22 | server/world_host/player_lottery.lua、common/lottery_draw.lua、common/cfg/lottery.lua | tests/native/prize_weapon_effect_test.lua、tests/native/lottery_draw_test.lua | 缺 | 缺 | 缺 | 缺 | a |
| 6-23 | common/cfg/items.lua、common/game_cfg.lua | tests/native/cfg_fish_items_test.lua、tests/native/prize_weapon_effect_test.lua、tests/native/prize_weapon_cfg_test.lua | 缺 | 缺 | 缺 | 缺 | a |
| 6-24 | server/world_host/player_weapon.lua、common/cfg/items.lua、server/ability_behaviors/melee_hit.lua、server/world_host/modifier_leaf.lua、common/game_cfg.lua | tests/native/prize_weapon_effect_test.lua、tests/native/weapon_system_test.lua、tests/native/status_effect_test.lua | 缺 | 缺 | 缺 | 缺 | a |
| 6-25 | server/world_host/player_weapon.lua、common/cfg/items.lua、server/ability_behaviors/melee_hit.lua、server/world_host/modifier_leaf.lua、common/game_cfg.lua | tests/native/prize_weapon_effect_test.lua、tests/native/weapon_system_test.lua、tests/native/status_effect_test.lua | 缺 | 缺 | 缺 | 缺 | a |
| 6-26 | server/world_host/player_weapon.lua、common/cfg/items.lua、server/ability_behaviors/melee_hit.lua、server/world_host/modifier_leaf.lua、server/world_host/attr_leaf.lua | tests/native/prize_weapon_effect_test.lua、tests/native/weapon_system_test.lua、tests/native/status_effect_test.lua、tests/native/spec/06_ai_target_test.lua | 有 | 有 | 缺 | 缺 | a |
| 6-27 | server/world_host/player_weapon.lua、common/cfg/items.lua、server/ability_behaviors/melee_hit.lua、server/world_host/modifier_leaf.lua、common/game_cfg.lua | tests/native/prize_weapon_effect_test.lua、tests/native/weapon_system_test.lua、tests/native/status_effect_test.lua | 缺 | 缺 | 缺 | 缺 | a |
| 6-28 | common/cfg/items.lua、server/world_host/player_weapon.lua、common/game_cfg.lua | tests/native/prize_weapon_effect_test.lua、tests/native/weapon_system_test.lua、tests/native/prize_weapon_cfg_test.lua | 缺 | 缺 | 缺 | 缺 | a |
| 6-29 | server/world_host/fish_ai.lua、server/world_host/fish_tree.lua、server/world_host/fish_ai.lua、common/ai_target_policy.lua | tests/native/ai_migration_test.lua、tests/native/spec/06_ai_target_test.lua | 有 | 有 | 缺 | 缺 | a |
| 6-30 | server/world_host/fish_ai.lua、server/world_host/fish_tree.lua、server/world_host/fish_ai.lua、common/ai_target_policy.lua | tests/native/ai_migration_test.lua、tests/native/spec/06_ai_target_test.lua | 有 | 有 | 缺 | 缺 | a |
| 6-31 | server/world_host/fish_ai.lua、common/boss_phase.lua、server/world_host/fish_tree.lua、server/world_host/fish_ai.lua | tests/native/ai_migration_test.lua、tests/native/spec/06_ai_target_test.lua | 有 | 有 | 缺 | 缺 | a |
| 6-32 | server/world_host/player_life.lua、server/world_host/player_weapon.lua | tests/native/combat_base_test.lua、tests/native/damage_float_test.lua | 缺 | 缺 | 缺 | 缺 | b |
| 6-33 | common/damage_notice.lua、client/damage_float.lua、server/world_host/player_life.lua | tests/native/combat_base_test.lua、tests/native/damage_float_test.lua | 缺 | 缺 | 缺 | 缺 | b |
| 6-34 | server/world_host/player_life.lua、server/world_host/player_life.lua | tests/native/combat_base_test.lua、tests/native/damage_float_test.lua | 缺 | 缺 | 缺 | 缺 | b |
| 6-38 | server/world_host/fish_ai.lua、common/ai_target_policy.lua、common/game_cfg.lua | — | 缺 | 缺 | 缺 | 缺 | a |

### 第 7 节 经济与钓场商店（25 条）

| 条款 | 代码落点 | 关联测试 | 正常流程 | 失败流程 | 退出重进 | 存档恢复 | 等级 |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 7-01 | server/world_host/player_fisherman.lua、server/world_host/player_lottery.lua | tests/native/feed_exchange_test.lua、tests/native/lottery_settle_test.lua | 缺 | 缺 | 缺 | 缺 | a |
| 7-02 | server/world_host/player_shop.lua、server/world_host/ferry_route.lua | tests/native/shop_test.lua、tests/native/ferry_test.lua | 缺 | 缺 | 缺 | 缺 | a |
| 7-03 | server/world_host/player_blindbox.lua、common/blindbox_draw.lua | tests/native/blindbox_settle_test.lua | 缺 | 缺 | 缺 | 缺 | a |
| 7-04 | common/game_cfg.lua、server/platform_host.lua | tests/native/platform_seam_test.lua | 缺 | 缺 | 缺 | 缺 | a |
| 7-05 | server/world_host/player_shop.lua | tests/native/shop_test.lua | 缺 | 缺 | 缺 | 缺 | a |
| 7-06 | server/world_host/player_fisherman.lua、server/world_host/ground_loot.lua | tests/native/feed_exchange_test.lua、tests/native/loot_recycle_test.lua | 缺 | 缺 | 缺 | 缺 | a |
| 7-07 | common/cfg/shop.lua、server/world_host/player_shop.lua | tests/native/shop_test.lua | 缺 | 缺 | 缺 | 缺 | a |
| 7-08 | common/cfg/shop.lua、server/world_host/player_shop.lua | tests/native/shop_test.lua | 缺 | 缺 | 缺 | 缺 | a |
| 7-09 | common/cfg/shop.lua、client/views/shop_view.lua | tests/native/shop_ui_test.lua | 缺 | 缺 | 缺 | 缺 | a |
| 7-10 | common/cfg/shop.lua | tests/native/cfg_shop_lottery_test.lua | 缺 | 缺 | 缺 | 缺 | a |
| 7-11 | server/world_host/player_shop.lua、server/data/player_data.lua | tests/native/spec/07_shop_purchase_limit_test.lua | 有 | 缺 | 缺 | 缺 | a |
| 7-12 | common/cfg/shop.lua、common/game_cfg.lua | tests/native/cfg_shop_lottery_test.lua | 缺 | 缺 | 缺 | 缺 | a |
| 7-13 | server/world_host/player_shop.lua、client/views/shop_view.lua | tests/native/shop_ui_test.lua | 缺 | 缺 | 缺 | 缺 | a |
| 7-14 | server/world_host/player_shop.lua、client/views/shop_view.lua | tests/native/shop_ui_test.lua | 缺 | 缺 | 缺 | 缺 | a |
| 7-15 | client/views/shop_view.lua | tests/native/shop_ui_test.lua | 缺 | 有 | 缺 | 缺 | a |
| 7-16 | server/platform_host.lua、client/views/platform_shop_view.lua、common/game_cfg.lua | tests/native/spec/07_coin_page_placeholder_test.lua | 有 | 有 | 缺 | 缺 | a |
| 7-17 | server/world_host/player_shop.lua、server/save_host.lua、server/data/player_data.lua | tests/native/spec/07_shop_settlement_atomic_test.lua | 有 | 有 | 缺 | 缺 | a |
| 7-18 | server/save_host.lua、server/world_host/player_shop.lua | tests/native/spec/18_session_settlement_contract_test.lua | 缺 | 缺 | 有 | 缺 | b |
| 7-19 | server/world_host/player_shop.lua、server/data/player_data.lua | tests/native/spec/07_shop_purchase_limit_test.lua | 缺 | 有 | 缺 | 缺 | b |
| 7-20 | server/data/player_data.lua、client/views/shop_view.lua | tests/native/shop_test.lua | 缺 | 缺 | 缺 | 缺 | b |
| 7-21 | server/save_host.lua、server/data/player_data.lua | tests/native/economy_persistence_test.lua | 缺 | 缺 | 缺 | 有 | b |
| 7-22 | server/data/player_data.lua、client/views/shop_view.lua | tests/native/shop_ui_test.lua | 缺 | 缺 | 缺 | 缺 | b |
| 7-23 | server/data/player_data.lua、server/world_host/player_shop.lua、server/world_host/ferry_route.lua | tests/native/economy_persistence_test.lua | 缺 | 缺 | 缺 | 缺 | b |
| 7-24 | client/views/shop_view.lua、client/views/platform_shop_view.lua | tests/native/shop_ui_test.lua | 缺 | 有 | 缺 | 缺 | b |
| 7-25 | common/game_cfg.lua、server/platform_host.lua | tests/native/spec/07_coin_page_placeholder_test.lua | 有 | 有 | 缺 | 缺 | a |

第 7 节的 7-16、7-17、7-25 已由适配层与商店结算的公开入口取证：金币页占位购买「先开通道、确认才到账」，
取消/超时不到账也不扣金币；商店一笔购买的成功与两类失败都在同一次结算里落地。7-24 只到客户端失败流程一栏。

### 第 8 节 NPC、兑换与摆渡（34 条）

| 条款 | 代码落点 | 关联测试 | 正常流程 | 失败流程 | 退出重进 | 存档恢复 | 等级 |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 8-01 | server/world_host/player_fisherman.lua、common/npc_dialogue.lua | tests/native/feed_exchange_test.lua、tests/native/exchange_zones_127_test.lua | 缺 | 缺 | 缺 | 缺 | a |
| 8-02 | server/world_host/player_fisherman.lua、common/cfg/items.lua | tests/native/feed_exchange_test.lua、tests/native/exchange_zones_127_test.lua | 缺 | 缺 | 缺 | 缺 | a |
| 8-03 | server/world_host/player_fisherman.lua、server/data/player_data.lua | tests/native/feed_exchange_test.lua、tests/native/exchange_zones_127_test.lua | 缺 | 缺 | 缺 | 缺 | a |
| 8-04 | server/world_host/player_fisherman.lua、common/game_cfg.lua | tests/native/feed_exchange_test.lua、tests/native/exchange_zones_127_test.lua | 缺 | 缺 | 缺 | 缺 | a |
| 8-05 | server/world_host/player_fisherman.lua、server/world_host/player_grill.lua | tests/native/feed_exchange_test.lua、tests/native/exchange_zones_127_test.lua | 缺 | 缺 | 缺 | 缺 | a |
| 8-06 | common/game_cfg.lua、common/content_validation.lua | tests/native/feed_exchange_test.lua、tests/native/exchange_zones_127_test.lua | 缺 | 缺 | 缺 | 缺 | a |
| 8-07 | server/world_host/player_fisherman.lua、common/game_cfg.lua | tests/native/feed_exchange_test.lua、tests/native/exchange_zones_127_test.lua | 缺 | 缺 | 缺 | 缺 | a |
| 8-08 | server/world_host/player_fisherman.lua、common/game_cfg.lua | tests/native/feed_exchange_test.lua、tests/native/exchange_zones_127_test.lua | 缺 | 缺 | 缺 | 缺 | a |
| 8-09 | server/world_host/player_fisherman.lua、common/game_cfg.lua | tests/native/feed_exchange_test.lua、tests/native/exchange_zones_127_test.lua | 缺 | 缺 | 缺 | 缺 | a |
| 8-10 | common/game_cfg.lua、common/content_validation.lua | tests/native/feed_exchange_test.lua、tests/native/exchange_zones_127_test.lua | 缺 | 缺 | 缺 | 缺 | a |
| 8-11 | server/world_host/ferry_route.lua | tests/native/ferry_test.lua、tests/native/ferry_ui_test.lua | 缺 | 缺 | 缺 | 缺 | a |
| 8-12 | server/world_host/ferry_route.lua | tests/native/ferry_test.lua、tests/native/ferry_ui_test.lua | 缺 | 缺 | 缺 | 缺 | a |
| 8-13 | server/world_host/ferry_route.lua | tests/native/ferry_test.lua、tests/native/ferry_ui_test.lua | 缺 | 缺 | 缺 | 缺 | a |
| 8-14 | common/game_cfg.lua、server/world_host/ferry_route.lua | tests/native/ferry_test.lua、tests/native/ferry_ui_test.lua | 缺 | 缺 | 缺 | 缺 | a |
| 8-15 | server/world_host/ferry_route.lua | tests/native/ferry_test.lua、tests/native/ferry_ui_test.lua | 缺 | 缺 | 缺 | 缺 | a |
| 8-16 | server/world_host/ferry_route.lua | tests/native/ferry_test.lua、tests/native/ferry_ui_test.lua | 缺 | 缺 | 缺 | 缺 | a |
| 8-17 | common/npc_dialogue.lua、client/views/ferry_view.lua | tests/native/ferry_test.lua、tests/native/ferry_ui_test.lua | 缺 | 缺 | 缺 | 缺 | a |
| 8-18 | server/world_host/ground_loot.lua、server/world_host/fish_tree.lua | tests/native/loot_drop_test.lua | 缺 | 缺 | 缺 | 缺 | a |
| 8-19 | server/world_host/ground_loot.lua、client/views/ground_loot_view.lua | tests/native/loot_client_test.lua | 缺 | 缺 | 缺 | 缺 | a |
| 8-20 | server/world_host/ground_loot.lua、server/data/player_data.lua | tests/native/loot_drop_test.lua | 缺 | 缺 | 缺 | 缺 | a |
| 8-21 | server/world_host/ground_loot.lua、common/game_cfg.lua | tests/native/loot_recycle_test.lua | 缺 | 缺 | 缺 | 缺 | a |
| 8-22 | server/world_host/ground_loot.lua、common/game_cfg.lua | tests/native/loot_recycle_test.lua | 缺 | 缺 | 缺 | 缺 | a |
| 8-23 | server/world_host/ground_loot.lua、common/game_cfg.lua | tests/native/loot_recycle_test.lua | 缺 | 缺 | 缺 | 缺 | a |
| 8-24 | common/game_cfg.lua、server/world_host/ground_loot.lua、common/zone_markers.lua | tests/native/bait_spot_test.lua | 缺 | 缺 | 缺 | 缺 | a |
| 8-25 | common/game_cfg.lua、server/world_host/fishing_phase.lua | tests/native/bait_spot_test.lua | 缺 | 缺 | 缺 | 缺 | a |
| 8-26 | server/world_host/player_fisherman.lua、server/save_host.lua | tests/native/economy_persistence_test.lua、tests/native/feed_exchange_test.lua | 缺 | 缺 | 缺 | 缺 | b |
| 8-27 | server/world_host/player_fisherman.lua、server/save_host.lua | tests/native/economy_persistence_test.lua、tests/native/feed_exchange_test.lua | 缺 | 缺 | 缺 | 缺 | b |
| 8-28 | server/world_host/ferry_route.lua | tests/native/ferry_test.lua | 缺 | 缺 | 缺 | 缺 | b |
| 8-29 | server/world_host/ferry_route.lua | tests/native/ferry_test.lua | 缺 | 缺 | 缺 | 缺 | b |
| 8-30 | server/world_host/ferry_route.lua、server/data/player_data.lua | tests/native/ferry_test.lua | 缺 | 缺 | 缺 | 缺 | b |
| 8-31 | server/world_host/ferry_route.lua | tests/native/ferry_test.lua | 缺 | 缺 | 缺 | 缺 | b |
| 8-32 | server/world_host/ferry_route.lua | tests/native/ferry_test.lua | 缺 | 缺 | 缺 | 缺 | b |
| 8-33 | server/world_host/ferry_route.lua、server/save_host.lua | tests/native/ferry_test.lua | 缺 | 缺 | 缺 | 缺 | b |
| 8-34 | server/world_host/ground_loot.lua、common/game_cfg.lua | tests/native/loot_recycle_test.lua | 缺 | 缺 | 缺 | 缺 | b |

返程票价由 game_cfg.Ferry.Routes 按区号生成（10×3^(区号−2)），兑换表在 game_cfg.Content.Exchanges；掉落预算与回收在 ground_loot。

### 第 9 节 多人规则（25 条，其中 9-23～9-25 是 C 级试玩条款）

| 条款 | 代码落点 | 关联测试 | 正常流程 | 失败流程 | 退出重进 | 存档恢复 | 等级 |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 9-01 | server/world_host/player_life.lua、server/world_host/pk_damage_filter.lua、server/main.lua | tests/native/spec/09_pk_damage_filter_test.lua | 有 | 有 | 缺 | 缺 | b |
| 9-02 | server/world_host/squad_dock.lua、server/main.lua | tests/native/spec/server_squad_314_test.lua | 缺 | 有 | 缺 | 缺 | a |
| 9-03 | server/world_host/player_life.lua、server/world_host/player_life.lua、server/world_host/player_fisherman.lua | tests/native/spec/09_rescue_test.lua | 缺 | 有 | 缺 | 缺 | b |
| 9-04 | server/world_host/fish_tree.lua、server/world_host/ground_loot.lua、server/world_host/ferry_route.lua | tests/native/fish_lift_test.lua、tests/native/ferry_test.lua | 缺 | 缺 | 缺 | 缺 | b |
| 9-05 | server/world_host/player_life.lua、server/save_host.lua、server/world_host/player_fisherman.lua | tests/native/spec/09_rescue_test.lua | 有 | 有 | 有 | 缺 | b |
| 9-06 | server/world_host/squad_dock.lua、common/game_cfg.lua | tests/native/spec/server_squad_314_test.lua | 有 | 有 | 缺 | 缺 | a |
| 9-07 | server/world_host/squad_dock.lua、common/game_cfg.lua | tests/native/spec/server_squad_314_test.lua | 有 | 有 | 缺 | 缺 | a |
| 9-08 | server/world_host/squad_dock.lua、common/game_cfg.lua | tests/native/spec/server_squad_314_test.lua | 有 | 有 | 缺 | 缺 | b |
| 9-09 | server/world_host/squad_dock.lua、common/game_cfg.lua | tests/native/spec/server_squad_314_test.lua | 有 | 缺 | 有 | 缺 | b |
| 9-10 | server/world_host/squad_dock.lua、common/game_cfg.lua | tests/native/spec/server_squad_314_test.lua | 有 | 缺 | 有 | 缺 | a |
| 9-11 | server/world_host/squad_dock.lua、common/game_cfg.lua | tests/native/spec/server_squad_314_test.lua | 有 | 缺 | 缺 | 缺 | a |
| 9-12 | server/world_host/player_life.lua、server/world_host/pk_damage_filter.lua、server/main.lua | tests/native/spec/09_pk_damage_filter_test.lua | 有 | 有 | 缺 | 缺 | a |
| 9-13 | server/world_host/player_life.lua、server/world_host/pk_damage_filter.lua、common/zone_markers.lua | tests/native/spec/09_pk_damage_filter_test.lua | 有 | 有 | 缺 | 缺 | a |
| 9-14 | server/world_host/player_life.lua、server/world_host/pk_damage_filter.lua、common/zone_markers.lua | tests/native/spec/09_pk_damage_filter_test.lua | 有 | 有 | 缺 | 缺 | a |
| 9-15 | server/world_host/player_life.lua、server/world_host/pk_damage_filter.lua | tests/native/spec/09_pk_damage_filter_test.lua | 有 | 缺 | 缺 | 缺 | a |
| 9-16 | server/world_host/player_life.lua、server/world_host/pk_damage_filter.lua、server/world_host/fish_tree.lua | tests/native/spec/09_pk_damage_filter_test.lua | 有 | 有 | 缺 | 缺 | a |
| 9-17 | server/world_host/player_fisherman.lua、server/world_host/player_life.lua、client/views/fisherman_view.lua | tests/native/spec/09_rescue_test.lua | 有 | 有 | 缺 | 缺 | a |
| 9-18 | server/world_host/player_life.lua、server/world_host/player_life.lua、common/game_cfg.lua | tests/native/spec/09_rescue_test.lua | 有 | 缺 | 缺 | 缺 | a |
| 9-19 | server/world_host/squad_dock.lua、common/game_cfg.lua、client/views/squad_view.lua | tests/native/spec/server_squad_314_test.lua、tests/native/spec/client_squad_314_test.lua | 有 | 有 | 缺 | 缺 | a |
| 9-20 | client/views/squad_view.lua、client/main.lua、server/world_host/squad_dock.lua | tests/native/spec/client_squad_314_test.lua | 有 | 有 | 缺 | 缺 | a |
| 9-21 | client/views/squad_view.lua、server/world_host/squad_dock.lua | tests/native/spec/client_squad_314_test.lua | 有 | 有 | 缺 | 缺 | a |
| 9-22 | server/world_host/squad_dock.lua、server/data/player_data.lua、server/save_host.lua、client/views/squad_view.lua、common/game_cfg.lua | tests/native/spec/server_squad_314_test.lua、tests/native/spec/client_squad_314_test.lua | 有 | 有 | 有 | 有 | b |

第 9 节由小队子单先贯通：9-02、9-06～9-11、9-19～9-22 的代码落点是 `server/world_host/squad_dock.lua`（服务端唯一权威的归属与名单）
与 `client/views/squad_view.lua`（队友血量与邀请倒计时），证据是两份 spec 断言。
9-01、9-12～9-16 经统一伤害入口与 PK 过滤接缝落地，spec 断言覆盖同队全武器免伤、鱼塘豁免、鱼塘外 PK、人数不足与鱼攻击；
9-12 除统一入口的类别遍历外，另从 `server/world_host/player_weapon.lua` 真实发起一次枪击（弹道只替身引擎边界）：
同队命中被挡成 0 伤害，离队后同一把枪照常结算——这样「近战 / 枪械 / 范围都按 0」不再只靠贴 category 标签；
9-03、9-17、9-18 已由抢救子单取证。
三者共用同一份矩阵小节，因此本表一次登记到位，四类证据只勾已经真取到的那几栏。

### 第 10 节 烧烤（25 条）

| 条款 | 代码落点 | 关联测试 | 正常流程 | 失败流程 | 退出重进 | 存档恢复 | 等级 |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 10-01 | common/game_cfg.lua、common/zone_markers.lua | tests/native/grill_test.lua | 缺 | 缺 | 缺 | 缺 | a |
| 10-02 | server/world_host/player_grill.lua | tests/native/grill_test.lua | 缺 | 缺 | 缺 | 缺 | a |
| 10-03 | server/world_host/player_grill.lua | tests/native/grill_test.lua、tests/native/spec/10_grill_curve_test.lua | 缺 | 有 | 缺 | 缺 | a |
| 10-04 | server/world_host/player_grill.lua | tests/native/grill_test.lua | 缺 | 缺 | 缺 | 缺 | a |
| 10-05 | server/world_host/player_grill.lua | tests/native/grill_test.lua | 缺 | 缺 | 缺 | 缺 | a |
| 10-06 | common/grill_curve.lua、common/game_cfg.lua | tests/native/grill_test.lua、tests/native/spec/10_grill_curve_test.lua | 有 | 缺 | 缺 | 缺 | a |
| 10-07 | common/grill_curve.lua、common/game_cfg.lua | tests/native/grill_test.lua、tests/native/spec/10_grill_curve_test.lua | 有 | 缺 | 缺 | 缺 | a |
| 10-08 | common/grill_curve.lua、common/game_cfg.lua | tests/native/grill_test.lua、tests/native/spec/10_grill_curve_test.lua | 有 | 缺 | 缺 | 缺 | a |
| 10-09 | client/views/grill_view.lua、common/grill_curve.lua | tests/native/grill_test.lua | 缺 | 缺 | 缺 | 缺 | a |
| 10-10 | server/world_host/player_grill.lua、common/grill_curve.lua | tests/native/grill_test.lua、tests/native/spec/10_grill_curve_test.lua | 有 | 缺 | 缺 | 缺 | a |
| 10-11 | server/world_host/player_grill.lua、common/grill_curve.lua | tests/native/grill_test.lua、tests/native/spec/10_grill_curve_test.lua | 缺 | 有 | 缺 | 缺 | a |
| 10-12 | server/world_host/player_grill.lua、server/world_host/player_life.lua | tests/native/grill_test.lua、tests/native/spec/10_grill_curve_test.lua | 缺 | 有 | 缺 | 缺 | a |
| 10-13 | client/views/grill_view.lua、server/world_host/player_grill.lua | tests/native/grill_test.lua、tests/native/spec/10_grill_curve_test.lua | 缺 | 有 | 缺 | 缺 | a |
| 10-14 | server/world_host/player_grill.lua | tests/native/grill_test.lua、tests/native/spec/10_grill_curve_test.lua | 有 | 缺 | 缺 | 缺 | a |
| 10-15 | server/world_host/player_grill.lua | tests/native/grill_test.lua、tests/native/spec/10_grill_curve_test.lua | 缺 | 有 | 缺 | 缺 | a |
| 10-16 | server/world_host/player_lottery.lua、common/lottery_eligibility.lua | tests/native/lottery_eligibility_test.lua、tests/native/grill_test.lua | 缺 | 缺 | 缺 | 缺 | a |
| 10-17 | server/world_host/player_fisherman.lua、server/world_host/player_grill.lua | tests/native/feed_exchange_test.lua、tests/native/grill_test.lua | 缺 | 缺 | 缺 | 缺 | a |
| 10-18 | server/world_host/player_grill.lua | tests/native/grill_test.lua | 缺 | 缺 | 缺 | 缺 | b |
| 10-19 | server/world_host/player_grill.lua | tests/native/grill_test.lua | 缺 | 缺 | 缺 | 缺 | b |
| 10-20 | server/world_host/player_grill.lua | tests/native/grill_test.lua | 缺 | 缺 | 缺 | 缺 | b |
| 10-21 | server/world_host/player_grill.lua、server/save_host.lua | tests/native/grill_test.lua | 缺 | 缺 | 缺 | 缺 | b |
| 10-22 | server/world_host/player_grill.lua、server/world_host/player_life.lua | tests/native/grill_test.lua | 缺 | 缺 | 缺 | 缺 | b |
| 10-23 | server/world_host/player_grill.lua、server/save_host.lua | tests/native/grill_test.lua | 缺 | 缺 | 缺 | 缺 | b |
| 10-24 | server/world_host/player_grill.lua、server/data/player_data.lua | tests/native/grill_test.lua | 缺 | 缺 | 缺 | 缺 | b |
| 10-25 | server/world_host/player_grill.lua、server/data/player_data.lua | tests/native/grill_test.lua | 缺 | 缺 | 缺 | 缺 | b |

倍率曲线是纯函数 common/grill_curve.lua，计时由 player_grill 按服务器时钟的投入时长一次算出，不按帧累加。

### 第 12 节 精英与首领行为（48 条）

| 条款 | 代码落点 | 关联测试 | 正常流程 | 失败流程 | 退出重进 | 存档恢复 | 等级 |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 12-01 | common/cfg/boss_moves.lua、common/game_cfg.lua | tests/native/spec/12_boss_moves_test.lua | 有 | 缺 | 缺 | 缺 | a |
| 12-02 | common/cfg/boss_moves.lua | tests/native/spec/12_boss_moves_test.lua | 有 | 缺 | 缺 | 缺 | a |
| 12-03 | common/cfg/boss_moves.lua | tests/native/spec/12_boss_moves_test.lua | 有 | 缺 | 缺 | 缺 | a |
| 12-04 | common/cfg/boss_moves.lua、server/world_host/fish_tree.lua | tests/native/spec/12_boss_moves_test.lua | 有 | 缺 | 缺 | 缺 | a |
| 12-05 | common/cfg/boss_moves.lua | tests/native/spec/12_boss_moves_test.lua | 有 | 缺 | 缺 | 缺 | a |
| 12-06 | server/world_host/fish_tree.lua、common/game_cfg.lua | tests/native/boss_bait_test.lua | 缺 | 缺 | 缺 | 缺 | a |
| 12-07 | common/cfg/boss_moves.lua、common/game_cfg.lua、server/world_host/fish_tree.lua| tests/native/spec/12_boss_moves_melee_aoe_test.lua、tests/native/eel_combat_test.lua| 有| 缺 | 缺 | 缺 | a |
| 12-08 | common/cfg/boss_moves.lua、common/game_cfg.lua、server/world_host/fish_tree.lua、common/gar_bite_notice.lua| tests/native/spec/12_boss_moves_melee_aoe_test.lua、tests/native/gar_combat_test.lua| 有| 缺 | 缺 | 缺 | a |
| 12-09 | common/cfg/boss_moves.lua、server/world_host/fish_tree.lua| tests/native/spec/12_boss_moves_melee_aoe_test.lua、tests/native/gar_combat_test.lua| 有| 有| 缺 | 缺 | a |
| 12-10 | common/cfg/boss_moves.lua、common/game_cfg.lua、server/world_host/fish_tree.lua| tests/native/spec/12_boss_moves_melee_aoe_test.lua、tests/native/shrimp_combat_test.lua| 有| 缺 | 缺 | 缺 | a |
| 12-11 | common/cfg/boss_moves.lua、common/game_cfg.lua、server/world_host/fish_tree.lua| tests/native/spec/12_boss_moves_melee_aoe_test.lua、tests/native/shrimp_combat_test.lua| 有| 缺 | 缺 | 缺 | a |
| 12-12 | common/game_cfg.lua、server/world_host/fish_tree.lua | tests/native/shrimp_combat_test.lua | 缺 | 缺 | 缺 | 缺 | a |
| 12-13 | common/game_cfg.lua、server/world_host/fish_tree.lua | tests/native/shrimp_combat_test.lua | 缺 | 缺 | 缺 | 缺 | a |
| 12-14 | common/game_cfg.lua、server/world_host/fish_tree.lua | tests/native/shrimp_combat_test.lua | 缺 | 缺 | 缺 | 缺 | a |
| 12-15 | common/cfg/boss_moves.lua、common/game_cfg.lua、server/world_host/fish_tree.lua| tests/native/spec/12_boss_moves_melee_aoe_test.lua、tests/native/king_crab_combat_test.lua| 有| 缺 | 缺 | 缺 | a |
| 12-16 | common/cfg/boss_moves.lua、common/game_cfg.lua、server/world_host/fish_tree.lua| tests/native/spec/12_boss_moves_melee_aoe_test.lua、tests/native/king_crab_combat_test.lua| 有| 缺 | 缺 | 缺 | a |
| 12-17 | common/cfg/boss_moves.lua、common/game_cfg.lua、server/world_host/fish_tree.lua| tests/native/spec/12_boss_moves_melee_aoe_test.lua、tests/native/crab_boss_combat_test.lua| 有| 缺 | 缺 | 缺 | a |
| 12-18 | common/cfg/boss_moves.lua、common/game_cfg.lua、server/world_host/fish_tree.lua| tests/native/spec/12_boss_moves_melee_aoe_test.lua、tests/native/crab_boss_combat_test.lua| 有| 缺 | 缺 | 缺 | a |
| 12-19 | common/cfg/boss_moves.lua、common/game_cfg.lua、server/world_host/fish_tree.lua| tests/native/spec/12_boss_moves_melee_aoe_test.lua、tests/native/crab_boss_combat_test.lua| 有| 缺 | 缺 | 缺 | a |
| 12-20 | common/game_cfg.lua、server/world_host/fish_tree.lua | tests/native/forest_combat_test.lua | 缺 | 缺 | 缺 | 缺 | a |
| 12-21 | common/cfg/boss_moves.lua、common/game_cfg.lua、server/world_host/fish_tree.lua | tests/native/spec/12_boss_moves_ranged_dive_test.lua | 有 | 缺 | 缺 | 缺 | a |
| 12-22 | common/game_cfg.lua、server/world_host/fish_tree.lua | tests/native/forest_combat_test.lua | 缺 | 缺 | 缺 | 缺 | a |
| 12-23 | common/game_cfg.lua、server/world_host/fish_tree.lua | tests/native/forest_combat_test.lua | 缺 | 缺 | 缺 | 缺 | a |
| 12-24 | common/cfg/boss_moves.lua、common/game_cfg.lua、server/world_host/fish_tree.lua | tests/native/spec/12_boss_moves_ranged_dive_test.lua | 有 | 缺 | 缺 | 缺 | a |
| 12-25 | common/game_cfg.lua、server/world_host/fish_tree.lua | tests/native/beach_combat_test.lua | 缺 | 缺 | 缺 | 缺 | a |
| 12-26 | common/cfg/boss_moves.lua、common/game_cfg.lua、server/world_host/fish_tree.lua | tests/native/spec/12_boss_moves_ranged_dive_test.lua | 有 | 缺 | 缺 | 缺 | a |
| 12-27 | common/game_cfg.lua、server/world_host/fish_tree.lua | tests/native/beach_combat_test.lua | 缺 | 缺 | 缺 | 缺 | a |
| 12-28 | common/cfg/boss_moves.lua、common/game_cfg.lua、server/world_host/fish_tree.lua | tests/native/spec/12_boss_moves_ranged_dive_test.lua | 有 | 缺 | 缺 | 缺 | a |
| 12-29 | common/game_cfg.lua、server/world_host/fish_tree.lua | tests/native/beach_combat_test.lua | 缺 | 缺 | 缺 | 缺 | a |
| 12-30 | common/cfg/boss_moves.lua、common/game_cfg.lua、server/world_host/fish_tree.lua | tests/native/spec/12_boss_moves_ranged_dive_test.lua | 有 | 缺 | 缺 | 缺 | a |
| 12-31 | common/cfg/boss_moves.lua、common/game_cfg.lua、server/world_host/fish_tree.lua | tests/native/spec/12_boss_moves_ranged_dive_test.lua | 有 | 缺 | 缺 | 缺 | a |
| 12-32 | common/cfg/boss_moves.lua、common/game_cfg.lua、server/world_host/fish_tree.lua | tests/native/spec/12_boss_moves_ranged_dive_test.lua | 有 | 缺 | 缺 | 缺 | a |
| 12-33 | common/cfg/boss_moves.lua、common/game_cfg.lua、server/world_host/fish_tree.lua | tests/native/spec/12_boss_moves_ranged_dive_test.lua | 有 | 缺 | 缺 | 缺 | a |
| 12-34 | common/cfg/boss_moves.lua、common/game_cfg.lua、server/world_host/fish_tree.lua | tests/native/spec/12_boss_moves_ranged_dive_test.lua | 有 | 缺 | 缺 | 缺 | b |
| 12-35 | common/cfg/boss_moves.lua、server/world_host/fish_tree.lua | tests/native/spec/12_boss_moves_phase_test.lua | 有 | 缺 | 缺 | 缺 | a |
| 12-36 | common/cfg/boss_moves.lua、common/game_cfg.lua、server/world_host/fish_tree.lua | tests/native/spec/12_boss_moves_phase_test.lua | 有 | 缺 | 缺 | 缺 | a |
| 12-37 | common/cfg/boss_moves.lua、server/world_host/fish_tree.lua | tests/native/spec/12_boss_moves_phase_test.lua | 有 | 缺 | 缺 | 缺 | a |
| 12-38 | common/cfg/boss_moves.lua、common/game_cfg.lua、server/world_host/fish_tree.lua | tests/native/spec/12_boss_moves_phase_test.lua | 有 | 缺 | 缺 | 缺 | a |
| 12-39 | common/cfg/fish.lua、common/cfg/boss_moves.lua | tests/native/spec/12_boss_moves_test.lua | 有 | 缺 | 缺 | 缺 | a |
| 12-40 | common/cfg/boss_moves.lua、common/boss_phase.lua | tests/native/spec/12_boss_moves_test.lua | 有 | 缺 | 缺 | 缺 | a |
| 12-41 | common/cfg/boss_moves.lua、server/world_host/fish_tree.lua | tests/native/spec/12_boss_moves_test.lua | 有 | 缺 | 缺 | 缺 | a |
| 12-42 | common/cfg/boss_moves.lua、server/world_host/fish_tree.lua | tests/native/spec/12_boss_moves_test.lua | 有 | 缺 | 缺 | 缺 | a |
| 12-43 | common/game_cfg.lua、common/boss_phase.lua、server/world_host/fish_tree.lua | tests/native/spec/12_boss_moves_test.lua | 有 | 缺 | 缺 | 缺 | a |
| 12-44 | common/game_cfg.lua、common/boss_phase.lua、server/world_host/fish_tree.lua | tests/native/spec/12_boss_moves_test.lua | 有 | 缺 | 缺 | 缺 | a |
| 12-45 | common/cfg/boss_moves.lua、common/game_cfg.lua、common/boss_phase.lua、server/world_host/fish_tree.lua | tests/native/spec/12_boss_moves_test.lua、tests/native/spec/12_boss_moves_phase_test.lua | 有 | 缺 | 缺 | 缺 | b |
| 12-46 | common/cfg/boss_moves.lua | tests/native/spec/12_boss_moves_test.lua | 有 | 缺 | 缺 | 缺 | a |
| 12-47 | common/game_cfg.lua、server/world_host/fish_tree.lua | — | 缺 | 缺 | 缺 | 缺 | a |
| 12-48 | common/game_cfg.lua | — | 缺 | 缺 | 缺 | 缺 | a |

第 12 节先建逐招表，再用火山岛首领哥斯拉贯通「配置 → 服务端调度 → 客户端预警 → 断言」：
12-04、12-05、12-39～12-46 已由 tests/native/spec/12_boss_moves_test.lua 走 fish_tree 的业务入口取证；
其余条款的落点与关联测试都是实现自检，状态仍是 unverified。

远程与俯冲组（#258）另由 tests/native/spec/12_boss_moves_ranged_dive_test.lua 走同一业务入口取证：
小白龙雨云 / 俯冲、剑鱼与三头鲨高跃、海象直线突击、虎鲸虎啸 / 鲸跃、白头鹰俯冲、
风神翼龙投掷 / 追踪俯冲共 11 条（12-13、12-14、12-21、12-24、12-26、12-28、12-30、12-31～12-34）。
断言改逐招表哨兵值后观察服务端结算，证明表是唯一数值来源；预警载荷带落点、范围与投送方式，
伤害只由服务端在锁定落点结算，测试进程没有加载客户端命中代码。

阶段与复合组（#259）另有一组 a/b 证据：沧龙用逐招表的 patrol / leap / head / bite / contact 五行区分绕岛巡航、命中段与叼走过程接触段，哥斯拉的阶段阈值单独放在 `M.Phases`（普通招式表仍是 `M.Rows`），由 tests/native/spec/12_boss_moves_phase_test.lua 走 fish_tree 的业务入口断言移速上限、砸击/甩头、最近岛中心目标、叼走入海、两段伤害与同帧阈值优先；四类证据只勾「正常流程」，失败 / 退出重进 / 存档恢复仍缺。

### 第 13 节 图鉴与成就（16 条）

| 条款 | 代码落点 | 关联测试 | 正常流程 | 失败流程 | 退出重进 | 存档恢复 | 等级 |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 13-01 | common/cfg/fish.lua、client/views/compendium_view.lua | tests/native/spec/server_progress_315_test.lua、tests/native/spec/client_progress_315_test.lua | 缺 | 缺 | 缺 | 缺 | a |
| 13-02 | client/views/compendium_view.lua、common/game_cfg.lua | tests/native/spec/client_progress_315_test.lua | 缺 | 缺 | 缺 | 缺 | a |
| 13-03 | client/views/compendium_view.lua | tests/native/spec/client_progress_315_test.lua | 缺 | 缺 | 缺 | 缺 | a |
| 13-04 | server/world_host/player_compendium.lua、server/world_host/fishing_phase.lua、server/world_host/fish_tree.lua | tests/native/spec/server_progress_315_test.lua | 缺 | 缺 | 缺 | 缺 | a |
| 13-05 | server/world_host/player_compendium.lua | tests/native/spec/server_progress_315_test.lua | 缺 | 缺 | 缺 | 缺 | b |
| 13-06 | server/world_host/player_compendium.lua、server/data/player_data.lua | tests/native/spec/server_progress_315_test.lua | 缺 | 缺 | 缺 | 缺 | a |
| 13-07 | client/views/compendium_view.lua、server/world_host/world_records.lua、common/records.lua | tests/native/spec/client_progress_315_test.lua | 有 | 缺 | 缺 | 缺 | a |
| 13-08 | client/views/compendium_view.lua、server/world_host/world_records.lua、common/records.lua | tests/native/spec/client_progress_315_test.lua | 有 | 缺 | 缺 | 缺 | a |
| 13-09 | server/world_host/player_compendium.lua、server/world_host/player_blindbox.lua、server/world_host/player_fisherman.lua | tests/native/spec/server_progress_315_test.lua | 缺 | 缺 | 缺 | 缺 | b |
| 13-10 | server/world_host/player_fisherman.lua、common/game_cfg.lua、server/world_host/player_achievements.lua | tests/native/exchange_zones_127_test.lua | 缺 | 缺 | 缺 | 缺 | a |
| 13-11 | server/world_host/player_compendium.lua、server/world_host/player_fisherman.lua | tests/native/spec/server_progress_315_test.lua、tests/native/exchange_zones_127_test.lua | 缺 | 缺 | 缺 | 缺 | a |
| 13-12 | server/world_host/player_achievements.lua、common/game_cfg.lua | tests/native/spec/server_progress_315_test.lua | 有 | 缺 | 有 | 有 | b |
| 13-13 | server/world_host/player_achievements.lua | tests/native/spec/server_progress_315_test.lua | 有 | 缺 | 有 | 有 | b |
| 13-14 | server/world_host/player_achievements.lua、server/save_host.lua | tests/native/spec/server_progress_315_test.lua | 有 | 有 | 缺 | 缺 | b |
| 13-17 | server/world_host/world_records.lua、server/data/records_adapter.lua、common/records.lua、client/views/compendium_view.lua | tests/native/spec/client_progress_315_test.lua、tests/native/records_test.lua | 缺 | 有 | 缺 | 缺 | b |
| 13-18 | server/world_host/player_achievements.lua、common/game_cfg.lua | tests/native/spec/server_progress_315_test.lua、tests/native/spec/server_progress_315_test.lua | 有 | 有 | 有 | 有 | b |

第 13 节的 13-07、13-08、13-17 由图鉴客户端与服务端纪录查询的公开入口取证：`tests/native/spec/client_progress_315_test.lua`
翻到「没有纪录」与「纪录服务未接入」两种回包，断言该列只显示「未取得数据」、不出现任何数字与保持者；13-12～13-14、13-18 由
成就交付队列取证。13-15、13-16 是试玩条款，不在本表登记。

### 第 14 节 抽奖机（23 条）

| 条款 | 代码落点 | 关联测试 | 正常流程 | 失败流程 | 退出重进 | 存档恢复 | 等级 |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 14-01 | common/game_cfg.lua、server/world_host/player_lottery.lua | tests/native/lottery_settle_test.lua、tests/native/lottery_draw_test.lua | 缺 | 缺 | 缺 | 缺 | a |
| 14-02 | common/lottery_eligibility.lua、server/world_host/player_lottery.lua | tests/native/lottery_eligibility_test.lua、tests/native/lottery_ui_test.lua | 缺 | 缺 | 缺 | 缺 | a |
| 14-03 | common/lottery_draw.lua、common/cfg/lottery.lua | tests/native/lottery_settle_test.lua、tests/native/lottery_draw_test.lua、tests/native/spec/14_lottery_rules_test.lua | 有 | 缺 | 缺 | 缺 | a |
| 14-04 | common/lottery_draw.lua、server/world_host/player_lottery.lua | tests/native/lottery_settle_test.lua、tests/native/lottery_draw_test.lua、tests/native/spec/14_lottery_rules_test.lua | 有 | 缺 | 缺 | 缺 | a |
| 14-05 | common/lottery_draw.lua、server/world_host/player_lottery.lua | tests/native/lottery_settle_test.lua、tests/native/lottery_draw_test.lua、tests/native/spec/14_lottery_rules_test.lua | 有 | 缺 | 缺 | 缺 | a |
| 14-06 | common/lottery_draw.lua、common/cfg/lottery.lua | tests/native/lottery_settle_test.lua、tests/native/lottery_draw_test.lua、tests/native/spec/14_lottery_rules_test.lua | 有 | 缺 | 缺 | 缺 | a |
| 14-07 | common/cfg/lottery.lua、common/lottery_draw.lua | tests/native/lottery_settle_test.lua、tests/native/lottery_draw_test.lua | 缺 | 缺 | 缺 | 缺 | a |
| 14-08 | common/cfg/lottery.lua、common/lottery_draw.lua | tests/native/lottery_settle_test.lua、tests/native/lottery_draw_test.lua | 缺 | 缺 | 缺 | 缺 | a |
| 14-09 | common/lottery_draw.lua、server/world_host/player_lottery.lua | tests/native/lottery_settle_test.lua、tests/native/lottery_draw_test.lua、tests/native/spec/14_lottery_rules_test.lua | 有 | 缺 | 缺 | 缺 | a |
| 14-10 | common/lottery_draw.lua、server/world_host/player_lottery.lua | tests/native/lottery_settle_test.lua、tests/native/lottery_draw_test.lua、tests/native/spec/14_lottery_rules_test.lua | 有 | 缺 | 缺 | 缺 | a |
| 14-11 | common/game_cfg.lua、client/views/lottery_view.lua | tests/native/lottery_local_test.lua、tests/native/lottery_ui_test.lua | 缺 | 缺 | 缺 | 缺 | a |
| 14-12 | server/world_host/player_lottery.lua、server/save_host.lua | tests/native/lottery_settle_test.lua | 缺 | 缺 | 缺 | 缺 | b |
| 14-13 | server/world_host/player_lottery.lua | tests/native/lottery_settle_test.lua、tests/native/lottery_draw_test.lua、tests/native/spec/14_lottery_rules_test.lua | 有 | 缺 | 缺 | 缺 | a |
| 14-14 | server/world_host/player_lottery.lua、server/data/player_data.lua | tests/native/lottery_settle_test.lua、tests/native/lottery_ui_test.lua | 缺 | 缺 | 缺 | 缺 | b |
| 14-15 | server/world_host/player_lottery.lua、server/data/player_data.lua | tests/native/lottery_settle_test.lua、tests/native/lottery_draw_test.lua、tests/native/spec/14_lottery_rules_test.lua | 有 | 缺 | 缺 | 缺 | a |
| 14-16 | client/views/lottery_view.lua | tests/native/lottery_eligibility_test.lua、tests/native/lottery_ui_test.lua | 缺 | 缺 | 缺 | 缺 | a |
| 14-17 | server/world_host/player_lottery.lua、server/save_host.lua | tests/native/lottery_settle_test.lua | 缺 | 缺 | 缺 | 缺 | b |
| 14-18 | server/world_host/player_lottery.lua、server/save_host.lua | tests/native/lottery_settle_test.lua | 缺 | 缺 | 缺 | 缺 | b |
| 14-19 | server/world_host/player_lottery.lua、server/save_host.lua | tests/native/lottery_settle_test.lua | 缺 | 缺 | 缺 | 缺 | b |
| 14-20 | common/special_item.lua、server/world_host/special_item_phase.lua | tests/native/spec/server_special_item_299_test.lua | 缺 | 缺 | 缺 | 缺 | a |
| 14-21 | common/special_item.lua、common/flight_path.lua | tests/native/spec/server_special_item_299_test.lua | 缺 | 缺 | 缺 | 缺 | a |
| 14-22 | common/special_item.lua、server/world_host/special_item_phase.lua | tests/native/spec/server_special_item_299_test.lua | 缺 | 缺 | 缺 | 缺 | a |
| 14-23 | common/special_item.lua、common/boss_phase.lua | tests/native/spec/server_special_item_299_test.lua | 缺 | 缺 | 缺 | 缺 | b |

图案权重与两同倍数在 common/cfg/lottery.lua，抽样与判奖在 common/lottery_draw.lua，扣物发奖与落位在 player_lottery。

### 第 15 节 地图盲盒（18 条）

| 条款 | 代码落点 | 关联测试 | 正常流程 | 失败流程 | 退出重进 | 存档恢复 | 等级 |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 15-01 | common/game_cfg.lua、server/world_host/player_blindbox.lua | tests/native/spec/15_blindbox_placeholder_settlement_test.lua | 有 | 缺 | 缺 | 缺 | a |
| 15-02 | common/game_cfg.lua、server/world_host/player_blindbox.lua | tests/native/blindbox_draw_test.lua | 缺 | 缺 | 缺 | 缺 | a |
| 15-03 | common/blindbox_draw.lua、common/game_cfg.lua | tests/native/blindbox_draw_test.lua | 缺 | 缺 | 缺 | 缺 | a |
| 15-04 | server/data/player_data.lua、server/world_host/player_blindbox.lua | tests/native/blindbox_settle_test.lua | 缺 | 缺 | 缺 | 缺 | a |
| 15-05 | server/world_host/ground_loot.lua、server/world_host/player_blindbox.lua | tests/native/blindbox_settle_test.lua | 缺 | 有 | 缺 | 缺 | a |
| 15-06 | server/world_host/ground_loot.lua | tests/native/loot_drop_test.lua | 缺 | 缺 | 缺 | 缺 | a |
| 15-07 | server/world_host/player_blindbox.lua、client/views/blindbox_view.lua | tests/native/platform_screens_test.lua | 缺 | 缺 | 缺 | 缺 | a |
| 15-08 | server/data/player_data.lua | tests/native/blindbox_settle_test.lua | 缺 | 有 | 缺 | 缺 | b |
| 15-09 | common/blindbox_draw.lua、common/game_cfg.lua | tests/native/spec/15_blindbox_placeholder_settlement_test.lua、tests/native/blindbox_draw_test.lua | 有 | 缺 | 缺 | 缺 | a |
| 15-10 | common/blindbox_draw.lua、common/game_cfg.lua | tests/native/spec/15_blindbox_placeholder_settlement_test.lua | 有 | 缺 | 缺 | 缺 | a |
| 15-11 | common/blindbox_draw.lua、common/game_cfg.lua | tests/native/spec/15_blindbox_placeholder_settlement_test.lua | 有 | 缺 | 缺 | 缺 | a |
| 15-12 | server/world_host/player_blindbox.lua、server/save_host.lua | tests/native/blindbox_settle_test.lua | 缺 | 缺 | 缺 | 缺 | b |
| 15-13 | common/game_cfg.lua、common/blindbox_draw.lua | tests/native/blindbox_draw_test.lua、tests/native/cfg_shop_lottery_test.lua | 缺 | 缺 | 缺 | 缺 | a |
| 15-14 | common/game_cfg.lua、common/blindbox_draw.lua | tests/native/blindbox_draw_test.lua | 缺 | 缺 | 缺 | 缺 | a |
| 15-15 | server/world_host/player_blindbox.lua、server/save_host.lua | tests/native/blindbox_settle_test.lua | 缺 | 缺 | 有 | 缺 | b |
| 15-16 | server/world_host/player_blindbox.lua、server/world_host/ground_loot.lua | tests/native/blindbox_settle_test.lua | 缺 | 缺 | 缺 | 有 | b |
| 15-17 | common/game_cfg.lua、server/world_host/player_blindbox.lua | tests/native/content_validation_test.lua | 缺 | 缺 | 缺 | 缺 | a |
| 15-21 | common/game_cfg.lua、server/platform_host.lua、client/views/blindbox_view.lua | tests/native/spec/15_blindbox_placeholder_settlement_test.lua | 有 | 有 | 缺 | 缺 | a |

第 15 节的 15-01、15-09～15-11、15-21 已由占位支付通道的公开入口取证（价目 10 / 90 金豆同一通道收费、
确认前不发奖、取消与超时不到账、第 50 抽强制保底、大奖清零计数）。15-21 原挂 C 级试玩口径，
按 ADR-0029 生产开关把「占位通道」判给 agent，真实平台支付通道作为生产开关单列。

### 第 16 节 物品基础数据（17 条）

| 条款 | 代码落点 | 关联测试 | 正常流程 | 失败流程 | 退出重进 | 存档恢复 | 等级 |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 16-01 | common/cfg/items.lua、common/content_validation.lua | tests/native/cfg_fish_items_test.lua、tests/native/content_validation_test.lua | 缺 | 缺 | 缺 | 缺 | a |
| 16-02 | common/cfg/items.lua | tests/native/cfg_fish_items_test.lua | 缺 | 缺 | 缺 | 缺 | a |
| 16-03 | common/cfg/items.lua | tests/native/cfg_fish_items_test.lua | 缺 | 缺 | 缺 | 缺 | a |
| 16-04 | common/cfg/items.lua、server/world_host/player_life.lua | tests/native/spec/16_item_base_data_test.lua、tests/native/spec/server_life_phase_298_test.lua | 有 | 缺 | 缺 | 缺 | a |
| 16-05 | common/cfg/items.lua、server/world_host/special_item_phase.lua | tests/native/spec/server_special_item_299_test.lua | 缺 | 缺 | 缺 | 缺 | a |
| 16-06 | common/cfg/items.lua、server/world_host/player_life.lua | tests/native/spec/16_item_base_data_test.lua、tests/native/spec/server_life_phase_298_test.lua | 缺 | 有 | 缺 | 缺 | a |
| 16-07 | common/cfg/items.lua、server/world_host/player_life.lua | tests/native/spec/16_item_base_data_test.lua、tests/native/spec/server_life_phase_298_test.lua | 有 | 缺 | 缺 | 缺 | a |
| 16-08 | common/cfg/items.lua、common/content_validation.lua | tests/native/content_validation_test.lua | 缺 | 缺 | 缺 | 缺 | a |
| 16-09 | common/cfg/items.lua、server/world_host/player_fisherman.lua | — | 缺 | 缺 | 缺 | 缺 | a |
| 16-10 | common/cfg/items.lua | tests/native/cfg_fish_items_test.lua | 缺 | 缺 | 缺 | 缺 | a |
| 16-11 | common/cfg/items.lua | tests/native/cfg_fish_items_test.lua | 缺 | 缺 | 缺 | 缺 | a |
| 16-12 | common/cfg/items.lua | tests/native/cfg_fish_items_test.lua | 缺 | 缺 | 缺 | 缺 | a |
| 16-13 | common/cfg/items.lua、common/game_cfg.lua、common/cfg/content_ledger.lua | tests/native/cfg_fish_items_test.lua、tests/native/content_validation_test.lua | 缺 | 缺 | 缺 | 缺 | b |
| 16-14 | common/cfg/items.lua、common/content_validation.lua | tests/native/content_validation_test.lua | 缺 | 缺 | 缺 | 缺 | b |
| 16-15 | common/cfg/items.lua、server/world_host/ground_loot.lua | tests/native/fish_loot_test.lua | 缺 | 缺 | 缺 | 缺 | b |
| 16-16 | common/cfg/items.lua、common/cfg/placeholder_assets.lua | tests/native/placeholder_assets_test.lua | 缺 | 缺 | 缺 | 缺 | b |
| 16-17 | common/cfg/items.lua、common/game_cfg.lua | tests/native/cfg_fish_items_test.lua | 缺 | 缺 | 缺 | 缺 | b |

第 16 节的 16-04、16-06、16-07 已由服务端 player_life（server_runtime.life）的公开食用入口取证：食物 / 极品食物 / 鱼饵全部可吃，
其余类别一律拒绝；负恢复项吃后扣饥饿并扣血。16-13 的「实现标记只有一份真源」由 common/cfg/content_ledger.lua
与 common/content_validation.lua 的一致性门禁守住。

### 第 17 节 新手任务、剧情与平台边界（22 条）

| 条款 | 代码落点 | 关联测试 | 正常流程 | 失败流程 | 退出重进 | 存档恢复 | 等级 |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 17-01 | common/game_cfg.lua、server/world_host/player_quest.lua | tests/native/spec/server_progress_315_test.lua | 缺 | 缺 | 缺 | 缺 | a |
| 17-02 | common/game_cfg.lua、server/world_host/player_quest.lua | tests/native/spec/server_progress_315_test.lua | 缺 | 缺 | 缺 | 缺 | a |
| 17-03 | server/world_host/player_quest.lua | tests/native/spec/server_progress_315_test.lua | 缺 | 缺 | 缺 | 缺 | a |
| 17-04 | server/world_host/player_quest.lua、server/save_host.lua、server/data/player_data.lua | tests/native/spec/server_progress_315_test.lua、tests/native/save_test.lua | 缺 | 缺 | 缺 | 缺 | b |
| 17-05 | server/world_host/player_quest.lua | tests/native/spec/server_progress_315_test.lua | 缺 | 缺 | 缺 | 缺 | a |
| 17-06 | common/game_cfg.lua、server/player_data_host.lua | tests/native/spec/client_progress_315_test.lua | 缺 | 缺 | 缺 | 缺 | a |
| 17-07 | common/game_cfg.lua、common/cfg/shop.lua、server/world_host/player_shop.lua | tests/native/spec/server_progress_315_test.lua、tests/native/shop_test.lua | 缺 | 缺 | 缺 | 缺 | a |
| 17-08 | server/world_host/player_story.lua、client/views/story_view.lua | tests/native/spec/server_progress_315_test.lua、tests/native/spec/client_progress_315_test.lua | 缺 | 缺 | 缺 | 缺 | a |
| 17-09 | server/world_host/player_story.lua、client/views/story_view.lua | tests/native/spec/server_progress_315_test.lua、tests/native/spec/client_progress_315_test.lua | 缺 | 缺 | 缺 | 缺 | a |
| 17-10 | server/world_host/player_story.lua、server/data/player_data.lua | tests/native/spec/server_progress_315_test.lua、tests/native/spec/client_progress_315_test.lua | 缺 | 缺 | 缺 | 缺 | b |
| 17-11 | common/npc_dialogue.lua、server/world_host/player_story.lua | — | 缺 | 缺 | 缺 | 缺 | a |
| 17-12 | common/npc_dialogue.lua、server/world_host/player_story.lua | — | 缺 | 缺 | 缺 | 缺 | a |
| 17-13 | common/npc_dialogue.lua、server/world_host/player_story.lua | — | 缺 | 缺 | 缺 | 缺 | a |
| 17-14 | server/world_host/player_story.lua | — | 缺 | 缺 | 缺 | 缺 | b |
| 17-15 | server/world_host/player_shop.lua、server/platform_host.lua、common/game_cfg.lua | tests/native/shop_test.lua、tests/native/platform_seam_test.lua | 缺 | 缺 | 缺 | 缺 | b |
| 17-16 | server/platform_host.lua、common/game_cfg.lua | tests/native/platform_seam_test.lua | 缺 | 缺 | 缺 | 缺 | b |
| 17-17 | server/world_host/player_achievements.lua、common/game_cfg.lua | tests/native/spec/server_progress_315_test.lua | 有 | 有 | 缺 | 缺 | b |
| 17-18 | server/platform_host.lua、common/game_cfg.lua | tests/native/spec/17_platform_boundary_placeholder_test.lua | 有 | 有 | 缺 | 缺 | b |
| 17-19 | common/cfg/placeholder_assets.lua | tests/native/placeholder_assets_test.lua | 缺 | 缺 | 缺 | 缺 | a |
| 17-20 | server/platform_host.lua、server/world_host/world_records.lua | tests/native/platform_seam_test.lua、tests/native/records_test.lua | 缺 | 缺 | 缺 | 缺 | b |
| 17-21 | server/platform_host.lua、common/game_cfg.lua | tests/native/platform_seam_test.lua | 缺 | 缺 | 缺 | 缺 | a |
| 17-22 | server/platform_host.lua、common/game_cfg.lua | tests/native/platform_seam_test.lua | 缺 | 缺 | 缺 | 缺 | a |

第 17 节的 17-17 由平台成就占位 ID 的完成与补交换配置取证，17-18 由分享占位入口取证；其余条款先登记落点，断言待后续。

### 第 18 节 存档与恢复契约（32 条）

| 条款 | 代码落点 | 关联测试 | 正常流程 | 失败流程 | 退出重进 | 存档恢复 | 等级 |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 18-01 | server/data/player_data.lua、server/save_host.lua | tests/native/spec/18_session_settlement_contract_test.lua | 有 | 有 | 有 | 有 | b |
| 18-02 | server/data/player_data.lua、server/save_host.lua | tests/native/spec/18_session_settlement_contract_test.lua | 有 | 缺 | 缺 | 有 | b |
| 18-03 | server/data/player_data.lua、server/world_host/player_weapon.lua | — | 缺 | 缺 | 缺 | 缺 | b |
| 18-04 | server/data/player_data.lua、server/world_host/player_shop.lua | tests/native/spec/18_session_settlement_contract_test.lua | 有 | 缺 | 缺 | 有 | b |
| 18-05 | server/data/player_data.lua、server/world_host/player_life.lua | tests/native/spec/18_session_settlement_contract_test.lua | 有 | 缺 | 有 | 有 | b |
| 18-06 | server/world_host/player_life.lua、server/data/player_data.lua | tests/native/spec/18_session_settlement_contract_test.lua | 有 | 缺 | 缺 | 有 | b |
| 18-07 | server/world_host/player_compendium.lua、server/data/player_data.lua | tests/native/spec/18_session_settlement_contract_test.lua | 有 | 缺 | 缺 | 有 | b |
| 18-08 | server/world_host/player_quest.lua、server/world_host/player_story.lua | tests/native/spec/18_session_settlement_contract_test.lua | 有 | 缺 | 缺 | 有 | b |
| 18-09 | server/world_host/ferry_route.lua、server/data/player_data.lua | tests/native/spec/18_session_settlement_contract_test.lua | 有 | 缺 | 缺 | 有 | b |
| 18-10 | server/data/player_data.lua、server/save_host.lua | tests/native/spec/18_session_settlement_contract_test.lua | 有 | 有 | 有 | 有 | b |
| 18-11 | server/world_host/player_blindbox.lua、server/data/player_data.lua | tests/native/spec/18_session_settlement_contract_test.lua | 有 | 缺 | 缺 | 有 | b |
| 18-12 | server/world_host/player_achievements.lua、server/data/player_data.lua | tests/native/spec/18_session_settlement_contract_test.lua | 有 | 缺 | 缺 | 有 | b |
| 18-13 | server/save_host.lua、server/world_host/ferry_route.lua | tests/native/spec/18_session_settlement_contract_test.lua | 有 | 有 | 有 | 有 | b |
| 18-14 | server/world_host/player_weapon.lua、server/data/player_data.lua | — | 缺 | 缺 | 缺 | 缺 | b |
| 18-15 | server/world_host/player_weapon.lua、server/save_host.lua | tests/native/weapon_system_test.lua | 缺 | 缺 | 缺 | 缺 | b |
| 18-16 | server/data/player_data.lua | tests/native/spec/18_session_settlement_contract_test.lua | 有 | 缺 | 缺 | 有 | b |
| 18-17 | server/data/player_data.lua | tests/native/spec/18_session_settlement_contract_test.lua | 有 | 缺 | 缺 | 有 | b |
| 18-18 | server/data/player_data.lua、server/save_host.lua | tests/native/spec/18_session_settlement_contract_test.lua | 有 | 有 | 缺 | 有 | b |
| 18-19 | server/main.lua、server/save_host.lua | tests/native/spec/18_session_settlement_contract_test.lua | 有 | 有 | 缺 | 缺 | b |
| 18-20 | server/save_host.lua、server/main.lua | tests/native/spec/18_session_settlement_contract_test.lua | 有 | 有 | 有 | 有 | b |
| 18-21 | server/save_host.lua | tests/native/spec/18_session_settlement_contract_test.lua | 有 | 有 | 缺 | 有 | b |
| 18-22 | server/save_host.lua | tests/native/spec/18_session_settlement_contract_test.lua | 有 | 有 | 缺 | 有 | b |
| 18-23 | server/save_host.lua、server/world_host/player_shop.lua | tests/native/spec/18_session_settlement_contract_test.lua | 有 | 有 | 有 | 有 | b |
| 18-24 | server/save_host.lua、server/world_host/ferry_route.lua、server/platform_host.lua | tests/native/spec/18_session_settlement_contract_test.lua | 有 | 有 | 有 | 有 | b |
| 18-25 | server/world_host/ferry_route.lua、server/save_host.lua | tests/native/ferry_test.lua | 缺 | 缺 | 缺 | 缺 | b |
| 18-26 | server/platform_host.lua | — | 缺 | 缺 | 缺 | 缺 | b |
| 18-27 | server/data/player_data.lua、server/world_host/ground_loot.lua | tests/native/spec/18_session_settlement_contract_test.lua | 有 | 缺 | 缺 | 有 | b |
| 18-28 | server/world_host/player_lottery.lua、server/save_host.lua | tests/native/lottery_settle_test.lua | 缺 | 缺 | 缺 | 缺 | b |
| 18-29 | server/world_host/player_fisherman.lua、server/save_host.lua | tests/native/economy_persistence_test.lua | 缺 | 缺 | 缺 | 缺 | b |
| 18-30 | server/world_host/player_grill.lua、server/main.lua | tests/native/grill_test.lua | 缺 | 缺 | 缺 | 缺 | b |
| 18-31 | server/save_host.lua、server/data/player_data.lua | tests/native/spec/18_session_settlement_contract_test.lua | 有 | 有 | 有 | 有 | b |
| 18-32 | server/main.lua、server/player_data_host.lua | tests/native/player_leave_rejoin_test.lua | 缺 | 缺 | 缺 | 缺 | b |

### 第 11 节 濒死、死亡与复活（39 条非试玩条款）

| 条款 | 代码落点 | 关联测试 | 正常流程 | 失败流程 | 退出重进 | 存档恢复 | 等级 |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 11-01 | server/world_host/player_life.lua、server/world_host/player_life.lua | tests/native/spec/09_rescue_test.lua | 有 | 缺 | 缺 | 缺 | a |
| 11-02 | server/world_host/player_life.lua、client/views/survival_overlay_view.lua | tests/native/spec/server_life_phase_298_test.lua | 缺 | 缺 | 缺 | 缺 | a |
| 11-03 | server/world_host/player_life.lua、server/world_host/player_life.lua | tests/native/spec/09_rescue_test.lua | 缺 | 有 | 缺 | 缺 | a |
| 11-04 | common/game_cfg.lua、server/world_host/player_life.lua | tests/native/spec/server_life_phase_298_test.lua | 缺 | 缺 | 缺 | 缺 | a |
| 11-05 | server/world_host/player_life.lua、server/world_host/player_life.lua | tests/native/spec/server_life_phase_298_test.lua | 缺 | 缺 | 缺 | 缺 | a |
| 11-06 | server/world_host/player_life.lua、common/game_cfg.lua | tests/native/spec/09_rescue_test.lua | 有 | 缺 | 缺 | 缺 | a |
| 11-07 | server/world_host/player_life.lua、server/player_data_host.lua | tests/native/spec/server_life_phase_298_test.lua | 缺 | 缺 | 缺 | 缺 | a |
| 11-08 | client/views/survival_overlay_view.lua、server/platform_host.lua | tests/native/platform_screens_test.lua | 缺 | 缺 | 缺 | 缺 | a |
| 11-09 | client/views/survival_overlay_view.lua、server/world_host/player_life.lua | tests/native/spec/server_life_phase_298_test.lua | 缺 | 缺 | 缺 | 缺 | a |
| 11-10 | server/world_host/player_life.lua、common/game_cfg.lua | tests/native/spec/server_life_phase_298_test.lua | 缺 | 缺 | 缺 | 缺 | a |
| 11-11 | server/world_host/player_life.lua、common/game_cfg.lua | tests/native/spec/server_life_phase_298_test.lua | 缺 | 缺 | 缺 | 缺 | a |
| 11-12 | server/world_host/player_life.lua、server/world_host/player_life.lua、common/game_cfg.lua | tests/native/spec/server_life_phase_298_test.lua | 缺 | 缺 | 缺 | 缺 | a |
| 11-13 | server/world_host/player_life.lua、server/world_host/player_life.lua、common/game_cfg.lua | tests/native/spec/server_life_phase_298_test.lua | 缺 | 缺 | 缺 | 缺 | a |
| 11-14 | server/world_host/player_life.lua、server/world_host/modifier_leaf.lua、common/game_cfg.lua | tests/native/spec/server_life_phase_298_test.lua | 缺 | 缺 | 缺 | 缺 | a |
| 11-15 | server/world_host/player_life.lua、server/world_host/player_life.lua | tests/native/spec/server_life_phase_298_test.lua | 缺 | 缺 | 缺 | 缺 | a |
| 11-16 | server/player_data_host.lua、server/save_host.lua、server/world_host/player_life.lua | tests/native/spec/18_session_settlement_contract_test.lua | 缺 | 缺 | 缺 | 有 | a |
| 11-17 | server/world_host/fishing_phase.lua、server/world_host/fish_tree.lua、server/world_host/player_life.lua | tests/native/fish_lift_test.lua | 缺 | 缺 | 缺 | 缺 | a |
| 11-18 | server/world_host/fish_tree.lua、server/world_host/player_life.lua | tests/native/fish_lift_test.lua | 缺 | 缺 | 缺 | 缺 | a |
| 11-19 | client/views/survival_overlay_view.lua、server/world_host/player_life.lua、server/platform_host.lua、common/game_cfg.lua | tests/native/spec/11_ad_revive_placeholder_test.lua | 有 | 有 | 缺 | 缺 | a |
| 11-20 | client/views/survival_overlay_view.lua、server/platform_host.lua、server/world_host/player_shop.lua | tests/native/platform_screens_test.lua | 缺 | 缺 | 缺 | 缺 | a |
| 11-21 | server/world_host/player_life.lua、server/world_host/player_life.lua、common/game_cfg.lua | tests/native/spec/11_ad_revive_placeholder_test.lua | 有 | 缺 | 缺 | 缺 | a |
| 11-22 | server/world_host/player_life.lua、server/world_host/modifier_leaf.lua | tests/native/spec/11_ad_revive_placeholder_test.lua | 有 | 缺 | 缺 | 缺 | a |
| 11-23 | common/cfg/shop.lua、server/world_host/player_shop.lua | tests/native/shop_test.lua | 缺 | 缺 | 缺 | 缺 | a |
| 11-24 | common/cfg/shop.lua、server/world_host/player_shop.lua | tests/native/shop_test.lua | 缺 | 缺 | 缺 | 缺 | a |
| 11-25 | server/world_host/player_life.lua、server/save_host.lua、server/data/player_data.lua | tests/native/spec/09_rescue_test.lua | 缺 | 缺 | 有 | 有 | a |
| 11-26 | server/world_host/ferry_route.lua、server/world_host/player_life.lua、server/data/player_data.lua | tests/native/spec/18_session_settlement_contract_test.lua | 缺 | 缺 | 有 | 有 | a |
| 11-27 | server/world_host/player_life.lua、server/world_host/modifier_leaf.lua、server/data/player_data.lua | tests/native/spec/server_life_phase_298_test.lua | 缺 | 缺 | 有 | 有 | a |
| 11-28 | server/world_host/player_life.lua、server/platform_host.lua | tests/native/spec/11_ad_revive_placeholder_test.lua | 有 | 有 | 缺 | 缺 | b |
| 11-29 | server/world_host/player_life.lua、server/platform_host.lua、common/game_cfg.lua | tests/native/spec/11_ad_revive_placeholder_test.lua | 有 | 有 | 缺 | 缺 | b |
| 11-30 | server/world_host/player_life.lua、server/platform_host.lua | tests/native/spec/11_ad_revive_placeholder_test.lua | 有 | 有 | 缺 | 缺 | b |
| 11-31 | server/platform_host.lua、server/world_host/player_life.lua、common/game_cfg.lua | tests/native/spec/11_ad_revive_placeholder_test.lua | 有 | 有 | 缺 | 缺 | b |
| 11-32 | server/world_host/player_life.lua、server/platform_host.lua、common/rate_limit.lua | tests/native/spec/11_ad_revive_placeholder_test.lua | 有 | 有 | 缺 | 缺 | b |
| 11-33 | server/world_host/player_life.lua、server/platform_host.lua | tests/native/spec/11_ad_revive_placeholder_test.lua | 缺 | 缺 | 缺 | 缺 | b |
| 11-34 | server/world_host/player_life.lua、server/world_host/player_life.lua、common/game_cfg.lua | tests/native/spec/09_rescue_test.lua | 缺 | 有 | 缺 | 缺 | b |
| 11-35 | server/world_host/player_life.lua、server/save_host.lua、server/data/player_data.lua | tests/native/spec/09_rescue_test.lua | 缺 | 缺 | 有 | 有 | b |
| 11-36 | server/world_host/player_life.lua、server/world_host/player_life.lua | tests/native/spec/09_rescue_test.lua | 有 | 缺 | 缺 | 缺 | b |
| 11-37 | server/platform_host.lua、server/world_host/player_life.lua、common/game_cfg.lua | tests/native/spec/11_ad_revive_placeholder_test.lua | 有 | 有 | 缺 | 缺 | b |
| 11-38 | server/platform_host.lua、common/game_cfg.lua | tests/native/spec/11_ad_revive_placeholder_test.lua | 有 | 有 | 缺 | 缺 | a |
| 11-39 | server/platform_host.lua、server/save_host.lua、common/game_cfg.lua | tests/native/platform_seam_test.lua | 缺 | 有 | 缺 | 缺 | a |

第 11 节由 #254 抢救子单整节登记：11-01、11-03、11-06、11-34、11-35、11-36 的证据走 `tests/native/spec/09_rescue_test.lua`
（致命伤害锁血、濒死免伤、呼救、其它伤害来源豁免、断线重连结算与血量夹取）；其余条款的代码落点与关联测试是实现自检，
状态仍是 unverified，等各自实现与断言。抢救耗时与打断规则的占位值集中在 `common/game_cfg.lua` 的 `game_cfg.Rescue`，
带 [未查证] 标记，待决题见 docs/to-questionnaire-策划案内部矛盾.md。

广告满血复活一组由 #262 登记：11-19、11-21、11-22、11-28～11-32、11-37、11-38 的证据统一走
`tests/native/spec/11_ad_revive_placeholder_test.lua`（濒死与死亡两个界面的广告入口、满血与饥饿下限、
倒计时暂停与平移、三条复活路径互斥、失败不扣费、重复点击与迟到回调、适配层成功与失败两条路径）。
占位广告位与广告文案集中在 `common/game_cfg.lua` 的 `game_cfg.Platform.Placeholder.Ads`、`game_cfg.Platform.Ads`
与 `game_cfg.Survival.AdReviveText`；真实广告位到位只替换那两处参数，判定不动。占位通道另有一道构建闸门
（`game_cfg.Platform.Placeholder.AllowInPublish`，默认 false）：关闭调试且未显式打开时，广告复活经
SurvivalAction 被拒、不复活，回执写「未开放」——这一条的证据是本文件里同一份 spec 的闸门用例（19-13）。参数缺口记在
docs/to-questionnaire-策划案内部矛盾.md。金豆入口（11-20）、迟到回调补发（11-33）与占位对称结算（11-39）不归本单，
仍是 unverified，四类证据列只勾该断言真正跑过的场景。

### 第 19 节 验收口径（20 条，其中 19-15～19-20 是 C 级试玩条款）

| 条款 | 代码落点 | 关联测试 | 正常流程 | 失败流程 | 退出重进 | 存档恢复 | 等级 |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 19-01 | common/cfg/fish.lua | tests/native/cfg_fish_items_test.lua | 缺 | 缺 | 缺 | 缺 | a |
| 19-02 | common/cfg/items.lua | tests/native/cfg_fish_items_test.lua | 缺 | 缺 | 缺 | 缺 | a |
| 19-03 | common/cfg/shop.lua | tests/native/cfg_shop_lottery_test.lua | 缺 | 缺 | 缺 | 缺 | a |
| 19-04 | common/cfg/lottery.lua | tests/native/cfg_shop_lottery_test.lua | 缺 | 缺 | 缺 | 缺 | a |
| 19-05 | common/cfg/blindbox.lua | tests/native/blindbox_draw_test.lua | 缺 | 缺 | 缺 | 缺 | a |
| 19-06 | common/game_cfg.lua、common/zone_markers.lua | tests/native/ferry_test.lua | 缺 | 缺 | 缺 | 缺 | a |
| 19-07 | server/world_host/player_life.lua、server/platform_host.lua | tests/native/spec/11_ad_revive_placeholder_test.lua、tests/native/spec/09_rescue_test.lua | 缺 | 缺 | 缺 | 缺 | a |
| 19-08 | server/world_host/player_lottery.lua、tests/probes/lottery_runtime.lua、tests/probes/local_link_runtime.lua | tests/native/lottery_draw_test.lua | 有 | 缺 | 缺 | 缺 | b |
| 19-09 | docs/acceptance/README.md、docs/acceptance/evidence-levels.md、tools/acceptance.lua | — | 缺 | 缺 | 缺 | 缺 | a |
| 19-10 | server/save_host.lua、server/data/player_data.lua、docs/acceptance/coverage.md | tests/native/save_test.lua、tests/native/spec/18_session_settlement_contract_test.lua | 缺 | 缺 | 缺 | 有 | a |
| 19-11 | server/save_host.lua、server/platform_host.lua | tests/native/spec/01_platform_adapter_failure_test.lua、tests/native/save_foundation_test.lua | 缺 | 有 | 缺 | 缺 | a |
| 19-12 | server/main.lua、server/world_host/squad_dock.lua、server/world_host/pk_damage_filter.lua、server/world_host/player_fisherman.lua | tests/native/spec/19_multiplayer_local_link_test.lua、tests/native/spec/01_capacity_local_link_test.lua、tests/probes/local_link_runtime.lua | 有 | 有 | 有 | 有 | b |
| 19-13 | server/platform_host.lua、common/game_cfg.lua | tests/native/spec/17_platform_boundary_placeholder_test.lua、tests/native/spec/11_ad_revive_placeholder_test.lua | 有 | 有 | 缺 | 缺 | a |
| 19-14 | tools/acceptance.lua、tools/cli.lua、server/platform_host.lua、common/game_cfg.lua | tests/native/guards/acceptance_matrix_test.lua、tests/native/cli_entry_test.lua | 缺 | 缺 | 缺 | 缺 | b |

第 19 节由 #264 整节登记：19-01～19-06 是数量与结构的静态口径，落点在共享配置，四类证据列都还空着；
19-08 的可重跑探针已就位（`tests/probes/forest_island.lua`、`tests/probes/lottery_runtime.lua`、`tests/probes/local_link_runtime.lua`），
所以「正常流程」勾 `有`，其余三栏留 `缺`。19-12 的证据是 `tests/native/spec/19_multiplayer_local_link_test.lua`：
八条以上虚拟连接同时在线时小队免伤、野外 PK、鱼塘安全区、共享地面实例只结算一次、施救者断线中止抢救与重连不补结算各自成立；
夹具结论只证代码路径，真实多人结论仍是生产开关，不用它替代。
19-13 由两份 spec 断言机器判定：发布构建（Debug 关）且
`game_cfg.Platform.Placeholder.AllowInPublish = false` 时，占位支付、金币页、广告与分享一律被拒
（`reason = 'not_open'`、回执写「未开放」），不发物品、不改金币、不建 flow；显式把开关置 true 才恢复——
所以「失败流程」这一栏也勾 `有`。19-14 的完整发布汇总仍未取证：其余发布检查项（真实渠道、容量、资源）
仍是生产开关，门禁全绿只证明代码路径完整，不作为发布依据。19-15～19-20 是 C 级试玩条款，不进覆盖表。

## 三、待登记小节

已无待登记小节：第 1～19 节全部登记，`tools/acceptance.lua` 的 `M.COVERAGE_SECTIONS` 跟着补到 19；
第 11 节由 #254（抢救）与 #262（广告复活）两组登记完毕。下一节扩大时仍按同一节奏：
先把该节非试玩条款的代码落点与既有测试补齐，再加进 `M.COVERAGE_SECTIONS`。
