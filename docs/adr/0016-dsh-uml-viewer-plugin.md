# 0016 架构图与质量工具改用 DSH 插件 dsh-uml-viewer

**Status**: accepted（取代 [ADR-0001](0001-standard-viewer-integration.md) 与 [ADR-0007](0007-viewer-herdr-version-floor.md)；部分取代 [ADR-0011](0011-cli-single-entry-standard-quality-no-acceptance.md) 中 `./uml` 入口与「质量工具只由人运行」的口径）

此前看图和跑质量工具都走项目内安装的 uml-viewer：人按上游文档执行 `get-uml-viewer`，安装器在仓库根生成 `./uml` 入口，把 viewer 与 crapper / mutator / dryer clone 到 `.uml-viewer/`，并在 `.gitignore` 追加 UML-VIEWER 区块。图上操作经 Herdr companion 转发：viewer 写邮箱，companion 消费后调用 `./uml crap|mutate|ir`，重启 viewer 还要走 `:quit-for-restart` → `./uml --restart` 协议。这条链路有几个问题：

- **每个检出都要装**：`.uml-viewer/` 不共享，新 worktree 想看图或跑质量工具得先由人安装一遍。
- **版本由项目钉**：viewer 与 Herdr 的版本耦合要项目跟进，ADR-0007 就是为一次 Herdr 升级改 pin 重装。
- **规则写在仓库里**：`docs/agents/workflow.md` 有一大段 companion 后端、重启协议与 `quality-result.json` 核对规则，靠 agent 读文档执行，和上游行为容易漂移。

决定：改用 DSH 插件 dsh-uml-viewer。插件自带 viewer 二进制和标准质量工具，在 DSH 面板里看图；图上操作以面板请求的形式交给当前会话的 agent，由 agent 调用插件工具 `uml_ir`、`uml_crap`、`uml_mutate`、`uml_dry`、`uml_display` 执行。

- **项目数据不变**：根目录 `policy.edn`（含 `:proposals`）、生成图 `docs/uml/se-fish.edn`、`.metrics/`（`crap.edn`、`mutate/*.edn`、`dry.edn`）与 `uml-quality.json` 的 `standardTools` 原样保留，插件继续读取，业务范围仍只在 `uml-quality.json` 声明。
- **规则由插件注入**：面板请求的处理顺序（质量 → `uml_ir` → `uml_display`）、`validResult` 校验、提案与 `:omit` 的编辑方式，都由插件在打开面板的会话里注入。仓库文档不再复述，只写项目口径（业务范围、指标为红的含义、不设门槛）。
- **质量工具的触发方**：由人在面板上发起，agent 只在收到面板请求时调用对应插件工具，不自行运行。ADR-0011 的「CLI 不包装质量工具」不变。
- **清理旧流程**：删除仓库根的 `./uml` 和 `.gitignore` 的 UML-VIEWER 区块；`AGENTS.md`、`docs/agents/workflow.md`、`docs/agents/domain.md`、`docs/architecture.md` 中的 `./uml`、Herdr companion、重启协议与 `get-uml-viewer` 安装说明删除或改写为插件口径。

备选方案（拒绝）：

1. **保留 `./uml` 与插件并存**：两套入口写同一份 `.metrics/` 和图文件，规则互相冲突（旧文档要求核对 `.uml-viewer/quality-result.json`，插件以工具返回记录为准）。
2. **CLI 包装插件工具**：插件工具只在 DSH 会话里可用，包一层没有可调用的对象。

后果：

- 看图与图上操作需要 DSH 会话并打开插件面板；在 DSH 之外不再有项目内的看图入口。
- worktree 无需为质量工具做任何准备，`worktree-init` 保持不准备。
- Herdr 不再是本仓库的依赖；开发端是否继续用 Herdr 与本仓库无关。
- 标准工具的环境准备（含 crapper 要求的 cluacov 1.0.0）仍由人完成，改按插件文档。
- ADR-0001、0007 只作历史记录；文中的 `./uml`、`uml.ps1`、companion 与 Herdr 版本约定不再适用。
