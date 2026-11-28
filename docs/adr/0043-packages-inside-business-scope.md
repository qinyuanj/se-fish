# 0043 `packages/` 重新纳入业务范围：架构图与质量工具统一度量

**Status**: accepted（2026-11-28；取代原 ADR-0021）

三端 `packages/` 同时包含官方整包与本仓维护的自研包。原 ADR-0021 曾将包目录排除出架构图与质量工具，导致包内模块、真实依赖与热点均不可见；为将这些代码重新纳入 UML 管理，重开并取代原范围决策。

## 决定

- **架构图直接建类**：`policy.edn` 删除 `:exclude ["packages"]` 与 `:foreign [client.packages common.packages server.packages]`。三端源码根原本已覆盖包目录，包内模块与其依赖边因此直接进入 `docs/uml/se-fish.edn`，不再收成外部椭圆。
- **质量工具使用同一范围**：`uml-quality.json` 的 `standardTools.exclude` 只保留 `server/_trigger`，CRAP、mutation、DRY 均扫描三端 `packages/`。
- **分层门禁不变**：三端包仍属 L6，`tools/arch_policy.lua` 的层归属、包到业务依赖禁令与包内循环豁免均不变。
- **包维护边界不变**：纳入 UML 管理只改变观察与度量范围，不授权就地修改上游整包；同步与维护规则仍以 [ADR-0022](0022-introduce-spoke-runtime.md) 和 [packages 参考](../packages-reference.md) 为准。

## 备选方案（拒绝）

1. **只画包、不跑质量工具**：图与指标重新各说各的范围，包内类会因没有指标而显示红色，却无法用同范围的质量结果解释。
2. **保留 `:foreign` 同时建类**：同一依赖会被人为分流到外部节点，无法准确表达包内结构与业务到包的真实依赖。
3. **按包类型分治（官方包不度量、自研包度量）**：再次制造分裂口径，且自研包上游单测本就不进本仓（[ADR-0022](0022-introduce-spoke-runtime.md)）。

## 后果

- 包内热点、包内依赖和业务到包的依赖在架构图上可见；缺 CRAP 或 mutation 指标的包内类会按插件既有规则显示红色，这是待补指标，不再通过排除目录消除。
- 质量快照的文件数与耗时随包源码纳入而增加；结果仍以插件发布的 `validResult`、实际退出码和 `.metrics/` 快照为准。
- `docs/uml/se-fish.edn` 由 `uml_ir` 重新生成，不手编。
