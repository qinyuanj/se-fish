# QA 存档槽、退出重进与恢复（Save & Rejoin）

玩家在隔离的 QA 存档槽中产生个人持久状态变更（金币、库存、装备、成长），停止试玩并同槽重进后，个人持久状态完整恢复；而共享世界对象（活鱼、地面物品）与个人会话态（抛竿/收线/烧烤占用）严格遵守状态边界，不复制、不丢失、不串档。

## Sub-features

- `save-qa-slot-isolation` — `lua tools/cli.lua qa-slot new` 隔离出全新档，与正式档及其他验收槽互不污染。
- `save-rejoin-persistence` — 停试玩后同槽重进，个人金币、库存、装备与已解锁区域保持连续。
- `save-world-state-boundary` — 共享世界的活鱼与地面掉落物不写入个人存档，重进时不复制成第二份。
- `save-session-fencing` — 存档未就绪前拒绝可变操作；离线/重连时旧会话异步回调不覆盖新会话存档，退出时烧烤/抽奖等会话有确定结算。

## How to get to it (user POV)

- 玩家在单局试玩中完成一笔可观察的持久变更（例如在 Z1 买一根新手鱼竿、出售鱼获使金币变化）。
- 退出当前对局（试玩停止），随后以同一账号重新进入地图。
- 核对画面与背包：金币、鱼竿与物品格位仍在，且角色落在合法安全落点。

## Driving it with tools/cli.lua & editor-cli

Preconditions:

- 已记录开跑前的 `QaSlot`（`lua tools/cli.lua qa-slot status`），以便 Cleanup 原样恢复。
- 当前未在试玩中（若已在试玩中，先 `$CLI play stop` 回到空闲编辑态再改槽与部署）。

1. **离线 B 级会话与存档契约校验**：
   ```bash
   busted tests/native/spec/18_session_settlement_contract_test.lua tests/native/spec/player_tree_state_sync_test.lua
   ```
   期望退出码 `0`。

2. **创建新验收槽并部署（第一局）**：
   ```bash
   CLI="$USERPROFILE/.eggitor/cli/editor-cli.exe"
   lua tools/cli.lua qa-slot new
   # 记下新生成的槽名 <slot-id>
   lua tools/cli.lua deploy
   "$CLI" play start --wait-ready --wait-timeout 60 --json
   ```
   执行 `probe_online_players.lua` 记下初始 `coins` 与 `save=ready`（记为 `session-1`）。

3. **产生可观察持久变更并确认落盘**：
   - 通过真实玩家操作（如购买新手鱼竿或卖鱼）使金币/库存发生变化；
   - 再次执行 `probe_online_players.lua` 记录变更后的 `coins`，并截屏保存 `tmp/verify-se-fish/<run-id>/rejoin-before.png`。

4. **停止试玩 → 同槽重进（切勿再次执行 `qa-slot new`）**：
   ```bash
   "$CLI" play stop --json
   # 轮询 "$CLI" status --json 直到 edit_mode=true, in_game_runtime=false, editor_state="idle"
   "$CLI" play start --wait-ready --wait-timeout 60 --json
   ```
   记下新会话 `session-2`，等待 `save=ready` 后执行 `probe_online_players.lua` 并截屏 `tmp/verify-se-fish/<run-id>/rejoin-after.png`。

5. **核对前后状态**：
   - 期望 `session-2` 的 `coins`、库存与 `session-1` 退出前一致；
   - 若 `session-1` 退出前场上有未拾取的地面鱼获或活鱼，核对重进后未在个人背包中凭空复制（条款 `18-27`）。

## Gotchas

- **试玩中禁止改槽或部署**：`tools/qa_slot.lua` 明确要求先停止试玩，再修改 `qa-slot` 与 `deploy`，否则运行中内存配置与磁盘不一致。
- **同槽重进不要再跑 `qa-slot new`**：`qa-slot new` 会生成全新槽名导致看到空档；复进同一槽只需直接 `play stop` → `play start`（或 `qa-slot set <slot-id>` 后 `deploy`）。
- **`play stop` 会让 `map dirty` 变 true**：这是编辑器正常行为，不要因此直接丢弃用户未保存的场景编辑；重开地图前先查 `map dirty --json`。
- **Cleanup 必须恢复原 `QaSlot`**：本功能会改动 `common/game_cfg.lua` 的 `QaSlot` 行，验证结束务必恢复至开跑前的值（绝不直接 `git checkout` 冲掉同一文件的其他未提交修改）。
