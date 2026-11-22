-- 条款 9（docs/acceptance/09-multiplayer-rules.md）队伍界面：HUD 显示同队队友的当前血量（9-20），
-- 收到组队邀请时的提示与 10 秒倒计时（9-21）。
-- 只走业务入口：client/ScreenHandlers/ScreenParty.lua 的公开显示面（Start / NoteState / Tick / View），
-- 与 MgrGameUI 的 ScreenHandlerLoaders 登记、client/main.lua 的启动接线。EUI、RE、时钟用替身。
-- 失败方式（先列后写）：
--   1. 界面只显示队友名字、血量不跟服务端快照走，或把队友血量错算成自己的（9-20）；
--   2. 无队伍时队友栏还在，或快照结构不对时把上一份状态清掉（9-20 失败流程）；
--   3. 邀请提示不显示邀请人、倒计时不从 10 秒开始或到点不撤板（9-21）；
--   4. handler 没登记进 ScreenHandlerLoaders / 没在客户端入口启动，界面对局里根本不存在（9-20 接线）；
--   5. 血条与按钮绕过 GameCfg.Party.HUD 内嵌正式资产 ID，配置换图后界面仍用旧资源（ADR-0029）。
local function signal()
  local listeners = {}
  return {
    Connect = function(_, fn)
      listeners[#listeners + 1] = fn
      local connected = true
      return { Disconnect = function()
        if not connected then return end
        connected = false
        for index, listener in ipairs(listeners) do
          if listener == fn then table.remove(listeners, index) ; break end
        end
      end }
    end,
    Count = function() return #listeners end,
    Fire = function(_, ...) for _, fn in ipairs(listeners) do fn(...) end end,
  }
end

describe('条款 9 队伍界面', function()
  local ctx

  before_each(function()
    -- 分辨率故意不与兜底值相同：布局真的按 GetDeviceResolution 算，丢掉分辨率这条断言会红。
    ctx = { now = 1000, nodes = {}, events = {}, heartbeats = signal(), sent = {},
      resolution = { x = 1280, y = 720 },
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
            env.created = (env.created or 0) + 1
            local createdNow = env.created
            local node = { Kind = kind, Visible = props.Visible ~= false }
            for key, value in pairs(props) do node[key] = value end
            node.Visible = props.Visible ~= false
            node.Destroy = function(me) rawset(me, 'Destroyed', true) end
            if kind == 'EUIButton' then node.OnClicked = signal() end
            env.nodes[node.Name] = node
            if env.failAfter and createdNow > env.failAfter then
              setmetatable(node, { __newindex = function(self, key, value)
                if not rawget(self, '_writeFailed') then
                  rawset(self, '_writeFailed', true)
                  error('建点失败')
                end
                rawset(self, key, value)
              end })
            end
            return node
          end }
      end
      if name == 'Players' then
        return { LocalPlayer = { PlayerGui = { EuiManager = {
          -- 生产按接口取根节点本体与分辨率（不再从根节点下标里猜），夹具同形
          GetRootNode = function() if env.missingRoot then return nil end ; return env.root or {} end,
          GetDeviceResolution = function() return env.resolution or { x = 1920, y = 1080 } end,
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
    -- 布局按 GetDeviceResolution 的分辨率算：分辨率被丢掉（旧写法从根节点下标里取）时这里会退回 1920 宽
    local hud = require('common.GameCfg').Party.HUD
    assert.same(1280 - hud.RowWidth - hud.MarginRight, ctx.nodes['PartyRoot'].Position.x,
      '队友栏贴右边缘的位置必须按设备分辨率算')
    assert.same(hud.MarginTop, ctx.nodes['PartyRoot'].Position.y)
    assert.same((1280 - hud.InviteWidth) / 2, ctx.nodes['PartyInvite'].Position.x,
      '邀请面板水平居中必须按设备分辨率算')
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
    -- 到期但还没清扫的邀请：拒绝原因是 expired，文案与「邀请已失效」一致。
    ctx.events.PartyResult.OnClientEvent:Fire({ action = 'Accept', ok = false, reason = 'expired' })
    assert.same(require('common.GameCfg').Party.HUD.NoInviteText, ctx.notices[#ctx.notices])
    -- 未映射的原因给通用失败文案；成功回执不打扰玩家
    local count = #(ctx.notices or {})
    ctx.events.PartyResult.OnClientEvent:Fire({ action = 'Accept', ok = false, reason = 'weird' })
    assert.same(require('common.GameCfg').Party.HUD.UnavailableText, ctx.notices[#ctx.notices])
    ctx.events.PartyResult.OnClientEvent:Fire({ action = 'Accept', ok = true })
    assert.same(count + 1, #ctx.notices, '成功回执不弹提示')
  end)

  -- 9-22：原队伍满员的恢复回执与「原队已散」文案不同（review #249-9）。
  it('9-22 原队伍满员与队伍已散的通知文案不同', function()
    local hud = require('common.GameCfg').Party.HUD
    push({ state = 'none', members = {}, notice = 'full' })
    assert.same(hud.RestoreFullText, ctx.notices[#ctx.notices])
    push({ state = 'none', members = {}, notice = 'disbanded' })
    assert.same(hud.DisbandText, ctx.notices[#ctx.notices])
    assert.is_true(hud.RestoreFullText ~= hud.DisbandText)
  end)

  it('9-20 Clear 清空客户端显示缓存但不影响服务端队伍', function()
    push({ state = 'party', partyId = 7, members = {
      { userId = 1, name = '甲', health = 300, maxHealth = 300, self = true },
      { userId = 2, name = '乙', health = 120, maxHealth = 300 },
    }, invite = { fromUserId = 3, fromName = '丙', expiresInSec = 8 }, notice = 'joined' })
    ctx.panel:Clear()
    assert.same({ state = 'none', partyId = nil, rows = {}, invite = nil,
      inviteVisible = false, countdownText = nil }, ctx.panel:View())
    for _, sent in ipairs(ctx.sent) do
      assert.is_not.equal('Leave', sent.payload, '清空客户端显示缓存不得向服务端发离队请求')
    end
  end)

  it('9-20 Clear 完整停止旧事件且可重复调用', function()
    ctx.panel:Clear()
    ctx.panel:Clear()
    assert.same(0, ctx.events.PartyState.OnClientEvent:Count())
    assert.same(0, ctx.events.PartyResult.OnClientEvent:Count())
    assert.same(0, ctx.heartbeats:Count())

    local before = ctx.panel:View()
    ctx.notices = {}
    ctx.events.PartyResult.OnClientEvent:Fire({ action = 'Invite', ok = false, reason = 'full' })
    push({ state = 'party', partyId = 99, members = {
      { userId = 1, name = '旧事件', health = 1, maxHealth = 1 },
    }, notice = 'disbanded' })
    ctx.heartbeats:Fire(0.1)
    assert.same(before, ctx.panel:View(), '停止后的旧事件不得改写显示快照')
    assert.same(0, #ctx.notices, '停止后的旧事件不得再通知')
  end)

  it('9-20 Start 重入和 EUI 失败重试保持单代监听与通知', function()
    ctx.panel:Start()
    assert.same(1, ctx.events.PartyState.OnClientEvent:Count())
    assert.same(1, ctx.events.PartyResult.OnClientEvent:Count())
    assert.same(1, ctx.heartbeats:Count())

    local before = ctx.panel:View()
    ctx.root = nil
    ctx.panel:Start()
    assert.same(before, ctx.panel:View(), 'EUI 暂缺不得清掉最后可用一代的显示状态')
    ctx.notices = {}
    ctx.events.PartyResult.OnClientEvent:Fire({ action = 'Invite', ok = false, reason = 'full' })
    assert.same(1, #ctx.notices, 'EUI 早退后旧代仍只通知一次')

    ctx.root = {}
    ctx.panel:Start()
    assert.same(1, ctx.events.PartyState.OnClientEvent:Count())
    assert.same(1, ctx.events.PartyResult.OnClientEvent:Count())
    assert.same(1, ctx.heartbeats:Count())
    ctx.notices = {}
    push({ state = 'none', members = {}, notice = 'disbanded' })
    assert.same(1, #ctx.notices, '重试成功后每次非空快照通知只投递一次')
  end)

  it('9-20 首次启动失败回到完全停止状态', function()
    local isolated = { events = {}, heartbeats = signal() }
    local saved = package.loaded['common.REUtil']
    package.loaded['common.REUtil'] = { GetRE = function(_, name)
      isolated.events[name] = isolated.events[name] or { OnClientEvent = signal(), FireServer = function() end }
      return isolated.events[name]
    end }
    local fresh = assert(loadfile('client/ScreenHandlers/ScreenParty.lua'))()
    package.loaded['common.REUtil'] = saved
    local savedGame = _G.game
    _G.game = setmetatable({ GetService = function(_, name)
      if name == 'RunService' then return { Heartbeat = isolated.heartbeats } end
      return savedGame:GetService(name)
    end }, { __index = savedGame })
    ctx.missingRoot = true
    fresh:Start()
    local party = isolated.events.PartyState and isolated.events.PartyState.OnClientEvent:Count() or 0
    local result = isolated.events.PartyResult and isolated.events.PartyResult.OnClientEvent:Count() or 0
    assert.same(0, party)
    assert.same(0, result)
    assert.same(0, isolated.heartbeats:Count())
    assert.same({ state = 'none', partyId = nil, rows = {}, invite = nil,
      inviteVisible = false, countdownText = nil }, fresh:View())
    ctx.missingRoot = nil

    local previous = {}
    for _, node in pairs(ctx.nodes) do previous[node] = true end
    ctx.root = {}
    ctx.failAfter = ctx.created + 2
    fresh:Start()
    local live = 0
    for _, node in pairs(ctx.nodes) do
      if not previous[node] and not node.Destroyed then live = live + 1 end
    end
    assert.same(0, live, '首次建点失败不得留下节点')
    local party = isolated.events.PartyState and isolated.events.PartyState.OnClientEvent:Count() or 0
    local result = isolated.events.PartyResult and isolated.events.PartyResult.OnClientEvent:Count() or 0
    assert.same(0, party)
    assert.same(0, result)
    assert.same(0, isolated.heartbeats:Count())
    _G.game = savedGame
  end)

  it('9-20 Clear 销毁当前显示节点', function()
    ctx.panel:Start()
    local names = { 'PartyRoot', 'PartyMember1', 'PartyMember1Name', 'PartyMember1Bar',
      'PartyMember1Fill', 'PartyMember1Health', 'PartyMember2', 'PartyMember2Name',
      'PartyMember2Bar', 'PartyMember2Fill', 'PartyMember2Health', 'PartyInvite',
      'PartyInviteText', 'PartyInviteCountdown', 'PartyInviteAccept', 'PartyInviteDecline' }
    local nodes = {}
    for _, name in ipairs(names) do nodes[name] = ctx.nodes[name] end
    ctx.panel:Clear()
    ctx.panel:Clear()
    for _, name in ipairs(names) do
      assert.is_true(nodes[name].Destroyed, 'Clear 必须销毁 ' .. name)
    end
  end)

  it('9-20 重建失败的新按钮不得发送旧代操作', function()
    local before = ctx.panel:View()
    local sent = #ctx.sent
    ctx.failAfter = ctx.created + 15
    ctx.panel:Start()
    local accept = ctx.nodes['PartyInviteAccept']
    local decline = ctx.nodes['PartyInviteDecline']
    assert.is_true(accept.Destroyed and decline.Destroyed, '失败新建的按钮必须回滚')
    accept.OnClicked:Fire()
    decline.OnClicked:Fire()
    assert.same(sent, #ctx.sent, '失败新建按钮不得发送接受或拒绝')
    assert.same(before, ctx.panel:View(), '失败新建按钮不得改写旧代显示')
  end)

  it('9-20 成功换代后只有当前按钮发送一次', function()
    local oldAccept = ctx.nodes['PartyInviteAccept']
    local oldDecline = ctx.nodes['PartyInviteDecline']
    ctx.panel:Start()
    local accept = ctx.nodes['PartyInviteAccept']
    local decline = ctx.nodes['PartyInviteDecline']
    assert.is_true(oldAccept.Destroyed and oldDecline.Destroyed, '旧按钮必须随旧代销毁')
    ctx.sent = {}
    oldAccept.OnClicked:Fire()
    oldDecline.OnClicked:Fire()
    assert.same(0, #ctx.sent, '旧按钮点击不得再发送')
    accept.OnClicked:Fire()
    decline.OnClicked:Fire()
    assert.same({
      { name = 'PartyAction', payload = { action = 'Accept' } },
      { name = 'PartyAction', payload = { action = 'Decline' } },
    }, ctx.sent)
    ctx.panel:Clear()
    accept.OnClicked:Fire()
    decline.OnClicked:Fire()
    assert.same(2, #ctx.sent, 'Clear 后当前按钮也不得再发送')
  end)

  it('9-20 重入建点失败保留最后可用一代并回滚新建节点', function()
    local previous = {}
    for _, node in pairs(ctx.nodes) do previous[node] = true end
    local oldRoot = ctx.nodes['PartyRoot']
    local before = ctx.panel:View()
    ctx.failAfter = ctx.created + 2
    ctx.panel:Start()
    assert.is_nil(oldRoot.Destroyed, '旧代节点必须继续可用')
    assert.same(before, ctx.panel:View(), '失败重建不得改写最后可用一代的显示状态')
    local rolled = 0
    for _, node in pairs(ctx.nodes) do
      if not previous[node] then
        assert.is_true(node.Destroyed, '新建到一半的节点必须回滚')
        rolled = rolled + 1
      end
    end
    assert.same(3, rolled, '已交给候选代的节点都要回滚')
    assert.same(1, ctx.events.PartyState.OnClientEvent:Count())
    assert.same(1, ctx.events.PartyResult.OnClientEvent:Count())
    assert.same(1, ctx.heartbeats:Count())
    ctx.notices = {}
    ctx.events.PartyResult.OnClientEvent:Fire({ action = 'Invite', ok = false, reason = 'offline' })
    assert.same(1, #ctx.notices, '回滚后旧代仍按每次投递通知一次')
  end)

  -- ADR-0029：正式资产由共享配置持有；换成测试 URI 后，重建的血条与按钮必须一起换。
  it('9-20 队伍血条与按钮资产统一读取 GameCfg', function()
    local hud = require('common.GameCfg').Party.HUD
    local original = hud.ColorBlockImage
    hud.ColorBlockImage = 'test://party-color-block'
    ctx.panel:Start()
    local fillImage = ctx.nodes['PartyMember1Fill'].Image
    local acceptImage = ctx.nodes['PartyInviteAccept'].NormalImage
    hud.ColorBlockImage = original
    assert.same('test://party-color-block', fillImage)
    assert.same('test://party-color-block', acceptImage)
  end)

end)
