# 开发工作流

修改代码、运行测试、同步宿主或操作编辑器前，以及整理过程产物时，读取本文。

## 工程用语

- **se-fish**：本图的 Lua 源码仓库。
- **业务范围**：质量工具与架构图共用的源码集合，定义见 `GLOSSARY.md`，决策见 [ADR-0010](../adr/0010-packages-as-business-code.md)。
- **仓库检出**：本仓的 git 工作树（含 worktree），是唯一跑 Lua、测试与工具链的地方；仓库内路径一律相对、`/` 分隔，离开仓库写正斜杠加盘符。定义见 `GLOSSARY.md`。
  _Avoid_: 开发端、本机
- **宿主目录**：编辑器 `code init` 绑定的本地 Lua 工程目录，根有 `eggy.json`，是部署目的地；与仓库检出分别管理，两者只经 `deploy` 与 `sync` 往来。路径与绑定方式见下方「工具链」。
  _Avoid_: 部署端、本机
- **部署树**：镜像进宿主目录的仓库根 `client/`、`common/`、`server/`；仓库根其余内容不部署。宿主内不归本仓库管理的内容由 `sync` 回灌，镜像粒度与操作细节见下方「工具链」。
  _Avoid_: 源码树（指仓库全部时）
- **quality gate**：质量工具（CRAP、mutation、DRY）的结果处理规则：由 dsh-uml-viewer 插件自带的标准工具发布快照与结果记录（`validResult`、实际退出码），指标只出报告，不设门槛。
- **Busted migration**：全部 Lua 测试改写为原生 Busted、移除 LuaUnit 依赖及桥接层的迁移，决策见 [ADR-0002](../adr/0002-native-busted-migration.md)，当前车道与运行约定见下方「工具链」。

## 工具链

Lua 命令使用 **Lua 5.4**，命令名统一 `lua`，执行前用 `lua -v` 核对；`tools/cli.lua` 入口在非 5.4 解释器下直接退 1，不提供带版本号后缀的解释器别名。Lua 5.5 对循环变量重新赋值会报 `attempt to assign to const variable`，遇到此错误先检查版本。

