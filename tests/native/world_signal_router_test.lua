local WorldSignalRouter = require("server.world_host.world_signal_router")

describe("WorldSignalRouter 玩家信号路由", function()
  it("运行时自定义 Player 类型可绑定并接收信号，普通标量仍被拒绝（#392）", function()
    local player = { UserId = 392 }
    local received = {}
    local connected = 0
    local cleanup
    local signal = {}
    function signal:Connect(fn)
      connected = connected + 1
      self.handler = fn
      return { Disconnect = function() end }
    end
    local scope = { on_cleanup = function(_, fn) cleanup = fn end }
    local native_type = _G.type
    local ok, err = pcall(function()
      _G.type = function(value)
        if value == player then return "Player" end
        return native_type(value)
      end

      WorldSignalRouter.bind_player(scope, signal, nil, function() end)
      local scalars = { false, 0, "", function() end, coroutine.create(function() end) }
      for _, value in ipairs(scalars) do
        WorldSignalRouter.bind_player(scope, signal, value, function() end)
      end
      assert.equals(0, connected)

      WorldSignalRouter.bind_player(scope, signal, player, function(actor, value)
        received[#received + 1] = { actor = actor, value = value }
      end)
      assert.equals(1, connected)
      signal.handler(player, "accepted")
      assert.same({ { actor = player, value = "accepted" } }, received)

      signal.handler(nil, "rejected")
      for _, value in ipairs(scalars) do signal.handler(value, "rejected") end
      assert.equals(1, #received)
    end)
    _G.type = native_type
    if cleanup then cleanup() end
    if not ok then error(err, 0) end
  end)
end)
