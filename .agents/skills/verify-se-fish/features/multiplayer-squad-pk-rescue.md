# 多人规则：小队、PK 免伤与他人抢救（Multiplayer: Squad, PK & Rescue）

覆盖《钓鱼怎么这么危险啊喂！》的多人共享世界规则：最多 3 人小队（2 米内邀请、10 秒超时、离线退队、少于 2 人解散）、同队与鱼塘安全区免伤、野外钓鱼区 PK 伤害、他人抢救濒死玩家恢复 10% 血量上限，以及多人同场共享活鱼/地面物唯一副本。

本功能按 [ADR-0044](../../../../docs/adr/0044-editor-local-multiplayer-and-ai-playtest.md) 执行**四层分离验证**，各层证明口径不混用：

| 层 | 入口 | 证明什么 | 证据级别 |
|---|---|---|---|
| L1 离线多连接夹具 | `busted` 规格车道 + `tests/probes/local_link_runtime.lua` | 8～10 连接的规则代码路径 | A / B |
| L2 单窗调试插件 AI | 单客户端试玩中 **调试插件 → AI → 添加AI / 切换AI** | 快速排障：交互入口、站位、角色切换 | 不记 C 级（语义待钉死） |
| L3 本地多人测试多窗口 | 编辑器 UI **测试 → 测试页签 → 本地多人测试 → 开始** | 多端 HUD、2 米邀请、安全区与 PK 边界、他人抢救、双端 `RemoteEvent` 收发 | C（`9-23`～`9-25` 主路径） |
| L4 共建多人测试 / 真机 | 编辑器 **共建多人测试**、真实线上房、多账号多设备 | 真实多账号、跨设备网络、8 人以上真实容量 | 发布前签署（生产开关 #7、#10） |

## Sub-features

- `mp-offline-squad-rules` — L1 离线多连接断言：3 人上限、2 米距离校验、10 秒邀请超时、主动离队/离线退队与少于 2 人解散（条款 `9-02`、`9-06`～`9-11`、`9-19`～`9-22`）。
- `mp-offline-pk-and-safezone` — L1 离线多连接断言：统一伤害入口、同队免伤、Z1 鱼塘安全区全员免伤、野外非同队 PK 伤害、安全区不阻挡鱼伤玩家（条款 `9-01`、`9-12`～`9-16`）。
- `mp-offline-rescue-and-shared-world` — L1 离线多连接断言：他人抢救恢复 10% 上限、施救者断线中止、重连不重复结算、8～10 连接共享地面物唯一副本竞抢只结算一次（条款 `9-03`～`9-05`、`9-17`、`9-18`、`19-12`）。
- `mp-solo-backbone-sanity` — 单客户端试玩校验：真实服务端 `SharedWorldTree` / `SquadDock` 运行正常，单人运行在唯一多人骨架上（[ADR-0028](../../../../docs/adr/0028-solo-clear-on-shared-world.md)）。
- `mp-debug-ai-triage` — L2 单窗调试插件 AI：添加 AI 角色后检查邀请入口、抢救气泡等交互是否出现，切换 AI 后检查操控与界面是否跟随；只做排障。
- `mp-local-multiwindow-e2e` — L3 本地多人测试（2～3 个客户端窗口）：2 米邀请与 `PartyHud` 血量显示不重叠、鱼塘免伤 vs 野外 PK 边界、玩家 A 濒死后由玩家 B 点击 `RescueView` 气泡救起、双端 `RemoteEvent` 收发与关窗离场清理（条款 `9-23`～`9-25` 与生产开关 #13）。
- `mp-live-platform-signoff` — L4 共建/真机复验：真实多账号存档、跨设备网络重连与 8 人以上真实容量（生产开关 #7、#10）。

## How to get to it (user POV)

- **L1 离线代码路径**：在仓库根运行 `busted` 规格车道与 10 连接 B 级时序探针。
- **L2 调试插件 AI**：单人试玩进入后，点编辑器顶部 **调试插件** 下拉 → **AI** → **添加AI** 生成 AI 角色，**切换AI** 切到该角色操控。
- **L3 本地多人测试**：编辑态下点顶部 **测试** 下拉 → **测试** 页签 → **本地多人测试**，设客户端数量（双端 `2`，满编小队 `3`）→ **开始**，每个客户端一个独立窗口（下称窗口 A / 窗口 B）进入同一会话：
  - **组队**：A 走到 B 身边 2 米内发起小队邀请 → B 在 10 秒内收到邀请提示并接受 → 双方右上角 `PartyHud` 显示队友与实时血量。
  - **安全区与 PK**：两人在 Z1 鱼塘（安全区）互相攻击不掉血；前往 Z2+ 野外钓鱼区后，非同队互相攻击正常掉血，同队互相攻击免伤；主动离队后立即恢复可互相伤害。
  - **他人抢救**：A 受致命伤害进入濒死并呼救 → B 走近 A 触发 `RescueView` 抢救气泡点击抢救 → A 解除濒死并恢复血量上限 10%。