- `lua tools/cli.lua deploy`：将三端一级子树字节镜像到宿主目录（经 `tools/seam.lua` 调用 `robocopy /MIR`，镜像前打印将被删掉的宿主多余文件；宿主三端根下仓库已删的散文件或子树同样先删）；robocopy 缺失时在镜像前以退出码 3 失败。编辑器开着本图时执行 validate → 有差异时 `code push` → `code diff` 复核，push 后仍不一致才返回失败。三端内本地已删的地图文件用 `code push --delete --yes` 删掉；三端外的地图独有文件（`temp/` 等编辑器生成物）只提示保留，两类同时出现时不推送（#167）。跨接缝约定见 [ADR-0017](../adr/0017-windows-native-only.md)。
- `lua tools/cli.lua sync`：将宿主目录的 API 存根、`data/` 回灌仓库；`eggy.json` 不回灌，见下方「编辑器工程 ≠ 仓库检出」；三端 `packages/` 由仓库管理，也不回灌。
- `lua tools/cli.lua blender <脚本.py> [--blend <输入.blend>] [-- <脚本参数>...]`：在本机无头 Blender 里执行脚本，是唯一的 Blender 入口；`--which` 核对将用的 Blender，`--expr` 执行内联代码。路径写正斜杠 Windows 形式（`C:/...`）或仓库内相对路径；用法见 [Blender 与 Meshy 使用](art-pipeline.md)，决策见 [ADR-0009](../adr/0009-blender-headless-only.md)。
- `lua tools/cli.lua screenshot [--window <标题子串>] [--screen] [--out <文件.png>]`：取证画面的统一入口，替代 editor-cli 的 `screenshot`。缺省走**后台抓屏**——`PrintWindow` + `PW_RENDERFULLCONTENT` 直接读窗口表面，目标窗口被遮挡、不在前台也不影响取帧；`--screen` 或 `--rect X,Y,W,H` 才走桌面合成（`CopyFromScreen`），那时窗口必须在最前面，被盖住抓到的是遮挡物。缺省取景是编辑器主窗口（`client.exe` 进程里面积最大的窗口），试玩时游戏视口就在它里面；`--window <子串>` 按标题挑，取面积最大的一条。选窗一律排除 `WS_EX_LAYERED` 的辅助表面——Qt 的 `Qt5QWindowToolSaveBits` 这类窗口标题也叫 `client`，却什么都不画（#185）。输出落 `tmp/`。加 `--info` 不抓图，只报屏幕列表、选中的目标窗口（标题、进程、尺寸）、所在显示器与「虚拟屏 / 非虚拟屏 / 不确定」判定，判据是该屏适配器是否挂在 PCI 总线上（`PCI\` 开头为真实显卡）。**判帧新旧只能连拍比 md5**：先确认两帧尺寸一致，再比 md5，尺寸变了的那组作废重采；单帧有效证明不了帧是新的。
- 官方包升级、直接调用接口与编辑器预设依赖见 [官方包接入参考](../packages-reference.md)。技能包预设命令见 `lua tools/cli.lua ability-presets --help`。
- **临时产物**：手工验证的中间文件、单据正文草稿等临时产物一律放仓库 `tmp/`（已 gitignored），无需清理；不放系统临时目录，也不为清理去 `rm`（沙盒会拒绝）。这条管 agent 手工产生的文件；脚本自建自删的临时目录不在此列。
- 质量工具（CRAP / mutation / DRY）是 dsh-uml-viewer 插件自带的标准工具（crapper / mutator / dryer），经插件面板触发，由 agent 调用插件工具 `uml_crap`、`uml_mutate`、`uml_dry` 执行；业务范围与选项只在根目录 `uml-quality.json` 的 `standardTools` 声明，见下方「架构图」。只出报告，不设指标门槛。
- 单测放 `tests/native/`（slow 车道放 `tests/native/slow/`，美术车道放 `tests/native/art/`：**美术 optional**，Blender 用例不进 full，用 `lua tools/cli.lua test art` 单独跑），共享夹具放 `tests/support/`，探针放 `tests/probes/`（手工探针，不入任何车道）。日常运行 `lua tools/cli.lua test`（缺省 fast），收尾运行 `lua tools/cli.lua test full`，`--` 之后的参数原样透传给 busted，退出码不透传：测试通过 0，busted 非 0（失败数加错误数）一律收成 1，busted 缺失 3；裸 `busted` 读 `default`，与 full 相同（crapper 列测试文件时不带 `--run`，覆盖率因此含 slow 车道）。车道由根目录 `.busted` 定义，共享初始化在 `tests/native/helper.lua`。Windows 原生是唯一测试环境，案例不分平台，完成判据表里的 `0 pending` 就是在这台机器上取的严格值。
  - **执行序只保证到文件内**：迁移保留的是**文件内**执行序（`it` 注册序 == 旧 LuaUnit 类内方法序），**不保留跨文件的全局类名字典序**。LuaUnit 的 `collectTests()` 排的是全局 `_G.Test*` **类名**，`.busted` 的 `sort-files=true` 排的是**文件路径字符串**，是两个键空间，技术上无法廉价复现；且 helper 在文件发现**之前**执行，插不进重排钩子。
    - 为什么可以接受：跨类没有共享状态；跨文件隔离由 `.busted` 显式开启的 `auto-insulate` 承担（每个文件结束后按键还原 `_G` 与 `package.loaded`，关掉后 fast 出现 7 failures / 3 errors），`tests/native/helper.lua` 只逐例快照 `GameCfg.Debug` 与 `Save.QaSlot`；**且不复刻旧序反而修了一个真 bug**——旧序下 `damage_float_test.lua` 与 `vitals_test.lua` 都定义全局 `TestDamageNotice`，后加载整表覆盖前者，导致 `test_rounding_and_effective_health` **从未被执行**，迁移后复活（+1，属修复而非回归）。
    - 裁定原文见迁移台账 `issue-84-mapping.md:96` 与 `issue-85-mapping.md:63`（台账在仓库外，按文件名检索）。
  - `busted` 命令：`test` 子命令与人手 shell 统一用 PATH 上的 `busted`（不在 PATH 时 CLI 退出码 3）。它由 LuaRocks 装在 `%APPDATA%\luarocks\bin`，该目录必须在 PATH 里；安装命令 `luarocks --local install busted` 在 Git Bash 里执行。

