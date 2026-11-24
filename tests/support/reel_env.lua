local ServerHost = require("tests.support.fishing_host")
local ClientHost = require("tests.support.reel_view_host")

local Reel = {}
function Reel.new(kind)
  if kind == "server" then return ServerHost.new() end
  return ClientHost.new()
end
return Reel
