-- 条款 6-29 / 6-30 / 6-31（docs/acceptance/06-combat-and-growth.md，#260）与
-- #260 接线验收：业务按伤害优先裁决目标，官方 AI 管理器只登记可观察结果；属性与效果投影保持一致。
--
-- 业务入口：MgrFishUnit:SpawnLanded + Drop 放下哥斯拉（一只鱼贯通），逐帧 Update 推进服务端权威时钟；
-- 玩家经公开损伤登记口 NoteDamage 记累计有效伤害，经 SetTargetOverride 指定特殊招式目标。
-- 观察三条外部可见结果：
--   1. 玩家血量：爪击只落在被选中的目标身上；
--   2. 官方 AI 管理器登记的结果（BehaviorRuntime.getState(receiver) 的 focusTarget / priorityMode）：
--      业务 Policy.Order 负责伤害优先裁决，官方包只保存登记值，不参与裁决；
--      适配层不调用 SearchEnemy / ChaseTarget，移动仍归自研 FishBehaviors / FlightPath；
--   3. 属性/效果投影值：MgrAttr 对 attr_rule 的分量写入，MgrModifier 对 modifier_system 的效果实例。
-- 客户端没有任何目标选择入口：目标只由服务端适配层裁决。
--
-- 失败方式（编码前列出）：
--   1. 近的玩家盖过累计伤害更高的玩家（6-29）；
--   2. 濒死 / 死亡 / 离线 / 离战范围的玩家仍被选中（6-30）；
--   3. 特殊招式指定目标被自动仇恨覆盖（6-31）；
--   4. 适配层写了 Controller 位移或启动官方搜敌模式，与自研轨迹双写权威；
--   5. 属性/效果投影与 AttrModel / GameCfg 公差不一致；
--   6. 官方加载、登记或状态读取失败阻断业务已经裁决的目标或 override；
--   7. require / pcall / State 失败日志缺模块、操作、鱼/单位标识或原始错误。

local Islet = require('tests.support.isle_combat')
local GameCfg = require('common.game_cfg')

local function need(cond, ...)
    if not cond then error(string.format(...), 2) end
end

