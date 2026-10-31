# 开发工作流

修改代码、运行测试、同步宿主或操作编辑器前，以及整理过程产物时，读取本文。

## 工程用语

- **se-fish**：本图的 Lua 源码仓库。
- **业务范围**：质量工具与架构图共用的源码集合，定义见 `GLOSSARY.md`，决策见 [ADR-0010](../adr/0010-packages-as-business-code.md)。
- **宿主目录**：编辑器 `code init` 绑定的本地 Lua 工程目录，根有 `eggy.json`，是部署目的地；与仓库检出分别管理。路径和绑定方式见下方「工具链」。
- **开发端**：WSL 里的仓库检出及其原生工具链，是唯一的开发、测试与质量运行环境；不在 Windows 开发。
  _Avoid_: 本机
- **部署端**：Windows 侧的 eggitor 编辑器、`editor-cli.exe` 与宿主目录；开发端只经 WSL interop 调用，不在开发端安装编辑器组件。
  _Avoid_: 本机
- **部署树**：镜像进宿主目录的仓库根 `client/`、`common/`、`server/`；仓库根其余内容不部署。宿主内不归本仓库管理的内容由 `sync` 回灌，镜像粒度与操作细节见下方「工具链」。
  _Avoid_: 源码树（指仓库全部时）
- **quality gate**：质量工具（CRAP、mutation、DRY）的结果处理规则：由 uml-viewer 标准工具发布快照与退出码（见 uml-viewer README 的质量分发说明），指标只出报告，不设门槛。
- **Busted migration**：全部 Lua 测试改写为原生 Busted、移除 LuaUnit 依赖及桥接层的迁移，决策见 [ADR-0002](../adr/0002-native-busted-migration.md)，当前车道与运行约定见下方「工具链」。

## 工具链

Lua 命令使用 **Lua 5.4**：WSL 上裸 `lua` 经 alternatives 可能指向 5.1，宿主工具一律用 `lua5.4`，执行前用 `lua5.4 -v` 核对；`tools/cli.lua` 入口在非 5.4 解释器下直接退 1。Lua 5.5 对循环变量重新赋值会报 `attempt to assign to const variable`，遇到此错误先检查版本。

