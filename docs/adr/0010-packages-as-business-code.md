# 0010 各端 packages/ 作为业务代码，质量工具与架构图共用业务范围

**Status**: accepted（取代 [ADR-0005](0005-packages-as-external.md)）

> **出处迁移（#146 / #147 追加）**：下文「以 `tools/quality/project.json` 的 `sources` 为准」已过时——`tools/quality/` 随项目自建质量工具一并删除。业务范围的定义不变，真源改为根目录 `uml-quality.json` 的 `standardTools`（`sourceRoots` 与 `exclude`），由 uml-viewer 标准工具读取；决策与取舍见 [ADR-0011](0011-cli-single-entry-standard-quality-no-acceptance.md)。下文提到的 `tools/quality/README.md` 同样已删除，当前口径见 [开发工作流](../agents/workflow.md)「架构图」。

ADR-0005 曾把三端 `packages/` 当作 vendor：`policy.edn` 的 `:exclude` 加 `"packages"`，业务代码对包的 `require` 用 `:foreign` 端级前缀收成外部椭圆。于是文档里出现了两个口径：架构图上只画「业务树」，质量工具读的是更大的「指标采集范围」，包内指标因为图上没有同名类，叠加时被忽略。之后 `c141b67` 把三端 packages 按真实命名空间建类（94 个包内模块），并移除了 `:foreign` 与 packages 排除；当前 `policy.edn` 的 `:exclude` 只剩 `_trigger`。包已经纳入业务代码开发，ADR-0005、`docs/agents/workflow.md`、`tools/quality/README.md` 与 `docs/packages-reference.md` 却仍用外部椭圆的口径（#126 决策 3）。

决定：

- **packages 按业务代码处理**：三端 `packages/` 在架构图上按真实命名空间建类，不设外部节点，`policy.edn` 不写 `:foreign`。
- **只有一个业务范围**：CRAP、mutation、DRY 与架构图共用同一个源码集合，即三端 `client/`、`common/`、`server/` 源码排除 `server/_trigger/`，含各端 `packages/`；以 `tools/quality/project.json` 的 `sources` 为准，`policy.edn` 的 `:exclude` 与之对齐。范围之外只有测试代码与 `server/_trigger/`。
- **术语统一**：只说「业务范围」，与 uml-viewer 上游 `0249322` 的定义一致；旧的两个说法列入 `GLOSSARY.md` 的 _Avoid_（#126 决策 7）。

代价：包内约 533 个函数没有 mutation 快照。viewer 按函数数加权聚合，缺快照的类按每个函数算一次失败试验，所以这些类在图上照常显红，并拉低所属端的聚合分数。这一点照常接受，不给 packages 跑 mutation 基线：三端 packages 是官方作者版包，升级方式是整包替换，包内没有版本号，一次升级就让基线作废，重跑成本每次都要重新付（#126 决策 12）。图上的红色只说明缺数据，不算工具失败。

备选方案（拒绝）：

1. **维持 ADR-0005 的外部节点**：包已经纳入业务代码开发（`c141b67`），继续藏起来就看不到包内依赖与热点；而且图与质量工具会再次各说各的范围，又要靠「指标记录被静默忽略」来弥合。
2. **给 packages 跑 mutate-all 基线**：能消掉红色，但整包升级后基线即作废；包内覆盖率很低（ADR-0005 实测 0.6%–5%），跑出来的大多是 uncovered，换来的信息很少。

后果：

- 架构图与质量工具对同一份源码说话，`.metrics` 里的包内记录都有对应类可上色，不再有「被忽略的记录」。
- 三端聚合分数会因包内缺快照而偏低。比较业务改动前后时，看具体类或差分 mutation 的结果，不看端级总分。
- `:omit` 的既有理由（无函数定义的配置与转发模块恒缺指标）不变，本 ADR 不动它。
- 包的升级、聚合入口与编辑器预设依赖仍以 [官方包接入参考](../packages-reference.md) 为准；该文档「架构图上的位置」一节已改为本口径。
