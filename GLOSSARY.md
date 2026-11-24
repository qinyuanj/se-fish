# 钓鱼怎么这么危险啊喂！术语表

统一玩法命名与易混概念。玩法规则见 [GameSpec](docs/GameSpec.md) 的资料优先级。

**命名规则**：一个术语同时给出英文与中文，**英文在前、中文在后**，写作 `**English / 中文**`。英文句首大写、其余小写，取自代码标识符（`reel_progress` → `Reel`），代码标识符一律用英文。一个术语一条，不把两个概念塞进一个标题。`_Avoid_` 列中英双语，只在确有混淆风险时列英文。

## 世界

**Solo clear / 单人可完成**：一名玩家无需协助即可完成多人共享世界中的通关与成长流程。
_Avoid_: 单机版、单人模式、独立单人逻辑、single-player mode

**Fishing zone / 钓鱼区**：可独立钓鱼、拥有配套鱼群与设施的场景。
_Avoid_: 关卡、岛、地图、区域（复合专名与平台术语除外）、level、island

**Safe zone / 安全区**：玩家互相免伤的钓鱼区。

**PK zone / PK 区**：非同队玩家可互相伤害的钓鱼区。

**Plot / 地块**：钓鱼区内由空气墙围住、玩家可行走的陆地。
_Avoid_: 平台、地板（编辑器单位名除外）

**Zone marker / 区域标记**：表达钓鱼区边界、水域或落点等几何位置的场景标记。

**Safe spot / 安全落点**：钓鱼区内供玩家落脚的基准点，属于区域标记。
_Avoid_: 出生点、复活点

**Bait spot / 鱼饵刷新点**：周期性刷出鱼饵的固定位置，属于区域标记。
_Avoid_: 蚯蚓点、worm point

**Spawn point / 出生点**：玩家进入地图时站立的引擎出生单位。
_Avoid_: 出生点位、复活点

**Squad / 小队**：玩家结成的互相免伤的团体。
_Avoid_: 队伍、阵营、team、party

## 鱼与钓鱼

**Fish / 鱼**：可被钓取、上岸后仍存活并按品级行动的生物。
_Avoid_: 怪物、怪（指鱼时）、monster、mob

**Loot / 鱼获**：鱼类产出的可持有物品，包括击杀掉落与盲盒直接生成的极品鱼获。
_Avoid_: 食物、海鲜（代指鱼获时）、catch

**Tier / 品级**：鱼在行为、掉落与奖励规则中使用的分类，包括普通、极品、精英、首领。
_Avoid_: 类型、BOSS、精英怪、type、rarity

**Multiplier / 个体倍率**：每条鱼上钩时随机得到、共同决定重量与鱼获价格的系数。
_Avoid_: 随机参数、随机倍率、random factor

**Bite / 上钩**：鱼咬线的时刻。
_Avoid_: 咬钩

**Reel / 收线**：上钩后玩家点击与鱼拉锯、争取使鱼上岸的过程。
_Avoid_: 拉线、fishing minigame

**Unhook / 脱钩**：收线失败、鱼未上岸即消失。

**Escape / 逃脱**：已上岸的活鱼回水消失。
_Avoid_: 逃跑（指逃脱结果时）

**Lift / 举鱼**：上岸后鱼被玩家顶在头上的状态。
_Avoid_: 顶鱼

**Drop / 放下**：玩家解除举鱼、使鱼开始按品级行动。

## 物品与持有

**Item / 物品**：可持有之物的总称；过关道具、自救道具、属性道具是其中的分类。
_Avoid_: 道具（作总称时）、prop

**Token / 信物**：精英鱼或首领独有的鱼获。
_Avoid_: 任务物品、独有道具、部件、relic、badge

**Boss bait / 首领饵**：由信物换得、必定钓出对应首领的鱼饵。
_Avoid_: BOSS 专用鱼饵

<a id="船票"></a>

**Ferry ticket / 船票**：去程摆渡消耗的凭证，物品类型为过关道具。
_Avoid_: 车票（作通用术语时；正式物品名除外）、门票

**Rod / 鱼竿**：带等级的钓具。
_Avoid_: 钓竿、杆子、fishing pole

**Potion / 药水**：食用后永久提升属性的消耗品。

**Upgrade / 升级**：购买后立即永久生效、不占物品格的提升。
_Avoid_: 强化、强化品

**Prize weapon / 武器大奖**：抽奖获得、具有独立攻击数值与效果的武器，不是升级。
_Avoid_: 武器皮肤、纯外观奖励、weapon skin

