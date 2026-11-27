# 开发工作流

修改代码、运行测试、同步宿主或操作编辑器前，以及整理过程产物时，读取本文。

## 工程用语

- **se-fish**：本图的 Lua 源码仓库。
- **Seam / 接缝**：不修改调用处源码即可切换行为的位置。声明时必须配对指明启用点（`Enabling Point`），且至少具备两个适配器。本仓工具链唯一实例为 `tools/seam.lua`，见 [ADR-0017](../adr/0017-windows-native-only.md)。
  _Avoid_: 把零外部依赖的被测入口、防腐层（`ACL`）、`Fake`、`Spy`、夹具（`Fixture` / `Harness`）、探针（`Probe`）或迁移过渡回调统称为「接缝」。各类位置使用各自专词。
- **Business scope / 业务范围**：质量工具与架构图共用的源码集合，不含任何 `packages/` 子树；机器真源是根目录 `uml-quality.json` 与 `policy.edn`，决策见 [ADR-0021](../adr/0021-packages-outside-business-scope.md)。
  _Avoid_: 业务树、指标采集范围、mutation 范围、scope（单独使用时）
  与**玩法实现**（三端业务代码）不是一回事，两者不混用，见 [ADR-0029](../adr/0029-scope-completeness-and-placeholder-first.md) 第二节。
- **Checkout / 仓库检出**：本仓的 git 工作树（含 worktree），是唯一跑 Lua、测试与工具链的地方；仓库内路径一律相对、`/` 分隔，离开仓库写正斜杠加盘符。
  _Avoid_: 开发端、本机、repo copy
- **Host directory / 宿主目录**：编辑器 `code init` 绑定的本地 Lua 工程目录，根有 `eggy.json`，是部署目的地；与仓库检出分别管理，两者只经 `deploy` 与 `sync` 往来。路径与绑定方式见下方「工具链」。
  _Avoid_: 部署端、本机、deploy target
- **部署树**：镜像进宿主目录的仓库根 `client/`、`common/`、`server/`；仓库根其余内容不部署。宿主内不归本仓库管理的内容由 `sync` 回灌，镜像粒度与操作细节见下方「工具链」。
  _Avoid_: 源码树（指仓库全部时）
- **quality gate**：质量工具（CRAP、mutation、DRY）的结果处理规则：由 dsh-uml-viewer 插件自带的标准工具发布快照与结果记录（`validResult`、实际退出码），指标只出报告，不设门槛；范围见 **Business scope**，agent 只在收到面板请求时调用插件工具。

## 工具链

Lua 命令使用 **Lua 5.4**，命令名统一 `lua`，执行前用 `lua -v` 核对；`tools/cli.lua` 入口在非 5.4 解释器下直接退 1，不提供带版本号后缀的解释器别名。Lua 5.5 对循环变量重新赋值会报 `attempt to assign to const variable`，遇到此错误先检查版本。

