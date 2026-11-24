# 0034 本仓自写代码统一 snake_case

**Status**: accepted（2026-11-24；分三层迁移，迁移完成前不得新写 PascalCase）

## 背景

2026-11-24 的 PR #322 为避开 SE 内置服务名把世界宿主改名为 `server/WorldHost`（[ADR-0033](0033-script-names-must-not-shadow-se-services.md)），[CODING_STANDARDS.md](../../CODING_STANDARDS.md) 随后写入命名章，但把**文件、目录与 `require` 命名空间**定为 PascalCase。该条款与本仓其余做法互相打架：

- 官方手册示例文件名几乎全是 snake_case（`common/remote_events.lua`、`client/hud.lua`、`server/round_manager.lua`），唯一 PascalCase 是 `common/TestCommonUtil.lua`；
- 上游包 `spoke`、`spoke_eggy` 整包 snake_case（[ADR-0024](0024-introduce-spoke-eggy-host-package.md)），业务代码却 PascalCase，同一次 `require` 里两种风格并存；
- 该条款自注「人工核对」：无门禁时它不生效。近 30 天三端新增 117 个 PascalCase 路径 vs 4 个 snake_case，就是人工核对的真实效力；
- 文件 PascalCase 还直接制造了 ADR-0033 那类撞名（`World` vs 内置 `World`），snake_case 不具备与 PascalCase 内置名同形的可能（编辑器是否大小写归一仍待实测）。

另一方面，引擎**不强制**任何文件风格；真正被强制的是 `require` 必须与文件名大小写精确一致（[source_guard_test.lua:134](../../tests/native/guards/source_guard_test.lua:134)；本机不区分大小写，换宿主才炸）。所以风格是纯项目选择。

## 决定

**本仓自写代码严格 snake_case；官方与引擎的东西一律原样（大写不管）。** 规则落到四层，逐层迁移：

| 层 | 内容 | 数量 |
| --- | --- | --- |
| L1 | 文件名、目录名、`require` 命名空间 | 121 文件 + 5 目录 + 639 处 `require`（tests 另 304） |
| L2 | 模块表变量名（与文件名逐段同名） | 1154 条声明 / 249 名 / 7830 处引用 |
| L3 | 方法与自研字段名（`DamageFloat:Show` → `damage_float:show`、`GameCfg.DamageFloat.Width` → `GameCfg.damage_float.width`） | 874 个方法定义 + 406 个 `GameCfg` 字段 |
| L4 | 现行文档（`coverage.md`、`architecture.md`、`AGENTS.md`、`workflow.md`） | 571 处 / 25 文件 |

四者同名是最低要求：`common/fish_catch.lua` ↔ `require("common.fish_catch")` ↔ `local fish_catch = ...`。这条取代原命名章里「文件与模块表同名用 PascalCase」与「其余标识符 snake_case」两行并存造成的自相矛盾（`local FishCatch` 是局部变量却按文件规则大写）。

## 官方契约原样（大写不管）

L3 最危险：同一张 table 里既有自研字段也有引擎键，改错一处是运行时静默失效。以下五类**一律原样**：

1. 官方 API 成员（`OnServerEvent` 等）与内置服务名（`World`、`MapData`、`Game`、`Camps`、`*Service`）；
2. EUI 节点与单位属性表键（`Name`、`Text`、`FontSize`、`Parent`、`Visible`、`Opacity` 等），以及 `scope:effect("DamageFloat")` 这类 Spoke 作用域名与运行期单位名字符串；
3. `data/` 导出字段与 `EggyAPI.lua` 等引擎存根；
4. 对应策划表列的配置字段；
5. `packages/` 上游整包（含 `*_Script.lua` / `*_LocalScript.lua` 后缀）、`unit_scripts/`、编辑器生成物（`server/_trigger/`）。

## 迁移分三层落地

L1 的实际落地方式（原计划「按端三个 PR」，执行时改为并行 + 收口）：一个分支、两端各自在独立 worktree 里只做文件改名与 `require` 替换，**共享写面由 root 收口**——`tools/arch_policy.lua` 的 50 个模块 id 与 `:59-64` 前缀棘轮、`policy.edn` 投影、`coverage.md`、六个双端测试（`arch_policy_test`、`weapon_system_test`、`grill_test`、`attr_presentation_test`、`prize_growth_wiring_test`、`spec/11_ad_revive_placeholder_test`）。三端合并后跑一次 `lua tools/cli.lua test full`，再做**一次** `deploy` + 试玩验证。

