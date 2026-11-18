# 测试耗时基线（Windows 原生，2026-11-18）

> 一次性基线测量：全仓所有测试的耗时，附可复现命令与误差口径。
> 测量对象：仓库检出 `D:/dev/github/se-fish`；主数据集对应提交 **`4eb7b67`**（测量中途从 `368229a` 推进，见 2.5）。
> 所有数字都标明来源（runner 内部计时 或 外部 wall 计时）与命令；制品见第 9 节。
> **测量环境**：测量期间蛋仔编辑器客户端 `client` 进程未运行。编辑器跑地图时同一套件实测慢约 2×（`client` 进程占满 CPU），任何后续基线与本次对比前须先确认编辑器状态，否则没有可比性。
> **文件名**：本报告写于 `qa-slot` 改名之前，文中的 `acceptance_slot_*` 即现在的 `qa_slot_*`，数字不受影响。
> **已过时项**：文中反复出现的 pre-commit hook（`tools/hooks/pre-commit`）已随 [ADR-0018](adr/0018-delete-pre-commit-hook.md) 删除，`slow/pre_commit_hook_test.lua`（15.016 s / 12 用例）一并移除；本仓现在没有任何提交时的自动检查。

## 0. 摘要

| 项 | 结果 | 来源 |
|---|---|---|
| 日常车道 `lua tools/cli.lua test fast` | **11.1 s**（1552 用例 / 142 文件，0 失败 0 错误 0 待定） | busted 自报，5 轮中位数 |
| 收尾车道 `lua tools/cli.lua test full` | **34.5 s**（1597 用例 / 148 文件，0 失败 0 错误 0 待定；4 轮 33.7 / 34.1 / 35.0 / 35.8 s，中位 34.5 s） | busted 自报，4 轮 |
| 覆盖率跑（`--coverage`，CRAP 口径） | **65.7 s** | busted 自报，1 轮 |
| 全套件"只发现 + 加载文件"的固定成本 | **1.125 s** | 空跑基线，2 轮 |
| 单文件端到端 wall 合计（148 个进程串行） | **53.7 s** | 外部 wall，3 轮中位 |
| 单例耗时中位数 | **0 ms**（即短于 busted 的一个计时 tick 15.625 ms） | runner 内部 |

三条结论：

1. **耗时极度集中**：7 个真起子进程的接缝测试文件（69 个用例，占文件数 4.7%）占全部文件级耗时的 **69.9%**；5 个文件占 **73.4%**；1597 个用例里 90.2% 短于 15.6 ms，最慢的 20 个用例占了逐用例累计的 **79.5%**。
2. **最贵的不是逻辑，是进程**：`git commit` 触发 pre-commit hook 的回归（15.0 s）、真 `blender.exe`（5.6 s）、`robocopy /MIR`（1.2 + 0.9 s）三者相加已过 22 s。
3. **夹具时间不计入用例耗时**：busted 的 `it` executor 在 `test.start` 之前跑 `before_each`、在 `test.end` 之后跑 `after_each`（`busted/init.lua:35/39/48/51`）。`pre_commit_hook_test` 文件级 15.016 s 里只有 10.030 s 落在用例内，其余 4.99 s（33%）是夹具。任何"按用例统计"的报表都会系统性低估贵测试。

## 1. 测试资产全景

### 1.1 入口与车道

| 入口 | 命令 | 范围 | 触发时机 |
|---|---|---|---|
| fast 车道 | `lua tools/cli.lua test fast` | `tests/native` | 日常开发 |
| full 车道 | `lua tools/cli.lua test full` | `tests/native` + `tests/native/slow` | 收尾、完成判据 |
| default（裸 `busted`） | `busted` | 与 full 相同 | crapper 列测试文件时读 default |
| 提交闸门 | `tools/hooks/pre-commit` → `lua tools/cli.lua test fast` | 与 fast 相同 | 每次 `git commit`（含 `.lua`/`.busted` 时） |
| 覆盖率 | `busted --run=full --coverage` | 与 full 相同 + LuaCov | crapper（人工在插件面板发起） |

车道由根目录 `.busted` 定义，关键项：`ROOT` 白名单（只列 `tests/native` 与 `tests/native/slow`，`recursive = false`，slow 因此不会被 fast 吞掉）、`pattern = "_test"`、`helper = "tests/native/helper.lua"`、`sort-files = true`、`auto-insulate = true`、`output = "plainTerminal"`。

### 1.2 文件与用例

| 资产 | 数量 | 是否入车道 |
|---|---:|---|
| `tests/native/*_test.lua`（fast） | 142 个文件 / 1552 用例 | 是（fast、full） |
| `tests/native/slow/*_test.lua`（slow） | 6 个文件 / 45 用例 | 是（仅 full） |
| `tests/support/*.lua` 共享夹具 | 19 个 | 否（被 require） |
| `tests/native/helper.lua` | 1 个 | 否（helper 钩子） |
| `tests/native/fixtures/hook_failure_case.lua` | 1 个 | 否（被 `hook_cleanup_test` 加载） |
| `tests/probes/*.lua` 手工探针 | 55 个 | **否**（不在任何 ROOT 内，需编辑器/试玩环境） |

按内容证据分类（grep `seam.spawn(`/`io.popen(` 与 `repo_root()` 判定，见 7.1）：

| 类别 | 文件数 | 用例数 | 文件级耗时 | 占比 |
|---|---:|---:|---:|---:|
| 接缝/集成（真起子进程：git / robocopy / blender / lua） | 7 | 69 | 23.797 s | 69.9% |
| 真实仓库扫描（门禁/校验，读全树源码） | 3 | 34 | 1.532 s | 4.5% |
| 其余（业务单测 + 夹具断言，纯 Lua，引擎用桩） | 138 | 1494 | 8.718 s | 25.6% |

接缝/集成那 7 个文件是：`seam_test.lua`、`cli_entry_test.lua`、`hook_cleanup_test.lua`、`slow/blender_transport_test.lua`、`slow/deploy_transport_test.lua`、`slow/pre_commit_hook_test.lua`、`slow/sync_transport_test.lua`。真实仓库扫描的 3 个是：`arch_policy_test.lua`、`fs_fixture_test.lua`、`screenshot_cli_test.lua`。`blender_cli_test.lua`（30 例 / 0.093 s）与 `platform_seam_test.lua`（19 例 / 0.062 s）虽然 grep 命中 `seam.spawn`，但那是桩替换、不起真进程，归入"其余"。

### 1.3 哪些"检查"不算测试（本报告不跑）

