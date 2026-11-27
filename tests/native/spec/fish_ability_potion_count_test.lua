-- 技能药剂计数（server/fish_ability.lua 的 FishAbility:potion_count）：技能展示与消耗药剂余量只经这一处读存档。
-- 失败方式：宿主没接存档时报出非 0（技能凭空可用）；读档抛错被吞成「有药」；存档里的脏值（非数字）
-- 被当数量返回；正常数量没跟着存档真源走。
-- 装配口径沿用 eel_ability_failure_test：包内技能系统与 AbilityAPI 都替换成桩，只取本文件的 Mgr；
-- server/fish_ability.lua 加载期就取 World / Task 服务，先在 _G 上挂替身再 loadfile。
local saved = {
  game = rawget(_G, "game"),
  api = package.loaded["server.ability_api"],
  vendor = package.loaded["server.packages.ability_system.api"],
}
_G.game = {
  GetService = function(_, name)
    if name == "World" then return { CreateAsset = function() return {} end } end
    if name == "Task" then return { Spawn = function(_, fn) fn() end, Wait = function() end } end
    return nil
  end,
}
package.loaded["server.ability_api"] = {}
package.loaded["server.packages.ability_system.api"] = {}
local FishAbility = assert(loadfile("server/fish_ability.lua"))()
local PlayerData = require("server.data.player_data")

local function ability_with(player_data)
  return setmetatable({ player_data = player_data }, { __index = FishAbility })
end

describe("FishAbility:potion_count 药剂计数", function()
  after_each(function()
    _G.game = saved.game
    package.loaded["server.ability_api"] = saved.api
    package.loaded["server.packages.ability_system.api"] = saved.vendor
  end)

  it("没接存档、读档抛错或脏值都报 0，不把失败当成有药", function()
    local player = { UserId = 42 }
    assert.same(0, FishAbility:potion_count(player, "item168"))
    assert.same(0, ability_with({ get_data_inst = function() error("读档失败") end }):potion_count(player, "item168"))
    local dirty = ability_with({ get_data_inst = function() return { potion_count = function() return "3" end } end })
    assert.same(0, dirty:potion_count(player, "item168"))
  end)

  it("数量跟着存档真源走，没持有的药剂报 0", function()
    local player = { UserId = 43, Name = "p43", SetAttribute = function() end }
    local data = PlayerData.new(player)
    data:Init()
    data.extra.growth.potions.item168 = 3
    local ability = ability_with({ get_data_inst = function() return data end })
    assert.same(3, ability:potion_count(player, "item168"))
    assert.same(0, ability:potion_count(player, "item167"))
  end)
end)
