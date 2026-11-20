-- 条款 6-29 / 6-30 / 6-31（docs/acceptance/06-combat-and-growth.md，#260）与
-- #260 接线验收：官方 AI 管理器按伤害优先持有鱼的目标选择；属性与效果投影保持与自研模型一致。
--
-- 业务入口：MgrFishUnit:SpawnLanded + Drop 放下哥斯拉（一只鱼贯通），逐帧 Update 推进服务端权威时钟；
-- 玩家经公开损伤登记口 NoteDamage 记累计有效伤害，经 SetTargetOverride 指定特殊招式目标。
-- 观察三条外部可见结果：
--   1. 玩家血量：爪击只落在被选中的目标身上；
--   2. 官方 AI 管理器持有的目标（BehaviorRuntime.getState(receiver).focusTarget 与 priorityMode）：
--      适配层把裁决交给官方包，不调用 SearchEnemy / ChaseTarget，移动仍归自研 FishBehaviors / FlightPath；
--   3. 属性/效果投影值：MgrAttr 对 attr_rule 的分量写入，MgrModifier 对 modifier_system 的效果实例。
-- 客户端没有任何目标选择入口：目标只由服务端适配层裁决。
--
-- 失败方式（编码前列出）：
--   1. 近的玩家盖过累计伤害更高的玩家（6-29）；
--   2. 濒死 / 死亡 / 离线 / 离战范围的玩家仍被选中（6-30）；
--   3. 特殊招式指定目标被自动仇恨覆盖（6-31）；
--   4. 适配层写了 Controller 位移或启动官方搜敌模式，与自研轨迹双写权威；
--   5. 属性/效果投影与 AttrModel / GameCfg 公差不一致。

local Islet = require('tests.support.isle_combat')
local GameCfg = require('common.GameCfg')

local function need(cond, ...)
    if not cond then error(string.format(...), 2) end
end

