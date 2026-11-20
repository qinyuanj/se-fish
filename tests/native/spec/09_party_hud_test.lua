-- 条款 9（docs/acceptance/09-multiplayer-rules.md）队伍界面：HUD 显示同队队友的当前血量（9-20），
-- 收到组队邀请时的提示与 10 秒倒计时（9-21）。
-- 只走业务入口：client/ScreenHandlers/ScreenParty.lua 的公开显示面（Start / NoteState / Tick / View），
-- 与 MgrGameUI 的 ScreenHandlerLoaders 登记、client/main.lua 的启动接线。EUI、RE、时钟用替身。
-- 失败方式（先列后写）：
--   1. 界面只显示队友名字、血量不跟服务端快照走，或把队友血量错算成自己的（9-20）；
--   2. 无队伍时队友栏还在，或快照结构不对时把上一份状态清掉（9-20 失败流程）；
--   3. 邀请提示不显示邀请人、倒计时不从 10 秒开始或到点不撤板（9-21）；
--   4. handler 没登记进 ScreenHandlerLoaders / 没在客户端入口启动，界面对局里根本不存在（9-20 接线）。
local function signal()
  local listeners = {}
  return {
    Connect = function(_, fn)
      listeners[#listeners + 1] = fn
      return { Disconnect = function() end }
    end,
    Fire = function(_, ...) for _, fn in ipairs(listeners) do fn(...) end end,
  }
end

describe('条款 9 队伍界面', function()
  local ctx

  before_each(function()
    ctx = { now = 1000, nodes = {}, events = {}, heartbeats = signal(), sent = {},
      saved = { game = rawget(_G, 'game'), Vector2 = rawget(_G, 'Vector2'),
        Color = rawget(_G, 'Color'), LocalMsgNotice = rawget(_G, 'LocalMsgNotice'),
        reutil = package.loaded['common.REUtil'] } }
    local env = ctx
    _G.Vector2 = { New = function(x, y) return { x = x, y = y } end }
    _G.Color = { New = function(...) return { ... } end }
    _G.LocalMsgNotice = function(message) env.notices = (env.notices or {}) ; env.notices[#env.notices + 1] = message end
    _G.game = { GetService = function(_, name)
      if name == 'World' then
        return { GetServerTime = function() return env.now end,
          CreateUnit = function(_, kind, props)
            local node = { Kind = kind, Visible = props.Visible ~= false }
            for key, value in pairs(props) do node[key] = value end
            node.Visible = props.Visible ~= false
            node.Destroy = function(me) me.Destroyed = true end
            env.nodes[node.Name] = node
            return node
          end }
      end
      if name == 'Players' then
        return { LocalPlayer = { PlayerGui = { EuiManager = {
          GetRootNode = function() return { env.root or {} } end,
          GetDeviceResolution = function() return { x = 1920, y = 1080 } end,
        } } } }
      end
      if name == 'RunService' then return { Heartbeat = env.heartbeats } end
    end }
    package.loaded['common.REUtil'] = { GetRE = function(_, name)
      env.events[name] = env.events[name] or { OnClientEvent = signal(),
        FireServer = function(_, payload) env.sent[#env.sent + 1] = { name = name, payload = payload } end }
      return env.events[name]
    end }
    ctx.panel = assert(loadfile('client/ScreenHandlers/ScreenParty.lua'))()
    ctx.panel:Start()
  end)

  after_each(function()
    if not ctx then return end
    package.loaded['common.REUtil'] = ctx.saved.reutil
    _G.game = ctx.saved.game
    _G.Vector2 = ctx.saved.Vector2
    _G.Color = ctx.saved.Color
    _G.LocalMsgNotice = ctx.saved.LocalMsgNotice
    ctx = nil
  end)

  local function push(state)
    ctx.events.PartyState.OnClientEvent:Fire(state)
  end

  -- 9-20：队友名字与当前血量跟着服务端快照走，自己不在队友栏里。
  it('9-20 队伍界面显示同队队友的当前血量', function()
    push({ state = 'party', partyId = 7, members = {
      { userId = 1, name = '甲', health = 300, maxHealth = 300, self = true },
      { userId = 2, name = '乙', health = 120, maxHealth = 300 },
      { userId = 3, name = '丙', health = 30, maxHealth = 300 },
    } })
    local view = ctx.panel:View()
    assert.same(2, #view.rows, '只列队友，自己不在队友栏')
    assert.same('乙', view.rows[1].name)
    assert.same(120, view.rows[1].health)
    assert.same('120/300', view.rows[1].healthText)
    assert.same('丙', view.rows[2].name)
    assert.same('30/300', view.rows[2].healthText)

    assert.is_true(ctx.nodes['PartyRoot'].Visible)
    assert.same('乙', ctx.nodes['PartyMember1Name'].Text)
    assert.same('120/300', ctx.nodes['PartyMember1Health'].Text)
    -- 血条按当前血量占上限的比例画：120/300 = 40%
    local expected = require('common.GameCfg').Party.HUD.BarWidth * 0.4
    assert.is_true(math.abs(ctx.nodes['PartyMember1Fill'].Size.x - expected) < 0.5)
    assert.same('30/300', ctx.nodes['PartyMember2Health'].Text)

    -- 队友血量变化后界面跟着更新；血量上限不同也按各自上限算比例。
    push({ state = 'party', partyId = 7, members = {
      { userId = 1, name = '甲', health = 300, maxHealth = 300, self = true },
      { userId = 2, name = '乙', health = 60, maxHealth = 300 },
      { userId = 3, name = '丙', health = 300, maxHealth = 300 },
    } })
    assert.same('60/300', ctx.nodes['PartyMember1Health'].Text, '队友掉血后界面跟着变')
    assert.same('300/300', ctx.nodes['PartyMember2Health'].Text)
  end)

  -- 9-20 失败流程：无队伍时收面板；结构不对的快照不得清掉上一份可信状态。
  it('9-20 无队伍时收起面板，坏快照不改上一份状态', function()
    push({ state = 'party', partyId = 7, members = {
      { userId = 1, name = '甲', health = 300, maxHealth = 300, self = true },
      { userId = 2, name = '乙', health = 200, maxHealth = 300 },
    } })
    assert.is_true(ctx.nodes['PartyRoot'].Visible)
    push({ state = 'party', members = '坏数据' })
    assert.same('200/300', ctx.nodes['PartyMember1Health'].Text, '坏快照不覆盖可信状态')
    -- 队友还没出生（服务端没有血量读数）时，名单照常在，血量显示占位而不是伪造数值。
    push({ state = 'party', partyId = 7, members = {
      { userId = 1, name = '甲', health = 300, maxHealth = 300, self = true },
      { userId = 2, name = '乙' },
    } })
    assert.same(1, #ctx.panel:View().rows, '缺血量不丢整份名单')
    assert.same('—', ctx.panel:View().rows[1].healthText)

    push({ state = 'none', members = {} })
    assert.is_false(ctx.nodes['PartyRoot'].Visible, '无队伍时收起队友栏')
    assert.same(0, #ctx.panel:View().rows)
  end)

  -- 9-21：邀请提示显示邀请人，倒计时从 10 秒开始，到点撤板。
  it('9-21 组队邀请提示与 10 秒倒计时', function()
    push({ state = 'none', members = {}, invite = { fromUserId = 2, fromName = '乙', expiresInSec = 10 } })
    assert.is_true(ctx.nodes['PartyInvite'].Visible, '收到邀请时显示提示')
    assert.is_truthy(string.find(ctx.nodes['PartyInviteText'].Text, '乙', 1, true))
    local countdown = require('common.GameCfg').Party.HUD.InviteCountdownText
    assert.same('10' .. countdown, ctx.nodes['PartyInviteCountdown'].Text, '倒计时从 10 秒开始')

    ctx.now = ctx.now + 3
    ctx.heartbeats:Fire(0.1)
    assert.same('7' .. countdown, ctx.nodes['PartyInviteCountdown'].Text, '倒计时按服务端剩余秒数走')

    ctx.now = ctx.now + 7
    ctx.heartbeats:Fire(0.1)
    assert.is_false(ctx.nodes['PartyInvite'].Visible, '10 秒到点按拒绝撤板')
    assert.is_nil(ctx.panel:View().invite)

    -- 服务端结算超时后会再推一份没有 invite 的状态，提示同样撤板。
    push({ state = 'none', members = {} })
    assert.is_false(ctx.nodes['PartyInvite'].Visible)
  end)

  -- 9-19/9-21 失败流程：服务端拒绝时的回执在界面上能看懂，不是静默失败。
  it('9-19 服务端拒绝邀请时界面给出可照做的原因', function()
    ctx.events.PartyResult.OnClientEvent:Fire({ action = 'Invite', ok = false, reason = 'too-far' })
    assert.same(require('common.GameCfg').Party.HUD.TooFarText, ctx.notices[#ctx.notices])
    ctx.events.PartyResult.OnClientEvent:Fire({ action = 'Invite', ok = false, reason = 'full' })
    assert.same(require('common.GameCfg').Party.HUD.FullText, ctx.notices[#ctx.notices])
    -- 未映射的原因给通用失败文案；成功回执不打扰玩家
    local count = #(ctx.notices or {})
    ctx.events.PartyResult.OnClientEvent:Fire({ action = 'Accept', ok = false, reason = 'weird' })
    assert.same(require('common.GameCfg').Party.HUD.UnavailableText, ctx.notices[#ctx.notices])
    ctx.events.PartyResult.OnClientEvent:Fire({ action = 'Accept', ok = true })
    assert.same(count + 1, #ctx.notices, '成功回执不弹提示')
  end)

  -- 接线：handler 按 AGENTS.md 登记进 ScreenHandlerLoaders，并由客户端入口启动。
  it('9-20 队伍界面登记进界面管理器并在客户端入口启动', function()
    local handle = assert(io.open('client/MgrGameUI.lua', 'rb'))
    local registry = handle:read('a')
    handle:close()
    assert.is_truthy(registry:find('ScreenParty = function() return require("client.ScreenHandlers.ScreenParty") end', 1, true),
      'ScreenParty 必须登记在 MgrGameUI 的 ScreenHandlerLoaders')

    local entry = assert(io.open('client/main.lua', 'rb'))
    local source = entry:read('a')
    entry:close()
    assert.is_truthy(source:find('ScreenParty = require("client.ScreenHandlers.ScreenParty")', 1, true),
      'client/main.lua 要按名字取到 handle')
    assert.is_truthy(source:find('ScreenParty:Start()', 1, true), 'client/main.lua 要启动队伍界面')
  end)
end)
