-- #172 出手动作（引擎官方动画临时占位，正式资源见 #44）。
-- 失败方式先列：
--   1. 空手 / 某近战 / 某枪 / 投掷漏配 Anim，或 ID 取自 data/OfficialAsset.lua 的 motion 段
--      （那里的 ID 不是 SE 运行时 ID，试玩实测 20701、20880 在蛋仔上不动；正确 ID 查手册「动作 · 资产目录」）→ 出手不动；
--   2. 被拒的出手（冷却、空匣、换弹中）也播动作 → 画面与结算不一致；
--   3. 近战施法失败仍播动作；
--   4. Animator 缺失或 LoadAnimation 抛错时连带攻击失败；
--   5. 动作被走跑动画盖掉（未设上半身过滤与 Action 优先级）、循环播放。
--   6. 每次出手都 LoadAnimation 新 track（自动枪 0.15 秒一发会不停堆积）；优先级赋值不被运行时接受时连带不播。
local Weapon = require('tests.support.weapon_world')
local GameCfg = require('common.GameCfg')

local function exportedMotionIds()
    local ids = {}
    for _, id in pairs(dofile('data/OfficialAsset.lua').motion) do ids[id] = true end
    return ids
end

local function configuredAnimations(node, path, found)
    for key, value in pairs(node) do
        local here = path .. '.' .. tostring(key)
        if type(value) == 'table' then
            configuredAnimations(value, here, found)
        elseif type(value) == 'string' and value:match('^official://animation/') then
            found[#found + 1] = { here, value }
        end
    end
    return found
end

local function attackSources()
    local ability = GameCfg.Ability
    local sources = { { 'Unarmed', ability.Unarmed }, { 'Throw', ability.Throw } }
    for id, row in pairs(ability.MeleeWeapons) do sources[#sources + 1] = { 'MeleeWeapons.' .. id, row } end
    for id, row in pairs(ability.Guns) do sources[#sources + 1] = { 'Guns.' .. id, row } end
    return sources
end

describe('攻击动作配置', function()
    it('空手、每把近战与枪械、投掷都配了官方动画', function()
        for _, source in ipairs(attackSources()) do
            local name, row = source[1], source[2]
            assert.is_string(row.Anim, name .. ' 缺 Anim')
            assert.is_truthy(row.Anim:match('^official://animation/%d+$'), name .. ' 的 Anim 不是官方动画 URI: ' .. row.Anim)
        end
    end)

    it('GameCfg 里的官方动画都不取自 OfficialAsset 的 motion 段', function()
        local exported = exportedMotionIds()
        for _, entry in ipairs(configuredAnimations(GameCfg, 'GameCfg', {})) do
            assert.is_nil(exported[entry[2]], entry[1] .. ' 用了 OfficialAsset.motion 的 ID: ' .. entry[2])
        end
    end)
end)

describe('攻击动作播放', function()
    local ctx
    before_each(function()
        ctx = Weapon.new()
        ctx:setUp()
        ctx.tracks = {}
        ctx.player.Character.Animator = { LoadAnimation = function(_, id)
            local track = { id = id, plays = 0 }
            function track:Play(fade, weight, speed) self.plays = self.plays + 1; self.args = { fade, weight, speed } end
            ctx.tracks[#ctx.tracks + 1] = track
            return track
        end }
    end)
    after_each(function()
        ctx:tearDown()
    end)

    local function played()
        local ids = {}
        for _, track in ipairs(ctx.tracks) do
            if track.plays > 0 then ids[#ids + 1] = track.id end
        end
        return ids
    end

    it('空手挥砍成功后播空手动作，上半身、Action 优先级、不循环', function()
        assert.is_true(ctx.mgr:Attack(ctx.player).ok)
        assert.same({ GameCfg.Ability.Unarmed.Anim }, played())
        local track = ctx.tracks[1]
        assert.same({ 30, 2, false, 1 }, { track.FilterType, track.Priority, track.Looped, track.plays })
    end)

    it('近战武器播本武器的动作；冷却被拒不播', function()
        ctx.data:GrantWeapon('item136', 1); ctx.data:HoldWeapon('item136')
        assert.is_true(ctx.mgr:Attack(ctx.player).ok)
        ctx.now = ctx.now + 0.1
        assert.same('cooldown', ctx.mgr:Attack(ctx.player).reason)
        assert.same({ GameCfg.Ability.MeleeWeapons.item136.Anim }, played())
    end)

    it('近战施法失败不播', function()
        package.loaded['server.AbilityAPI'].CastAbility = function() return false end
        assert.same('cast-failed', ctx.mgr:Attack(ctx.player).reason)
        assert.same({}, played())
    end)

    it('开枪播本枪动作；空匣与换弹中被拒不播', function()
        ctx.data:GrantWeapon('item142', 1); ctx.data:HoldWeapon('item142') -- 火箭筒 1 发
        assert.is_true(ctx.mgr:Attack(ctx.player).ok)
        ctx.now = ctx.now + 3
        assert.same('empty', ctx.mgr:Attack(ctx.player).reason)
        ctx.now = ctx.now + 0.5
        assert.same('reloading', ctx.mgr:Attack(ctx.player).reason)
        assert.same({ GameCfg.Ability.Guns.item142.Anim }, played())
    end)

    it('连续开火复用同一 track', function()
        ctx.data:GrantWeapon('item139', 1); ctx.data:HoldWeapon('item139')
        assert.is_true(ctx.mgr:Attack(ctx.player).ok)
        ctx.now = ctx.now + 1
        assert.is_true(ctx.mgr:Attack(ctx.player).ok)
        assert.same(1, #ctx.tracks)
        assert.same(2, ctx.tracks[1].plays)
    end)

    it('优先级赋值被拒时照样播', function()
        ctx.player.Character.Animator = { LoadAnimation = function(_, id)
            local track = setmetatable({ id = id, plays = 0 }, { __newindex = function(t, key, value)
                if key == 'Priority' then error('bad enum') end
                rawset(t, key, value)
            end })
            function track.Play(self) self.plays = self.plays + 1 end
            ctx.tracks[#ctx.tracks + 1] = track
            return track
        end }
        assert.is_true(ctx.mgr:Attack(ctx.player).ok)
        assert.same({ GameCfg.Ability.Unarmed.Anim }, played())
    end)

    it('投掷出手播投掷动作', function()
        ctx.mgr.ResolveTarget = function() return { x = 0, y = 2, z = 5 }, nil end
        ctx.mgr:Launch(ctx.player, 'item143', nil)
        assert.same({ GameCfg.Ability.Throw.Anim }, played())
    end)

    it('没有 Animator 或加载抛错时攻击照常成功', function()
        ctx.player.Character.Animator = nil
        assert.is_true(ctx.mgr:Attack(ctx.player).ok)
        ctx.now = ctx.now + 1
        ctx.player.Character.Animator = { LoadAnimation = function() error('boom') end }
        assert.is_true(ctx.mgr:Attack(ctx.player).ok)
    end)
end)
