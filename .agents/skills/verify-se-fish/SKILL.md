---
name: verify-se-fish
description: |
  驱动《钓鱼怎么这么危险啊喂！》（se-fish，蛋仔派对 SE 地图）完成可复现的单人试玩与多人规则验证。
  当需要启动/检查试玩、按玩家路径操作钓鱼/战斗/商店/烧烤/存档重进、运行多人离线多连接代码路径或真实双客户端联机实测、以及留存可追溯取证产物（日志+截图）时启用。
---

# verify-se-fish — 单人试玩与多人验证指南

本技能面向冷启动接手验证任务的 agent，提供驱动《钓鱼怎么这么危险啊喂！》（SE 状态同步地图）真实运行时与离线验收车道的标准流程。所有命令均来自本仓库实测（基于 Lua 5.4、`tools/cli.lua`、编辑器 `1.0.37` 与 `editor-cli 0.20.17`）。

## Surface & Isolation（交互面与隔离边界）

| 层次 | 交互面 | 适用范围 | 证据级别（见 [evidence-levels.md](../../../docs/acceptance/evidence-levels.md)） |
|---|---|---|---|
| **主交互面（单人真实试玩）** | 蛋仔派对世界版（SE）PC 编辑器试玩运行时（真实 EUI + 3D 场景 + 服务端权威 Lua） | Solo clear 玩法闭环、手感、UI 可读性、贴地/净空、退局重进恢复 | C 级（试玩观察）与真机探针 |
| **次交互面（离线验收车道）** | 仓库根 `lua tools/cli.lua test spec` 与 `tests/probes/local_link_runtime.lua` | 数值、路由、原子结算、8～10 条虚拟连接的小队/PK/抢救/共享世界代码路径 | A 级（黑盒断言）与 B 级（时序探针） |
| **真双端联机面（多人实测）** | 真实双客户端进入同一房间，分别通过 `--player` 路由或真机操作 | 真实 `PlayerAdded`/`PlayerRemoving`、2 米组队邀请、同队免伤、野外 PK、他人抢救、双端 HUD | C 级（真实多人取证） |

### 强制隔离与边界约定

1. **单实例互斥**：同地图同时只允许一个 agent 驱动同一个编辑器试玩实例。检测到多实例时（`editor-cli editor-instances list --json`），所有 CLI 命令必须显式带 `--editor-instance <pid|port|地图名>`，绝不盲目覆盖他人的试玩会话。
2. **存档槽隔离**：试玩前必须使用独立 QA 存档槽（`lua tools/cli.lua qa-slot new` 或指定既有验收槽）再执行 `lua tools/cli.lua deploy`，禁止在 `QaSlot == ''` 的正式存档上做破坏性试玩。
3. **本地无法模拟多人（[ADR-0040](../../../docs/adr/0040-local-multiplayer-not-simulatable-in-editor.md)）**：截至编辑器 `1.0.37` / `editor-cli 0.20.17`，`play start` 无人数/机器人参数，`Player` 不可自行创建，`EggyUnit` NPC 不能替代真实玩家。
   - 本地可验证的多人部分必须走**离线多连接夹具**（`tests/native/spec/19_multiplayer_local_link_test.lua`、`09_pk_damage_filter_test.lua`、`09_rescue_test.lua`、`server_squad_314_test.lua`、`client_squad_314_test.lua` 及 `tests/probes/local_link_runtime.lua`），且只宣称**代码路径已验证**；
   - 真实多人 C 级条款（如 [09-multiplayer-rules.md](../../../docs/acceptance/09-multiplayer-rules.md) 的 `9-23`～`9-25`）必须有**真实第二客户端**入房；缺第二客户端时如实报告 `blocked`，禁止用单客户端或 NPC 充数。
