# 钓鱼怎么这么危险啊喂！术语表

统一命名与易混概念。玩法规则见 [GameSpec](docs/GameSpec.md) 的资料优先级；工程操作见[开发工作流](docs/agents/workflow.md)。

**命名规则**：一个术语同时给出英文与中文，**英文在前、中文在后**，写作 `**English / 中文**`。英文句首大写、其余小写，取自代码标识符（`ReelProgress` → `Reel`），代码标识符一律用英文。一个术语一条，不把两个概念塞进一个标题。`_Avoid_` 列中英双语，只在确有混淆风险时列英文。

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

**Safe spot / 安全落点**：钓鱼区内供玩家落脚的基准点，属于区域标记；摆渡目的地、飞行高度基准与首领场地中心都取它。
_Avoid_: 出生点、复活点

**Bait spot / 鱼饵刷新点**：周期性刷出鱼饵的固定位置，属于区域标记。
_Avoid_: 蚯蚓点、worm point

**Spawn point / 出生点**：玩家进入地图时站立的引擎出生单位，全图只有 01 鱼塘一个，位置与所在钓鱼区的安全落点重合。
_Avoid_: 出生点位、复活点

**Squad / 小队**：玩家结成的互相免伤的团体。
_Avoid_: 队伍、阵营、team、party

## 鱼与钓鱼

**Fish / 鱼**：上岸后仍存活的生物。
_Avoid_: 怪物、怪（指鱼时）、monster、mob

**Loot / 鱼获**：鱼死亡后掉落的物品。
_Avoid_: 食物、海鲜（代指鱼获时）、catch

**Tier / 品级**：鱼的行为类别：普通鱼、极品鱼只逃跑，精英鱼、首领会攻击玩家；极品鱼获可抽奖，首领用于通关。
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

**Token / 信物**：精英鱼或首领独有的鱼获；未经烤制时可兑换首领饵、船票或最终通关成就，也可用于抽奖。
_Avoid_: 任务物品、独有道具、部件、relic、badge

**Boss bait / 首领饵**：由信物换得、必定钓出对应首领的鱼饵。
_Avoid_: BOSS 专用鱼饵

<a id="船票"></a>

**Ferry ticket / 船票**：去程摆渡消耗的凭证，物品类型为过关道具。
_Avoid_: 车票、门票

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

**Weapon slot / 武器栏**：装备一种武器的固定栏位。

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

**Ferry / 摆渡**：钓鱼区之间的通行方式。**Outbound / 去程**交船票，同行未交票者称**Hitchhike / 搭便船**；**Return / 返程**按人付金币。
_Avoid_: 顺风船、蹭车、过关（指摆渡时）

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

**Weak revive / 虚弱复活**：等待后以低血量并附带限时减速的**Weak / 虚弱**状态复活。

**Full revive / 满血复活**：通过广告或金豆立即满血复活。

**Coin / 金币**：本地图内的游戏币。
_Avoid_: 金、钱（代指金币时）、gold

**Bean / 金豆**：平台充值货币。

**Park coin / 乐园币**：平台可免费获得的货币。

**Platform shop / 地图商店**：以金豆或乐园币支付的平台商店。使用时写全称，以区别钓场商店。

**Compendium / 图鉴**：鱼的收集册，含个人最大钓取重量。盲盒解锁收集条目，不产生钓取重量纪录。
_Avoid_: 图册、catalog

**Records / 纪录**：某种鱼在所有玩家中的最大重量及保持者。
_Avoid_: 极限重量、排名（指纪录时）、ranking、leaderboard

## 技能与官方包

**Ability / 技能**：玩家武器攻击或鱼攻击行为背后的施法单元，仅用于系统层描述；玩家文案使用对应攻击名称。
_Avoid_: 招式、spell（指技能时）

**Ability manager / 技能管理器**：管理技能的容器（官方预设名「技能背包」）。
_Avoid_: 背包（省略「技能」时）、skill bar

**Ability anchor / 技能锚点**：技能时间轴上的动作单元。与场景里的**锚点名**同名不同义。
_Avoid_: 锚点（单说时与场景锚点名混淆）

