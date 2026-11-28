local GameCfg = require("common.game_cfg")
local Tokens = require("client.ui.tokens")
local Layout = require("client.ui.layout")
local Primitives = require("client.ui.primitives")
local Controls = require("client.ui.controls")
local ViewUtil = require("client.views.view_util")
local RescueView = require("client.views.rescue_view")

local SquadView = {}

-- 小队 HUD 与邀请卡片尺寸（全部对齐 4px 栅格，EUI Y-up 中心坐标，零重叠 StatusTopLeft / QuestLeft / HintTop / MenuEntry / CenterClear）。
local ROW_W = 232
local ROW_H = 56
local ROW_GAP = 8
local HUD_RIGHT_OFFSET = 360
local HUD_TOP_OFFSET = 60
local BAR_W = 208
local BAR_H = 16

local INVITE_W = 384
local INVITE_H = 124
local INVITE_TOP = 12
local INVITE_BTN_W = 140
local INVITE_BTN_H = 40
local INVITE_BTN_GAP = 24
local INVITE_BTN_Y = 32

local NOTICE_TEXT = {
  disbanded = "DisbandText", left = "LeftText", restored = "RestoredText",
  full = "RestoreFullText", joined = "", ["save-failed"] = "UnavailableText",
}
local REASON_TEXT = {
  ["too-far"] = "TooFarText", full = "FullText", offline = "OfflineText",
  ["target-in-party"] = "TargetInPartyText", ["no-invite"] = "NoInviteText",
  expired = "NoInviteText", ["save-failed"] = "UnavailableText",
  ["already-in-party"] = "UnavailableText", invalid = "UnavailableText",
}

local function panel_height(max_rows)
  local count = math.max(1, max_rows or 2)
  return count * ROW_H + math.max(0, count - 1) * ROW_GAP
end

local function notice_from_event(ctx, event)
  if type(event) ~= "table" then return end
  local payload = event.payload
  if event.channel == "PartyResult" and type(payload) == "table" then
    if payload.ok then return end
    local field = REASON_TEXT[payload.reason]
    if field then ViewUtil.notify(ctx, GameCfg.Party.HUD[field]) end
  elseif event.channel == "PartyState" and type(payload) == "table" then
    local field = NOTICE_TEXT[payload.notice]
    if field then ViewUtil.notify(ctx, GameCfg.Party.HUD[field] or "") end
  end
end

function SquadView.hud_spec()
  return {
    name = "SquadHud",
    mount = function(scope, ctx)
      local hud = GameCfg.Party.HUD
      local screen = ViewUtil.get_resolution(ctx)
      if screen == nil then return end

      local panel_h = panel_height(hud.MaxRows)
      local right_offset = Layout.snap4(math.min(HUD_RIGHT_OFFSET, math.max(Tokens.SPACE.SAFE_EDGE, screen.x - ROW_W - Tokens.SPACE.SAFE_EDGE)))
      local panel = Primitives.container(scope, ctx, {
        name = "PartyHud",
        rect = Layout.from_top_right(screen.x, screen.y, right_offset, HUD_TOP_OFFSET, ROW_W, panel_h),
        z_order = Tokens.Z.HUD_CONTENT,
        visible = false,
      })

      local invite = Primitives.capsule(scope, ctx, {
        name = "PartyInvite",
        rect = Layout.top_center(screen.x, screen.y, INVITE_TOP, INVITE_W, INVITE_H),
        z_order = Tokens.Z.HUD_POPUP_BG,
        visible = false,
      })
      invite.TouchEnabled = true
      invite.SwallowTouchEnabled = true

      local text = Primitives.label(scope, ctx, {
        name = "PartyInviteText",
        parent = invite,
        rect = Layout.from_top_left(INVITE_H, 16, 8, INVITE_W - 32, 28),
        text = "",
        font_size = Tokens.FONT_SIZE.CAPTION,
        bold = true,
        color = Tokens.COLOR.WHITE,
        outline = true,
        outline_color = Tokens.COLOR.OUTLINE_DARK,
        z_order = 1,
      })

      local countdown = Primitives.label(scope, ctx, {
        name = "PartyInviteCountdown",
        parent = invite,
        rect = Layout.from_top_left(INVITE_H, 16, 40, INVITE_W - 32, 24),
        text = "",
        font_size = Tokens.FONT_SIZE.MICRO,
        bold = false,
        color = Tokens.COLOR.TEXT_GOLD,
        outline = true,
        outline_color = Tokens.COLOR.OUTLINE_DARK,
        z_order = 1,
      })

      local send = ctx.services and ctx.services.send_party
      local btn_slots = Layout.centered_row(INVITE_W, INVITE_BTN_Y, 2, INVITE_BTN_W, INVITE_BTN_H, INVITE_BTN_GAP)
      local accept = Controls.button(scope, ctx, {
        name = "PartyInviteAccept",
        parent = invite,
        rect = btn_slots[1],
        text = hud.AcceptText,
        variant = "gold",
        font_size = Tokens.FONT_SIZE.CAPTION,
        z_order = 2,
        touch = false,
        on_click = function()
          if type(send) == "function" then send({ action = "Accept" }) end
        end,
      })
      local decline = Controls.button(scope, ctx, {
        name = "PartyInviteDecline",
        parent = invite,
        rect = btn_slots[2],
        text = hud.DeclineText,
        variant = "blue",
        font_size = Tokens.FONT_SIZE.CAPTION,
        z_order = 2,
        touch = false,
        on_click = function()
          if type(send) == "function" then send({ action = "Decline" }) end
        end,
      })

      scope:subscribe(ctx.store.on_server_event, function(event) notice_from_event(ctx, event) end)

      local invite_identity, fallback_expires_at = nil, nil
      scope:effect("PartyHudProjection", function(es)
        local party = es:d(ctx.store.party)
        es:d(ctx.clock.second)
        panel.Visible = party.state == "party"

        local invitation = party.invite
        if invitation then
          local identity = tostring(invitation.fromUserId) .. ":" .. tostring(invitation.expiresAt or "local")
          if identity ~= invite_identity then
            invite_identity = identity
            fallback_expires_at = invitation.expiresAt or (ctx.clock.now() + invitation.expiresInSec)
          end
          local left = math.max(0, math.ceil(fallback_expires_at - ctx.clock.now()))
          local visible = left > 0
          invite.Visible = visible
          Controls.set_button_enabled(accept, visible, "gold")
          Controls.set_button_enabled(decline, visible, "blue")
          text.Text = tostring(invitation.fromName or invitation.fromUserId) .. hud.InviteText
          countdown.Text = tostring(left) .. hud.InviteCountdownText
        else
          invite_identity, fallback_expires_at = nil, nil
          invite.Visible = false
          Controls.set_button_enabled(accept, false, "gold")
          Controls.set_button_enabled(decline, false, "blue")
          text.Text, countdown.Text = "", ""
        end
      end)
    end,
  }
