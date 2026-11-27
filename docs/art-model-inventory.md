# 自定义模型清单与缺口台账

> 盘点日期：2026-11-27  
> 数据来源：编辑器自定义模型资产（`AssetService:ListCustomAssets('Mesh')` 与各资产包 `.animconfig`）  
> 业务配置对照：[common/cfg/fish.lua](../common/cfg/fish.lua)（56 种活体 `SourceId = 1..56`）、[common/game_cfg.lua](../common/game_cfg.lua)（`GameCfg.Ferry.Routes`）  
> 相关制作与验收约束已随美术创作工作流归档至 tag `art-workflow-archive-v1`（`git show art-workflow-archive-v1:docs/art-asset-overview.md`）。

## 概览

当前编辑器账号中共保留 **49 个**有效自定义模型（2026-11-27 导入批次）：

- **活体鱼类模型**：**47 种**（对照 56 种基础生物，尚缺 **9 种**）
- **场景载具模型**：**2 个**（`ferry_boat`、`ferry_cart`）
- **配置对应口径**：
  - `fish_XXX` 的数字编号对应 `common/cfg/fish.lua` 的 `SourceId`；普通与极品共用同一模型。
  - 例外说明：`fish_004`（鲈鱼）对应 `bass` / `item11`（极品鲈鱼），`fish_005`（鲶鱼）对应 `catfish` / `item10`（极品鲶鱼）——按鱼名归位，原因见 `common/cfg/fish.lua` 顶部注释。

### 动画分组总览

| 分组 | 动画片段名（`AnimatedUnit:PlayAnimation`） | 数量 | 说明 |
| --- | --- | ---: | --- |
| **A. 通用鱼类 3 动画** | `Attack_Bite`, `Swim_1`, `Swim_2` | 25 | 全部共享完全相同的 3 份动画数据（MD5 一致） |
| **B. 独立专属动画** | 各自带 `fish_XXX_a_*` 前缀，互不相同 | 6（6 组） | 虾霸（3 动作）、蟹老板/哥斯拉（各 2 动作）、海参/企鹅/海绵（各 1 动作） |
| **C. 无动画** | 无 | 18 | 16 种生物 + 2 个摆渡载具；其中 3 种带骨架但未挂动画 |
| **合计** | — | **49** | — |

---

## 组 A：通用鱼类 3 动画（25 个）

动画片段：`Attack_Bite`、`Swim_1`、`Swim_2`（25 个模型动画数据 MD5 完全一致：`4f36d3b8` / `ac0356f4` / `c23b9c24`）。