并行之所以能这么切：`client` 与 `server` 互不 `require`（实测各 0 条），两端重叠的写面只有 6 个双端测试与上述共享文件；`coverage.md` 单行常混两端（如 6-33 行），`arch_policy.lua` 有 9 行同一行同时出现 client 与 server 命名，`policy.edn` 的 `:levels` 是单行——这三处正是并行改必然冲突、且错了不报错的地方。

门禁在 L1 完成后开启（先开会让全仓常红）：三端文件名与目录名必须 snake_case，豁免名单外一律失败；`require` 大小写精确匹配已有守卫。

## 与 ADR-0033 的关系

ADR-0033 的「新增目录或脚本前逐个核对内置服务名」保留为核对项。snake_case 让同形撞名在**区分大小写**的判定下不可能发生，但「编辑器是否归一化大小写」至今无依据，故需一次实测（宿主建 `server/world_probe/` → `deploy` → 推送 → 看是否报 `warn/editor` → 回滚），结果回填本节与 ADR-0033。实测未做前，不得宣称撞名风险已消除。

## 拒绝的备选方案

- **只改文件名，模块表仍 PascalCase**：`local GameCfg = require("common.game_cfg")` 让「文件叫什么」与「变量叫什么」两套规则并存，观感与现状几乎无差别。
- **L3 只约束新增代码**：存量 874 个方法与 406 个字段是「代码看起来还是 PascalCase」的主因，只约束新增等于永远不统一。
- **一次性单 PR 改完四层**：639 处 `require` + 571 处文档 + 7830 处引用挤在一个 diff 里，review 与回滚都无法定位。
- **保留 PascalCase 文件层**（2026-11-24 上午写入的条款）：见「背景」四条反证。

## 后果

- `arch_policy.lua` 的 id 与前缀棘轮不同步时门禁会**静默放行**——L1 每个 PR 必须同批检查 `:59-64` 的 `'^client%.Store$'`、`'^client%.Views%.'`、`'^server%.WorldHost%.'` 前缀。
- `coverage.md` 的 494 处 landing / test 路径有 [acceptance_matrix_test](../../tests/native/guards/acceptance_matrix_test.lua) 守着，不改就红；`policy.edn:7` 与 `docs/uml/se-fish.edn` 是生成物，改名后重新生成而不手编。
- `client/InteractionBubble.lua` 全仓无任何 `require`（只有 `GameCfg:26` 一个配置键），是疑似死代码；L1 照改，不顺手删。
- 历史记录（`docs/adr/00xx` 正文、`evidence/`）里的旧名不改，以本文件附录的映射表兜底。
- **棘轮前缀写成 Lua 模式**：`'^server%.WorldHost%.'` 里是 `%.` 而不是 `.`，普通的「命名空间 token 替换」覆盖不到它。L1 时这条漏改过，`arch_policy` 的门禁当场静默失效——抓到它的是 `spoke_ratchet_guard_test` 的反向依赖用例，不是 arch_policy 自己的测试。凡是从命名空间派生的**模式串**，改名后必须单独扫一遍 `%.` + 大写字母的形态。
- **守卫里硬编码命名约定的启发式**：`static_require_test` 的宿主发现靠 `^(.+Host)%.lua$` 匹配「名字以 Host 结尾」，改成 snake_case 后一个都扫不到。改名要让这类启发式跟着换（`^(.+_host)%.lua$`），否则守卫从「拦住问题」静默变成「永远失败」或「永远通过」。

## 附录：L1 旧名 → 新名

目录（5 个）：

- `client/Store → client/store`
- `client/Views → client/views`
- `server/Data → server/data`
- `server/WorldHost → server/world_host`
- `server/AbilityBehaviors → server/ability_behaviors`

`common/`（40 个文件）：