- **本仓没有任何 CI 配置**（`docs/agents/workflow.md`「实机验收在 Windows 原生」明确：历史上也从未有，不新增）。唯一自动闸门是 pre-commit hook。
- **质量工具** `uml_crap` / `uml_mutate` / `uml_dry`：由人在 dsh-uml-viewer 插件面板发起，不进 CLI、不进 hook。本次只测了它们的底层跑法（full + 覆盖率）。
- **构建/同步/编辑器操作**（`deploy`、`sync`、`acceptance-slot`、`ability-presets`、试玩 E2E、`code validate`）：会改宿主目录或依赖编辑器在线，**不是测试**，本次不跑（见第 8 节）。
- **`tests/probes/` 的 55 个探针**：手工探针，`.busted` 的 ROOT 白名单把它们排除在任何车道外。

## 2. 测量方法与误差口径

### 2.1 两套计时来源（两者都标在表里）

| 来源 | 取值方式 | 分辨率 | 覆盖范围 | 用途 |
|---|---|---|---|---|
| **runner 内部** | busted 在 `core.lua` 的 `safe_publish` 里给每个 suite/file/test 打 `starttick`/`endtick`（`busted.monotime()`），算出 `element.duration`；本报告用自定义输出处理器 `tmp/timing/timing_handler.lua` 原样读取这三个字段，不自行计时 | **15.625 ms**（见下） | suite 总耗时、逐文件、逐用例 | 逐用例/逐文件的主数据 |
| **外部 wall** | bash `date +%s%N` 包住整条命令，取毫秒差 | ~1 ms | 单文件（独立进程）端到端 | 交叉验证 + 单文件成本 |

**runner 内部计时的分辨率实测**（这条决定了所有小数位怎么读）：

- 连续采样 `system.monotime()` 的相邻变化量，40 个样本只有两个取值：`0.015` 与 `0.016` s → 底层是 Windows 的 64 Hz 计时器，**步长 15.625 ms**（1/64 s），显示到毫秒。
- 1597 条用例记录只有 **42 个不同取值**，且全部是 0.015625 s 的整数倍（例如 47 ms = 3 tick、531 ms = 34 tick、2703 ms = 173 tick）。
- tick 直方图（tick 数:用例数）：0t:1440、1t:97、2t:9、3t:15、4t:4、5t:1、6t:2、7t:3 …… 173t:1——**没有一个用例落在 0 与 1 tick 之间**，这本身就是粒度的直接证据。
- 因此"0 ms"的真实含义是**该用例短于一个 tick（<15.625 ms）**，不是"零成本"。

### 2.2 误差量级（对应"单项 <200 ms 时误差多大"）

| 被测量的量 | 误差量级 | 能不能用来排序 |
|---|---|---|
| 单个用例 <15.6 ms | 读数 0，误差 100% | 不能，只能归入"1 tick 以内" |
| 单个用例 15.6–200 ms | ±15.6 ms（±7.8% 到 ±100%） | 只能判量级 |
| 单个用例 >500 ms | ±15.6 ms（约 ±3%） | 可以 |
| 单文件进程内耗时 | ±15.6 ms；最小的文件（35 个 ≤16 ms）只有一个 tick 的分辨力 | 小文件之间不可比 |
| 整套件总耗时 | ±15.6 ms / 34 s ≈ ±0.05% | 可以 |
| 单文件端到端 wall（外部） | ±(进程启动 93–142 ms) + 抖动 | 小文件的 wall 几乎全是启动成本，不代表测试本身 |

单文件进程启动成本实测：`busted --run=fast --filter=__no_such_case__ tests/native/ability_api_test.lua` → wall 93/142 ms（0 用例）；`lua -e "print(1)"` → 36–86 ms。逐文件表的 wall 与进程内耗时之差（中位 **116 ms**）就是这个成本。

### 2.3 环境

| 项 | 值 |
|---|---|
| OS | Microsoft Windows 11 专业版 Insider Preview，build 26220（`uname` 报 `MSYS_NT-10.0-26220`，Git Bash/MSYS 环境） |
| Lua | **Lua 5.4.6**（`C:/Users/Lzx_8/AppData/Local/Programs/Lua/bin/lua.exe`），与 `docs/agents/workflow.md` 要求的 5.4 一致 |
| 测试 runner | **busted 2.3.0**（LuaRocks 装在 `%APPDATA%\\luarocks\\bin`，`busted.bat`） |
| CPU | AMD Ryzen 5 5500，**6 物理核 / 12 逻辑核**，3.6 GHz |
| 内存 | 31.9 GB |
| 磁盘 | SSD（GVE-1TB 2280） |
| 并行 | **无**。busted 单进程串行跑用例；`.busted` 未开 shuffle，`sort-files = true` 固定文件序；测试内部只有串行的 `seam.spawn` 子进程调用 |

### 2.4 冷启动 vs 热启动

Windows 上不借助管理员工具无法清文件缓存，因此本报告只区分**会话首跑**与**重复跑**，并把差值交给噪声判读：

| 车道 | 轮次 | busted 自报 s | 外部 wall ms |
|---|---|---|---|
| fast | r1（本会话首跑，无预热） | 11.000 | 11355 |
| fast | r2 | 14.688 | 15205 |
| fast | r3 | 13.094 | 13433 |
| fast | r4 | 11.141 | 11461 |
| fast | r5 | 11.141 | 11460 |
| full | r1 | 33.688 | 33959 |
| full | r2 | 35.781 | 36167 |
| full | r3 | 35.016 | 35310 |
| full | r4 | 34.062 | （未单独计时） |

判读：**本机测不到冷启动惩罚**。fast 的首跑（11.0 s）反而是 5 轮里最快的；波动来自机器负载而不是缓存。相对抖动：fast 极差 11.0–14.7 s（+34%），full 极差 33.7–35.8 s（+6%）。fast 更飘的原因是它 11 s 里有 1.1 s 加载 + 绝大多数用例亚毫秒，抖动来自解释器与调度；full 的时间由子进程 I/O 等待主导，反而稳定。

**给"单项 <200 ms"的结论**：这类数字不能当性能指标用——runner 内部只有 15.6 ms 粒度，外部 wall 又被 93–142 ms 的进程启动淹没。

### 2.5 测量期间的干扰（必须声明）