| 模型名 | Asset URI | 对应名称 | 钓区 | 品级 | 配置 ID（普通 / 极品） | 三角面 | 备注 |
| --- | --- | --- | --- | --- | --- | ---: | --- |
| `fish_001` | `custom://0h573vyTyI4YdAO8s` | 罗非鱼 | 鱼塘 | 普通/极品 | `tilapia` / `item7` | 2586 | |
| `fish_002` | `custom://0h573zlC3XBo9cItU` | 鲤鱼 | 鱼塘 | 普通/极品 | `carp` / `item8` | 1702 | |
| `fish_003` | `custom://0h5743hWoEyCawa4k` | 刀鱼 | 鱼塘 | 普通/极品 | `knifeFish` / `item9` | 3992 | |
| `fish_004` | `custom://0h5749JcVMVIup0vY` | 鲈鱼 | 鱼塘 | 普通/极品 | `bass` / `item11` | 2008 | `item11` 原表 `SourceId=5`，按鱼名归位 |
| `fish_005` | `custom://0h574DUfKQ3x1SWHW` | 鲶鱼 | 鱼塘 | 普通/极品 | `catfish` / `item10` | 9950 | `item10` 原表 `SourceId=4`，按鱼名归位 |
| `fish_006` | `custom://0h574I3FO2ErGuHmT` | 金鱼 | 鱼塘 | 普通/极品 | `goldfish` / `item12` | 2288 | |
| `fish_007` | `custom://0h574MOedERH1NUXg` | 电鳗 | 鱼塘 | 精英 | `eel` | 9378 | |
| `fish_026` | `custom://0h575SljDUkjJoCWq` | 比目鱼 | 树林岛 | 普通/极品 | `item50` / `item56` | 2172 | |
| `fish_027` | `custom://0h575X0lrkqxrkq3c` | 三文鱼 | 树林岛 | 普通/极品 | `item51` / `item57` | 2786 | |
| `fish_028` | `custom://0h577DWgeHrBiTYlI` | 翻车鲀 | 树林岛 | 普通/极品 | `item52` / `item58` | 1260 | 已删除较早的重复上传 `0h575aOoRtbt5OD2U` |
| `fish_029` | `custom://0h577HBBKayovrwBd` | 鳐鱼 | 树林岛 | 普通/极品 | `item53` / `item59` | 2121 | |
| `fish_030` | `custom://0h575hHkjvUmDM1S9` | 旗鱼 | 树林岛 | 普通/极品 | `item54` / `item60` | 2528 | |
| `fish_031` | `custom://0h575l9fHnBOuhgSB` | 剑鱼 | 树林岛 | 精英 | `fish31Elite` | 2177 | |
| `fish_032` | `custom://0h575pPM1xVMfxYTS` | 三头鲨 | 树林岛 | 首领 | `fish32Boss` | 3886 | |
| `fish_034` | `custom://0h577KZnSt5fRJ6Dq` | 海兔 | 沙滩岛 | 普通/极品 | `item66` / `item72` | 2466 | |
| `fish_035` | `custom://0h5761WbtKvtd1uMu` | 海马 | 沙滩岛 | 普通/极品 | `item67` / `item73` | 3436 | |
| `fish_036` | `custom://0h5765gCtrp83PO7u` | 海狗 | 沙滩岛 | 普通/极品 | `item68` / `item74` | 3138 | |
| `fish_037` | `custom://0h5769lEsexstcd58` | 海狮 | 沙滩岛 | 普通/极品 | `item69` / `item75` | 2520 | |
| `fish_038` | `custom://0h576EM4QRH9BS09F` | 海牛 | 沙滩岛 | 普通/极品 | `item70` / `item76` | 9941 | |
| `fish_039` | `custom://0h577NcfEHNBxdNsK` | 海象 | 沙滩岛 | 精英 | `fish39Elite` | 9950 | |
| `fish_040` | `custom://0h576N5OG8LIYRyZo` | 虎鲸 | 沙滩岛 | 首领 | `fish40Boss` | 2452 | |
| `fish_052` | `custom://0h577SuctlWOCmEdA` | 鱼龙 | 火山岛 | 普通/极品 | `item100` / `item106` | 9950 | |
| `fish_053` | `custom://0h576k80960uaUU6c` | 蛇颈龙 | 火山岛 | 普通/极品 | `item101` / `item107` | 2956 | |
| `fish_054` | `custom://0h576o5PlYtvQ8DBk` | 美人鱼 | 火山岛 | 普通/极品 | `item102` / `item108` | 6888 | |
| `fish_055` | `custom://0h576rzBGgI7VxKGb` | 沧龙 | 火山岛 | 精英 | `fish55Elite` | 6432 | |

---

## 组 B：独立专属动画（6 组，共 6 个）

以下 6 个模型均自带独立骨骼与独立命名动画片段，各自成组：

| 分组 | 模型名 | Asset URI | 对应名称 | 钓区 | 品级 | 配置 ID（普通 / 极品） | 三角面 | 动画片段列表 |
| --- | --- | --- | --- | --- | --- | --- | ---: | --- |
| B1（3 动作） | `fish_015` | `custom://0h574nOwvGlRkROpR` | 虾霸 | 虾池 | 精英 | `fish15Elite` | 4002 | `fish_015_a_attack_1`, `fish_015_a_attack_2`, `fish_015_a_walk` |
| B2（2 动作） | `fish_024` | `custom://0h575LQxQxQaIGF15` | 蟹老板 | 蟹湖 | 首领 | `fish24Boss` | 1880 | `fish_024_a_attack`, `fish_024_a_walk` |
| B3（2 动作） | `fish_056` | `custom://0h576wxaCb0l7b0m2` | 哥斯拉 | 火山岛 | 首领 | `fish56Boss` | 10000 | `fish_056_a_attack`, `fish_056_a_walk` |
| B4（1 动作） | `fish_033` | `custom://0h575tTkJQvwpw5Ic` | 海参 | 沙滩岛 | 普通/极品 | `item65` / `item71` | 7977 | `fish_033_a_walk` |
| B5（1 动作） | `fish_042` | `custom://0h576RFkJMUUJSMWl` | 企鹅 | 礁石岛 | 普通/极品 | `item82` / `item88` | 2484 | `fish_042_a_walk` |
| B6（1 动作） | `fish_051` | `custom://0h576cZCngziPZ1fn` | 海绵 | 火山岛 | 普通/极品 | `item99` / `item105` | 3831 | `fish_051_a_walk` |

---

## 组 C：无动画模型（18 个）