**Anchor name / 锚点名**：场景实体在编辑器里的位置节点名，属区域标记的落地形式；代码里以 `AnchorName` 出现（如 `Interact.Fishermen[i].AnchorNames`）。与技能时间轴的**技能锚点**同名不同义。

**Reference / 引用**：挂接官方托管、随官方更新且可取消的包。
_Avoid_: 开启、安装（指引用时）、link

**Import / 导入**：一次性拷入地图、由本图维护的包，不能撤销回引用。
_Avoid_: vendor、de-init、取消导入（指编辑器状态时）、copy-in

**Official package / 官方包**：网易官方托管、随官方整包更新、包内无版本号的包，位于三端 `packages/` 下。
_Avoid_: 官方库、官方资源包、third-party package

**In-house package / 自研包**：本仓自研、以整包形式落位与升级的库，位于三端 `packages/` 下；不随官方更新，升级由本仓决定。
_Avoid_: 自研库、第三方库、内置库、vendor 包、内部包

## 官方资产

**Asset table / 资产表**：官方按编辑器分类发布的资产目录数据，给出资产的名称、编号与外观描述；与工程导出的 `OfficialAsset.lua` 是两套独立口径。
_Avoid_: 资产清单、资源表、资产列表

**Two generations of IDs / 两代编号**：同一资产在资产表与工程导出中各自成号，名称也不构成子集，两者不能互相推导或合并。
_Avoid_: 编号映射、ID 对照、编号兼容

## 工程与验收

**Unit / 单位**：脚本经 `CreateUnit` 建出的引擎单位，是引擎侧的对象本体（`UnitId`、`UnitType`、`Name`）；与游戏实体不等同：一个游戏实体可能由多个单位组成（鱼本体 + 隐形受击体），界面节点也是单位。运行期建点清单见 #206 台账。
_Avoid_: 对象、实体、game object、object（指单位时）

**Checkout / 仓库检出**：本仓的 Git 工作树（含 worktree），是唯一跑 Lua、测试与工具链的地方；仓库内路径一律相对、`/` 分隔，离开仓库写正斜杠加盘符。
_Avoid_: 开发端、本机、repo copy

**Host directory / 宿主目录**：编辑器 `code init` 绑定的本地 Lua 工程目录，根有 `eggy.json`，是部署目的地；与仓库检出只经 `deploy` 与 `sync` 往来。
_Avoid_: 部署端、本机、deploy target

**Business scope / 业务范围**：质量工具与架构图共用的业务源码集合，不含任何 `packages/` 子树（整包交付物另见**官方包**、**自研包**）；由根目录 `uml-quality.json` 的 `exclude` 与 `policy.edn` 的 `:exclude` 声明。
_Avoid_: 业务树、指标采集范围、mutation 范围、scope（单独使用时）

**Test lane / 测试车道**：按耗时划分的测试集合：fast 用于日常，full 追加慢用例、用于收尾。
_Avoid_: 验收车道、代码收尾门、lane（单独使用时）、test suite、test group

**Playtest acceptance / 试玩验收**：编辑器试玩中以合法输入、新档走通玩家流程并留证的验收。
_Avoid_: 实机测试、真机验收（指编辑器试玩时）、QA test

**Physical device / 真实设备**：玩家实际使用的手机或客户端平台；与试玩验收的结果分开记录。
_Avoid_: 实机（未说明环境时）、real device

**Production save / 正式存档**：玩家账号在 DataStore 中的常驻存档，键为 `u<userId>`；试玩验收不得写入。
_Avoid_: 主存档、线上档、main save

**QA save slot / QA 存档槽**：试玩验收专用的存档槽，键为 `u<userId>:qa:<slot>`；槽名由 `lua tools/cli.lua qa-slot new` 生成，空槽表示使用正式存档。配置字段为 `GameCfg.Save.QaSlot`。
_Avoid_: 验收存档槽、acceptance-slot、沙盒存档、sandbox save、test save

**Save key / 存档 key**：`GameCfg.Save.Store` 集合内定位一份存档的键，由 `KeyPrefix`、userId 与可选的 QA 存档槽后缀拼成。
_Avoid_: 存档 ID、档位号、save id