- **仓库被并发修改并提交**：本次会话有另一个 agent 同时在同一工作区改仓库。测量开始时 HEAD 是 `368229a`，fast 1549 例 / full 1594 例；中途它把改动提交成 **`4eb7b67`**（“工具链：截图加显示路径自检（--info）”），其中 `tests/native/screenshot_cli_test.lua` +28 行、+3 用例，用例数因此变成 **1552 / 1597**。第 3/4/5/6 节的主数据集（`full_r4`）与逐文件 r3 轮都在 `4eb7b67` 的树上；逐文件 r1/r2 轮在 `368229a` 上（表里三轮并列，正好用来看抖动）。测量收尾时在 `4eb7b67` 上复核 fast：1552 例全过，busted 13.547 s / wall 13989 ms（比 r4/r5 慢，属负载噪声）。
- **并发负载**：fast r2（14.7 s）与 `arch_policy_test` 的 1.6→2.8 s 波动，很可能就是同一台机器上其他 agent 的进程在跑。
- `tasklist` 在两轮之间未见常驻 `lua.exe`，但另一个 agent 的短进程无法逐一排查。

## 3. 轮次结果（全部退出码 0，0 失败 / 0 错误 / 0 待定）

| 轮次 | 命令 | 用例数 | busted 自报 s | 外部 wall ms | 退出码 |
|---|---|---:|---:|---:|---:|
| fast r1 | `lua tools/cli.lua test fast` | 1549 | 11.000 | 11355 | 0 |
| fast r2 | 同上 | 1549 | 14.688 | 15205 | 0 |
| fast r3 | 同上 | 1549 | 13.094 | 13433 | 0 |
| fast r4 | 同上 | 1552 | 11.141 | 11461 | 0 |
| fast r5 | 同上 | 1552 | 11.141 | 11460 | 0 |
| fast 直跑 | `busted --run=fast tests/native` | 1549 | 11.765 | 12031 | 0 |
| fast 冒烟（带计时处理器） | `busted --run=fast -o timing_handler -m "tmp/timing/?.lua"` | 1549 | 11.625 | 11932 | 0 |
| full r1 | `busted --run=full -o timing_handler -m "tmp/timing/?.lua"` | 1594 | 33.688 | 33959 | 0 |
| full r2 | 同上 | 1594 | 35.781 | 36167 | 0 |
| full r3 | 同上 | 1597 | 35.016 | 35310 | 0 |
| **full r4（主数据集）** | 同上 | **1597** | **34.062** | （未计时） | 0 |
| full + 覆盖率 | `LUACOV_STATS_FILE=tmp/timing/luacov.stats.out busted --run=full --coverage` | 1597 | 65.734 | 66129 | 0 |
| slow 目录直跑 | `busted --run=full tests/native/slow` | 45 | 23.109 | （未计时） | 0 |
| full 空跑 | `busted --run=full --filter=__no_such_case__` | 0 | 1.125 / 1.125 | 1317 / 1298 | 0 |
| fast 空跑 | `busted --run=fast --filter=__no_such_case__` | 0 | 1.140 / 1.141 / 1.531 | 1317 / 1309 / 1818 | 0 |

带 `timing_handler` 的轮次与走 CLI 的轮次结果一致（1492… 例数相同、0 失败），差别只有"是否落逐用例 JSON"。CLI 本身不做别的：`tools/test.lua` 只是 `seam.spawn{ argv = { busted, "--run=<lane>" } }`，退出码归一（通过 0 / 有失败 1 / busted 缺失 3）。

**覆盖率开销**：34.06 s → 65.73 s（**+93%**）。这是 crapper 跑 CRAP 的固定成本，也是 mutation 之外最贵的单项检查。

## 4. 分布画像

主数据集：`tmp/timing/full_r4.json`（full 车道，1597 用例 / 148 文件，busted 自报 34.062 s；逐用例累加 23.746 s；逐文件累加 34.047 s）。

| 耗时区间（按 busted 的 15.625 ms 计时 tick 分桶） | 用例数 | 占比 | 累计占比 | 该区间合计耗时 s |
|---|---:|---:|---:|---:|
| 0（不足 1 tick，<15.625 ms） | 1440 | 90.2% | 90.2% | 0.000 |
| 1 tick（15.6–31.25 ms） | 97 | 6.1% | 96.2% | 1.512 |
| 2–3 tick（31–62 ms） | 24 | 1.5% | 97.7% | 0.983 |
| 4–7 tick（62–125 ms） | 10 | 0.6% | 98.4% | 0.846 |
| 8–19 tick（125–312 ms） | 5 | 0.3% | 98.7% | 1.141 |
| 20–63 tick（312 ms–1 s） | 13 | 0.8% | 99.5% | 7.203 |
| 64+ tick（>1 s） | 8 | 0.5% | 100.0% | 12.061 |

集中度（同数据集）：

| 口径 | 值 | 占该口径总量 |
|---|---:|---:|
| 最慢 1 个用例 | 2.703 s | 11.4% |
| 最慢 8 个用例（>1 s） | 12.061 s | 50.8% |
| 最慢 20 个用例 | 18.873 s | 79.5% |
| 最慢 2 个文件 | 20.641 s | 60.6% |
| 最慢 5 个文件 | 25.000 s | 73.4% |
| fast 车道 8 个文件 | 5.579 s | 49.4%（fast 文件级 11.282 s） |
| slow 车道 6 个文件 | 22.765 s | 66.9%（全程 34.047 s） |

文件级分带（148 个文件按进程内耗时）：

| 带 | 文件数 | 合计耗时 |
|---|---:|---:|
| ≤16 ms（1 tick 内） | 35 | 0.545 s |
| 17–50 ms | 33 | 1.347 s |
| 51–100 ms | 28 | 2.043 s |
| 101–300 ms | 11 | 1.783 s |
| 301–1000 ms | 7 | 3.329 s |
| >1 s | 5 | 25.000 s |

**画像**：典型的双峰长尾。90.2% 的用例在 1 个 tick 以内（<15.6 ms），中位数读数就是 0；剩下 10% 里又有一半强（157 例里 8 例）超过 1 s。中间地带（15.6–125 ms）只有 131 个用例、合计 3.34 s（1 tick 的 97 例 + 2–7 tick 的 34 例）。换句话说：**这个测试套件的成本不是"很多小测试慢慢累积"，而是"少数几个真起进程的测试"**。

## 5. 逐文件耗时（148 个文件，按进程内耗时降序）

列说明：`进程内耗时` = busted 文件级计时（`file.start`→`file.end`，含文件加载与该文件内所有夹具）；`wall 中位`/`最小/最大` = 该文件单独起一个 busted 进程从外部计时的 3 轮结果（含进程启动）。

