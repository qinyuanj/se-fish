# 0035 编辑器 SDK 全树枚举故障，与 `exec` 绕过合同

**Status**: accepted（2026-10-14 定不修，2026-11-24 收口成本条 ADR；2026-11-28 复查：`editor-unit` 在 0.20.17 恢复，`exec` 合同降为兜底，见「2026-11-28 复查」）

本图几乎所有场景取证、批量写入与逐点验收都要先读场景。而编辑器 SDK 的 `editor-unit` 子命令族在本机是全线故障的：它坏在 SDK 内部的类型反射缓存上，调用侧没有补丁点。不知道这件事，第一反应会去「修命令」或者「换个参数再试」，两头都是空耗。

## 故障

`WorldService.lua:535` 的 `tryBuildReflectClass` 把 Python/MessagePack 桥接字符串（`u'WaterUnit'`、`u'Script'`）直接当 Lua 表键写进 `REFLECT_CLASS_CACHE`，抛 `table index can only be a string/integer/real.`。0.20.12 复查时出错位置随版本移到 `WorldService.lua:547`，行为不变。

**调用侧无补丁点**：`~/.eggitor/cli/editor-cli.exe` 是单文件打包，`editor-unit` 的 Lua 载荷在 exe 内；即便改了也会被 `editor-cli env-res` 更新覆盖。所以「修复」只剩官方 SDK 一条路（影响面取证见 #101，复现见 #65）。

**后果比「某条命令坏了」严重**：`editor-unit` 的 `find_unit` 先经 `all_units` → `getUnits` 建全量索引，所以**即使已持有正确 UnitId 也失败**——`get` / `get-property` 实测 `EDITOR_UNIT_SCAN_FAILED`；`transform` / `set-property` / `reparent` / `rename` / `delete` 属同族，按同因判失败。

## 决定

不修，接受绕过（决策单 #100，2026-10-14）。绕过写成**四条硬边界**，边界外一律不做：

1. 不用 `editor-unit` 子命令做任何按 ID 的操作，一律走 `editor-cli exec` + Lua 直调公开 Unit API。
2. 编辑器侧不用 `World:GetDescendants()` / `World:GetChildren()`（World 包装对象没有 `GetChildren`）；试玩中服务端枚举 World 根节点用 `World:GetDescendants()` 或递归 `World:FindFirstChild(name)`，同样不用 `GetChildren`。
3. 不枚举 `Script` / `PresetLink` **类型本身**（`GetUnitsByUnitType` 仍报 535）；这两类经已知父节点的 `GetChildren` 访问。
4. 同名递归查找必须限定父节点：**递归能力只在 `World` 服务上**，同名多对象（7 个 `铁艺弯钩`、7 个 `设施`）只返回第一个命中。`World:FindFirstChild(name)` 递归且**不需要**第二个参数；`Unit:FindFirstChild(name)` 的 meta 只有 `name` 一个参数，**只匹配直接子级**，多传的 `true` 被静默忽略（`zone:FindFirstChild('大地板', true)` → nil，`zone:FindFirstChild('地块'):FindFirstChild('大地板')` → 命中）。要递归就手工栈遍历，不要指望第二个参数。

边界内经 `exec` 已实测可用：非 `Script` / `PresetLink` 的类型枚举、非根子树 `GetChildren` / `GetDescendants`、任意层级 `GetProperty` / `SetProperty`、`World:CreateUnit`、`SetPosition` / `SetRotation` / `SetScale`、`SetParent`、地图保存与重开回读。

### 复查触发

`editor-cli --version` 变化即重开 #100，评估是否换回原路径；`env-res list` 的 `latest` 变化只作背景信息。本机 2026-11-20 已是 **0.20.17**，而上一次复跑停在 0.20.12，所以这条复查现在是欠着的：挂在 [#323](https://github.com/qinyuanj/se-fish/issues/323) 第五节，没复跑就没有「已修 / 未修」的结论。2026-11-28 已复跑，见下节。

## 2026-11-28 复查

**触发条件已满足**：`editor-cli --version` 从 0.20.12 前进到 **0.20.17**（`~/.eggitor/cli/editor-cli.exe --version` 实测）。`env-res list` 显示 `editor_cli_win` 当前 0.20.17、`latest` 0.20.20（`needs_update: true`），只作背景信息。

**实测**（本机编辑器已开图，全部只读命令，未写场景）：

