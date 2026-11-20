# 验收矩阵索引

> 本文件是《渔力全开》规格的条款矩阵入口。`docs/GameSpec.md` 的每个小节对应本目录下的一份分片：一条条款是一句能独立判真假的话，并逐条标注组、执行者、所需证据等级与状态。
> 七列取值、必填项与新增条款的入口见 [TEMPLATE.md](TEMPLATE.md)；可照抄的示范样本是 [09-multiplayer-rules.md](09-multiplayer-rules.md)。
> 本文件**不含手写计数**：各节条数与状态分布由扫描脚本写入下方生成块，手改会被门禁判红。

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
| 9 | 多人规则 | [09-multiplayer-rules.md](09-multiplayer-rules.md) | 小队、PK、他人抢救三组条款与必须保留的接口接缝 |
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
（本节由 `lua tools/cli.lua acceptance` 生成，勿手改）
<!-- END GENERATED: acceptance-counts -->