| # | 文件（相对 tests/native/） | 车道 | 用例数 | 进程内耗时 ms | wall 中位 ms | wall 最小/最大 ms |
|---:|---|---|---:|---:|---:|---|
| 1 | slow/pre_commit_hook_test.lua | slow | 12 | 15016 | 16766 | 15615 / 16961 |
| 2 | slow/blender_transport_test.lua | slow | 5 | 5625 | 6033 | 5389 / 7360 |
| 3 | main_hud_layout_test.lua | fast | 13 | 1687 | 1513 | 1399 / 1701 |
| 4 | arch_policy_test.lua | fast | 13 | 1500 | 1695 | 1582 / 2833 |
| 5 | slow/deploy_transport_test.lua | slow | 6 | 1172 | 1306 | 1256 / 1549 |
| 6 | slow/sync_transport_test.lua | slow | 17 | 937 | 1119 | 1066 / 1979 |
| 7 | seam_test.lua | fast | 19 | 578 | 636 | 537 / 645 |
| 8 | compendium_test.lua | fast | 12 | 453 | 549 | 476 / 625 |
| 9 | blindbox_settle_test.lua | fast | 27 | 360 | 617 | 546 / 711 |
| 10 | cli_entry_test.lua | fast | 9 | 359 | 565 | 527 / 571 |
| 11 | ferry_test.lua | fast | 30 | 329 | 458 | 408 / 618 |
| 12 | survival_test.lua | fast | 41 | 313 | 499 | 349 / 808 |
| 13 | weapon_system_test.lua | fast | 44 | 282 | 456 | 392 / 524 |
| 14 | economy_persistence_test.lua | fast | 18 | 281 | 372 | 363 / 396 |
| 15 | status_effect_test.lua | fast | 19 | 219 | 511 | 423 / 599 |
| 16 | grill_test.lua | fast | 40 | 156 | 243 | 235 / 270 |
| 17 | save_foundation_test.lua | fast | 9 | 141 | 230 | 213 / 239 |
| 18 | guide_persistence_test.lua | fast | 14 | 125 | 222 | 220 / 280 |
| 19 | volcano_combat_test.lua | fast | 12 | 125 | 214 | 210 / 306 |
| 20 | modifier_system_probe_test.lua | fast | 11 | 125 | 179 | 176 / 213 |
| 21 | reef_combat_test.lua | fast | 13 | 110 | 227 | 206 / 230 |
| 22 | hook_cleanup_test.lua | fast | 1 | 110 | 234 | 213 / 279 |
| 23 | attack_animation_test.lua | fast | 10 | 109 | 236 | 209 / 299 |
| 24 | shrimp_pond_test.lua | fast | 12 | 94 | 192 | 187 / 256 |
| 25 | beach_combat_test.lua | fast | 18 | 93 | 204 | 187 / 319 |
| 26 | reel_ui_test.lua | fast | 15 | 93 | 200 | 186 / 233 |
| 27 | blender_cli_test.lua | fast | 30 | 93 | 269 | 223 / 278 |
| 28 | landing_test.lua | fast | 17 | 79 | 177 | 177 / 237 |
| 29 | revive_callback_test.lua | fast | 12 | 78 | 219 | 184 / 224 |
| 30 | ai_migration_test.lua | fast | 12 | 78 | 209 | 173 / 345 |
| 31 | attr_migration_test.lua | fast | 8 | 78 | 169 | 167 / 277 |
| 32 | ability_proto_test.lua | fast | 28 | 78 | 179 | 174 / 301 |
| 33 | records_test.lua | fast | 29 | 78 | 169 | 152 / 172 |
| 34 | main_hud_wiring_test.lua | fast | 15 | 78 | 212 | 182 / 222 |
| 35 | platform_screens_test.lua | fast | 16 | 78 | 161 | 156 / 174 |
| 36 | quest_test.lua | fast | 20 | 78 | 144 | 141 / 168 |
| 37 | fish_feed_test.lua | fast | 11 | 78 | 181 | 177 / 218 |
| 38 | hud_popup_ui_test.lua | fast | 17 | 78 | 208 | 202 / 271 |
| 39 | loot_recycle_test.lua | fast | 11 | 63 | 172 | 167 / 239 |
| 40 | shop_test.lua | fast | 21 | 63 | 182 | 154 / 203 |
| 41 | fish_loot_test.lua | fast | 8 | 63 | 171 | 168 / 232 |
| 42 | exchange_zones_127_test.lua | fast | 9 | 63 | 182 | 179 / 215 |
| 43 | zone_layout_plan_test.lua | fast | 12 | 63 | 175 | 164 / 180 |
| 44 | loot_drop_test.lua | fast | 15 | 62 | 173 | 156 / 192 |
| 45 | save_test.lua | fast | 16 | 62 | 197 | 175 / 205 |
| 46 | item_bar_ui_test.lua | fast | 10 | 62 | 171 | 159 / 265 |
| 47 | eel_combat_test.lua | fast | 15 | 62 | 158 | 153 / 168 |
| 48 | gar_combat_test.lua | fast | 13 | 62 | 159 | 154 / 164 |
| 49 | worktree_init_test.lua | fast | 8 | 62 | 179 | 168 / 209 |
| 50 | boss_bait_test.lua | fast | 11 | 62 | 233 | 231 / 274 |
| 51 | platform_seam_test.lua | fast | 19 | 62 | 170 | 161 / 177 |
| 52 | special_item_mgr_test.lua | fast | 27 | 47 | 210 | 167 / 230 |
| 53 | fish_lift_test.lua | fast | 12 | 47 | 185 | 142 / 189 |
| 54 | forest_combat_test.lua | fast | 14 | 47 | 208 | 173 / 236 |
| 55 | shrimp_combat_test.lua | fast | 10 | 47 | 188 | 144 / 212 |
| 56 | fish_escape_test.lua | fast | 11 | 47 | 183 | 144 / 184 |
| 57 | lottery_ui_test.lua | fast | 12 | 47 | 148 | 146 / 190 |
| 58 | special_item_ui_test.lua | fast | 7 | 47 | 162 | 161 / 190 |
| 59 | fish_air_escape_test.lua | fast | 4 | 47 | 173 | 148 / 193 |
| 60 | prize_weapon_effect_test.lua | fast | 6 | 47 | 138 | 131 / 195 |
| 61 | ability_seams_test.lua | fast | 11 | 47 | 163 | 154 / 318 |
| 62 | vitals_test.lua | fast | 24 | 47 | 154 | 154 / 203 |
| 63 | bait_spot_test.lua | fast | 6 | 47 | 145 | 138 / 273 |
| 64 | editor_finalize_test.lua | fast | 21 | 47 | 223 | 149 / 242 |
| 65 | official_ai_probe_test.lua | fast | 10 | 47 | 148 | 148 / 227 |
| 66 | crab_boss_combat_test.lua | fast | 8 | 47 | 145 | 138 / 151 |
| 67 | lottery_settle_test.lua | fast | 13 | 47 | 173 | 154 / 207 |
| 68 | cfg_fish_items_test.lua | fast | 6 | 46 | 191 | 176 / 222 |
| 69 | prize_growth_wiring_test.lua | fast | 10 | 46 | 178 | 140 / 199 |
| 70 | item_action_ui_test.lua | fast | 8 | 46 | 164 | 150 / 209 |
| 71 | feed_exchange_test.lua | fast | 6 | 46 | 173 | 141 / 187 |
| 72 | prize_weapon_cfg_test.lua | fast | 7 | 32 | 128 | 125 / 130 |
| 73 | ability_presets_test.lua | fast | 35 | 32 | 142 | 138 / 208 |
| 74 | beach_island_cfg_test.lua | fast | 7 | 32 | 202 | 199 / 240 |
| 75 | player_leave_rejoin_test.lua | fast | 6 | 32 | 143 | 141 / 148 |
| 76 | growth_cleanup_test.lua | fast | 4 | 32 | 128 | 116 / 137 |
| 77 | cfg_shop_lottery_test.lua | fast | 6 | 32 | 171 | 150 / 178 |
| 78 | cast_waiting_test.lua | fast | 14 | 32 | 166 | 157 / 248 |
| 79 | item_bar_test.lua | fast | 14 | 32 | 120 | 116 / 167 |
| 80 | shop_pages_test.lua | fast | 18 | 31 | 144 | 127 / 172 |
| 81 | hold_operate_ui_test.lua | fast | 4 | 31 | 140 | 131 / 150 |
| 82 | forest_island_cfg_test.lua | fast | 6 | 31 | 199 | 136 / 232 |
| 83 | king_crab_combat_test.lua | fast | 6 | 31 | 135 | 133 / 152 |
| 84 | save_array_meta_test.lua | fast | 8 | 31 | 131 | 130 / 157 |
| 85 | crab_lake_cfg_test.lua | fast | 5 | 16 | 136 | 131 / 146 |
| 86 | gm_coin_test.lua | fast | 8 | 16 | 127 | 124 / 136 |
| 87 | gm_state_test.lua | fast | 6 | 16 | 131 | 129 / 195 |
| 88 | damage_float_test.lua | fast | 2 | 16 | 114 | 102 / 115 |
| 89 | ferry_ui_test.lua | fast | 5 | 16 | 143 | 137 / 166 |
| 90 | attr_rule_probe_test.lua | fast | 7 | 16 | 136 | 123 / 230 |
| 91 | reel_progress_test.lua | fast | 4 | 16 | 119 | 108 / 188 |
| 92 | screenshot_cli_test.lua | fast | 16 | 16 | 121 | 118 / 126 |
| 93 | eel_ability_failure_test.lua | fast | 6 | 16 | 115 | 111 / 182 |
| 94 | reel_session_test.lua | fast | 16 | 16 | 139 | 126 / 143 |
| 95 | interpreter_test.lua | fast | 3 | 16 | 131 | 105 / 150 |
| 96 | reel_unhook_test.lua | fast | 6 | 16 | 128 | 121 / 134 |
| 97 | placeholder_assets_test.lua | fast | 2 | 16 | 118 | 115 / 123 |
| 98 | vitals_growth_test.lua | fast | 9 | 16 | 175 | 116 / 176 |
| 99 | fs_fixture_test.lua | fast | 5 | 16 | 122 | 113 / 169 |
| 100 | combat_base_test.lua | fast | 9 | 16 | 128 | 126 / 135 |
| 101 | lottery_local_test.lua | fast | 4 | 16 | 133 | 123 / 171 |
| 102 | fixture_lifecycle_test.lua | fast | 5 | 16 | 132 | 131 / 149 |
| 103 | rod_visual_test.lua | fast | 6 | 16 | 129 | 122 / 157 |
| 104 | eggy_json_guard_test.lua | fast | 7 | 16 | 114 | 111 / 170 |
| 105 | lottery_eligibility_test.lua | fast | 5 | 15 | 132 | 110 / 133 |
| 106 | zone_scene_125_test.lua | fast | 6 | 15 | 119 | 118 / 121 |
| 107 | deploy_plan_test.lua | fast | 11 | 15 | 127 | 123 / 129 |
| 108 | hold_operate_test.lua | fast | 6 | 15 | 117 | 114 / 156 |
| 109 | test_cli_test.lua | fast | 10 | 15 | 185 | 131 / 213 |
| 110 | gm_panel_test.lua | fast | 4 | 15 | 129 | 121 / 131 |
| 111 | slow/acceptance_slot_write_test.lua | slow | 4 | 15 | 134 | 134 / 138 |
| 112 | shop_ui_test.lua | fast | 10 | 15 | 133 | 131 / 165 |
| 113 | water_judge_test.lua | fast | 25 | 15 | 128 | 123 / 165 |
| 114 | fish_carrier_test.lua | fast | 28 | 15 | 142 | 130 / 142 |
| 115 | reel_client_test.lua | fast | 6 | 15 | 119 | 112 / 139 |
| 116 | static_require_test.lua | fast | 4 | 15 | 146 | 134 / 175 |
| 117 | rate_limit_test.lua | fast | 25 | 15 | 122 | 118 / 140 |
| 118 | compendium_ui_test.lua | fast | 3 | 15 | 119 | 115 / 140 |
| 119 | fisherman_model_pulse_test.lua | fast | 4 | 15 | 140 | 122 / 145 |
| 120 | baseline_test.lua | fast | 3 | 0 | 112 | 110 / 240 |
| 121 | blindbox_draw_test.lua | fast | 11 | 0 | 163 | 146 / 241 |
| 122 | official_package_bootstrap_test.lua | fast | 1 | 0 | 118 | 103 / 150 |
| 123 | reel_display_test.lua | fast | 10 | 0 | 121 | 113 / 147 |
| 124 | lottery_draw_test.lua | fast | 6 | 0 | 118 | 112 / 197 |
| 125 | hold_operate_mgr_test.lua | fast | 9 | 0 | 123 | 120 / 156 |
| 126 | cfg_item_refs_test.lua | fast | 2 | 0 | 148 | 123 / 150 |
| 127 | attr_model_test.lua | fast | 2 | 0 | 109 | 108 / 202 |
| 128 | item_bar_flow_test.lua | fast | 10 | 0 | 116 | 115 / 132 |
| 129 | acceptance_slot_test.lua | fast | 2 | 0 | 111 | 111 / 322 |
| 130 | achievement_delivery_test.lua | fast | 3 | 0 | 140 | 115 / 471 |
| 131 | attr_presentation_test.lua | fast | 4 | 0 | 113 | 107 / 238 |
| 132 | combat_behavior_test.lua | fast | 6 | 0 | 129 | 110 / 148 |
| 133 | loot_client_test.lua | fast | 5 | 0 | 134 | 110 / 182 |
| 134 | engine_double_test.lua | fast | 5 | 0 | 119 | 114 / 126 |
| 135 | shared_init_test.lua | fast | 3 | 0 | 150 | 108 / 161 |
| 136 | eggy_workspace_test.lua | fast | 4 | 0 | 115 | 110 / 195 |
| 137 | config_anchor_baseline_sync_test.lua | fast | 2 | 0 | 112 | 111 / 122 |
| 138 | gar_bite_warning_test.lua | fast | 5 | 0 | 112 | 112 / 119 |
| 139 | special_item_test.lua | fast | 7 | 0 | 159 | 126 / 286 |
| 140 | sync_plan_test.lua | fast | 7 | 0 | 137 | 113 / 202 |
| 141 | content_validation_test.lua | fast | 4 | 0 | 116 | 114 / 130 |
| 142 | slow/native_slow_test.lua | slow | 1 | 0 | 112 | 111 / 132 |
| 143 | eel_loot_test.lua | fast | 1 | 0 | 129 | 125 / 144 |
| 144 | initial_ability_test.lua | fast | 2 | 0 | 151 | 108 / 167 |
| 145 | ability_api_test.lua | fast | 1 | 0 | 123 | 118 / 266 |
| 146 | assert_semantics_test.lua | fast | 6 | 0 | 118 | 115 / 177 |
| 147 | attr_growth_test.lua | fast | 3 | 0 | 113 | 110 / 204 |
| 148 | survival_screen_test.lua | fast | 6 | 0 | 143 | 114 / 200 |