end

function SquadView.member_spec()
  return {
    items = function(es, store)
      local party = es:d(store.party)
      if party.state ~= "party" then return {} end
      local rows = {}
      for _, row in ipairs(party.members) do
        if not row.self and #rows < GameCfg.Party.HUD.MaxRows then
          rows[#rows + 1] = {
            userId = row.userId, name = row.name, health = row.health, max_health = row.max_health,
            phase = row.phase, index = #rows + 1,
          }
        end
      end
      return rows
    end,
    key_of = function(row) return tostring(row.userId) end,
    mount = function(scope, ctx, item_signal)
      local hud = GameCfg.Party.HUD
      local panel = ctx.root_node:FindFirstChild("PartyHud", true) or ctx.root_node
      local uid = tostring(item_signal:now().userId)
      local total_h = panel_height(hud.MaxRows)

      local row = Primitives.capsule(scope, ctx, {
        name = "PartyMember" .. uid,
        parent = panel,
        rect = Layout.from_top_left(total_h, 0, 0, ROW_W, ROW_H),
        z_order = 1,
        visible = true,
      })

      local name = Primitives.label(scope, ctx, {
        name = "PartyMemberName" .. uid,
        parent = row,
        rect = Layout.from_top_left(ROW_H, 12, 4, 116, 24),
        text = "",
        font_size = Tokens.FONT_SIZE.MICRO,
        bold = true,
        color = Tokens.COLOR.WHITE,
        outline = true,
        outline_color = Tokens.COLOR.OUTLINE_DARK,
        align_x = 0,
        align_y = 1,
        z_order = 1,
      })

      local health_text = Primitives.label(scope, ctx, {
        name = "PartyHealthText" .. uid,
        parent = row,
        rect = Layout.from_top_right(ROW_W, ROW_H, 12, 4, 88, 24),
        text = "",
        font_size = Tokens.FONT_SIZE.MICRO,
        bold = false,
        color = Tokens.COLOR.TEXT_SOFT_WHITE,
        outline = true,
        outline_color = Tokens.COLOR.OUTLINE_DARK,
        align_x = 2,
        align_y = 1,
        z_order = 1,
      })

      local bar_bg = Primitives.image(scope, ctx, {
        name = "PartyHealthBar" .. uid,
        parent = row,
        rect = Layout.from_top_left(ROW_H, 12, 32, BAR_W, BAR_H),
        image = Tokens.ASSET.ROUND_RECT,
        color = Tokens.COLOR.HUD_BAR_BG,
        opacity = Tokens.OPACITY.HUD_SURFACE,
        stretch = Tokens.vec4(8, 8, 8, 8),
        z_order = 1,
      })

      local fill = ctx.create_node(scope, "EUILoadingBar", {
        Name = "PartyHealthFill" .. uid,
        Parent = bar_bg,
        Position = Tokens.vec2(BAR_W / 2, BAR_H / 2),
        Size = Tokens.vec2(BAR_W - 4, BAR_H - 4),
        Image = Tokens.ASSET.BAR_FILL,
        Direction = 0,
        Percent = 100,
        Visible = true,
        LocalZOrder = 1,
      })
      fill.Color = ViewUtil.color(Tokens.COLOR.HEALTH)
      fill.TouchEnabled = false
      fill.SwallowTouchEnabled = false

      scope:effect("PartyMemberProjection", function(es)
        local value = es:d(item_signal)
        local health = value.health or 0
        local maximum = value.max_health or 0
        local top = (value.index - 1) * (ROW_H + ROW_GAP)
        Layout.apply(row, Layout.from_top_left(total_h, 0, top, ROW_W, ROW_H))
        row.Visible = true
        name.Text = value.name
        health_text.Text = tostring(health) .. " / " .. tostring(maximum)
        local ratio = maximum > 0 and math.max(0, math.min(1, health / maximum)) or 0
        fill.Percent = ratio * 100
      end)
    end,
  }
end

-- 抢救入口（state / driver_spec / bubble_spec）的参数集中在 RescueView 的预设里，这里只绑定本视图的入口。
local RescueApi = RescueView.view_api("squad")

SquadView.rescue_state = RescueApi.state
SquadView.rescue_driver_spec = RescueApi.driver_spec
SquadView.rescue_bubble_spec = RescueApi.bubble_spec

return SquadView