- `lua tools/cli.lua deploy`：将三端一级子树字节镜像到宿主目录（经 `tools/seam.lua` 调用 `robocopy /MIR`，镜像前打印将被删掉的宿主多余文件；宿主三端根下仓库已删的散文件或子树同样先删）；robocopy 缺失时在镜像前以退出码 3 失败。编辑器开着本图时执行 validate → 有差异时 `code push` → `code diff` 复核，push 后仍不一致才返回失败。三端内本地已删的地图文件用 `code push --delete --yes` 删掉；三端外的地图独有文件（`temp/` 等编辑器生成物）只提示保留，两类同时出现时不推送（#167）。跨接缝约定见 [ADR-0017](../adr/0017-windows-native-only.md)。
- `lua tools/cli.lua sync`：将宿主目录的 API 存根、`data/` 回灌仓库；`eggy.json` 不回灌，见下方「编辑器工程 ≠ 仓库检出」；三端 `packages/` 由仓库管理，也不回灌。
- `lua tools/cli.lua naming [--recon|--apply|--check] [--layer l3a|l3b|all] [--root <目录>]`：命名改名 codemod 与旧名字符串键守卫（#337）。`--recon` 只列将要改的 `文件:行 旧名 -> 新名`，`--apply` 才落盘且要求目标 git 工作区干净（只用于父提交 worktree）；映射与 keydefs 在 `tools/naming/data/`，口径见 [ADR-0034](../adr/0034-self-written-code-snake-case.md)。`--root` 用于在父提交的干净 worktree 上重放历史层：L3a 对应 `b3a1855`（父提交 `e2a59d1`），L3b 对应 `9685b9e`（父提交 `c75e740`）。`--check` 与 `tests/native/guards/naming_string_keys_test.lua` 共用规则，发现字符串字面量里的旧方法名时报文件与行号。
- `lua tools/cli.lua docs sync`：显式同步 SE 官方手册到已忽略的 `.toolcache/se-manual/`，覆盖 `lua/00–22`、教程与 API 总索引及 API 索引所列最新 changelog；`docs sync api <类型名或官方 URL>` 按需加入一个 `game_api` 成员页。每个纯文本文件头记录官方 URL、UTC 拉取时间与正文的 SHA-256，日志另记官网文件名提供的版本；所有核心页面下载并解析成功后才写入，失败保留旧缓存。`lua tools/cli.lua docs search <查询>` 只检索本地缓存、无需网络或编辑器，命中给出本地文件行号与官方来源 URL；缓存为空时先跑 `docs sync`，精确成员详情仍可走 `editor-cli api get` / 官方单页兜底。同步依赖 PATH 上的 `curl`，检索不依赖它。
- `lua tools/cli.lua blender <脚本.py> [--blend <输入.blend>] [-- <脚本参数>...]`：在本机无头 Blender 里执行脚本，是唯一的 Blender 入口；`--which` 核对将用的 Blender，`--expr` 执行内联代码。路径写正斜杠 Windows 形式（`C:/...`）或仓库内相对路径；用法见 [Blender 与 Meshy 使用](art-pipeline.md)，决策见 [ADR-0009](../adr/0009-blender-headless-only.md)。
- `lua tools/cli.lua screenshot [--window <标题子串>] [--screen] [--out <文件.png>]`：取证画面的统一入口，缺省后台抓屏（`PrintWindow`），输出落 `tmp/`。选窗、虚拟屏与判帧新旧的实测坑见 [editor-cli.md「截图」](editor-cli.md)，取证前先跑 `--info`。
- `lua tools/cli.lua acceptance [--check|--write|--update-baseline|--infer]`：验收矩阵的统一校验入口（#326），矩阵入口见 [条款矩阵](../acceptance/README.md)（接手先读 [交接说明](../acceptance/handover.md)），判定逻辑在 `tools/acceptance.lua`，用法与退出码看 `--help`。状态从证据文件反推，`--infer` 单独列出；同一判定随 fast 车道跑（`tests/native/guards/acceptance_matrix_test.lua`）。
- `lua tools/cli.lua emmylua [--update-baseline]`：EmmyLua 诊断门禁（[ADR-0038](../adr/0038-emmylua-agentic-coding-quality-gate.md)），固定 `emmylua_check 0.25.1`，扫描三端自写代码、排除 `tests/` 与 `packages/`；只拦 `tools/emmylua_baseline.txt` 基线外的新诊断。pre-commit 在 `test guards` 之后运行它，CI 随 `full` job 作为 required 门禁运行。
  **Ratchet / 棘轮**：验收基线的单向闸门，已取证数只升。_Avoid_: 阈值、配额、budget、上限