| 旧路径 → 新路径 | 旧路径 → 新路径 |
| --- | --- |
| `common/AiTargetPolicy.lua → common/ai_target_policy.lua` | `common/AttrGrowth.lua → common/attr_growth.lua` |
| `common/AttrModel.lua → common/attr_model.lua` | `common/BlindboxDraw.lua → common/blindbox_draw.lua` |
| `common/BodyScale.lua → common/body_scale.lua` | `common/BossPhase.lua → common/boss_phase.lua` |
| `common/CarryMount.lua → common/carry_mount.lua` | `common/ContentValidation.lua → common/content_validation.lua` |
| `common/DamageNotice.lua → common/damage_notice.lua` | `common/FishCatch.lua → common/fish_catch.lua` |
| `common/FlightPath.lua → common/flight_path.lua` | `common/GameCfg.lua → common/game_cfg.lua` |
| `common/GarBiteNotice.lua → common/gar_bite_notice.lua` | `common/GrillCurve.lua → common/grill_curve.lua` |
| `common/HostSignal.lua → common/host_signal.lua` | `common/LotteryDraw.lua → common/lottery_draw.lua` |
| `common/LotteryEligibility.lua → common/lottery_eligibility.lua` | `common/MathWaterJudge.lua → common/math_water_judge.lua` |
| `common/NpcDialogue.lua → common/npc_dialogue.lua` | `common/Number.lua → common/number.lua` |
| `common/QuestSteps.lua → common/quest_steps.lua` | `common/REUtil.lua → common/re_util.lua` |
| `common/RateLimit.lua → common/rate_limit.lua` | `common/Records.lua → common/records.lua` |
| `common/ReelDisplay.lua → common/reel_display.lua` | `common/ReelProgress.lua → common/reel_progress.lua` |
| `common/SpecialItem.lua → common/special_item.lua` | `common/SpokeClock.lua → common/spoke_clock.lua` |
| `common/TeleportUtil.lua → common/teleport_util.lua` | `common/Util.lua → common/util.lua` |
| `common/Vitals.lua → common/vitals.lua` | `common/ZoneMarkers.lua → common/zone_markers.lua` |
| `common/cfg/Blindbox.lua → common/cfg/blindbox.lua` | `common/cfg/BossMoves.lua → common/cfg/boss_moves.lua` |
| `common/cfg/ContentLedger.lua → common/cfg/content_ledger.lua` | `common/cfg/Fish.lua → common/cfg/fish.lua` |
| `common/cfg/Items.lua → common/cfg/items.lua` | `common/cfg/Lottery.lua → common/cfg/lottery.lua` |
| `common/cfg/PlaceholderAssets.lua → common/cfg/placeholder_assets.lua` | `common/cfg/Shop.lua → common/cfg/shop.lua` |

`server/`（44 个文件）：

| 旧路径 → 新路径 | 旧路径 → 新路径 |
| --- | --- |
| `server/AbilityAPI.lua → server/ability_api.lua` | `server/Data/PlayerData.lua → server/data/player_data.lua` |
| `server/Data/RecordsAdapter.lua → server/data/records_adapter.lua` | `server/FishAbility.lua → server/fish_ability.lua` |
| `server/FishBehaviors.lua → server/fish_behaviors.lua` | `server/PlatformHost.lua → server/platform_host.lua` |
| `server/PlayerDataHost.lua → server/player_data_host.lua` | `server/SaveHost.lua → server/save_host.lua` |
| `server/SwingRegistry.lua → server/swing_registry.lua` | `server/WorldHost/AbilityLeaf.lua → server/world_host/ability_leaf.lua` |
| `server/WorldHost/AttrLeaf.lua → server/world_host/attr_leaf.lua` | `server/WorldHost/FerryRoute.lua → server/world_host/ferry_route.lua` |
| `server/WorldHost/FishAi.lua → server/world_host/fish_ai.lua` | `server/WorldHost/FishAiTarget.lua → server/world_host/fish_ai_target.lua` |
| `server/WorldHost/FishCarrier.lua → server/world_host/fish_carrier.lua` | `server/WorldHost/FishTree.lua → server/world_host/fish_tree.lua` |
| `server/WorldHost/FishingPhase.lua → server/world_host/fishing_phase.lua` | `server/WorldHost/GroundLoot.lua → server/world_host/ground_loot.lua` |
| `server/WorldHost/HeldRodLeaf.lua → server/world_host/held_rod_leaf.lua` | `server/WorldHost/InteractionPoints.lua → server/world_host/interaction_points.lua` |
| `server/WorldHost/LifeFacade.lua → server/world_host/life_facade.lua` | `server/WorldHost/ModifierLeaf.lua → server/world_host/modifier_leaf.lua` |
| `server/WorldHost/PkDamageFilter.lua → server/world_host/pk_damage_filter.lua` | `server/WorldHost/PlayerAchievements.lua → server/world_host/player_achievements.lua` |
| `server/WorldHost/PlayerBlindbox.lua → server/world_host/player_blindbox.lua` | `server/WorldHost/PlayerCompendium.lua → server/world_host/player_compendium.lua` |
| `server/WorldHost/PlayerEffects.lua → server/world_host/player_effects.lua` | `server/WorldHost/PlayerFisherman.lua → server/world_host/player_fisherman.lua` |
| `server/WorldHost/PlayerGM.lua → server/world_host/player_gm.lua` | `server/WorldHost/PlayerGrill.lua → server/world_host/player_grill.lua` |
| `server/WorldHost/PlayerLife.lua → server/world_host/player_life.lua` | `server/WorldHost/PlayerLottery.lua → server/world_host/player_lottery.lua` |
| `server/WorldHost/PlayerPlatformShop.lua → server/world_host/player_platform_shop.lua` | `server/WorldHost/PlayerQuest.lua → server/world_host/player_quest.lua` |
| `server/WorldHost/PlayerShop.lua → server/world_host/player_shop.lua` | `server/WorldHost/PlayerStory.lua → server/world_host/player_story.lua` |
| `server/WorldHost/PlayerTree.lua → server/world_host/player_tree.lua` | `server/WorldHost/PlayerWeapon.lua → server/world_host/player_weapon.lua` |
| `server/WorldHost/ServerRuntime.lua → server/world_host/server_runtime.lua` | `server/WorldHost/SharedWorldTree.lua → server/world_host/shared_world_tree.lua` |
| `server/WorldHost/SpecialItemPhase.lua → server/world_host/special_item_phase.lua` | `server/WorldHost/SquadDock.lua → server/world_host/squad_dock.lua` |
| `server/WorldHost/WorldRecords.lua → server/world_host/world_records.lua` | `server/WorldHost/WorldSignalRouter.lua → server/world_host/world_signal_router.lua` |

