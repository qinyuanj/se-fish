# 0018 删除 pre-commit hook，提交时不再自动检查

**Status**: accepted（修改 [ADR-0017](0017-windows-native-only.md) 中「唯一非 Windows 原生例外」一条，该例外随之消失）

本仓此前在 `tools/hooks/pre-commit` 里做两件事：对暂存区每个 `.lua` 取暂存内容做 `loadfile`，以及暂存区含 `.lua`/`.busted` 时经 CLI 跑 `lua tools/cli.lua test fast`。它是全仓唯一的提交时自动检查，也是 [ADR-0017](0017-windows-native-only.md) 里唯一的非 Windows 原生例外（`#!/bin/sh`，由 Git for Windows 执行）。

## 决定

整个机制删除：`tools/hooks/pre-commit`、`tools/hooks/shim`、每个克隆一次的安装步骤、`tests/native/slow/pre_commit_hook_test.lua`（296 行），以及[开发工作流](../agents/workflow.md) 里「pre-commit hook」整节与完成判据表对应行。**不挂任何替代钩子**（不挂 `pre-push`，不挂 `post-commit`）。

## 理由

1. **信号价值不足**：`loadfile` 查的是暂存内容，fast 跑的是工作区；部分暂存（`git add -p`、暂存后又改）时两者不一致，它给的是一份「看起来检查过」的安全感。而语法错误在 `test fast` 启动的头一秒就会暴露。
2. **成本集中在一处**：82 行 hook + 229 字节 shim + 296 行回归测试 + 每克隆一次的安装步骤 + 一条架构例外，全部为了一个秒级的检查。
3. **耗时账**：`pre_commit_hook_test` 单项 **15.016 s**，占 full 车道的 **43%**（见[耗时基线](../test-timing-baseline.md)）。删除后 full 从 34.5 s 降到 20.656 s。

## 后果

- 本仓**没有任何提交时自动检查，也没有 CI**（历来没有，且不新增）。提交前是否跑 `test fast` 由 agent 与人自行执行；完成判据表里的每一项都由 agent 显式执行。
- [ADR-0017](0017-windows-native-only.md) 的「唯一非 Windows 原生例外」消失：仓库里不再有任何 `#!/bin/sh` 脚本。
- `tools/hooks/` 目录整体删除。
- 坏提交（含语法错）可以静默进分支，直到下一次有人跑 `test fast` 才发现。这是明确认领的代价。

## 备选方案（拒绝）

1. **只删跑 fast 那段、保留 `loadfile`**：付着 296 行测试 + 安装步骤 + 非原生例外的全部成本，只换一个与提交内容和工作区都可能不一致的语法检查。
2. **改挂 `pre-push`**：一次 push 常含多个提交，失败后回滚的心理成本更高；本机 push 频率低，拦在那一处的收益小于成本。
3. **改挂 `post-commit`（不阻塞）**：拦不住任何东西，价值只剩提醒，而提醒可以直接写进纪律。
4. **保留 hook 但去掉 `loadfile`**：「提交时同步阻塞」本身就是要去掉的那件事，与检查内容无关。
