# 0034 本仓自写代码命名规范：文件与成员 snake_case，模块表 PascalCase

**Status**: accepted（2026-11-24；合并原 ADR-0037）

引擎不强制 Lua 文件命名风格，只强制 `require` 与文件名大小写精确一致（`source_guard_test.lua`）。此前命名条款与官方手册示例、`spoke` 上游包互相冲突，且文件名 PascalCase 曾直接诱发与内置服务 `World` 同名冲突（[ADR-0033](0033-script-names-must-not-shadow-se-services.md)）。

## 决定

现行细则与正反例以 [CODING_STANDARDS.md「命名」](../../CODING_STANDARDS.md#命名) 为唯一事实源，本 ADR 记录分层口径、豁免边界与决策理由：

| 层 | 范围 | 口径 | 依据 |
| --- | --- | --- | --- |
| L1 | 文件名、目录名、`require` 命名空间 | `snake_case` | 官方手册示例与 `spoke` 整包；降低与 PascalCase 内置服务撞名面 |
| L2 | 模块表与类型名 | **`PascalCase`**（文件名的驼峰形） | 与上游 `spoke` 一致（`spoke_runtime.lua` → `local SpokeRuntime`），读代码一眼区分类型与值 |
| L3 | 方法、自研字段、局部、参数 | `snake_case`（常量 `UPPER_SNAKE_CASE`） | 与上游 `spoke` 成员风格统一 |

### 官方契约与边界一律原样（大写不管）
1. **官方 API 成员与内置服务名**（`OnServerEvent`、`World`、`MapData`、`Game`、`Camps`、`*Service`）；
2. **EUI 节点与单位属性表键**（`Name`、`Text`、`FontSize`、`Parent`、`Visible` 等，以 `EggyAPI.lua` 与 `docs sync api` 为准），以及引号内的 Spoke 作用域名、状态频道串、运行期单位/节点名与动态键字符串（改名会导致跨端或运行期静默失配）；
3. **`data/` 导出文件与 `EggyAPI.lua` 存根**；
4. **对应 `docs/design/` 策划表列的配置字段**（行锚点只到行，列对应依赖字段名）；
5. **所有 `*/packages/` 整包**（官方包与自研包同等处理，不参与命名迁移）、`unit_scripts/`、编辑器生成物（`server/_trigger/`）；
6. **实现官方或包内声明接口的方法名跟随接口**（如 ability 锚点接口 `M.Attach`），同名的自研方法照常 `snake_case`。

### 与 ADR-0033 的关系
[ADR-0033](0033-script-names-must-not-shadow-se-services.md) 的「新增顶层目录或脚本前核对 SE 内置服务名」仍有效：编辑器是否做大小写归一尚未实测，不能仅凭 `snake_case` 宣称撞名风险消除。

## 拒绝的方案

1. **全量 `snake_case`（含模块表）**：与上游 `spoke` 相反，同一次 `require` 里 `State`/`World` 与 `game_cfg` 风格割裂，且失去类型与值的视觉区分。
2. **文件层保持 PascalCase**：与官方手册示例、`spoke` 冲突，且易与 SE 内置服务重名。
3. **只约束新增代码不迁移存量**：存量 PascalCase 会永久割裂全仓风格。

## 后果与门禁

- 命名守卫与旧名字符串键守卫见 `tests/native/guards/naming_guard_test.lua` 与 `tools/naming_guard.lua`；批量改名与检查走 `lua tools/cli.lua naming [--recon|--apply|--check]`（数据在 `tools/naming/data/`）。
- 凡从命名空间派生的 Lua 模式串（如 `tools/arch_policy.lua` 中的 `'^server%.world_host%.'`）与守卫正则，改名时必须同步核对，避免门禁静默放行。
- 历史记录（旧 ADR、`evidence/`、`.metrics/` 历史快照）不追改旧名。