4. **与 `eggy-se-qa` 的协作边界**：
   - **复用**：`eggy-se-qa` 的「单测 / 运行时集成 / 视觉截图 / GM 辅助」分层、唯一日志标记 + `log grep --play-session` 断言模式、以及 `exec --platform client` 零侵入动态注入（不改 `client/main.lua`、单引号约束）。
   - **按本仓实测覆写**：
     - 截图**一律用 `lua tools/cli.lua screenshot`**，不用 `editor-cli screenshot`（虚拟屏下会产出黑帧或旧帧，见 [editor-cli.md](../../../docs/agents/editor-cli.md)）；
     - `editor-cli code diff` 必须显式传 `--workspace <宿主目录>`（在仓库根直接跑会报 `CODE_BINDING_INVALID`，切 `cwd` 到含中文宿主目录在 Windows `cmd.exe` 下会路径报错），日常直接用 `lua tools/cli.lua deploy`；
     - 证明玩家行为优先走真实玩家输入路径（`input`、EUI 按钮、真实移动与交互），**禁止**调用内部 setter 或通过 `GameCfg.Debug` / GM 跳过步骤却宣称玩家路径通过。

---

## Launch（启动与就绪判据）

先设定 CLI 变量（Git Bash 示例）：

```bash
CLI="$USERPROFILE/.eggitor/cli/editor-cli.exe"
```

### 路径 A：单人真实试玩启动（从干净验收槽到可用态）

```bash
# 1. 记录当前存档槽，便于 Cleanup 时原样恢复
lua tools/cli.lua qa-slot status

# 2. 创建隔离验收槽（复测同槽重进时改用 qa-slot set <槽名>）
lua tools/cli.lua qa-slot new

# 3. 镜像三端源码到宿主目录并推送至编辑器（含 validate -> code push -> code diff）
lua tools/cli.lua deploy

# 4. 确保编辑器已打开本图（若已在试玩态请直接看 Doctor）
lua tools/cli.lua editor open

# 5. 启动试玩并等待真正就绪（必须带 --wait-ready）
"$CLI" play start --wait-ready --wait-timeout 60 --json
```

**就绪判据（Ready ≠ 进程活着）**：
- `play start --wait-ready --json` 返回成功（SE 校验探针 `ready_probe=player_state_rpc+se_loading_complete_log`），记下输出的 `play_session`。
- 切勿等待 `status.ready == true`——在试玩中 `status.ready` 永远为 `false`（它代表「编辑态可编辑」）。
- 试玩就绪的真实判据是：**`status.in_game_runtime == true` 且 `status.editor_state == "playing"`**，且 `"$CLI" input state --json` 返回 `success: true` 与合法 `position`，且服务端只读探针 [probe_online_players.lua](scripts/probe_online_players.lua) 返回 `runtime=true` 与 `save=ready`（注：`editor-cli 0.20.17` 的 `status.available_runtimes` 在试玩中仍可能只列 `["editor"]`，若 `exec --platform server` 偶发 `game VM not running` 多为重启间隙，确认没有其他会话在驱动后稍候重试或重新 `play start --wait-ready`）。

### 路径 B：离线单人/多人代码路径启动

无需编辑器即可运行（要求 `lua -v` 为 `Lua 5.4`，且 `busted` 在 PATH 上）：

```bash
lua -v
lua tools/cli.lua test spec
lua tests/probes/local_link_runtime.lua
```

### Teardown（停止试玩，返回编辑态）

```bash
"$CLI" input stop --json || true
"$CLI" play stop --json
# 轮询确认已回到空闲编辑态（edit_mode=true, in_game_runtime=false, editor_state="idle"）
"$CLI" status --json
```

---

## Doctor（一键只读体检）

在开始驱动或发现任何异常时，**先运行只读体检脚本**：

```bash
lua .agents/skills/verify-se-fish/scripts/doctor.lua
# 需要机器可读 JSON 或指定多实例时：
lua .agents/skills/verify-se-fish/scripts/doctor.lua --instance 31028 --json
```

该脚本严格只读，不修改地图、存档或游戏状态，一次性核对：
1. `Lua 5.4` 与 `busted` 可用性（离线验收车道）；
2. `editor-cli.exe` 路径与版本（对比 ADR-0040 钉子版本 `0.20.17`）；
3. `GameCfg.Save.QaSlot` 当前槽名（若为空则告警正使用正式存档）；
4. `editor-cli status --json`（正确区分 `edit_ready` / `playing` / `transitioning` / `not_running`，弥补 `tools/cli.lua editor status` 在试玩态误报「未进图」的盲区）；
5. 试玩态下的 `input state --json` 玩家坐标与状态；
6. 在**宿主目录**执行 `editor-cli --json code diff`（豁免 `unit_scripts/` 与 `.agents/`）；
7. `lua tools/cli.lua screenshot --info` 窗口可见性与显示路径（虚拟屏/非虚拟屏）。

