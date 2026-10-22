# 开发工作流

修改代码、运行测试、同步宿主或操作编辑器前，以及整理过程产物时，读取本文。

## 工程用语

- **se-fish**：本图的 Lua 源码与质量工具仓库。
- **业务树**：`client/`、`common/`、`server/` 中的业务源码，即架构图上的三棵树；排除各端 `packages/` 与 `server/_trigger/` 等非业务目录。
- **指标采集范围**：CRAP、DRY 与差分 mutation 实际读的源码集合，三端全树（**含**各端 `packages/`），仅排除 `server/_trigger/`；以 `tools/quality/project.json` 的 `sources` 为准。与「业务树」不是一回事，理由见 [ADR-0005](../adr/0005-packages-as-external.md)。
- **宿主目录**：编辑器 `code init` 绑定的本地 Lua 工程目录，根有 `eggy.json`，是部署目的地；与仓库检出分别管理。路径和绑定方式见下方「工具链」。
- **开发端**：WSL 里的仓库检出及其原生工具链，是唯一的开发、测试与质量运行环境；不在 Windows 开发。
  _Avoid_: 本机
- **部署端**：Windows 侧的 eggitor 编辑器、`editor-cli.exe` 与宿主目录；开发端只经 WSL interop 调用，不在开发端安装编辑器组件。
  _Avoid_: 本机
- **部署树**：镜像进宿主目录的仓库根 `client/`、`common/`、`server/`；仓库根其余内容不部署。宿主内不归本仓库管理的内容由 `sync` 回灌，镜像粒度与操作细节见下方「工具链」。
  _Avoid_: 源码树（指仓库全部时）