- `lua5.4 tools/cli.lua deploy`：将三端一级子树字节镜像到宿主目录（经 WSL 接缝层调用部署端 `robocopy /MIR`，镜像前打印将被删掉的宿主多余文件；宿主三端根下仓库已删的散文件或子树同样先删）；interop 不可用时在镜像前以退出码 3 失败。编辑器开着本图时执行 validate → 有差异时 `code push` → `code diff` 复核，push 后仍不一致才返回失败。三端内本地已删的地图文件用 `code push --delete --yes` 删掉；三端外的地图独有文件（`temp/` 等编辑器生成物）只提示保留，两类同时出现时不推送（#167）。跨接缝约定见 [ADR-0008](../adr/0008-wsl-development-windows-deploy.md)。
- `lua5.4 tools/cli.lua sync`：将宿主目录的 `eggy.json`、API 存根、`data/` 回灌仓库。
- `lua5.4 tools/cli.lua sync --packages`：在上述清单外追加三端 `packages/` 字节镜像，删除过期文件；任一端源 packages 缺失或为空时整次同步在写入前失败。该方向以宿主为准，回灌前先确认工作区已提交。
- `lua5.4 tools/cli.lua blender <脚本.py> [--blend <输入.blend>] [-- <脚本参数>...]`：在部署端无头 Blender 里执行脚本，是唯一的 Blender 入口；`--which` 核对将用的 Blender，`--expr` 执行内联代码。路径写开发端形式，由入口转换；用法见 [Blender 与 Meshy 使用](art-pipeline.md)，决策见 [ADR-0009](../adr/0009-blender-headless-only.md)。
- 官方包升级、直接调用接口与编辑器预设依赖见 [官方包接入参考](../packages-reference.md)。技能包预设命令见 `lua5.4 tools/cli.lua ability-presets --help`。
- **临时产物**：手工验证的中间文件、单据正文草稿等临时产物一律放仓库 `tmp/`（已 gitignored），无需清理；不放系统临时目录，也不为清理去 `rm`（沙盒会拒绝）。这条管 agent 手工产生的文件；脚本自建自删的临时目录（如 pre-commit hook 在 git 目录下的工作目录）不在此列。
- 质量工具（CRAP / mutation / DRY）是 uml-viewer 自带的标准工具（crapper / mutator / dryer），由人运行 `./uml crap`、`./uml mutate`、`./uml dry`；业务范围与选项只在根目录 `uml-quality.json` 的 `standardTools` 声明，见下方「架构图」。只出报告，不设指标门槛。
- 单测放 `tests/native/`（slow 车道放 `tests/native/slow/`），共享夹具放 `tests/support/`，探针放 `tests/probes/`（手工探针，不入任何车道）。日常运行 `lua5.4 tools/cli.lua test`（缺省 fast），收尾运行 `lua5.4 tools/cli.lua test full`，`--` 之后的参数原样透传给 busted，退出码不透传：测试通过 0，busted 非 0（失败数加错误数）一律收成 1，busted 缺失 3；裸 `busted` 读 `default`，与 full 相同（crapper 列测试文件时不带 `--run`，覆盖率因此含 slow 车道）。车道由根目录 `.busted` 定义，共享初始化在 `tests/native/helper.lua`。开发端（WSL）是唯一测试环境，案例不分平台，完成判据表里的 `0 pending` 就是在开发端取的严格值。
  - **执行序只保证到文件内**：迁移保留的是**文件内**执行序（`it` 注册序 == 旧 LuaUnit 类内方法序），**不保留跨文件的全局类名字典序**。LuaUnit 的 `collectTests()` 排的是全局 `_G.Test*` **类名**，`.busted` 的 `sort-files=true` 排的是**文件路径字符串**，是两个键空间，技术上无法廉价复现；且 helper 在文件发现**之前**执行，插不进重排钩子。
    - 为什么可以接受：跨类没有共享状态；跨文件隔离由 `.busted` 显式开启的 `auto-insulate` 承担（每个文件结束后按键还原 `_G` 与 `package.loaded`，关掉后 fast 出现 7 failures / 3 errors），`tests/native/helper.lua` 只逐例快照 `GameCfg.Debug` 与 `Save.AcceptanceSlot`；**且不复刻旧序反而修了一个真 bug**——旧序下 `damage_float_test.lua` 与 `vitals_test.lua` 都定义全局 `TestDamageNotice`，后加载整表覆盖前者，导致 `test_rounding_and_effective_health` **从未被执行**，迁移后复活（+1，属修复而非回归）。
    - 裁定原文见迁移台账 `issue-84-mapping.md:96` 与 `issue-85-mapping.md:63`（台账在仓库外，按文件名检索）。
  - `busted` 命令：`test` 子命令与人手 shell 统一用 PATH 上的 `busted`（不在 PATH 时 CLI 退出码 3）。它由 LuaRocks 装在 `~/.luarocks/bin`，该目录必须在 PATH 里。

**架构图（uml-viewer）。** 根目录 `policy.edn` 描述三端模块树、排除目录与隐藏模块（`:exclude`、`:omit`），`docs/uml/se-fish.edn` 是生成的依赖图（不要手编）。 六层职责与依赖方向见 [架构分层与依赖门禁](../architecture.md)，唯一分层声明在 `tools/arch_policy.lua`；`tests/native/arch_policy_test.lua` 随 fast/full 阻止未分类、反向依赖、业务环及 `:levels` 漂移。

