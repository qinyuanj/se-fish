-- 服务端全局信号一次性路由工具（ADR-0032 §4）：
-- 按信号对象弱键建立唯一 `:Connect` 连接，避免每玩家树挂载时产生 O(N) 重复连接；
-- 玩家级信号按 UserId O(1) 路由并在 scope:on_cleanup 自动注销，世界级信号按活跃会话注销。
-- 更换假 RE 对象（如独立单测）时因弱键表不命中会自动绑定新信号。

local WorldSignalRouter = {}

local bound_player_signals = setmetatable({}, { __mode = "k" })
local bound_world_signals = setmetatable({}, { __mode = "k" })

function WorldSignalRouter.is_valid_player(player)
  local kind = type(player)
  return (kind == "table" or kind == "userdata") and player.UserId ~= nil
end

function WorldSignalRouter.bind_player(scope, signal, player, fn)
  if not signal or not WorldSignalRouter.is_valid_player(player) then return end
  local slot = bound_player_signals[signal]
  if not slot then
    local handlers = {}
    local connection = signal:Connect(function(actor, ...)
      if not WorldSignalRouter.is_valid_player(actor) then return end
      local entry = handlers[actor.UserId]
      if entry and entry.player == actor then
        entry.fn(actor, ...)
      end
    end)
    slot = { connection = connection, handlers = handlers }
    bound_player_signals[signal] = slot
  end
  local uid = player.UserId
  local entry = { player = player, fn = fn }
  slot.handlers[uid] = entry
  scope:on_cleanup(function()
    if slot.handlers[uid] == entry then
      slot.handlers[uid] = nil
    end
  end)
end

function WorldSignalRouter.bind_world(scope, signal, owner, fn)
  if not signal then return end
  local slot = bound_world_signals[signal]
  if not slot then
    local entry = { owner = nil, fn = nil }
    local connection = signal:Connect(function(...)
      if entry.owner ~= nil and entry.fn ~= nil then
        entry.fn(...)
      end
    end)
    entry.connection = connection
    bound_world_signals[signal] = entry
    slot = entry
  end
  slot.owner = owner
  slot.fn = fn
  scope:on_cleanup(function()
    if slot.owner == owner then
      slot.owner = nil
      slot.fn = nil
    end
  end)
end

return WorldSignalRouter
