# 0011 CLI 为唯一公开工具入口，质量交给 uml-viewer 标准工具，删除 acceptance4lua

**Status**: accepted（部分取代 [ADR-0010](0010-packages-as-business-code.md) 中业务范围的出处）

此前在 se-fish 跑检查要记多个形态各异的入口：裸 `busted --run=fast|full`、项目自建的 Python 质量入口 `tools/quality/project`、bash 验收脚本 `run_acceptance.sh`，以及只收运维子命令的 `tools/cli.lua`。质量工具在仓库内重复实现了 uml-viewer 标准工具已有的能力，Gherkin 验收（acceptance4lua）与 busted 用例高度重合，art 车道又和美术校验脚本核对同一份报告（#144）。本 ADR 记录收口时的三项决定。

## 1. `tools/cli.lua` 是唯一公开工具入口

agent 与人日常反复调用的检查与运维命令都经 `lua5.4 tools/cli.lua <子命令>`，包括新增的 `test [fast|full] [-- <busted 参数>...]`；pre-commit hook 也经它跑 fast 车道。入口强制 Lua 5.4，由脚本自身位置推导仓库根，子命令接口为 `main(args, env) -> 退出码`。不进清单的模块及理由写在 CLI 头注释。

- **退出码 3 与 ADR-0008 并存**：0 成功 / 1 业务失败 / 2 用法错误 / 3 平台或工具不可用（busted 缺失、`editor-cli.exe` 或 Blender 找不到、WSL interop 失败）。退出码 3 让调用方分清「该查环境」还是「该改代码」。`test` 不原样透传 busted 的退出码：busted 的退出码是失败数加错误数，恰好 3 个失败会被误读成「busted 不可用」，所以 busted 非 0 一律收成 1，只有 busted 缺失才是 3。[ADR-0008](0008-wsl-development-windows-deploy.md) 的「编辑器没装或没打开本图 → 打印跳过并返回 0」不变：那是 `deploy` 有意设计的可跳过收尾，镜像本身已经成功，不算工具不可用。
- **不照搬 monopoly 的 `packages/<pkg>/cli` + foundation 结构**：本仓库只有七个路由模块，顶层路由表加平铺模块足以表达封闭命令集；多层包结构和非路由白名单 guard 只增加样板，没有对应的复用收益。
- **CLI 不包装 `./uml`**：`./uml` 由 uml-viewer 安装器生成，命令集与参数随上游演进；包一层只会多一份要同步的转发，且质量工具只由人运行，不需要进 agent 的入口。

## 2. 质量工具交给 uml-viewer 标准工具，删除项目自建实现

CRAP、mutation、DRY 改用 uml-viewer 自带的 crapper / mutator / dryer，由人运行 `./uml crap|mutate|dry`。项目只在根目录 `uml-quality.json` 的 `standardTools` 声明业务范围（`sourceRoots` 三端、`exclude` 为 `server/_trigger`）与选项；整个 `tools/quality/`（安装器、覆盖率 / CRAP / mutation / DRY 实现、复验脚本、Python 回归）及其 Lua 测试删除。

- **`.busted` 的 `default` 改为与 `full` 相同**：crapper 列测试文件时不带 `--run`，读的是 `default`；不改的话覆盖率会漏掉 slow 车道，CRAP 失真。代价是直接敲裸 `busted` 得到 full，日常 fast 须经 `lua5.4 tools/cli.lua test` 显式指定。
- **`mutatorOptions` 取 `--busted-task fast`**：mutator 经 uml-viewer 透传的 `--busted-task` 选任务；每个变异体只跑 fast，差分 mutation 的耗时不随 slow 车道膨胀。被 slow 用例独占覆盖的代码可能因此多出存活变异体，已接受。

## 3. 删除 acceptance4lua

验收运行器、bootstrap、步骤文件、全部 feature（gameplay 与 art 车道）以及只被 art 步骤使用的美术报告与网格预算读取模块一并删除。玩法回归只由 busted 承担，被删 feature 的场景不改写为 busted 用例（它们与现有 busted 用例高度重合）；美术离线交付门槛只看仓库外美术校验脚本的报告（`failures` 为空，含网格封闭性硬门槛）。

因此不再需要 `verify` 子命令与「代码收尾门」：代码收尾只剩 `lua5.4 tools/cli.lua test full` 一条命令，美术校验是另一条独立判据，二者无需编排。`acceptance-slot`（试玩验收存档槽）与 Gherkin 无关，保留。

备选方案（拒绝）：

1. **保留 art 车道、只删 gameplay 车道**：art 车道断言的是校验脚本已经判过的同一份报告，只是重复读一遍；为此要维持 acceptance4lua、bootstrap 与 `.toolcache` 整条依赖链。
2. **`verify` 编排 test full 与验收**：验收删除后只剩一项检查，编排层没有内容可装。

后果：

- 完成判据表只列 `test full`、pre-commit hook 与美术校验（及原有的部署、试玩、code-review 项），见 [开发工作流](../agents/workflow.md)「完成判据」。
- worktree 初始化不再准备 `.toolcache`；`.gitignore` 的 `/.toolcache/` 条目移除。
- 质量工具首次运行前的环境准备（含 crapper 要求的 cluacov 1.0.0）按 uml-viewer 文档由人完成。
