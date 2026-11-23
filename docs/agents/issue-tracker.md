# Issue tracker：GitHub

单据在 GitHub `qinyuanj/se-fish`，用 `gh`。每次带 `-R qinyuanj/se-fish`。动手前 `gh api user --jq .login` 须为 `qinyuanj`。

> **工单已清空，验收面改为 [条款矩阵](../acceptance/README.md)**。能落成条款的走 [TEMPLATE.md](../acceptance/TEMPLATE.md)，已关闭旧单的未完成项见 [legacy-ledger.md](../acceptance/legacy-ledger.md)。

## 本仓和 `gh` 默认的差别

- 多行正文写 UTF-8 文件，用 `--body-file` 提交，再回读正文、标签和状态。正文文件按 [开发工作流](workflow.md) 的临时产物处理。
- 本机 gh 2.45：`gh issue view` 不带 `--json`（含 `--comments`）会去查已下线的 Projects (classic)，GraphQL 报错、单取不回来。读单带 `--json title,body,labels,state,comments`。
- 关闭前先评论验收结果，再 `gh issue close <编号> -R qinyuanj/se-fish --reason completed`；不再处理用 `--reason "not planned"`。PR 与 issue 共用编号，读之前先确认类型。

skill 要求「发布到 issue tracker」时在本仓库建 issue，默认 `ready-for-agent`，除非另有指示。标签见 [triage-labels.md](triage-labels.md)。

## Wayfinding

地图、`wayfinder:*`、frontier、认领、结案的形状见 wayfinder 技能。本机 gh 2.45 没有原生 sub-issue 与 blocking：子 ticket 正文顶部写 `Part of #<地图编号>`，阻塞写 `Blocked by #<编号>`，blocker 都关闭才推进。认领是会话第一次写：`gh issue edit <编号> -R qinyuanj/se-fish --add-assignee @me`。结案后把一句结论追加到地图的 Decisions-so-far。`wayfinder:*` 用前先查标签，没有就建。
