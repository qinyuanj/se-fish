# 验收矩阵索引

> 本文件是《渔力全开》规格的条款矩阵入口。`docs/GameSpec.md` 的每个小节对应本目录下的一份分片：一条条款是一句能独立判真假的话，并逐条标注组、执行者、所需证据等级与状态。
> **acceptance matrix / 验收矩阵**：_Avoid_: 验收清单、测试清单、验收文档、checklist
> 七列取值、必填项与新增条款的入口见 [TEMPLATE.md](TEMPLATE.md)；可照抄的示范样本是 [09-multiplayer-rules.md](09-multiplayer-rules.md)。
> 范围口径见 [ADR-0029](../adr/0029-scope-completeness-and-placeholder-first.md)：**规格内没有永久出界**，外部渠道事项进它的生产开关台账，不再写成阻塞。
> 每条非试玩条款由哪段代码负责、有没有测试守着，看[实现覆盖表](coverage.md)；它是文档与代码之间的静态门禁，不是证据。
> 本文件**不含手写计数**：各节条数与状态分布由扫描脚本写入下方生成块，手改会被门禁判红。
> 接手先读 [交接说明](handover.md)：矩阵满屏 `unverified` 是正常状态、a/b/C 三档证据怎么补、八条完成判据的逐条核对表。

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
> 本表由 `lua tools/cli.lua acceptance --write` 从 `docs/acceptance/NN-*.md` 的条款行生成，勿手改；
> 手改会被 `lua tools/cli.lua acceptance --check`（fast 车道门禁）判红。

| 节 | 标题 | 条款数 | unverified | evidenced | accepted | blocked | out-of-scope | 缺口密度 |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| [1](01-overview-and-scope.md) | 概述与范围 | 19 | 11 | 3 | 0 | 5 | 0 | 84% |
| [2](02-player-attributes.md) | 玩家属性 | 18 | 17 | 0 | 0 | 1 | 0 | 100% |
| [3](03-inventory-and-controls.md) | 持有与操作 | 25 | 22 | 1 | 0 | 2 | 0 | 96% |
| [4](04-fishing-system.md) | 钓鱼系统 | 31 | 25 | 3 | 0 | 3 | 0 | 90% |
| [5](05-zone-fish-data.md) | 七区鱼种完整数据 | 18 | 16 | 2 | 0 | 0 | 0 | 89% |
| [6](06-combat-and-growth.md) | 战斗与成长 | 38 | 31 | 4 | 0 | 3 | 0 | 89% |
| [7](07-economy-and-shop.md) | 经济与钓场商店 | 27 | 21 | 5 | 0 | 1 | 0 | 81% |
| [8](08-npc-exchange-ferry.md) | NPC、兑换与摆渡 | 41 | 34 | 0 | 0 | 7 | 0 | 100% |
| [9](09-multiplayer-rules.md) | 多人规则 | 25 | 2 | 20 | 0 | 3 | 0 | 20% |
| [10](10-grilling.md) | 烧烤 | 28 | 15 | 11 | 0 | 2 | 0 | 61% |
| [11](11-downed-death-revive.md) | 濒死、死亡与复活 | 42 | 23 | 16 | 0 | 3 | 0 | 62% |
| [12](12-elite-boss-behavior.md) | 精英与首领行为 | 55 | 13 | 35 | 0 | 7 | 0 | 36% |
| [13](13-compendium-achievements.md) | 图鉴与成就 | 18 | 9 | 8 | 0 | 1 | 0 | 56% |
| [14](14-lottery.md) | 抽奖机 | 28 | 15 | 8 | 0 | 5 | 0 | 71% |
| [15](15-map-blindbox.md) | 地图盲盒 | 21 | 13 | 5 | 0 | 3 | 0 | 76% |
| [16](16-item-base-data.md) | 物品基础数据 | 17 | 14 | 3 | 0 | 0 | 0 | 82% |
| [17](17-tutorial-story-platform.md) | 新手任务、剧情与平台边界 | 22 | 20 | 2 | 0 | 0 | 0 | 91% |
| [18](18-save-and-recovery.md) | 存档与恢复契约 | 32 | 9 | 23 | 0 | 0 | 0 | 28% |
| [19](19-acceptance-criteria.md) | 验收口径 | 20 | 12 | 2 | 0 | 6 | 0 | 90% |
| 合计 | — | 525 | 322 | 151 | 0 | 52 | 0 | 71% |

已取证（evidenced + accepted）151 / 525；缺口密度 71% =（unverified + blocked + out-of-scope）÷ 条款数，其中 out-of-scope 占 0%。
<!-- END GENERATED: acceptance-counts -->