**退出码**：`0` 表示当前实例可驱动；`1` 表示存在 `[BLOCKER]`，须先按提示处理后再驱动。

---

## Drive（驱动配方：单人 + 多人）

### 1. 玩家输入驱动（真实用户操作）

```bash
# 读取玩家当前坐标与运动状态
"$CLI" input state --json

# 直线/摇杆走到世界坐标（走完或异常后务必 input stop）
"$CLI" input move-to <x> <y> <z> --joystick --json
"$CLI" input joystick <dx> <dy> --json
"$CLI" input stop --json

# 按键与触屏点击（注意：touch 吃游戏画面像素坐标，非窗口坐标、非 EUI 设计坐标）
"$CLI" input key <key> --json
"$CLI" input touch <x_画面> <y_画面> --json
```

- **`input touch` 坐标换算实测**（1280×760 窗口、EUI 画布 2280×1080、画面 1214×532，见 [editor-cli.md](../../../docs/agents/editor-cli.md)）：
  `x_画面 = 0.5 * x_设计 + 31.5`，`y_画面 = -0.5 * y_设计 + 556`。窗口尺寸变动时须重新测量。`input touch` 点空也会返回 `success: true`，**只能通过点击后的状态变化与截图反证点中**。

### 2. 运行时只读观测与定向驱动（`exec` + `log grep`）

- 服务端/客户端 `exec` 为异步提交；编辑器 `exec` 同步返回约 5KB 静默截断且有 5 秒硬预算。
- **一律打印唯一标记再用 `log grep` 取回完整结果**（`--max-matches` 传大值防止只留最旧 50 条）：

```bash
# 枚举当前在线真实 Player（单人起手核对 & 双端多人取 --player 参数）
"$CLI" exec --platform server --file D:/dev/github/se-fish/.agents/skills/verify-se-fish/scripts/probe_online_players.lua --json
"$CLI" log grep "VERIFY_PLAYERS" --play-session <play_session> --max-matches 100

# 客户端定向注入（单引号包内部字符串；绝不修改 client/main.lua）
"$CLI" exec --platform client --player <UserId|Name> "print('VERIFY_CLI_OK')" --json
```

### 3. 多人双轨驱动入口

1. **离线多连接代码路径（随时可跑，无编辑器要求）**：
   ```bash
   # 小队、PK 免伤、他人抢救、8～10 连接共享世界（注意 busted --filter 使用 Lua pattern，不支持 | 分支，按文件直跑最稳）
   busted tests/native/spec/server_squad_314_test.lua tests/native/spec/client_squad_314_test.lua tests/native/spec/09_pk_damage_filter_test.lua tests/native/spec/09_rescue_test.lua tests/native/spec/19_multiplayer_local_link_test.lua tests/native/spec/01_capacity_local_link_test.lua tests/native/spec/server_weapon_pk_300_test.lua
   # B 级 10 连接全生命周期时序探针
   lua tests/probes/local_link_runtime.lua
   ```
2. **真实双客户端联机驱动（需第二真实账号入房）**：
   - 先执行 `probe_online_players.lua`，要求日志出现 `SUMMARY count>=2 mode=multiplayer`，并记录两个真实玩家的 `uid` / `name`；
   - 若 `count < 2`，说明当前仍为单客户端，**立刻将真双端多人条目记为 `blocked`（原因：缺第二真实客户端，ADR-0040）**，不得伪造通过；
   - `count >= 2` 时，分别用 `--player <uidA>` / `--player <uidB>` 路由客户端 `exec`（或双端各自操作），按 [features/multiplayer-squad-pk-rescue.md](features/multiplayer-squad-pk-rescue.md) 逐项验证并记录（同时注记 ADR-0040 尚未实测的 `--player` 路由表现）。

### 4. 画面抓屏（强制走工具链）