- `lua tools/cli.lua size [--update-baseline|--report]`：单文件 token 预算门禁（[ADR-0041](../adr/0041-token-budget-gate.md)），口径 `se-fish-budget-v1`（纯 Lua 近似分词器，与 cl100k_base 中位偏差 +2%）；扫描范围同 emmylua 门禁，单文件超过 5500 tokens 且不在 `tools/size_baseline.txt` 里即失败。`--report` 只列超限清单，`--update-baseline` 只在没有新超限时收窄基线（棘轮只许减少）。pre-commit 在 `test guards` 之后、`emmylua` 之前运行它。
- 官方包升级、直接调用接口与编辑器预设依赖见 [官方包接入参考](../packages-reference.md)。技能包预设命令见 `lua tools/cli.lua ability-presets --help`。
- **临时产物**：agent 手工产物（验证中间文件、单据正文草稿）放仓库 `tmp/`，任务结束时删掉本任务产生的文件。脚本自建自删的目录由脚本收尾。
- **Test lane / 测试车道**五条：单测放 `tests/native/`，slow 放 `tests/native/slow/`，**条款断言**放 `tests/native/spec/`，**门禁型**放 `tests/native/guards/`，美术放 `tests/native/art/`（**美术 optional**，Blender 用例不进 full，用 `lua tools/cli.lua test art` 单独跑）；共享夹具放 `tests/support/`，探针放 `tests/probes/`（手工探针，不入任何车道）。日常运行 `lua tools/cli.lua test`（缺省 fast），收尾运行 `lua tools/cli.lua test full`（= fast + slow + spec），单独跑条款或门禁用 `lua tools/cli.lua test spec` / `lua tools/cli.lua test guards`；`--` 之后的参数原样透传给 busted。车道真源是根目录 `.busted`，共享初始化在 `tests/native/helper.lua`。
  _Avoid_: 验收车道、代码收尾门、lane（单独使用时）、test suite、test group
  - `busted` 命令：`test` 子命令与人手 shell 统一用 PATH 上的 `busted`（不在 PATH 时 CLI 退出码 3）。它由 LuaRocks 装在 `%APPDATA%\luarocks\bin`，该目录必须在 PATH 里；安装命令 `luarocks --local install busted` 在 Git Bash 里执行。
  - `--jobs N`：把车道按文件分给 N 个 busted 进程并跑（1..8，缺省 1 即串行）。文件表从 `.busted` 现读、按文件字节数装箱；写固定路径的车道段（slow、art）始终串行，段序与 `.busted` 的 ROOT 顺序相同；每片内部按文件名字典序跑，跨片并发，所以用例的整体交错顺序与串行不同（文件级隔离靠 `.busted` 的 auto-insulate，不靠顺序）。12 逻辑核实测 fast 约 15 秒 → 4.3 秒、full 约 27 秒 → 10 秒、guards 5.3 秒 → 1.9 秒；8 路之后收益饱和（每路都要重新读盘）。并行时 `--` 之后只收 busted 选项：再给 ROOT 参数与分片冲突，按用法错误退 2。

### 试玩存档隔离

- **Production save / 正式存档**：QA 不得写入。
  _Avoid_: 主存档、线上档、main save
- **QA save slot / QA 存档槽**：试玩验收必须使用。会话开始在试玩前执行 `lua tools/cli.lua qa-slot new`，再执行 `lua tools/cli.lua deploy`；会话内槽位固定，同槽重进不要重新 `new`。
  _Avoid_: 验收存档槽、acceptance-slot、沙盒存档、sandbox save、test save
- `lua tools/cli.lua qa-slot off` 只切回正式存档配置，不删除任何存档。
- **Save key / 存档 key**：拼接以 `server/save_host.lua` 为实现真源。
  _Avoid_: 存档 ID、档位号、save id

**架构图（dsh-uml-viewer）。** 看图与图上操作用 DSH 的 dsh-uml-viewer 插件面板；根目录 `policy.edn` 是架构图的机器真源，生成图在 `docs/uml/se-fish.edn`（不要手编）。六层职责与依赖方向见 [架构分层与依赖门禁](../architecture.md)，层归属唯一声明在 `tools/arch_policy.lua`。修改三端代码或 `policy.edn` 后用插件工具 `uml_ir` 重新生成图；面板请求的处理顺序与 `validResult` 校验以插件注入规则为准。

- `target/` 放覆盖率与 mutation worker，属于忽略的临时产物；`.metrics/` 保留质量快照并纳入版本管理。viewer 从 `.metrics/crap.edn`、`.metrics/mutate/*.edn` 加载指标，缺少任一指标的类卡片为红色。无函数定义的配置或转发模块不生成 mutation 快照；当前工具不测试模块顶层语句。
- **Windows 原生**：full／fast、coverage 与 CRAP 的标准环境是 Windows。PR 与 `main` 的 full 由 GitHub Actions `windows-latest` 执行；coverage 与 CRAP 的实机数据仍来自本机仓库检出。**macOS 未实机验证，没有实机数据**。

