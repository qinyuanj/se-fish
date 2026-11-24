local EconomyWorld = require("tests.support.economy_world")

local M = {}
function M.new()
  local world = EconomyWorld.new()
  world.set_up = function() end
  world.draw = world.blindbox_draw
  local last_result = world.last_result
  world.last_result = function(self, name)
    return last_result(self, name or "BlindboxResult")
  end
  return world
end
return M
