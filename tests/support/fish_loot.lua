-- 鱼获共享夹具：真 PlayerData 配合举鱼假引擎，不注册测试案例。
-- 复用 fish_lift 的方式：以它为 __index 原型（同族统一手法），不再逐方法拷贝。
local FishLift = require('tests.support.fish_lift')
local M = setmetatable({}, { __index = FishLift })

--- 建一个空世界壳；调用方随后 :set_up() 搭世界、:tear_down() 拆除
--- （与 blindbox_world / revive_world 同一构造/拆除入口名）。
function M.new()
    return setmetatable({}, { __index = M })
end

local function vec(x, y, z)
    return setmetatable({ x = x, y = y, z = z }, { __add = function(a, b)
        return vec(a.x + b.x, a.y + b.y, a.z + b.z)
    end })
end

function M:set_up()
    self.savedColor = _G.Color
    self.lootModule = package.loaded['server.world_host.ground_loot']
    self.lootSaved = true
    _G.Color = { New = function(r, g, b, a) return { r = r, g = g, b = b, a = a } end }
    -- 拾饵消费者可能已经开启调试，保留它传入的原始基线。
    self.savedGrantDebug = self.savedGrantDebug or require('common.game_cfg').Debug
    require('common.game_cfg').Debug = { Enabled = true, InitialGrants = self.savedGrantDebug.InitialGrants }
    FishLift.set_up(self)
    local env = self
    self.diedSubs = {}
    package.loaded['server.world_host.fish_carrier'].subscribe_died = function(_, fn)
        env.diedSubs[#env.diedSubs + 1] = fn
        return true
    end
    self.groundY = 1.0
    self.physics = { Raycast = function(_, origin, direction)
        if direction.y < 0 then return { Position = vec(origin.x, env.groundY, origin.z), Distance = 1 } end
    end }
    _G.RaycastParams = { New = function() return { FilterDescendantsInstances = {} } end }
    local get = _G.game.GetService
    _G.game = { GetService = function(s, name)
        if name == 'PhysicsService' then return env.physics end
        return get(s, name)
    end }
    self.data = {}
    local PlayerData = assert(loadfile('server/data/player_data.lua'))()
    for _, player in ipairs({ self.player, self.other }) do
        player.SetAttribute = function() end
        local data = PlayerData.New(player)
        data:Init()
        self.data[player.UserId] = data
    end
    self.synced = {}
    self.broadcasts = 0
    self.replies = {}
    self.loot = { Loots = {}, Start = function() end }
end

function M:tear_down()
    if self.lootSaved then
        -- set_up 未完成时也按已保存状态回滚，避免半成品环境遗留到下一轮。
        local ok, err = pcall(function() FishLift.tear_down(self) end)
        _G.Color = self.savedColor
        if self.savedGrantDebug then require('common.game_cfg').Debug = self.savedGrantDebug end
        package.loaded['server.world_host.ground_loot'] = self.lootModule
        self.lootSaved = nil
        if not ok then error(err, 0) end
        return
    end
    FishLift.tear_down(self)
end

function M:kill(fish)
    for _, fn in ipairs(self.diedSubs) do fn(fish.Carrier) end
end

function M:loot_units()
    local list = {}
    for _, unit in ipairs(self.created) do
        if unit.UnitType == 'WorldUnit' and tostring(unit.Name):find('^FishLoot_') and not unit.Destroyed then
            list[#list + 1] = unit
        end
    end
    return list
end

function M:only_loot()
    local ids = {}
    for id in pairs(self.loot.Loots) do ids[#ids + 1] = id end
    assert(#ids == 1, '预期只有一份鱼获')
    return self.loot.Loots[ids[1]]
end

function M:bar(player)
    return self.data[player.UserId]:GetItemBarSnapshot().slots
end

return M