**worktree 起手式。** 新建 worktree 后在其根执行一次：

```bash
lua tools/cli.lua worktree-init
```

- 从 magpie 资源库复制上游 `blender-*` skill 到 `.agents/skills/`（来源见[Blender 与 Meshy 使用](art-pipeline.md#上游-blender--skill)）；已存在的条目跳过（可重复执行），来源缺失时在写入前失败。参数见 `--help`。
- 某个 skill 损坏时，删掉对应目录后重跑 `worktree-init`，由它重建。

**美术资产（Meshy MCP + 无头 Blender）。** Blender 与 Meshy 的接入与用法见 [Blender 与 Meshy 使用](art-pipeline.md)，尺寸口径见 [ADR-0004](../adr/0004-fish-asset-scale.md)。唯一的 MCP 是 Meshy，注册与密钥接法见 [Blender 与 Meshy 使用](art-pipeline.md#前端配置)。Blender 不接 MCP，只经 `blender` 子命令无头执行（[ADR-0009](../adr/0009-blender-headless-only.md)）。资产本体不进本仓，正式资产走编辑器导入。

**宿主目录专用于镜像。** 默认由 `USERPROFILE` 推导：`C:/Users/<用户名>/Desktop/dev/eggy/LuaSource_钓鱼怎么这么危险啊喂！`。可用 `EGGY_WORKSPACE` 覆盖，值写正斜杠 Windows 路径（如 `C:/Users/<用户名>/Desktop/dev/eggy/LuaSource_钓鱼怎么这么危险啊喂！`）；空串当作未设置。

**编辑器工程 ≠ 仓库检出。** `code init` 绑定只在宿主目录那份 `eggy.json`（`projectID`、`mapDir` 等本机信息）。仓库那份只留 `{"isSEMap": true}`，SessionStart hook 从 cwd 向上找它且只认这个键；其他键由 `tests/native/guards/eggy_json_guard_test.lua` 随 fast 车道拦住（#166）。手动执行 code-* 时用 `--workspace` 指向宿主目录，值写正斜杠 Windows 路径；在仓库里不带 `--workspace` 会报 `CODE_BINDING_INVALID`，`deploy` 已带此参数。手工复核直接看 `lua tools/cli.lua deploy` 的收尾输出。

**编辑器 CLI 取证。** 目标命令的 `--help`、试玩与截图、保存与重开、风险步闸门（推送、场景写入；部署、试玩、地图保存与重开免授权）等项目实测都记在 [editor-cli.md](editor-cli.md)。操作前先读它。

## 测试纪律

- **试玩优先**：新增验证尽量只用编辑器 E2E，复杂功能以试玩证明可用；操作见 skill `eggy-se-qa`。
- **先列失败方式**：确需单独测试某个系统时，先列出所有可能失败的方式，再写代码；代码写完后不补写单测。
- **局部开发、全量收尾**：开发期间用 `lua tools/cli.lua test` 验证；业务功能仍按需试玩，收尾执行下面的全部检查。
- **可复现取证**：每次试玩保留可重跑的触发步骤（`input` 命令、探针文件）与对应证据（`log grep` 命中行、截图路径）。
- **只写有失败方式的用例**：用例分五类——①行为（分支、边界、失败路径）、②跨真源守卫（`data/` ↔ `GameCfg` ↔ 代码里的 id 引用、表间绑定）、③复述（断言等价于把实现或配置再写一遍）、④重复覆盖（同一行为在多个文件各测一遍）、⑤基架自测（只保护 `tests/support/` 夹具或 `tools/` 工具本身）。只写 ①②；③④⑤不写，遇到就删，删时记一行「原来拦住哪种失败 / 删掉后由谁接手」。门禁型（`arch_policy_test`、`eggy_json_guard_test` 这类挡仓库不变量的）不在此列：一律放 `tests/native/guards/`，走 guards 车道、不计入验收基线的遗留测试数。共享夹具若复刻反直觉的宿主行为，可设独立契约门禁，但必须同时有业务用例消费；否则仍按⑤删除。
- **按文件算耗时，不按用例算**：九成用例短于 busted 的一个计时 tick（15.6 ms），删单条用例几乎不减墙钟——减时间靠删或合并**文件**、降低用例里的循环规模。参数矩阵用两两覆盖（每对因子取值至少配过一次）而不是全组合。断言消息只在失败分支里拼（`if not cond then fail(fmt, ...) end`），写在断言参数里等于每个通过的断言都付一次 `string.format` 的钱（`main_hud_layout_test` 实测 2825 ms → 176 ms）。

## 按改动选测试

不跑 full 时，用下面的判定式说明「为什么够用」；从上往下读，先命中先执行，判不清就落 full。逐车道/逐文件的原始数据、闭包与 fast+guards 原型见 [#395](https://github.com/qinyuanj/se-fish/issues/395)。

- **判定式 1（纯文档）**：改了什么——只改 `docs/**/*.md`（`docs/agents/art-pipeline.md` 除外）或根 `README.md` / `AGENTS.md` / `GLOSSARY.md` / `CODING_STANDARDS.md`。必须跑——`test guards`。可以跳过——fast、slow、spec、art。跳过的已知代价——链接、锚点、归属与验收矩阵仍由 guards 覆盖，但代码行为零验证。谁补证——PR 作者贴 CI `full` check 的 guards 结果并确认 diff 无代码，reviewer 复核；CI 对纯文档 PR 走同一快速路径。
- **判定式 2（只改测试）**：改了什么——只在 `tests/`。必须跑——该文件所属车道（slow 不在 `lua tools/cli.lua test` 的车道表里，用 `busted tests/native/slow` 单跑）；改 `tests/support/` 时，把消费该夹具的车道一起跑。可以跳过——其余车道。跳过的已知代价——若夹具还有别的消费方而没跑那条车道，失败只会在 CI 暴露。谁补证——作者列出夹具消费方与所跑车道；CI `full` 兜底。
- **判定式 3（三端代码，车道归属清晰，用于本地迭代）**：改了什么——`client/`、`common/`、`server/` 中的文件，且改动文件都出现在 fast 用例的覆盖集里（用一次 `busted --coverage` 或 #395 的覆盖清单判定），没有触及判定式 4 的路径。必须跑——`test fast`（guards 已含在 fast 内）。可以跳过——spec、slow。跳过的已知代价——spec 的跨端契约与 slow 的 `tools/` transport 不验；按 #395 的对拍，fast+guards 只覆盖 57.1% 的受影响用例（漏 42.9%，主要是 spec）。谁补证——本地迭代由作者记录；开 PR 前按后面的门槛补 full，或由 reviewer 写明接受该风险。
- **判定式 4（跨车道依赖）**：改了什么——触及 `common/` 共享件、`server/world_host/`、`tools/`、`policy.edn`、`.busted`、`tests/support/`，或同时改两端以上。必须跑——`test full`。可以跳过——无。跳过的已知代价——无。谁补证——CI `full`。
- **判定式 5（判不清）**：改了什么——闭包与覆盖结论冲突、选择集为空或比 full 还慢、新目录尚未登记。必须跑——`test full`。可以跳过——无。跳过的已知代价——无。谁补证——CI `full`。

**为什么不是一张车道表。** 实测 192 个测试文件、1653 个用例：fast 1090 / guards 114 / slow 28 / spec 421；逐文件串行墙钟 fast 20.9 s、guards 7.6 s、slow 3.4 s、spec 15.9 s，8 路并行 full 13.56 s、fast 6.38 s、guards 3.50 s。闭包原型对最近 30 个三端提交的 26 个非聚合提交对拍：召回 85.2%、精确 90.4%；但选出的 113 个用例实测 13.57 s，和 full 13.56 s 打平；fast+guards 的召回只有 57.1%。所以「选得准」不等于「省时间」——省时间只在纯文档（3.5 s vs 13.5 s）和本地迭代（fast 6.4 s vs full 13.5 s）成立。

**判定式只决定跑什么，不自动授权跳过 full 开 PR。** 门槛由人定（见 #395 的待决项）：在门槛确定前，只有判定式 1 允许不带 full 开 PR；判定式 2/3 跳过 full 需要作者在 PR 描述里写明代价并取得 reviewer 同意。

### full 通过不能证明什么

- **不证明实机可玩。** #392 的 full 是 `1611 successes / 0 failures / 0 errors`，之后仍靠试玩修掉 `ground_loot` 的宿主对象判断、`fish_carrier` 注入与 UI 颜色/进度条问题；四渔区验收至今未签收。
- **不证明覆盖率或断言质量。** `.metrics/mutate` 的 99 份快照里只有 43 份能对上当前路径，56 份是改名/重构前的死路径；覆盖率只证明执行过，不证明断言能抓住变异。
- **不证明工具链 transport。** slow 的 4 个文件覆盖 `tools/deploy.lua`、`tools/sync_plan.lua`、`tools/qa_slot.lua` 的真实子进程路径，fast 没有对应用例；但 `lua tools/cli.lua test slow` 会以「未知车道」退出 2，slow 只能由 full 带上（或直接 `busted tests/native/slow`）。它的去留是待决项，不是既成事实。
- **不证明美术资产。** art 车道不进 full；当前 worktree 缺 `.agents/skills/blender-core` 时 art 的 3 条用例直接失败，CI 也没有 Blender。
- **不证明 PR 的验收条款。** 条款矩阵与验收证据是另一套真源，full 绿不等于 `docs/acceptance/` 的条款已取证。

### 待决（由人定，不在本文替选）

- 允许在什么风险下跳过 full 直接开 PR。证据见 #395：除纯文档外，自动选择没有省时间且漏约 15%。
- slow 车道的去留：修成可单跑 / 并进 guards / 删除。观测：4 文件 28 用例 3.39 s 串行，是 `tools/deploy.lua`、`tools/sync_plan.lua`、`tools/qa_slot.lua` transport 的唯一覆盖；`lua tools/cli.lua test slow` 退出 2 是 CLI 没有 slow 车道，不是用例失败；历史提交里 4 个文件都随引入当次的修复/迁移落地，没找到它事后抓过回归的证据。
- art 车道是否进收尾：1 文件 5 用例 1.93 s，当前缺 `.agents/skills/blender-core` 时 3 条失败，CI 无 Blender。

## 完成判据

代码改动按顺序执行，全部通过才算完成。新 checkout 执行 `lua tools/cli.lua worktree-init` 会安装本地 `pre-commit`，已有 checkout 可单独执行 `lua tools/cli.lua git-hook-init`（带自家签名头的旧版 hook 会自动升级）；提交前自动依次运行 `lua tools/cli.lua test guards`、`lua tools/cli.lua size` 与 `lua tools/cli.lua emmylua`，重复安装幂等，已有其他 hook 不覆盖。PR 与 `main` 推送由 [test.yml](../../.github/workflows/test.yml) 的单一 `full` job 执行，check-run context `full`（PR 界面显示 `test / full`）是 `main` 的唯一 required status check：代码 PR 与 `push(main)` 依次运行 `lua tools/cli.lua test full --jobs <2× 核数，下限 4、上限 8>`（GitHub 托管 runner 是 4 逻辑核 → 8 片，实测 24.0 秒 → 12.3 秒）与 `lua tools/cli.lua size`、`lua tools/cli.lua emmylua`；仅修改白名单纯文档（`docs/**/*.md` 排除 `docs/agents/art-pipeline.md`，及根 `README.md` / `AGENTS.md` / `GLOSSARY.md` / `CODING_STANDARDS.md`）的 PR 在同一 `full` job 内走快速路径，只跑 `lua tools/cli.lua test guards --jobs <同上>`，任何非白名单变更或变更检测异常一律兜底全量。Lua 5.4.6 / LuaRocks 3.12.2 / Busted 2.3.0-1 直接从本仓 Release `ci-toolchain-v1` 下载预构建包并校验 SHA-256（需升级版本时由 [build-ci-toolchain.yml](../../.github/workflows/build-ci-toolchain.yml) 手动重打并回填摘要），`.emmylua` 按版本哈希经 `actions/cache@v6` 缓存；PR 同分支连续推送开启并发取消，`push(main)` 按 `run_id` 独立分组不取消。下表其余每一项仍由 agent 显式执行，质量工具由人运行，见表后的「人工验收」。

| 检查 | 通过条件 |
|---|---|
| `lua tools/cli.lua test full`（收尾） | 含 slow 车道，全部用例通过，末行匹配 `N successes / 0 failures / 0 errors / 0 pending : T seconds`，退出码 0。`--jobs N` 并行时这一行由工具把各分片聚合后最后打印，T 是两位小数的墙钟（串行时是 busted 自己那行） |
| `lua tools/cli.lua emmylua`（本地门禁） | `emmylua_check 0.25.1` 跑完且没有基线外诊断，退出码 0；CI 随 `full` 强制执行 |
| `lua tools/cli.lua size`（本地门禁） | 没有基线外超限文件，退出码 0；CI 随 `full` 强制执行 |
| 美术资产交付（美术校验） | 仓库外的资产校验脚本跑完并产出 `validation/validation.json`，报告里 `failures` 为空（含网格封闭性硬门槛）；只看这份报告，不另开 CI，资产校验不进测试车道。预算文件、`mesh` 段或 `validation.json` 缺失同样算失败，口径见 [美术资产概要「验收」](../art-asset-overview.md#验收) |
| `lua tools/cli.lua deploy` 后复核 `code validate` | `ok=true`、`data.valid=true`、`data.is_se_map=true`，`data.issues` 与 `meta.warnings` 均为空 |
| validate 通过后全套试玩 | 每条验收现象都有取证产物；`log trace` 本轮窗口有效且无错误 |
| 本轮改动提交到分支后、合入 main 前，对 `<基线>...HEAD` 跑 `/code-review`（改动尚未提交时用 `git diff <基线>` 的范围） | 取得 Standards / Spec 两轴结论；硬性违规已修复，或在交付说明里逐条写明 |

**美术诊断任务**：任务单明确允许以失败或阻塞报告交付时，完成诊断须逐项记录实际校验结果、缺失或未完成的检查、停止位置、产物绝对路径和重跑命令，并在任务单保留证据索引。交付说明开头分别说明离线校验是否通过、是否已向 eggitor 发布、是否完成游戏内验收；未执行的阶段写“未执行”。诊断任务结案不改变上表的资产交付门槛，后续发布仍须取得当前输入的合格报告。

**人工验收**：质量工具由人在 dsh-uml-viewer 插件面板上发起，标准工具环境（含 crapper 要求的 cluacov 1.0.0）由人按插件文档准备。agent 在交付说明里把 `uml_crap`、`uml_mutate`、`uml_dry` 列为待人工在面板发起的项；是否通过以插件发布的结果记录和 `.metrics/` 快照为准。

## 提 PR 与叠栈合并

- **先合底层，再改基合上层**：B 栈在 A 上时，合 A 后把 B 的 base 改成 `main` 再合。
- **合底层不要删基分支**：GitHub 在基分支被删时会直接关闭下游 PR，且重建同名基分支也无法重开（#326 实测），只能从同一 head 分支新开一个 PR 承接。确认上层已改基或已合入后再删。
- **合并前确认 `mergeStateStatus` 为 `CLEAN`**：`full` 是 `main` 唯一的 required status check，pending 与 blocked 都不算通过。

## 产物归属

执行过程产物（调研全文、验证台账、验收记录、开发计划）贴进对应 issue 的评论；`docs/` 只留长期参考（术语、技术难点、ADR、跨轮复用的技术选型调查）。放进 `docs/research/` 的文档必须从 `AGENTS.md`、`docs/agents/` 或 ADR 留一条指针——没人指向的调研等于不存在，`doc_link_guard_test` 会拦下零引用的 research 文档。`eggy-dev-plan` 默认的 `docs/plan/` 输出在本仓库改为 issue 评论。

**交接摘要**：写交接或续接摘要时附授权台账，逐条列「用户授权原文 → 覆盖的动作 → 已用完 / 未用」；台账里写不出原文的动作视为未授权，续接方须重新取得确认。部署、试玩、地图保存与重开不需要授权（见 [editor-cli.md](editor-cli.md)），不必入台账。
