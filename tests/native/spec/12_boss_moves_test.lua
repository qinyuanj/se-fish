-- 条款 12-39 / 12-40 / 12-41 / 12-42 / 12-43 / 12-44 / 12-45 / 12-46 与
-- 12-04 / 12-05（docs/acceptance/12-elite-boss-behavior.md，#256）。
--
-- 业务入口：MgrFishUnit:SpawnLanded + Drop 把哥斯拉放下，逐帧 Update 推进服务端权威时钟；
-- 只观察玩家看得见的三个面：
--   1. 鱼本体血量（Carrier.Health / MaxHealth，玩家打得到的那条血）；
--   2. 玩家血量（Controller.Health，所有伤害都走 MgrVitals）；
--   3. 广播给客户端的 gar_bite_notice 预警载荷（client/LocalGarBite 消费的同一份契约）。
-- 服务端招式台账 fish.Phase.AttackLog 由 common/boss_phase.lua 公开维护（探针与台账取「攻击序列」的
-- 同一入口），这里用它断言冷却调度，不碰任何内部字段。
--
-- 失败方式（编码前列出）：
--   1. 逐招表缺列 / 重复行 / 混进表外招式 / 出现必中招式；
--   2. 改了表但服务端照旧用写死的数值，预警形状与表不一致；
--   3. 吐息不再秒杀，或跺脚伤害 / 范围与表不符；
--   4. 阶段阈值被普通招式循环压住（该入水时还在出爪击）。

local cfg = require('common.game_cfg')
local islet = require('tests.support.isle_combat')
local boss_moves = require('common.cfg.boss_moves')

-- 循环里的断言只在失败时拼消息（断言参数里的字符串每个通过的断言都要付一次）。
local function need(cond, ...)
    if not cond then error(string.format(...), 2) end
end

