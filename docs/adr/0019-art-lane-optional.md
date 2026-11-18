# 0019 美术 optional：Blender 用例移出 full 车道

**Status**: accepted（补充 [ADR-0009](0009-blender-headless-only.md)：无头 Blender 仍是唯一入口，但不再挂在每次交付的收尾门上）

美术资产交付不再是每次代码交付的必经项。此前 `tests/native/slow/blender_transport_test.lua` 跟着 full 车道每次收尾都跑，它起真 `blender.exe`，实测 **5.625 s**，是慢车道第二贵的文件（见[耗时基线](../test-timing-baseline.md)）。

## 决定

1. 新增 `art` 车道（`.busted` 的 `art` 任务，ROOT 为 `tests/native/art/`），`blender_transport_test.lua` 从 `tests/native/slow/` 移入。
2. `fast` / `full` / `default` 三个车道都**不含** art：`default` 是 crapper 采覆盖率读的任务，美术用例不在业务覆盖率口径内。
3. 完成判据表里的「美术资产交付」一行改为**按任务触发**，不再是无条件的收尾项。
4. `tools/blender.lua`、[美术资产管线](../agents/art-pipeline.md)、[ADR-0009](0009-blender-headless-only.md) 全部保留：美术能力不删，只是不再强制。

## 理由

「optional」变的是**触发条件**，不是能力。删掉工具链会让下次做美术时从零重建，而 `blender` 子命令与无头约束本身仍有长期价值。把用例移出 full 同时解决两件事：美术不卡每次交付的收尾门，保护也没丢——要用时 `lua tools/cli.lua test art` 一条命令。

## 后果

- full 车道再减 5.6 s。
- 美术回归不再被自动覆盖。改动 `tools/blender.lua` 或 `tools/cli.lua` 的 blender 分支时，必须显式跑 `test art`。
- `worktree-init` 仍复制上游 `blender-*` skill，与美术 optional 不冲突：那是 agent 的手册，不是每次交付的步骤。

## 备选方案（拒绝）

1. **删除整个美术工具链**（`tools/blender.lua` + 两个测试 + `worktree-init` 的 skill 复制 + ADR-0009 归档）：把能力拆了重来。美术工作随时可能恢复，而 `art-pipeline.md` 与 ADR-0009 是长期参考。
2. **保留在 full 里**：与「optional」直接矛盾——一个 optional 的东西每次交付都要付 5.6 s。
3. **只删测试、保留工具**：`blender` 子命令是起真进程的接缝，没有回归护栏等于把最容易静默坏掉的一层裸露在外。
