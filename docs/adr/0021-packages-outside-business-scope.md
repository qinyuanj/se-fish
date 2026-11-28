# 0021 `packages/` 退出业务范围：质量工具与架构图都不度量、不画包

**Status**: superseded by [ADR-0043](0043-packages-inside-business-scope.md)（2026-11-28）

此前三端 `packages/` 曾被收进业务范围，理由是「只有一个业务范围」，让图与质量工具对同一份源码说话；代价照常接受——包内缺 mutation 快照按每个函数算一次失败试验，图上显红。

引入第一个自研包 `spoke` 之后，这个口径撑不住了。此前拒绝给包跑基线的唯一理由是「官方作者版包整包升级即作废、包内无版本号」；自研包受本仓版本控制，这条理由对它不成立。要沿用就得另立「官方包不度量、自研包度量」一套分裂口径，而这正是单一业务范围当初要消灭的东西。

决定：

- **业务范围不含任何 `packages/` 子树**：`uml-quality.json` 的 `standardTools.exclude` 增加 `client/packages`、`common/packages`、`server/packages`；CRAP、mutation、DRY 都不度量包。
- **架构图同进退**：`policy.edn` 的 `:exclude` 增加 `"packages"`，并恢复 `:foreign [client.packages common.packages server.packages]`；业务对包的 `require` 在图上收成外部椭圆。
- **分层门禁不跟着退**：`tools/arch_policy.lua` 仍扫描三端全部 `.lua`、仍要求每个模块可分类，L6 声明保留，包内循环豁免照旧。

备选方案（拒绝）：

1. **只退质量工具、图保留**：包内类在图上没有任何指标，于是全红；「图与工具各说各的范围」的问题会反向复发一次。
2. **按包类型分治**（官方包不度量、自研包度量）：比没有口径更糟；而且自研包同样跑不出有意义的基线——spoke 本身在本仓不跑测试（[ADR-0022](0022-introduce-spoke-runtime.md)）。

后果：

- 包内热点与包内依赖从图上消失。需要时另立 policy 生成第二份图，不在本轮做。
- 图上多出「端盒子 → 外部椭圆」的箭头；新增包不需要改 policy。
- 术语「业务范围」改为「不含任何 `packages/` 子树」。
- `docs/uml/se-fish.edn` 需用 `uml_ir` 重新生成后才反映本决策。