- **L4 共建/真机**：编辑器 **共建多人测试**（同时仅允许一个多人试玩房间，随进随出）或真实线上房，由不同真实账号/设备加入。

## Driving it with tools/cli.lua & editor-cli

Preconditions:

- **L1**：只需 `lua -v` 为 5.4 且 `busted` 在 PATH 上，无需编辑器。
- **L2**：`doctor.lua` 通过且单人试玩就绪（`play start --wait-ready`）。
- **L3**：隔离 QA 槽 + `lua tools/cli.lua deploy` 完成，编辑态 `edit_ready`；**多窗口只能由编辑器 UI 启动**（`editor-cli 0.20.20` 的 `play start` 只起单客户端），agent 无法点击时请用户代点 **本地多人测试 → 开始**。
- **L4**：具备共建房间或真实线上房与第二真实账号/设备。

```bash
CLI="$USERPROFILE/.eggitor/cli/editor-cli.exe"
```

### L1：离线多连接多人规则与 10 连接时序探针（每次改动必跑）

```bash
# 1. 小队、PK 免伤过滤、他人抢救、8 连接本地连接夹具（A/B 级黑盒规格断言）
busted tests/native/spec/server_squad_314_test.lua tests/native/spec/client_squad_314_test.lua tests/native/spec/09_pk_damage_filter_test.lua tests/native/spec/09_rescue_test.lua tests/native/spec/19_multiplayer_local_link_test.lua tests/native/spec/01_capacity_local_link_test.lua tests/native/spec/server_weapon_pk_300_test.lua

# 2. 10 条虚拟连接全生命周期 B 级时序探针（独立存档键、同队免伤、野外 PK、地面物竞抢、施救断线重连）
lua tests/probes/local_link_runtime.lua
```

期望：两条命令退出码均为 `0`，`local_link_runtime.lua` 所有 `LOCALLINK264` 检查项均为 `PASS`。将完整输出保存至 `tmp/verify-se-fish/<run-id>/mp-offline.log`。

### 单客户端多人骨架自检（L2 / L3 前置）

```bash
"$CLI" exec --platform server --file D:/dev/github/se-fish/.agents/skills/verify-se-fish/scripts/probe_online_players.lua --json
"$CLI" log grep "VERIFY_PLAYERS" --play-session <session> --max-matches 50
```

期望：`runtime=true` 且单人玩家读出 `party=none`、`save=ready`，确认多人共享世界骨架（`ServerRuntime` + `SquadDock`）在单人试玩下无报错加载。

### L2：单窗调试插件 AI 快速排障

1. 单人试玩中点 **调试插件 → AI → 添加AI**，再点 **切换AI** 切换操控角色。
2. 跑语义核查并留档：
   ```bash
   lua .agents/skills/verify-se-fish/scripts/probe_local_mp_run.lua --mode debug-ai --instance <id> --out tmp/verify-se-fish/<run-id>/adr0044-debug-ai.md
   ```
   报告中「AI 是否进入 `Players:GetPlayers()` / 触发 `PlayerAdded`」与「切换后 `LocalPlayer`、`ClientStore`、服务端 `RemoteEvent` 发送者是否跟随」各项为 `CONFIRMED` / `MISMATCH` / `UNOBSERVED`。
3. 用途限于看交互入口（邀请提示、`RescueView` 气泡）是否出现、站位与切换是否顺手；**结论只写进排障记录，不写进 C 级 `session.md`**，直到 ADR-0044 回写 AI 语义可用于取证。

### L3：本地多人测试多窗口（C 级主验收）

1. **启动**：编辑器 UI **测试 → 测试页签 → 本地多人测试**，客户端数量 `2`（验 3 人上限时设 `3`）→ **开始**；`"$CLI" status --json` 到 `in_game_runtime=true`、`editor_state="playing"`。
2. **人数闸门（禁止跳过）**：运行 `probe_online_players.lua` 并抓取 `VERIFY_PLAYERS` 日志：
   - 若 `count < 2`：多窗口未成功进入同一会话，停止 L3，把 `mp-local-multiwindow-e2e`（及条款 `9-23`～`9-25`）标记为 **`blocked`**，注明「当前在线玩家数 = `<count>`，本地多人测试未就绪」。
   - 若 `count >= 2`：记下各玩家的 `uidA`/`nameA`、`uidB`/`nameB`。
3. **首轮语义探针（每个编辑器/CLI 版本至少一次）**：
   ```bash
   lua .agents/skills/verify-se-fish/scripts/probe_local_mp_run.lua --mode local-mp --instance <id> --out tmp/verify-se-fish/<run-id>/adr0044-local-mp.md
   ```
   核对唯一 `UserId`、独立 `LocalPlayer` 与存档键、`Players` 与 `ServerRuntime` 计数一致、`--player` 路由命中率。任一项 `MISMATCH` 时如实记录并按 Gotchas 降级驱动方式。
4. **窗口对号**：
   ```bash
   lua tools/cli.lua screenshot --list
   ```
   记下每个窗口的 `hwnd` / `pid`，结合画面（头顶名字）或客户端探针输出，在 `summary.md` 写明 `hwnd` → `uid` / `name` 对应表。
