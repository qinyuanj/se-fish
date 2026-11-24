-- 迁移自 tests/gameplay/rod_visual_test.lua（#85）。
-- it 名字沿用旧方法名，注册顺序 = LuaUnit sortedPairs 的实际执行顺序。

local GameCfg = require('common.game_cfg')
local Mgr = require('server.player_data_host')
local ServerRuntime = require('server.world_host.server_runtime')

local function signal()
  local callbacks = {}
  return {
    Connect = function(_, fn)
      callbacks[#callbacks + 1] = fn
      return { Disconnect = function() for i, cb in ipairs(callbacks) do
        if cb == fn then callbacks[i] = nil end
      end end }
    end,
    Fire = function(_, ...) for _, cb in ipairs(callbacks) do cb(...) end end,
  }
end

describe('鱼竿外观挂载（PlayerDataHost）', function()
  local env
  local restore

  before_each(function()
    -- #49：进图白送只在调试开关下发放，这些用例沿用它的起始库存（鱼竿在第 1 格、蚯蚓若干）
    -- 快照先于任何改动，夹具中途失败时 after_each 仍能还原。
    restore = {
      GrantDebug = require('common.game_cfg').Debug,
      game = _G.game,
      Vector3 = _G.Vector3,
      Color = _G.Color,
      REUtil = _G.REUtil,
    }
    env = { failKind = nil, created = {}, events = {} }
    require('common.game_cfg').Debug = { Enabled = true, InitialGrants = restore.GrantDebug.InitialGrants }
    local world = { CreateUnit = function(_, kind, props)
      if env.failKind == kind then return nil end
      local unit = { Kind = kind, Destroyed = false }
      for key, value in pairs(props) do unit[key] = value end
      function unit:Destroy() self.Destroyed = true end
      env.created[#env.created + 1] = unit
      return unit
    end }
    _G.game = { GetService = function(_, name) if name == 'World' then return world end end }
    _G.Vector3 = { New = function(x, y, z) return { x = x, y = y, z = z } end }
    -- 鱼竿模型带 ModelColor1，服务端要 Color.New；原生逐例隔离后不能再蹭别的套件的残留全局。
    _G.Color = { New = function(...) return { ... } end }
    _G.REUtil = { check_recd = function() return false end, get_re = function(_, name)
      if not env.events[name] then
        env.events[name] = {
          OnServerEvent = signal(),
          FireClient = function(_, player, state) player.lastState = state end,
        }
      end
      return env.events[name]
    end }
    env.player = { UserId = 34001, Character = { Name = 'Eggy' },
      CharacterAdded = signal(), CharacterRemoving = signal() }
    function env.player:SetAttribute() end
    env.runtime = ServerRuntime.new({
      player_data = Mgr,
      bait_spots = { Enabled = false },
      create_unit = function(kind, props)
        return world:CreateUnit(kind, props)
      end,
      on_item_bar_state = function(p, snapshot)
        _G.REUtil:get_re('ItemBarState'):FireClient(p, snapshot)
      end,
    })
    env.runtime:start()
    env.runtime:mark_started()
    env.join = function(p)
      env.runtime:on_player_added(p)
      local data = Mgr:get_data_inst(p)
      if data then env.runtime:on_save_ready(p, data) end
    end
    env.leave = function(p)
      env.runtime:on_player_removing(p)
    end
    env.join(env.player)
  end)

  after_each(function()
    -- 顺序与旧 tear_down 一致：先还原 Debug 开关，再送走玩家，最后还原全局。
    if restore then
      require('common.game_cfg').Debug = restore.GrantDebug
    end
    if env and env.runtime then
      env.runtime:shutdown()
    end
    if env and env.player then
      Mgr:on_player_removing(env.player)
    end
      if restore then
      _G.game = restore.game
      _G.Vector3 = restore.Vector3
      _G.Color = restore.Color
      _G.REUtil = restore.REUtil
    end
    env = nil
    restore = nil
  end)

  local function select(index)
    env.events.ItemBarAction.OnServerEvent:Fire(env.player, { action = 'SelectSlot', value = index })
  end

  it('test_disconnect_and_partial_spawn_failure_cleanup', function()
    select(1)
    local mount, model = env.created[1], env.created[2]
    env.leave(env.player)
    assert.is_true(mount.Destroyed)
    assert.is_true(model.Destroyed)
    env.player.CharacterAdded:Fire({ Name = 'late' })
    assert.same(2, #env.created)
    env.join(env.player)
    env.failKind = 'WorldUnit'
    select(1)
    assert.is_true(env.created[3].Destroyed)
    assert.same(3, #env.created)
    env.failKind = nil
    Mgr:send_item_bar(env.player)
    Mgr:sync_player_tree(env.player)
    assert.same(5, #env.created)
    assert.is_false(env.created[4].Destroyed)
    assert.is_false(env.created[5].Destroyed)
  end)

  it('test_empty_slot_discard_and_external_depletion_cleanup', function()
    select(1)
    local mount, model = env.created[1], env.created[2]
    select(2)
    assert.is_true(mount.Destroyed)
    assert.is_true(model.Destroyed)
    select(1)
    env.events.ItemBarAction.OnServerEvent:Fire(env.player, { action = 'DiscardSlot', value = 1 })
    assert.is_true(env.created[3].Destroyed)
    assert.is_true(env.created[4].Destroyed)
    assert.is_nil(env.player.lastState.selectedSlot)
  end)

  it('test_external_depletion_and_respawn_cleanup', function()
    select(1)
    local firstMount = env.created[1]
    local oldCharacter = env.player.Character
    env.player.CharacterRemoving:Fire(oldCharacter)
    assert.is_true(firstMount.Destroyed)
    env.player.Character = { Name = 'Respawn' }
    env.player.CharacterAdded:Fire(env.player.Character)
    assert.same(4, #env.created)
    assert.are.equal(env.player.Character, env.created[3].Parent)
    Mgr:get_data_inst(env.player):UpdateData(function(data)
      data.containers[GameCfg.Items.ContainerId.ItemBar][1].count = 0
    end, true)
    Mgr:sync_player_tree(env.player)
    assert.is_true(env.created[3].Destroyed)
    assert.is_true(env.created[4].Destroyed)
    assert.is_nil(env.player.lastState.selectedSlot)
  end)

  it('test_players_hold_independent_rods', function()
    local other = { UserId = 34002, Character = { Name = 'Other' },
      CharacterAdded = signal(), CharacterRemoving = signal() }
    function other:SetAttribute() end
    env.join(other)
    select(1)
    env.events.ItemBarAction.OnServerEvent:Fire(other, { action = 'SelectSlot', value = 1 })
    assert.same(4, #env.created)
    assert.are.equal(env.player.Character, env.created[1].Parent)
    assert.are.equal(other.Character, env.created[3].Parent)
    select(1)
    assert.is_true(env.created[1].Destroyed)
    assert.is_false(env.created[3].Destroyed)
    env.leave(other)
    assert.is_true(env.created[3].Destroyed)
  end)

  it('test_selected_before_character_spawns_on_character_added', function()
    env.player.Character = nil
    select(1)
    assert.same(0, #env.created)
    assert.same(1, env.player.lastState.selectedSlot)
    env.player.Character = { Name = 'Late' }
    env.player.CharacterAdded:Fire(env.player.Character)
    assert.same(2, #env.created)
    assert.are.equal(env.player.Character, env.created[1].Parent)
  end)

  it('test_selection_spawns_server_mount_and_idempotent_refresh', function()
    select(1)
    assert.same(2, #env.created)
    local mount, model = env.created[1], env.created[2]
    assert.same('SkeletalSocketMount', mount.Kind)
    assert.are.equal(env.player.Character, mount.Parent)
    assert.same('l_weapon', mount.SocketName)
    assert.same('WorldUnit', model.Kind)
    assert.are.equal(mount, model.Parent)
    assert.same('official://mesh/50450', model.RenderMeshId)
    assert.same({ x = 0.2, y = 0.25, z = 0.2 }, model.Scale)
    assert.is_false(model.PhysicsActive)
    assert.is_false(model.CanCollide)
    Mgr:send_item_bar(env.player)
    Mgr:sync_player_tree(env.player)
    assert.same(2, #env.created)
    select(1)
    assert.is_true(mount.Destroyed)
    assert.is_true(model.Destroyed)
  end)
end)
