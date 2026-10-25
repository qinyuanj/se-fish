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

Lua 命令使用 **Lua 5.4**：WSL 上裸 `lua` 经 alternatives 可能指向 5.1，宿主工具一律用 `lua5.4`，执行前用 `lua5.4 -v` 核对（与 `tools/quality/project.json` 的 `lua.executable` 同口径）；验收脚本可用 `ACCEPTANCE_LUA_BIN` 指定解释器。Lua 5.5 对循环变量重新赋值会报 `attempt to assign to const variable`，遇到此错误先检查版本。

- `lua5.4 tools/cli.lua deploy`：将三端一级子树字节镜像到宿主目录（经 WSL 接缝层调用部署端 `robocopy /MIR`，镜像前打印将被删掉的宿主多余文件）；interop 不可用时在镜像前以非零退出码失败。编辑器开着本图时执行 validate → 有差异时 `code push` → `code diff` 复核，push 后仍不一致才返回失败。跨接缝约定见 [ADR-0008](../adr/0008-wsl-development-windows-deploy.md)。
- `lua5.4 tools/cli.lua sync`：将宿主目录的 `eggy.json`、API 存根、`data/` 回灌仓库。
- `lua5.4 tools/cli.lua sync --packages`：在上述清单外追加三端 `packages/` 字节镜像，删除过期文件；任一端源 packages 缺失或为空时整次同步在写入前失败。该方向以宿主为准，回灌前先确认工作区已提交。
- `lua5.4 tools/cli.lua blender <脚本.py> [--blend <输入.blend>] [-- <脚本参数>...]`：在部署端无头 Blender 里执行脚本，是唯一的 Blender 入口；`--which` 核对将用的 Blender，`--expr` 执行内联代码。路径写开发端形式，由入口转换；用法与约定见 [美术资产流水线](art-pipeline.md)，决策见 [ADR-0009](../adr/0009-blender-headless-only.md)。
- 官方包升级、聚合入口与编辑器预设依赖见 [官方包接入参考](../packages-reference.md)。技能包预设命令见 `lua5.4 tools/cli.lua ability-presets --help`；验收脚本说明见 `tools/acceptance/README.md`。
- **临时产物**：手工验证的中间文件、单据正文草稿等临时产物一律放仓库 `tmp/`（已 gitignored），无需清理；不放系统临时目录，也不为清理去 `rm`（沙盒会拒绝）。这条管 agent 手工产生的文件；脚本自建自删的临时目录（如 pre-commit hook 在 git 目录下的工作目录）不在此列。
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
- `.toolcache` 与 `.uml-viewer` **不** symlink 共享：由人在 worktree 里执行 `tools/quality/project install` 独立安装（pip、字体与 cimgui 有缓存；agent 不执行，见「完成判据」的人工验收表）。`lua_tools` 七项（`luacov`、`dry4lua`、`luacheck`、`acceptance4lua`、`argparse`、`datafile`、`luafilesystem`）全部登记在 `project.json`，url 与 commit 是声明式来源，由 install 拉取、校验与构建。独立安装也避开共享 venv 的必然后果：`doctor` 里针对 `crapper.__file__` 的断言会失败（editable 安装写下的 `.pth` 硬编码主检出路径）。缺 `luacheck` 时 `tests/native/slow/quality_report_test.lua` 会经 `dry4lua/ast.lua` 抛 `luacheck required`，断言先撞在 `broken.lua` 那一行——报错点离根因三层。
- **不要在 worktree 根内建这四个 symlink**：install 只按 `../<tool>` 从**父目录**解析来源，根内的同名目录无人引用；它们又不在 `.gitignore`（只忽略 `.toolcache/` 与 `.uml-viewer/`），会以 `?? crapper/` 出现在 `git status`，一次 `git add -A` 就提交进去。

