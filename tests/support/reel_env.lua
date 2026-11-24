local ServerHost = require("tests.support.fishing_host")
local ClientHost = require("tests.support.reel_view_host")

local reel = {}
function reel.new(kind)
  if kind == "server" then return ServerHost.new() end
  return ClientHost.new()
end
return reel
