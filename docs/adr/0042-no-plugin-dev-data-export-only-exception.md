# 0042 开发不依赖 VS Code Eggitor 插件，`data/` 导出是唯一例外

**Status**: accepted（2026-11-28）

本仓默认无插件开发：开发、取证与验收的入口是 `editor-cli` 与 `lua tools/cli.lua`，不为 VS Code Eggitor 插件写代码、维护工程或写插件开发步骤。插件在本仓只保留一个用途——`data/` 的导出。本条把边界钉死，避免后续把插件工程、插件调试或插件专属配置重新带回主线。

## 背景

- 审计确认 11 个开发步骤已由 `editor-cli` / `lua tools/cli.lua` 闭合；唯一例外是 `data/` 导出（见下）。
- `data/` 是导出物而非源码：实测 `data/CustomAsset.lua`、`data/UINodes.lua` 首行均为 `---AUTTO EXPORT BY EGGITOR PLUGIN, PLEASE DO NOT EDIT`；手改会在下次导出时被覆盖。
- `editor-cli --help` 的命令组（`status` / `doctor` / `editor-instances` / `map` / `play` / `input` / `exec` / `editor-unit` / `preset` / `code` / `log` / `screenshot` / `docs` / `env-res` 等）里**没有任何 `data/` 导出命令**；`preset export-*` 导的是预设资产，不是地图 Lua 数据表。→ `data/` 只能由编辑器里的插件导出。
- `env-res` 管的是 AI 资源版本（`codex` / `codemaker` 规则、`editor-cli`、`eggy-api`），不提供 `data/` 导出。
- `code init` 由编辑器创建并注册工程（scaffold + `eggy.json` + API stubs），生成的是工程与 API 存根，不产出 `data/`。

## 决定

1. **默认无插件**：仓库不为 VS Code Eggitor 插件维护工程、代码或开发步骤；文档与验收不把「装插件、开插件、插件调试」写成前置条件。
2. **唯一例外是 `data/`**：`data/` 的生成与更新必须回编辑器用插件导出，再 `lua tools/cli.lua sync` 回灌；不手写、不脚本生成 `data/`。
3. **判据**：`data/**` 文件首行为 `---AUTTO EXPORT BY EGGITOR PLUGIN, PLEASE DO NOT EDIT` 即视为导出物。
4. **插件不可用不阻塞主线**：不需要 `data/` 变化的改动照常走 CLI；需要 `data/` 变化的任务显式登记为「等插件导出」，在验收记录里留缺口，不用手写绕过。
5. **与 SDK/场景读写无关**：那条路径由 [ADR-0035](0035-editor-sdk-enumeration-broken-and-exec-bypass.md) 的 2026-11-28 复查结论管（`editor-unit` 恢复为首选读取面），插件不参与。

## 备选方案（拒绝）

- **手写或脚本生成 `data/`**：与「导出物」事实冲突，没有 schema 来源，下次导出即被覆盖，还会掩盖数据漂移。
- **为插件维护并行开发链**：审计已确认 11 步由 CLI 闭合，维护插件工程是净成本。
- **用 CLI 的 `preset export-*` 替代 `data/` 导出**：语义不同（预设资产 vs 地图数据表），替代不了。
- **把插件作为「可选开发方式」写进文档**：会重新产生两条路径的维护负担与口径分裂。

## 后果

- `AGENTS.md` 与 `docs/agents/workflow.md` 按本条声明「无插件开发 + `data/` 唯一例外」。
- 需要 `data/` 变化的验收必须在证据里注明「由编辑器插件导出」，并保留导出前后的回读证据。
