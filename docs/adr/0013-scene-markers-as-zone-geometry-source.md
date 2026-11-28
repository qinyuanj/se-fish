# 0013 区域几何以编辑态场景标记校验导出的只读表为准

**Status**: accepted（2026-11-28 修订收口）

七区场景独立演进，在 `GameCfg` 手写坐标会在每次美术调整后与派生边界失步；同时全图 800 余个预摆 `WorldUnit` 若在开服时保持动态加载会产生运行期负担，而开启 `IsStaticOptimization = true` 后静态物体在运行期不再创建完整 `Unit`（`World:FindFirstChild` 与 `GetDescendants` 均不可见）。

## 决定

### 1. 编辑态具名标记校验导出只读几何表

- **唯一编辑真源**：场景内具名区域标记（每区四面边界空气墙、可钓水域盒 `Z*_Water*`、安全落点、去/返程摆渡点、抽奖点、烧烤点、鱼饵刷新点、商店与渔民点；01/02 区统一命名为 `Z1_Shop`、`Z1_Fisherman`、`Z2_Shop`、`Z2_Fisherman`、`Z1_FerryOut`、`Z2_FerryReturn`）。摆渡车、烤架等美术装饰件不作查找入口。
- **离线校验导出**：场景修改后执行 `lua tools/export_scene_geometry.lua` 采集并生成受控只读表 `common/cfg/scene_geometry.lua` 与 `common/cfg/scene_water_geometry.lua`（`--check` 复核一致）。缺标记、重名、越出所属区边界、空气墙朝向或尺寸非法、水域重叠均在导出期直接报错阻断。
- **运行期只读加载与静态化**：`common/zone_markers.lua` 运行期直接加载只读导出表（仅对显式传入的测试夹具 `world` 保留树解析）；`GameCfg` 只保留爆炸半径等玩法数值，不存区域坐标。28 面边界空气墙、48 个纯坐标点位与 189 个 `Z*_Water*` 全量开启 `IsStaticOptimization = true`（纯点位与水域标记同步关闭渲染、碰撞、触发与物理），基线由 `tests/native/guards/scene_static_baseline_test.lua` 锁定。

### 2. 可钓水域采用方案 A（`MathWaterJudge` + 只读水区表）

- 保留 `common/math_water_judge.lua` 纯数学判水、`toward` 水向计算与 07 首领 `cruise_water`。
- 7 块去重叠并对齐高度的原生 `WaterUnit("深水")`（`topY = -0.250 == SurfaceY`）仅负责视觉水面、游泳浮力与入水表现。

### 3. 交互提示采用自研响应式气泡 + 导出坐标

- 退役 14 个零监听空壳 `TriggerUnit`；服务端与客户端全部 38 个交互点（7 商店、7 渔民、7 抽奖、5 烧烤、12 摆渡）统一从只读几何表读取锚点坐标。
- 客户端以响应式 `EUISceneNode` 交互气泡承载跨设施单选互斥、键鼠与触屏统一点击，以及随玩家 `BodyScale` 放大的动态交互半径。
- 除 7 个钓鱼佬站桩外观豁免保留轻量非静态 `WorldUnit`（供客户端按区脉冲缩放反馈）外，标记、装饰与地块类动态 `WorldUnit` 清零。

## 拒绝的方案

1. **在 `GameCfg` 维护手写坐标或保留隐藏灰盒**：美术改动即与派生区域失步，隐藏灰盒与新地形重叠还会引发双重碰撞与穿帮。
2. **开服运行期遍历场景树读取标记**：迫使数百个标记与空气墙保持非静态动态 `Unit`。
3. **方案 B（原生 `WaterUnit` + `PhysicsService:Raycast` 判水）**：在编辑器 `1.0.38` / `editor-cli 0.20.17` 实测未通过硬门槛。静态装饰命中时 `RaycastResult.Instance == nil` 且无法被 `RaycastParams` 过滤，高空射线被树冠、岩石与石拱截胡（189 个水域中心点漏判 13 处），低空射线起点落入厚地块内部会穿透陆地误判入水，且 06 内池 `Z6_PondFloor`（顶面 `0.00`）高于水面（`-0.25`）导致内池遮挡、`toward` 点积 `-0.92` 反向逃离（实测 300 次纯数学判水约 `0.20 ms`、射线约 `0.10 ms`，耗时同量级但空间准确性不达标）。
4. **原生 `ProximityPrompt` 交互提示**：实测双端 `game:GetService("ProximityPromptService")` 均为 `nil`，`InputHoldBegin` / `InputHoldEnd` 缺失，靠近按 `E` 后 `PromptShown` / `Triggered` 零触发且无界面渲染；挂在静态优化父节点下还会在进游戏后脱锚退化至 `World` 根。
