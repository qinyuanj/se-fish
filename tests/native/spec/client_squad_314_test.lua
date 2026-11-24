
local game_cfg = require("common.game_cfg")
local client_store = require("client.store.client_store")
local root_view = require("client.views.root_view")
local squad_view = require("client.views.squad_view")
local eui = require("tests.support.eui_double")

local function child(root, name) return root:FindFirstChild(name, true) end

local function snapshot(members, fields)
  local value = { state = "party", partyId = 7, members = members or {} }
  for key, item in pairs(fields or {}) do value[key] = item end
  return value
end

local function member(id, name, health, max_health, phase, self)
  return { userId = id, name = name, health = health, maxHealth = max_health,
    phase = phase or "alive", self = self == true }
end

local function mount(options)
  options = options or {}
  local store, writer = client_store.new({ initial_now = 100 })
  local root = eui.Node({ Name = "UIRoot" })
  local me = options.me or { UserId = 1 }
  local players = options.players or { me }
  local rescue = squad_view.rescue_state({
    get_players = function() return players end,
    get_local_player = function() return me end,
  })
  local view = root_view.mount(root, store, {
    hud = { squad_view.hud_spec(), squad_view.rescue_driver_spec(rescue) },
    docks = {
      squad_members = squad_view.member_spec(),
      squad_rescue = squad_view.rescue_bubble_spec(rescue),
    },
    services = {
      send_party = options.send_party,
      send_interact = options.send_interact,
      next_seq = options.next_seq,
      notify = options.notify,
      get_device_resolution = options.get_device_resolution,
    },
    create_node = function(kind, props)
      local node = eui.Node({
        Kind = kind, Name = props and props.Name, Parent = props and props.Parent,
        Visible = props and props.Visible ~= false,
        Text = props and (props.Text or props.ButtonText) or "",
        TouchEnabled = kind == "EUIButton", Size = props and props.Size,
        Position = props and props.Position, Anchor = props and props.Anchor,
      })
      for key, value in pairs(props or {}) do node[key] = value end
      return node
    end,
  })
  return { store = store, writer = writer, root = root, view = view, me = me,
    players = players, rescue = rescue }
end

