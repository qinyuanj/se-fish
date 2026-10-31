# 0014 编辑器分发的 AI 资源不作事实源

**Status**: accepted

编辑器经 `env-res` 分发一套 AI 资源：`~/.eggitor/codex/se/rules/eggy-se.mdc` 由 SessionStart hook 注入，8 个 `eggy-se-*` / `eggy-*` skill 软链进 `~/.codex/skills/`。2026-10-31 用 CLI 0.20.13 的 `help export` 对照，并考古 115 个历史会话，发现问题主要是**文档跑在 CLI 前面**，而不是简单的过期：`screenshot offscreen`、`screenshot --format` 还没发布，却被写成默认做法；截图在遮挡或最小化时仍能出图、`editor-unit list/search` 可用等说法被实测推翻；判脏闸门没有排除非业务目录；`map save`、`preflight`、`preset` 等常用命令完全没写到。注入规则的优先级高于按需读取的仓库文档，所以 `docs/agents/workflow.md` 里已有的勘误也被压过。

决定：命令与参数以 CLI 自带的 `--help` / `help export` 为准，工作流与项目实测以 `docs/agents/workflow.md` 为准；两者与编辑器分发的资源冲突时，以前两者为准。SessionStart hook 只注入一段固定的最小文本（CLI 路径与 WSL 调用方式、上面这条优先级、动手前读 `workflow.md`、`docs search` 别名表），不再读取 mdc。上游 skill 全部保留可用，`workflow.md` 只记已确认的勘误，不复述 skill 里正确的部分。

备选方案（拒绝）：继续用正则从 mdc 里剔除错误行——每次上游出新错都要追加补丁，而且注入内容随上游升级悄悄变化；fork 上游 skill 自己维护——维护成本高，上游修好后还得手工合并；禁用上游 skill——会丢掉 `references/` 里仍然有用的工作流与 API 资料。

后果：编辑器升级带来的新规则不会再自动进入会话，需要自己留意 `env-res` 的更新；勘误同时整理给 eggitor 团队，上游修好一条，就从 `workflow.md` 删掉对应的一条。
