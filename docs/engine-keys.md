# 引擎键与官方名排除清单（ADR-0034 L3 前置）

用途：L3 要改「方法名与自研 table 字段」（874 个方法 / 406 个 `GameCfg` 字段，见 [ADR-0034](adr/0034-self-written-code-snake-case.md) L3 行）。本文件是**排除清单**：命中即不改。五类豁免出处：[CODING_STANDARDS.md:11](../CODING_STANDARDS.md) 与 ADR-0034「官方契约原样」。

总则：**引擎手册或引擎存根（`EggyAPI.lua`）能查到的名字不改；`data/` 里的字段不改；引号里的运行期名字不改；能与 `docs/design/` 列或数值对上的不改；`*/packages/` 整包（含自研包）不改。** 正反对照：`DamageFloat:Show` → `DamageFloat:show`（自研：类型留 Pascal、方法改 snake）；`OnServerEvent`（官方，不动）。

自查入口：`lua tools/cli.lua docs search <词>`（实测可用；任务书里的 `tools/cli.cua` 在本仓不存在，真实入口见 [tools/cli.lua:42](../tools/cli.lua)）。缓存 `.toolcache/se-manual`，缺页时 `lua tools/cli.lua docs sync` 或 `lua tools/cli.lua docs sync api <类型名>`（[tools/docs.lua:353-355](../tools/docs.lua)）。

## 1. EUI 节点与单位属性表键

**判别依据**（已与官方逐属性页核对，见文末「决策记录」第 1 条）
- 官方逐属性页 `.toolcache/se-manual/game_api/unit/EUINodeBase.txt` / `EUIButton.txt` / `EUITextLabel.txt`（`lua tools/cli.lua docs sync api <类型名>` 抓取，页头记 `sha256` 与 `fetched_at`）：本节 31 + 13 + 4 个属性名逐条对过，**0 缺项**。
- 引擎存根 `EggyAPI.lua`：按 `---@class` 逐类列 `@field`，给出本地行号，便于正查。
- 手册页 `.toolcache/se-manual/lua/09-ui-eui-coregui.txt:520-536`：属性直读、`Parent` 必须指向 EUI 根、动态创建走 `World:CreateUnit(类型名, {...})`；同页 `:677-678` 说明 `Opacity` 不是隐藏开关。
- `.toolcache/se-manual/game_api/README.txt:106`（`EUINodeBase` 摘要）、`:110`（`EUIRichTextLabel`）。

**条目（可直接查，行号指 `EggyAPI.lua`）**
- `Unit` 基类 `:7818-7819`：`Name`、`Parent`。
- `EUINodeBase` `:6170-6214`：`Anchor`、`Position`、`Size`、`Scale`、`Rotation`、`LocalZOrder`、`LayoutOrder`、`Opacity`、`Visible`、`TouchEnabled`、`SwallowTouchEnabled`、`TouchDragEnabled`、`FlippedX`/`FlippedY`、`AnchorXAdaptMode`/`AnchorXAdaption`（Y、Left、Right、Top、Bottom 同构）、`ShowEvent`/`HideEvent`/`ClickEvent`/`LongtouchEvent`/`TouchbeginEvent`/`TouchendEvent`、`TouchBeginAudio`/`TouchClickAudio`/`TouchEndAudio`；信号 `OnClicked`/`OnTouchBegan`/`OnTouchMoved`/`OnTouchEnded`。
- `EUIButton` `:6038-6053`：`ButtonText`、`ButtonTextColor`、`ButtonTextFont`、`ButtonTextFontSize`、`ButtonNormalColor`/`ButtonPressColor`/`ButtonDisableColor`、`NormalImage`/`PressImage`/`DisableImage`、`Disabled`、`StretchArea`/`StretchAreaPercentEnabled`。
- `EUITextLabel` `:6401-6415`：`Text`、`TextColor`、`Font`、`FontSize`、`TextHorizontalAlignment`、`TextVerticalAlignment`、`Outline*`、`Shadow*`、`ItalicEnabled`。
- `EUIImage` `:6090-6094`：`Image`、`Color`、`StretchArea*`；`EUISceneNode` `:6325-6330`。
- `EUIManager` `:828` 起：`GetRootNode`、`GetDeviceResolution`、`CreateSceneUIByPrefabKeyAttachUnit` 等（调用点 [client/game_ui.lua:62](../client/game_ui.lua)）。

**代码实证（L3 最常碰到的写法）**：[client/damage_float.lua:69-77](../client/damage_float.lua)（`Text`/`FontSize`/`TouchEnabled`/`SwallowTouchEnabled`/`Opacity`/`Visible`/`LocalZOrder`）、[client/interaction_bubble.lua:11-26](../client/interaction_bubble.lua)、[client/views/reel_overlay_view.lua:57](../client/views/reel_overlay_view.lua)、[client/views/main_hud_vitals_view.lua:76-79](../client/views/main_hud_vitals_view.lua)（`TextVerticalAlignment`）。

