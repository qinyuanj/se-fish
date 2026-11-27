# 多人规则：小队、PK 免伤与他人抢救（Multiplayer: Squad, PK & Rescue）

覆盖《钓鱼怎么这么危险啊喂！》的多人共享世界规则：最多 3 人小队（2 米内邀请、10 秒超时、离线退队、少于 2 人解散）、同队与鱼塘安全区免伤、野外钓鱼区 PK 伤害、他人抢救濒死玩家恢复 10% 血量上限，以及多人同场共享活鱼/地面物唯一副本。

本功能严格执行**双轨分离验证**：离线多连接夹具证明 A/B 级代码路径，真实双客户端进入同一房间证明 C 级真机多人体验；**缺第二真实客户端时绝不伪造 C 级通过**（[ADR-0040](../../../../docs/adr/0040-local-multiplayer-not-simulatable-in-editor.md)）。

## Sub-features

- `mp-offline-squad-rules` — 离线多连接断言：3 人上限、2 米距离校验、10 秒邀请超时、主动离队/离线退队与少于 2 人解散（条款 `9-02`、`9-06`～`9-11`、`9-19`～`9-22`）。
- `mp-offline-pk-and-safezone` — 离线多连接断言：统一伤害入口、同队免伤、Z1 鱼塘安全区全员免伤、野外非同队 PK 伤害、安全区不阻挡鱼伤玩家（条款 `9-01`、`9-12`～`9-16`）。
- `mp-offline-rescue-and-shared-world` — 离线多连接断言：他人抢救恢复 10% 上限、施救者断线中止、重连不重复结算、8～10 连接共享地面物唯一副本竞抢只结算一次（条款 `9-03`～`9-05`、`9-17`、`9-18`、`19-12`）。
- `mp-solo-backbone-sanity` — 单客户端试玩校验：真实服务端 `SharedWorldTree` / `SquadDock` 运行正常，单人运行在唯一多人骨架上（[ADR-0028](../../../../docs/adr/0028-solo-clear-on-shared-world.md)）。
- `mp-live-two-client-e2e` — **需真实第二客户端**：两人同房实测 2 米邀请与 `PartyHud` 血量显示不重叠、鱼塘免伤 vs 野外 PK、以及真实玩家 A 濒死后由玩家 B 点击 `RescueView` 气泡救起（条款 `9-23`～`9-25` 与生产开关 #10/#13）。

## How to get to it (user POV)

- **离线代码路径入口**：在仓库根运行 `busted` 规格车道与 10 连接 B 级时序探针。
- **真实双客户端入口**：两名真实玩家（客户端 A 与客户端 B）通过编辑器**「多人共建」多人试玩房间**（或真实线上/联机测试房；多人共建支持随进随出，当前同时仅允许存在一个多人试玩房间）加入同一联机房间：
  - **组队**：A 走到 B 身边 2 米内发起小队邀请 → B 在 10 秒内收到邀请提示并接受 → 双方右上角 `PartyHud` 显示队友与实时血量。
  - **安全区与 PK**：两人在 Z1 鱼塘（安全区）互相攻击不掉血；前往 Z2+ 野外钓鱼区后，非同队互相攻击正常掉血，同队互相攻击免伤；主动离队后立即恢复可互相伤害。
  - **他人抢救**：A 受致命伤害进入濒死并呼救 → B 走近 A 触发 `RescueView` 抢救气泡点击抢救 → A 解除濒死并恢复血量上限 10%。

## Driving it with tools/cli.lua & editor-cli

Preconditions:

- **轨 1（离线多连接 A/B 级）**：只需 `lua -v` 为 5.4 且 `busted` 在 PATH 上，无需编辑器。
- **轨 2（单客户端多人骨架）**：`doctor.lua` 通过且单人试玩就绪。
- **轨 3（真实双客户端联机 C 级）**：必须具备**真实第二客户端**加入同一房间，使 `probe_online_players.lua` 返回 `SUMMARY count>=2 mode=multiplayer`。

### 轨 1：运行离线多连接多人规则与 10 连接时序探针（每次改动必跑）

```bash
# 1. 小队、PK 免伤过滤、他人抢救、8 连接本地连接夹具（A/B 级黑盒规格断言）
busted tests/native/spec/server_squad_314_test.lua tests/native/spec/client_squad_314_test.lua tests/native/spec/09_pk_damage_filter_test.lua tests/native/spec/09_rescue_test.lua tests/native/spec/19_multiplayer_local_link_test.lua tests/native/spec/01_capacity_local_link_test.lua tests/native/spec/server_weapon_pk_300_test.lua

# 2. 10 条虚拟连接全生命周期 B 级时序探针（独立存档键、同队免伤、野外 PK、地面物竞抢、施救断线重连）
lua tests/probes/local_link_runtime.lua
```

