# 验收矩阵索引

> 本文件是《渔力全开》规格的条款入口。`docs/GameSpec.md` 的每个小节对应本目录下的一份分片：一条条款是一句能独立判真假的话，证据等级写成文案的行尾后缀，走到哪一步由脚本从证据文件反推。
> **Acceptance matrix / 验收矩阵**：_Avoid_: 验收清单、测试清单、验收文档、checklist
> 两列格式、等级口径与新增条款的入口见 [TEMPLATE.md](TEMPLATE.md)；可照抄的示范样本是 [09-multiplayer-rules.md](09-multiplayer-rules.md)。
> 范围口径见 [ADR-0029](../adr/0029-scope-completeness-and-placeholder-first.md)：**规格内没有永久出界**，外部渠道事项进[生产开关台账](production-switches.md)，不再写成阻塞。
> 每份分片带三节驾驶说明：从玩家视角怎么走到这个功能、用 `tools/cli.lua` 怎么从零走一遍、容易踩的坑。状态不手写：A/B 级看 `tests/native/spec/` 与 `tests/probes/` 的正文，C 级看 `evidence/*/session.md` 的 `✅` 行。
> 本文件**不含手写计数**：各节条数与状态分布由扫描脚本写入下方生成块，手改会被门禁判红。
> 接手先读 [交接说明](handover.md)：矩阵满屏 `unverified` 是正常状态、A/B/C 三档证据怎么补、怎么新增条款。

## 小节清单

| 节号 | 标题 | 分片 | 一句话说明 |
| --- | --- | --- | --- |
| 1 | 概述与范围 | [01-overview-and-scope.md](01-overview-and-scope.md) | 工程定位、单人可完成性与共享世界，以及外部交付依赖的边界 |
| 2 | 玩家属性 | [02-player-attributes.md](02-player-attributes.md) | 血量、体型、移速与饥饿的基础值、成长与上限 |
| 3 | 持有与操作 | [03-inventory-and-controls.md](03-inventory-and-controls.md) | 界面布局、库存进出规则与选中/手持分离 |
| 4 | 钓鱼系统 | [04-fishing-system.md](04-fishing-system.md) | 抛竿、上钩、收线的完整流程与鱼饵消耗 |
| 5 | 七区鱼种完整数据 | [05-zone-fish-data.md](05-zone-fish-data.md) | 各钓鱼区的鱼种数值表与表外裁决口径 |
| 6 | 战斗与成长 | [06-combat-and-growth.md](06-combat-and-growth.md) | 武器规则、伤害结算与成长升级 |
| 7 | 经济与钓场商店 | [07-economy-and-shop.md](07-economy-and-shop.md) | 各货币的来源去向与钓场商店的分页规则 |
| 8 | NPC、兑换与摆渡 | [08-npc-exchange-ferry.md](08-npc-exchange-ferry.md) | 钓鱼佬回收、信物兑换、双向摆渡与地面物品刷新 |
| 9 | 多人规则 | [09-multiplayer-rules.md](09-multiplayer-rules.md) | 小队、PK、他人抢救三组条款与必须保留的接口接缝；功能组随依赖排期，不划出范围 |
| 10 | 烧烤 | [10-grilling.md](10-grilling.md) | 烤制倍率曲线、取出结算与烤糊的失败路径 |
| 11 | 濒死、死亡与复活 | [11-downed-death-revive.md](11-downed-death-revive.md) | 濒死倒计时、免费与付费复活、肾上腺素 |
| 12 | 精英与首领行为 | [12-elite-boss-behavior.md](12-elite-boss-behavior.md) | 精英与首领的招式表口径与阶段切换 |
| 13 | 图鉴与成就 | [13-compendium-achievements.md](13-compendium-achievements.md) | 收集记录、个人最大重量与全服纪录 |
| 14 | 抽奖机 | [14-lottery.md](14-lottery.md) | 三轴独立抽样、两同金币与三同大奖 |
| 15 | 地图盲盒 | [15-map-blindbox.md](15-map-blindbox.md) | 抽价、奖池构成与连续未中保底 |
| 16 | 物品基础数据 | [16-item-base-data.md](16-item-base-data.md) | 物品表的分类、可食用性与改名裁决 |
| 17 | 新手任务、剧情与平台边界 | [17-tutorial-story-platform.md](17-tutorial-story-platform.md) | 新手引导九步、开场对话与外部交付参数 |
| 18 | 存档与恢复契约 | [18-save-and-recovery.md](18-save-and-recovery.md) | 存档字段、版本升级与恢复的幂等语义 |
| 19 | 验收口径 | [19-acceptance-criteria.md](19-acceptance-criteria.md) | 正常新档通关、数据导入核对与外部依赖的验收口径 |

## 计数（脚本生成）

<!-- BEGIN GENERATED: acceptance-counts -->
> 本表由 `lua tools/cli.lua acceptance --write` 从 `docs/acceptance/NN-*.md` 与证据文件生成，勿手改；
> 手改会被 `lua tools/cli.lua acceptance --check`（fast 车道门禁）判红。

| 节 | 标题 | 条款数 | evidenced | blocked | unverified | 缺口密度 |
| --- | --- | --- | --- | --- | --- | --- |
| [1](01-overview-and-scope.md) | 概述与范围 | 19 | 3 | 5 | 11 | 84% |
| [2](02-player-attributes.md) | 玩家属性 | 18 | 0 | 1 | 17 | 100% |
| [3](03-inventory-and-controls.md) | 持有与操作 | 25 | 1 | 2 | 22 | 96% |
| [4](04-fishing-system.md) | 钓鱼系统 | 31 | 3 | 3 | 25 | 90% |
| [5](05-zone-fish-data.md) | 七区鱼种完整数据 | 18 | 2 | 0 | 16 | 89% |
| [6](06-combat-and-growth.md) | 战斗与成长 | 38 | 6 | 3 | 29 | 84% |
| [7](07-economy-and-shop.md) | 经济与钓场商店 | 27 | 5 | 1 | 21 | 81% |
| [8](08-npc-exchange-ferry.md) | NPC、兑换与摆渡 | 41 | 0 | 7 | 34 | 100% |
| [9](09-multiplayer-rules.md) | 多人规则 | 25 | 20 | 3 | 2 | 20% |
| [10](10-grilling.md) | 烧烤 | 28 | 11 | 2 | 15 | 61% |
| [11](11-downed-death-revive.md) | 濒死、死亡与复活 | 42 | 16 | 3 | 23 | 62% |
| [12](12-elite-boss-behavior.md) | 精英与首领行为 | 55 | 37 | 7 | 11 | 33% |
| [13](13-compendium-achievements.md) | 图鉴与成就 | 18 | 9 | 1 | 8 | 50% |
| [14](14-lottery.md) | 抽奖机 | 28 | 8 | 5 | 15 | 71% |
| [15](15-map-blindbox.md) | 地图盲盒 | 21 | 5 | 3 | 13 | 76% |
| [16](16-item-base-data.md) | 物品基础数据 | 17 | 3 | 0 | 14 | 82% |
| [17](17-tutorial-story-platform.md) | 新手任务、剧情与平台边界 | 22 | 2 | 0 | 20 | 91% |
| [18](18-save-and-recovery.md) | 存档与恢复契约 | 32 | 23 | 0 | 9 | 28% |
| [19](19-acceptance-criteria.md) | 验收口径 | 20 | 2 | 6 | 12 | 90% |
| 合计 | — | 525 | 156 | 52 | 317 | 70% |

已取证 156 / 525；缺口密度 70% =（unverified + blocked）÷ 条款数。
<!-- END GENERATED: acceptance-counts -->
