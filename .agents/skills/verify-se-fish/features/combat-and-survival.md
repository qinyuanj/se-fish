# 战斗、濒死与复活（Combat & Survival）

玩家使用空手、近战、远程武器或投掷物攻击活鱼，并在遭受致命伤害时依次经历濒死（15 秒锁血 1 点、不可行动、免伤可呼救）、死亡（30 秒免费等待原地虚弱复活，或经可替换适配层发起广告/金豆满血复活）与状态恢复。

## Sub-features

- `combat-weapon-hit` — 近战/远程/投掷按统一伤害入口结算并伴随可见出手动作与伤害飘字。
- `survival-downed` — 致命伤害触发濒死（`SurvivalPhase == "downed"`），血量锁 1、饥饿暂停、出现 `SurvivalBanner` 与 15 秒倒计时。
- `survival-free-revive` — 濒死 15 秒到期进入死亡，30 秒后原地免费复活：10% 血量上限、至少 10% 饥饿、60 秒虚弱移速减半（`SurvivalWeak` 提示）。
- `survival-full-revive-placeholder` — 濒死/死亡界面提供 `SurvivalAdRevive`（广告）与 `SurvivalPaidRevive`（5 金豆）入口，占位通道可走通互斥结算与倒计时暂停/恢复（不宣称真实付费权益）。
- `survival-death-preserves-inventory` — 死亡不清空库存与成长；进行中钓鱼终止，已举起的鱼经「放下」入口处理。

## How to get to it (user POV)

- 钓起并放下精英鱼或首领（或持有近战/远程武器接近活鱼），点击主 HUD 攻击按钮发起攻击。
- 在战斗中被鱼击至致命伤害，观察屏幕中央弹出 `SurvivalBanner`（含 `SurvivalTitle`、`SurvivalAdrenaline`、`SurvivalAdRevive`、`SurvivalPaidRevive`）。
- 等待 15 秒进入死亡，再等待 30 秒触发免费原地弱复活，或点击 `SurvivalAdRevive` 测试占位满血复活。

## Driving it with tools/cli.lua & editor-cli

Preconditions:

- `lua .agents/skills/verify-se-fish/scripts/doctor.lua` 退出码为 `0`，使用独立 QA 存档槽且已完成 `deploy`。
- 试玩已就绪，记下 `<session>`。

1. **离线 A/B 级规则验证（武器伤害、目标选择、濒死/死亡/占位复活互斥）**：
   ```bash
   busted tests/native/spec/06_blast_fish_test.lua tests/native/spec/06_shotgun_pellets_test.lua tests/native/spec/06_ai_target_test.lua tests/native/spec/11_ad_revive_placeholder_test.lua tests/native/spec/server_life_phase_298_test.lua tests/native/spec/client_survival_overlay_298_test.lua tests/native/spec/server_weapon_pk_300_test.lua
   ```
   期望退出码 `0`。

2. **记录战前玩家状态（血量/库存/位置）**：
   ```bash
   CLI="$USERPROFILE/.eggitor/cli/editor-cli.exe"
   "$CLI" exec --platform server --file D:/dev/github/se-fish/.agents/skills/verify-se-fish/scripts/probe_online_players.lua --json
   "$CLI" log grep "VERIFY_PLAYERS" --play-session <session> --max-matches 50
   lua tools/cli.lua screenshot --out tmp/verify-se-fish/<run-id>/combat-before.png
   ```

3. **试玩触发战斗与受击濒死**：
   - 按 [solo-fishing-loop.md](solo-fishing-loop.md) 钓起并放下战斗鱼（或在已有活鱼附近接近），点击攻击按钮并用 `lua tools/cli.lua screenshot` 连拍两帧确认出手动作与伤害飘字（条款 `6-35`～`6-37`）；
   - 如验证专项精英战斗循环，可运行对应真机探针（如 `tests/probes/crab_combat_runtime.lua` 或 `shrimp_combat_runtime.lua`）；
   - 受致命伤进入濒死后，立刻抓拍 `survival-downed.png` 并运行 `probe_online_players.lua`，期望看到 `phase=downed` 且画面显示 `SurvivalBanner` 倒计时。

4. **验证免费弱复活与副作用**：
   - 等待 15 秒进入 `dead`，再等待 30 秒观察自动原地复活，抓拍 `survival-revived.png`；
   - 再次运行 `probe_online_players.lua`，期望 `phase` 恢复正常、虚弱提示可见、库存与金币未丢失。

## Gotchas

- **广告与金豆入口在编辑器内走占位通道（[ADR-0036](../../../../docs/adr/0036-platform-commerce-and-ads-not-verifiable-in-editor.md)）**：占位通道仅证明代码路径与互斥结算，绝不宣称真实支付或真实广告权益；发布构建守卫见 `lua tools/cli.lua test spec -- --filter='19%-13'`。
- **禁止直接改血量冒充战斗受击**：要证明「攻击/受击/濒死」完整链路必须经真实伤害事件或活鱼攻击，不能直接把 `Health` 设成 0 后就宣称战斗受击通过。
- **濒死/死亡退局恢复（11-25～11-27）**：若测试退局恢复，需在 `downed`/`dead` 或虚弱态下执行 `$CLI play stop` 再同槽重启试玩，核对安全落点与剩余虚弱时长未重置为 60 秒。
