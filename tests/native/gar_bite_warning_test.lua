-- 迁移自 tests/gameplay/gar_bite_warning_test.lua（#85）；行为契约原文见 #134、#141。
-- 失败方式：

local Eui = require('tests.support.eui_double')
local ClientStore = require('client.Store.ClientStore')
local RootView = require('client.Views.RootView')
local FishCombatView = require('client.Views.FishCombatView')
local SpokeClock = require('common.spoke_clock')
local GarBiteNotice = require('common.gar_bite_notice')
local GameCfg = require('common.game_cfg')

describe('鳄雀鳝上钩预警表现（GarBiteWarning -> FishCombatView）', function()
  local env

  local function mountView()
    local clock = SpokeClock.new(100)
    local store, writer = ClientStore.new({ clock = clock })
    local root = Eui.Node({ Name = 'UIRoot' })
    local created = {}
    local view = RootView.mount(root, store, {
      create_node = function(kind, props)
        local node = Eui.Node(props or {})
        node.UnitType = kind
        created[#created + 1] = node
        return node
      end,
      docks = {
        fish_warning = FishCombatView.warning_spec(),
      },
    })
    return { clock = clock, store = store, writer = writer, root = root, view = view, created = created }
  end

  local function aliveWarnings()
    local out = {}
    for _, node in ipairs(env.created) do
      if not node.Destroyed and type(node.Name) == 'string' and node.Name:find('FishWarn_', 1, true) == 1 then
        out[#out + 1] = node
      end
    end
    return out
  end

  local function findWarning(id)
    local target = 'FishWarn_' .. tostring(id)
    for _, node in ipairs(env.created) do
      if not node.Destroyed and node.Name == target then return node end
    end
  end

  before_each(function()
    env = mountView()
    env.cfg = GameCfg.FishCombat.gar
  end)

  after_each(function()
    if env and env.view then env.view:dispose() end
    env = nil
  end)

  local function lockNotice(fishId, fx, fz)
    return GarBiteNotice.Lock(fishId, { x = 1, y = 2, z = 3 }, fx, fz, env.cfg.BiteRange,
      env.cfg.HeadHalfAngleDeg, env.cfg.BiteCooldownSec)
  end

  it('test_invalid_payload_ignored_and_asset_failure_does_not_block_next_round', function()
    assert.is_false(GarBiteNotice.Valid(nil))
    assert.is_false(GarBiteNotice.Valid(GarBiteNotice.Lock(5, { x = 0 / 0, y = 0, z = 0 }, 1, 0, 2.5, 90, 1.5)))
    assert.is_false(GarBiteNotice.Valid(GarBiteNotice.Lock(5, { x = 0, y = 0, z = 0 }, 1, 0, 0, 90, 1.5)))
    assert.is_false(GarBiteNotice.Valid(GarBiteNotice.Lock(5, { x = 0, y = 0, z = 0 }, 1, 0, 2.5, 90, -1)))

    assert.is_false(env.writer:ingest_event('FishCombatState', nil))
    assert.is_true(env.writer:ingest_event('FishCombatState', {
      warnings = { 'bad', { fishId = 5, kind = 'lock' } },
    }))
    assert.same(0, #aliveWarnings())

    local valid = lockNotice(5, 1, 0)
    assert.is_true(GarBiteNotice.Valid(valid))
    assert.is_true(env.writer:ingest_event('FishCombatState', {
      warnings = { { id = 5, fishId = 5, kind = valid.kind, range = valid.range } },
    }))
    assert.same(1, #aliveWarnings())
    assert.is_not_nil(findWarning(5))
  end)

  it('test_jump_circle_consumer_places_full_landing_warning_and_clears', function()
    local warnCfg = env.cfg.Warning
    assert.same('official://preset/7191', warnCfg.CirclePreset)
    assert.same(10, warnCfg.CircleRadius)
    for _, radius in ipairs({ 5, 10 }) do
      local payload = GarBiteNotice.Lock(141, { x = 15, y = 2, z = 30 }, 0, 1, radius, 180, 1.5)
      payload.move, payload.shape = 'jump', 'circle'
      assert.is_true(GarBiteNotice.Valid(payload))
      assert.same(radius == 5 and 0.5 or 1, payload.range / warnCfg.CircleRadius)

      assert.is_true(env.writer:ingest_event('FishCombatState', {
        warnings = { { id = 141, fishId = 141, move = 'jump', shape = 'circle', range = radius } },
      }))
      local node = findWarning(141)
      assert.is_not_nil(node)
      assert.is_true(node.Visible)

      assert.is_true(GarBiteNotice.Valid(GarBiteNotice.Clear(141, 'cancel')))
      assert.is_true(env.writer:ingest_event('FishCombatState', { warnings = {} }))
      assert.is_true(node.Destroyed)
      assert.is_nil(findWarning(141))
    end
  end)

  it('test_rain_effect_is_distinct_and_cleared_with_warning', function()
    assert.is_string(GameCfg.FishCombat.dragon.RainEffect)
    assert.is_not.same(env.cfg.Warning.EffectPreset, GameCfg.FishCombat.dragon.RainEffect)
    local payload = lockNotice(8, 0, 1)
    payload.move = 'rain'
    assert.is_true(GarBiteNotice.Valid(payload))

    assert.is_true(env.writer:ingest_event('FishCombatState', {
      warnings = { { id = 8, fishId = 8, move = 'rain', kind = 'lock' } },
    }))
    local node = findWarning(8)
    assert.is_not_nil(node)
    assert.is_true(env.writer:ingest_event('FishCombatState', { warnings = {} }))
    assert.is_true(node.Destroyed)
    assert.same(0, #aliveWarnings())
  end)

  it('test_relock_replaces_and_clear_hides', function()
    assert.is_true(env.writer:ingest_event('FishCombatState', {
      warnings = { { id = 5, fishId = 5, kind = 'lock', yaw = 0 } },
    }))
    assert.same(1, #aliveWarnings())
    local first = findWarning(5)

    assert.is_true(env.writer:ingest_event('FishCombatState', {
      warnings = { { id = 5, fishId = 5, kind = 'lock', yaw = math.pi } },
    }))
    assert.same(1, #aliveWarnings())
    assert.same(first, findWarning(5))

    assert.is_true(env.writer:ingest_event('FishCombatState', { warnings = {} }))
    assert.is_true(first.Destroyed)
    assert.same(0, #aliveWarnings())
  end)

  it('test_timeout_fallback_only_hides_its_own_round', function()
    assert.is_true(env.writer:ingest_event('FishCombatState', {
      warnings = { { id = '5:1', fishId = 5, kind = 'lock' } },
    }))
    local round1 = findWarning('5:1')
    assert.is_not_nil(round1)

    assert.is_true(env.writer:ingest_event('FishCombatState', {
      warnings = {
        { id = '5:1', fishId = 5, kind = 'lock' },
        { id = '5:2', fishId = 5, kind = 'lock' },
      },
    }))
    local round2 = findWarning('5:2')
    assert.is_not_nil(round2)

    assert.is_true(env.writer:ingest_event('FishCombatState', {
      warnings = { { id = '5:2', fishId = 5, kind = 'lock' } },
    }))
    assert.is_true(round1.Destroyed)
    assert.is_nil(round2.Destroyed)
    assert.is_not_nil(findWarning('5:2'))

    assert.is_true(env.writer:ingest_event('FishCombatState', { warnings = {} }))
    assert.is_true(round2.Destroyed)
    assert.same(0, #aliveWarnings())
  end)
end)