describe("客户端小队 HUD 与队友抢救气泡（#314）", function()
  local old_vector
  before_each(function()
    old_vector = rawget(_G, "Vector2")
    _G.Vector2 = { New = function(x, y) return { x = x, y = y } end }
  end)
  after_each(function() _G.Vector2 = old_vector end)

  it("9-20 动态投影队友血量行，坏快照不覆盖，退队后零残留", function()
    local ctx = mount()
    local ok = ctx.writer:ingest_event("PartyState", snapshot({
      member(1, "自己", 300, 300, "alive", true),
      member(2, "甲", 50, 100, "alive"),
      member(3, "乙", 0, 100, "dead"),
    }))
    assert.is_true(ok)
    assert.is_true(child(ctx.root, "PartyHud").Visible)
    assert.is_nil(child(ctx.root, "PartyMember1"))
    assert.equals("甲", child(ctx.root, "PartyMemberName2").Text)
    assert.equals("50 / 100", child(ctx.root, "PartyHealthText2").Text)
    assert.equals(game_cfg.Party.HUD.BarWidth * 0.5, child(ctx.root, "PartyHealthFill2").Size.x)
    assert.equals(game_cfg.Party.HUD.ColorBlockImage, child(ctx.root, "PartyHealthFill2").Image)
    assert.is_true(child(ctx.root, "PartyMember3").Visible)

    local row = child(ctx.root, "PartyMember2")
    assert.is_true(ctx.writer:ingest_event("PartyState", snapshot({
      member(1, "自己", 300, 300, "alive", true),
      member(2, "甲", 90, 300, "rescuing"),
    })))
    assert.is_true(row == child(ctx.root, "PartyMember2"), "同一队员更新不得重建行")
    assert.equals("90 / 300", child(ctx.root, "PartyHealthText2").Text)
    assert.is_nil(child(ctx.root, "PartyMember3"))

    local previous = ctx.store.party:now()
    assert.is_false(ctx.writer:ingest_event("PartyState", { state = "party", members = "bad" }))
    assert.is_true(previous == ctx.store.party:now())
    assert.is_true(row == child(ctx.root, "PartyMember2"))

    ctx.writer:ingest_event("PartyState", { state = "none", members = {} })
    assert.is_false(child(ctx.root, "PartyHud").Visible)
    assert.is_nil(child(ctx.root, "PartyMember2"))
  end)

  it("9-21 邀请文案、十秒倒计时与接受/拒绝上行保持协议", function()
    local sent = {}
    local ctx = mount({ send_party = function(payload) sent[#sent + 1] = payload end })
    ctx.writer:ingest_event("PartyState", { state = "none", members = {}, invite = {
      fromUserId = 2, fromName = "玩家2", expiresInSec = 10, expiresAt = 110,
    } })
    local invite = child(ctx.root, "PartyInvite")
    assert.is_true(invite.Visible)
    assert.equals("玩家2" .. game_cfg.Party.HUD.InviteText, child(ctx.root, "PartyInviteText").Text)
    assert.equals("10" .. game_cfg.Party.HUD.InviteCountdownText, child(ctx.root, "PartyInviteCountdown").Text)
    ctx.writer:advance_clock(3)
    assert.equals("7" .. game_cfg.Party.HUD.InviteCountdownText, child(ctx.root, "PartyInviteCountdown").Text)
    ctx.writer:ingest_event("PartyState", { state = "none", members = {}, invite = {
      fromUserId = 2, fromName = "玩家2", expiresInSec = 10, expiresAt = 110,
    } })
    assert.equals("7" .. game_cfg.Party.HUD.InviteCountdownText, child(ctx.root, "PartyInviteCountdown").Text)
    assert.is_true(eui.Click(child(ctx.root, "PartyInviteAccept")))
    assert.same({ action = "Accept" }, sent[1])
    assert.is_true(eui.Click(child(ctx.root, "PartyInviteDecline")))
    assert.same({ action = "Decline" }, sent[2])
    ctx.writer:advance_clock(7)
    assert.is_false(invite.Visible)
    ctx.writer:ingest_event("PartyState", { state = "none", members = {} })
    assert.is_false(eui.Click(child(ctx.root, "PartyInviteAccept")))
    assert.equals(2, #sent)
  end)

  it("9-19/9-22 拒绝原因与恢复/解散通知使用配置文案", function()
    local notices = {}
    local ctx = mount({ notify = function(text) notices[#notices + 1] = text end })
    ctx.writer:ingest_event("PartyResult", { action = "Invite", ok = false, reason = "too-far" })
    assert.equals(game_cfg.Party.HUD.TooFarText, notices[#notices])
    ctx.writer:ingest_event("PartyState", snapshot({ member(1, "自己", 300, 300, "alive", true) }, { notice = "full" }))
    assert.equals(game_cfg.Party.HUD.RestoreFullText, notices[#notices])
    ctx.writer:ingest_event("PartyState", { state = "none", members = {}, notice = "disbanded" })
    assert.equals(game_cfg.Party.HUD.DisbandText, notices[#notices])
    ctx.writer:ingest_event("PartyState", snapshot({ member(1, "自己", 300, 300, "alive", true) }, { notice = "restored" }))
    assert.equals(game_cfg.Party.HUD.RestoredText, notices[#notices])
  end)

  it("队友濒死按距离建抢救气泡，抢救上行，恢复/死亡/退队/超距对称销毁", function()
    local sent = {}
    local target = { UserId = 2, Character = { Position = { x = 1, y = 0, z = 0 } } }
    local ctx = mount({
      players = nil,
      send_interact = function(payload) sent[#sent + 1] = payload end,
      next_seq = function() return 41 end,
    })
    ctx.players[#ctx.players + 1] = target
    ctx.writer:update_spatial({ x = 0, y = 0, z = 0 }, {})
    ctx.writer:ingest_event("PartyState", snapshot({
      member(1, "自己", 300, 300, "alive", true), member(2, "甲", 1, 300, "downed"),
    }))
    ctx.writer:advance_clock(0.05)
    local button = child(ctx.root, "BtnSquadRescue2")
    assert.is_not_nil(button)
    assert.equals(game_cfg.Rescue.PromptText, button.Text)
    assert.is_true(eui.Click(button))
    assert.same({ target = game_cfg.Rescue.Target, action = game_cfg.Rescue.Action,
      targetUserId = 2, seq = 41 }, sent[1])

    ctx.writer:ingest_event("PartyState", snapshot({
      member(1, "自己", 300, 300, "alive", true), member(2, "甲", 1, 300, "rescuing"),
    }))
    ctx.writer:advance_clock(0.05)
    assert.is_true(button == child(ctx.root, "BtnSquadRescue2"), "濒死到抢救中不得重建同一气泡")
    ctx.writer:ingest_event("PartyState", snapshot({
      member(1, "自己", 300, 300, "alive", true), member(2, "甲", 30, 300, "alive"),
    }))
    assert.is_nil(child(ctx.root, "BtnSquadRescue2"))

    ctx.writer:ingest_event("PartyState", snapshot({
      member(1, "自己", 300, 300, "alive", true), member(2, "甲", 1, 300, "downed"),
    }))
    ctx.writer:advance_clock(0.05)
    assert.is_not_nil(child(ctx.root, "BtnSquadRescue2"))
    target.Character.Position.x = game_cfg.Rescue.Range + 1
    ctx.writer:advance_clock(0.05)
    assert.is_nil(child(ctx.root, "BtnSquadRescue2"))
    target.Character.Position.x = 1
    ctx.writer:advance_clock(0.05)
    assert.is_not_nil(child(ctx.root, "BtnSquadRescue2"))
    ctx.writer:ingest_event("PartyState", { state = "none", members = {} })
    assert.is_nil(child(ctx.root, "BtnSquadRescue2"))

    ctx.writer:ingest_event("PartyState", snapshot({
      member(1, "自己", 300, 300, "alive", true), member(2, "甲", 0, 300, "dead"),
    }))
    ctx.writer:advance_clock(0.05)
    assert.is_nil(child(ctx.root, "BtnSquadRescue2"))
  end)

  it("根 UI 销毁后行动节点、气泡与点击连接全部回收", function()
    local target = { UserId = 2, Character = { Position = { x = 1, y = 0, z = 0 } } }
    local ctx = mount({ players = { { UserId = 1 }, target } })
    ctx.writer:update_spatial({ x = 0, y = 0, z = 0 }, {})
    ctx.writer:ingest_event("PartyState", snapshot({
      member(1, "自己", 300, 300, "alive", true), member(2, "甲", 1, 300, "downed"),
    }, { invite = { fromUserId = 3, fromName = "玩家3", expiresInSec = 10, expiresAt = 110 } }))
    ctx.writer:advance_clock(0.05)
    local row = child(ctx.root, "PartyMember2")
    local accept = child(ctx.root, "PartyInviteAccept")
    local rescue = child(ctx.root, "BtnSquadRescue2")
    ctx.root:Destroy()
    assert.is_true(row.Destroyed)
    assert.is_true(rescue.Destroyed)
    assert.equals(0, accept.OnClicked:Count())
    assert.equals(0, rescue.OnClicked:Count())
  end)

  it("队友全员存活时零 on_frame 扫描，且分辨率通过 get_device_resolution 注入", function()
    local reads = 0
    local me = { UserId = 1 }
    local teammate = { UserId = 2, Character = { Position = { x = 1, y = 0, z = 0 } } }
    local store, writer = client_store.new({ initial_now = 100 })
    local root = eui.Node({ Name = "UIRoot" })
    local rescue = squad_view.rescue_state({
      get_players = function()
        reads = reads + 1
        return { me, teammate }
      end,
      get_local_player = function() return me end,
    })
    root_view.mount(root, store, {
      hud = { squad_view.hud_spec(), squad_view.rescue_driver_spec(rescue) },
      docks = {
        squad_members = squad_view.member_spec(),
        squad_rescue = squad_view.rescue_bubble_spec(rescue),
      },
      services = {
        get_device_resolution = function() return { x = 1280, y = 720 } end,
      },
      create_node = function(kind, props)
        local node = eui.Node({
          Kind = kind, Name = props and props.Name, Parent = props and props.Parent,
          Visible = props and props.Visible ~= false,
          Text = props and (props.Text or props.ButtonText) or "",
          TouchEnabled = kind == "EUIButton", Size = props and props.Size,
          Position = props and props.Position,
        })
        for key, value in pairs(props or {}) do node[key] = value end
        return node
      end,
    })
    local hud = game_cfg.Party.HUD
    assert.equals(1280 - hud.RowWidth - hud.MarginRight, child(root, "PartyHud").Position.x)

    writer:update_spatial({ x = 0, y = 0, z = 0 }, {})
    writer:ingest_event("PartyState", snapshot({
      member(1, "自己", 300, 300, "alive", true),
      member(2, "甲", 100, 100, "alive"),
    }))
    local baseline = reads
    writer:advance_clock(0.05)
    writer:advance_clock(0.05)
    assert.equals(baseline, reads)
    root:Destroy()
  end)
end)
