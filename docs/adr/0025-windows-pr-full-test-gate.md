# 0025 引入 Windows PR full 测试门禁

**Status**: accepted（修改 [ADR-0018](0018-delete-pre-commit-hook.md) 的「不新增 CI」后果，不恢复本地提交钩子）

PR #237 的修复有能红的守卫和完整宿主证据，但 GitHub 没有任何检查；测试结果只存在于 agent 报告，合入是否执行取决于自觉。ADR-0018 删除的是信号错配、维护成本高的本地 pre-commit hook，不需要因此永久排除针对推送内容的 CI。

决定：

- 新增 `.github/workflows/test.yml`，在 PR 与 `main` 推送上运行同一个 `test / full` 检查，并将它设为 `main` 的 required status check。
- runner 固定 `windows-latest`，遵守 [ADR-0017](0017-windows-native-only.md) 的 Windows 原生唯一测试环境；安装 Lua 5.4.6、LuaRocks 3.12.2、Busted 2.3.0-1，与当前仓库检出所用版本一致。
- 测试入口仍是 `lua tools/cli.lua test full`，不新增第二套测试命令或 Linux 专用兼容层。
- CI 只替代「提交后是否记得跑 full」这一机械步骤。部署、strict validate、宿主试玩、真实设备验收仍按开发工作流逐项执行，不因 full 变绿而省略。

后果：

- PR 的测试内容与合入内容一致，避免本地 pre-commit 曾有的暂存区与工作区错配。
- 坏提交会在 PR 上直接暴露；main 的直接推送也运行 full，但不能绕过 PR 门禁时仍受分支保护约束。
- 外部 action 与 runner 属于新增供应链和维护面；版本在 workflow 中显式声明，升级时核对 Lua 5.4 与 Windows 原生约束。