describe('第 6 节 官方 AI 目标选择接线（哥斯拉贯通）', function()
    local env
    local savedExtra

    local function vec(x, y, z) return env.vec(x, y, z) end

    local function addRival()
        local controller = { Health = 100000, MaxHealth = 100000,
            HealthChanged = env.signal(), Died = env.signal() }
        function controller:TakeDamage(d)
            self.Health = math.max(0, self.Health - d)
            self.HealthChanged:Fire(self.Health)
            if self.Health == 0 then self.Died:Fire() end
        end
        env.rival = { UserId = 3702, Character = { Controller = controller, Position = vec(0, 0, 0),
            Rotation = _G.Quaternion.FromEulerAngles() }, CharacterAdded = env.signal(),
            CharacterRemoving = env.signal(), SetAttribute = function() end }
        env.players[2] = env.rival
        env.vitals:OnPlayerAdded(env.rival)
        env.mgr:OnPlayerAdded(env.rival)
    end

    local function place(fish, player, distance)
        local p = fish.Carrier.Body.Position
        player.Character.Position = vec(p.x + distance, p.y, p.z)
    end

    local function dropBoss()
        local fish = env:drop('fish56Boss')
        -- 官方包 utils.isValidUnit 要求单位有 Parent；宿主世界里受击体挂在 World 下。
        fish.Carrier.Receiver.Parent = env.world
        return fish
    end

    local function officialFocus(fish)
        return require('server.Mgr.MgrAiTarget'):Focus(fish)
    end

    before_each(function()
        savedExtra = { remote = rawget(_G, 'RemoteEvent') }
        env = Islet.new(7)
        _G.RemoteEvent = { New = function() return { OnServerEvent = {
            Connect = function() return { Disconnect = function() end } end } } end }
        for _, name in ipairs({ 'server.Mgr.MgrAiTarget', 'server.packages.official_ai_feature.api',
            'server.packages.official_ai_feature.official_ai_feature',
            'server.packages.official_ai_feature.behavior_runtime',
            'server.packages.official_ai_feature.ability_bridge' }) do
            package.loaded[name] = nil
        end
        local p = Islet.shoreDryPoint(7)
        env.player.Character.Position = vec(p.x, p.y, p.z)
        env.player.Character.Controller.Health = 100000
        addRival()
    end)

    after_each(function()
        env:tearDown()
        _G.RemoteEvent = savedExtra.remote
    end)

    it('条款 6-29：累计有效伤害优先于距离，裁决交给官方 AI 管理器', function()
        local fish = dropBoss()
        place(fish, env.player, 3)
        place(fish, env.rival, 1.5)
        env.mgr:NoteDamage(fish, env.player, 300)
        env.mgr:NoteDamage(fish, env.rival, 10)

        env:advance(0.2)
        assert.same(env.player.Character, officialFocus(fish), '官方 AI 管理器没有持有伤害优先目标')
        local adapter = require('server.Mgr.MgrAiTarget')
        local state = adapter:State(fish)
        assert.same(GameCfg.Ability.AiTarget.PriorityMode, state.priorityMode,
            '伤害优先模式没有登记到官方 AI 管理器')

        local before = env.player.Character.Controller.Health
        local rivalBefore = env.rival.Character.Controller.Health
        env:advance(2.4)
        need(env.player.Character.Controller.Health < before, '高伤害玩家没有被爪击')
        need(before - env.player.Character.Controller.Health
            > rivalBefore - env.rival.Character.Controller.Health,
            '爪击没有优先落在累计伤害最高的玩家身上')
    end)

    it('条款 6-29：没有伤害记录时回退最近的有效玩家', function()
        local fish = dropBoss()
        place(fish, env.player, 3)
        place(fish, env.rival, 1.5)
        env:advance(0.2)
        assert.same(env.rival.Character, officialFocus(fish), '无伤害记录时应选最近玩家')
    end)

    it('条款 6-30：死亡与离线的玩家不参与选择', function()
        local fish = dropBoss()
        place(fish, env.player, 3)
        place(fish, env.rival, 1.5)
        env.mgr:NoteDamage(fish, env.player, 300)

        -- 累计伤害最高的玩家死亡：立刻从仇恨账本清除，改选近处仍有效的对手。
        env.player.Character.Controller.Died:Fire()
        env:advance(0.4)
        assert.same(env.rival.Character, officialFocus(fish), '死亡玩家仍被选中')
        assert.is_nil(fish.Threat[env.player], '死亡玩家的伤害记录没有清除')

        -- 换到有伤害的玩家，再让他离线（离开玩家列表）：同样不能成为目标。
        env.mgr:NoteDamage(fish, env.rival, 900)
        env.players[2] = nil
        env:advance(0.6)
        assert.is_nil(officialFocus(fish), '离线玩家仍被选中')
    end)

    it('条款 6-31：特殊招式指定目标优先于自动伤害排序，失效后回到自动目标', function()
        local fish = dropBoss()
        place(fish, env.player, 1.5)
        place(fish, env.rival, 3)
        env.mgr:NoteDamage(fish, env.player, 300)
        env:advance(0.2)
        assert.same(env.player.Character, officialFocus(fish))

        assert.is_true(env.mgr:SetTargetOverride(fish, env.rival))
        env:advance(0.4)
        assert.same(env.rival.Character, officialFocus(fish), '指定目标没有优先于自动目标')

        env.rival.Character.Controller.Died:Fire()
        env:advance(0.6)
        assert.is_nil(fish.TargetOverride)
        assert.same(env.player.Character, officialFocus(fish), '指定目标失效后没有回到自动目标')
    end)

    it('接线守卫：官方 AI 只持有目标，不启动搜敌/追击模式，不写鱼本体位移', function()
        local fish = dropBoss()
        place(fish, env.player, 2)
        env:advance(1)
        local adapter = require('server.Mgr.MgrAiTarget')
        local state = adapter:State(fish)
        assert.is_nil(state and state.modeName, '官方 AI 启动了移动模式，与自研轨迹双写权威')
        assert.is_not_true(fish.Carrier.AiOwnsMovement, '受击体的移动所有权被官方 AI 接管')
        local pos = fish.Carrier.Body.Position
        place(fish, env.player, 2)
        env:advance(0.2)
        assert.same(pos.x, fish.Carrier.Body.Position.x, '目标选择不应改动鱼本体位置')
    end)
end)
-- #260 接线验收：属性与效果投影。目标选择用到的有效伤害来自同一条投影链——
-- 自研 AttrModel / AttrGrowth 只产分量，官方 attr_rule 持有运行期属性；效果由 modifier_system 持有。
describe('接线验收：属性与效果投影一致', function()
    it('AttrModel / AttrGrowth 的分量与官方 attr_rule 投影值一致', function()
        local AttrRuntime = require('tests.support.attr_runtime')
        local Model = require('common.AttrModel')
        local Growth = require('common.AttrGrowth')
        local GameCfg = require('common.GameCfg')
        local data = { body = 2, speed = 3 }
        function data:PotionCount(id)
            return id == GameCfg.Ability.SpeedPotion.Item and self.speed or self.body
        end
        local mgr = AttrRuntime.New({ GetDataInst = function() return data end }, function() return 0.5 end)
        local player = { UserId = 72, Character = { Controller = { WalkSpeed = 7 },
            GetChildren = function() return {} end, SetScale = function() end } }
        local plan = mgr:Plan(player)
        local expected = Model.Plan({ bodyPotions = 2, speedPotions = 3, baseSpeed = 7, moveMultiplier = 0.5 })
        assert.same(expected.Attributes.PlayerWalkSpeed, plan.Attributes.PlayerWalkSpeed,
            'MgrAttr:Plan 与 AttrModel:Plan 分量不一致')
        assert.near(1.3, Growth.SpeedFactor(3), 1e-9, 'AttrGrowth 与药水成长公式不一致')

        assert.is_true(mgr:ApplyGrowth(player).Ok)
        local speed = mgr.AttrAPI.Funcs.GetAttr(player.Character, 'PlayerWalkSpeed')
        local c = expected.Attributes.PlayerWalkSpeed
        assert.near((c.Base + c.BaseExtra) * (1 + c.Ratio) + c.Bonus, speed, 1e-9,
            '官方 attr_rule 的属性值与 AttrModel 分量不一致')
    end)

    -- 条款 6-26：霜之新星命中减速 30%、霜冻不叠加（持续 3 秒由效果定义给，这里断言倍率与不叠加）。
    it('条款 6-26：效果投影由 modifier_system 持有，霜冻减速 30% 且不叠加', function()
        local Runtime = require('tests.support.modifier_runtime')
        local rt = Runtime.New(100)
        local modifier = rt:loadModifier()
        local player = { UserId = 73, Character = rt.unit('character') }
        assert.is_true(modifier:Apply(nil, player, 'frost'), '霜冻效果没有交给官方效果系统')
        assert.near(0.7, modifier:GetMoveMultiplier(player), 1e-9, '霜冻减速不是 30%')
        assert.is_true(modifier:Apply(nil, player, 'frost'), '重复霜冻应刷新持续')
        assert.near(0.7, modifier:GetMoveMultiplier(player), 1e-9, '霜冻效果叠加了')
    end)
end)
