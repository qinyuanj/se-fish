-- 由 tests/native/hook_cleanup_test.lua 以子进程执行的故意失败夹具。
-- 文件名故意不匹配 _test 且 fixtures/ 不在任何车道 ROOT 内，不进入 Busted 发现范围。
local game_cfg = require("common.game_cfg")

local function rec(tag)
  io.stdout:write("EV:" .. tag .. "\n")
end

describe("outer", function()
  before_each(function() rec("outer_before") end)
  after_each(function() rec("outer_after") end)

  describe("pollution", function()
    it("dirties the shared config then fails", function()
      game_cfg.Debug = { Enabled = false }
      game_cfg.Save.QaSlot = "dirty"
      error("intentional fixture failure")
    end)
    it("observes the config restored by the helper", function()
      rec("cfg_enabled=" .. tostring(game_cfg.Debug.Enabled))
      rec("cfg_slot=" .. (game_cfg.Save.QaSlot == "" and "EMPTY" or game_cfg.Save.QaSlot))
    end)
  end)

  describe("inner", function()
    before_each(function()
      rec("inner_before")
      error("intentional inner before_each failure")
    end)
    after_each(function() rec("inner_after") end)
    it("body must not run", function() rec("test_body") end)
    describe("deeper", function()
      after_each(function() rec("deeper_after") end)
      it("deeper body must not run", function() rec("deeper_body") end)
    end)
  end)

  describe("sibling", function()
    after_each(function() rec("sibling_after") end)
    it("sibling still runs", function() rec("sibling_body") end)
  end)
end)