**Special item / 特殊道具**：选中后赋予特殊行动能力的物品，如风神之翼、哥斯拉。

**Grilled fish / 烤鱼**：加工过的鱼获，失去抽奖与信物兑换资格。

**Burnt fish / 烤糊**：烤制过头导致鱼获损毁并爆炸。

**weapon slot / 武器栏**：装备一种武器的固定栏位。

**Bait slot / 鱼饵栏**：装备一种鱼饵的固定栏位；武器与普通鱼饵有独立库存，首领饵占物品格。

**Item bar / 道具栏**：可选中使用物品的栏位。
_Avoid_: 通用背包栏、快捷栏、hotbar

**Inventory / 背包**：存放物品、须移至道具栏才能使用的空间。

**Held / 手持**：当前实际拿在手中的物品。

## NPC 与设施

**Fisherman / 钓鱼佬**：回收物品的 NPC。

**Feed / 喂食**：向钓鱼佬出售物品或交付信物兑换奖励。

**Shopkeeper / 钓场老板**：售卖 NPC。
_Avoid_: 鱼塘老板、merchant

**Shop / 钓场商店**：以金币购买鱼竿、鱼饵、武器与升级的商店。

**Stand / 摊位**：钓场商店的售卖点，每个钓鱼区一个。
_Avoid_: 商店（指摊位时）、店铺、柜台

**Stand level / 摊位等级**：摊位上架商品的门槛等级，等级越高兼容越多商品。
_Avoid_: 商店等级、shop level

**Ferry / 摆渡**：钓鱼区之间的通行方式，包括去程与返程。
_Avoid_: 顺风船、过关（指摆渡时）

**Outbound / 去程**：交船票后前往下一钓鱼区的行程。

**Hitchhike / 搭便船**：去程中未交船票、随已交票玩家同行的行为。
_Avoid_: 蹭车

**Return / 返程**：按人支付金币、返回上一钓鱼区的行程。

**Grill point / 烧烤点**：加工鱼获的设施，涵盖篝火、烤炉、火山口等形态。

**Lottery machine / 抽奖机**：以**极品食物**（极品鱼获与信物）为赌注，产出金币或大奖的设施。
_Avoid_: 老虎机、拉霸、游戏机、slot machine

**Blindbox / 盲盒**：付费抽取极品鱼获的平台功能。
_Avoid_: loot box

## 玩家状态与成长

**Downed / 濒死**：血量耗尽后的锁血倒地状态。

**Rescue / 抢救**：其他玩家解除其濒死。
_Avoid_: 复活（指解除濒死时）

**Revive / 复活**：死亡后重新回到场上。

**Weak revive / 虚弱复活**：等待后以低血量复活的方式，复活后进入虚弱。

**Weak / 虚弱**：虚弱复活后持续一段时间的减速状态。

**Full revive / 满血复活**：通过广告或金豆立即满血复活。

**Coin / 金币**：本地图内的游戏币。
_Avoid_: 金、钱（代指金币时）、gold

**Bean / 金豆**：平台充值货币。

**Park coin / 乐园币**：平台可免费获得的货币。

**Platform shop / 地图商店**：以金豆或乐园币支付的平台商店。使用时写全称，以区别钓场商店。

**Compendium / 图鉴**：鱼的收集册，包含个人最大钓取重量。
_Avoid_: 图册、catalog

**records / 纪录**：某种鱼在所有玩家中的最大重量及保持者。
_Avoid_: 极限重量、排名（指纪录时）、ranking、leaderboard

## 验收与范围

**Gameplay implementation / 玩法实现**：能让一条验收条款成立的三端业务代码——`client/`、`common/`、`server/` 下的业务模块与共享配置。条目的真源是[实现覆盖表](docs/acceptance/coverage.md)。
_Avoid_: 实现范围、代码范围、实现度、implementation coverage

**Business scope / 业务范围**：质量工具与架构图度量的源码集合，不含任何 `packages/` 子树；机器真源是根目录 `uml-quality.json` 与 `policy.edn`，决策见 [ADR-0021](docs/adr/0021-packages-outside-business-scope.md)、范围口径见 [ADR-0029](docs/adr/0029-scope-completeness-and-placeholder-first.md)、用法见[开发工作流](docs/agents/workflow.md)。
_Avoid_: 玩法实现、交付范围、scope（单独使用时）

两个词不混用：问「这条玩家规则由哪段代码负责」用玩法实现；问「质量工具量哪些文件」用业务范围。