**美术资产（Meshy MCP + 无头 Blender）。** 产出鱼类等模型与动画的接入方式、导出分件与验收步骤见 [美术资产流水线](art-pipeline.md)，尺寸口径见 [ADR-0004](../adr/0004-fish-asset-scale.md)。唯一的 MCP 是 Meshy，注册与密钥接法见 [美术资产流水线](art-pipeline.md#前端配置)。Blender 不接 MCP，只经 `blender` 子命令无头执行（[ADR-0009](../adr/0009-blender-headless-only.md)）。资产本体不进本仓，正式资产走编辑器导入。

**蛋仔 hook 与技能（开发端接入）。** eggitor 的 `SessionStart` hook（`session_start.mjs`）向会话注入 `eggy-se.mdc` 规则与帧同步技能禁用清单，但安装器只把它登记在部署端的 `~/.codex/hooks.json`。开发端手动接入，复用部署端资产，随编辑器升级自动更新：

- 软链 `ln -sfn /mnt/c/Users/<用户名>/.eggitor ~/.eggitor`：脚本按 `os.homedir()` 定位规则与技能。
- 在开发端 `~/.codex/hooks.json` 的 `SessionStart` **末尾**追加 `bash -lc "node ~/.eggitor/codex/hooks/session_start.mjs"`（`bash -lc` 取到 nvm 的 `node`）。Codex 按 `事件:序号` 在 `config.toml` 的 `hooks.state` 记录信任，追加在末尾才保得住已信任的条目；新条目首次启动时确认信任。
- 把 `~/.eggitor/codex/se/skills/*` 逐个软链进 `~/.codex/skills/`，只挂 `se`。
- 自检：`echo '{"cwd":"'"$PWD"'"}' | node ~/.eggitor/codex/hooks/session_start.mjs` 输出的 `additionalContext` 以 `eggy-se.mdc` 的 front matter 开头即接入完成。

注入的规则有三处与开发端不符，以本仓约定为准：

- **沙盒警告**：脚本只在 `~/.codex/config.toml` 全文找 `danger-full-access` 字样，"检测到 Codex 沙盒环境"按实际 `sandbox_mode` 判断。
- **编辑工具**："只用 `replace_in_file` 编辑文件"写给 codemaker；Codex 用 `apply_patch`，保持 UTF-8。
- **技能表**：`eggy-se-scene-env` 未随 eggitor 分发，氛围类需求没有对应技能。

**teamai 的 Gitea 凭据（开发端接入）。** `GITEA_URL`、`GITEA_TOKEN` 存在部署端用户环境变量，经 Windows 用户变量 `WSLENV=GITEA_URL:GITEA_TOKEN` 透传到开发端，凭据只存一份。改 `WSLENV` 后关闭全部终端并 `wsl --shutdown` 才生效，常驻会话（Herdr 等）一并重启；`teamai doctor` 的两项 Gitea 检查通过即接入完成。缺凭据时 pull、recall 与 hook 照常，走 Gitea API 的操作（`members`、贡献 learning）失败。

**pre-commit hook（开发端接入）。** 检查脚本入库在 `tools/hooks/pre-commit`：对暂存区每个 `.lua` 取**暂存内容**做 Lua 5.4 `loadfile`，暂存区含 `.lua` 或 `.busted` 时再跑 `busted --run=fast`，纯文档提交不跑 busted；质量工具不进 hook。共享 hooks 目录（`git rev-parse --git-common-dir` 下的 `hooks/`，所有 worktree 共用）里的 `pre-commit` 只转发到当前检出的脚本，每个克隆装一次：

```bash
H="$(git rev-parse --git-common-dir)/hooks"
printf '%s\n' '#!/bin/sh' 'f="$(git rev-parse --show-toplevel)/tools/hooks/pre-commit"; [ -f "$f" ] || exit 0; exec sh "$f" "$@"' >"$H/pre-commit"
chmod +x "$H/pre-commit"
```

- 当前分支没有该脚本时放行，旧分支与并行 worktree 不受影响。
- **检查对象不同**：`loadfile` 查的是暂存内容；`busted --run=fast` 跑的是工作区。部分暂存（`git add -p`、暂存后又改）时 fast 的结果可能与实际提交的内容不一致，需要确认时先把未暂存改动 `git stash --keep-index` 再提交。
- **不用 `core.hooksPath`**：git 2.43 下设了它，teamai 装在 hooks 目录的 post-* hook 就不再执行，teamai 也拒绝重装。**不用软链**：软链按主 worktree 解析，其他 worktree 会跑主检出那份脚本。
- **与 teamai 分工**：teamai 只管 `post-checkout` / `post-merge` / `post-rewrite`（文件内有 `managed by teamai` 标记），`pre-commit` 归本仓库；两边互不覆盖，改 hook 后核对三个 post-* 仍在且内容未变。
- **`--no-verify` 仅限人用**：agent 不得使用；hook 拦下时修复问题后重新提交。

**宿主目录专用于镜像。** 默认由 WSL 接缝层从部署端 `USERPROFILE` 推导：`%USERPROFILE%\Desktop\dev\eggy\LuaSource_钓鱼怎么这么危险啊喂！`。可用 `EGGY_WORKSPACE` 覆盖，接受 `/mnt/c/...` 与 `C:\...` 两种形式；空串当作未设置。

**编辑器工程 ≠ 仓库检出。** `eggy.json` 回灌不等于 `code init` 绑定；手动执行 code-* 时用 `--workspace` 指向已绑定的宿主目录（部署端 exe 只认 Windows 形式，用 `wslpath -w` 转换），否则会报 `CODE_BINDING_INVALID`。`deploy` 已带此参数。手工复核（WSL interop）：

```bash
"/mnt/c/Users/<用户名>/.eggitor/cli/editor-cli.exe" code validate --strict --json --workspace "$(wslpath -w '<宿主目录>')"
```

等价地直接看 `lua5.4 tools/cli.lua deploy` 的收尾输出。

## 测试纪律

- **试玩优先**：新增验证尽量只用编辑器 E2E，复杂功能以试玩证明可用；操作见 `eggy-lua` 的「试玩验收」。
- **先列失败方式**：确需单独测试某个系统时，先列出所有可能失败的方式，再写代码；代码写完后不补写单测。
- **局部开发、全量收尾**：开发期间用 `busted --run=fast` 验证；业务功能仍按需试玩，收尾执行下面的全部检查。
- **可复现取证**：每次试玩保留可重跑的触发步骤（`input` 命令、探针文件）与对应证据（`log grep` 命中行、截图路径）。

## 完成判据

代码改动按顺序执行，全部通过才算完成；pre-commit 一项不占顺序，每次提交时由 hook 自动完成。下表只列 agent 执行的项；质量工具由人运行，见表后的「人工验收」。

| 检查 | 通过条件 |
|---|---|
| `busted --run=fast`（日常） | fast 车道全部用例通过，末行匹配 `N successes / 0 failures / 0 errors / 0 pending : T seconds`，退出码 0 |
| `busted --run=full`（收尾） | 含 slow 车道，全部用例通过，末行匹配 `N successes / 0 failures / 0 errors / 0 pending : T seconds`，退出码 0 |
| `bash tools/acceptance/run_acceptance.sh`（无参数；有 feature 时） | 跑除 `art` 外的全部车道及 `features/` 根下的裸 feature，每个 feature `N passed, 0 failed`，末行 `acceptance run OK`；所选范围无 feature 时提示跳过且返回 0。`art` 断言仓库外美术产物，不进代码收尾门（见「美术资产交付」行）；`--all` 跑全部车道 |
| 美术资产交付 | `04-validate.py` 跑完并通过（报告里 `failures` 为空，含网格封闭性硬门槛），且 `bash tools/acceptance/run_acceptance.sh art` 全绿；只经这两个公开入口调用，不另开 CI，资产校验不进 pre-commit。预算文件、`mesh` 段或 `validation.json` 缺失同样算失败（缺报告时提示缺哪份，可用 `EGGY_ART_ASSETS` 指到美术资产根目录），口径见 [美术资产流水线](art-pipeline.md#网格封闭性硬门槛) |
| 提交时 pre-commit hook 自动检查（见上方「pre-commit hook」）：暂存的 `.lua` 逐个 `loadfile`，含 Lua 改动时再跑 `busted --run=fast`；agent 不另跑这一项，提交时也不必为它重复手跑 fast | `git commit` 成功，未被 hook 拦下 |
| `lua5.4 tools/cli.lua deploy` 后执行上面的 `code validate` | `ok=true`、`data.valid=true`、`data.is_se_map=true`，`data.issues` 与 `meta.warnings` 均为空 |
| validate 通过后全套试玩 | 每条验收现象都有取证产物；`log trace` 本轮窗口有效且无错误 |
| 本轮改动提交到分支后、合入 main 前，对 `<基线>...HEAD` 跑 `/code-review`（改动尚未提交时用 `git diff <基线>` 的范围） | 取得 Standards / Spec 两轴结论；硬性违规已修复，或在交付说明里逐条写明 |

**人工验收**：质量工具（`tools/quality/project` 的 `install`、`quality`、`test-tooling` 等全部子命令）由人手动运行，agent 不执行；agent 在交付说明里照抄下表命令，列为待人工跑的项。

| 检查 | 通过条件 |
|---|---|
| `tools/quality/project quality` | 完整 Busted 套件通过，生成本轮 LCOV、全树 CRAP 与 DRY 报告 |
| `tools/quality/project test-tooling` | `tests/tooling/slow` 的 Python 回归全绿（空缓存安装 suite 只吃独立检出，此处按设计跳过）；真实拉起 crapper/mutator 的端到端用例由 `SE_FISH_QUALITY_E2E` 门控，默认跳过、`SE_FISH_QUALITY_E2E=1` 释放，「全绿」指门控默认形态下全绿 |

## 产物归属

执行过程产物（调研全文、验证台账、验收记录、开发计划）贴进对应 issue 的评论；`docs/` 只留长期参考（术语、技术难点、ADR）。`eggy-dev-plan` 默认的 `docs/plan/` 输出在本仓库改为 issue 评论。