- **quality gate**：质量流程的失败处理与快照发布规则，见 [质量工具](../../tools/quality/README.md#日常命令)及其中的「墙钟预算、启动前记录与退出码」；指标只出报告，不设门槛。
- **Busted migration**：全部 Lua 测试改写为原生 Busted、移除 LuaUnit 依赖及桥接层的迁移，决策见 [ADR-0002](../adr/0002-native-busted-migration.md)，当前车道与运行约定见下方「工具链」。

## 工具链

Lua 命令使用 **Lua 5.4**，执行前用 `lua -v` 核对；验收脚本可用 `ACCEPTANCE_LUA_BIN` 指定解释器。Lua 5.5 对循环变量重新赋值会报 `attempt to assign to const variable`，遇到此错误先检查版本。

- `lua tools/cli.lua deploy`：将三端一级子树字节镜像到宿主目录（`robocopy /MIR`，镜像前打印将被删掉的宿主多余文件）；编辑器开着本图时执行 validate → 有差异时 `code push` → `code diff` 复核，push 后仍不一致才返回失败。
- `lua tools/cli.lua sync`：将宿主目录的 `eggy.json`、API 存根、`data/` 回灌仓库。
- `lua tools/cli.lua sync --packages`：在上述清单外追加三端 `packages/` 字节镜像，删除过期文件；任一端源 packages 缺失或为空时整次同步在写入前失败。该方向以宿主为准，回灌前先确认工作区已提交。
- 官方包升级、聚合入口与编辑器预设依赖见 [官方包接入参考](../packages-reference.md)。技能包预设命令见 `lua tools/cli.lua ability-presets --help`；验收脚本说明见 `tools/acceptance/README.md`。
- 质量入口为 `tools/quality/project`（POSIX sh 薄转发），安装、覆盖率、CRAP、DRY、差分 mutation 与复验步骤见 [tools/quality/README.md](../../tools/quality/README.md)；只出报告，不设指标门槛。
- 单测放 `tests/native/`（slow 车道放 `tests/native/slow/`），共享夹具放 `tests/support/`，探针放 `tests/probes/`（手工探针，不入任何车道）。日常运行 `busted --run=fast`（等价 `default`），收尾运行 `busted --run=full`；车道由根目录 `.busted` 定义，共享初始化在 `tests/native/helper.lua`。开发端（WSL）是唯一测试环境，案例不分平台，完成判据表里的 `0 pending` 就是在开发端取的严格值。
  - **执行序只保证到文件内**：迁移保留的是**文件内**执行序（`it` 注册序 == 旧 LuaUnit 类内方法序），**不保留跨文件的全局类名字典序**。LuaUnit 的 `collectTests()` 排的是全局 `_G.Test*` **类名**，`.busted` 的 `sort-files=true` 排的是**文件路径字符串**，是两个键空间，技术上无法廉价复现；且 helper 在文件发现**之前**执行，插不进重排钩子。
    - 为什么可以接受：跨类没有共享状态，夹具逐例隔离（`tests/native/helper.lua`）；**且不复刻旧序反而修了一个真 bug**——旧序下 `damage_float_test.lua` 与 `vitals_test.lua` 都定义全局 `TestDamageNotice`，后加载整表覆盖前者，导致 `test_rounding_and_effective_health` **从未被执行**，迁移后复活（+1，属修复而非回归）。
    - 裁定原文见迁移台账 `issue-84-mapping.md:96` 与 `issue-85-mapping.md:63`（台账在仓库外，按文件名检索）。
  - `busted` 命令：人手 shell 与工具子进程统一用裸 `busted`；`tools/quality/project.json` 的 `commands.*` 与 `busted.command` 都写裸 `busted`。它由 LuaRocks 按固定版本装在 `~/.luarocks/bin`，该目录必须在 PATH 里；`tools/quality/project doctor` 会在缺失时给出提示。

**架构图（uml-viewer）。** 根目录 `policy.edn` 描述三端模块树、排除目录与外部节点（`:exclude`、`:foreign`），`docs/uml/se-fish.edn` 是生成的依赖图（不要手编）。

- `./uml`（安装器生成的原生入口）：首次启动 viewer 与 companion 看图、向 agent 发起图上操作；`./uml ir` 在修改三端代码后重新生成图，viewer 检测文件变化自动重载。
- **companion 后端是 Herdr（>= 0.9.3，socket protocol 22）**：旧 tmux/psmux 路径已退役，运行平台是 WSL2/Linux（Windows 原生不受支持，macOS 当前不承诺）。PATH 上每个 `herdr` 都逐一预检，选出兼容者中版本最高者（同版本取 PATH 靠前者），本次启动的全部 Herdr 调用都走它的绝对路径；无兼容候选时列出各候选路径与拒绝原因，不自动下载、升级或回退。companion ownership 记录在 `.uml-viewer/companion.edn`，必须显式记为 Herdr；旧记录或缺 backend 的记录会保留并拒绝接管，不要猜着重连。能力契约与验收边界见 uml-viewer 的 `docs/herdr-backend-contract.md`，版本下限与可执行文件选择见其 `docs/adr/0003-herdr-version-floor.md`、`docs/adr/0004-herdr-executable-selection.md`。
- **重启 viewer 必须走协议**：往 `.uml-viewer/to-viewer.edn` 写 `:quit-for-restart` → 等旧 JVM 自然退出 → `./uml --restart`；新 JVM 按持久化记录重新 bind 原 pane，不新建 companion。**绝不 SIGKILL**，也不要绕开公开 wrapper 直接传 `--restart`。
- 图上 `crap` / `mutate`：companion 消费邮箱命令后执行项目公开入口（即 `uml-quality.json` 声明的 `tools/quality/project refresh-crap` / `tools/quality/project mutation`）。每次调用前删掉上一条 `.uml-viewer/quality-result.json`，运行后核对刚等到的记录里 `version`、`operation`、`projectRoot`、实际退出码与 `validResult`；只有 `validResult` 为真才继续 IR 与显示。
- 图上 `client|common|server` 为三棵**业务树**：各端 `packages/` 不建类，业务代码对官方包的 `require` 收成外部椭圆（`policy.edn` 的 `:foreign` 取 `client|common|server.packages` 三个端级前缀，每端一个椭圆，新增包无需改 policy）。viewer 从 `.metrics/crap.edn` 与 `.metrics/mutate/*.edn` 加载指标；缺少任一指标的类卡片为红色，指标里没有对应类的记录被忽略（包内代码仍在「指标采集范围」内，只是图上无类可上色）。Lua 指标安装与命令见 [tools/quality/README.md](../../tools/quality/README.md)。
- **标准 quality 分发**：根目录 `uml-quality.json`（版本管理）声明图上 `crap` / `mutate` 转交哪个项目公开命令，终端与右键走同一实现；参数、退出码、锁与失败报告一致。改项目质量入口时同步核对这份声明，`tools/quality/project doctor` 会先校验它。
- `target/` 放覆盖率与 mutation worker，属于忽略的临时产物；`.metrics/` 保留质量快照并纳入版本管理。无函数定义的配置或转发模块不生成 mutation 快照；当前工具不测试模块顶层语句。
- 根目录 `uml` 由安装器生成（原生 POSIX 入口），不要编辑；固定工具组合的安装与校验使用 [tools/quality/README.md](../../tools/quality/README.md) 的项目入口。
- **实机验收在开发端（WSL2）**：安装、doctor、full／fast、coverage、CRAP、独立 Python 回归与 Herdr 恢复的实机数据都来自 WSL。**macOS 未实机验证，没有实机数据**。

**worktree 起手式。** `tools/quality/project.json` 的 `tools.*.source` 写成 `../uml-viewer` 这类相对路径，从检出根的**父目录**解析；worktree 里没有主检出旁的真实工具检出，必须在 worktree 的父目录建 symlink：

```bash
cd "<worktree 父目录>"
for t in uml-viewer crapper mutator dryer; do
  ln -s "<主检出旁的 $t 检出路径>" "$t"
done
```

- 目标必须是这些**真实检出**。指向 `.uml-viewer/<tool>`（安装产物而非上游检出）会让 install／doctor 预检与标准分发回归大面积报错。
- `.toolcache` 与 `.uml-viewer` **不** symlink 共享：在 worktree 里直接 `tools/quality/project install` 独立安装即可（pip、字体与 cimgui 有缓存）。`lua_tools` 七项（`luacov`、`dry4lua`、`luacheck`、`acceptance4lua`、`argparse`、`datafile`、`luafilesystem`）全部登记在 `project.json`，url 与 commit 是声明式来源，由 install 拉取、校验与构建。独立安装也避开共享 venv 的必然后果：`doctor` 里针对 `crapper.__file__` 的断言会失败（editable 安装写下的 `.pth` 硬编码主检出路径）。缺 `luacheck` 时 `tests/native/slow/quality_report_test.lua` 会经 `dry4lua/ast.lua` 抛 `luacheck required`，断言先撞在 `broken.lua` 那一行——报错点离根因三层。
- **不要在 worktree 根内建这四个 symlink**：install 只按 `../<tool>` 从**父目录**解析来源，根内的同名目录无人引用；它们又不在 `.gitignore`（只忽略 `.toolcache/` 与 `.uml-viewer/`），会以 `?? crapper/` 出现在 `git status`，一次 `git add -A` 就提交进去。

**美术资产（Blender / Meshy MCP）。** 产出鱼类等模型与动画的接入方式、导出分件与验收步骤见 [美术资产流水线](art-pipeline.md)，尺寸口径见 [ADR-0004](../adr/0004-fish-asset-scale.md)。仓库不提交 MCP 配置，由所用前端（目前是 Codex）自行接入（key 走环境变量 `MESHY_API_KEY`，不入库）。资产本体不进本仓，正式资产走编辑器导入。

**宿主目录专用于镜像。** 默认 `C:\Users\<用户名>\Desktop\dev\eggy\LuaSource_钓鱼怎么这么危险啊喂！`，可用 `EGGY_WORKSPACE` 覆盖。

**编辑器工程 ≠ 仓库检出。** `eggy.json` 回灌不等于 `code init` 绑定；手动执行 code-* 时用 `--workspace` 指向已绑定的宿主目录，否则会报 `CODE_BINDING_INVALID`。`deploy` 已带此参数。Git Bash 验证命令：

```bash
"$USERPROFILE/.eggitor/cli/editor-cli.exe" code validate --strict --json --workspace "<宿主目录>"
```

## 测试纪律

- **试玩优先**：新增验证尽量只用编辑器 E2E，复杂功能以试玩证明可用；操作见 `eggy-lua` 的「试玩验收」。
- **先列失败方式**：确需单独测试某个系统时，先列出所有可能失败的方式，再写代码；代码写完后不补写单测。
- **局部开发、全量收尾**：开发期间用 `busted --run=fast` 验证；业务功能仍按需试玩，收尾执行下面的全部检查。
- **可复现取证**：每次试玩保留可重跑的触发步骤（`input` 命令、探针文件）与对应证据（`log grep` 命中行、截图路径）。

## 完成判据

代码改动按顺序执行，全部通过才算完成：

| 检查 | 通过条件 |
|---|---|
| `busted --run=fast`（日常） | fast 车道全部用例通过，末行匹配 `N successes / 0 failures / 0 errors / 0 pending : T seconds`，退出码 0 |
| `busted --run=full`（收尾） | 含 slow 车道，全部用例通过，末行匹配 `N successes / 0 failures / 0 errors / 0 pending : T seconds`，退出码 0 |
| `tools/quality/project quality` | 完整 Busted 套件通过，生成本轮 LCOV、全树 CRAP 与 DRY 报告 |
| `tools/quality/project test-tooling` | `tests/tooling/slow` 的 Python 回归全绿（空缓存安装 suite 只吃独立检出，此处按设计跳过） |
| `bash tools/acceptance/run_acceptance.sh`（有 feature 时） | `N passed, 0 failed`，末行 `acceptance run OK`；无 feature 时提示跳过且返回 0 |
| 美术资产交付 | `04-validate.py` 跑完并通过（报告里 `failures` 为空，含网格封闭性硬门槛），且 `bash tools/acceptance/run_acceptance.sh` 的 `features/art/` 车道全绿；只经这两个公开入口调用，不另开 pre-commit / CI。预算文件或 `mesh` 段缺失同样算失败，口径见 [美术资产流水线](art-pipeline.md#网格封闭性硬门槛) |
| 每个改过的 `.lua` 执行 `lua -e "assert(loadfile('<file>'))"` | 无输出、退出码 0 |
| `lua tools/cli.lua deploy` 后执行上面的 `code validate` | `ok=true`、`data.valid=true`、`data.is_se_map=true`，`data.issues` 与 `meta.warnings` 均为空 |
| validate 通过后全套试玩 | 每条验收现象都有取证产物；`log trace` 本轮窗口有效且无错误 |

## 产物归属

执行过程产物（调研全文、验证台账、验收记录、开发计划）贴进对应 issue 的评论；`docs/` 只留长期参考（术语、技术难点、ADR）。`eggy-dev-plan` 默认的 `docs/plan/` 输出在本仓库改为 issue 评论。