describe('第 6 节 官方 AI 目标选择接线（哥斯拉贯通）', function()
    local env

    local function vec(x, y, z) return env.vec(x, y, z) end

    -- 候选玩家：UserId 自选（并列裁决要按号码大小分辨真假），血量足够大不让爪击打死。
    local function spawn(userId)
        local controller = { Health = 100000, MaxHealth = 100000,
            HealthChanged = env.signal(), Died = env.signal() }
        function controller:TakeDamage(d)
            self.Health = math.max(0, self.Health - d)
            self.HealthChanged:Fire(self.Health)
            if self.Health == 0 then self.Died:Fire() end
        end
        local player = { UserId = userId, Character = { Controller = controller, Position = vec(0, 0, 0),
            Rotation = _G.Quaternion.FromEulerAngles() }, CharacterAdded = env.signal(),
            CharacterRemoving = env.signal(), SetAttribute = function() end }
        env.players[#env.players + 1] = player
        env.lifeHost:add(player)
        env.mgr:OnPlayerAdded(player)
        return player
    end

    local function addRival()
        env.rival = spawn(3702)
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
        return require('server.world_host.fish_ai_target'):Focus(fish)
    end

    before_each(function()
        env = Islet.new(7)
        for _, name in ipairs({ 'server.world_host.fish_ai_target', 'server.packages.official_ai_feature.api',
            'server.packages.official_ai_feature.official_ai_feature',
            'server.packages.official_ai_feature.behavior_runtime',
            'server.packages.official_ai_feature.ability_bridge' }) do
            package.loaded[name] = nil
        end
        env.mgr.AiTarget = require('server.world_host.fish_ai_target')
        local p = Islet.shoreDryPoint(7)
        env.player.Character.Position = vec(p.x, p.y, p.z)
        env.player.Character.Controller.Health = 100000
        addRival()
    end)

    after_each(function()
        env:tearDown()
    end)

    it('条款 6-29：业务按累计有效伤害裁决，结果登记到官方 AI 管理器', function()
        local fish = dropBoss()
        place(fish, env.player, 3)
        place(fish, env.rival, 1.5)
        env.mgr:NoteDamage(fish, env.player, 300)
        env.mgr:NoteDamage(fish, env.rival, 10)

        env:advance(0.2)
        assert.same(env.player.Character, officialFocus(fish), '官方 AI 管理器没有持有伤害优先目标')
        local adapter = require('server.world_host.fish_ai_target')
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

    -- 6-29（review #249-10）：伤害与距离都打平时按 UserId 数值裁决，不是字符串序
    -- （91 与 100：数值 91 更小，字符串序 '100' < '91' 会选反）。
    it('条款 6-29：同伤害同距离按 UserId 数值裁决', function()
        local fish = dropBoss()
        place(fish, env.player, 20)
        place(fish, env.rival, 22)
        local low, high = spawn(91), spawn(100)
        local p = fish.Carrier.Body.Position
        low.Character.Position = vec(p.x + 2, p.y, p.z)
        high.Character.Position = vec(p.x - 2, p.y, p.z)
        env:advance(0.2)
        assert.same(low.Character, officialFocus(fish), '同伤害同距离时没有按 UserId 数值裁决')
        local selected = env.mgr:ChooseTarget(fish, p)
        assert.same(low, selected, '业务裁决目标不是号码更小的玩家')
    end)

    it('官方登记抛错时保留业务伤害优先目标，并记录模块、操作、对象与错误', function()
        local fish = dropBoss()
        place(fish, env.player, 3)
        place(fish, env.rival, 1.5)
        env.mgr:NoteDamage(fish, env.player, 300)

        local manager = require('server.packages.official_ai_feature.official_ai_feature')
        local original = manager.setSearchEnemyPriorityMode
        manager.setSearchEnemyPriorityMode = function() error('official-register-failed') end
        local rawPrint = _G.print
        local logs = {}
        _G.print = function(...)
            local parts = {}
            for i = 1, select('#', ...) do parts[#parts + 1] = tostring(select(i, ...)) end
            logs[#logs + 1] = table.concat(parts, ' ')
        end
        local ok, selected, cp = pcall(env.mgr.ChooseTarget, env.mgr, fish, fish.Carrier.Body.Position)
        _G.print = rawPrint
        manager.setSearchEnemyPriorityMode = original
        assert.is_true(ok, tostring(selected))
        assert.same(env.player, selected, '官方登记失败阻断了业务伤害优先目标')
        assert.same(env.player.Character.Position, cp)

        local text = table.concat(logs, '\n')
        assert.is_truthy(text:find('[FishAiTarget]', 1, true), '日志缺模块名')
        assert.is_truthy(text:find('SetFocus', 1, true), '日志缺官方登记操作名')
        assert.is_truthy(text:find(tostring(fish.Id), 1, true), '日志缺鱼标识')
        assert.is_truthy(text:find(tostring(fish.Carrier.Receiver.UnitId), 1, true), '日志缺单位标识')
        assert.is_truthy(text:find('official-register-failed', 1, true), '日志缺原始错误')
    end)

    it('官方 API 加载失败时保留业务目标，并记录完整错误日志', function()
        local fish = dropBoss()
        place(fish, env.player, 3)
        place(fish, env.rival, 1.5)
        env.mgr:NoteDamage(fish, env.player, 300)

        local apiName = 'server.packages.official_ai_feature.api'
        local oldApi, oldPreload = package.loaded[apiName], package.preload[apiName]
        package.loaded[apiName] = nil
        package.preload[apiName] = function() error('official-api-load-failed') end
        package.loaded['server.world_host.fish_ai_target'] = nil
        env.mgr.AiTarget = require('server.world_host.fish_ai_target')
        local rawPrint = _G.print
        local logs = {}
        _G.print = function(...) logs[#logs + 1] = tostring((...)) end
        local ok, selected = pcall(env.mgr.ChooseTarget, env.mgr, fish, fish.Carrier.Body.Position)
        _G.print = rawPrint
        package.preload[apiName] = oldPreload
        package.loaded[apiName] = oldApi
        assert.is_true(ok, tostring(selected))
        assert.same(env.player, selected, '官方 API 加载失败阻断了业务伤害优先目标')

        local text = table.concat(logs, '\n')
        assert.is_truthy(text:find('[FishAiTarget]', 1, true), '日志缺模块名')
        assert.is_truthy(text:find('RequireOfficialAPI', 1, true), '日志缺官方 API 加载操作名')
        assert.is_truthy(text:find(tostring(fish.Id), 1, true), '日志缺鱼标识')
        assert.is_truthy(text:find(tostring(fish.Carrier.Receiver.UnitId), 1, true), '日志缺单位标识')
        assert.is_truthy(text:find('official-api-load-failed', 1, true), '日志缺原始错误')
    end)

    it('特殊招式目标官方登记失败时仍采用业务 override', function()
        local fish = dropBoss()
        place(fish, env.rival, 2)
        assert.is_true(env.mgr:SetTargetOverride(fish, env.rival))
        local manager = require('server.packages.official_ai_feature.official_ai_feature')
        local original = manager.setSearchEnemyPriorityMode
        manager.setSearchEnemyPriorityMode = function() error('official-focus-failed') end
        local rawPrint = _G.print
        local logs = {}
        _G.print = function(...) logs[#logs + 1] = tostring((...)) end
        local ok, selected = pcall(env.mgr.ChooseTarget, env.mgr, fish, fish.Carrier.Body.Position)
        _G.print = rawPrint
        manager.setSearchEnemyPriorityMode = original
        assert.is_true(ok, tostring(selected))
        assert.same(env.rival, selected, '官方焦点登记失败阻断了业务 override')
        local text = table.concat(logs, '\n')
        assert.is_truthy(text:find('[FishAiTarget]', 1, true), '日志缺模块名')
        assert.is_truthy(text:find('SetFocus', 1, true), '日志缺焦点注册操作名')
        assert.is_truthy(text:find(tostring(fish.Id), 1, true), '日志缺鱼标识')
        assert.is_truthy(text:find(tostring(env.rival.UserId), 1, true), '日志缺目标玩家标识')
        assert.is_truthy(text:find('official-focus-failed', 1, true), '日志缺原始错误')
    end)

    it('官方状态读取失败时记录模块、操作、对象与原始错误', function()
        local fish = dropBoss()
        local adapter = require('server.world_host.fish_ai_target')
        local runtime = require('server.packages.official_ai_feature.behavior_runtime')
        local original = runtime.getState
        runtime.getState = function() error('official-state-read-failed') end
        local rawPrint = _G.print
        local logs = {}
        _G.print = function(...) logs[#logs + 1] = tostring((...)) end
        local ok, state = pcall(adapter.State, adapter, fish)
        _G.print = rawPrint
        runtime.getState = original
        assert.is_true(ok, tostring(state))
        assert.is_nil(state)
        local text = table.concat(logs, '\n')
        assert.is_truthy(text:find('[FishAiTarget]', 1, true), '日志缺模块名')
        assert.is_truthy(text:find('ReadOfficialState', 1, true), '日志缺状态读取操作名')
        assert.is_truthy(text:find(tostring(fish.Id), 1, true), '日志缺鱼标识')
        assert.is_truthy(text:find(tostring(fish.Carrier.Receiver.UnitId), 1, true), '日志缺单位标识')
        assert.is_truthy(text:find('official-state-read-failed', 1, true), '日志缺原始错误')
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

        -- 濒死：生命接缝拒伤（与 MgrSurvival:Hooks 同语义），累计伤害最高也不参与选择。
        -- 断言读业务裁决口 ChooseTarget：官方包只在目标单位失效时清焦点，血量锁 1 的濒死者
        -- 单位仍然有效，不能拿镜面焦点当「没被选中」的证据。
        local wounded = spawn(3703)
        place(fish, wounded, 2)
        local pos = fish.Carrier.Body.Position
        assert.same(wounded, (env.mgr:ChooseTarget(fish, pos)), '新玩家应接替成为目标')
        env.mgr:NoteDamage(fish, wounded, 900)
        env.vitals:ApplyHit(env.vitals:NewHit(nil, 'fishAttack'), wounded, 1000000)
        assert.equals('downed', env.vitals:LifeStatus(wounded))
        assert.is_nil((env.mgr:ChooseTarget(fish, pos)), '濒死玩家仍被选中')
        assert.is_nil(fish.Threat[wounded], '濒死玩家的伤害记录没有清除')
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
        local adapter = require('server.world_host.fish_ai_target')
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
        local Model = require('common.attr_model')
        local Growth = require('common.attr_growth')
        local GameCfg = require('common.game_cfg')
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

-- 6-30 的「离开战斗范围」只在飞行鱼上成立：UpdateFlying 用 Flight.AggroRange 做候选过滤。
-- 业务入口：SpawnLanded + Drop 放下白头鹰，逐帧 Update 推进；只观察官方 AI 持有的焦点。
describe('第 6 节 6-30：离开战斗范围的玩家退出飞行鱼目标', function()
    local env

    local function vec(x, y, z) return env.vec(x, y, z) end
    local function focus(fish) return require('server.world_host.fish_ai_target'):Focus(fish) end

    before_each(function()
        env = Islet.new(6)
        for _, name in ipairs({ 'server.world_host.fish_ai_target', 'server.packages.official_ai_feature.api',
            'server.packages.official_ai_feature.official_ai_feature',
            'server.packages.official_ai_feature.behavior_runtime',
            'server.packages.official_ai_feature.ability_bridge' }) do
            package.loaded[name] = nil
        end
        env.mgr.AiTarget = require('server.world_host.fish_ai_target')
        local p = Islet.shoreDryPoint(6)
        env.player.Character.Position = vec(p.x, p.y, p.z)
    end)

    after_each(function()
        env:tearDown()
    end)

    -- 断言读业务裁决口与自研轨迹目标：官方包只在目标单位失效时清焦点，站得远但仍然有效的
    -- 玩家会留在镜面焦点里，不能拿它当「没被选为目标」的证据。
    it('条款 6-30：离开索敌半径的玩家不再被飞行鱼锁定', function()
        local fish = env:drop('fish47Elite')
        fish.Carrier.Receiver.Parent = env.world
        assert.is_not_nil(fish.Flight, '精英鱼应在空中飞行')
        local p = fish.Carrier.Body.Position
        env.player.Character.Position = vec(p.x + 5, p.y, p.z)
        env:advance(0.3)
        assert.same(env.player.Character, focus(fish), '索敌半径内的玩家应被锁定')
        assert.is_not_nil(fish.Flight.Target, '索敌半径内应给轨迹一个追击点')

        -- 走出 Flight.AggroRange：候选过滤在外，业务裁决无目标，轨迹不再追这个玩家。
        local range = GameCfg.Ability.Flight.AggroRange
        local at = fish.Carrier.Body.Position
        env.player.Character.Position = vec(at.x + range + 20, at.y, at.z)
        env:advance(env.now + 0.2) -- advance 收的是绝对时刻
        assert.is_nil((env.mgr:ChooseTarget(fish, fish.Carrier.Body.Position, { AggroRange = range })),
            '离开战斗范围仍被选为目标')
        assert.is_nil(fish.Flight.Target, '离开战斗范围后轨迹仍在追玩家')
    end)
end)

-- review #249-6：起手时长统一按 BossMoves.KeyOf 反查逐招行（与预警广播同一条行），
-- 不再按字面鱼键硬取；取不到时调用方按 0 退化，不 nil 崩。
describe('第 6 节：逐招表按 KeyOf 反查', function()
    local BossMoves = require('common.cfg.boss_moves')

    it('逐招行按 KeyOf 反查，预警与起手时长同源', function()
        assert.is_true(#BossMoves.Rows > 0)
        -- 有 Combat 标签的鱼：KeyOf 就是标签；没有标签时退回鱼种 Id。
        local crab = assert(GameCfg.Fish.fish23Elite)
        assert.same('kingCrab', BossMoves.KeyOf(crab, crab.Id))
        assert.same('fishPlain', BossMoves.KeyOf({ Id = 'fishPlain' }, 'fishPlain'))
        assert.same('fishPlain', BossMoves.KeyOf(nil, 'fishPlain'))
        -- 走逐招表起手时长的三族鱼：KeyOf 必须取到行，预警广播与起手时长读同一格数值。
        for _, key in ipairs({ 'kingCrab', 'crabBoss', 'eel' }) do
            local rows = BossMoves.ForFish(key)
            assert.is_true(#rows > 0, '逐招行缺族：' .. key)
            for _, row in ipairs(rows) do
                assert.same(row, BossMoves.Get(key, row.Move), '逐招行取不到：' .. key .. '.' .. row.Move)
                local warning = assert(BossMoves.WarningOf(key, row.Move),
                    '预警取不到：' .. key .. '.' .. row.Move)
                assert.same(row.Warning.WindupSec, warning.WindupSec, '起手时长与预警不是同一行数值')
            end
        end
        -- 缺行退化：取不到返回 nil，调用方按 0 / 空表兜底，不再按字面鱼键硬取。
        assert.is_nil(BossMoves.Get('noSuchFish', 'noSuchMove'))
        assert.same('noSuchFish', BossMoves.KeyOf(nil, 'noSuchFish'))
    end)

    it('起手时长与预警广播取的是同一行', function()
        -- 帝王蟹的鱼种 Id 是 fish23Elite，逐招行键是它的 Combat 标签 kingCrab；
        -- 按字面鱼键硬取会落空，按 KeyOf 才取到广播预警用的同一行。
        local species = assert(GameCfg.Fish.fish23Elite)
        local key = BossMoves.KeyOf(species, species.Id)
        assert.same('kingCrab', key)
        assert.same(BossMoves.WarningOf(key, 'jab').WindupSec, BossMoves.Get(key, 'jab').Warning.WindupSec)
        assert.is_nil(BossMoves.Get(species.Id, 'jab'), '按鱼种 Id 硬取应当落空，这正是要修的字面鱼键')
    end)
end)

-- 6-26：霜之新星（枪械大奖特效）经武器命中业务入口挂 3 秒霜冻，重复命中只刷新不叠加。
-- 预设键取 GameCfg.Ability.ModifierPresets（不用测试替身）。只替引擎边界：射线、角色、RE、时钟。
describe('接线验收：霜之新星命中经武器入口挂霜冻（6-26）', function()
    local ctx
    local function v3(x, y, z) return { x = x, y = y, z = z } end

    before_each(function()
        -- 起始时钟不为 0：枪械射速按「上次开火时刻」算，0 会被当成刚开过枪（冷却中）。
        ctx = { now = 100, sent = {}, saved = { game = rawget(_G, 'game'), vector = rawget(_G, 'Vector3'),
            reutil = rawget(_G, 'REUtil'), re = package.loaded['common.re_util'] } }
        local env = ctx
        _G.Vector3 = { New = function(x, y, z) return v3(x, y, z) end }
        _G.game = { GetService = function(_, name)
            if name == 'World' then return { GetServerTime = function() return env.now end } end
            if name == 'PhysicsService' then return { Raycast = function() return env.rayHit end } end
            if name == 'Players' then
                return { GetPlayers = function() return { env.player } end,
                    GetPlayerFromCharacter = function(_, character)
                        if character == env.target.Character then return env.target end
                        return nil
                    end }
            end
            return {}
        end }
        package.loaded['common.re_util'] = nil
        _G.REUtil = { GetRE = function(_, name)
            env.sent[name] = env.sent[name] or {}
            local record = env.sent[name]
            local function signal()
                return { Connect = function() return { Disconnect = function() end } end }
            end
            return { OnServerEvent = signal(), OnClientEvent = signal(),
                FireClient = function(_, _player, payload) record[#record + 1] = payload end }
        end }

        env.player = { UserId = 91, Character = { Position = v3(0, 0, 0),
            Rotation = { GetForward = function() return v3(0, 0, 1) end } } }
        env.rt = require('tests.support.modifier_runtime').New(100)
        env.modifier = env.rt:loadModifier()
        env.modifier.Presets = nil -- 走 GameCfg.Ability.ModifierPresets 的真实预设键
        env.refreshed = 0
        env.modifier.Ability = { RefreshMoveSpeed = function() env.refreshed = env.refreshed + 1; return true end }
        -- 目标角色用引擎替身单位：modifier_system 的容器按单位建，真实角色也是单位对象。
        local character = env.rt.unit('character')
        character.Controller = { Health = 300, MaxHealth = 300 }
        character.Position = v3(0, 0, 5)
        env.target = { UserId = 92, Character = character }
        env.rayHit = { Instance = env.target.Character, Position = v3(0, 0, 5) }
        env.data = { GetItemBarSnapshot = function()
                return { held = { kind = 'weapon', id = 'item163' }, weapons = { item163 = 1 } }
            end, MagazineSize = function(_, base) return base end }
        local SpokeClock = require('common.spoke_clock')
        local spoke = require('common.packages.spoke.api')
        local PlayerWeapon = require('server.world_host.player_weapon')
        env.clock = SpokeClock.new(env.now)
        local heldState = spoke.State.new('AiTarget626.held', { kind = 'weapon', id = 'item163' })
        local selectedState = spoke.State.new('AiTarget626.selected', nil)
        local weaponsState = spoke.State.new('AiTarget626.weapons', { item163 = 1 })
        local canActState = spoke.State.new('AiTarget626.can_act', true)
        local scalesState = spoke.State.new('AiTarget626.scales', { melee = 1, ranged = 1, explosive = 1 })
        local fakeTree = {
            player = env.player, data = env.data, clock = env.clock,
            states = { held = heldState, selected_weapon = selectedState, weapons = weaponsState },
            memos = { can_act = canActState, weapon_damage_scales = scalesState },
            get_item_bar_snapshot = function() return env.data:GetItemBarSnapshot() end,
        }
        local weaponHandle
        env.spokeTree = spoke.SpokeTree.spawn(spoke.Effect.new('AiTarget626', function(scope)
            weaponHandle = PlayerWeapon.mount(scope, fakeTree, {
                remote = _G.REUtil,
                new_hit = function(source, category)
                    return { source = source, sourcePlayer = source, category = category }
                end,
                apply_hit = function(hit, target, amount)
                    if target ~= env.target then return false end
                    env.damage = (env.damage or 0) + amount
                    return true
                end,
                apply_effect = function(source, target, kind)
                    return env.modifier:ApplyWeaponEffect(source, target, { Kind = kind })
                end,
            })
        end))
        env.weapon = {
            Attack = function(_, _player, aim)
                env.clock:step(math.max(0, env.now - env.clock.now()), env.now)
                weaponHandle:handle({ action = 'attack', aim = aim })
                local replies = env.sent.WeaponResult
                return replies and replies[#replies] or nil
            end,
        }
    end)

    after_each(function()
        if not ctx then return end
        if ctx.spokeTree then ctx.spokeTree:dispose() end
        _G.game, _G.Vector3, _G.REUtil = ctx.saved.game, ctx.saved.vector, ctx.saved.reutil
        package.loaded['common.re_util'] = ctx.saved.re
        ctx = nil
    end)

    it('条款 6-26：命中挂 3 秒霜冻，减速 30%，重复命中只刷新不叠加', function()
        assert.is_truthy(GameCfg.Ability.ModifierPresets.frost, '霜冻预设键应由共享配置给出')
        local gcfg = GameCfg.Ability.Guns.item163
        local hit = ctx.weapon:Attack(ctx.player, v3(0, 0, 1))
        assert.is_true(hit and hit.ok, '武器命中入口没有结算成功')
        assert.same(gcfg.Damage, ctx.damage, '枪伤没走统一伤害入口')
        assert.same(3, ctx.modifier:GetRemaining(ctx.target, 'frost'), '命中后霜冻不是 3 秒')
        assert.near(0.7, ctx.modifier:GetMoveMultiplier(ctx.target), 1e-9, '霜冻减速不是 30%')
        assert.is_true(ctx.refreshed > 0, '减速投影没有跟着刷新移速')

        -- 1 秒后再命中：只把剩余时间刷回 3 秒，不叠成两层 / 6 秒。
        ctx.rt.wait(1)
        ctx.now = ctx.now + 1.1
        assert.same(2, ctx.modifier:GetRemaining(ctx.target, 'frost'), '霜冻剩余时间没有随时钟走')
        assert.is_true(ctx.weapon:Attack(ctx.player, v3(0, 0, 1)).ok, '第二次命中结算失败')
        assert.same(3, ctx.modifier:GetRemaining(ctx.target, 'frost'), '重复命中应刷新到 3 秒而不是叠加')
        assert.near(0.7, ctx.modifier:GetMoveMultiplier(ctx.target), 1e-9, '霜冻效果叠加了')
    end)

    it('条款 6-26：脱靶不挂霜冻（特效只在伤害被接受后挂）', function()
        ctx.rayHit = nil
        assert.is_true(ctx.weapon:Attack(ctx.player, v3(0, 0, 1)).ok, '未命中也应正常回执')
        assert.same(0, ctx.modifier:GetRemaining(ctx.target, 'frost'), '脱靶仍挂了霜冻')
        assert.is_nil(ctx.damage)
    end)
end)