| 模型名 | Asset URI | 对应名称 | 钓区 / 用途 | 品级 | 配置 ID（普通 / 极品） | 三角面 | 骨架状态 |
| --- | --- | --- | --- | --- | --- | ---: | --- |
| `fish_009` | `custom://0h574Q0uz6IFpOE1e` | 虾米 | 虾池 | 普通/极品 | `shrimp` / `rareShrimp` | 3390 | 无骨架 |
| `fish_010` | `custom://0h574TemqjCjL2fYZ` | 沼虾 | 虾池 | 普通/极品 | `riverShrimp` / `rareRiverShrimp` | 3006 | 无骨架 |
| `fish_011` | `custom://0h574Xi6yUuClmFe6` | 小龙虾 | 虾池 | 普通/极品 | `crayfish` / `rareCrayfish` | 2218 | 无骨架 |
| `fish_012` | `custom://0h574b3PR7xqojDv4` | 波龙 | 虾池 | 普通/极品 | `bostonLobster` / `rareBostonLobster` | 2658 | 无骨架 |
| `fish_013` | `custom://0h574edbj0K0kIt2Z` | 澳龙 | 虾池 | 普通/极品 | `aussieLobster` / `rareAussieLobster` | 2811 | 无骨架 |
| `fish_014` | `custom://0h574iIpjOmQiauJJ` | 奶龙 | 虾池 | 普通/极品 | `milkLobster` / `rareMilkLobster` | 2819 | **有骨架**（未挂动画） |
| `fish_017` | `custom://0h574s5i6vEHyoOao` | 蟛蜞 | 蟹湖 | 普通/极品 | `item33` / `item39` | 9447 | 无骨架 |
| `fish_018` | `custom://0h574vJM41e5EKg5P` | 寄居蟹 | 蟹湖 | 普通/极品 | `item34` / `item40` | 2267 | 无骨架 |
| `fish_019` | `custom://0h574yxxslfXKzJWx` | 大闸蟹 | 蟹湖 | 普通/极品 | `item35` / `item41` | 3706 | 无骨架 |
| `fish_020` | `custom://0h5754A4pQ9HuFGpA` | 梭子蟹 | 蟹湖 | 普通/极品 | `item36` / `item42` | 9943 | 无骨架 |
| `fish_021` | `custom://0h57587tARmGOwZJ9` | 青蟹 | 蟹湖 | 普通/极品 | `item37` / `item43` | 2679 | 无骨架 |
| `fish_022` | `custom://0h575BT6mcjJWbHAB` | 面包蟹 | 蟹湖 | 普通/极品 | `item38` / `item44` | 2629 | 无骨架 |
| `fish_023` | `custom://0h575GHOqy8fgl516` | 帝王蟹 | 蟹湖 | 精英 | `fish23Elite` | 9752 | 无骨架 |
| `fish_025` | `custom://0h575OitLdr632Bbr` | 海胆 | 树林岛 | 普通/极品 | `item49` / `item55` | 2644 | 无骨架 |
| `fish_049` | `custom://0h576V4S1K1m3lT0x` | 章鱼 | 火山岛 | 普通/极品 | `item97` / `item103` | 3289 | **有骨架**（未挂动画） |
| `fish_050` | `custom://0h576YjATSmoddZLy` | 海星 | 火山岛 | 普通/极品 | `item98` / `item104` | 4139 | **有骨架**（未挂动画） |
| `ferry_boat` | `custom://0h573nzXec7leJ4jq` | 摆渡船 | 跨区摆渡 | 场景载具 | `GameCfg.Ferry.Routes` | 2905 | 无骨架 |
| `ferry_cart` | `custom://0h573rCD5r3yi1Qqp` | 摆渡车 | 跨区摆渡 | 场景载具 | `GameCfg.Ferry.Routes` | 4100 | 无骨架 |

---

## 缺口清单

### 1. 未导入的活体模型（9 种，对照 `SourceId` 1~56）

