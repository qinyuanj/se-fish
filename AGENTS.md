# 钓鱼怎么这么危险啊喂！

蛋仔派对世界版（状态同步，SE）地图的 Lua 源码。

**语言**：思考、进度说明与最终回复一律用中文；产出物见文末「团队协作约定」。

## 按任务读取

- **探索代码**：先读 `docs/agents/domain.md`，按其中指引读取领域资料；ADR 放在 `docs/adr/`。
- **玩法与术语**：玩法与系统设计以 `docs/design/` 为准（策划案原文与数值表）；起名或写玩家可见文案前查 `GLOSSARY.md`。
- **技术方案**：涉及平台能力、工具链或生命周期前，先读 `docs/adr/` 里相关条目，剩余能力缺口与待实测项见 [#323](https://github.com/qinyuanj/se-fish/issues/323)；策划案内部矛盾与数值缺口一律记在 [`docs/to-questionnaire-策划案内部矛盾.md`](docs/to-questionnaire-策划案内部矛盾.md)（未定的题），定案后移进 [策划案已确认结论](docs/策划案已确认结论.md)。
- **编码与审查**：编写或审查 SE 业务 Lua 前，读 `CODING_STANDARDS.md`。
- **开发工作流**：修改代码、运行测试、同步宿主或操作编辑器前，以及整理过程产物时，读 `docs/agents/workflow.md`。
- **截图**：取证统一走 `lua tools/cli.lua screenshot`，细节见 `docs/agents/editor-cli.md`「截图」条。
- **架构导航**：需要模块依赖全景、评估改动影响或从图上操作时，打开 dsh-uml-viewer 插件面板；图由根目录 `policy.edn` 生成到 `docs/uml/se-fish.edn`（不要手编），操作规则由插件注入。
- **架构分层**：新增模块、调整模块职责或依赖方向前，读 `docs/architecture.md`；层归属与门禁唯一声明在 `tools/arch_policy.lua`。
- **spoke 运行时**：写或评审调用 `common.packages.spoke.*` 或 `common.packages.spoke_eggy.*` 的代码前，读 `.dsh/skills/spoke/`（库与技能都是上游 spoke 仓库的整包拷贝，两边都不就地修改）；宿主包独立成包、依赖单向，见 [ADR-0024](docs/adr/0024-introduce-spoke-eggy-host-package.md)。技能 `references/eggy-integration.md` 允许消费方自选 submodule 或纯拷贝：本仓取纯拷贝，SHA 记账在 [packages 参考](docs/packages-reference.md)。
- **美术资产**：定位美术工作区文件、用 Blender 或 Meshy 前读 `docs/agents/art-pipeline.md`；验收资产前读 `docs/art-asset-overview.md`「验收」，尺寸口径见 `docs/adr/0004-fish-asset-scale.md`。Blender 只走无头：一律 `lua tools/cli.lua blender`，跳过上游 blender-* skill 的 Live/MCP 段落，见 `docs/adr/0009-blender-headless-only.md`。
- **验收与条款**：判断某项做完没有、新增待办或收口工单前，先读 `docs/acceptance/README.md`（条款矩阵入口）；七列格式与新增条款的受控入口见 `docs/acceptance/TEMPLATE.md`，已关闭旧单的未完成项去向见 `docs/acceptance/legacy-ledger.md`。
- **Issue**：读写前看 `docs/agents/issue-tracker.md`；打 triage 标签前看 `docs/agents/triage-labels.md`。单据在 GitHub `qinyuanj/se-fish`，用 `gh` 操作。

## 修改边界

- **服务端宿主**：宿主服务放在 `server/` 对应职责模块，标记 `SpokeHost = true` 并由 `server/main.lua` 显式注入 `ServerRuntime`；运行时统一管理启动、玩家加入/离场、帧更新与清理，不恢复 `MgrMap`。
- **界面**：视图放在 `client/Views/`，由 `RootView` 的 Spoke 视图树统一建点和清理，经 `ClientStore` 读取状态；不恢复 `MgrGameUI` 或旧 `ScreenHandlers` 双轨入口。
- **共享配置**：数值配置集中在 `common/GameCfg.lua`；技能配置在 `GameCfg.Ability`。
- **生成内容**：`data/` 只读，修改须回编辑器重新导出，再用 `sync` 回灌；`unit_scripts/` 由引擎生成，不在本仓库管理。

<!-- [teamai:culture:start] -->
<!-- DO NOT EDIT: This section is auto-managed by teamai -->

## Team Culture (teamai)

## Team: netease

# 团队协作约定

适用于所有任务。

1. **思考与回复使用中文。**
2. **产出物用中文。** 仓库文档、代码注释、commit 信息、PR 描述和写给 agent 的文件使用中文；代码标识符与文件名使用英文。
3. **专有名词与代码原样保留。** 工具名、skill 名、命令、路径和代码片段不翻译。Matt skills 保持上游英文原文。
4. **用户明确要求其他语言时以用户为准。** 引用英文原文时保留原文，并附中文说明。

<!-- [teamai:culture:end] -->

<!-- [teamai:recall-rules:start] -->
<!-- DO NOT EDIT: This section is auto-managed by teamai -->

## Team Knowledge Recall (teamai)

**Before** starting a task that involves code changes, debugging,
or design decisions, you **SHOULD** search the team knowledge base
(learnings, docs, skills, rules and the codebase wiki) by running:

```bash
teamai recall "<3-6 high-signal keywords from the task>"
```

unless one of these skip conditions applies:

1. **User already provided context** — the user referenced specific files,
   gave a solution, or said "the answer is in this directory/file".
2. **Local files have the answer** — the task info is directly available
   from the current workspace (e.g. fixing an obvious bug in the current file).
3. **Trivial/local change** — small modifications to known files (typo fix,
   parameter tweak, formatting) that need no additional knowledge.
4. **Task domain is outside team knowledge coverage** — the task is
   unrelated to this team's systems/workflows. `teamai recall --check "<keywords>"`
   answers `RELEVANT` or `NOT_RELEVANT` without reading anything.

Matching is lexical: give each domain term in every language the team
writes in, and keep names, identifiers, error codes and paths as they are.
Read the files recall returns for their full content. If its output contains
`Nothing was searched:`, show that line to the user instead of concluding the
team has no knowledge on the topic.

<!-- [teamai:recall-rules:end] -->
