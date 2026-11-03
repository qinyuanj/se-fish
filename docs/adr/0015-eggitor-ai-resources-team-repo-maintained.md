# 0015 蛋仔 AI 环境迁入团队仓维护

**Status**: proposed（通过后取代 [ADR-0014](0014-eggitor-ai-resources-not-source-of-truth.md)）

编辑器经 `env-res` 分发两套 AI 环境，放在 `~/.eggitor/codex/` 下：`se/`（状态同步）有 8 个 `eggy-*` / `eggy-se-*` skill 和 `eggy-se.mdc`，`fs/`（帧同步）有 7 个 `eggy-fs-*` skill 和 `eggy-fs.mdc`。两套共用一个 SessionStart hook，它按工程 `eggy.json` 的 `isSEMap` 判断模式，注入对应的 mdc，并列出另一模式的 skill 禁止使用。本仓开发端把 SE skill 软链进 `~/.codex/skills/`，hook 换成了只注入固定文本的精简版。ADR-0014 的做法是保留上游原样，勘误记在 `docs/agents/workflow.md`，同时整理给 eggitor 团队（#165）。运行下来有三个问题：

- **上游修不动**：skill 和 mdc 停在 2026-10-14、15 日的版本，CLI 已经到了 0.20.13。#165 列的错误在 2026-11-03 复测时大多还在；`editor-unit` 已在 0.20.13 修好，文档也没跟上。上游没有反馈渠道，也没有修复时间表。
- **勘误压不住原文**：agent 打开 skill 后照着原文执行，`workflow.md` 的勘误要在另一个文件里才看得到。会话考古里有多起“读了 skill 之后命令失败”。
- **只惠及一个仓**：勘误留在 se-fish 里，FS 工程（如 fs-monopoly）和团队其他成员用不到。两套 skill 与 mdc 落盘时间相同（2026-10-14、15），FS 那套同样没跟上 CLI。团队仓 `eggy/teamai-netease` 已经在给成员分发 skill 和协作约定，覆盖 Codex、Claude Code、Kimi Code 等工具。

决定：蛋仔 AI 环境改由团队仓 `eggy/teamai-netease` 维护和分发，编辑器分发的那份只作为上游来源。

- **范围**：SE 与 FS 一起迁，即 `~/.eggitor/codex/se/`、`~/.eggitor/codex/fs/` 下的全部 15 个 skill 和两份 mdc，以及 hook 的模式判定。编辑器本体和 `editor-cli` 不在范围内。
- **导入**：以 `env-res` 当前版本（SE `codemaker-se` 0.3.4、FS `codex-fs` 0.3.6）为基线，分别整体导入团队仓 `skills/eggy-se/` 与 `skills/eggy-fs/`，skill 名称保持不变（两套之间没有重名）。上游原样快照放在不分发的 `upstream/eggy/`，版本和逐文件哈希记在 `eggy-upstream.json`。这套布局与同步脚本沿用团队仓 9 月的做法，细节以团队仓配套 ADR 为准。
- **修订**：#165 的勘误和 `workflow.md`「编辑器 CLI 取证」里的通用条目直接改进 SE 副本；FS 的勘误由 FS 工程整理后改进 FS 副本。都走分支加 PR，由 reviewer 审核。两套共用的 CLI 行为（截图、`--editor-instance`、`map save` 等）两边一起改。命令和参数细节仍以 CLI 的 `--help` / `help export` 为准，skill 只写工作流和踩坑。没有发布的能力不写进默认流程。
- **规则与 hook**：注入文本改由团队仓维护，SE、FS 各一份，内容沿用 ADR-0014 的精简版：CLI 路径与调用方式、优先级、该模式的 `docs search` 别名表（SE 用 `manual` 等四个库，FS 用 `fs-manual`、`fs-component`）。模式仍按 `eggy.json` 的 `isSEMap` 判定，无 `eggy.json` 时不注入。开发端不再读取上游的 mdc。
- **模式隔离**：teamai 把团队技能全量发给每个成员，SE 工程里也装着 FS skill，反之亦然。注入文本必须照上游 hook 的做法列出另一模式的 skill 并禁止使用，清单按团队仓目录生成，不手写。
- **分发**：成员通过 `teamai pull` 获取，注入 hook 由团队仓 `hooks/hooks.yaml` 下发到工程的 `.codex/hooks.json`（Codex、Claude Code 支持，Kimi 不支持）。开发端撤掉 `~/.codex/skills/` 下指向 `~/.eggitor` 的软链（SE 与 FS），删掉本仓自建的 `~/.codex/hooks/eggy-se-lean.mjs` 条目，避免同名重复或重复注入。`.ai_res_update_skip` 标记在 0.20.13 下没有证据仍然有效，不作依据；编辑器以后若把联接和 hook 装回来，发现时再处理。
- **上游跟进**：`env-res` 更新后，用同步脚本对照锁文件列出上游差异，人工挑选要合入的部分，在同一个 PR 里更新锁文件，不整体覆盖。
- **优先级**：CLI `--help` 优先于团队仓 skill，团队仓 skill 优先于编辑器分发的原文。`workflow.md` 只保留 se-fish 自身的项目实测，比如宿主目录、试玩闸门例外、多实例约定。

备选方案（拒绝）：

1. **维持 ADR-0014，只记勘误**：原文比勘误先被读到，错误会反复出现；勘误也没法给其他仓和其他成员用。
2. **在 se-fish 里 fork**：只有本仓受益，fs-monopoly 和其他成员还得各自再 fork 一份。
3. **等上游修复**：没有渠道，也没有时间表。0.20.12 到 0.20.13 之间 CLI 改了，文档没动。
4. **禁用上游 skill、不提供替代**：会丢掉 `references/` 里仍然有用的 API 与工作流资料。
5. **在团队仓自建重写**：团队仓 9 月就这么做过，实际效果不如上游原样，10-08 已整体撤掉。所以这次只在上游原样上做逐条的最小修订。

后果：

- 团队仓 README 写着“不维护蛋仔业务资源”，这次决定会推翻这一条，需要在团队仓另起配套 ADR，并修改 README 和 `scripts/check.py` 的下线资源检查。本 ADR 改为 accepted 时，同时把 ADR-0014 改成 `superseded by ADR-0015`。
- FS 那套还没像 #165 那样体检过，导入时只是原样搬入；它的勘误要由 FS 工程按同样的方法（`help export` 对照加会话考古）补做。
- 编辑器以外的 FS 工程也要换接入方式：撤软链、停用上游 hook、改用 `teamai pull`，各工程在自己的文档里记录。
- 团队承担跟进上游的成本：每次 `env-res` 更新都要比对和合并。不比对的话，编辑器新增的能力不会进入团队副本。
- `workflow.md`「蛋仔 hook 与技能（开发端接入）」整节改成 `teamai pull` 接入。「编辑器 CLI 取证」里的通用勘误迁出后删除，只留项目实测。
- #165 的收尾口径改为“团队仓修订合入”。转交 eggitor 团队变成可选，不再是关单条件。
- 编辑器分发的资源没有授权说明。沿用团队仓 9 月的口径“网易内部内容，非开源许可，仅限团队内部使用”，在团队仓 `ATTRIBUTION.md` 写明来源与版本，不另申请书面授权。