期望：两条命令退出码均为 `0`，`local_link_runtime.lua` 所有 `LOCALLINK264` 检查项均为 `PASS`。将完整输出保存至 `tmp/verify-se-fish/<run-id>/mp-offline.log`。

### 轨 2：单客户端试玩中的多人骨架自检

```bash
CLI="$USERPROFILE/.eggitor/cli/editor-cli.exe"
"$CLI" exec --platform server --file D:/dev/github/se-fish/.agents/skills/verify-se-fish/scripts/probe_online_players.lua --json
"$CLI" log grep "VERIFY_PLAYERS" --play-session <session> --max-matches 50
```

期望：`runtime=true` 且单人玩家读出 `party=none`、`save=ready`，确认多人共享世界骨架（`ServerRuntime` + `SquadDock`）在单人试玩下无报错加载。

### 轨 3：真实双客户端联机验证（具备第二客户端时）

1. **人数闸门（禁止跳过）**：
   运行 `probe_online_players.lua` 并抓取 `VERIFY_PLAYERS` 日志：
   - 若 `count < 2`：立即停止轨 3，并在证据摘要中把 `mp-live-two-client-e2e`（及条款 `9-23`～`9-25`）标记为 **`blocked`**，注明「当前在线真实玩家数 = `<count>`，缺真实第二客户端（ADR-0040）」。
   - 若 `count >= 2`：记下两名玩家的 `uidA`/`nameA` 与 `uidB`/`nameB`。
2. **双端分步实测**：
   - **组队与 HUD（9-23、9-24）**：将 A、B 移动到相距 >2 米尝试邀请（期望拒绝提示），再走近至 2 米内发邀请并由 B 接受；在两端核对 `PartyHud` 头像/血量与左上角自身血量不重叠，抓屏存档；
   - **安全区与 PK（9-25）**：在 Z1 鱼塘离队互打验证免伤；移动至 Z2+ PK 区验证非同队掉血、同队免伤，并核对玩家能分辨安全区与 PK 区边界；
   - **他人抢救**：A 濒死后由 B 靠近点击 `RescueView` 气泡，核对 A 解除濒死并恢复 10% 血量上限；
   - **定向路由观测**：可用 `"$CLI" exec --platform client --player <uidA|nameA> "..."` 分别在双端读取 UI 状态（如实记录 `--player` 路由是否按预期送达对应客户端）。
3. **归档**：双端截图与日志落盘 `tmp/verify-se-fish/<run-id>/`；正式 C 级条款写入 `docs/acceptance/evidence/<session>/session.md` 并跑 `lua tools/cli.lua acceptance --infer`。

## Gotchas

- **绝不用 NPC 或离线单测冒充真实多人通过（ADR-0040）**：`World:CreateUnit` 生成的 `EggyUnit` 不进 `Players:GetPlayers()`，没有真实 `UserId` 与独立网络通道；轨 1 通过只证明「代码路径」，轨 3 缺失第二客户端时必须报 `blocked`。
- **`EggyEditorAPI.lua` 与 `editor-cli` 均无模拟多人入口**：已对仓库 [EggyEditorAPI.lua](../../../../EggyEditorAPI.lua)（`EditorAPI.run_game()` / `StateSyncEditorApi.run_game()` 均无参）、在线编辑器 `1.0.38` 实时编辑态 API（`Editor.RunGame` / `RunService`）及 `editor-cli 0.20.17` 全量命令（含 `--include-internal`）复核，均无「添加虚拟玩家 / 设置本地多开人数」接口。不要猜测或尝试 `--players 2` / `--bots` 等不存在的选项；若 `doctor.lua` 提示 `editor-cli` 或编辑器大版本升级，先查 `play start --help` 与 `api search-editor` 复核后再决定是否更新 ADR-0040。
- **`exec --player` / `input --player` 实测未钉死**：ADR-0040 已标明「真实多人房内 `play input --player` / `exec --player` 的路由行为尚未在钉子版本实测」。首次在真双客户端房间使用时，必须先用 `exec --platform client --player <uidB> "print('PING_B')"` 实测确认路由精准命中 B 而非 A，并把结果回写本节。
- **`RemoteEvent.New` 多人收发属生产开关 #13**：迟加入、重连与 `PlayerRemoving` 清理的真实联机结论记在 [production-switches.md](../../../../docs/acceptance/production-switches.md)，单人试玩通过不得将其标为已结项。
