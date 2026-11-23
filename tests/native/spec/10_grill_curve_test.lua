-- 条款 10-03 / 10-06 / 10-07 / 10-08 / 10-10 / 10-11 / 10-12 / 10-13 / 10-14 / 10-15
-- （docs/acceptance/10-grilling.md）：
--   10-03 只有未烤制的鱼获可以放入烧烤点；10-06 0～2 秒由 1.00 线性升到 1.50；
--   10-07 2～2.5 秒保持 1.50；10-08 2.5～4.5 秒由 1.50 线性降到 0.00；
--   10-10 取出时按取出瞬间的倍率结算，取出后不再随时间变化；
--   10-11 4.5 秒没取出就烤糊损毁、从烧烤点消失；10-12 烤糊瞬间对周围 3 米玩家各 30 点伤害；
--   10-13 烤糊时向操作者提示「烤糊」；10-14 取出后放回可用格位并保持选中；
--   10-15 烤过的鱼不可再次放入烧烤点。
-- 只走业务入口：玩家 GrillAction 经 PlayerGrill 宿主绑定进来，断言落在下发给玩家的
-- GrillResult / GrillState 上。引擎边界（World 时钟与锚点、Players、Task、DataStore、RE）用替身；
-- 伤害经生命公开入口落到 Controller 替身，只记「谁被打了多少」。
-- 失败方式（先列后写）：
--   1. 曲线不是分段线性的（1 / 2.25 / 3.5 秒读数错位），或曲线读的是帧数不是服务器时刻；
--   2. 取出后倍率还在涨，或物品回不到格位、不保持选中；
--   3. 4.5 秒不烤糊、烤糊后物品还在、3 米内的玩家没吃伤害、操作者收不到烤糊提示；
--   4. 非鱼获或烤过的鱼获也能投入。
local GameCfg = require('common.GameCfg')

local FISH = 'carp'      -- 普通鱼获：可烤
local NOT_FISH = 'item126' -- 核废料桶：不是鱼获