**架构图（dsh-uml-viewer）。** 根目录 `policy.edn` 描述三端模块树、排除目录与隐藏模块（`:exclude`、`:omit`），`docs/uml/se-fish.edn` 是生成的依赖图（不要手编）。 六层职责与依赖方向见 [架构分层与依赖门禁](../architecture.md)，唯一分层声明在 `tools/arch_policy.lua`；`tests/native/arch_policy_test.lua` 随 fast/full 阻止未分类、反向依赖、业务环、`:levels` 漂移及声明残留（源码已删、声明仍在）。

- 看图与图上操作用 DSH 的 dsh-uml-viewer 插件面板，插件自带二进制与质量工具，无需在项目里安装；面板请求的处理规则（质量 → `uml_ir` → `uml_display` 的顺序、`validResult` 校验等）由插件在打开面板的会话里注入，以注入规则为准；决策见 [ADR-0016](../adr/0016-dsh-uml-viewer-plugin.md)。修改三端代码或 `policy.edn` 后用插件工具 `uml_ir` 重新生成图。
- 图上 `client|common|server` 三棵树覆盖整个**业务范围**：各端 `packages/` 按真实命名空间建类，不设外部节点（`policy.edn` 不写 `:foreign`，`:exclude` 只排除 `_trigger`）。viewer 从 `.metrics/crap.edn` 与 `.metrics/mutate/*.edn` 加载指标；缺少任一指标的类卡片为红色。包内类不跑 mutation 基线，因缺快照显红并拉低端级聚合分数，属已接受的代价，理由见 [ADR-0010](../adr/0010-packages-as-business-code.md)。标准工具的环境准备（含 crapper 要求的 cluacov 1.0.0）按 dsh-uml-viewer 插件文档由人完成。
- **标准 quality 分发**：根目录 `uml-quality.json`（版本管理）只含 `standardTools`：`sourceRoots` 为三端 `client`、`common`、`server`，`exclude` 为 `server/_trigger`，`mutatorOptions` 为 `--busted-task fast`（每个变异体只跑 fast 车道）。插件的 `uml_crap`、`uml_mutate`、`uml_dry` 读这里的范围；业务范围只在这里声明一次，CRAP、mutation、DRY 与架构图口径一致。CLI 不包装质量工具。
- `target/` 放覆盖率与 mutation worker，属于忽略的临时产物；`.metrics/` 保留质量快照并纳入版本管理。无函数定义的配置或转发模块不生成 mutation 快照；当前工具不测试模块顶层语句。
- **实机验收在 Windows 原生**：full／fast、coverage 与 CRAP 的实机数据都来自这台 Windows 机器上的仓库检出。**macOS 未实机验证，没有实机数据**。本仓没有任何 CI 配置（历史上也从未有），不新增 CI：全部检查都在本机跑。

**worktree 起手式。** 新建 worktree 后在其根执行一次：

```bash
lua tools/cli.lua worktree-init
```

