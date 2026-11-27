# Spoke 游戏架构现状快照

本文记录 se-fish 当前工作树的业务代码水位、六层依赖声明与 Spoke 运行时拓扑。统计和门禁的复核基线为 [`de5f0178fd417605c4c310a8168c320396a7938f`](https://github.com/qinyuanj/se-fish/commit/de5f0178fd417605c4c310a8168c320396a7938f)。上游 `05_BaseDefence` 的固定版本调研已拆分至 `SPOKE_BASE_DEFENCE_RESEARCH.md`。

## 数据口径

- 统计 `server/`、`client/`、`common/` 下的 Lua 文件，排除 `packages/` 与 `_trigger/`。
- 复核窗口内共 **142 个业务 Lua 文件、34284 行**：`server/` 61 个文件 19852 行，`client/` 39 个文件 8659 行，`common/` 42 个文件 5773 行。
- 统计包含该窗口内工作树的未提交 Lua 改动；上述 HEAD 是提交基线，不表示这些改动已入库。
- 原样重跑下列命令可复核三端文件数和行数：

```powershell
python -c "import os, glob; [print(d, len(fs), sum(len(open(p, encoding='utf-8', errors='replace').readlines()) for p in fs)) for d in ['server','client','common'] for fs in [[p for p in glob.glob(os.path.join(d,'**','*.lua'), recursive=True) if os.sep+'packages'+os.sep not in p and os.sep+'_trigger'+os.sep not in p]]]"
```

## 六层模块分布

本仓保留 `client/`、`server/`、`common/` 三个运行端目录。[ADR-0012](docs/adr/0012-six-layer-architecture.md) 确立六层单向依赖；[tools/arch_policy.lua](tools/arch_policy.lua) 的 `M.policy.levels` 是完整层归属的唯一声明，[policy.edn](policy.edn) 是其投影，[arch_policy_test.lua](tests/native/guards/arch_policy_test.lua) 检查二者同步。依赖只能指向同层或更内层，详见 [docs/architecture.md](docs/architecture.md)。

| 层级 | 当前命名空间 | 职责 |
|---|---|---|
| L1 入口 | [client/main.lua](client/main.lua)、[server/main.lua](server/main.lua) | 启动、宿主适配、玩法服务装配、引擎事件翻译与依赖注入 |
| L2 应用流程与宿主 | `server.world_host`、`server.ability_api`、`server.ability_behaviors`、`server.player_data_host`、`server.save_host`、`server.platform_host`、`server.fish_ability`；[client/views/](client/views/root_view.lua) | 服务端世界、玩家和活鱼树，以及持久化、平台、能力宿主；客户端 Spoke 视图树与交互流程 |
| L3 展示与运行端支撑 | [client/store/](client/store/client_store.lua)、`client.game_ui`、`client.damage_float`、`client.interaction_bubble`、`client.main_hud_layout`、`client.press_gesture`、`client.weapon_aim`；`server.fish_behaviors`；`common.re_util`、`common.engine_read`、`common.util`、`common.teleport_util`、`common.damage_notice`、`common.gar_bite_notice` | 对视图暴露只读响应式状态，提供展示、布局、手势、瞄准、行为分发与引擎协议适配 |
| L4 共享规则与业务状态 | `server.data`、`server.swing_registry`；[common/spoke_clock.lua](common/spoke_clock.lua)、[common/game_cfg.lua](common/game_cfg.lua)、`common.attr_model`、`common.fish_catch`、`common.vitals` 等 | 存档与记录、挥砍登记、确定性时钟、配置解析与共享玩法计算；完整名单以 `M.policy.levels` 为准 |
| L5 配置内容 | `common.cfg` | 鱼、物品、商店、抽奖、盲盒及占位资产数据 |
| L6 包 | `client.packages`、`server.packages`、`common.packages` | 整包交付的官方包与自研包；包不得反向依赖包外业务 |

三端 `packages` 同属 L6，但不进入生成架构图和质量度量；它们仍受分层与循环依赖门禁约束，范围依据 [ADR-0021](docs/adr/0021-packages-outside-business-scope.md)。`common.util` 含引擎等待、通知与 `REUtil` 依赖，因此归 L3；`common.game_cfg` 含配置解析和玩法计算，因此归 L4。

## 运行时 Spoke 树拓扑

[ADR-0032](docs/adr/0032-spoke-native-lifecycle-architecture.md) 定义服务端三类隔离树与客户端单轨响应式视图。当前代码中的对应实现如下。

| 运行单元 | 当前结构与证据 |
|---|---|
| `ServerRuntime` | [server_runtime.lua](server/world_host/server_runtime.lua) 持有 `SpokeClock`，启动 `SharedWorldTree`，管理玩家树与活鱼宿主，并编排离场三步协议；`step` 驱动时钟和宿主更新 |
| `SharedWorldTree` | [shared_world_tree.lua](server/world_host/shared_world_tree.lua) 对应全局单棵树；ADR-0032 记录 7 个钓鱼区、地面物品、摆渡与全局 `SquadDock` |
| `PlayerTree` | [player_tree.lua](server/world_host/player_tree.lua) 对应每名在场玩家一棵树；存档与库存 State、属性 Memo、生命 Phase、动作与设施会话按声明顺序协作，`dispatch_action` 把命令送入树内 Trigger |
| `FishTree` | [fish_tree.lua](server/world_host/fish_tree.lua) 对应每条活鱼一棵树；当前直接装配 [lifted.lua](server/world_host/fish_phases/lifted.lua)、[combat.lua](server/world_host/fish_phases/combat.lua)、[escaping.lua](server/world_host/fish_phases/escaping.lua)、[wild.lua](server/world_host/fish_phases/wild.lua) 与 [boss.lua](server/world_host/fish_phases/boss.lua) |
| `ClientStore` | [client_store.lua](client/store/client_store.lua) 收敛 RemoteEvent 快照和本地传感器，对视图暴露 Spoke `State` / `Trigger` |
| `RootView` | [root_view.lua](client/views/root_view.lua) 与 [client/main.lua](client/main.lua) 装配单棵客户端视图树；HUD、Modal、Overlay 和动态 Dock 均由该树管理 |
| 跨树与网络边界 | 跨树只读观测使用 `s:d(signal)`，原子状态写入使用 `SpokeRuntime.batch`，依据 ADR-0032 与 [special_item_phase.lua](server/world_host/special_item_phase.lua)；服务端 RemoteEvent 连接位于 [server_runtime.lua](server/world_host/server_runtime.lua) |

模块静态依赖以 [docs/uml/se-fish.edn](docs/uml/se-fish.edn) 为准，该文件由 [policy.edn](policy.edn) 经 `uml_ir` 生成。生成图不表示 RemoteEvent、`s:d` 或运行时快照流；这些运行时关系以 ADR-0032 和上表代码路径为证据。

## 口径与复核

### 复核基线

- 复核窗口：**2026-11-27T17:26:20+08:00 至 2026-11-27T17:26:59+08:00**（Asia/Shanghai）；窗口首尾的三端统计一致。
- HEAD：[`de5f0178fd417605c4c310a8168c320396a7938f`](https://github.com/qinyuanj/se-fish/commit/de5f0178fd417605c4c310a8168c320396a7938f)。
- 三端统计输出：

```text
server 61 19852
client 39 8659
common 42 5773
```

### #386 前后行数实测

#386 对应 [`9aeb759a401ae1d2437b240945b1b7223158fa51`](https://github.com/qinyuanj/se-fish/commit/9aeb759a401ae1d2437b240945b1b7223158fa51)，父提交为 `a20c15a8bc4fcb0881e9a30fb9bbd6079d675b57`。以下结果使用 `git show <sha>:<path> | wc -l` 取得；当前值使用 `wc -l <path>` 取得。

| 文件 | #386 前 | #386 后 | 当前 |
|---|---:|---:|---:|
| `server/world_host/server_runtime.lua` | 1319 | 1192 | 1192 |
| `server/world_host/fish_tree.lua` | 2586 | 761 | 736 |
| `server/world_host/player_tree.lua` | 1080 | 1083 | 1073 |
| `client/main.lua` | 386 | 386 | 386 |

复核命令：

```sh
for p in server/world_host/server_runtime.lua server/world_host/fish_tree.lua server/world_host/player_tree.lua client/main.lua; do
  for rev in 9aeb759^ 9aeb759; do
    printf '%s %s ' "$rev" "$p"
    git show "$rev:$p" | wc -l
  done
  wc -l "$p"
done
```

### 结构检索口径

检索范围为 `server/`、`client/`、`common/`，排除 `packages/`、`_trigger/`、`EggyAPI.lua`。实测结果：

| 检索式 | 当前结果 |
|---|---|
| `update_fish`、`weapon_sessions`、`MgrMap`、`OwnedUnits` | 均为 0 命中 |
| `mount_phase(` | 2 处，均为 [player_tree.lua](server/world_host/player_tree.lua) 中的方法定义 |
| `hud_backpack_open` | 5 处，均位于 [client/main.lua](client/main.lua) 的 HUD 装配及其视图参数中 |
| 裸 `:Connect(` | 仍存在，例见 [server/main.lua](server/main.lua)、[fish_tree.lua](server/world_host/fish_tree.lua)、[client_store.lua](client/store/client_store.lua) |

### 生成图复核

- `uml_ir`：退出码 0，`validResult: true`。
- `uml_display`：`status: ok`。
- 当前投影含 144 个文件节点和 3 个外部包节点。
- 当前 [docs/uml/se-fish.edn](docs/uml/se-fish.edn) 的 SHA-256 为 `f34fd846fcd766668f8d439d3760a2d25f1112025f380c4b331940a093e3a635`；`uml_display` 状态为 `ok`。

### 门禁复核

```sh
lua tools/cli.lua test guards -- tests/native/guards/arch_policy_test.lua
lua tools/cli.lua test full
```

在当前 HEAD 的实测结果：

```text
14 successes / 0 failures / 0 errors / 0 pending : 0.797 seconds
1621 successes / 0 failures / 0 errors / 0 pending : 28.703 seconds
```

两条命令退出码均为 **0**。
