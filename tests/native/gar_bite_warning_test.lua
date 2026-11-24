-- 迁移自 tests/gameplay/gar_bite_warning_test.lua（#85）；行为契约原文见 #134、#141。
-- 驱动真实生产模块：common/GarBiteNotice.lua（预警载荷契约）与 client/Views/FishCombatView.lua（客户端预警视图）。
-- 失败方式：
--   1. 非法预警载荷（nil、NaN 坐标、非正射程/时长、缺 id 快照）漏过或阻塞后续预警挂载；
--   2. 同一条鱼连续锁定叠出多个节点，或撤销/根销毁后预警节点残留；
--   3. 旧轮次预警撤回误关新轮次预警；
--   4. 圆形落点与暴雨预警的共享配置口径缺失或撤销后未清理。

local Eui = require('tests.support.eui_double')
local ClientStore = require('client.Store.ClientStore')
local RootView = require('client.Views.RootView')
local FishCombatView = require('client.Views.FishCombatView')
local SpokeClock = require('common.SpokeClock')
local GarBiteNotice = require('common.GarBiteNotice')
local GameCfg = require('common.GameCfg')

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

    -- 客户端 FishCombatView 收到坏快照或无 id 预警项时不建节点，也不阻塞后续合法预警挂载
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
    -- #141 圆形落点：共享配置声明官方整圆预设与 10 米基准半径，FishCombatView 挂载与撤销零残留
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

    -- 同一条鱼连续重新锁定不叠出多节点
    assert.is_true(env.writer:ingest_event('FishCombatState', {
      warnings = { { id = 5, fishId = 5, kind = 'lock', yaw = math.pi } },
    }))
    assert.same(1, #aliveWarnings())
    assert.same(first, findWarning(5))

    -- 撤销后唯一节点销毁，零残留
    assert.is_true(env.writer:ingest_event('FishCombatState', { warnings = {} }))
    assert.is_true(first.Destroyed)
    assert.same(0, #aliveWarnings())
  end)

  it('test_timeout_fallback_only_hides_its_own_round', function()
    -- 第一轮与第二轮预警使用独立轮次键：撤回旧轮次不得误关新轮次，直到新轮次撤销或根销毁才回收
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

    -- 旧轮次超时移除：只销毁 round1，round2 仍保持存活
    assert.is_true(env.writer:ingest_event('FishCombatState', {
      warnings = { { id = '5:2', fishId = 5, kind = 'lock' } },
    }))
    assert.is_true(round1.Destroyed)
    assert.is_nil(round2.Destroyed)
    assert.is_not_nil(findWarning('5:2'))

    -- 新轮次结束后彻底销毁
    assert.is_true(env.writer:ingest_event('FishCombatState', { warnings = {} }))
    assert.is_true(round2.Destroyed)
    assert.same(0, #aliveWarnings())
  end)
end)
