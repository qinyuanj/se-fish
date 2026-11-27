# 单人钓鱼主循环（Solo Fishing Loop）

玩家在钓鱼区岸边面向水面抛竿，消耗鱼饵并等待上钩提示，点击收线按钮把进度从 50% 推到 100% 让鱼上岸顶在头上（举鱼），随后放下让普通/极品鱼逃跑或让精英/首领进入战斗。

## Sub-features

- `fishing-invalid-cast` — 落点不在可钓水域时服务端拒绝抛竿、不扣鱼饵并立即回到可抛竿状态。
- `fishing-cast-and-bite` — 有效落水扣一次鱼饵，约 3 秒后服务端抽鱼，上钩时同时触发文字提示、收线按钮呼吸高亮与提示音。
- `fishing-reel-success` — 收线从 50% 起步（每秒降 5%、每次点收线按钮升 5%），到 100% 播放上岸动作并进入举鱼，操作按钮切换为「放下」。
- `fishing-reel-unhook` — 收线进度降到 0% 即脱钩，需再次操作收竿才能回到可抛竿状态。
- `fishing-drop-dispatch` — 放下后普通与极品鱼朝最近水域逃脱，精英与首领进入战斗并显示逃跑条。

## How to get to it (user POV)

- 角色在 Z1 鱼塘出生点走向岸边并面向水面。
- 若背包无鱼竿，先到 Z1 钓场商店买新手鱼竿（5 金币），再到本区固定鱼饵刷新点拾取普通鱼饵（拾取后 15 秒刷新）。
- 在道具栏选中鱼竿与鱼饵，点击主 HUD 动作按钮 `BtnItemActionLabel`（「抛竿」）。
- 上钩后点击收线覆盖层（`ReelOverlayView`）的收线按钮；上岸举鱼后再次点击动作按钮「放下」。

## Driving it with tools/cli.lua & editor-cli

Preconditions:

- `lua .agents/skills/verify-se-fish/scripts/doctor.lua` 退出码为 `0`，`QaSlot` 为非空验收槽，且已完成 `lua tools/cli.lua deploy`。
- 试玩已启动（`$CLI play start --wait-ready --wait-timeout 60 --json`）并记下 `<session>`。
- 角色处于 Z1 鱼塘且持有可用鱼竿与普通鱼饵（测普通抽取时背包不含首领饵）。

1. **离线 A 级前置基线（确认收线与上岸规则全绿）**：
   ```bash
   busted tests/native/spec/04_fishing_reel_rules_test.lua tests/native/spec/server_cast_reel_302_test.lua tests/native/spec/client_reel_overlay_302_test.lua tests/native/spec/client_cast_source_302_test.lua
   ```
   期望退出码 `0`，所有收线起止/衰减/增益/脱钩/上岸分流断言通过。

2. **核验试玩在线玩家与存档就绪**：
   ```bash
   CLI="$USERPROFILE/.eggitor/cli/editor-cli.exe"
   "$CLI" exec --platform server --file D:/dev/github/se-fish/.agents/skills/verify-se-fish/scripts/probe_online_players.lua --json
   "$CLI" log grep "VERIFY_PLAYERS" --play-session <session> --max-matches 50
   ```
   期望输出 `SUMMARY count=1 mode=solo runtime=true` 且玩家 `save=ready`。

3. **走位到 Z1 水边并采集操作前状态与截图**：
   ```bash
   "$CLI" input state --json
   "$CLI" input move-to <岸边x> <岸边y> <岸边z> --joystick --json
   "$CLI" input stop --json
   lua tools/cli.lua screenshot --info
   lua tools/cli.lua screenshot --out tmp/verify-se-fish/<run-id>/fishing-before.png
   ```

4. **执行抛竿 → 上钩 → 收线 → 举鱼 → 放下**：
   - 使用 `"$CLI" input touch <x_画面> <y_画面> --json` 点击主 HUD 抛竿按钮，等待约 3 秒观察上钩文字、收线按钮高亮与提示音；
   - 连续点击收线按钮（而非进度条）直到 100% 上岸举鱼，抓拍 `fishing-lifted.png` 并用 `read_image` 确认鱼位于头顶且不穿模、不挡血条与按钮（对照条款 `4-30`）；
   - 点击「放下」，抓拍 `fishing-dropped.png` 并通过日志确认普通/极品鱼向水域逃脱或精英/首领进入战斗并显示逃跑条（对照条款 `4-31`）。
   - 如需自动化连续走完 Z1 鱼塘正常闭环（仅走合法业务意图、不改 RNG/库存/金币），可执行真机探针：
     ```bash
     "$CLI" exec --platform server --file D:/dev/github/se-fish/tests/probes/pond_loop_runtime.lua --json
     "$CLI" log grep "PONDLOOP" --play-session <session> --max-matches 200
     ```

5. **证据检查与归档**：
   将命令、日志节选与双帧截图保存到 `tmp/verify-se-fish/<run-id>/`；若用于正式 C 级条款取证（`4-29`～`4-31`），写入 `docs/acceptance/evidence/<session>/session.md` 并跑 `lua tools/cli.lua acceptance --infer`。

## Gotchas

- **进度条不可点击（4-09）**：自动化 `input touch` 必须落在收线按钮区域，点进度条不会增加进度且 `input touch` 仍返回 `success: true`。
- **开面板不暂停收线（4-10）**：收线时打开商店/背包/图鉴进度照常下降，关闭面板不触发脱钩。
- **脱钩需手动收竿（4-11）**：进度归零不会自动恢复可抛竿状态，必须再操作一次收竿。
- **首领饵优先级最高（4-17、4-18）**：测普通鱼池前先移出首领饵，否则在任意钓鱼区都会优先走首领判定且脱钩/逃跑不退饵。
- **窗口最小化无法抓屏**：若 `lua tools/cli.lua screenshot --info` 报找不到窗口，先确认编辑器进程窗口不是 `Iconic=True`，还原后再抓。
- **C 级不可由 A 级替代**：`4-29`（提示音/高亮可辨）、`4-30`（举鱼贴合无遮挡）、`4-31`（逃跑条可读）必须有真实试玩画面与人工/读图判定，单测全绿时反推仍保持 `blocked`。
