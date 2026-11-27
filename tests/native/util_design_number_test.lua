-- 设计数值展示（common/util.lua 的 Util:design_number）：金币、伤害这类大数在界面上只经这一处换算成 K/M/B。
-- 失败方式：负数被换算成 "0.00K"；未到千位就加后缀；过千/百万/十亿仍用原始长串；
-- 后缀与数量级错配（1.2K 显示成 1.2M）；keepNum 不生效（小数位恒为 2）。
-- common/util.lua 在加载期就取 Task/RunService/World 并在服务端挂 RE 监听，所以先在 _G 上挂替身再 require。
local saved = { game = rawget(_G, "game"), re = rawget(_G, "REUtil") }
local channels = {}
_G.game = {
  GetService = function(_, name)
    if name == "Task" then return { Wait = function() end } end
    if name == "RunService" then
      return { IsServer = function() return true end, IsClient = function() return false end }
    end
    if name == "World" then return { GetServerTime = function() return 0 end } end
    if name == "Players" then
      return { PlayerRemoving = { Connect = function() return { Disconnect = function() end } end } }
    end
    return nil
  end,
}
_G.REUtil = {
  get_re = function(_, name)
    channels[name] = channels[name] or {
      OnServerEvent = { Connect = function() return { Disconnect = function() end } end },
      OnClientEvent = { Connect = function() return { Disconnect = function() end } end },
      FireClient = function() end,
      FireAllClients = function() end,
    }
    return channels[name]
  end,
}
-- common/re_util.lua 在加载期给服务端事件建 RemoteEvent，替身只补它用到的成员。
_G.RemoteEvent = { New = function()
  return {
    OnServerEvent = { Connect = function() return { Disconnect = function() end } end },
    OnClientEvent = { Connect = function() return { Disconnect = function() end } end },
    FireClient = function() end,
    FireAllClients = function() end,
  }
end }
local Util = require("common.util")

describe("Util:design_number 设计数值展示", function()
  it("不到千位与负数保持原样，不加后缀也不进小数格式化", function()
    assert.same("0", Util:design_number(0))
    assert.same("999", Util:design_number(999))
    assert.same("-1500", Util:design_number(-1500))
  end)

  it("千/百万/十亿各用对应后缀，并按 keepNum 决定小数位", function()
    assert.same("1.50K", Util:design_number(1500))
    assert.same("1.23K", Util:design_number(1234))
    assert.same("2.50M", Util:design_number(2500000))
    assert.same("3.20B", Util:design_number(3200000000))
    assert.same("1.5K", Util:design_number(1500, 1))
    assert.same("2K", Util:design_number(1500, 0))
  end)
end)

return saved