**怎么判断**
1. 名字能在 `EggyAPI.lua` 对应 `@class` 的 `@field` 查到 → 不改；
2. `lua tools/cli.lua docs search <属性名>` 有命中 → 不改（实测 `FontSize` 命中 2 条）；
3. `node.X = ...` 里 X 首字母大写、但 `EggyAPI.lua` 查不到 → 才可能是自研字段，需另查，不要单独下结论。
待确认：`.toolcache/se-manual/game_api` 只缓存了 `README.txt`/`changelog`/`unit/RemoteEvent.txt`，`EUINodeBase.html` 等逐属性页未缓存；本次受「只新建一个文件」约束未跑 `docs sync`（sync 会写 `.toolcache`）逐条对照。

## 2. Spoke 作用域名与运行期单位名字符串

**判别依据**
- `.dsh/skills/spoke/references/runtime.md`：`dock:effect(key, block)`、Dock key、`export`/`import` 都用**非空字符串 key**；校验在 [common/packages/spoke/runtime/dock.lua:10-11](../common/packages/spoke/runtime/dock.lua) 与 `.../epoch_builder.lua:28-29`。
- ADR-0034「L2 的三类残留」第 1 条：数据串与 Spoke 作用域名同级——改名只动标识符，不动引号里的运行期名字。

**条目与来源**
- effect 键：[client/views/attack_view.lua:89](../client/views/attack_view.lua) `"AttackEnabled"`、`:101` `"AttackCaption"`、`:184` `"damage_float"`；[client/views/root_view.lua:164](../client/views/root_view.lua) `"Hud:" .. hud_name`、`:221` `"DockSync:" .. dock_id`；`main_hud_backpack_view.lua:501` `"BackpackSlotRender:" .. dock_key`（视图里 40+ 处，形如 `xx:effect("大写名", ...)`）。
- 状态频道串：[client/store/client_store.lua:25-45](../client/store/client_store.lua) 的 `"ItemBarState"`、`"SurvivalState"`、`"FishCombatState"`、`"ItemBarResult"` 等，与服务端消息频道同名、跨端。
- 单位类型串：`"EUIButton"`/`"EUITextLabel"`/`"EUILayout"`/`"EUIImage"`，作为 `World:CreateUnit` 第一参数（`attack_view.lua:79` 等 25+ 处；封装见 [client/views/root_view.lua:50-52](../client/views/root_view.lua)）。
- 运行期节点名串：`"ScreenMain"`（`attack_view.lua:70`）、`"LabelCoin"`/`"ImageCoin"`（[client/views/main_hud_vitals_view.lua:102-103](../client/views/main_hud_vitals_view.lua)），对应 `data/UINodes.lua` 的节点名。

**怎么判断**：名字在引号里，且被 (a) `effect`/`State`/`Dock`/`export`/`import` key、(b) `CreateUnit` 类型参数、(c) `FindFirstChild(名字[, true])` 参数使用 → 一律不改。改名等于改运行期协议，跨文件或跨端静默失配、不报错。
待确认：`State.new` 键串风格不统一（`"ReelOverlay.closedSession"` vs `"SurvivalOverlay.noticed_dead"`，见 `reel_overlay_view.lua:68`、`survival_overlay_view.lua:188-189`），ADR-0034 未写明 L3 是否纳入；建议维持「引号内不改」，本次不动。

## 3. data/ 导出字段与引擎 API 成员

**判别依据**：`data/*.lua` 五个导出文件；`EggyAPI.lua`；手册 `.toolcache/se-manual/lua/08-client-server-remote-event.txt:41-47`（RemoteEvent 方向表）与 `.toolcache/se-manual/game_api/unit/RemoteEvent.txt`。

**data/ 导出的表与字段风格**
| 文件 | 顶层字段 | 字段风格 |
| --- | --- | --- |
| `data/UINodes.lua` | 返回节点树数组 | `{name, type, {children}}`，如 `{"ScreenMain", "EUILayout", {...}}`；49 个节点、6 种类型（`EUITextLabel` 20、`EUIImage` 12、`EUIButton` 9、`EUILayout` 4、`EUIListView` 2、`EUISceneNode` 2） |
| `data/OfficialAsset.lua` | `effect`/`icon`/`model`/`motion`/`sound` | `["中文资源名"] = "official://..."`，7109 行 |
| `data/CustomAsset.lua` | `icon` | `["2001"] = "custom://..."` |
| `data/Prefab.lua` | `scene_eui` | `["新场景界面"] = 1073737796` |
| `data/FontData.lua` | 无顶层名 | `["宋体"] = 5` |
共同点：键全是**带引号的字符串**（中文名、数字串、文件名），没有标识符式字段；五个文件头都是 `---AUTTO EXPORT BY EGGITOR PLUGIN, PLEASE DO NOT EDIT`。