## 6. 最慢用例 Top 45（runner 内部计时，精度 15.625 ms）

| # | 耗时 ms | 文件 | 用例 |
|---:|---:|---|---|
| 1 | 2703 | slow/blender_transport_test.lua | TestBlenderCli test_qa_check_on_minimal_mesh_returns_structured_result |
| 2 | 1516 | main_hud_layout_test.lua | 主界面布局模块 test_popup_rows_with_max_candidates_stay_on_screen |
| 3 | 1375 | slow/blender_transport_test.lua | TestBlenderCli test_script_failure_exit_code_is_passed_through |
| 4 | 1328 | slow/pre_commit_hook_test.lua | TestPreCommitHook test_commit_all_does_not_leak_index_to_busted |
| 5 | 1312 | slow/pre_commit_hook_test.lua | TestPreCommitHook test_signal_TERM_interrupted_lane_blocks_commit_and_cleans_workdir |
| 6 | 1281 | slow/pre_commit_hook_test.lua | TestPreCommitHook test_deleting_lua_runs_busted |
| 7 | 1281 | slow/pre_commit_hook_test.lua | TestPreCommitHook test_signal_INT_interrupted_lane_blocks_commit_and_cleans_workdir |
| 8 | 1265 | slow/blender_transport_test.lua | TestBlenderCli test_env_report_returns_blender_version_json |
| 9 | 719 | slow/pre_commit_hook_test.lua | TestPreCommitHook test_broken_worktree_with_good_stage_passes |
| 10 | 688 | slow/pre_commit_hook_test.lua | TestPreCommitHook test_lua_change_runs_fast_lane_without_git_env |
| 11 | 640 | slow/pre_commit_hook_test.lua | TestPreCommitHook test_busted_config_change_runs_busted |
| 12 | 609 | slow/pre_commit_hook_test.lua | TestPreCommitHook test_failing_fast_lane_blocks_with_output |
| 13 | 594 | slow/pre_commit_hook_test.lua | TestPreCommitHook test_staged_syntax_error_blocks_with_staged_path |
| 14 | 547 | slow/pre_commit_hook_test.lua | TestPreCommitHook test_missing_busted_blocks |
| 15 | 531 | arch_policy_test.lua | 架构分层门禁 真实业务模块全部分类且无反向依赖或循环 |
| 16 | 516 | slow/pre_commit_hook_test.lua | TestPreCommitHook test_broken_stage_with_good_worktree_blocks |
| 17 | 515 | slow/pre_commit_hook_test.lua | TestPreCommitHook test_docs_only_commit_skips_busted |
| 18 | 500 | slow/deploy_transport_test.lua | TestDeployCli test_second_deploy_is_a_no_op_success |
| 19 | 484 | arch_policy_test.lua | 架构分层门禁 扫描真实 require，忽略注释字符串和 _trigger |
| 20 | 469 | arch_policy_test.lua | 架构分层门禁 真实分层声明的模块与命名空间都在源码中 |
| 21 | 391 | compendium_test.lua | 图鉴写入（MgrCompendium × MgrSave × PlayerData） test_every_species_gets_its_own_entry |
| 22 | 266 | slow/blender_transport_test.lua | TestBlenderCli test_which_reports_one_forward_slash_path_and_version |
| 23 | 265 | slow/deploy_transport_test.lua | TestDeployCli test_backslash_workspace_is_accepted |
| 24 | 250 | slow/deploy_transport_test.lua | TestDeployCli test_deploy_mirrors_bytes_and_removes_stale_files |
| 25 | 188 | economy_persistence_test.lua | TestEconomyPersistence test_expired_and_forged_identity_cannot_buy_again |
| 26 | 172 | blindbox_settle_test.lua | 盲盒服务端结算（MgrBlindbox × MgrSave × MgrPlatform） test_terminal_retention_and_safe_expiry |
| 27 | 110 | hook_cleanup_test.lua | native hook failure cleanup after_each runs from the failed ancestor upward and config is restored |
| 28 | 110 | seam_test.lua | TestSeamWhich accepts a real interpreter found on PATH |
| 29 | 109 | save_foundation_test.lua | TestSaveFoundation test_log_is_bounded_and_cleaned_identity_cannot_replay |
| 30 | 94 | modifier_system_probe_test.lua | TestModifierProbe test_real_vendor_public_api_reruns_and_cleans_isolated_objects |
| 31 | 94 | seam_test.lua | TestSeamSpawn sets env vars and working directory for the child |
| 32 | 78 | seam_test.lua | TestSeamWhich rejects a fake shell that prints nothing, accepts one that prints a version |
| 33 | 63 | main_hud_layout_test.lua | 主界面布局模块 test_residents_avoid_engine_reserved |
| 34 | 63 | seam_test.lua | TestSeamMirror mirrors a directory tree with robocopy |
| 35 | 63 | seam_test.lua | TestSeamCapture removes its temporary output file |
| 36 | 62 | main_hud_layout_test.lua | 主界面布局模块 test_residents_pairwise_disjoint |
| 37 | 47 | seam_test.lua | TestSeamSpawn passes arguments verbatim through cmd quoting |
| 38 | 47 | slow/sync_transport_test.lua | TestSyncPackages test_packages_flag_is_a_usage_error |
| 39 | 47 | cli_entry_test.lua | TestCliEntryRepoRoot test_subcommand_loads_from_a_subdirectory |
| 40 | 47 | slow/deploy_transport_test.lua | TestDeployCli test_missing_robocopy_fails_before_mirroring |
| 41 | 47 | cli_entry_test.lua | TestCliEntryInterpreter test_non_54_interpreter_exits_1_with_hint |
| 42 | 47 | slow/sync_transport_test.lua | TestSyncCli test_extra_argument_is_a_usage_error |
| 43 | 47 | cli_entry_test.lua | TestCliEntryHelp test_unknown_subcommand_exits_2 |
| 44 | 47 | slow/deploy_transport_test.lua | TestDeployCli test_empty_workspace_never_targets_the_filesystem_root |
| 45 | 47 | cli_entry_test.lua | TestCliEntryHelp test_test_subcommand_is_routed |

