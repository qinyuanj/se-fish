# 架构决策记录（ADR）索引

按你要动的区域按需读取对应条目；不批量通读。若方案与既有 ADR 冲突，明说冲突并说明重开理由，不默默覆盖。

## 架构、代码与生命周期
- [0012](0012-six-layer-architecture.md) — 新增模块、调整目录职责或依赖方向：六层架构与依赖门禁。
- [0021](0021-packages-outside-business-scope.md) — 调整质量工具或架构图范围：三端 `packages/` 退出业务范围但保留分层门禁。
- [0022](0022-introduce-spoke-runtime.md) — 引用或同步 `spoke` / `spoke_eggy`：纯拷贝落位、同源同 SHA、不就地修改、单向依赖与 `is_alive` 边界。
- [0032](0032-spoke-native-lifecycle-architecture.md) — 改动服务端/客户端生命周期、Spoke 树、单位创建回收或官方包接入：三类树拓扑、双层 Phase、离场三步、跨树协作与单位所有权规则。
- [0033](0033-script-names-must-not-shadow-se-services.md) — 新建三端顶层目录或脚本文件：禁止与 SE 内置服务名同名。
- [0034](0034-self-written-code-snake-case.md) — 修改命名规范、豁免名单或命名门禁：文件与成员 snake_case、模块表 PascalCase、官方契约原样。

## 玩法系统与持久化
- [0013](0013-scene-markers-as-zone-geometry-source.md) — 改动七区坐标、水域、摆渡或交互点：编辑态场景标记校验导出只读几何表、可钓水域方案 A 与自研气泡定案。
- [0030](0030-dual-unit-fish-carrier.md) — 改动活鱼抓举、受伤、AI 或销毁：鱼本体（`WorldUnit`）与受击体（`EggyUnit`）双单位载体合同。
- [0031](0031-persistent-operation-identity.md) — 改动存档写入、重试、交易或外部交付：持久会话 fencing 与三类操作身份分层。

## 验收口径与范围
- [0028](0028-solo-clear-on-shared-world.md) — 设计业务闭环、多人接缝或存档边界：Solo clear 跑在真实多人服务端权威骨架上、四类证据与状态边界。
- [0029](0029-scope-completeness-and-placeholder-first.md) — 判断需求是否在范围、缺外部参数如何推进：规格内无永久出界、占位优先与生产开关口径。
- [0039](0039-acceptance-surface-as-feature-files.md) — 登记条款、补证据或改验收门禁：唯一验收面、两列条款与状态反推。

## 工具链与平台边界
- [0009](0009-blender-headless-only.md) — （已废弃，工作流存于 tag `art-workflow-archive-v1`）驱动 Blender 处理美术资产：只走无头，唯一入口 `lua tools/cli.lua blender`。
- [0017](0017-windows-native-only.md) — 改动 `tools/` CLI、子进程、路径或测试夹具：Windows 原生单一环境与唯一接缝 `tools/seam.lua`。
- [0035](0035-editor-sdk-enumeration-broken-and-exec-bypass.md) — 用 `editor-cli` 读写场景或写引擎替身：`editor-unit` 在 0.20.17 恢复为首选读取面、`exec` 合同降为兜底；故障与四条硬边界作历史保留。
- [0036](0036-platform-commerce-and-ads-not-verifiable-in-editor.md) — 改动商城、支付或广告适配层：编辑器内不可验收、订单身份自研与超时兜底。
- [0038](0038-emmylua-agentic-coding-quality-gate.md) — 改动 Lua 诊断门禁、`.emmyrc.json` 或基线：EmmyLua 作为诊断质量门禁与单向基线。
- [0040](0040-local-multiplayer-not-simulatable-in-editor.md) — 评估多人联机取证或本地模拟：本地模拟多人不可用，必须真实第二客户端。
- [0041](0041-token-budget-gate.md) — 新增或调整单文件体积规则、基线或 pre-commit/CI 门禁：token 预算（`se-fish-budget-v1`）、出货集与受管集、棘轮基线。
- [0042](0042-no-plugin-dev-data-export-only-exception.md) — 判断开发是否依赖 VS Code Eggitor 插件、或如何改 `data/`：默认无插件开发，`data/` 导出是唯一插件例外。

## 美术资产
- [0004](0004-fish-asset-scale.md) — 制作、导出或验收鱼类模型与动画：单位方块基准、100 倍导入换算、底面中心原点与贴图编码。
- [0006](0006-structural-asset-reuse.md) — 规划物种资产与动画复用：按身体结构复用骨架与动作，根位移由程序驱动。