- `./uml`（安装器生成的原生入口）：首次启动 viewer 与 companion 看图、向 agent 发起图上操作；`./uml ir` 在修改三端代码后重新生成图，viewer 检测文件变化自动重载。
- **companion 后端是 Herdr（>= 0.9.3，socket protocol 22）**：旧 tmux/psmux 路径已退役，运行平台是 WSL2/Linux（Windows 原生不受支持，macOS 当前不承诺）。PATH 上每个 `herdr` 都逐一预检，选出兼容者中版本最高者（同版本取 PATH 靠前者），本次启动的全部 Herdr 调用都走它的绝对路径；无兼容候选时列出各候选路径与拒绝原因，不自动下载、升级或回退。companion ownership 记录在 `.uml-viewer/companion.edn`，必须显式记为 Herdr；旧记录或缺 backend 的记录会保留并拒绝接管，不要猜着重连。能力契约与验收边界见 uml-viewer 的 `docs/herdr-backend-contract.md`，版本下限与可执行文件选择见其 `docs/adr/0003-herdr-version-floor.md`、`docs/adr/0004-herdr-executable-selection.md`。
- **重启 viewer 必须走协议**：往 `.uml-viewer/to-viewer.edn` 写 `:quit-for-restart` → 等旧 JVM 自然退出 → `./uml --restart`；新 JVM 按持久化记录重新 bind 原 pane，不新建 companion。**绝不 SIGKILL**，也不要绕开公开 wrapper 直接传 `--restart`。
- 图上 `crap` / `mutate`：companion 消费邮箱命令后执行与终端 `./uml crap` / `./uml mutate` 相同的标准工具调用（范围取自 `uml-quality.json` 的 `standardTools`）。每次调用前删掉上一条 `.uml-viewer/quality-result.json`，运行后核对刚等到的记录里 `version`、`operation`、`projectRoot`、实际退出码与 `validResult`；只有 `validResult` 为真才继续 IR 与显示。
- 图上 `client|common|server` 三棵树覆盖整个**业务范围**：各端 `packages/` 按真实命名空间建类，不设外部节点（`policy.edn` 不写 `:foreign`，`:exclude` 只排除 `_trigger`）。viewer 从 `.metrics/crap.edn` 与 `.metrics/mutate/*.edn` 加载指标；缺少任一指标的类卡片为红色。包内类不跑 mutation 基线，因缺快照显红并拉低端级聚合分数，属已接受的代价，理由见 [ADR-0010](../adr/0010-packages-as-business-code.md)。标准工具的环境准备（含 crapper 要求的 cluacov 1.0.0）按 uml-viewer 文档由人完成。
- **标准 quality 分发**：根目录 `uml-quality.json`（版本管理）只含 `standardTools`：`sourceRoots` 为三端 `client`、`common`、`server`，`exclude` 为 `server/_trigger`，`mutatorOptions` 为 `--busted-task fast`（每个变异体只跑 fast 车道）。终端 `./uml crap|mutate|dry` 与图上右键走同一实现；业务范围只在这里声明一次，CRAP、mutation、DRY 与架构图口径一致。不用 CLI 包装 `./uml`。
- `target/` 放覆盖率与 mutation worker，属于忽略的临时产物；`.metrics/` 保留质量快照并纳入版本管理。无函数定义的配置或转发模块不生成 mutation 快照；当前工具不测试模块顶层语句。
- 根目录 `uml` 由安装器生成（原生 POSIX 入口），不要编辑；安装与升级按 uml-viewer 文档（`get-uml-viewer`）由人执行。
- **实机验收在开发端（WSL2）**：安装、full／fast、coverage、CRAP 与 Herdr 恢复的实机数据都来自 WSL。**macOS 未实机验证，没有实机数据**。

**worktree 起手式。** 新建 worktree 后在其根执行一次：

```bash
lua5.4 tools/cli.lua worktree-init
```