local function signal()
  local handlers = {}
  return {
    Connect = function(_, fn)
      handlers[#handlers + 1] = fn
      return { Disconnect = function() end }
    end,
    Fire = function(_, ...) for _, fn in ipairs(handlers) do fn(...) end end,
  }
end

describe('条款 10：烧烤倍率与会话规则', function()
  local ctx

  local function drain() while #ctx.queue > 0 do table.remove(ctx.queue, 1)() end end

  local function grillAnchor()
    for _, entity in ipairs(GameCfg.Zones[3].Scene.Entities) do
      if entity.Role == 'Grill' then return entity end
    end
  end

  before_each(function()
    ctx = { values = {}, queue = {}, now = 1000, events = {}, hits = {}, seq = 0, list = {} }
    ctx.oldGame, ctx.oldRE = _G.game, _G.REUtil
    ctx.oldDebug = GameCfg.Debug
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
    ctx.anchorPos = grillAnchor().Position
    _G.game = { GetService = function(_, name)
      if name == 'Task' then
        return { Spawn = function(_, fn) ctx.queue[#ctx.queue + 1] = fn end, Wait = function() end }
      end
      if name == 'DataStoreService' then return { GetDataStore = function() return ctx.store end } end
      if name == 'World' then return { GetServerTime = function() return ctx.now end } end
      if name == 'Players' then return { GetPlayers = function() return ctx.list end } end
    end }
    _G.REUtil = { CheckRECD = function() return false end, GetRE = function(_, name)
      if not ctx.events[name] then
        ctx.events[name] = { OnServerEvent = signal(),
          FireClient = function(_, player, payload)
            if name == 'GrillResult' then
              player.results = player.results or {}
              player.results[#player.results + 1] = payload
            elseif name == 'GrillState' then
              player.state = payload
            end
          end }
      end
      return ctx.events[name]
    end }
    ctx.events.GrillAction = { OnServerEvent = signal(), FireClient = function() end }
    ctx.PlayerData = assert(loadfile('server/Data/PlayerData.lua'))()
    ctx.save = assert(loadfile('server/SaveHost.lua'))()
    ctx.ServerRuntime = assert(loadfile('server/World/ServerRuntime.lua'))()
    ctx.datas = {}
    ctx.runtime = ctx.ServerRuntime.new({
      initial_now = ctx.now,
      remote = _G.REUtil,
      player_data = { GetDataInst = function(_, player) return ctx.datas[player.UserId] end },
      save = ctx.save,
      players_service = { GetPlayers = function() return ctx.list end },
      world_service = {
        FindFirstChild = function(_, name)
          if name == GameCfg.Zones[3].Scene.GrillName then
            return { Name = name, Position = ctx.anchorPos }
          end
        end,
      },
      create_unit = function(kind, props)
        return { kind = kind, Name = props and props.Name,
          Destroy = function(self) self.Destroyed = true end }
      end,
      bind_grill_action = function(dispatch)
        ctx.events.GrillAction.OnServerEvent:Connect(function(player, payload)
          dispatch(player, payload)
        end)
      end,
    })
    ctx.runtime:start()
    ctx.runtime:mark_started()
    ctx.mgr = { GetSession = function(_, player)
      local state = player.state and player.state.state
      return (state == 'cooking' or state == 'ready') and player.state or nil
    end }
  end)

  after_each(function()
    _G.game, _G.REUtil = ctx.oldGame, ctx.oldRE
    GameCfg.Debug = ctx.oldDebug
  end)

  -- 站在烧烤点旁（1 米内）；atGrill=false 站 100 米外
  local function join(id, atGrill)
    local player = { UserId = id, Name = 'p' .. id, attrs = {}, CharacterAdded = signal(),
      Character = { Position = { x = ctx.anchorPos.x + (atGrill == false and 100 or 1),
        y = ctx.anchorPos.y, z = ctx.anchorPos.z }, Size = { y = 2 },
        Controller = { Health = GameCfg.Vitals.MaxHealth,
          TakeDamage = function(self, amount)
            self.Health = math.max(0, self.Health - amount)
            ctx.hits[#ctx.hits + 1] = { category = 'grillBurn', userId = id, amount = amount }
          end } } }
    function player:SetAttribute(key, value) self.attrs[key] = value end
    local data = ctx.PlayerData.New(player)
    data:Init(true)
    ctx.save:LoadInto(player, data)
    drain()
    ctx.datas[id] = data
    ctx.list[#ctx.list + 1] = player
    ctx.runtime:on_player_added(player)
    ctx.runtime:on_save_ready(player, data)
    drain()
    return player, data
  end

  local function act(player, payload)
    ctx.seq = ctx.seq + 1
    payload.seq = ctx.seq
    ctx.events.GrillAction.OnServerEvent:Fire(player, payload)
    drain()
    return player.results and player.results[#player.results]
  end

  local function advance(seconds)
    ctx.now = ctx.now + seconds
    ctx.runtime.clock:advance(seconds)
    drain()
  end

  local function giveSelected(data, itemId, mult, cooked)
    assert.is_true(data:AddItem(itemId, mult, cooked))
    assert.is_true(data:SelectSlot(1))
    local owner = nil
    for _, player in ipairs(ctx.list) do
      if ctx.datas[player.UserId] == data then owner = player break end
    end
    local tree = owner and ctx.runtime:get_player_tree(owner.UserId)
    if tree then tree:sync_from_data(data) end
  end

  local function countItem(data, itemId)
    local total = 0
    for _, container in pairs(data.Data.Containers) do
      for _, entry in pairs(container) do
        if entry.itemId == itemId and entry.count > 0 then total = total + entry.count end
      end
    end
    return total
  end

  -- 10-03 / 10-15：不是鱼获、或已经烤过的鱼获都放不进去。
  it('10-03 只有未烤制的鱼获可以放入烧烤点', function()
    local player, data = join(9500)
    giveSelected(data, NOT_FISH, 1)
    local reply = act(player, { action = 'Start' })
    assert.is_false(reply.ok)
    assert.are.equal('no-fish', reply.reason)
    assert.is_nil(ctx.mgr:GetSession(player), '被拒的投入不该留下会话')
    -- 烤过一次的鱼获：倍率已冻结，不能再烤
    local other, otherData = join(9501)
    giveSelected(otherData, FISH, 1.2)
    local started = act(other, { action = 'Start' })
    assert.is_true(started.ok)
    advance(1)
    assert.is_true(act(other, { action = 'Takeout' }).ok)
    assert.is_true(act(other, { action = 'Start' }).ok == false, '烤过的鱼不能再烤')
  end)

  -- 10-06：1 秒处是上升段的中点 1.25
  it('10-06 0 到 2 秒由 1.00 线性升到 1.50', function()
    local player, data = join(9502)
    giveSelected(data, FISH, 1)
    assert.is_true(act(player, { action = 'Start' }).ok)
    advance(1)
    local reply = act(player, { action = 'Takeout' })
    assert.is_true(reply.ok)
    assert.near(1.25, reply.rate, 0.001)
  end)

  -- 10-07：2.25 秒仍在保持段顶端
  it('10-07 2 到 2.5 秒保持 1.50', function()
    local player, data = join(9503)
    giveSelected(data, FISH, 1)
    assert.is_true(act(player, { action = 'Start' }).ok)
    advance(2.25)
    local reply = act(player, { action = 'Takeout' })
    assert.near(1.5, reply.rate, 0.001)
  end)

  -- 10-08：3.5 秒在下降段中点 0.75
  it('10-08 2.5 到 4.5 秒由 1.50 线性降到 0.00', function()
    local player, data = join(9504)
    giveSelected(data, FISH, 1)
    assert.is_true(act(player, { action = 'Start' }).ok)
    advance(3.5)
    local reply = act(player, { action = 'Takeout' })
    assert.near(0.75, reply.rate, 0.001)
  end)

  -- 10-10 / 10-14：取出瞬间冻结倍率、放回格位并保持选中，之后再等也不变
  it('10-10 取出后倍率冻结且放回格位保持选中', function()
    local player, data = join(9505)
    giveSelected(data, FISH, 1)
    assert.is_true(act(player, { action = 'Start' }).ok)
    advance(1)
    local reply = act(player, { action = 'Takeout' })
    assert.near(1.25, reply.rate, 0.001)
    local entry = data.Data.Containers[GameCfg.Items.ContainerId.ItemBar][1]
    assert.are.equal(FISH, entry.itemId, '鱼获要放回可用格位')
    assert.are.equal(reply.rate, entry.cooked)
    assert.are.equal(1, data.Data.SelectedSlot, '取出后保持选中')
    advance(20)
    assert.are.equal(1.25, data.Data.Containers[GameCfg.Items.ContainerId.ItemBar][1].cooked,
      '倍率取出即冻结，之后再等也不变')
  end)

  -- 10-11 / 10-12 / 10-13：4.5 秒没取出就损毁，3 米内玩家各吃 30 点伤害，操作者收到烤糊提示
  it('10-11 4.5 秒未取出则烤糊损毁并炸伤周围玩家', function()
    local player, data = join(9506)
    join(9507)             -- 站在烤炉旁
    join(9508, false)      -- 站在 100 米外
    giveSelected(data, FISH, 1)
    assert.is_true(act(player, { action = 'Start' }).ok)
    -- 跨过 4.5 秒：服务端心跳自己结算烤糊，不需要玩家再点
    advance(4.6)
    assert.are.equal(0, countItem(data, FISH), '烤糊的鱼获要损毁')
    local after = act(player, { action = 'Takeout' })
    assert.is_false(after.ok, '烤糊后没有可取出的东西')
    assert.are.equal('no-session', after.reason)
    assert.is_nil(ctx.mgr:GetSession(player), '烤糊后会话结束')
    -- 3 米内的两名玩家各吃 30 点伤害，100 米外的没有
    local burned = {}
    for _, hit in ipairs(ctx.hits) do
      burned[hit.userId] = (burned[hit.userId] or 0) + 1
      assert.are.equal(30, hit.amount)
    end
    assert.are.equal(2, #ctx.hits, '3 米内两名玩家各结算一次')
    assert.is_nil(burned[9508], '3 米外的玩家不吃伤害')
    assert.are.equal('burnt', player.state.state, '操作者收到烤糊状态')
  end)

  -- 10-11 边界：判定点是 elapsed >= BurnSec（4.5 秒整已糊，4.5 秒前未糊，见 common/GrillCurve.lua）。
  -- 失败方式：边界写成 > 或 <，4.5 秒整不糊 / 4.5 秒前就糊。
  it('10-11 4.5 秒整已烤糊、4.5 秒前尚未烤糊', function()
    -- 4.5 秒前（BurnSec - 0.25 秒）取出仍成功，倍率尚未归零
    local beforePlayer, beforeData = join(9510)
    giveSelected(beforeData, FISH, 1)
    assert.is_true(act(beforePlayer, { action = 'Start' }).ok)
    advance(GameCfg.Grill.BurnSec - 0.25)
    local taken = act(beforePlayer, { action = 'Takeout' })
    assert.is_true(taken.ok, '4.5 秒前取出不该判烤糊')
    assert.is_true(taken.rate > 0, '4.5 秒前倍率还没降到 0')
    -- 4.5 秒整：烤糊、会话结束、状态 burnt，事后取不出东西
    local player, data = join(9511)
    giveSelected(data, FISH, 1)
    assert.is_true(act(player, { action = 'Start' }).ok)
    advance(GameCfg.Grill.BurnSec)
    assert.is_nil(ctx.mgr:GetSession(player), '4.5 秒整会话要结束')
    assert.are.equal('burnt', player.state.state, '4.5 秒整要判烤糊')
    assert.are.equal(0, countItem(data, FISH), '4.5 秒整的鱼获要损毁')
    local after = act(player, { action = 'Takeout' })
    assert.is_false(after.ok, '烤糊后没有可取出的东西')
  end)
end)
