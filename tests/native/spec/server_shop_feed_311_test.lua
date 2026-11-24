
local GameCfg = require("common.game_cfg")
local ServerRuntime = require("server.world_host.server_runtime")

local function signal()
  local handlers = {}
  return {
    Connect = function(_, fn)
      handlers[#handlers + 1] = fn
      return { Disconnect = function() end }
    end,
    Fire = function(_, ...)
      for _, fn in ipairs(handlers) do fn(...) end
    end,
  }
end

local function vec(x, y, z) return { x = x, y = y, z = z } end

describe("服务端商店与钓鱼佬原子事务（#311）", function()
  local ctx

  local function drain()
    while #ctx.queue > 0 do table.remove(ctx.queue, 1)() end
  end

  local function join(id, target, before_ready)
    local center = target == "shop" and vec(0, 0, 0) or vec(100, 0, 0)
    local player = {
      UserId = id,
      Name = "p" .. id,
      attrs = {},
      CharacterAdded = signal(),
      CharacterRemoving = signal(),
      Character = {
        Position = vec(center.x, center.y, center.z),
        Size = { y = 2 },
        Controller = { Health = GameCfg.Vitals.MaxHealth },
      },
    }
    function player:SetAttribute(key, value) self.attrs[key] = value end
    local data = ctx.PlayerData.New(player)
    data:Init(true)
    ctx.save:load_into(player, data)
    drain()
    if before_ready then before_ready(data) end
    ctx.datas[id] = data
    ctx.players[#ctx.players + 1] = player
    ctx.runtime:on_player_added(player)
    ctx.runtime:on_save_ready(player, data)
    drain()
    return player, data
  end

  local function act(player, channel, payload)
    ctx.seq = (ctx.seq or 0) + 1
    payload.seq = payload.seq or ctx.seq
    _G.REUtil:get_re(channel).OnServerEvent:Fire(player, payload)
    drain()
    local results = player.results and player.results[channel == "ShopAction" and "ShopResult" or "InteractResult"]
    return results and results[#results] or nil
  end

  before_each(function()
    ctx = { values = {}, queue = {}, events = {}, datas = {}, players = {}, snapshots = {}, plays = {} }
    ctx.old_game, ctx.old_re, ctx.old_debug = _G.game, _G.REUtil, GameCfg.Debug
    GameCfg.Debug = { Enabled = false }
    ctx.store = {
      GetAsync = function(_, key) return ctx.values[key] end,
      UpdateAsync = function(_, key, transform)
        local value = transform(ctx.values[key])
        if value then ctx.values[key] = value end
        return value
      end,
      SetAsync = function(_, key, value) ctx.values[key] = value end,
    }
    ctx.anchors = {}
    for _, stand in ipairs(GameCfg.Shop.Stands) do
      ctx.anchors[stand.AnchorName] = { Name = stand.AnchorName, Position = vec(0, 0, 0) }
    end
    for _, npc in ipairs(GameCfg.Interact.Fishermen) do
      for _, name in ipairs(npc.AnchorNames) do
        ctx.anchors[name] = {
          Name = name,
          Position = vec(100, 0, 0),
          PlayAnimation = function(_, animation) ctx.plays[#ctx.plays + 1] = animation end,
        }
      end
    end
    _G.game = { GetService = function(_, name)
      if name == "Task" then
        return { Spawn = function(_, fn) ctx.queue[#ctx.queue + 1] = fn end, Wait = function() end }
      end
      if name == "DataStoreService" then return { GetDataStore = function() return ctx.store end } end
      if name == "World" then
        return {
          GetServerTime = function() return ctx.runtime and ctx.runtime.clock.now() or 1000 end,
          FindFirstChild = function(_, child_name) return ctx.anchors[child_name] end,
        }
      end
      if name == "Players" then return { GetPlayers = function() return ctx.players end } end
    end }
    _G.REUtil = {
      check_recd = function() return false end,
      get_re = function(_, name)
        if not ctx.events[name] then
          ctx.events[name] = {
            OnServerEvent = signal(),
            OnClientEvent = signal(),
            FireClient = function(self, player, payload)
              if name == "ItemBarState" then
                ctx.snapshots[player.UserId] = payload
              elseif name == "ShopResult" or name == "InteractResult" then
                player.results = player.results or {}
                player.results[name] = player.results[name] or {}
                player.results[name][#player.results[name] + 1] = payload
              end
            end,
          }
        end
        return ctx.events[name]
      end,
    }
    ctx.PlayerData = assert(loadfile("server/data/player_data.lua"))()
    ctx.save = assert(loadfile("server/save_host.lua"))()
    ctx.runtime = ServerRuntime.new({
      initial_now = 1000,
      remote = _G.REUtil,
      player_data = { get_data_inst = function(_, player) return ctx.datas[player.UserId] end },
      save = ctx.save,
      players_service = _G.game:GetService("Players"),
      world_service = _G.game:GetService("World"),
      on_item_bar_state = function(player, snapshot)
        _G.REUtil:get_re("ItemBarState"):FireClient(player, snapshot)
      end,
      bind_shop_action = function(dispatch)
        _G.REUtil:get_re("ShopAction").OnServerEvent:Connect(dispatch)
      end,
      bind_interact_action = function(dispatch)
        _G.REUtil:get_re("InteractAction").OnServerEvent:Connect(dispatch)
      end,
    })
    ctx.runtime:start()
    ctx.runtime:mark_started()
  end)

  after_each(function()
    if ctx.runtime then ctx.runtime:shutdown() end
    _G.game, _G.REUtil = ctx.old_game, ctx.old_re
    GameCfg.Debug = ctx.old_debug
  end)

  it("购买鱼竿在同一批扣金币、发货并刷新库存快照", function()
    local player, data = join(31101, "shop", function(d) d:AddCoin(20, nil, "test") end)
    local reply = act(player, "ShopAction", { action = "Buy", itemId = "starterRod" })
    assert.is_not_nil(reply)
    assert.is_true(reply.ok)
    assert.same(15, data.Data.FishCoin)
    assert.same(1, data:ItemCount("starterRod"))
    assert.same(15, ctx.snapshots[player.UserId].coin)
  end)

  it("扩容逐级落账并同步道具栏与背包容量", function()
    local player, data = join(31102, "shop", function(d) d:AddCoin(100, nil, "test") end)
    local reply = act(player, "ShopAction", { action = "UpgradeStorage" })
    assert.is_not_nil(reply)
    assert.is_true(reply.ok)
    assert.same("UpgradeStorage", reply.action)
    assert.same(0, data.Data.FishCoin)
    assert.same(1, data.Data.UpgradeLevel)
    assert.same(3, ctx.snapshots[player.UserId].slotCount)
    assert.same(10, ctx.snapshots[player.UserId].backpackCount)
  end)

  it("相同持久操作重放返回原结果且不重复扣款发货", function()
    local player, data = join(31103, "shop", function(d) d:AddCoin(20, nil, "test") end)
    local request = { action = "Buy", itemId = "starterRod", seq = 9 }
    local first = act(player, "ShopAction", request)
    local replies = #player.results.ShopResult
    local replay = act(player, "ShopAction", request)
    assert.is_true(first.ok)
    assert.is_true(replay.ok)
    assert.same(first.operation.id, replay.operation.id)
    assert.same(15, data.Data.FishCoin)
    assert.same(1, data:ItemCount("starterRod"))
    assert.same(replies + 1, #player.results.ShopResult)
  end)

  it("喂食选中鱼获按个体倍率一次结算并同步库存", function()
    local player, data = join(31104, "fisherman", function(d)
      assert.is_true(d:AddItem("bass", 1.99))
      assert.is_true(d:SelectSlot(1))
    end)
    local reply = act(player, "InteractAction", { target = "fisherman", action = "Feed" })
    assert.is_not_nil(reply)
    assert.is_true(reply.ok)
    assert.same(11, reply.coins)
    assert.same(11, data.Data.FishCoin)
    assert.is_nil(data.Data.Containers.itemBar[1])
    assert.is_nil(data.Data.SelectedSlot)
    assert.same(11, ctx.snapshots[player.UserId].coin)
    assert.same({ GameCfg.Interact.Fisherman.EatAnimation }, ctx.plays)
  end)

  it("信物兑换与产物交付原子完成并使用交付释放的格位", function()
    local player, data = join(31105, "fisherman", function(d)
      assert.is_true(d:AddItem("eelHead"))
      while d:AddItem("tilapia") do end
      assert.is_true(d:SelectSlot(1))
    end)
    local reply = act(player, "InteractAction", { target = "fisherman", action = "Feed" })
    assert.is_not_nil(reply)
    assert.is_true(reply.ok)
    assert.same({ from = "eelHead", to = "duck" }, reply.exchange)
    assert.same(0, data:ItemCount("eelHead"))
    assert.same(1, data:ItemCount("duck"))
    assert.same("duck", data.Data.Containers.itemBar[1].itemId)
    assert.same(0, data.Data.FishCoin)
    assert.is_nil(data.Data.SelectedSlot)
  end)

  it("旧交互管理器拆除后抢救仍经统一宿主按距离受理", function()
    local downed = join(31106, "fisherman")
    local rescuer = join(31107, "fisherman")
    rescuer.Character.Position.x = 102
    ctx.runtime.life:apply_hit(ctx.runtime.life:new_hit(nil, "fishAttack"), downed,
      GameCfg.Vitals.MaxHealth + 1)
    assert.same("downed", ctx.runtime.life:Phase(downed))
    local reply = act(rescuer, "InteractAction", {
      target = GameCfg.Rescue.Target,
      action = GameCfg.Rescue.Action,
      targetUserId = downed.UserId,
    })
    assert.is_not_nil(reply)
    assert.is_true(reply.ok)
    assert.same("rescuing", ctx.runtime.life:Phase(downed))
  end)
end)
