# 0002 Full native Busted migration

**Status**: accepted

结束状态（#93）：Lua 侧已完成全量切换——`tests/run.lua`、`tests/run_migration.lua`、`tests/lanes.lua` 与 vendored LuaUnit 已删除，根目录 `.busted` 是唯一 Lua 测试入口；测试文件放 `tests/native/`（slow 车道 `tests/native/slow/`），共享夹具放 `tests/support/`，手工探针放 `tests/probes/`（不入任何车道）。覆盖率与车道的当前口径（#146）：项目自建质量工具与 Python 回归已删除，质量工具交给 uml-viewer 标准工具（范围在 `uml-quality.json` 的 `standardTools`）；`.busted` 的 `default` 与 `full` 相同，crapper 不带 `--run` 读 `default`，覆盖率含 slow 车道；mutator 经 `mutatorOptions` 的 `--busted-task fast` 每个变异体只跑 fast。详见 [开发工作流](../agents/workflow.md)「工具链」与「人工验收」。

se-fish 全部 Lua 测试全面改写为原生 Busted：116 个测试文件、约 1,297 个案例、7,191 处 LuaUnit 断言，移除 LuaUnit 依赖及桥接层。断言深比较/身份比较/容差语义、执行顺序、共享环境与失败清理行为在迁移后保留；`.busted` 定义 full（coverage）与 fast（mutation）命名任务；Python tooling 回归独立保留。

备选方案（拒绝）：Busted 调度 + LuaUnit 断言桥接——长期保留两套断言体系，语义复杂度不减反增；仅保留 LuaUnit——标准工具默认 runner 为 Busted，配置适配负担持续存在。

后果：测试 runner 的 Windows `dir` 发现与全局加载由 Busted 发现机制替换；`.busted` 配置替代 `tests/run.lua`；现有部署、同步等 Windows 专用 tooling/slow 测试明确标注适用平台，跨平台改造另行处理；Busted、LuaCov、LCOV reporter 纳入固定依赖安装与 doctor 契约。
