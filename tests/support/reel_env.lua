local server_host = require("tests.support.fishing_host")
local client_host = require("tests.support.reel_view_host")

local Reel = {}
function Reel.new(kind)
  if kind == "server" then return server_host.new() end
  return client_host.new()
end
return Reel