```bash
# 1. 先检查目标窗口（若报错找不到窗口，先确认编辑器未最小化 Iconic=False）
lua tools/cli.lua screenshot --info

# 2. 后台 PrintWindow 抓取（无需置前），连拍两张比哈希防旧帧
lua tools/cli.lua screenshot --out tmp/verify-se-fish/<run-id>/step1-a.png
lua tools/cli.lua screenshot --out tmp/verify-se-fish/<run-id>/step1-b.png
```

---

## Evidence（取证与证明标准）

### 证据落盘位置（Cleanup 严禁删除）

- **日常验证证据**：`tmp/verify-se-fish/<run-id>/`（目录内含 `summary.md`、命令输出/日志节选 `*.log`、双帧截图 `*.png`）。
- **正式 C 级条款归档**：`docs/acceptance/evidence/<session-name>/session.md`（逐条标 `✅` 或 `❌` 后运行 `lua tools/cli.lua acceptance --infer` 复核状态反推）。

### 证明标准

1. **真实路径优先**：证明必须走玩家真实操作（`input`、真实交互入口、正常业务事件）；不以直接改内存/调内部 setter 或 GM 直改结果替代玩家路径。若前置布景使用了 GM 或服务端定位，必须在证据中明示「前置布景方式」与「被测动作走真实路径」。
2. **动作与结果成对记录**：每步同时保留「执行的命令/操作」与「操作后的状态变化」（坐标/属性/库存/日志行/截图），不只贴一张终态截图。
3. **验证副作用**：界面变化之外，必须从服务端只读状态（或退局重进同槽）验证持久化、扣费、库存、世界对象归属等真实副作用。
4. **帧新校验**：单张截图不能证明帧已刷新；截图证据须确认窗口尺寸未突变，并对关键操作前后连拍比哈希或直接用 `read_image` 审图确认画面内容。
5. **诚实分层**：离线 A/B 级通过不能冒充 C 级试玩通过；单客户端试玩通过不能冒充真双端多人通过；未满足前置条件的入口记为 `blocked` 并附上命令与缺失前提。

---

## Cleanup（清理与保底恢复）

无论验证成功还是中途失败，**每次迭代结束都必须执行清理**：

1. **释放持续输入**：`"$CLI" input stop --json || true`。
2. **只停自己启动的会话/实例**：
   - 若本轮新启动了试玩：执行 `"$CLI" play stop --json`，并轮询 `"$CLI" status --json` 到 `edit_mode=true, in_game_runtime=false, editor_state="idle"`；
   - 若本轮额外拉起了编辑器进程：仅按本轮记录的 PID/端口执行 `lua tools/cli.lua editor stop <pid|port>`。**严禁**按 `client.exe` 进程名批量强杀，也禁止停掉用户原本正在使用的编辑器窗口。
3. **还原 `qa-slot`**：
   - 若开跑前记录的槽名非空，用 `lua tools/cli.lua qa-slot set <原槽名>` 还原；若原本为空且仅本次开启了临时槽，用 `lua tools/cli.lua qa-slot off` 还原（切勿用 `git checkout` 误清用户对 `common/game_cfg.lua` 的其他未提交改动）。
4. **确认证据完好**：清理完成后显式检查 `tmp/verify-se-fish/<run-id>/`（或 `docs/acceptance/evidence/<session-name>/session.md`）依然存在且非空——**任何删除证据的清理都是失败的清理**。

---

## Helpers（附带可执行脚本）

| 脚本 | 职责 | 调用方式 |
|---|---|---|
| [scripts/doctor.lua](scripts/doctor.lua) | 一键只读环境与实例体检（Lua/busted/CLI/宿主 diff/qa-slot/试玩态/截图通道） | `lua .agents/skills/verify-se-fish/scripts/doctor.lua [--instance <id>] [--json]` |
| [scripts/probe_online_players.lua](scripts/probe_online_players.lua) | 试玩服务端只读探针：枚举真实 `Players:GetPlayers()`、坐标、存档、小队，判定 solo/multiplayer | `"$CLI" exec --platform server --file D:/dev/github/se-fish/.agents/skills/verify-se-fish/scripts/probe_online_players.lua --json` |

## Feature Map（功能验证地图）

验证具体玩法前先读索引 [features/README.md](features/README.md)，按功能进入对应配方（覆盖单人核心循环与多人规则双轨测试）。随玩法演进更新本图时，使用 `/maintain-verification-skill`。
