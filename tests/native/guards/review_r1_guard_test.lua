-- 集成分支 R1 结构硬项守卫；行为仍由公开宿主规格测试证明。
local fs = require("tests.support.fs_fixture")

local function slurp(path)
  return assert(fs.slurp(path), path)
end

local function contains(text, needle)
  return text:find(needle, 1, true) ~= nil
end

describe("集成分支 R1 结构硬项", function()
  it("每条活鱼拥有 Auto SpokeTree 和 Lifted/Combat/Escaping Phase，且无集中 Update", function()
    local source = slurp("server/World/FishTree.lua")
    for _, needle in ipairs({
      "SpokeTree.spawn", "LiftedPhase", "CombatPhase", "EscapingPhase",
      ".on_frame", "on_cleanup", "HolderTree",
    }) do
      assert.is_true(contains(source, needle), "FishTree 缺少 " .. needle)
    end
    local update = source:match("function Mgr:Update%(%)(.-)\nend")
    assert.is_not_nil(update)
    assert.is_false(contains(update, "pairs(self.Fish)"), "Update 不得集中逐鱼循环")
    assert.is_false(contains(update, "UpdateFish"), "Update 只能泵帧 Trigger")
  end)

  it("官方 AI 不保存反向控制状态，也不读取官方 BehaviorRuntime", function()
    local source = slurp("server/World/FishAi.lua")
    for _, forbidden in ipairs({ "BehaviorRuntime", "Mgr.States", "HasActiveMove", "function Mgr:Sync" }) do
      assert.is_false(contains(source, forbidden), "FishAi 仍是反向控制层: " .. forbidden)
    end
  end)

  it("特殊道具按 selected 建独立 Phase，根作用域不常驻订阅 on_frame", function()
    local source = slurp("server/World/SpecialItemPhase.lua")
    assert.is_true(contains(source, '"WingsPhase"'))
    assert.is_true(contains(source, '"GodzillaPhase"'))
    assert.is_false(contains(source, "ps:subscribe(clock.on_frame"), "存活整个挂载期不得每帧 reconcile")
  end)

  it("GroundLoot 远程连接归世界树作用域且使用频控，不保留测试双生产回退", function()
    local source = slurp("server/World/GroundLoot.lua")
    assert.is_false(contains(source, "_ground_action_bound"))
    assert.is_false(contains(source, "_ground_request_bound"))
    assert.is_true(contains(source, "CheckRECD"))
    assert.is_true(contains(source, "GroundLootRemote"))
    assert.is_false(contains(source, "失败时退回普通表"))
  end)

  it("生命生产代码不含 DBG，重登协议注释仍是一次性虚弱复活", function()
    local source = slurp("server/World/PlayerLife.lua")
    assert.is_false(contains(source, "DBG reopen"))
    assert.is_true(contains(source, "survival:recover"))
  end)
end)