## 7. 结构性问题（按代码定位，不是猜测）

### 7.1 夹具时间完全不计入用例耗时（最容易被误读的一处）

`busted/init.lua` 的 `it` executor 执行序是：

```
init.lua:35  block.execAll('before_each', parent, true)     -- 夹具跑在这里
init.lua:39  safe_publish('test', { 'test', 'start' }, ...) -- 计时从这里开始
init.lua:48  safe_publish('test', { 'test', 'end' }, ...)   -- 计时在这里结束
init.lua:51  block.dexecAll('after_each', ancestor, true)   -- 夹具跑在这里
```

**证据**：`slow/pre_commit_hook_test.lua` 文件级 15.016 s，12 个用例加起来只有 10.030 s → **4.99 s（33%）不在任何用例的耗时里**。这段就是 `before_each(function() seed() end)`（新建临时 git 仓库：`git init` + `git add -A` + `git commit` 三次子进程）与 `after_each(function() fs.rmrf(ROOT) end)`（删整棵仓库树）。

同一现象在 fast 车道整体也成立：文件级 11.282 s vs 逐用例累加 6.780 s，差 **4.50 s**（其中约 1.1 s 是全套件文件发现/加载，其余是 `before_each`/`after_each`）。

**结论**：任何"按用例耗时排序"的优化决策都会系统性漏掉最贵的一块。

