# 编辑器 CLI 取证

本文件由 `docs/agents/workflow.md` 的同名一节整体搬出，搬出的条目措辞未改；workflow.md 原地只留一行指针。条目按主题排列，新增实测接在相关条目之后。

**编辑器 CLI 取证。** 操作前用目标命令的 `--help`（或 `help export <命令>`）确认当前版本能力。团队仓分发的 `eggy-*` 技能与本节或 CLI `--help` 冲突时，以后两者为准；通用勘误提 PR 改团队仓 SE 副本（[ADR-0015](../adr/0015-eggitor-ai-resources-team-repo-maintained.md)），本节只留项目实测。以下是 0.20.12～0.20.13 的项目实测：

- **会话首开对齐**：本会话第一次做 Lua 相关操作且编辑器在线时，先跑 `code diff --json`；changelist 非空就把分类计数与文件清单报给用户，由用户选 push、pull 或暂不处理，agent 不自选方向。
- **多实例**：`editor-instances list` 列出多个实例时（含停在 `<starting>` 的），每条命令都带 `--editor-instance <pid>`。
- **试玩闸门例外**：`code diff` 中 `differs`、`only-on-map` 为空，且 `only-local` 全在 `unit_scripts/` 或 `.agents/` 下时，视为干净，不 push、直接试玩，并在取证记录里写明这些文件。`unit_scripts/` 由引擎生成（见 `AGENTS.md`），`deploy` 只镜像三端子树，不会清理它；`.agents/` 是 agent 配置，不进地图。
- **试玩就绪**：`status.ready` 表示「编辑器可以编辑地图」，试玩跑起来后它是 `false`，不能拿来做轮询条件（永远等不到）。试玩就绪的判据是 `in_game_runtime == true` 且 `editor_state == "playing"`，或直接跑一条 `input state` 看有没有返回玩家坐标。
- **异步输出**：服务端、客户端 `exec` 提交成功只表示代码已提交。脚本打印唯一标记后，用 `log grep <标记> | grep '^>'` 读取实际结果（不带过滤时会混入上下文行与统计行）。`log grep` 没有 `-i`：默认就不区分大小写，需要区分时加 `--case-sensitive`。编辑器 `exec` 的同步返回值在约 5KB 处静默截断，批量读取同样走打印标记加 `log grep`。
- **exec 预算**：编辑器 `exec` 有 5 秒硬预算，`--timeout` 改不动。超时是半途中断：已写入的部分生效，返回里只有一条 timeout 错误，不告诉你做到第几个节点（实测一次建了 8 个 EUI 节点就被掐断，26 个节点的骨架分了 5 轮才补齐）。写场景的探针因此必须幂等（同名节点存在就跳过或只改属性，不重建）并分批（每次只动固定个数，剩下的下次重跑）；每轮跑之前先 dry-run，跑完立刻改回 `APPLY = false`。
- **EUI 几何写入**：`Position` / `Size` / `Anchor` 传普通 table 时 `SetProperty` 照样返回 `true`，但值一点不变（实测写 `{X=24, Y=700}` 后读回还是原值，8 个节点全停在 `0,0 100×100`，探针一路报成功）。正确写法是 `node:SetProperty('Position', Vector2.New(24, 700))`——`Vector2` 在编辑态 exec 沙箱里是全局可用的。读写还不对称：写入用 userdata（字段 `.X` / `.Y`），读回来是数组下标形态（`[1]` / `[2]`，`.X` 为 nil），拿 `.X` 比对会永远判不等，表现成每次重跑都全量重写。规则：写几何用 `Vector2.New`，读回来用下标，不拿 `SetProperty` 的返回值当成功证据，要读回校验。
- **截图**：先判显示路径——`lua tools/cli.lua screenshot --info` 报「虚拟屏 / 非虚拟屏 / 不确定」，别用适配器列表里有没有 GameViewer 来推断（虚拟适配器常挂着但未附加到桌面）。非虚拟屏用 editor-cli `screenshot game`（游戏画面）与 `screenshot editor`（编辑器界面）。虚拟屏（UU 远程的 GameViewer Virtual Display Adapter）上窗口表面抓取取不到新内容，形态有两种：校验通过的黑帧（`FRAME_VALID`，0.20.16 实测），以及尺寸正常、内容停在旧帧（#185，0.20.13 实测）；置前重试都无效，改用工具链的 `lua tools/cli.lua screenshot`。**单帧 `FRAME_VALID` 证明不了帧是新的**：判新旧用连拍，先确认两帧尺寸一致，再比 md5，尺寸变了的那组作废重采。窗口被遮挡或最小化时，先让目标窗口显示在屏幕上再抓一次；`screenshot game` 可能返回 `FRAME_NEAR_WHITE`，`screenshot editor` 可能得到 1×1（`SCREENSHOT_INVALID_DIMENSIONS`）。仍无画面就请用户目视确认，给出选项、时间点和观察要点，不要循环重试。
- **保存与重开**：`map save` 成功后 `map dirty` 仍可能为 true，此时 `map reopen` 报 `MAP_REOPEN_REJECTED`。保存与重开都不需要授权：先用 `map dirty --json` 列出 dirty 来源并记进取证，再执行 `map reopen --force`。来源不明时可能是用户的手动编辑，强制重开前把来源清单与当前 `code diff` 写进取证，别静默丢弃。停止试玩本身也会让 dirty 变成 true。
- **风险步逐次确认**：推送、场景写入，每一步单独取得用户确认；一次授权只覆盖它点名的那一轮或那一批。部署（`lua tools/cli.lua deploy`，含它收尾阶段随行的 validate → `code push` → `code diff` 复核）、试玩（起停、`input` 操作、截图取证）与地图保存（`map save`）不需要授权，直接执行，但照「测试纪律」留可重跑的触发步骤与证据。不经 `deploy` 的手工 `code push` 仍算推送，要确认。地图保存与重开都会碰当前 dirty，先按上一条「保存与重开」记录来源再执行。场景写入即以 `APPLY = true` 执行写场景探针：先以 `APPLY = false` 跑 dry-run 并把结果交给用户，用户确认一批才执行一批，执行完立即把探针改回 `APPLY = false`。
- **场景整理顺序**：空目录清理排在全部建标记批次之后，只处理基线回读时已存在的空目录。删除或挪动场景地面（灰盒地块等）前，先在试玩服务端对受影响区的 `Z*` 点位与设施打向下射线，确认其下仍有地面（删 01 灰盒大地板后，渔夫、商店、抽奖、出生点、鱼饵曾悬在鱼塘水面上）。
- **编辑态读不到的设置**：编辑态 `editor:GetService('PhysicsService')` 为 nil，地面高度只能在试玩服务端用射线测；编辑态读 World 的 `AOIType`、`StreamingEnabled` 得到 nil，流式加载设置无法经 CLI 确认。
- **场景枚举**：编辑器侧执行[技术难点识别的绕过合同](../技术难点识别.md#绕过合同四条硬边界)，试玩服务端的例外也写在那里。
- **检索失败**：`docs search` 报 HTTP 500 等服务端错误时（0.20.12 的 `editor-api` docset 出现过），改查 `manual` 或编辑器在线时的 `api search-editor` / `api get-editor`。
- **检索范围**：本图是世界版（SE），`status --json` 显示 `editor_mode: "se"`。`docs search` 只查世界版文档库：`manual`、`game-api`、`editor-api`、`asset`。用户问题里的词在这些库里查不到时，先问用户指什么，等确认后再换库或换方向。原点版（FS）的 `fs-manual`、`fs-component` 只在用户点名「原点版 / FS」时才查。
- **模型动画验收**：导入、播放与画面判定读[美术资产概要「模型动画导入与播放」](../art-asset-overview.md#模型动画导入与播放)。
- **验收判据读产物**：判据不要读工具或探针自己打印的摘要。实测验收手册把「探针打印的 `PLANNED-MISSING(0)`」当判据，而探针统计缺失时一律从根节点 `FindFirstChild` 取（函数不递归），嵌套子节点永远是「缺失」，判据根本不可能达成。正确做法是让判据落在产物上：节点树回读、`data/UINodes.lua`、`log grep` 的实打实行；探针自己算的摘要本身也要有测试。两条工具用法：`log grep` 追「最新进展」要加 `--max-matches` 一个大值再 `tail`（默认只留最旧的 50 条，本次拿到的是 457 条里最早的 50 条）；等长时状态别在一条命令里塞 `sleep` 循环（期间没有任何输出，中断或超时等于零信息），每次只查一次由调用方重试，或用后台任务。
- **sync 回灌的引擎生成物**：`sync` 会把 `EggyAPI.lua` 这样的引擎生成物一并带回仓库；与本次改动无关时单独 `git restore`，并在验收记录里点名，别让无关的 API 刷新混进功能分支。
