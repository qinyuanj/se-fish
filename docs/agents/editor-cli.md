# 编辑器 CLI 取证

本文件由 `docs/agents/workflow.md` 的同名一节整体搬出；workflow.md 原地只留一行指针。条目按主题排列，新增实测接在相关条目之后。

**通用用法读技能。** CLI 定位、`status` 字段、code 命令组与判脏、日志子命令、截图通道、EUI 与场景命令的用法以团队技能 `eggy-se-editor-cli`（含 references）为准，本节只留项目实测、技能没写到的坑，以及与本图口径或实测结果不同的地方。技能与本节或 CLI `--help` 冲突时以后两者为准；通用勘误提 PR 改团队仓 SE 副本。实测版本 0.20.12～0.20.13，另标注者除外。

- **试玩闸门例外**：技能的判脏例外只列 `unit_scripts/`；`.agents/` 同样算干净（agent 配置，不进地图，`deploy` 也不清理），取证时点名。
- **试玩就绪**：`status.ready` 是「编辑器可编辑地图」，试玩中为 `false`，等它永远等不到。判据是 `in_game_runtime == true` 且 `editor_state == "playing"`，或 `input state` 有玩家坐标。
- **异步输出**：服务端、客户端 `exec` 提交成功只表示已提交；编辑器 `exec` 的同步返回在约 5KB 处静默截断。批量读取一律打印唯一标记再 `log grep <标记> | grep '^>'`（不加 `^>` 会混入上下文行与统计行）。
- **exec 预算**：编辑器 `exec` 有 5 秒硬预算，`--timeout` 改不动；超时是半途中断，已写入的部分生效，返回只有一条 timeout 错误，不告诉你做到第几个节点。写场景探针因此必须幂等（同名节点跳过或只改属性）并分批；每轮先 dry-run，跑完立刻改回 `APPLY = false`。
- **EUI 几何写入（技能写法实测无效）**：技能文档让 `SetProperty('Position', {100.0, 200.0})` 传 table、`CreateEUINode` 传 `{X=..., Y=...}`；实测 `SetProperty` 返回 `true` 但值不变。写几何用 `node:SetProperty('Position', Vector2.New(24, 700))`（`Vector2` 在编辑态沙箱可用）；读回来是下标形态（`[1]` / `[2]`，`.X` 为 nil），拿 `.X` 比对永远不等。不拿 `SetProperty` 返回值当成功证据，要读回校验。
- **截图**：取证统一用 `lua tools/cli.lua screenshot`，不用 editor-cli 的 `screenshot`——它的窗口表面抓取在虚拟屏上会失败：校验通过的黑帧（0.20.16 实测），或尺寸正常、内容停在旧帧（#185，0.20.13 实测），置前重试也无效。工具链这条走 `PrintWindow` + `PW_RENDERFULLCONTENT` 读窗口表面，目标窗口被遮挡也能取到当前帧；选窗时排除 `WS_EX_LAYERED` 辅助表面（`Qt5QWindowToolSaveBits` 这类窗口标题也叫 `client` 却不画东西，#185）。取证前先跑 `--info` 确认选中了哪颗窗口（报标题、进程、尺寸与虚拟屏 / 非虚拟屏 / 不确定），别用 GameViewer 适配器在不在列表里推断。单帧有效证明不了帧新：连拍比 md5，先锁尺寸，尺寸变了的那组作废重采。仍无画面就请用户目视确认，不循环重试。
- **保存与重开**：`map save` 成功后 `map dirty` 仍可能为 true，此时 `map reopen` 报 `MAP_REOPEN_REJECTED`。两者都不需要授权；先用 `map dirty --json` 列出来源记进取证再执行，别静默丢弃可能是用户手动编辑的来源（停止试玩本身也会让 dirty 变 true）。
- **风险步逐次确认**：推送、场景写入单独取得用户确认，一次授权只覆盖它点名的那一轮或那一批；不经 `deploy` 的手工 `code push` 算推送。部署（含随行 validate → `code push` → `code diff`）、试玩（起停、`input`、截图取证）、地图保存与重开都不需要授权，直接执行，照「测试纪律」留证据。场景写入以 `APPLY = true` 跑探针：先 `APPLY = false` dry-run 交用户，确认一批执行一批，执行完改回 `APPLY = false`。
- **场景整理顺序**：空目录清理排在全部建标记批次之后，只处理基线回读时已存在的空目录。删除或挪动场景地面前，先在试玩服务端对受影响区打向下射线，确认其下仍有地面。
- **编辑态读不到的设置**：编辑态 `editor:GetService('PhysicsService')` 为 nil，地面高度只能在试玩服务端用射线测；编辑态读 World 的 `AOIType`、`StreamingEnabled` 得到 nil，流式加载设置无法经 CLI 确认。
- **场景枚举**：编辑器侧执行 [ADR-0035](../adr/0035-editor-sdk-enumeration-broken-and-exec-bypass.md) 的四条硬边界（绕过合同），试玩服务端的例外也写在那里。
- **检索失败**：`docs search` 报 HTTP 500 等服务端错误时（0.20.12 的 `editor-api` docset 出现过），改查 `manual` 或编辑器在线时的 `api search-editor` / `api get-editor`。
- **检索范围**：本图是世界版（SE，`status --json` 的 `editor_mode: "se"`）。`docs search` 查不到问题里的词时先问用户指什么，等确认后再换库或换方向，不自行换库；原点版（FS）的库只在用户点名「原点版 / FS」时才查。
- **模型动画验收**：导入、播放与画面判定读[美术资产概要「模型动画导入与播放」](../art-asset-overview.md#模型动画导入与播放)。
- **验收判据读产物**：判据不读工具或探针自己打印的摘要——探针统计缺失时只从根节点 `FindFirstChild` 取（不递归），嵌套子节点永远「缺失」，这类摘要本身也要有测试。判据落在产物上：节点树回读、`data/UINodes.lua`、`log grep` 的实打实行。`log grep` 追最新进展加 `--max-matches` 大值再 `tail`（默认只留最旧 50 条）；等长时状态一条命令只查一次，别塞 `sleep` 循环（无输出，超时等于零信息），由调用方重试或用后台任务。
- **sync 回灌的引擎生成物**：`sync` 会把 `EggyAPI.lua` 这样的引擎生成物一并带回仓库；与本次改动无关时单独 `git restore`，并在验收记录里点名，别让无关的 API 刷新混进功能分支。
- **`code push --delete` 逐条超时**：地图侧多出本地已删的脚本时，`code push --delete --yes` 常常只删掉一条就报 `EDITOR_UNREACHABLE: script_delete failed: Timeout waiting for response to script_delete`（`applied before failure: none`），但那条删除其实已经生效。复核用 `code diff` 的 `only-on-map`，它每轮减一；重复执行直到 0 即可（2026-11-24 清理改名遗留的 8 条实测，`--timeout 60` 不改变表现）。
- **本地模拟多人不可用**：截至编辑器 1.0.37 / editor-cli 0.20.17，没有「单次试玩加入多个虚拟玩家、生成真实 `Player`」的入口；NPC（`World:CreateUnit` 的 `EggyUnit`）不能替代真实玩家，多人验收必须真实第二客户端。结论与未验证项见 [ADR-0040](../adr/0040-local-multiplayer-not-simulatable-in-editor.md)。
