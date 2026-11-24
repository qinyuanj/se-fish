
local Eui = require('tests.support.eui_double')

local function vec(x, y, z) return { x = x, y = y, z = z } end

describe('客户端摆渡统一视图树（RootView × ClientStore）', function()
  local env
  local restore

  local function child(name)
    return env.root:FindFirstChild(name, true)
  end

  local function state(payload)
    assert.is_true(env.writer:ingest_event('FerryState', payload))
  end

  local function result(payload)
    assert.is_true(env.writer:ingest_event('FerryResult', payload))
  end

  local function stand(point, dx, dz)
    local position = env.anchor_positions[point.AnchorName]
    assert.is_not_nil(position)
    env.writer:update_spatial(vec(position.x + (dx or 0), position.y, position.z + (dz or 0)))
  end

  before_each(function()
    restore = { Vector2 = rawget(_G, 'Vector2'), Vector3 = rawget(_G, 'Vector3'),
      Color = rawget(_G, 'Color'), modules = {} }
    for _, name in ipairs({ 'common.game_cfg', 'client.Store.ClientStore', 'client.Views.FerryView' }) do
      restore.modules[name] = package.loaded[name]
      package.loaded[name] = nil
    end
    _G.Vector2 = { New = function(x, y) return { x = x, y = y } end }
    _G.Vector3 = { New = vec }
    _G.Color = { New = function(...) return { ... } end }
    env = { sent = {}, notices = {}, created = {} }
    env.cfg = require('tests.support.zone_fixtures').Load()
    env.routes = env.cfg.Ferry.Routes
    env.route = env.routes[1]
    env.anchor_positions = {}
    for _, zone in ipairs(env.cfg.Zones) do
      for _, entity in ipairs(zone.Scene.Entities) do
        if entity.Role == 'Ferry' then env.anchor_positions[entity.Name] = entity.Position end
      end
    end
    local ClientStore = require('client.Store.ClientStore')
    local RootView = require('client.Views.RootView')
    local FerryView = require('client.Views.FerryView')
    env.store, env.writer = ClientStore.new({ initial_now = 100 })
    env.root = Eui.Node({ Name = 'UIRoot' })
    env.view = RootView.mount(env.root, env.store, {
      hud = { FerryView.spec() },
      docks = { ferry = FerryView.legs_spec() },
      services = {
        send_ferry = function(payload) env.sent[#env.sent + 1] = payload end,
        notify = function(text) env.notices[#env.notices + 1] = text end,
        create_scene_node = function(position, name)
          local node = Eui.Node({ Name = name, Kind = 'EUISceneNode', Parent = env.root,
            Position = position, Visible = true })
          env.created[#env.created + 1] = node
          return node
        end,
      },
      create_node = function(kind, props)
        local node = Eui.Node({ Kind = kind, Name = props and props.Name,
          Parent = props and props.Parent, Visible = props and props.Visible ~= false,
          Text = props and (props.Text or props.ButtonText) or '',
          ButtonText = props and props.ButtonText,
          Position = props and props.Position, Size = props and props.Size,
          TouchEnabled = kind == 'EUIButton' })
        env.created[#env.created + 1] = node
        return node
      end,
    })
  end)

  after_each(function()
    if env and env.view and not env.root.Destroyed then env.view:dispose() end
    for name, value in pairs(restore.modules) do package.loaded[name] = value end
    _G.Vector2, _G.Vector3, _G.Color = restore.Vector2, restore.Vector3, restore.Color
    env = nil
    restore = nil
  end)

  it('test_each_leg_sends_its_own_route_id', function()
    local seq = 0
    for _, route in ipairs(env.routes) do
      for _, leg in ipairs({ { point = route.Outbound, action = 'Board', text = '乘船' },
          { point = route.Return, action = 'Return', text = '返程' } }) do
        stand(leg.point)
        local button = child('BtnFerry' .. leg.point.AnchorName)
        assert.is_not_nil(button)
        assert.same(leg.text, button.Text)
        assert.is_true(Eui.Click(button))
        seq = seq + 1
        assert.same({ action = leg.action, routeId = route.Id, seq = seq }, env.sent[#env.sent])
      end
    end
    assert.same(12, #env.sent)
  end)

  it('test_leg_bubble_shows_only_within_its_radius', function()
    local point = env.route.Outbound
    stand(point, point.Radius + 0.25, 0)
    assert.is_nil(child('BtnFerry' .. point.AnchorName))
    stand(point)
    assert.is_not_nil(child('BtnFerry' .. point.AnchorName))
    stand(point, point.Radius + 0.25, 0)
    assert.is_nil(child('BtnFerry' .. point.AnchorName))
  end)

  it('test_countdown_is_per_route_and_label_follows_the_soonest', function()
    local routeA, routeB = env.routes[1], env.routes[2]
    state({ phase = 'countdown', routeId = routeA.Id, seconds = 5 })
    state({ phase = 'countdown', routeId = routeB.Id, seconds = 8 })
    env.writer:advance_clock(4)
    assert.same('前往虾池 1 秒', child('FerryCountdown').Text)
    env.writer:advance_clock(1)
    assert.same('前往蟹湖 3 秒', child('FerryCountdown').Text)
    env.writer:advance_clock(3)
    assert.is_nil(child('FerryCountdown'))
    state({ phase = 'countdown', seconds = 5 })
    assert.is_nil(child('FerryCountdown'))
  end)

  it('test_stale_terminal_does_not_clear_or_announce_a_new_operation', function()
    state({ phase = 'countdown', routeId = env.route.Id, operation = '1:1', seconds = 5 })
    state({ phase = 'countdown', routeId = env.route.Id, operation = '2:4', seconds = 8 })
    state({ phase = 'cancelled', routeId = env.route.Id, operation = '1:1', reason = 'payer_left' })
    env.writer:advance_clock(1)
    assert.same('前往虾池 7 秒', child('FerryCountdown').Text)
    assert.same({}, env.notices)
  end)

  it('test_shared_terminal_only_clears_matching_countdown_without_notice', function()
    state({ phase = 'countdown', routeId = env.route.Id, operation = '1:1', seconds = 5 })
    state({ phase = 'countdown', routeId = env.route.Id, operation = '2:4', seconds = 8 })
    state({ phase = 'departed', routeId = env.route.Id, operation = '1:1' })
    state({ phase = 'cancelled', routeId = env.route.Id, operation = '1:1', reason = 'empty' })
    env.writer:advance_clock(1)
    assert.same('前往虾池 7 秒', child('FerryCountdown').Text)
    state({ phase = 'departed', routeId = env.route.Id, operation = '2:4' })
    assert.is_nil(child('FerryCountdown'))
    state({ phase = 'countdown', routeId = env.route.Id, operation = '3:1', seconds = 4 })
    state({ phase = 'cancelled', routeId = env.route.Id, operation = '3:1', reason = 'anchor' })
    assert.is_nil(child('FerryCountdown'))
    assert.same({}, env.notices)
  end)

  it('test_personal_results_name_arrival_and_refund_without_claiming_shared_refund', function()
    result({ ok = true, action = 'Board', routeId = env.route.Id, operation = { id = '1:1' } })
    result({ ok = false, action = 'Board', routeId = env.route.Id, reason = 'not_aboard' })
    result({ ok = false, action = 'Board', routeId = env.route.Id, reason = 'anchor' })
    result({ ok = false, action = 'Board', routeId = env.route.Id, reason = 'interrupted' })
    result({ ok = false, action = 'Board', routeId = env.route.Id, reason = 'teleport' })
    result({ ok = false, action = 'Return', routeId = env.route.Id, reason = 'teleport' })
    assert.same({ '已经到虾池了', '没赶上船，船票已退', '航班取消，船票已退',
      '上次航班已取消，船票已退', '传送失败，船票已退', '传送失败，金币已退' }, env.notices)
  end)

  it('test_notices_name_the_route_and_its_destination', function()
    state({ phase = 'countdown', routeId = env.route.Id, seconds = 5 })
    state({ phase = 'departed', routeId = env.route.Id })
    state({ phase = 'cancelled', routeId = env.routes[2].Id })
    assert.same({}, env.notices)
    result({ ok = true, action = 'Board', routeId = env.route.Id, seconds = 5 })
    result({ ok = true, action = 'Return', routeId = env.route.Id, price = 10 })
    result({ ok = false, action = 'Board', routeId = 'fishPond>volcanoIsland', reason = 'route' })
    result({ ok = false, action = 'Return', routeId = env.route.Id, reason = 'coin' })
    assert.same({ '船票已交，5 秒后开船', '已经回到鱼塘，金币 -10',
      '找不到这条航线，请重进本图', '金币不够，船家不开船' }, env.notices)
  end)

  it('test_countdown_label_is_created_on_demand_and_destroyed_when_it_ends', function()
    assert.is_nil(child('FerryCountdown'))
    state({ phase = 'countdown', routeId = env.route.Id, seconds = 5 })
    local label = child('FerryCountdown')
    assert.is_not_nil(label)
    assert.is_true(label.Visible)
    env.writer:advance_clock(5)
    assert.is_true(label.Destroyed)
    assert.is_nil(child('FerryCountdown'))
  end)

  it('test_root_destroy_reclaims_legs_countdown_and_event_listeners', function()
    stand(env.route.Outbound)
    state({ phase = 'countdown', routeId = env.route.Id, seconds = 5 })
    local button = child('BtnFerry' .. env.route.Outbound.AnchorName)
    local label = child('FerryCountdown')
    env.root:Destroy()
    assert.is_true(button.Destroyed)
    assert.is_true(label.Destroyed)
    local sent, notices = #env.sent, #env.notices
    env.writer:ingest_event('FerryResult', { ok = true, action = 'Board', routeId = env.route.Id })
    assert.same(sent, #env.sent)
    assert.same(notices, #env.notices)
  end)
end)