describe('第 12 节 首领逐招表（哥斯拉）', function()
    local env
    local savedExtra

    before_each(function()
        savedExtra = { ability = package.loaded['server.ability_api'] }
        env = islet.new(7)
        package.loaded['server.ability_api'] = nil
        local p = islet.shoreDryPoint(7)
        env.player.Character.Position = env.vec(p.x, p.y, p.z)
    end)

    after_each(function()
        env:tearDown()
        package.loaded['server.ability_api'] = savedExtra.ability
    end)

    -- 把玩家摆到鱼的水平距离 distance 处（同高），返回该距离。
    local function stand(fish, distance)
        local p = fish.Carrier.Body.Position
        env.player.Character.Position = env.vec(p.x, p.y, p.z + distance)
    end

    -- 服务端招式台账里某一招的全部落地记录（按时间序）。
    local function landed(fish, name)
        local out = {}
        for _, attack in ipairs(fish.Phase and fish.Phase.AttackLog or {}) do
            if attack.Name == name then out[#out + 1] = attack end
        end
        return out
    end

    local function noticesBy(move)
        local out = {}
        for _, notice in ipairs(env.notices) do
            if notice.move == move then out[#out + 1] = notice end
        end
        return out
    end

    it('条款 12-39：放下哥斯拉即以 25000 血进入战斗态', function()
        local fish = env:drop('fish56Boss')
        assert.same(25000, cfg.Fish.fish56Boss.Health)
        assert.same(25000, fish.Carrier.MaxHealth)
        assert.same(25000, fish.Carrier.Health)
        assert.is_not_nil(fish.Phase)
    end)

    it('条款 12-04：逐招表一招一行、四列齐全，覆盖第 12 节全部精英与首领', function()
        local seen = {}
        for _, row in ipairs(boss_moves.Rows) do
            local key = row.Fish .. '.' .. row.Move
            need(seen[key] == nil, '逐招表出现重复行：%s', key)
            seen[key] = true
            need(type(row.Name) == 'string' and type(row.MoveName) == 'string', '%s 缺鱼名或招式名', key)
            need(type(row.Clause) == 'string' and row.Clause:match('^12%-%d+$') ~= nil,
                '%s 缺条款 ID', key)
            need(type(row.Range) == 'number' and row.Range > 0, '%s 的作用范围必须为正', key)
            -- 一列：伤害来源映射
            need(type(row.Damage) == 'table' and type(row.Damage.From) == 'string',
                '%s 缺伤害来源映射或出处', key)
            if row.Damage.Kind == 'flat' or row.Damage.Kind == 'contact' then
                need(type(row.Damage.Value) == 'number', '%s 固定伤害缺数值', key)
            end
            -- 二列：冷却调度
            need(type(row.Schedule) == 'table', '%s 缺冷却调度', key)
            if row.Schedule.Kind == 'combo' then
                need(type(row.Schedule.Count) == 'number' and type(row.Schedule.StepSec) == 'number',
                    '%s 连段缺段数或段间隔', key)
            else
                need(type(row.Schedule.Sec) == 'number', '%s 缺调度秒数', key)
            end
            -- 三列：预警
            need(type(row.Warning) == 'table' and type(row.Warning.WindupSec) == 'number',
                '%s 缺预警或起手时长', key)
            if row.Warning.Kind ~= 'none' then
                need(row.Warning.WindupSec > 0, '%s 有预警却没有起手时长', key)
                local shape = row.Warning.Kind
                need(shape == 'circle' or shape == 'line' or shape == 'cone',
                    '%s 的预警形状 %s 不在词表里', key, tostring(shape))
            end
            -- 四列：单人躲避窗口
            need(type(row.Dodge) == 'table' and row.Dodge.Kind ~= 'none', '%s 缺躲避窗口或是必中招式', key)
            if row.Dodge.Kind == 'telegraph' then
                need(row.Dodge.Sec == row.Warning.WindupSec, '%s 的躲避窗口必须等于起手时长', key)
            end
        end
        -- 第 12 节列出的七只精英与七只首领都要有行：键是 Combat 标签，没有标签的鱼用鱼种 Id
        for _, key in ipairs({ 'eel', 'gar', 'shrimp', 'dragon', 'kingCrab', 'crabBoss',
            'swordfish', 'shark', 'walrus', 'orca', 'fish47Elite', 'fish48Boss',
            'mosasaur', 'godzilla' }) do
            need(boss_moves.Index[key] ~= nil, '逐招表漏了 %s', key)
            local found = cfg.Fish[key] ~= nil
            if not found then
                for _, species in pairs(cfg.Fish) do
                    if species.Combat == key then found = true; break end
                end
            end
            need(found, '逐招表的 %s 没有对应鱼种', key)
        end
    end)

    it('条款 12-05 / 12-46：哥斯拉只有正文与表内的五招，没有凭空新增的追踪攻击', function()
        local names = {}
        for name in pairs(cfg.Ability.boss_phase.Attacks) do names[#names + 1] = name end
        table.sort(names)
        assert.same({ 'bite', 'breath', 'claw', 'stomp', 'tail' }, names)
        for _, row in ipairs(boss_moves.Rows) do
            assert.truthy(row.Move ~= 'track' and row.Move ~= 'tracking',
                '逐招表凭空新增了追踪攻击：' .. row.Fish)
            if row.Fish == 'godzilla' then
                assert.truthy(row.Damage.Value ~= 260, '孤立的 260 不得挂到哥斯拉身上')
            end
        end
        -- 正文末尾那个孤立的 260 只属于风神翼龙的俯冲（12-34 要求核对映射，不静默丢弃）
        assert.same(260, boss_moves.Get('fish48Boss', 'dive').Damage.Value)
    end)

    it('条款 12-40：爪击每 2 秒 50、甩尾每 6 秒 50，吐息 30 秒才起手', function()
        env.player.Character.Controller.Health = 100000
        local fish = env:drop('fish56Boss')
        stand(fish, 2) -- 爪击 4 米内、甩尾 5 米内
        env:advance(29.9)

        -- 同一帧只落地一个招式（common/boss_phase.lua 的确定性契约）：跺脚 0.8 秒起手期间
        -- 爪击会被挤到起手结束后的第一帧，所以节拍允许被另一招起手推迟一拍，但不能更久。
        local claw = landed(fish, 'claw')
        assert.truthy(#claw >= 11, '爪击没有按 2 秒节拍落地')
        for _, attack in ipairs(claw) do assert.same(50, attack.Damage) end
        for index = 2, #claw do
            local gap = claw[index].At - claw[index - 1].At
            -- 爪击到期时若正好撞上另一招的起手，会顺延到起手结束（最多 0.8 秒的跺脚起手）
            need(gap >= 1.9 and gap <= 2.9, '爪击间隔不是 2 秒（实测 %s）', gap)
        end

        local tail = landed(fish, 'tail')
        assert.truthy(#tail >= 2, '甩尾被爪击吃掉了')
        for _, attack in ipairs(tail) do assert.same(50, attack.Damage) end
        for index = 2, #tail do
            local gap = tail[index].At - tail[index - 1].At
            need(gap >= 5.9 and gap <= 6.8, '甩尾间隔不是 6 秒（实测 %s）', gap)
        end

        assert.same(0, #noticesBy('bossBreath'), '吐息不到 30 秒就起手了')
        env:advance(30.2)
        assert.truthy(#noticesBy('bossBreath') >= 1, '吐息满 30 秒仍未起手')
    end)

    it('条款 12-41：跺脚 10 米范围 150，预警是圆形', function()
        env.player.Character.Controller.Health = 100000
        local fish = env:drop('fish56Boss')
        stand(fish, 7) -- 爪击 4 米外、甩尾 5 米外，只在跺脚的 10 米内
        env:advance(3.2)

        local stomp = landed(fish, 'stomp')
        assert.truthy(#stomp >= 1, '跺脚没有落地')
        assert.same(150, stomp[1].Damage)
        assert.same(100000 - 150, env.player.Character.Controller.Health)

        local warning = noticesBy('bossStomp')[1]
        assert.is_not_nil(warning, '跺脚没有预警')
        assert.same('circle', warning.shape)
        assert.same(10, warning.range)
    end)

    it('条款 12-42：吐息只秒杀正前 10 米内的目标，预警是 2 米宽线形', function()
        env.player.Character.Controller.Health = 100000
        local fish = env:drop('fish56Boss')
        stand(fish, 8) -- 正前 8 米，在吐息 10 米内
        env:advance(31.6)
        assert.same(1, env.player.Character.Controller.Health, '吐息没有把目标打进濒死')
        assert.same('downed', env.vitals:LifeStatus(env.player))

        local warning = noticesBy('bossBreath')[1]
        assert.is_not_nil(warning)
        assert.same('line', warning.shape)
        assert.same(2, warning.width)
        assert.same(1.5, warning.duration)
        -- 客户端的合法性门禁必须接受这份载荷（LocalGarBite 只画合法的预警）
        assert.is_true(require('common.gar_bite_notice').Valid(warning))
    end)

    it('条款 12-43：血量低于 60% 入水，切换沧龙式攻击，咬中 1000', function()
        env.player.Character.Controller.Health = 100000
        local fish = env:drop('fish56Boss')
        stand(fish, 2)
        env:advance(0.2)
        fish.Carrier.Health = 14000 -- 56%
        env:advance(0.4)
        assert.same('water', fish.Phase.Phase, '血量低于 60% 没有入水')

        -- 入水后走沧龙式巡游：15 秒后跃起锁定玩家落点，落地 35 接触伤 + 咬中 1000
        local bite = cfg.Ability.boss_phase.Thresholds[1].BiteDamage
        assert.same(1000, bite)
        local before = env.player.Character.Controller.Health
        env:advance(18)
        local delta = before - env.player.Character.Controller.Health
        assert.truthy(delta >= bite, '入水咬击没有结算 1000（实际掉血 ' .. tostring(delta) .. '）')
        assert.is_not_nil(fish.carry, '咬中后没有叼走玩家')
    end)

    it('条款 12-44：低于 20% 重新上岸，伤害 +50%、吐息改为每 10 秒', function()
        env.player.Character.Controller.Health = 100000
        local fish = env:drop('fish56Boss')
        stand(fish, 2)
        env:advance(0.2)
        fish.Carrier.Health = 4000 -- 16%
        env:advance(0.4)
        assert.same('enraged', fish.Phase.Phase, '血量低于 20% 没有进入狂暴阶段')

        -- 上岸后位置回到战斗点，重新贴身观察
        stand(fish, 2)
        env:advance(2.4)
        local claw = landed(fish, 'claw')
        assert.truthy(#claw >= 1, '狂暴阶段不再出爪击')
        assert.same(75, claw[#claw].Damage, '狂暴阶段伤害没有 +50%')

        -- 吐息节拍从 30 秒改成 10 秒：10 秒内必须起手
        local mark = #noticesBy('bossBreath')
        env:advance(11)
        assert.truthy(#noticesBy('bossBreath') > mark, '狂暴阶段吐息没有改成每 10 秒')
    end)

    it('条款 12-45：阶段阈值优先于普通招式循环，起手中的吐息立即撤销', function()
        env.player.Character.Controller.Health = 100000
        local fish = env:drop('fish56Boss')
        stand(fish, 8)
        env:advance(30.1)
        assert.truthy(#noticesBy('bossBreath') >= 1, '吐息没有进入起手')

        fish.Carrier.Health = 14000 -- 起手中跌破 60%
        env:advance(30.2)
        assert.same('water', fish.Phase.Phase, '阶段阈值没有立即生效')
        assert.is_nil(fish.BossWarn, '阶段切换后旧的起手没有撤销')
        env:advance(33)
        assert.is_true(env.player.Character.Controller.Health > 0, '撤销的吐息仍然落地了')
    end)

    it('逐招表 → 服务端广播 → 客户端预警：载荷形状与宽度就是表里那一行', function()
        env.player.Character.Controller.Health = 100000
        local fish = env:drop('fish56Boss')
        stand(fish, 7)
        env:advance(2.2)
        local warning = noticesBy('bossStomp')[1]
        assert.is_not_nil(warning)
        local row = boss_moves.Get('godzilla', 'stomp')
        assert.same(row.Warning.Kind, warning.shape)
        assert.same(row.Warning.WindupSec, warning.duration)
        assert.same(row.Range, warning.range)
        assert.is_true(require('common.gar_bite_notice').Valid(warning))
    end)
end)