**引擎 API 成员（不改）**：`RemoteEvent:FireServer`/`FireClient`/`FireAllClients`、`OnServerEvent`/`OnClientEvent`、`RemoteEvent.New`（`EggyAPI.lua:7259-7283`；手册 `08-...txt:41-47`）；`Unit.Name`/`Unit.Parent`（`:7818-7819`）、`GetChildren`/`FindFirstChild`（[client/game_ui.lua:24](../client/game_ui.lua)、`attack_view.lua:70`）、`Destroy`、`World:CreateUnit`、`Signal:Connect`。

**怎么判断**：字段名或名字串在 `data/` 任一文件出现（节点名、资源名、图标号、字体名）→ 任何一端都不得改名。实测全仓 **0 处** `require("data.XXX")` 形态引用（检索 `data.UINodes|data.OfficialAsset|data.Prefab|data.CustomAsset|data.FontData` 无命中）：它们由编辑器导出、以字符串名被视图消费，所以**名字串是契约**，`data/` 文件名本身不进入 L3。

## 4. 与策划表列对应的配置字段

**判别依据**：`docs/design/*.xlsx`（列名全中文）+ `docs/design/策划案--渔力全开.docx`（正文数值）+ 配置行里的行锚点 `source = '<表>!R<行>'`。

**结论**：策划列名是中文，配置字段是英文 PascalCase 的语义对照；行锚点只记到行（如 `source = '钓鱼表!R2'`），**列对应只能靠字段名**。这些字段一改名，策划表↔代码的唯一线索就断了 → 一律不改。

**实例（`common/game_cfg.lua` 真实字段 ↔ 策划案列/正文）**
| # | game_cfg 字段 | 策划来源 |
| --- | --- | --- |
| 1 | `game_cfg.Fish.<id>.Health`（[common/game_cfg.lua:165](../common/game_cfg.lua) → [common/cfg/fish.lua:5](../common/cfg/fish.lua)） | 钓鱼表 F 列「血量」 |
| 2 | `game_cfg.Fish.<id>.BaseWeight` | 钓鱼表 J 列「基础重量（kg）」 |
| 3 | `game_cfg.Fish.<id>.EscapeSec` | 钓鱼表 I 列「逃跑时间」 |
| 4 | `game_cfg.Fish.<id>.ZoneId`/`Bait`/`RodLevel`/`DrawWeight` | 钓鱼表 L「钓取地图」/M「鱼饵」/N「钓竿等级」/O「权重」 |
| 5 | `game_cfg.Items.Definitions.<id>.Type`（`game_cfg.lua:56` → [common/cfg/items.lua:3](../common/cfg/items.lua)） | 物品表「物品类型」 |
| 6 | `game_cfg.Items.Definitions.<id>.EatPercent` | 物品表「食用恢复百分比」 |
| 7 | `game_cfg.Items.Definitions.<id>.BasePrice` | 物品表「基础出售价格（喂钓鱼佬）」 |
| 8 | `game_cfg.vitals.MaxHealth = 300`（`game_cfg.lua:62`）、`MaxHunger`、`HungerPerSec = 1`、`StarveDamagePerSec = 5` | 策划案正文 P38/P39：「血量总值300点」「饥饿总值300点」「每秒扣除1点」「每秒扣除5点血量」 |
| 9 | `game_cfg.Items.ItemBarSlots = 8`、`InitialItemBarSlots = 2`、`BackpackSlotsPerUpgrade = 5`、`MaxBackpackSlots = 40`（`game_cfg.lua:37-41`） | 策划案正文 P51/P53：「道具栏，2~8个」「背包格子数5~40个」 |
| 10 | [common/cfg/blindbox.lua:8](../common/cfg/blindbox.lua) 的 `weight`/`jackpot`/`number` | 地图盲盒表「抽奖权重」/「是否大奖」/「编号」 |

**怎么判断**：字段值能在 `docs/design/` 某列或策划案段落的数字/文案上对上，或该行带 `source = '<表>!R<行>'` → 不改；新增字段若源自策划列，沿用该列在配置里的既有写法（`Health` 就继续 `Health`，不要另起 `hp`）。

## 决策记录

1. **逐属性页已核准**（2026-11-24）：`lua tools/cli.lua docs sync api EUINodeBase`（另加 `EUIButton`、`EUITextLabel`）补抓三页，第 1 节属性名逐条对过、0 缺项，故本节不再是「仅据存根」的待确认项。要复核就重跑一次 `docs sync api` 再看页头 `fetched_at`。
2. **`State`/`effect`/`Dock` 的 key 串不纳入 L3**（已定）：本次一律不动引号内的运行期名字。现存两种风格（`"ReelOverlay.closedSession"` 与 `"SurvivalOverlay.noticed_dead"`）是已知的、不阻塞 L3 的现象，由上游 spoke 仓库统一，本仓不各自重命名——改了等于改运行期协议，跨端静默失配且不报错。
3. **EUI 属性名是否大小写归一：仍待实测**（工单见任务板 task-6），**L3 不依赖该结论**，也不因此延后；属性名本身在豁免清单内，无论实测结果如何都不进 L3。