| 预期模型名 | `SourceId` | 名称 | 钓区 | 品级 | 配置 ID（普通 / 极品） | 垂钓来源 | 说明 |
| --- | ---: | --- | --- | --- | --- | --- | --- |
| `fish_008` | 8 | 鳄雀鳝 | 鱼塘 | 首领 | `alligatorGar` | `water` | 历史试点资产（见 `art-asset-overview.md`）不在当前账号列表中，需确认并补导入 |
| `fish_016` | 16 | 小白龙 | 虾池 | 首领 | `fish16Boss` | `water` | 未导入 |
| `fish_041` | 41 | 巨脉蜻蜓 | 礁石岛 | 普通/极品 | `item81` / `item87` | `air` | 礁石岛空中生物，未导入 |
| `fish_043` | 43 | 飞鱼 | 礁石岛 | 普通/极品 | `item83` / `item89` | `air` | 礁石岛空中生物，未导入 |
| `fish_044` | 44 | 海鸥 | 礁石岛 | 普通/极品 | `item84` / `item90` | `air` | 礁石岛空中生物（离线接缝 B 已过），未导入当前账号 |
| `fish_045` | 45 | 军舰鸟 | 礁石岛 | 普通/极品 | `item85` / `item91` | `air` | 礁石岛空中生物，未导入 |
| `fish_046` | 46 | 信天翁 | 礁石岛 | 普通/极品 | `item86` / `item92` | `air` | 礁石岛空中生物，未导入 |
| `fish_047` | 47 | 白头鹰 | 礁石岛 | 精英 | `fish47Elite` | `air` | 礁石岛空中精英，未导入 |
| `fish_048` | 48 | 风神翼龙 | 礁石岛 | 首领 | `fish48Boss` | `air` | 礁石岛空中首领，未导入 |

### 2. 已导入模型的动画与骨架缺口

- **有骨架但未挂动画（3 种）**：`fish_014`（奶龙）、`fish_049`（章鱼）、`fish_050`（海星）包内含 `.skeleton` 但无任何 `.animation` 片段，需确认是导入时漏挂动画，还是改为程序动画兜底。
- **无骨架无动画的活体生物（13 种）**：
  - 虾池 5 种普通虾：`fish_009`（虾米）、`fish_010`（沼虾）、`fish_011`（小龙虾）、`fish_012`（波龙）、`fish_013`（澳龙）
  - 蟹湖 6 种普通蟹 + 精英：`fish_017`（蟛蜞）、`fish_018`（寄居蟹）、`fish_019`（大闸蟹）、`fish_020`（梭子蟹）、`fish_021`（青蟹）、`fish_022`（面包蟹）、`fish_023`（帝王蟹，**精英**）
  - 树林岛：`fish_025`（海胆）
- **精英 / 首领专属动作缺口提示**：
  - `fish_023`（帝王蟹，精英）当前**无动画**。
  - `fish_007`（电鳗）、`fish_031`（剑鱼）、`fish_032`（三头鲨）、`fish_039`（海象）、`fish_040`（虎鲸）、`fish_055`（沧龙）当前均复用通用鱼类 3 动画（`Attack_Bite` / `Swim_1` / `Swim_2`），如招式演出需要独立技能动作需后续补齐。
- **面数超标提示（对照 `art-asset-overview.md` 候选上限）**：
  - 普通鱼候选上限约 3000 面、精英 5000 面、首领 8000 面；当前接近 10000 面的有：`fish_005`（鲶鱼 9950）、`fish_007`（电鳗 9378）、`fish_017`（蟛蜞 9447）、`fish_020`（梭子蟹 9943）、`fish_023`（帝王蟹 9752）、`fish_033`（海参 7977）、`fish_038`（海牛 9941）、`fish_039`（海象 9950）、`fish_052`（鱼龙 9950）、`fish_054`（美人鱼 6888）、`fish_055`（沧龙 6432）、`fish_056`（哥斯拉 10000）。需在压力场景下复核性能预算。

### 3. 验收与接入状态

- 当前 49 个模型仅完成**导入上传与资产包动画清单盘点**，尚未逐个写入 [common/cfg/fish.lua](../common/cfg/fish.lua) 的 `Model` 字段，也尚未完成接缝 A（游戏内尺寸、原点贴地与逐段动画画面验收）。
- `data/CustomAsset.lua` 仍保留历史导出快照，下次从编辑器导出同步后将自动更新。

---

## 清理记录（2026-11-27）

| 类型 | 模型名 | 已删除 Asset URI | 删除方式 |
| --- | --- | --- | --- |
| 重复上传 | `fish_028` | `custom://0h575aOoRtbt5OD2U` | 开发者手动删除（保留 `custom://0h577DWgeHrBiTYlI`） |
| 历史旧模型（2026-09） | `罗飞鱼` | `custom://0gwLQKVJ3QlXPuJFh` | `AssetService:DeleteAssets` 云端与本地彻底删除 |
| 历史旧模型（2026-09） | `罗飞鱼` | `custom://0gwLZXEJ0U08NJWvm` | `AssetService:DeleteAssets` 云端与本地彻底删除 |
| 历史旧模型（2026-09） | `罗飞鱼` | `custom://0gwLb2ksZFlFQiOWD` | `AssetService:DeleteAssets` 云端与本地彻底删除 |
| 历史旧模型（2026-09） | `凤模型` | `custom://0gwbUpAGZeISEYwBm` | `AssetService:DeleteAssets` 云端与本地彻底删除 |