- 从 magpie 资源库复制上游 `blender-*` skill 到 `.agents/skills/`（来源见[Blender 与 Meshy 使用](art-pipeline.md#上游-blender--skill)）；已存在的条目跳过（可重复执行），来源缺失时在写入前失败。参数见 `--help`。
- 不为质量工具做任何准备：质量工具由 dsh-uml-viewer 插件自带，worktree 里无需安装。
- 某个 skill 损坏时，删掉对应目录后重跑 `worktree-init`，由它重建。

**美术资产（Meshy MCP + 无头 Blender）。** Blender 与 Meshy 的接入与用法见 [Blender 与 Meshy 使用](art-pipeline.md)，尺寸口径见 [ADR-0004](../adr/0004-fish-asset-scale.md)。唯一的 MCP 是 Meshy，注册与密钥接法见 [Blender 与 Meshy 使用](art-pipeline.md#前端配置)。Blender 不接 MCP，只经 `blender` 子命令无头执行（[ADR-0009](../adr/0009-blender-headless-only.md)）。资产本体不进本仓，正式资产走编辑器导入。

**蛋仔技能与注入（teamai 接入）。** 蛋仔 SE 技能和 SessionStart 注入由团队仓 `eggy/teamai-netease` 分发（[ADR-0015](../adr/0015-eggitor-ai-resources-team-repo-maintained.md)），接入前提、验收与排错以团队仓 `INSTALL-AGENT.md` 为准。本仓检出：

- 本目录接团队项目 `eggy-se`，teamai 只接 Codex：`teamai projects set eggy-se` 后 `teamai pull --force`（新检出用 `teamai init <团队仓> --scope workspace --agent codex --project eggy-se`）。技能装进 `.codex/skills/`，注入 hook 写进 `.codex/hooks.json`。
- hook 直接调 `node`，用的是 Codex 进程的 PATH：启动 Codex 的终端里 `node` 必须在 PATH 上。
- `%USERPROFILE%\.codex\config.toml` 的 `[[skills.config]]` 屏蔽 `.codex/skills/eggy-se-*/references/features/` 下的 9 个子技能，它们由父技能按需引用；团队仓增删子技能后同步这份清单。
- 自检：新开会话的上下文里「蛋仔编辑器（世界版 SE」只出现一次，且没有「项目接错了」。

**teamai 的 Gitea 凭据。** `GITEA_URL`、`GITEA_TOKEN` 存在 Windows 用户环境变量里，Windows 原生进程直接可见，不需要任何透传或转换，凭据只存一份。改完变量后重开终端（含常驻会话）才生效；`teamai doctor` 的两项 Gitea 检查通过即接入完成。缺凭据时 pull、recall 与 hook 照常，走 Gitea API 的操作（`members`、贡献 learning）失败。

**宿主目录专用于镜像。** 默认由 `USERPROFILE` 推导：`C:/Users/<用户名>/Desktop/dev/eggy/LuaSource_钓鱼怎么这么危险啊喂！`。可用 `EGGY_WORKSPACE` 覆盖，值写正斜杠 Windows 路径（如 `C:/Users/<用户名>/Desktop/dev/eggy/LuaSource_钓鱼怎么这么危险啊喂！`）；空串当作未设置。

**编辑器工程 ≠ 仓库检出。** `code init` 绑定只在宿主目录那份 `eggy.json`（`projectID`、`mapDir` 等本机信息）。仓库那份只留 `{"isSEMap": true}`，唯一的读者是 SessionStart hook（从 cwd 向上找 `eggy.json`，只认 `"isSEMap": true`）；`tests/native/eggy_json_guard_test.lua` 随 fast 车道拦住其他键（#166）。手动执行 code-* 时用 `--workspace` 指向宿主目录，值写正斜杠 Windows 路径（`editor-cli.exe` 只认 Windows 形式），在仓库里不带 `--workspace` 会报 `CODE_BINDING_INVALID`。`deploy` 已带此参数。`eggy.json` 的 `excludePatterns` 不被 CLI 读取（0.20.13 `code diff --help` 明示，实测在列的 `.codex/` 仍报 only-local），排除不了 `.agents/` 等目录。手工复核（把路径换成自己的宿主目录，在 Git Bash 或任意 shell 里直接粘贴）：

```bash
"C:/Users/<用户名>/.eggitor/cli/editor-cli.exe" code validate --strict --json --workspace "C:/Users/<用户名>/Desktop/dev/eggy/LuaSource_钓鱼怎么这么危险啊喂！"
```

等价地直接看 `lua tools/cli.lua deploy` 的收尾输出。

**编辑器 CLI 取证。** 目标命令的 `--help`、试玩与截图、保存与重开、风险步闸门（推送、场景写入；部署、试玩、地图保存与重开免授权）等项目实测都记在 [editor-cli.md](editor-cli.md)。操作前先读它。

## 测试纪律

- **试玩优先**：新增验证尽量只用编辑器 E2E，复杂功能以试玩证明可用；操作见 skill `eggy-se-qa`。
- **先列失败方式**：确需单独测试某个系统时，先列出所有可能失败的方式，再写代码；代码写完后不补写单测。
- **局部开发、全量收尾**：开发期间用 `lua tools/cli.lua test` 验证；业务功能仍按需试玩，收尾执行下面的全部检查。
- **可复现取证**：每次试玩保留可重跑的触发步骤（`input` 命令、探针文件）与对应证据（`log grep` 命中行、截图路径）。
- **只写有失败方式的用例**：用例分五类——①行为（分支、边界、失败路径）、②跨真源守卫（`data/` ↔ `GameCfg` ↔ 代码里的 id 引用、表间绑定）、③复述（断言等价于把实现或配置再写一遍）、④重复覆盖（同一行为在多个文件各测一遍）、⑤基架自测（只保护 `tests/support/` 夹具或 `tools/` 工具本身）。只写 ①②；③④⑤不写，遇到就删，删时记一行「原来拦住哪种失败 / 删掉后由谁接手」。门禁型（`arch_policy_test`、`eggy_json_guard_test` 这类挡仓库不变量的）不在此列。
- **按文件算耗时，不按用例算**：九成用例短于 busted 的一个计时 tick（15.6 ms），删单条用例几乎不减墙钟——减时间靠删或合并**文件**、降低用例里的循环规模。参数矩阵用两两覆盖（每对因子取值至少配过一次）而不是全组合。断言消息只在失败分支里拼（`if not cond then fail(fmt, ...) end`），写在断言参数里等于每个通过的断言都付一次 `string.format` 的钱（`main_hud_layout_test` 实测 2825 ms → 176 ms）。

## 完成判据

代码改动按顺序执行，全部通过才算完成。本仓没有提交时自动检查；PR 与 `main` 推送由 [test.yml](../../.github/workflows/test.yml) 自动运行 full，`test / full` 是 `main` 的 required status check（见 [ADR-0025](../adr/0025-windows-pr-full-test-gate.md)）。下表其余每一项仍由 agent 显式执行，质量工具由人运行，见表后的「人工验收」。

| 检查 | 通过条件 |
|---|---|
| `lua tools/cli.lua test full`（收尾） | 含 slow 车道，全部用例通过，末行匹配 `N successes / 0 failures / 0 errors / 0 pending : T seconds`，退出码 0 |
| 美术资产交付（美术校验） | 仓库外的资产校验脚本跑完并产出 `validation/validation.json`，报告里 `failures` 为空（含网格封闭性硬门槛）；只看这份报告，不另开 CI，资产校验不进测试车道。预算文件、`mesh` 段或 `validation.json` 缺失同样算失败，口径见 [美术资产概要「验收」](../art-asset-overview.md#验收) |
| `lua tools/cli.lua deploy` 后执行上面的 `code validate` | `ok=true`、`data.valid=true`、`data.is_se_map=true`，`data.issues` 与 `meta.warnings` 均为空 |
| validate 通过后全套试玩 | 每条验收现象都有取证产物；`log trace` 本轮窗口有效且无错误 |
| 本轮改动提交到分支后、合入 main 前，对 `<基线>...HEAD` 跑 `/code-review`（改动尚未提交时用 `git diff <基线>` 的范围） | 取得 Standards / Spec 两轴结论；硬性违规已修复，或在交付说明里逐条写明 |

**美术诊断任务**：任务单明确允许以失败或阻塞报告交付时，完成诊断须逐项记录实际校验结果、缺失或未完成的检查、停止位置、产物绝对路径和重跑命令，并在任务单保留证据索引。交付说明开头分别说明离线校验是否通过、是否已向 eggitor 发布、是否完成游戏内验收；未执行的阶段写“未执行”。诊断任务结案不改变上表的资产交付门槛，后续发布仍须取得当前输入的合格报告。

**人工验收**：质量工具由人在 dsh-uml-viewer 插件面板上发起，agent 只在收到面板请求时调用对应插件工具，不自行运行；标准工具环境（含 crapper 要求的 cluacov 1.0.0）由人按插件文档准备。agent 在交付说明里照抄下表，列为待人工在面板发起的项。

| 检查 | 通过条件 |
|---|---|
| `uml_crap` | crapper 以 `.busted` 的 `default`（与 full 相同）跑完整套件并采集覆盖率，按 `standardTools` 业务范围发布全树 `.metrics/crap.edn` |
| `uml_mutate`（差分；面板的 mutate-all 才全量重测） | mutator 对业务范围内的目标做差分 mutation，每个变异体经 `--busted-task fast` 只跑 fast 车道，快照写入 `.metrics/mutate/` |
| `uml_dry` | dryer 对业务范围出 DRY 报告 `.metrics/dry.edn` |

## 产物归属

执行过程产物（调研全文、验证台账、验收记录、开发计划）贴进对应 issue 的评论；`docs/` 只留长期参考（术语、技术难点、ADR）。`eggy-dev-plan` 默认的 `docs/plan/` 输出在本仓库改为 issue 评论。

**交接摘要**：写交接或续接摘要时附授权台账，逐条列「用户授权原文 → 覆盖的动作 → 已用完 / 未用」；台账里写不出原文的动作视为未授权，续接方须重新取得确认。部署、试玩、地图保存与重开不需要授权（见 [editor-cli.md](editor-cli.md)「风险步逐次确认」），不必入台账。

