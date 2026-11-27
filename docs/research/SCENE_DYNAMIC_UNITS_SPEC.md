# 进游戏动态单位盘点与收口定版规格

本文记录 2026-11-27 对《钓鱼怎么这么危险啊喂！》（`map_id=6aab8e60ee615830184f4963`，实查工具 `editor-cli 0.20.17`，官方云文档含 2026-11-12 / 2026-11-26 契约）场景预摆单位与代码建点的全量盘点快照，以及经逐类评审定版后的规格与分批收口方案。对应跟踪总单：[#403](https://github.com/qinyuanj/se-fish/issues/403)。

> 术语口径以 [GLOSSARY.md](../../GLOSSARY.md) 为准；本次演进与 [ADR-0013](../adr/0013-scene-markers-as-zone-geometry-source.md) 的关系须在两道可行性探针得出硬结论后再正式修订或续写 ADR 落档。

---

## 一、实查盘点快照（2026-11-27）

### A. 场景内预摆单位（进游戏随地图加载为运行时 Unit）

> 关键发现：全图共 **804 个 `WorldUnit`**，其中开启 `IsStaticOptimization = true` 的数量为 **`0`**——所有装饰物、边界空气墙、可钓水域块和纯坐标点位标记在进游戏时全部作为完整动态 Unit 生成。

| 类别 | 单位类型 | 实查数量 | 分布与实查现状 | 代码实际用法 |
| --- | --- | ---: | --- | --- |
| 1. 原生水体 | `WaterUnit` | **5** | `01 鱼塘`（`topY=-1.07`）、`02 虾池`（`topY=-0.93`）、`04 树林岛`、`05 沙滩岛`（`1000×948`，`topY=-0.25` 横穿全部 7 个钓鱼区）、`07 火山岛` 的 `装饰/深水`；`03 蟹湖`、`06 礁石岛` 无独立节点 | 代码零引用；存在大海面与 01/02 池水上下重叠及高度错位 |
| 2. 可钓水域标记 | `WorldUnit` | **189** | `01` 33、`02` 35、`03` 46、`04` 19、`05` 22、`06` 5、`07` 29（`Z1_Water*`~`Z7_Water*`，`topY=-0.75`），抽样实查仍开着 `PhysicsActive=true` / `ModelVisible=true` | 启动时被 [zone_markers.lua](../../common/zone_markers.lua) 读取坐标尺寸供 [math_water_judge.lua](../../common/math_water_judge.lua) 判水与逃脱寻水 |
| 3. 交互点触发器 | `TriggerUnit` | **14** | 7 商店（`TGUnitShop`、`TGUnitShopShrimp`、`Z3_Shop`~`Z7_Shop`）+ 7 渔民（`TGUnitFish`、`TGUnitFishShrimp`、`Z3_Fisherman`~`Z7_Fisherman`） | 代码**零处**监听 `OnTriggerEnter/Leave`；仅被 [interaction_points.lua](../../server/world_host/interaction_points.lua) 与客户端当坐标锚点测距 |
| 4. 商店占位子件 | `WorldUnit` | **28** | 7 个商店 `TriggerUnit` 下各挂 `FishFood` → `中式杆` → `铁艺弯钩` + `直线绳索`（4×7） | 代码零引用；原型期拼出的摊位外观 |
| 5. 站桩 NPC 外观 | `EggyUnit` + `WorldUnit` | **3 + 1** | 3 个带完整 `EggyController` 的 `EggyUnit("厨师蛋")`（仅 `04`/`05`/`06` 有，`03`/`07` 缺）；1 个 `WorldUnit("FishermanModel")`（仅 `01` 有，`02`~`07` 缺） | `厨师蛋` 代码零引用；`FishermanModel` 由客户端渔民视图执行按区脉冲缩放反馈 |
| 6. 区域边界空气墙 | `WorldUnit` | **28** | 7 个钓鱼区 × 4 面（`Z1_BoundaryWest/East/South/North` ~ `Z7_Boundary*`） | 既作物理阻挡，又在启动时被区域标记解析器按名读取边界盒 |
| 7. 纯坐标点位标记 | `WorldUnit` | **48** | 安全落点 `Z*_Safe` × 7、摆渡点 `FerryBoat`/`FerryReturn`/`Z*_FerryOut/Return` × 12、抽奖点 `Z*_Lottery` × 7、烧烤点 `Z*_Grill` × 5、鱼饵刷新点 `Z*_Bait*` × 17；抽样实查连 `Z1_Safe` 均开着 `PhysicsActive=true` / `CanTrigger=true` / `ModelVisible=true` | 启动读坐标（交互点另用于测距或挂气泡），整局不渲染不移动 |
| 8. 06 礁石岛临时地块 | `WorldUnit` | **11** | `06 礁石岛/地块` 下 `Z6_Land`、`Z6_Bank`、`Z6_PondFloor`、`Z6_Ridge*` 等；实查 10 块 `TerrainUnit` 尚未覆盖 06（`X=-505, Z=312`） | 代码零引用；[ADR-0013](../adr/0013-scene-markers-as-zone-geometry-source.md) 标注为正式地形补齐前的临时地面 |
| 9. 场景特效 | `EffectUnit` | **5** | `World/FX/渐变光-箭头`、`01/设施/FX_Shop`、`02/设施/TGUnitFishShrimp/渐变光-箭头`、`02/设施/TGUnitShopShrimp/FX_Shop`、`07/装饰/烟雾2` | 代码零引用；前 4 个是 01/02 原型期指引残留 |
| 10. 纯美术装饰与组合 | `WorldUnit` + `ModelUnit` | **~500 + 14** | 7 个钓鱼区 `装饰` 目录下的树、草丛、岩石、躺椅、导演椅、摆渡船、烤架、`组合_0` 等（下挂 79 个 `SkinUnit`，零脚本/零控制器） | 代码零引用；当前全量未开静态优化 |
| 11. 地形与出生点 | `TerrainUnit` + `SpawnLocationUnit` | **10 + 1** | `World` 下 10 块 `地形` + `01 鱼塘/摆渡/出生点` | 引擎原生基础单位 |

*(另含引擎附属子节点：`PresetLink` × 690、`SkinUnit` × 79、`EggyController` × 3、`Folder` × 47。)*

### B. 代码侧进游戏 / 局内动态创建的单位（对照台账）

| 时机 | 创建对象 | 规模 | 本次定位 |
| --- | --- | --- | --- |
| 开服即建 | 初始可拾取鱼饵 `BaitSpot_*`（`WorldUnit`） | **17 个** | 真实玩法动态实体，维持现状（点位来源切至导出表） |
| 开服即建 | 官方包事件载体 `BindableEvent` | 3+ 个 | 本总单范围外（官方包内部机制） |
| 玩家进房（服务端） | `AttrUnit`、`AbilityManager` + 初始技能/锚点预设、左手持竿挂点（`SkeletalSocketMount` + `WorldUnit`） | 每人 1 套 | 本总单范围外 |
| 玩家进房（客户端） | 交互气泡 `SceneNode`（商店 7 + 渔民 7 + 抽奖 7 + 烧烤 5 + 摆渡 12） | 每客户端约 **38 个** | 纳入 Q8 原生 `ProximityPrompt` 探针评估替换 |
| 局内按事件 | 活鱼双载体（[ADR-0030](../adr/0030-dual-unit-fish-carrier.md)）、钓线、挥砍/投掷判定与视觉、烤鱼视觉、特殊道具占位挂点、地面掉落、预警/技能特效 | 按行为动态生灭 | 本总单范围外 |

---

## 二、逐类定版总表

| 类别 | 定版决策 | 运行态动态 Unit 目标 |
| --- | --- | --- |
| 原生 `WaterUnit("深水")` | 消除 05 大海面与 01/02 池水重叠，按 7 个钓鱼区理顺为边界清晰、互不重叠的原生 `WaterUnit`，视觉水面高度与玩法 `SurfaceY` 一致 | **7 块（按区规范）** |
| 189 个 `Z*_Water*` 水域标记 | **优先方案 B（先测可行性）**：通过 4 条硬门槛则彻底删除并重开 ADR-0013，改原生深水 + 物理射线/高度判水；**任一不过则回落方案 A**（编辑态真源 → 导出只读水区表 + 标记关渲染物理并静态化） | **0 个** |
| 14 个 `TriggerUnit` + 38 个客户端气泡 | **优先原生 `ProximityPrompt`（先测可行性）**：通过触屏/互斥/`BodyScale`/静态体挂载探针后退役 14 空壳与自研气泡；19 有 NPC 点直挂站桩 NPC，19 无 NPC 点视探针决定静态挂载或留最小无物理锚点；**探针不过则回落自研气泡 + 导出坐标** | **0 或 19 个最小锚点** |
| 28 个商店占位子件 | 从 `TriggerUnit` 解绑并开启 `IsStaticOptimization = true` 作临时摊位，待正式美术替换 | **0 个** |
| 站桩 NPC | 全 7 区统一 **19 个**轻量化站桩 NPC（7 商店 + 7 渔民 + 5 烧烤），禁开 `EggyController` / 物理，补齐缺区占位；7 个渔民模型维持非静态轻量单位以兼容客户端缩放脉冲并兼作提示宿主 | **19 个无控制器轻量 NPC** |
| 28 面边界空气墙 | 升级 ADR-0013：编辑态真源 → 工具导出只读边界表 → 全量开启 `IsStaticOptimization = true` | **0 个** |
| 48 个纯坐标点位标记 | 走编辑态导出只读坐标表；场景中关闭渲染/碰撞/触发/物理并开启 `IsStaticOptimization = true` | **0 个** |
| 11 个 06 礁石岛临时灰盒 | 因正式地形尚未覆盖，暂留不删并开启 `IsStaticOptimization = true`，待地形补齐后拆除 | **0 个** |
| 5 个场景 `EffectUnit` | 删除 4 个 01/02 原型指引特效，保留 `07 火山岛/装饰/烟雾2` | **1 个** |
| ~500 纯美术装饰 + 14 `ModelUnit` + 79 `SkinUnit` | 全量开启 `IsStaticOptimization = true`（含风扇、摆渡船、烤架、`组合_0`；排除 `WaterUnit`、`EggyUnit`、`烟雾2`） | **0 个** |
| 6 个 01/02 原型旧名 | 统一收口为 `Z1_Shop`、`Z1_Fisherman`、`Z2_Shop`、`Z2_Fisherman`、`Z1_FerryOut`、`Z2_FerryReturn` | 命名统一 |
| 17 个开服鱼饵实物 `BaitSpot_*` | 保留为玩法动态实体，仅坐标来源切至导出表 | **17 个（玩法必需）** |

> 预期效果：场景侧进游戏动态 `WorldUnit` 由 **804 个** 压降至 **0 个**（若无 NPC 设施需独立提示锚点则至多 **19 个**），**14 个**空壳 `TriggerUnit` 清零，**3 个**带 `EggyController` 控制器清零。

---

## 三、两道前置可行性探针硬门槛

### 探针 ①：原生深水判水替代 189 个 `Z*_Water*`（方案 B 门槛）
须 **4 条同时通过**，否则自动回落方案 A（编辑态导出水区表 + 静态不可见化）：
1. 物理空间查询（`PhysicsService:Raycast` 或重叠查询）能稳定区分开放水面（原生 `WaterUnit`）与陆地（`TerrainUnit` + 06 静态临时地块 + 静态装饰地面），无穿帮误判；
2. 300 次级高频判水耗时可控，与现行纯数学判水同量级，不拖慢服务端帧循环；
3. 能以极简数据满足活鱼上岸后的逃脱寻水方向计算（`towardWater`）与 07 火山岛首领水下巡游区域（`cruise_water`）；
4. 实机覆盖全部 7 个钓鱼区（含 01/02 池塘与 06 临时地块）无误判。

### 探针 ②：原生 `ProximityPrompt` 替代 14 个 `TriggerUnit` 与自研气泡
1. 手机触屏点击与键鼠触发均正常工作；
2. 多提示互斥（`Exclusivity`）与玩家体型缩放（`BodyScale` 动态交互半径）可正确适配；
3. 验证开启 `IsStaticOptimization = true` 的单位是否支持挂载 `ProximityPrompt`（决定 19 个抽奖/摆渡点是否需保留最小无物理动态锚点）。

---

## 四、分阶段执行顺序与测试策略

### 执行顺序
1. **Phase 1（前置探针）**：在试玩环境完成探针 ① 与探针 ②，沉淀实测结论。
2. **Phase 2（ADR 定稿）**：按探针硬结论修订或续写 [ADR-0013](../adr/0013-scene-markers-as-zone-geometry-source.md)。
3. **Phase 3（分批施工）**：
   - **批 1（低风险先行减负）**：纯美术装饰 + 06 临时灰盒 + 28 商店拼件批量静态化、删除 4 个原型指引特效、整理 7 区原生 `WaterUnit` 重叠与水面高度；
   - **批 2（真源导出 + 命名与 NPC 收口）**：落地编辑态只读几何导出与解析器切换、统一 6 个旧名、补齐 19 个无控制器站桩 NPC、28 空气墙与 48 纯点位全量静态化；
   - **批 3（按探针定案落地）**：执行水域方案 B（或回落 A）与原生 `ProximityPrompt` 迁移（或回落自研气泡）。

### 测试与验收边界
- **原则**：只测外部可观察行为与跨真源契约，不测实现细节；按 [开发工作流](../agents/workflow.md) 的「按改动选测试」规则执行对应测试车道。
- **离线行为与契约覆盖**：区域标记契约与快照加载（含 6 个旧名统一与缺标记阻断）、判水与活鱼逃脱寻水边界、商店/渔民/抽奖/烧烤/摆渡交互与 `BodyScale` 距离扩展、渔民模型按区脉冲缩放、17 个鱼饵刷新点、以及运行期建点台账守卫与文档/命名/架构门禁。
- **范围边界**：本规格不重开活鱼双单位载体合同（[ADR-0030](../adr/0030-dual-unit-fish-carrier.md)）、官方技能/属性/效果包运行时建点机制及正式美术资产制作（仍遵循 [ADR-0029](../adr/0029-scope-completeness-and-placeholder-first.md) 的完整范围口径）。