### 7.2 真子进程才是大头：7 个文件 = 69.9%

| 文件 | 用例 | 文件级耗时 | 每例在干什么 |
|---|---:|---:|---|
| `slow/pre_commit_hook_test.lua` | 12 | 15.016 s | 每例 seed 一个临时 git 仓库，再在用例里多次 `git` + 一次 `git commit` 触发 hook；hook 里再起 `sh`、`lua tools/cli.lua`、桩 `busted.bat` |
| `slow/blender_transport_test.lua` | 5 | 5.625 s | 真 `blender.exe` + 真 python 跑上游脚本（单例 `test_qa_check_on_minimal_mesh_returns_structured_result` = 2.703 s） |
| `slow/deploy_transport_test.lua` | 6 | 1.172 s | 真 `robocopy /MIR` + 真 CLI 子进程 |
| `slow/sync_transport_test.lua` | 17 | 0.937 s | 真 CLI 子进程 + 临时宿主目录 |
| `fast/seam_test.lua` | 19 | 0.578 s | 每例 `seam.spawn` 起 `lua`/`robocopy`/`cmd` 子进程 |
| `fast/cli_entry_test.lua` | 9 | 0.359 s | 每例起 `lua` 子进程验证 CLI 入口行为 |
| `fast/hook_cleanup_test.lua` | 1 | 0.110 s | `io.popen` 起子进程，验证失败清理会沿祖先链执行 |

另有 `fast/blender_cli_test.lua`（30 例 / 0.093 s）：grep 会命中 `seam.spawn`，但那是**桩替换**，不起真进程，所以不进上表；`fast/platform_seam_test.lua`（19 例 / 0.062 s）同理。

Windows 上每次 `CreateProcess` + 解释器/工具初始化就是 40–120 ms 量级（实测 `lua -e "print(1)"` 36–86 ms、单文件 busted 启动 93–142 ms）。`pre_commit_hook_test` 单例平均 1.25 s，里面至少 5–8 次子进程调用，**耗时基本上就是进程数乘以启动成本**，与 Lua 断言本身无关。

### 7.3 纯 Lua 里的平方项：`main_hud_layout_test` 的 popup 用例 1.516 s

13 个用例里这一个占 90%，且**完全不碰 I/O**。`tests/native/main_hud_layout_test.lua:227-252`：

- 外层 `each_case` 是三重笛卡尔积：`HEIGHTS` × `SLOT_COUNTS` × `REELING`（`Compute` 每格都重算一次布局）；
- 内层对每个候选数 `n = 1..count` 调用 `MainHudLayout.PopupCells(layout, kind, n)`（count 取自真实配置：武器数、鱼饵数）；
- 对返回的 `cells` 再做 **两两互叠检查 O(n²)**，且每个 cell 还要与 `layout.Reserved` 的每个保留区做一次重叠检查；
- 这些都是 `assert.is_true` 逐个调用，消息用 `string.format` 现拼。

复杂度约 `O(格数 × 候选数 × n² × 保留区数)`，全部是纯 Lua 表操作与循环，没有缓存。这类耗时是真实的 CPU 成本，但也是**唯一可以只靠改测试结构就砍掉 1.4 s 的地方**（不碰业务代码）。

### 7.4 重复扫全树：`arch_policy_test` 3 个用例各 ~0.5 s

`Arch.scan(真实仓库根, Arch.policy)` 会遍历并解析 `client`/`common`/`server` 下**全部** `.lua` 的 `require`。同一个文件里三处扫描（`真实业务模块全部分类…` 0.531 s、`扫描真实 require…` 0.484 s、`真实分层声明的模块…` 0.469 s）各扫一遍，没有 `setup`/`before_all` 级缓存。这是 fast 车道第 2 贵的文件（1.500 s，13.3%）。

### 7.5 固定成本：加载 1.1 s + 每进程 ~116 ms