5. **分步实测**（在对应窗口内操作；`--player` 路由确认命中后才可用 `input --player` / `exec --platform client --player` 代替手动操作）：
   - **组队与 HUD（9-23、9-24）**：A、B 相距 >2 米尝试邀请（期望拒绝提示），再走近至 2 米内发邀请并由 B 接受；两端核对 `PartyHud` 头像/血量与左上角自身血量不重叠；
   - **安全区与 PK（9-25）**：在 Z1 鱼塘离队互打验证免伤；移动至 Z2+ PK 区验证非同队掉血、同队免伤，并核对玩家能分辨安全区与 PK 区边界；
   - **他人抢救**：A 濒死后由 B 靠近点击 `RescueView` 气泡，核对 A 解除濒死并恢复 10% 血量上限；
   - **`RemoteEvent` 收发与离场（生产开关 #13）**：两端各自触发一次需服务端回包的操作，核对对端可见变化；关闭窗口 B 后用 `probe_online_players.lua` 核对 `count` 回落且 B 的小队关系按规则清理。
6. **取证**：关键步骤一次抓全部窗口并连拍比哈希：
   ```bash
   lua tools/cli.lua screenshot --all --out tmp/verify-se-fish/<run-id>/9-23-a.png   # 落盘 9-23-a-1.png、9-23-a-2.png …
   lua tools/cli.lua screenshot --hwnd <hwndB> --out tmp/verify-se-fish/<run-id>/rescue-B.png
   ```
7. **归档**：截图与日志落盘 `tmp/verify-se-fish/<run-id>/`；正式 C 级条款写入 `docs/acceptance/evidence/<session>/session.md`（注明「L3 本地多人测试，客户端数 N」）并跑 `lua tools/cli.lua acceptance --infer`。

### L4：共建多人测试 / 真机复验（发布前）

- 用编辑器 **共建多人测试** 或真实线上房，由不同真实账号/设备加入，复验 L3 场景在真实网络下的表现，并补真实多账号存档、跨设备重连与 8 人以上真实容量。
- 结论记入 [production-switches.md](../../../../docs/acceptance/production-switches.md) 第 7、10 项（#13 中真实网络重连部分一并补记），不回填为 L3 条款证据。

## Gotchas

- **绝不用 NPC 或离线单测冒充真实多人通过**：业务脚本 `World:CreateUnit` 生成的 `EggyUnit` 不进 `Players:GetPlayers()`，没有真实 `UserId` 与独立网络通道，任何一层都不得用它充当第二玩家；L1 通过只证明「代码路径」，不冒充 C 级。
- **CLI 只起单客户端（ADR-0044）**：`editor-cli 0.20.20` 的 `play start`、`--help --include-internal` 与 `Editor.RunGame` 都没有人数 / AI 参数，不要猜测 `--players 2` / `--bots` 等不存在的选项。多窗口只能从编辑器 UI **本地多人测试 → 开始** 启动；`doctor.lua` 提示 `editor-cli` 版本变化时，先查 `play start --help` 是否开放了自动化参数，再决定是否更新 ADR-0044 与本配方。
- **`--player` 路由待首轮探针钉死**：ADR-0044 尚未确认多窗口下 `exec --platform client --player`、`play input --player` 是否精准命中目标窗口。`probe_local_mp_run.lua --mode local-mp` 确认命中前，一律在对应窗口手动操作，并用 `screenshot --hwnd` 按窗口取证；若报告显示请求全部落到同一窗口，如实记录 `MISMATCH`，不得把单窗口观察当成双端证据。结果出来后回写 ADR-0044 与本节。
- **AI 的 `Players` 语义待钉死**：**添加AI** 生成的角色是否进 `Players:GetPlayers()`、触发 `PlayerAdded`，**切换AI** 是否同步切换 `LocalPlayer`、`ClientStore` 与服务端 `RemoteEvent` 发送者，均未确认；钉死前 L2 只做排障，不写 C 级证据。若探针显示 AI 只是场景里的非 `Player` 单位，L2 永久只做排障。
- **本地多窗口不等于真实容量 / 真实网络**：2～3 个本地窗口只证明多端交互；8 人以上真实容量、真实多账号存档限流与跨设备网络仍归 [production-switches.md](../../../../docs/acceptance/production-switches.md) 第 7、10 项（[证据分级](../../../../docs/acceptance/evidence-levels.md)「什么不算取证」）。
- **多窗口存档键要独立**：若首轮探针报存档键冲突（各窗口共用同一存档键），说明本地多窗口共享账号身份，此时涉及存档的多人结论（如离线退队后重进）不可信，只记录交互观察，持久化相关条目留给 L4。
- **`RemoteEvent.New` 多人收发属生产开关 #13**：L3 实测的多客户端收发、迟加入与关窗离场清理结论记入 [production-switches.md](../../../../docs/acceptance/production-switches.md) 第 13 项；真实网络重连归第 10 项，单人试玩通过不得将其标为已结项。
