-- 条款 16-04 / 16-06 / 16-07（docs/acceptance/16-item-base-data.md）：
--   16-04 食物、极品食物与鱼饵可食用；
--   16-06 除食物、极品食物、鱼饵与药水外，其余类别不能走普通食用；
--   16-07 食用恢复百分比可为负值，负值表示食用后扣减而非恢复。
local GameCfg = require('common.game_cfg')

-- 前提守卫：本文件复现的是 main.lua 的接线，而不是自造一套协作关系。
local WIRING = {
    'local fishHost = WorldRuntime.fish_host',
    'local PlayerDataHost = require("server.player_data_host")',
}

local function assert_wiring()
    local handle = assert(io.open('server/main.lua', 'rb'), '读不到 server/main.lua')
    local source = handle:read('a')
    handle:close()
    for _, line in ipairs(WIRING) do
        assert.is_truthy(source:find(line, 1, true), 'server/main.lua 里找不到本文件复现的接线：' .. line)
    end
end

local function signal()
    local handlers = {}
    return {
        Connect = function(_, fn)
            handlers[#handlers + 1] = fn
            return { Disconnect = function() end }
        end,
        Fire = function(_, ...) for _, fn in ipairs(handlers) do fn(...) end end,
    }
end

local function newController()
    local c = { Health = 300, MaxHealth = 300, HealthChanged = signal(), Died = signal(), OnReborn = signal(),
        damages = {}, reborns = 0 }
    function c:TakeDamage(amount)
        self.damages[#self.damages + 1] = amount
        self.Health = math.max(0, self.Health - amount)
        self.HealthChanged:Fire(self.Health)
        if self.Health <= 0 then self.Died:Fire() end
    end
    function c:Reborn() self.reborns = self.reborns + 1 end
    return c
end

local function new_player(id)
    local p = { UserId = id, Name = 'p' .. id, attrs = {}, CharacterAdded = signal() }
    p.Character = { Controller = newController(), Position = { x = 0, y = 0, z = 0 }, Size = { y = 2 } }
    function p:SetAttribute(key, value) self.attrs[key] = value end
    return p
end

local EDIBLE = { ['食物'] = true, ['极品食物'] = true, ['鱼饵'] = true }

describe('条款 16-04 / 16-06 / 16-07：物品食用规则', function()
    local env

    before_each(function()
        assert_wiring()
        local Host = require('tests.support.life_host')
        env = { host = Host.start({ now = 0 }) }
        env.Vitals = env.host.runtime.life
        env.player = new_player(7001)
        env.host:add(env.player)
    end)

    after_each(function()
        if env and env.host then env.host:shutdown() end
    end)

    it('食物、极品食物与鱼饵可食用，恢复或扣减按恢复百分比生效', function()
        -- 负恢复项（如 item119）会真的扣血，扣到 0 之后 can_act 就拒绝一切进食——所以每件物品
        -- 各用一个新玩家，并把物品按 ID 排序，用例结果不随 pairs 的遍历顺序或进程哈希种子漂移。
        local ids = {}
        for id, item in pairs(GameCfg.Items.Definitions) do
            if EDIBLE[item.Type] then ids[#ids + 1] = id end
        end
        table.sort(ids)
        local checked = 0
        for _, id in ipairs(ids) do
            local item = GameCfg.Items.Definitions[id]
            local player = new_player(7100 + checked)
            env.host:add(player)
            checked = checked + 1
            assert.is_true(env.Vitals:can_eat(player, id), '可食用类别被拒：' .. id)
            env.Vitals:set_hunger(player, 100)
            local before = env.Vitals:GetState(player).tree.states.hunger:now()
            local healthBefore = player.Character.Controller.Health
            assert.is_true(env.Vitals:eat(player, id), '可食用类别吃不下：' .. id)
            local after = env.Vitals:GetState(player).tree.states.hunger:now()
            if item.EatPercent > 0 then
                assert.is_true(after > before, '正恢复没有回饥饿：' .. id)
            elseif item.EatPercent < 0 then
                assert.is_true(after <= before, '负恢复抬高了饥饿：' .. id)
                assert.is_true(player.Character.Controller.Health < healthBefore, '负恢复没有扣血：' .. id)
            else
                assert.are.equal(before, after, '零恢复改动了饥饿：' .. id)
            end
            env.host:remove(player)
        end
        assert.is_true(checked > 0, '物品表里没有可食用项')
    end)

    it('其余类别不能走普通食用', function()
        local checked = 0
        for id, item in pairs(GameCfg.Items.Definitions) do
            if not EDIBLE[item.Type] then
                checked = checked + 1
                assert.is_false(env.Vitals:can_eat(env.player, id), '非食用类别被当成可吃：' .. id)
                assert.is_false(env.Vitals:eat(env.player, id), '非食用类别吃成功：' .. id)
            end
        end
        assert.is_true(checked > 0, '物品表里没有非食用项')
    end)
end)
