-- #302 兼容入口：旧测试已迁移，新增用例请直接使用两个公共宿主。
local ServerHost = require("tests.support.fishing_host")
local ClientHost = require("tests.support.reel_view_host")

local Reel = {}
function Reel.new(kind)
  if kind == "server" then return ServerHost.new() end
  return ClientHost.new()
end
return Reel