- **文件发现 + 加载**：0 用例的 full 空跑仍要 **1.125 s**（148 个测试文件全部被加载、注册，`auto-insulate` 给每个文件包了隔离块）。占 full 的 3.3%、fast 的 10%。
- **每进程启动**：单文件 wall 中位 116 ms 高于进程内耗时。**逐文件串行跑全量 = 53.7 s，一次跑 = 34.1 s（1.58×）**——所以"逐文件计时"这种口径不能当 CI 时长估算。

### 7.6 车道结构与直觉相反

- 6 个 slow 文件（占文件数 4%）吃掉 **66.9%** 的时间；142 个 fast 文件里最贵的 8 个占 fast 车道的 49.4%，其余 134 个加起来才 5.7 s。
- **日常 fast 11.1 s 里真正在跑业务断言的只有约 5.7 s**，剩下是 1.1 s 加载 + 4.5 s 夹具 + 进程开销。

## 8. 未能运行 / 未纳入的项目（不假装跑过）

| 项 | 为什么没跑 | 它大概要多少 |
|---|---|---|
| 编辑器内 E2E / 试玩验收 | 需要编辑器开着本图（`editor_mode: "se"`），且属"试玩"不是测试；本会话没有编辑器在线授权 | 每轮人工取证，分钟级；与测试套件无关 |
| `lua tools/cli.lua deploy` + `code validate` | 会写宿主目录（镜像三端），属改仓库外状态 | deploy 依赖 robocopy /MIR 与编辑器；仓库里有 `slow/deploy_transport_test.lua` 用假仓库证明同类路径，15.0 s 量级里含它 1.2 s |
| pre-commit hook 端到端（真 `git commit`） | 会改仓库状态（产生提交），本任务禁止 | ≈ `fast` 11.1 s + 每个暂存 `.lua` 一次 `lua` 进程（36–86 ms） |
| `uml_crap` / `uml_mutate` / `uml_dry` | `docs/agents/workflow.md` 规定由人在插件面板发起，agent 不自行运行 | CRAP = full + 覆盖率 = **65.7 s**（已实测底层命令）；mutation = 每个变异体一次 fast 车道 **11.1 s 起**，N 个变异体就是 N×11.1 s 量级；DRY 未测 |
| 美术资产校验（仓库外脚本） | 资产不在本仓，脚本在仓库外 | 未测，无法估计 |
| `tests/probes/` 55 个探针 | 不在任何车道，需编辑器/试玩环境，且多为写场景的探针 | 未测；单个探针 = 一次编辑器 exec |
| 任何 CI 流水线 | **本仓没有 CI 配置**（workflow.md 明确） | 无 |

测试本身**没有跳过项**：所有轮次都是 `0 pending`，1597 个用例全部实际执行。

## 9. 复现命令与制品

### 9.1 命令（在仓库根，Git Bash）

```bash
# 车道总耗时（外部 wall 计时）
s=$(date +%s%N); lua tools/cli.lua test fast; echo "exit=$? wall_ms=$(( ($(date +%s%N)-s)/1000000 ))"
s=$(date +%s%N); lua tools/cli.lua test full; echo "exit=$? wall_ms=$(( ($(date +%s%N)-s)/1000000 ))"

# 逐用例/逐文件（runner 内部计时）：需要 tmp/timing/timing_handler.lua
TIMING_LANE=full TIMING_RUN=r4 TIMING_OUT=tmp/timing/full_r4.json \
  busted --run=full -o timing_handler -m "tmp/timing/?.lua"

# 逐文件外部 wall（148 个独立进程，3 轮）
sh tmp/timing/perfile.sh r1

# 汇总成表（生成第 4/5/6 节与 CSV）
lua tmp/timing/gen_tables.lua tmp/timing/full_r4.json docs/test-timing

# 空跑基线（只发现+加载）
busted --run=full --filter=__no_such_case__

# 覆盖率跑（CRAP 口径，stats 落 tmp 以免动仓库）
LUACOV_STATS_FILE=tmp/timing/luacov.stats.out busted --run=full --coverage
```

`timing_handler.lua`、`perfile.sh`、`gen_tables.lua` 是本次测量的一次性脚本，放在 `tmp/timing/`（`tmp/` 已 gitignored）。它们只读 busted 的 `element.duration` 与外部 `date`，不修改被测量的代码。

### 9.2 制品

| 路径 | 内容 | 行数 |
|---|---|---:|
| `docs/test-timing/cases.csv` | 全部 1597 个用例：lane, file, case, status, ms, offset | 1598 |
| `docs/test-timing/files.csv` | 全部 148 个文件：用例数、进程内耗时、3 轮 wall（min/中位/max）、进程开销 | 149 |
| `tmp/timing/full_r4.json` | 逐用例原始记录（runner 计时） | — |
| `tmp/timing/perfile_r1..r3.csv` | 逐文件外部 wall 原始记录 | 149 × 3 |

## 10. 结论与可选优化方向（均未实施）

1. **基线数字**：fast **11.1 s**、full **34.5 s**（4 轮中位）、覆盖率跑 **65.7 s**、空加载 **1.125 s**。相对抖动：full ±3%、fast ±34%（受机器负载主导，不是冷热差）。
2. **不要按用例数估时长**：90.2% 的用例在 15.6 ms 以内，8 个用例占一半时间。
3. 若将来要压 fast 车道（按收益排序，都不动业务代码）：
   - `arch_policy_test`：把 `Arch.scan(真实仓库根)` 提到文件级 `setup` 缓存一次 → 约 **-1.0 s**（1.5 s → 0.5 s）；
   - `main_hud_layout_test` 的 popup 用例：把 `each_case` 的三重笛卡尔积按等价类抽样，或把 `PopupCells` 结果按 `(kind, n)` 缓存 → 约 **-1.4 s**；
   - 其余 134 个 fast 文件加起来只有 5.7 s，收益有限。
4. 若将来要压 slow 车道：`pre_commit_hook_test` 的种子仓库可以复制一份模板目录代替每例 `git init/add/commit` → 估计 **-3～4 s**（占它的 33%）；`blender_transport_test` 的 5.6 s 是真实外部成本，除非把 QA 检查降为桩，否则压不下来。
5. **不要为了压时间关 `.busted` 的 `auto-insulate`**：`docs/agents/workflow.md` 记录关掉后 fast 出现 7 failures / 3 errors。1.1 s 的加载成本里有它的一份。
6. **测量口径建议**：以后报"测试多慢"，一律用**外部 wall + 整套件**；报"哪个测试慢"，用**文件级**而不是用例级（夹具不在用例里）；单例级数字只用于量级判断，因为粒度是 15.625 ms。
