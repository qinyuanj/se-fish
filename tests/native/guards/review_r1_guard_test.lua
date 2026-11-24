local Arch = require("tools.arch_policy")
local fs = require("tests.support.fs_fixture")

local function slurp(path)
  return assert(fs.slurp(path), path)
end

local function contains(text, needle)
  return text:find(needle, 1, true) ~= nil
end

describe("集成分支 R1 结构硬项", function()
  it("每条活鱼拥有 Auto SpokeTree 和 Lifted/Combat/Escaping Phase，且无集中 Update", function()
    local source = slurp("server/world_host/fish_tree.lua")
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
    local source = slurp("server/world_host/fish_ai.lua")
    for _, forbidden in ipairs({ "BehaviorRuntime", "Mgr.States", "HasActiveMove", "function Mgr:Sync" }) do
      assert.is_false(contains(source, forbidden), "FishAi 仍是反向控制层: " .. forbidden)
    end
  end)

  it("特殊道具按 selected 建独立 Phase，根作用域不常驻订阅 on_frame", function()
    local source = slurp("server/world_host/special_item_phase.lua")
    assert.is_true(contains(source, '"WingsPhase"'))
    assert.is_true(contains(source, '"GodzillaPhase"'))
    assert.is_false(contains(source, "ps:subscribe(clock.on_frame"), "存活整个挂载期不得每帧 reconcile")
  end)

  it("GroundLoot 远程连接归世界树作用域且使用频控，不保留测试双生产回退", function()
    local source = slurp("server/world_host/ground_loot.lua")
    assert.is_false(contains(source, "_ground_action_bound"))
    assert.is_false(contains(source, "_ground_request_bound"))
    assert.is_true(contains(source, "CheckRECD"))
    assert.is_true(contains(source, "GroundLootRemote"))
    assert.is_false(contains(source, "失败时退回普通表"))
  end)

  it("生命模块保留重登一次性虚弱复活与离场终镜像结构，且无临时 DBG 调试输出", function()
    local source = slurp("server/world_host/player_life.lua")
    local code = Arch.code_only(source)
    local from = 1
    while true do
      local pos = code:find("print%s*%(", from)
      if not pos then break end
      assert.is_nil(source:sub(pos):match("^print%s*%(%s*['\"]DBG"),
        "PlayerLife 生产代码不得残留 DBG 调试 print")
      from = pos + 5
    end
    local has_recover_request = false
    from = 1
    while true do
      local pos = code:find("ResolveRequest%s*%(", from)
      if not pos then break end
      local call = source:sub(pos):match("^ResolveRequest%s*(%b())")
      if call and call:find("['\"]survival:recover['\"]") then
        has_recover_request = true
        break
      end
      from = pos + 14
    end
    assert.is_true(has_recover_request, "PlayerLife 缺少重登恢复事务键 survival:recover 调用")
    assert.is_true(contains(code, "weak_revive()"), "PlayerLife 缺少一次性虚弱复活调用")
    assert.is_true(contains(code, "register_leave_finalizer"), "PlayerLife 缺少离场终镜像登记")
  end)
end)
