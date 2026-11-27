# 0041 部署范围的单文件 token 预算门禁

**Status**: accepted（2026-11-27）

## 背景

- agent 改码按文件读入、按文件改写：文件越大，一次放进上下文的内容越挤，截断、漏改与「只看到半截」的概率越高。ADR-0038 把 EmmyLua 立为**诊断型**门禁，管「对不对」；没有东西管「读不读得动」。
- 本仓 2026-11-27 实测（cl100k_base 计数，排除上游 `packages/`、`server/data/`、`_trigger/`、`tests/`、`tmp/`）：受管范围 138 个 Lua 文件共 374,927 tokens，其中 16 个超过 5500 tokens，最大 `common/cfg/fish.lua` 16,638。
- EmmyLua 没有体积类规则，这条**不能**写成 `.emmyrc.json` 诊断：emmylua-analyzer-rust 的 `DiagnosticCode` 共 58 个变体，没有任何一条与文件大小、行数或 token 有关；配置项里也没有体积阈值（`preloadFileSize` 是库文件预加载，与预算无关）。所以只能做成脚本规则。

## 决定

- **入口**：`lua tools/cli.lua size [--update-baseline|--report]`，模块 `tools/size_budget.lua`，纯 Lua 5.4，不引入外部工具与网络依赖（ADR-0017）。
- **口径**：`se-fish-budget-v1`，一个钉死常数的近似分词器（词元前 10 字节算 1 个、之后每 8 字节 +1；含换行的空白段 1 个；非 ASCII 码点各 1 个）。用 cl100k_base 校准：受管范围样本上与真实值的中位比值 1.01，P10–P90 0.95–1.08，极值 0.82–1.14。**阈值 5500 是这套口径下的数**，不声称等于任何模型的 token 数；换口径要同时改模块常数、本 ADR 与基线。
- **范围**：与 ADR-0038 的扫描范围一致——`client/`、`common/`、`server/`，排除 `packages/`（上游整包与自研包整包）、`data/`（引擎导出）、`_trigger/`（生成物）、`tests/`、`tmp/`。出货集 ≠ 受管集：这些文件随 `deploy` 进宿主目录，但不在本预算内。
- **基线**：`tools/size_baseline.txt`，逐行「相对路径:token 数」，记录首轮 16 个超限文件。门禁只拦**基线外**的新超限文件；`--update-baseline` 只在没有新超限时写入，因此基线只许收窄（棘轮），拒绝时退出码 2。
- **语义**：基线按成员判定，不按数值判定——基线内文件允许随业务增长（`common/game_cfg.lua` 按 AGENTS.md 是集中配置的注册表，本来就会长）；存量增长靠 review，本门禁只挡新增超限文件。要让某个文件回到预算内：先拆模块，再 `--update-baseline` 把条目删掉。
- **失败语义**：基线外超限 → 退出码 1；基线缺失且已有超限 → 1 并提示先 `--update-baseline`；用法错误 → 2。纯 Lua 实现，不使用退出码 3。
- **挂载**：pre-commit 依次 `test guards` → `size` → `emmylua`（`tools/git_hooks.lua` 的签名头机制让旧 hook 自动升级）；CI 在 `.github/workflows/test.yml` 的单一 `full` job 里、`test full` 之后、`emmylua` 之前运行；纯文档快速路径不跑。

## 后果

- `docs/agents/workflow.md` 的工具链与完成判据、`CODING_STANDARDS.md` 的「文件体积」条、`tools/git_hooks.lua` 的 pre-commit、CI 与 ADR 索引同一轮更新。
- 首轮把 16 个存量超限文件写进基线；此后新文件要么 ≤5500 tokens，要么当场拆模块。基线数值只是记录、不参与判定；文件拆分后重跑 `--update-baseline` 收紧名单。
- 口径是近似值：估算与真实 token 数有约 ±15% 的偏差带（极端中文表文件可到 -18%）。跨在阈值附近的文件可能比真实值略多或略少，规则按近似值执行，不为此再引入真实分词器。
- 与 ADR-0038 同形：都是「棘轮基线 + 单一 CLI 入口 + pre-commit/CI 双挂载」；两条门禁共用扫描范围，改扫描范围时两处一起改。

## 备选方案

- **接 tiktoken / 真实模型分词器**：需要 Python 或词表文件，破坏「纯 Lua + Windows 原生」的工具链（ADR-0017），pre-commit 上还要够快；实测 143 个文件一次扫描约 0.2 秒，纯 Lua 足够。
- **用行数代替 token**：行数在中文注释、长字符串表与配置表上失真，而 agent 的成本按 token 算；本仓 `common/cfg/fish.lua` 实测 2.64 字节/token，行数换算会低估这类文件。
- **零存量直接卡全仓**：22 个存量文件首日必红，最后只会关掉门禁；改用棘轮基线，与 ADR-0038 同一手法。
- **塞进 `.emmyrc.json`**：EmmyLua 没有体积规则，配置里无从表达，只能做成独立子命令。