- `editor-unit capabilities --json`：`success: true`，`backend: se_editor_api`，`data.available` / `data.fully_aligned` / `data.editor_only` 均为 `true`，`locator: UnitId`，`unit_id_scope: current_map_load`，`list_default_limit: 50` / `list_max_limit: 200`；13 个操作在 `operation_support` 里全部为 `supported`：`capabilities` / `list` / `search` / `get` / `selected` / `select` / `create` / `rename` / `transform` / `get-property` / `set-property` / `reparent` / `delete`。
- `editor-unit list --json`：`success: true`，单页 50 条，带 `has_more` / `next_offset` / `total` / `type_groups`；返回类型含 `WorldUnit` / `Folder` / `PresetLink` / `SpawnLocationUnit`。
- `editor-unit get 1179017579 --json`：`success: true`，返回 `WorldUnit` `Z1_FerryOut` 的 `unit` 对象，含 `path`、`parent_unit_id`、`child_count` 与 `transform{position, rotation, scale}`。
- `editor-unit get 1134030614 --json`：`success: true`，返回 `Folder` `01 鱼塘`。
- `editor-unit get-property 1134030614 name --json`：`success: true`，`property: "name"`、`value: "01 鱼塘"`、`value_type: "string"`。
- `capabilities.data.limitations`（SE）：`create` / `transform --scale` 由 `Unit:SetScale` 在单位存在后写入并读回校验，写失败回滚并报告。

**结论变化**：

- 原「`editor-unit` 全线故障、按 ID 的读也必须走 `exec`」作废：**按 ID 的读操作改回 `editor-unit` 首选**（`list` / `search` / `get` / `get-property` / `selected`），`exec` 退回「它覆盖不到时的兜底」。故障描述与 2026-10-14 的决定作为历史保留，不删。
- **写操作未切换**：`capabilities` 声称 `create` / `rename` / `transform` / `set-property` / `reparent` / `delete` 均 `supported`，但本次复查只跑只读命令（禁写场景），没有实跑写操作。切换前先在目标图上实测一次；在此之前写操作仍按原合同走 `exec`。
- **四条硬边界的新适用边界**：边界 1（任何按 ID 操作都不用 `editor-unit`）作废；边界 2 / 3 / 4 只约束 `exec` 路径（World 枚举、`Script` / `PresetLink` 类型本身、同名递归）。`editor-unit list` / `search` 可作为这些场景的替代读取面，但 `Script` / `PresetLink` **类型本身**的枚举与同名递归**本次未复测**，仍按未验证处理。
- **UnitId 仍不可持久化**：`unit_id_scope: current_map_load`，地图重开、加载或起停试玩都会变；持久身份继续按 [ADR-0031](0031-persistent-operation-identity.md) 的操作身份口径。
- 复跑命令（可复现，全部只读）：

  ```
  editor-cli --version
  editor-cli editor-unit capabilities --json
  editor-cli editor-unit list --json
  editor-cli editor-unit get <unit-id> --json
  editor-cli editor-unit get-property <unit-id> <attr> --json
  ```

## 已知副作用与附带事实

**沙盒能力边界**（#65 P2 实测）：`exec` 的编辑器沙盒里 `require` 存在但不可用（`sdk.common.lua:830: attempt to call a nil value (field 'require')`），`io` / `os` / `loadfile` / `package` 全部缺席。所以探针**不能**加载 `common/game_cfg.lua`、也读不了外部数据文件；任何配置派生的清单必须离线生成后以字面量嵌入（做法见 `tools/gen_config_anchor_probe.lua` 与 fast 车道的同步守卫）。另：`EffectUnit` 不是 `SpaceUnit`，`GetPosition()` 回读 nil，不能把 nil 当坐标 0。

**坐标形态**：编辑态 `Unit.Position` 是数组 `[1]` / `[2]` / `[3]`（`.x` 为 nil）；运行时是 `Vector3`，用 `.x` / `.y` / `.z`。同一段坐标逻辑跨两端复用时先按端取分量。

**`SetTRS` 有旋转写入异常**，优先用 `SetPosition` / `SetRotation` / `SetScale` 三个独立接口（#65 记录）。

**编辑器 API 没有 Unit 同级排序成员**：`api search` 检 `order` / `sort` / `index` / `sibling` 只命中 DataStore 的排序存储。这与本故障无关，但同属「修好 535 也拿不到」的能力——「分组按数字升序显示」这类需求只能靠命名 / 摆位表达，或改判期望。

## 取证口径

绕过用的探针脚本按[开发工作流](../agents/workflow.md)的目录约定入库；一次性脚本只用于临时试验，正式证据要可重跑、可 diff。

## 备选方案（拒绝）

- **等 SDK 修复再动场景**：当时官方资源通道最新为 `editor_cli_* 0.20.2`，没有已知修复版本，而绕过路径已覆盖那轮的全部操作类型。等待只是让场景工作停摆。
- **反编译或改 exe 内的 Lua 载荷**：单文件打包，改动会被 `env-res` 更新覆盖，也进不了版本库被复核。
- **走官方反馈渠道推动修复**：2026-10-14 决定不走，修复到达以版本变化为准。
- **用截图加人工目视代替场景读取**：读不出坐标、父子关系与属性值，任何逐点验收都退化成「看起来对」。