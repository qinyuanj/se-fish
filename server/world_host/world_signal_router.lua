
local EngineRead = require("common.engine_read")

local WorldSignalRouter = {}

local bound_player_signals = setmetatable({}, { __mode = "k" })
local bound_world_signals = setmetatable({}, { __mode = "k" })

function WorldSignalRouter.is_valid_player(player)
  return EngineRead.is_valid_player(player)
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