`client/`（37 个文件）：

| 旧路径 → 新路径 | 旧路径 → 新路径 |
| --- | --- |
| `client/DamageFloat.lua → client/damage_float.lua` | `client/GameUI.lua → client/game_ui.lua` |
| `client/InteractionBubble.lua → client/interaction_bubble.lua` | `client/MainHudLayout.lua → client/main_hud_layout.lua` |
| `client/PressGesture.lua → client/press_gesture.lua` | `client/Store/ClientStore.lua → client/store/client_store.lua` |
| `client/Views/AttackView.lua → client/views/attack_view.lua` | `client/Views/BlindboxView.lua → client/views/blindbox_view.lua` |
| `client/Views/CameraZoomView.lua → client/views/camera_zoom_view.lua` | `client/Views/CastSourceView.lua → client/views/cast_source_view.lua` |
| `client/Views/CompendiumView.lua → client/views/compendium_view.lua` | `client/Views/EconomyModal.lua → client/views/economy_modal.lua` |
| `client/Views/FerryView.lua → client/views/ferry_view.lua` | `client/Views/FishCombatView.lua → client/views/fish_combat_view.lua` |
| `client/Views/FishermanView.lua → client/views/fisherman_view.lua` | `client/Views/GMView.lua → client/views/gm_view.lua` |
| `client/Views/GrillView.lua → client/views/grill_view.lua` | `client/Views/GroundLootView.lua → client/views/ground_loot_view.lua` |
| `client/Views/GuideView.lua → client/views/guide_view.lua` | `client/Views/LotteryInteraction.lua → client/views/lottery_interaction.lua` |
| `client/Views/LotteryView.lua → client/views/lottery_view.lua` | `client/Views/MainHudActionButtonsView.lua → client/views/main_hud_action_buttons_view.lua` |
| `client/Views/MainHudBackpackView.lua → client/views/main_hud_backpack_view.lua` | `client/Views/MainHudEquipPopups.lua → client/views/main_hud_equip_popups.lua` |
| `client/Views/MainHudItemBarView.lua → client/views/main_hud_item_bar_view.lua` | `client/Views/MainHudVitalsView.lua → client/views/main_hud_vitals_view.lua` |
| `client/Views/MessageView.lua → client/views/message_view.lua` | `client/Views/PlatformShopView.lua → client/views/platform_shop_view.lua` |
| `client/Views/ReelOverlayView.lua → client/views/reel_overlay_view.lua` | `client/Views/RescueView.lua → client/views/rescue_view.lua` |
| `client/Views/RootView.lua → client/views/root_view.lua` | `client/Views/ShopView.lua → client/views/shop_view.lua` |
| `client/Views/SquadView.lua → client/views/squad_view.lua` | `client/Views/StoryView.lua → client/views/story_view.lua` |
| `client/Views/SurvivalOverlayView.lua → client/views/survival_overlay_view.lua` | `client/Views/ViewUtil.lua → client/views/view_util.lua` |
| `client/WeaponAim.lua → client/weapon_aim.lua` |  |