- 从 magpie 资源库复制上游 `blender-*` skill 到 `.agents/skills/`（来源见[Blender 与 Meshy 使用](art-pipeline.md#上游-blender--skill)）；已存在的条目跳过（可重复执行），来源缺失时在写入前失败。参数见 `--help`。
- 不为质量工具做任何准备：质量工具是 uml-viewer 的标准工具，`.uml-viewer` 不共享，需要在某个 worktree 跑 `./uml` 时由人按 uml-viewer 文档在该 worktree 安装。
- 某个 skill 损坏时，删掉对应目录后重跑 `worktree-init`，由它重建。

**美术资产（Meshy MCP + 无头 Blender）。** Blender 与 Meshy 的接入与用法见 [Blender 与 Meshy 使用](art-pipeline.md)，尺寸口径见 [ADR-0004](../adr/0004-fish-asset-scale.md)。唯一的 MCP 是 Meshy，注册与密钥接法见 [Blender 与 Meshy 使用](art-pipeline.md#前端配置)。Blender 不接 MCP，只经 `blender` 子命令无头执行（[ADR-0009](../adr/0009-blender-headless-only.md)）。资产本体不进本仓，正式资产走编辑器导入。

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

**pre-commit hook（开发端接入）。** 检查脚本入库在 `tools/hooks/pre-commit`：对暂存区每个 `.lua` 取**暂存内容**做 Lua 5.4 `loadfile`，暂存区含 `.lua` 或 `.busted` 时再经 CLI 跑 `lua5.4 tools/cli.lua test fast`（busted 不可用时 CLI 退出码 3，hook 提示安装 busted 并拦下），纯文档提交不跑 busted；质量工具不进 hook。共享 hooks 目录（`git rev-parse --git-common-dir` 下的 `hooks/`，所有 worktree 共用）里的 `pre-commit` 是入库的转发 shim `tools/hooks/shim`，只转发到当前检出的脚本。每个克隆在检出根装一次；shim 改动后重装：

```bash
install -m 755 tools/hooks/shim "$(git rev-parse --git-common-dir)/hooks/pre-commit"
```

- 当前分支没有该脚本时放行，旧分支与并行 worktree 不受影响。
- **检查对象不同**：`loadfile` 查的是暂存内容；fast 车道跑的是工作区。部分暂存（`git add -p`、暂存后又改）时 fast 的结果可能与实际提交的内容不一致，需要确认时先把未暂存改动 `git stash --keep-index` 再提交。
- **不用 `core.hooksPath`**：git 2.43 下设了它，teamai 装在 hooks 目录的 post-* hook 就不再执行，teamai 也拒绝重装。**不用软链**：软链按主 worktree 解析，其他 worktree 会跑主检出那份脚本。
- **与 teamai 分工**：teamai 只管 `post-checkout` / `post-merge` / `post-rewrite`（文件内有 `managed by teamai` 标记），`pre-commit` 归本仓库；两边互不覆盖，改 hook 后核对三个 post-* 仍在且内容未变。
- **`--no-verify` 仅限人用**：agent 不得使用；hook 拦下时修复问题后重新提交。

**宿主目录专用于镜像。** 默认由 WSL 接缝层从部署端 `USERPROFILE` 推导：`%USERPROFILE%\Desktop\dev\eggy\LuaSource_钓鱼怎么这么危险啊喂！`。可用 `EGGY_WORKSPACE` 覆盖，接受 `/mnt/c/...` 与 `C:\...` 两种形式；空串当作未设置。

**编辑器工程 ≠ 仓库检出。** `eggy.json` 回灌不等于 `code init` 绑定；手动执行 code-* 时用 `--workspace` 指向已绑定的宿主目录（部署端 exe 只认 Windows 形式，用 `wslpath -w` 转换），否则会报 `CODE_BINDING_INVALID`。`deploy` 已带此参数。手工复核（WSL interop）：

```bash
"/mnt/c/Users/<用户名>/.eggitor/cli/editor-cli.exe" code validate --strict --json --workspace "$(wslpath -w '<宿主目录>')"
```

等价地直接看 `lua5.4 tools/cli.lua deploy` 的收尾输出。

**编辑器 CLI 取证。** 操作前用目标命令的 `--help`（或 `help export <命令>`）确认当前版本能力。编辑器分发的 skill（`eggy-se-*`）与本节或 CLI `--help` 冲突时，以后两者为准，见 [ADR-0014](../adr/0014-eggitor-ai-resources-not-source-of-truth.md)。以下是 0.20.12～0.20.13 的项目实测：

- **会话首开对齐**：本会话第一次做 Lua 相关操作且编辑器在线时，先跑 `code diff --json`；changelist 非空就把分类计数与文件清单报给用户，由用户选 push、pull 或暂不处理，agent 不自选方向。
- **多实例**：`editor-instances list` 列出多个实例时（含停在 `<starting>` 的），每条命令都带 `--editor-instance <pid>`。
- **试玩闸门例外**：`code diff` 中 `differs`、`only-on-map` 为空，且 `only-local` 全在 `unit_scripts/` 或 `.agents/` 下时，视为干净，不 push、直接试玩，并在取证记录里写明这些文件。`unit_scripts/` 由引擎生成（见 `AGENTS.md`），`deploy` 只镜像三端子树，不会清理它；`.agents/` 是 agent 配置，不进地图。
- **异步输出**：服务端、客户端 `exec` 提交成功只表示代码已提交。脚本打印唯一标记后，用 `log grep <标记> | grep '^>'` 读取实际结果（不带过滤时会混入上下文行与统计行）。`log grep` 没有 `-i`：默认就不区分大小写，需要区分时加 `--case-sensitive`。
- **画面**：该版本没有 `screenshot offscreen`，也没有 `--format`（只出 PNG，用 `--output` / `--stdout`）；编辑态截图带网格时，改用试玩的 `screenshot game` 取无网格证据。只截判读对象，结束后还原取景和现场。
- **截图失败**：窗口被遮挡、最小化或在远程虚拟屏上时，`screenshot game` 会返回 `FRAME_NEAR_WHITE` 或黑帧，`screenshot editor` 会得到 1×1（`SCREENSHOT_INVALID_DIMENSIONS`）。先把编辑器窗口置前再重试一次；仍失败就请用户目视确认，给出选项、时间点和观察要点，不要循环重试。
- **保存与重开**：`map save` 成功后 `map dirty` 仍可能为 true，此时 `map reopen` 报 `MAP_REOPEN_REJECTED`。先用 `map dirty --json` 列出 dirty 来源请用户确认，确认后才可 `map reopen --force`；来源不明时可能是用户的手动编辑，不要强制。停止试玩本身也会让 dirty 变成 true。
- **场景枚举**：编辑器侧执行[技术难点识别的绕过合同](../技术难点识别.md#绕过合同四条硬边界)，试玩服务端的例外也写在那里。
- **检索失败**：`docs search` 报 HTTP 500 等服务端错误时（0.20.12 的 `editor-api` docset 出现过），改查 `manual` 或编辑器在线时的 `api search-editor` / `api get-editor`。
- **模型动画验收**：导入、播放与画面判定读[美术资产概要「模型动画导入与播放」](../art-asset-overview.md#模型动画导入与播放)。

## 测试纪律

- **试玩优先**：新增验证尽量只用编辑器 E2E，复杂功能以试玩证明可用；操作见 skill `eggy-se-qa`。
- **先列失败方式**：确需单独测试某个系统时，先列出所有可能失败的方式，再写代码；代码写完后不补写单测。
- **局部开发、全量收尾**：开发期间用 `lua5.4 tools/cli.lua test` 验证；业务功能仍按需试玩，收尾执行下面的全部检查。
- **可复现取证**：每次试玩保留可重跑的触发步骤（`input` 命令、探针文件）与对应证据（`log grep` 命中行、截图路径）。

## 完成判据

代码改动按顺序执行，全部通过才算完成；pre-commit 一项不占顺序，每次提交时由 hook 自动完成。下表只列 agent 执行的项；质量工具由人运行，见表后的「人工验收」。

| 检查 | 通过条件 |
|---|---|
| `lua5.4 tools/cli.lua test full`（收尾） | 含 slow 车道，全部用例通过，末行匹配 `N successes / 0 failures / 0 errors / 0 pending : T seconds`，退出码 0 |
| 美术资产交付（美术校验） | 仓库外的资产校验脚本跑完并产出 `validation/validation.json`，报告里 `failures` 为空（含网格封闭性硬门槛）；只看这份报告，不另开 CI，资产校验不进 pre-commit。预算文件、`mesh` 段或 `validation.json` 缺失同样算失败，口径见 [美术资产概要「验收」](../art-asset-overview.md#验收) |
| 提交时 pre-commit hook 自动检查（见上方「pre-commit hook」）：暂存的 `.lua` 逐个 `loadfile`，含 Lua 改动时再经 CLI 跑 `lua5.4 tools/cli.lua test fast`；agent 不另跑这一项，提交时也不必为它重复手跑 fast | `git commit` 成功，未被 hook 拦下 |
| `lua5.4 tools/cli.lua deploy` 后执行上面的 `code validate` | `ok=true`、`data.valid=true`、`data.is_se_map=true`，`data.issues` 与 `meta.warnings` 均为空 |
| validate 通过后全套试玩 | 每条验收现象都有取证产物；`log trace` 本轮窗口有效且无错误 |
| 本轮改动提交到分支后、合入 main 前，对 `<基线>...HEAD` 跑 `/code-review`（改动尚未提交时用 `git diff <基线>` 的范围） | 取得 Standards / Spec 两轴结论；硬性违规已修复，或在交付说明里逐条写明 |

**美术诊断任务**：任务单明确允许以失败或阻塞报告交付时，完成诊断须逐项记录实际校验结果、缺失或未完成的检查、停止位置、产物绝对路径和重跑命令，并在任务单保留证据索引。交付说明开头分别说明离线校验是否通过、是否已向 eggitor 发布、是否完成游戏内验收；未执行的阶段写“未执行”。诊断任务结案不改变上表的资产交付门槛，后续发布仍须取得当前输入的合格报告。

**人工验收**：质量工具（`./uml crap`、`./uml mutate`、`./uml dry`）只由人运行，agent 不执行；标准工具环境（含 crapper 要求的 cluacov 1.0.0）由人按 uml-viewer 文档准备。agent 在交付说明里照抄下表命令，列为待人工跑的项。

| 检查 | 通过条件 |
|---|---|
| `./uml crap` | crapper 以 `.busted` 的 `default`（与 full 相同）跑完整套件并采集覆盖率，按 `standardTools` 业务范围发布全树 `.metrics/crap.edn` |
| `./uml mutate`（可带文件或 `--changed`） | mutator 对业务范围内的目标做差分 mutation，每个变异体经 `--busted-task fast` 只跑 fast 车道，快照写入 `.metrics/mutate/` |
| `./uml dry` | dryer 对业务范围出 DRY 报告 `.metrics/dry.edn` |

## 产物归属

执行过程产物（调研全文、验证台账、验收记录、开发计划）贴进对应 issue 的评论；`docs/` 只留长期参考（术语、技术难点、ADR）。`eggy-dev-plan` 默认的 `docs/plan/` 输出在本仓库改为 issue 评论。

