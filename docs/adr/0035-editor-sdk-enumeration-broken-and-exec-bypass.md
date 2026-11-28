# 0035 编辑器场景读写合同：editor-unit 首选读取与 exec 兜底边界

**Status**: accepted（2026-10-14 确立 `exec` 绕过；2026-11-28 随 `editor-cli 0.20.17` 恢复 `editor-unit` 首选只读）

`editor-cli 0.20.12` 及更早版本因 SDK 内部 `WorldService` 的 `tryBuildReflectClass` 将桥接字符串直接写入反射缓存抛错，导致 `editor-unit` 子命令族全线故障（调用侧对单文件打包的 `editor-cli.exe` 无补丁点）。`0.20.17` 实测已修复 `editor-unit` 只读路径，但场景写操作尚未在目标图实测切换，且批量采集仍需经 `editor-cli exec` 执行。

## 决定

1. **按 ID 与列表只读首选 `editor-unit`**：单点查看、分页枚举与属性读取优先走 `editor-unit`（`capabilities` / `list` / `search` / `get` / `get-property` / `selected`，`list` 默认 50、上限 200）。`unit_id_scope` 为 `current_map_load`，重开地图或起停试玩即变；持久身份继续按 [ADR-0031](0031-persistent-operation-identity.md) 处理。
2. **批量采集与场景写操作走 `editor-cli exec`**：在目标图实测验证 `editor-unit` 写操作前，`create` / `transform` / `set-property` / `reparent` / `rename` / `delete` 仍走 `exec` 调公开 Unit API。
3. **`exec` 路径三条硬边界**（同时约束采集脚本与 `tests/support/engine_double.lua`）：
   - 编辑器侧不用 `World:GetDescendants()` / `World:GetChildren()`（`World` 包装对象无 `GetChildren`）；试玩服务端枚举根用 `World:GetDescendants()` 或递归 `World:FindFirstChild(name)`，同样不用 `World:GetChildren()`。
   - 不用 `GetUnitsByUnitType` 枚举 `Script` / `PresetLink` 类型本身，改经已知父节点的 `GetChildren()` 访问。
   - 同名查找必须限定父节点：递归能力只在 `World:FindFirstChild(name)` 上（无需第二参数，同名多对象只返回首个）；`Unit:FindFirstChild(name)` 只匹配直接子级且静默忽略第二参数，子树递归须手工栈遍历。

## 沙盒与引擎附带事实

- **`exec` 沙盒无外部模块与文件 I/O**：`require` 调用报错，`io` / `os` / `loadfile` / `package` 全部缺席。依赖业务配置清单的探针须离线生成字面量嵌入（见 `tools/gen_config_anchor_probe.lua`）。探针脚本按[开发工作流](../agents/workflow.md)目录约定入库，正式证据须可重跑、可 diff。
- **两端坐标与类型差异**：编辑态 `Unit.Position` 为数组 `[1..3]`（`.x` 为 `nil`），运行态为 `Vector3`（`.x` / `.y` / `.z`）；`EffectUnit` 不是 `SpaceUnit`，`GetPosition()` 返回 `nil`。
- **变换与排序限制**：`SetTRS` 有旋转写入异常，统一改用 `SetPosition` / `SetRotation` / `SetScale` 分立接口；编辑器 API 无同级节点排序成员，分组顺序只能靠命名或摆位表达。

## 拒绝的方案

1. **反编译或修改 `editor-cli.exe` 内置 Lua 载荷**：单文件打包且会被 `env-res` 更新覆盖，无法入库复核。
2. **用截图加目视代替场景属性回读**：读不出精确坐标、层级与属性值，逐点验收退化为主观目测。
3. **未经目标图实测直接将写操作切到 `editor-unit`**：`capabilities` 报 `supported` 不等同于实机写入无回归，切换前须在目标图单做写回读验证。
