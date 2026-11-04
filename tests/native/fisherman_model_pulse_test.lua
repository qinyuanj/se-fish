-- #172 七区钓鱼佬各有模型（Fishermen[i].ModelName），喂食吃动作脉冲只落在喂食所在区。
-- 失败方式先列：沿用全图唯一名导致只认一个模型；喂 03 却脉冲 01；某区缺模型时别区也不播；
-- 脉冲结束残留放大；写 Scale 失败后反复报错。
local GameCfg = require('common.GameCfg')

describe('钓鱼佬模型按区脉冲', function()
    local saved, interact, models, sent
    local function model(scale)
        return { Scale = { x = scale, y = scale, z = scale } }
    end
    before_each(function()
        saved = { game = rawget(_G, 'game'), vector = rawget(_G, 'Vector3'), util = package.loaded['common.Util'],
            re = package.loaded['common.REUtil'], interact = package.loaded['client.LocalInteract'] }
        _G.Vector3 = { New = function(x, y, z) return { x = x, y = y, z = z } end }
        _G.game = { GetService = function() return {} end }
        models, sent = {}, {}
        package.loaded['common.Util'] = { WaitForChild = function(_, _, name) return models[name] end }
        package.loaded['common.REUtil'] = { GetRE = function()
            return { FireServer = function(_, payload) sent[#sent + 1] = payload end }
        end }
        package.loaded['client.LocalInteract'] = nil
        interact = assert(loadfile('client/LocalInteract.lua'))()
    end)
    after_each(function()
        _G.game, _G.Vector3 = saved.game, saved.vector
        package.loaded['common.Util'] = saved.util
        package.loaded['common.REUtil'] = saved.re
        package.loaded['client.LocalInteract'] = saved.interact
    end)

    it('每区一个模型名，01 沿用 FishermanModel，名字互不重复', function()
        local names = {}
        for index, npc in ipairs(GameCfg.Interact.Fishermen) do names[index] = npc.ModelName end
        assert.same({ 'FishermanModel', 'Z2_FishermanModel', 'Z3_FishermanModel', 'Z4_FishermanModel',
            'Z5_FishermanModel', 'Z6_FishermanModel', 'Z7_FishermanModel' }, names)
    end)

    it('喂 03 只脉冲 03 的模型，结束还原基准缩放', function()
        models.FishermanModel, models.Z3_FishermanModel = model(1), model(2)
        for index, npc in ipairs(GameCfg.Interact.Fishermen) do interact:BindModel(index, npc) end
        interact:Feed(3)
        assert.same('Feed', sent[1].action)
        interact:StartPulse()
        local peak = 0
        while interact.PulseLeft do
            interact:UpdatePulse()
            peak = math.max(peak, models.Z3_FishermanModel.Scale.x)
        end
        assert.is_true(peak > 2)
        assert.same({ x = 2, y = 2, z = 2 }, models.Z3_FishermanModel.Scale)
        assert.same({ x = 1, y = 1, z = 1 }, models.FishermanModel.Scale)
    end)

    it('喂食所在区缺模型时不播，别区照常', function()
        models.FishermanModel = model(1)
        for index, npc in ipairs(GameCfg.Interact.Fishermen) do interact:BindModel(index, npc) end
        interact:Feed(5)
        interact:StartPulse()
        assert.is_nil(interact.PulseLeft)
        interact:Feed(1)
        interact:StartPulse()
        assert.is_not_nil(interact.PulseLeft)
    end)

    it('写 Scale 失败后丢弃该模型，不再重试', function()
        local broken = setmetatable({}, { __index = function(_, key)
            if key == 'Scale' then return { x = 1, y = 1, z = 1 } end
        end, __newindex = function() error('locked') end })
        models.FishermanModel = broken
        interact:BindModel(1, GameCfg.Interact.Fishermen[1])
        interact:Feed(1)
        interact:StartPulse()
        interact:UpdatePulse()
        assert.is_nil(interact.PulseLeft)
        interact:StartPulse()
        assert.is_nil(interact.PulseLeft)
    end)
end)
