# se-fish 功能验证地图（Feature Map）

本目录是《钓鱼怎么这么危险啊喂！》（`se-fish`）面向用户视角的试玩与验收驾驶真源，覆盖**单人可完成（Solo clear）核心循环**与**多人规则（离线多连接代码路径 + 真实双客户端联机）**。驱动前先阅读本索引，再按目标功能进入对应配方。

> 条款级真源在 [验收矩阵索引](../../../../docs/acceptance/README.md)；本目录负责把高频用户旅程拆解为可执行的驱动步骤、前置条件、观测点与避坑清单，不重复抄写条款全文。

## Baseline preconditions（基线前置条件）

- 在仓库根执行 `lua .agents/skills/verify-se-fish/scripts/doctor.lua`，确认无 `[BLOCKER]`。
- 明确本轮运行的证据目录：`tmp/verify-se-fish/<run-id>/`（Cleanup 不得删除）。
- 单人试玩前须通过 `lua tools/cli.lua qa-slot new`（或指定已有验收槽）隔离存档，并执行 `lua tools/cli.lua deploy`，确认宿主目录 `code diff` 干净（仅允许 `unit_scripts/`、`.agents/` 豁免项）。
- 试玩就绪后，执行一次服务端只读探针 [probe_online_players.lua](../scripts/probe_online_players.lua)，确认在线人数与 `save=ready`。
- 禁止在未确认所有权的情况下驱动他人的编辑器实例；多实例时所有 `editor-cli` 命令必须显式带 `--editor-instance <pid|port|地图名>`。

## Driving conventions（驱动约定）

- 优先走玩家真实操作（`editor-cli input`、EUI 按钮、正常业务交互），不把直接改状态或 GM 跳步算作玩家路径通过。
- 命令参数与日志标记按字面原样执行；客户端 `exec` 内部统一单引号，且绝不修改 `client/main.lua`。
- 抓屏一律走 `lua tools/cli.lua screenshot`（先跑 `--info` 确认编辑器窗口非最小化），关键状态连拍两张校验帧新。
- 多人规则严格区分两轨：
  1. **离线多连接轨（A/B 级）**：`lua tools/cli.lua test spec` 与 `lua tests/probes/local_link_runtime.lua`；
  2. **真实双端联机轨（C 级）**：必须 `probe_online_players.lua` 返回 `count>=2`，否则该轨记为 `blocked`（[ADR-0040](../../../../docs/adr/0040-local-multiplayer-not-simulatable-in-editor.md)）。
- 每次改动状态后在 Cleanup 恢复 `qa-slot` 与停止持续输入，但不删除证据文件。

## Proof and skip reporting（取证与跳过报告规范）

- 每条证据必须记录：**Feature ID + 入口路径 + 执行命令/操作 + 观测结果（日志/状态/截图）**。
- 试玩 UI 证据包含关键操作前后截图（`lua tools/cli.lua screenshot`）及 `read_image` 复核结论，并配服务端/客户端日志对照。
- 离线命令证据包含完整命令、关键输出摘要与退出码。
- 变更持久化类证据必须包含二次只读回读或「停试玩 → 同槽重进」后的状态复核。
- 前置条件不满足（例如缺少真实第二客户端、编辑器窗口最小化无法抓屏）时，必须如实报告 `blocked` / 未达成的具体前提与已尝试命令，**绝不通过其他入口或降级手段伪报已验证**。

## Feature entry contract（功能文件契约）

每份功能文件包含：一个 H1 标题、一段用户视角概述，以及四个固定 H2 小节：
1. `## Sub-features` — 子功能 ID 与一句话行为定义
2. `## How to get to it (user POV)` — 玩家视角的全部进入路径
3. `## Driving it with tools/cli.lua & editor-cli` — 前置条件、分步驱动命令与可观察终态
4. `## Gotchas` — 本仓实测坑点、能力边界与前置缺失时的报告口径

## Feature index（功能索引）

| Feature | 覆盖范围 | 对应模式 | 关联验收分片 |
|---|---|---|---|
| [solo-fishing-loop.md](solo-fishing-loop.md) | Z1 鱼塘买竿/拾饵、抛竿、上钩、收线、举鱼与放下（普通鱼逃跑 / 精英战斗） | 单人试玩 + A 级单测 | [04-fishing-system.md](../../../../docs/acceptance/04-fishing-system.md) |
| [combat-and-survival.md](combat-and-survival.md) | 武器装备与攻击活鱼、受击进入濒死（15 秒）、死亡免费弱复活（30 秒/60 秒虚弱）与复活入口 | 单人试玩 + A/B 级单测 | [06-combat-and-growth.md](../../../../docs/acceptance/06-combat-and-growth.md)、[11-downed-death-revive.md](../../../../docs/acceptance/11-downed-death-revive.md) |
| [economy-shop-and-grill.md](economy-shop-and-grill.md) | 钓鱼佬回收鱼获、钓场商店四分页购买/限购、Z3+ 烤炉烤制倍率曲线与烤糊 30 伤害 | 单人试玩 + A/B 级单测 | [07-economy-and-shop.md](../../../../docs/acceptance/07-economy-and-shop.md)、[08-npc-exchange-ferry.md](../../../../docs/acceptance/08-npc-exchange-ferry.md)、[10-grilling.md](../../../../docs/acceptance/10-grilling.md) |
| [save-and-rejoin.md](save-and-rejoin.md) | QA 存档槽隔离、退出重进恢复个人持久状态、共享世界活鱼/地面物不入个人档与 ADR-0028 四栏覆盖 | 单人试玩 + B 级单测 | [18-save-and-recovery.md](../../../../docs/acceptance/18-save-and-recovery.md) |
| [multiplayer-squad-pk-rescue.md](multiplayer-squad-pk-rescue.md) | 小队组队（3 人上限/2 米距离/10 秒超时）、同队与鱼塘免伤、野外 PK、他人抢救（10% 恢复）与共享世界竞争 | 离线多连接（A/B）+ 单端骨架 + 真双端联机（C） | [09-multiplayer-rules.md](../../../../docs/acceptance/09-multiplayer-rules.md)、[production-switches.md](../../../../docs/acceptance/production-switches.md) |
