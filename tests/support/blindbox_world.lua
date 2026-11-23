-- 兼容旧文件名；实际搭建与驱动统一走 #312 ServerRuntime 宿主测试双。
local EconomyWorld = require("tests.support.economy_world")

local M = {}
function M.new()
  local world = EconomyWorld.new()
  world.setUp = function() end
  world.draw = world.blindboxDraw
  local last_result = world.lastResult
  world.lastResult = function(self, name)
    return last_result(self, name or "BlindboxResult")
  end
  return world
end
return M
